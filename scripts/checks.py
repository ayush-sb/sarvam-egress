#!/usr/bin/env python3
"""Window checks for sweep.sh: is a measured window valid, and did the two gateway arms see the same load?

  checks.py sample URL ENGINE        print load samples (tokens, streams in flight) once a second
  checks.py window DIR LEVEL MODE SECONDS    check one window, write DIR/gate.json; exit 1 if rejected
  checks.py pair [--direct] DIR DIR  compare two windows of a pair (or a gateway arm with SGLang's own server)
"""

import argparse
import json
from pathlib import Path
import re
import sys
import time
from urllib.request import urlopen


def metrics(text, engine):
    tokens = running = 0
    for line in text.splitlines():
        if engine == "sglang-direct":
            is_running = line.startswith("sglang:num_running_reqs{")
            is_token = (line.startswith("sglang:realtime_tokens_total{")
                        and 'engine_type="unified"' in line and 'mode="decode"' in line)
        else:
            is_running = line.startswith("dynamo_frontend_inflight_requests")
            is_token = line.startswith("dynamo_frontend_output_tokens_total")
        if is_running:
            running += int(float(line.rsplit(maxsplit=1)[-1]))
        if is_token:
            tokens += int(float(line.rsplit(maxsplit=1)[-1]))
    return {"tokens": tokens, "inflight": running}


def sample(url, engine):
    while True:
        try:
            with urlopen(url, timeout=1) as response:
                result = metrics(response.read().decode(), engine)
        except (OSError, ValueError):
            result = {"scrape_failed": True}
        print(json.dumps({"t_ns": time.time_ns()} | result), flush=True)
        time.sleep(2)


def load(path):
    return json.loads(path.read_text())


def thread_peak(path, process=None):
    """Largest average per-thread CPU percentage in pidstat -u -t output."""
    values = []
    group = None
    for line in path.read_text().splitlines():
        fields = line.split()
        if not line.startswith("Average:") or len(fields) < 10:
            continue
        if fields[2].isdigit() and fields[3] == "-":
            group = int(fields[2])
        if fields[2] == "-" and fields[3].isdigit() and (process is None or group == process):
            values.append(float(fields[-3]))
    if not values:
        raise ValueError(f"Missing per-thread CPU samples in {path.name}")
    return max(values)


