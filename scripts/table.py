"""Build the brief's table from one benchmark output directory (sweep.sh calls it after every window).

  table.py results/bench-<time> default-gateway > table.md      (also writes table.json there)

One row per arm and concurrency level. CPU and client numbers: median of the cpu windows (with min-max).
Syscalls and bytes: the syscalls window. Emit-to-wire latency: median of the latency windows. Windows with a
profiler or a capture attached never give CPU numbers. Client gaps are cut to the measured window.
When tokens per event differ between arms, compare CPU per event, not CPU per token.
"""
import collections, glob, json, os, statistics, sys

root = sys.argv[1].rstrip("/")
runs = []
for f in sorted(glob.glob(f"{root}/*/summary.json")):
    s = json.load(open(f)); s["_dir"] = os.path.basename(os.path.dirname(f)); runs.append(s)
if not runs: sys.exit(f"no runs under {root}")

SAT_CPU = 0.90      # frontend above 90% of its allotted cores -> not sustainable
SAT_GAP = 1.20      # client gap p99 more than 20% above the lowest level's -> not sustainable

def med(v):
    v = [x for x in v if x is not None]
    return statistics.median(v) if v else None
def rng(v):
    v = [x for x in v if x is not None]
    return (min(v), max(v)) if v else (None, None)
def f(x, d=1): return "-" if x is None else f"{x:,.{d}f}"
def gap_window(s, k):
    g = (s["client"].get("window") or {}).get("chunk_gap_ms") or {}
    return g.get(k)
def stalls(l, threshold, k):
    return ((l.get("stall_episodes") or {}).get(f"over_{threshold}ms") or {}).get(k)
groups = collections.defaultdict(lambda: collections.defaultdict(list))
for s in runs: groups[(s.get("variant", "baseline"), s["concurrency"])][s["mode"]].append(s)
variants = list(dict.fromkeys(s.get("variant", "baseline") for s in runs))
levels = sorted({s["concurrency"] for s in runs})

rows = {}
for (v, c), by_mode in groups.items():
    cpu = by_mode.get("cpu", [])
    if not cpu: continue
    lat_runs = [s.get("wire") or {} for s in by_mode.get("latency", [])]
    lat = lat_runs[0] if lat_runs else {}
    sysc = (by_mode.get("syscalls") or [{}])[0]
    prof = (by_mode.get("profile") or [{}])[0]
    e2w = {k: med([(l.get("emit_to_wire_us") or {}).get(k) for l in lat_runs]) for k in ("p50", "p99", "p99.9")}
    names = sysc.get("syscalls_per_token_by_name") or {}
    rows[(v, c)] = {
        "variant": v, "streams": c, "gateway": cpu[0].get("gateway", True), "n": len(cpu),
        "gateway_cores": cpu[0].get("gateway_cores"),
        "tokens_per_s": med([s["tokens_per_s"] for s in cpu]),
        "cpu_s_per_1m": med([s["frontend_cpu_s_per_1m_tokens"] for s in cpu]),
        "cpu_s_per_1m_range": rng([s["frontend_cpu_s_per_1m_tokens"] for s in cpu]),
        "tokens_per_core_s": med([s["tokens_per_frontend_core_s"] for s in cpu]),
        "fe_cores_busy": med([s["frontend_cores_busy"] for s in cpu]),
        "engine_cores_busy": med([s["worker_cores_busy"] for s in cpu]),
        "syscalls_per_token": sysc.get("syscalls_per_token"),
        "syscalls_top": ", ".join(f"{k} {x:.2f}" for k, x in list(names.items())[:2]),
        # SSE body bytes per event, from the syscalls window: latency windows add timestamp comments.
        "payload_bytes_per_event": sysc.get("payload_bytes_per_event") or lat.get("payload_bytes_per_event"),
        "wire_bytes_per_token": sysc.get("wire_bytes_per_token"),
        "packets_per_event": lat.get("packets_per_event"),
        "e2w_p50_us": e2w.get("p50"), "e2w_p99_us": e2w.get("p99"), "e2w_p999_us": e2w.get("p99.9"),
        "e2w_p999_range_us": rng([(l.get("emit_to_wire_us") or {}).get("p99.9") for l in lat_runs]),
        "latency_windows": len(lat_runs),
        "h2w_us": {k: med([(l.get("handoff_to_wire_us") or {}).get(k) for l in lat_runs]) for k in ("p50", "p99", "p99.9")},
        "s2h_us": {k: med([(l.get("step_to_handoff_us") or {}).get(k) for l in lat_runs]) for k in ("p50", "p99")},
        "capture_dropped": max([l.get("dropped_by_kernel") or 0 for l in lat_runs], default=None),
        "stamped_tokens": lat.get("stamped_tokens"),
        "latency_tokens_per_event": med([l.get("tokens_per_event") for l in lat_runs]),
        "stall_episodes_100ms": med([stalls(l, 100, "episodes") for l in lat_runs]),
        "stall_episodes_250ms": med([stalls(l, 250, "episodes") for l in lat_runs]),
        "stall_worst_ms": max([stalls(l, 100, "worst_ms") or 0 for l in lat_runs], default=None) or None,
        "gap_p50_ms": med([gap_window(s, "p50") for s in cpu]),
        "gap_p99_ms": med([gap_window(s, "p99") for s in cpu]),
        "tokens_per_event": med([s.get("tokens_per_event") for s in cpu]),
        "cpu_us_per_event": med([s.get("frontend_cpu_us_per_event") for s in cpu]),
        "cpu_us_per_event_range": rng([s.get("frontend_cpu_us_per_event") for s in cpu]),
        "flags": sorted({flag for s in cpu + by_mode.get("latency", []) for flag in s.get("flags") or []}),
        "ttft_p50_ms": med([(s["client"].get("ttft_ms") or {}).get("p50") for s in cpu]),
        "errors": sum(s["client"].get("errors_or_incomplete") or 0 for s in cpu),
        "flame": f'{prof["_dir"]}/flame.svg' if prof else None,
        "serving_cpu_s_per_1m": {k: med([(s.get("serving_cpu_s_per_1m_tokens") or {}).get(k) for s in cpu])
                                 for k in ("engine", "worker_main", "frontend", "total")},
    }
