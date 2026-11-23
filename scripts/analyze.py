"""Summarise one measurement window (a measure.sh output directory) into summary.json.

  analyze.py DIR --concurrency N --mode MODE --engine sglang|sglang-direct --variant NAME
             --frontend-cpus LIST --engine-cpus LIST --client-cpus LIST

CPU comes from the snapshots at the window edges: the frontend process (for SGLang's own server: its
main process) and the worker's whole process group. Client timing comes from SGLang's benchmark client,
cut to the window with clock.json. Flags mark a window whose numbers need care; they never drop it.
"""
import argparse
import collections
import json
import os
from pathlib import Path
import re
import statistics

ap = argparse.ArgumentParser()
ap.add_argument("out", type=Path)
ap.add_argument("--concurrency", type=int, required=True)
ap.add_argument("--mode", required=True)
ap.add_argument("--engine", required=True)
ap.add_argument("--variant", required=True)
ap.add_argument("--frontend-cpus", required=True)
ap.add_argument("--engine-cpus", required=True)
ap.add_argument("--client-cpus", required=True)
args = ap.parse_args()
out = args.out
TICK = os.sysconf("SC_CLK_TCK")
gateway = args.engine != "sglang-direct"


def cpus(spec):   # "1,2,4-7" -> [1, 2, 4, 5, 6, 7]
    result = []
    for part in filter(None, spec.split(",")):
        lo, _, hi = part.partition("-")
        result.extend(range(int(lo), int(hi or lo) + 1))
    return result


def pct(values, p):   # percentile of a sorted list
    return values[min(len(values) - 1, int(p / 100 * len(values)))] if values else None


def load(name):
    return json.loads((out / name).read_text())


# CPU and tokens between the two snapshots.
a, b = load("snap_a.json"), load("snap_b.json")
secs = (b["t_ns"] - a["t_ns"]) / 1e9
tokens = b["tokens"] - a["tokens"]
if tokens <= 0 or secs <= 0:
    raise SystemExit("no tokens counted in the window")
frontend_cpu = (b["frontend_ticks"] - a["frontend_ticks"]) / TICK
worker_cpu = (b["worker_ticks"] - a["worker_ticks"]) / TICK
worker_main_cpu = (b["worker_main_ticks"] - a["worker_main_ticks"]) / TICK
# The whole serving path. Worker main process: SGLang's HTTP server and tokenizer manager (no gateway),
# or Dynamo's Python relay and SGLang's tokenizer manager. Engine: the rest of the worker (scheduler,
# detokenizer). With no gateway the "frontend" process is the worker's main process, so it adds nothing.
serving = {"engine": worker_cpu - worker_main_cpu, "worker_main": worker_main_cpu,
           "frontend": frontend_cpu if gateway else 0.0}
serving["total"] = sum(serving.values())

s = {
    "concurrency": args.concurrency, "mode": args.mode, "engine": args.engine, "variant": args.variant,
    "gateway": gateway,           # False: the frontend_* fields describe SGLang's own server process
    "gateway_cpus": args.frontend_cpus, "gateway_cores": len(cpus(args.frontend_cpus)),
    "window_s": round(secs, 2), "tokens_in_window": tokens, "tokens_per_s": round(tokens / secs),
    "frontend_cpu_s": round(frontend_cpu, 2),
    "frontend_cores_busy": round(frontend_cpu / secs, 3),
    "frontend_cpu_s_per_1m_tokens": round(frontend_cpu / tokens * 1e6, 2),
    "tokens_per_frontend_core_s": round(tokens / frontend_cpu) if frontend_cpu else None,
    "worker_cores_busy": round(worker_cpu / secs, 3),
    "serving_cpu_s_per_1m_tokens": {k: round(v / tokens * 1e6, 2) for k, v in serving.items()},
}

# Busy share of each core over the window (100 - idle; includes steal, which is also kept on its own).
busy, steal, header = {}, {}, None
for line in (out / "mpstat.txt").read_text().splitlines():
    f = line.split()
    if len(f) > 2 and f[0] == "Average:" and f[1] == "CPU":
        header = f[1:]
    elif len(f) > 2 and f[0] == "Average:" and f[1].isdigit():
        busy[int(f[1])] = round(100 - float(f[-1]), 1)
        if header and "%steal" in header:
            steal[int(f[1])] = float(f[1 + header.index("%steal")])
s["cpu_busy_pct"], s["cpu_steal_pct"] = busy, steal