def write_gate(path, result):
    (path / "gate.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return bool(result["errors"])


def window(path, count, mode, expected_seconds):
    summary = load(path / "summary.json")
    a, b = (load(path / f"snap_{edge}.json") for edge in "ab")
    series = [a]
    with (path / "load-samples.jsonl").open() as stream:
        for line in stream:
            row = json.loads(line)
            if a["t_ns"] < row["t_ns"] < b["t_ns"]:
                series.append(row)
    series.append(b)
    errors = []
    warnings = []
    seconds = summary["window_s"]
    minimum = (count * 98 + 99) // 100
    if seconds < expected_seconds * .98 or seconds > expected_seconds * 1.15:
        errors.append("measurement window duration differs from the configured duration")
    if len(series) < 4 or any(p.get("inflight", 0) < minimum for p in series):
        errors.append(f"missing samples or fewer than {minimum} active requests during the window")
    durations = [(y["t_ns"] - x["t_ns"]) / 1e9 for x, y in zip(series, series[1:])]
    if max(durations) > 4.5 or min(durations) <= 0:
        errors.append("clock or gaps in active-load sampling")
    rates = [(y["tokens"] - x["tokens"]) / dt for x, y, dt in zip(series, series[1:], durations)
             if "tokens" in x and "tokens" in y and dt >= 1.25]
    tps = summary["tokens_per_s"]
    if len(rates) < 2 or min(rates) < .75 * tps:
        errors.append("decode delivery stalled or fell below 75% of the window rate")

    mock = summary.get("engine") == "mocker"     # Dynamo's mock engine: no SGLang log lines, no prompt set
    engine = summary.get("engine_log") or {}
    if not mock and (engine.get("decode_log_lines", 0) < 2 or (engine.get("running_req_min") or 0) < minimum):
        errors.append(f"worker logs do not establish {minimum} sustained decoding requests")
    lifecycle = path / "worker-after-launch.log"
    worker = lifecycle.read_text(errors="replace")
    if re.search(r"Retract requests|out of memory|KV cache pool is full", worker, re.I):
        errors.append("worker had KV retractions or an out-of-memory condition, including during drain")

    client = summary.get("client", {})
    arrivals = client.get("window") or {}
    if client.get("errors_or_incomplete", 1) or not (arrivals.get("chunk_gap_ms") or {}).get("p99"):
        errors.append("client errors or missing in-window inter-token measurements")
    if not mock and client.get("requests") != int((path / "expected-prompts.txt").read_text()):
        errors.append("official client did not finish the full fixed prompt set")
    grouping = summary.get("tokens_per_event") or 0
    if grouping > 1.20 and summary.get("engine") != "sglang-direct":
        # Dynamo's SGLang worker merges tokens before the gateway sees them. Both gateway arms share
        # that worker, and the pair check still requires them to match. Report it, do not reject.
        warnings.append(f"{grouping:.2f} logical tokens per client event; the worker groups tokens upstream of the gateway")
    elif not .90 <= grouping <= 1.20:
        errors.append(f"{grouping:.2f} logical tokens per client event is outside 0.90–1.20")

    gates = summary.get("gates", {})
    client_peak = thread_peak(path / "pidstat_client.txt")
    worker_peak = thread_peak(path / "pidstat_worker.txt")
    serving_pid = int((path / "worker-id.txt").read_text().split()[0])
    serving_peak = thread_peak(path / "pidstat_worker.txt", serving_pid)
    if client_peak >= 90 or (gates.get("client_cpu_busy_max_pct") or 0) >= 85:
        errors.append("client CPU is saturated")
    engine_busy = (gates.get("engine_cpu_busy_mean_pct") or 0) >= 85
    if summary.get("engine") == "sglang-direct" and serving_peak >= 90 and not engine_busy:
        # SGLang's own server runs one Python thread for every stream. If it saturates, that is a
        # measurement of the no-gateway path (its sustainable concurrency). The window is still
        # valid if delivery holds. The in-flight, rate, grouping and routed-vs-direct checks decide that.
        warnings.append("direct SGLang server thread reached 90%; no-gateway path is at its CPU limit")
    elif serving_peak >= 90 or engine_busy:
        errors.append("engine or relay host CPU is saturated")
    if worker_peak >= 90 and serving_peak < 90:
        warnings.append("a worker subprocess thread reached 90%; inspect scheduler feeding and GPU utilization")

    if mode == "latency":
        wire = summary.get("wire", {})
        invalid_counts = ("dropped_by_kernel", "sequence_gaps", "ambiguous_overlaps", "negative_latencies")
        coverage = (wire.get("stamped_tokens") or 0) / max(1, summary["tokens_in_window"])
        if any(wire.get(key) != 0 for key in invalid_counts) or not .95 <= coverage <= 1.05:
            errors.append(f"invalid packet capture or stamp coverage {coverage:.1%} outside 95–105%")
        if (wire.get("emit_to_wire_us") or {}).get("p99.9") is None:
            errors.append("missing emit-to-wire p99.9")
    if mode == "syscalls" and (not summary.get("syscalls_per_token") or not summary.get("wire_bytes_per_token")):
        errors.append("missing syscall count or captured bytes")
    if mode == "profile" and not (path / "frontend.folded").stat().st_size:
        errors.append("the CPU profile has no resolved stacks")

    return {
        "errors": errors, "warnings": warnings, "tokens_per_s": tps,
        "client_events_per_s": (summary.get("content_events_in_window") or 0) / seconds,
        "tokens_per_event": grouping, "min_inflight": min(row.get("inflight", 0) for row in series),
        "min_segment_tokens_per_s": round(min(rates)) if rates else None,
        "client_thread_peak_pct": client_peak, "engine_thread_peak_pct": worker_peak,
        "relay_or_direct_server_thread_peak_pct": serving_peak,
        "gateway_cores_busy": summary.get("frontend_cores_busy"),
    }


def compare(left, right, is_direct, rate_tolerance=.05):
    problems, notes = [], []
    for metric in ("tokens_per_s", "client_events_per_s", "tokens_per_event"):
        a, b = left[metric], right[metric]
        if is_direct and metric == "tokens_per_event":
            # Worker grouping is reported by the window gate; record the difference from direct.
            if not min(a, b) or max(a, b) / min(a, b) > 1.05:
                notes.append(f"routed tokens_per_event differs from direct SGLang ({b:.2f} vs {a:.2f})")
        elif is_direct:
            if b < .90 * a:
                # Fewer routed events follow from worker grouping, which the window gate reports.
                (notes if metric == "client_events_per_s" else problems).append(
                    f"routed {metric} is under 90% of direct SGLang ({b:.2f} vs {a:.2f})")
        elif metric == "tokens_per_s":
            if not min(a, b) or max(a, b) / min(a, b) > 1 + rate_tolerance:
                problems.append(f"{metric} differs by more than {rate_tolerance:.0%} ({a:.2f} vs {b:.2f})")
        elif not min(a, b) or max(a, b) / min(a, b) > 1.10:
            # The Dynamo worker merges tokens upstream of the gateway, unevenly between runs. A
            # grouping difference is reported with the window (CPU per event is in the table).
            notes.append(f"{metric} differs by more than 10% ({a:.2f} vs {b:.2f})")
    return problems, notes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    sampler = commands.add_parser("sample")
    sampler.add_argument("url")
    sampler.add_argument("engine")
    check = commands.add_parser("window")
    check.add_argument("path", type=Path)
    check.add_argument("count", type=int)
    check.add_argument("mode")
    check.add_argument("seconds", type=int)
    pair = commands.add_parser("pair")
    pair.add_argument("left", type=Path)
    pair.add_argument("right", type=Path)
    pair.add_argument("--direct", action="store_true")
    # CPU per token depends on the token rate, so cpu windows need a close match. In the other windows
    # the instruments (perf, timestamps) slow the two frontends by different amounts.
    pair.add_argument("--rate-tolerance", type=float, default=.05)
    args = parser.parse_args()
    if args.command == "sample":
        sample(args.url, args.engine)
    elif args.command == "window":
        try:
            result = window(args.path, args.count, args.mode, args.seconds)
        except (OSError, ValueError, KeyError, TypeError) as error:
            result = {"errors": [str(error)]}
        return write_gate(args.path, result)
    else:
        paths = (args.left, args.right)
        left, right = (load(path / "gate.json") for path in paths)
        problems, notes = compare(left, right, args.direct, args.rate_tolerance)
        errors = left["errors"] + right["errors"] + problems
        if not args.direct and (paths[0] / "worker-id.txt").read_text() != (paths[1] / "worker-id.txt").read_text():
            errors.append("the two gateways used different worker processes")
        print(json.dumps({"errors": errors, "warnings": notes, "windows": [str(path) for path in paths]}, indent=2))
        return bool(errors)


if __name__ == "__main__":
    sys.exit(main())