for v in variants:      # sustainability, per variant
    ref = next((rows[(v, c)]["gap_p99_ms"] for c in levels if (v, c) in rows), None)
    for c in levels:
        r = rows.get((v, c))
        if not r: continue
        cpu_ok = (not r["gateway"]) or not r["gateway_cores"] or r["fe_cores_busy"] <= SAT_CPU * r["gateway_cores"]
        gap_ok = ref is None or r["gap_p99_ms"] is None or r["gap_p99_ms"] <= SAT_GAP * ref
        r["sustainable"] = bool(cpu_ok and gap_ok and r["gap_p99_ms"] is not None and not r["errors"])
        r["limit"] = "" if r["sustainable"] else ("cpu" if not cpu_ok else "latency or invalid workload")
json.dump([rows[k] for k in sorted(rows, key=lambda k: (variants.index(k[0]), k[1]))], open(f"{root}/table.json", "w"), indent=1)

# ---- Markdown: the brief's measures first (result, then one short table per level), then details and settings.
direct = next((v for v in variants if any(not rows[k]["gateway"] for k in rows if k[0] == v)), None)
base = sys.argv[2] if len(sys.argv) > 2 else next((v for v in variants if v != direct), variants[0])
NAMES = {"no-gateway": "SGLang alone (no gateway)", "default-gateway": "Stock Dynamo", "optimized-gateway": "Optimized Dynamo"}
name = lambda v: NAMES.get(v, v)
order = [v for v in [direct, base] if v] + [v for v in variants if v not in (direct, base)]
def ms(us):                   # microseconds -> readable milliseconds
    if us is None: return "-"
    x = us / 1000
    return f"{x:.2f}" if x < 1 else f"{x:.1f}" if x < 10 else f"{x:,.0f}"
def pair(a, b, d=1): return "-" if a is None and b is None else f"{f(a, d)} / {f(b, d)}"
def table(c, rowdefs):        # one level: arms as columns, a row per measure (rows with no data are left out)
    arms = [v for v in order if (v, c) in rows]
    R = [rows[(v, c)] for v in arms]
    print("| | " + " | ".join(name(v) for v in arms) + " |")
    print("|---|" + "---|" * len(arms))
    for label, cell in rowdefs:
        cells = [cell(r) for r in R]
        if any(x.strip("-/; ") for x in cells):
            print(f"| {label} | " + " | ".join(cells) + " |")
    print()
def cpu_cell(r):
    lo, hi = r["cpu_s_per_1m_range"]
    return f'{f(r["cpu_s_per_1m"])} ({f(lo)}–{f(hi)})'
e2w = lambda r: "-" if r["e2w_p50_us"] is None else f'{ms(r["e2w_p50_us"])} / {ms(r["e2w_p99_us"])} / {ms(r["e2w_p999_us"])}'
comparisons = [v for v in order if v not in (base, direct)]

print(f"# Benchmark {os.path.basename(root)}\n")
if os.path.exists(f"{root}/UNTUNED"): print("**Benchmark mode was OFF for this run. Do not use these numbers.**\n")
for r in rows.values():
    if r["capture_dropped"]: print(f'**{name(r["variant"])}, {r["streams"]} streams: the capture dropped packets; its latency numbers are not valid.**\n')
    if r["errors"]: print(f'**{name(r["variant"])}, {r["streams"]} streams: {r["errors"]} request errors.**\n')

for v in comparisons:
    cmp = [(c, rows[(base, c)], rows[(v, c)]) for c in levels if (base, c) in rows and (v, c) in rows]
    if not cmp: continue
    print(f"## Result: {name(v)} against {name(base)}\n")
    print("| Streams | Tokens per gateway core-second | Client inter-token p99 (ms) | Emit→wire p99.9 (ms) |")
    print("|---|---|---|---|")
    for c, b, a in cmp:
        ratio = (a["tokens_per_core_s"] / b["tokens_per_core_s"]) if a["gateway"] and b["gateway"] and a["tokens_per_core_s"] and b["tokens_per_core_s"] else None
        print(f'| {c} | {f(b["tokens_per_core_s"], 0)} → {f(a["tokens_per_core_s"], 0)} (**{f(ratio, 2)}x**) '
              f'| {f(b["gap_p99_ms"])} → {f(a["gap_p99_ms"])} | {ms(b["e2w_p999_us"])} → {ms(a["e2w_p999_us"])} |')
    print()