# Client timing from SGLang's benchmark client, for the whole run and cut to the window. A gap belongs to
# the window when the event that ends it arrives inside the window. clock.json converts the window's
# realtime edges to the client's monotonic clock.
client = json.loads((out / "sglang-client.jsonl").read_text().splitlines()[-1])
offsets = load("clock.json")["realtime_minus_monotonic_ns"]
offset = sum(offsets) / len(offsets)
lo, hi = (a["t_ns"] - offset) / 1e9, (b["t_ns"] - offset) / 1e9
gaps, ttfts, gaps_w, events_w, starts_w = [], [], [], 0, 0
with open(out / "arrivals.jsonl", "w") as arrivals:     # every token's arrival time, per request
    for request, (start, ttft, intervals, error) in enumerate(zip(
            client["start_times"], client["ttfts"], client["itls"], client["errors"], strict=True)):
        if error or ttft <= 0:
            continue
        times = [start + ttft]
        ttfts.append(ttft * 1000)
        for gap in intervals:
            times.append(times[-1] + gap)
            gaps.append(gap * 1000)
        arrivals.write(json.dumps({"request": request, "monotonic_s": times}) + "\n")
        starts_w += lo <= start < hi
        for i, t in enumerate(times):
            if lo <= t < hi:
                events_w += 1
                if i:
                    gaps_w.append((t - times[i - 1]) * 1000)
if not gaps or any(client["errors"]) or client["completed"] != len(client["errors"]):
    raise SystemExit("the client did not complete the workload")
levels = (("p50", 50), ("p99", 99), ("p99.9", 99.9))
gaps.sort(); ttfts.sort(); gaps_w.sort()
s["client"] = {
    "requests": client["completed"], "errors_or_incomplete": 0,
    "chunk_gap_ms": {k: pct(gaps, p) for k, p in levels},         # whole run, ramp-up and drain included
    "ttft_ms": {k: pct(ttfts, p) for k, p in levels},
    "window": {"content_events": events_w, "requests_started": starts_w,
               "chunk_gap_ms": {k: pct(gaps_w, p) for k, p in levels} if gaps_w else None},
}
s["content_events_in_window"] = events_w

if args.mode == "latency":
    s["wire"] = load("wire_latency.json")
if args.mode == "syscalls":
    wire = load("wire_bytes.json")
    if wire["dropped_by_kernel"] or not wire["captured_bytes"]:
        raise SystemExit("unusable packet capture")
    s["wire_bytes_per_token"] = wire["captured_bytes"] / tokens
    s["payload_bytes_per_event"] = wire.get("payload_bytes_per_event")    # SSE body, no timestamp comments
    counts = {}
    for line in (out / "syscalls.txt").read_text().splitlines():
        if (m := re.match(r"\s*([\d,]+)\s+syscalls:sys_enter_(\w+)", line)) and int(m[1].replace(",", "")):
            counts[m[2]] = int(m[1].replace(",", ""))
    s["syscalls_per_token"] = round(sum(counts.values()) / tokens, 3)
    s["syscalls_per_token_by_name"] = {k: round(v / tokens, 3) for k, v in sorted(counts.items(), key=lambda kv: -kv[1])[:12]}

# Per SSE event: most frontend work is per event, so CPU per token moves when the worker groups tokens.
if events_w:
    s["tokens_per_event"] = round(tokens / events_w, 3)
    s["frontend_cpu_us_per_event"] = round(frontend_cpu / events_w * 1e6, 2)

# SGLang's decode-batch log lines from the window: running requests, CUDA graph use, retractions.
running, graph, retractions = [], collections.Counter(), 0
for line in (out / "worker-window.log").read_text(errors="replace").splitlines():
    retractions += "Retract requests" in line
    if "Decode batch" in line:
        if m := re.search(r"#running-req: (\d+)", line):
            running.append(int(m[1]))
        if m := re.search(r"graph: (True|False)", line):
            graph[m[1]] += 1
s["engine_log"] = {"decode_log_lines": len(running), "running_req_min": min(running, default=None),
                   "cuda_graph_lines": dict(graph), "retraction_lines": retractions}

engine_cpus, client_cpus = cpus(args.engine_cpus), cpus(args.client_cpus)
measured = set(cpus(args.frontend_cpus)) | set(engine_cpus) | set(client_cpus)
s["gates"] = {
    "engine_cpu_busy_mean_pct": round(statistics.mean(busy[c] for c in engine_cpus if c in busy), 1) if busy else None,
    "client_cpu_busy_max_pct": max((busy[c] for c in client_cpus if c in busy), default=None),
    "steal_max_pct": max((steal[c] for c in measured if c in steal), default=None),
}
flags = []
if (s["gates"]["engine_cpu_busy_mean_pct"] or 0) > 85: flags.append("engine-cpu-saturated")
if (s["gates"]["client_cpu_busy_max_pct"] or 0) > 85: flags.append("client-cpu-saturated")
if (s["gates"]["steal_max_pct"] or 0) > 2: flags.append("steal")
if (s.get("tokens_per_event") or 0) > 1.2: flags.append("grouped-frames")          # the worker merged tokens
if starts_w > 0.05 * args.concurrency: flags.append("requests-started-in-window")
if retractions: flags.append("kv-retractions")
if graph.get("False"): flags.append("decode-without-cuda-graph")
s["flags"] = flags
(out / "summary.json").write_text(json.dumps(s, indent=2) + "\n")
print(json.dumps(s, indent=2))