print("## The brief's measures\n")
print("Gateway: the Dynamo frontend; for SGLang alone, its HTTP server process. Medians of the cpu windows (min–max in brackets).\n")
for c in levels:
    print(f"### {c} streams\n")
    table(c, [
        ("Gateway CPU-s per 1M tokens", cpu_cell),
        ("Tokens per gateway core-second", lambda r: f(r["tokens_per_core_s"], 0)),
        ("Syscalls per token", lambda r: f(r["syscalls_per_token"], 2)),
        ("Bytes on the wire per token", lambda r: f(r["wire_bytes_per_token"], 0)),
        ("Emit→wire p50 / p99 / p99.9 (ms)", e2w),
        ("Client inter-token p99 (ms)", lambda r: f(r["gap_p99_ms"])),
        ("Sustainable", lambda r: "yes" if r["sustainable"] else f'no ({r["limit"]})'),
        ("Flame graph", lambda r: f'[flame.svg]({r["flame"]})' if r["flame"] else "-"),
    ])
if len(levels) > 1:
    print("**Max sustainable streams:** " + "; ".join(
        f'{name(v)} {max([c for c in levels if (v, c) in rows and rows[(v, c)]["sustainable"]], default="none")}' for v in order) + ".\n")

print("## Details\n")
for c in levels:
    print(f"### {c} streams: other measurements\n")
    def added(r):
        ref = rows.get((direct, c), {}).get("serving_cpu_s_per_1m", {}).get("total") if direct else None
        t = r["serving_cpu_s_per_1m"]["total"]
        return "-" if not ref or not r["gateway"] or t is None else f'{t - ref:+,.1f} ({t / ref:.2f}x)'
    sv = lambda r, k: f(r["serving_cpu_s_per_1m"][k]) if (k != "frontend" or r["gateway"]) else "-"
    lat_n = max((rows[(v, c)]["latency_windows"] for v in order if (v, c) in rows), default=0)
    table(c, [
        ("Tokens/s", lambda r: f(r["tokens_per_s"], 0)),
        ("Tokens per event", lambda r: f(r["tokens_per_event"], 2)),
        ("Gateway CPU µs per event", lambda r: "-" if r["cpu_us_per_event"] is None else
            f'{f(r["cpu_us_per_event"])} ({f(r["cpu_us_per_event_range"][0])}–{f(r["cpu_us_per_event_range"][1])})'),
        ("Gateway cores busy", lambda r: f(r["fe_cores_busy"], 2) + (f' of {r["gateway_cores"]}' if r["gateway"] and r["gateway_cores"] else "")),
        ("Top syscalls per token", lambda r: r["syscalls_top"] or "-"),
        ("SSE body bytes per event", lambda r: f(r["payload_bytes_per_event"], 0)),
        ("Serving path CPU-s per 1M tokens: engine / worker main / frontend / total",
            lambda r: " / ".join(sv(r, k) for k in ("engine", "worker_main", "frontend", "total"))),
        ("Serving path added to SGLang alone", added),
        ("Client inter-token p50 (ms)", lambda r: f(r["gap_p50_ms"])),
        ("Time to first token p50 (ms)", lambda r: f(r["ttft_p50_ms"], 0)),
        (f"Step→handoff p50 / p99 (ms; median of {lat_n} latency windows)",
            lambda r: "-" if r["s2h_us"]["p50"] is None else f'{ms(r["s2h_us"]["p50"])} / {ms(r["s2h_us"]["p99"])}'),
        ("Handoff→wire p50 / p99 / p99.9 (ms)",
            lambda r: "-" if r["h2w_us"]["p50"] is None else f'{ms(r["h2w_us"]["p50"])} / {ms(r["h2w_us"]["p99"])} / {ms(r["h2w_us"]["p99.9"])}'),
        ("Tokens per event with timestamps on", lambda r: f(r["latency_tokens_per_event"], 2)),
        ("Stall episodes per window > 100 / > 250 ms; worst step (ms)", lambda r: "-" if r["stall_episodes_100ms"] is None else
            f'{f(r["stall_episodes_100ms"])} / {f(r["stall_episodes_250ms"])}; {f(r["stall_worst_ms"], 0)}'),
        ("Matched token timestamps", lambda r: "-" if r["stamped_tokens"] is None else f'{r["stamped_tokens"]:,}'),
        ("Engine cores busy", lambda r: f(r["engine_cores_busy"], 2)),
        ("Flags", lambda r: ", ".join(r["flags"]) or "-"),
    ])

if os.path.exists(f"{root}/config.txt"):
    print("## Run settings\n\n```\n" + open(f"{root}/config.txt").read().strip() + "\n```")
