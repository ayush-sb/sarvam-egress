"""Emit-to-wire latency and bytes on the wire, from a loopback capture of the responses to the client.

  wire_latency.py CAPTURE.pcap [TCPDUMP_STDERR] [--require-step-stamps] [--window SNAP_A SNAP_B] -> JSON

In latency windows each SSE event carries SGLang's scheduler step timestamps (": step=<ns>,...") and
the time Dynamo's Python worker handed the frame to its Rust sender (": handoff=<ns>"). Step to wire is
the whole path; handoff to wire leaves out SGLang's output path and the Python relay, so it is the
frontend's share (plus the worker's Rust send and the hop to the frontend).
The packet that carries the last byte of an event gives its wire time
(tcpdump's timestamp). Per connection the TCP payload is put in sequence order first, so an event split
over two packets is timed by the second, and several events in one packet are each counted. Without
timestamps (syscalls windows) only the byte and event counts are reported.
"""
import argparse, bisect, collections, json, re, struct

STEP_EVENT = re.compile(rb"data: \{[^\n]*\n: step=([0-9,]+)\n(?::[^\n]*\n)*\n")
DATA = re.compile(rb"data: [{\[]")
HANDOFF = re.compile(rb"\n: handoff=([0-9]+)\n")

def tcp_segments(path):
    with open(path, "rb") as f:
        magic = f.read(4)
        if magic == b"\x4d\x3c\xb2\xa1": scale = 1            # nanosecond pcap, little endian
        elif magic == b"\xd4\xc3\xb2\xa1": scale = 1000       # microsecond pcap
        else: raise SystemExit(f"unsupported pcap magic {magic.hex()}")
        f.read(16); linktype = struct.unpack("<I", f.read(4))[0]
        if linktype != 1: raise SystemExit(f"unsupported link type {linktype}")
        hdr = struct.Struct("<IIII")
        while True:
            h = f.read(16)
            if len(h) < 16: return
            sec, frac, caplen, origlen = hdr.unpack(h)
            buf = f.read(caplen)
            if caplen < origlen or len(buf) != caplen:
                raise SystemExit("truncated packet: capture with -s 0")
            if buf[12:14] != b"\x08\x00" or buf[23] != 6: continue       # IPv4 + TCP only
            ihl = (buf[14] & 15) * 4
            tot = struct.unpack_from(">H", buf, 16)[0]
            t = 14 + ihl
            sport, dport, seq = struct.unpack_from(">HHI", buf, t)
            off = (buf[t + 12] >> 4) * 4
            payload = buf[t + off:14 + tot]
            yield (buf[26:34], sport, dport), sec * 1_000_000_000 + frac * scale, seq, payload, origlen, buf[t + 13]


def packets(path):
    for key, stamp, seq, payload, length, _ in tcp_segments(path):
        if payload:
            yield key, stamp, seq, payload, length

def pct(v, p): return v[min(len(v) - 1, int(p * len(v)))]

STALL_THRESHOLDS_MS = (100, 250)

def stall_episodes(rows):
    """Count stall episodes in a step-stamped capture.

    A tail percentile over all tokens hides how many separate events made it: one stall delays
    every stream at once. A step is slow when its slowest token took longer than the threshold
    from emit to wire. An episode is a run of consecutive slow steps, in emit order. The number of
    episodes is the real sample size behind the p99.9 of one window.
    """
    worst = collections.defaultdict(int)          # emit stamp -> slowest emit->wire of that step
    for row in rows:
        worst[row["emit_ns"]] = max(worst[row["emit_ns"]], row["wire_ns"] - row["emit_ns"])
    steps = sorted(worst.items())
    result = {"steps": len(steps)}
    for threshold_ms in STALL_THRESHOLDS_MS:
        limit = threshold_ms * 1_000_000
        episodes = []                             # [first emit, last emit, worst latency, steps]
        previous_slow = False
        for emit_ns, latency in steps:
            slow = latency > limit
            if slow and previous_slow:
                episode = episodes[-1]
                episode[1] = emit_ns; episode[2] = max(episode[2], latency); episode[3] += 1
            elif slow:
                episodes.append([emit_ns, emit_ns, latency, 1])
            previous_slow = slow
        result[f"over_{threshold_ms}ms"] = {
            "episodes": len(episodes),
            "slow_steps": sum(e[3] for e in episodes),
            "worst_ms": round(max(e[2] for e in episodes) / 1e6, 1) if episodes else None,
            "longest_span_ms": round(max(e[1] - e[0] for e in episodes) / 1e6, 1) if episodes else None,
        }
    return result

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pcap")
    parser.add_argument("tcpdump_stderr", nargs="?")
    parser.add_argument("--require-step-stamps", action="store_true")
    parser.add_argument("--window", nargs=2, metavar=("SNAP_A", "SNAP_B"))
    parser.add_argument("--events-out", help="Save the matched token timestamps as JSONL")
    args = parser.parse_args()
    require_steps = args.require_step_stamps
    if args.window:
        edges = []
        for path in args.window:
            with open(path) as snap:
                edges.append(json.load(snap)["t_ns"])
        start_ns, end_ns = edges
        if end_ns <= start_ns:
            raise SystemExit("packet capture window must have a positive length")
    flows = collections.defaultdict(list)
    n_pkts = wire_bytes = payload_bytes = 0
    capture_first = capture_last = None
    t_first = t_last = None
    for key, ts, seq, payload, origlen in packets(args.pcap):
        if args.window:
            capture_first = ts if capture_first is None else min(capture_first, ts)
            capture_last = ts if capture_last is None else max(capture_last, ts)
            if not start_ns <= ts < end_ns:
                continue
        flows[key].append((seq, ts, payload))
        n_pkts += 1; wire_bytes += origlen; payload_bytes += len(payload)
        t_first = t_first or ts; t_last = ts
    if args.window and (capture_first is None or capture_first > start_ns or capture_last < end_ns):
        raise SystemExit("packet capture does not cover the complete token-count window")
    lat = []; per_pkt = collections.Counter(); data_events = gaps = retrans = duplicates = 0
    sse_events = 0      # stamped SSE events; with step stamps one event can carry several tokens
    event_rows = []
    handoff_lat = []; relay_lat = []    # handoff -> wire per event; step -> handoff per token
    for flow_id, segs in enumerate(flows.values()):
        step_tokens = {}
        handoffs = {}                   # handoff stamp -> (wire time, step stamps of that frame)
        step_handoff = {}               # step stamp -> handoff stamp, for the saved rows
        base = segs[0][0]
        segs = sorted(((s - base) & 0xFFFFFFFF, ts, p) for s, ts, p in segs)
        runs, cur, nxt = [], None, None                 # contiguous byte runs
        last_segment = None
        for rel, ts, p in segs:
            if nxt is not None and rel < nxt:
                retrans += 1
                # Identical bytes at the same sequence number preserve the
                # timestamp of the first observed segment.
                if last_segment == (rel, p):
                    duplicates += 1
                continue
            if rel != nxt:
                if nxt is not None: gaps += 1
                cur = ([], [], []); runs.append(cur)    # chunks, end offsets, times
            cur[0].append(p); cur[1].append((cur[1][-1] if cur[1] else 0) + len(p)); cur[2].append(ts)
            nxt = rel + len(p)
            last_segment = (rel, p)
        for chunks, ends, times in runs:
            buf = b"".join(chunks)
            data_events += len(DATA.findall(buf))
            hits = collections.Counter()
            for m in STEP_EVENT.finditer(buf):
                i = bisect.bisect_left(ends, m.end())   # packet that holds the event's last byte
                hits[i] += 1
                sse_events += 1
                # Reasoning and content can split one source chunk. Use the
                # last wire boundary carrying a stamp and count it once.
                for emit_ns, count in collections.Counter(map(int, m.group(1).split(b","))).items():
                    previous, previous_count = step_tokens.get(emit_ns, (0, 0))
                    step_tokens[emit_ns] = max(previous, times[i]), max(previous_count, count)
                h = HANDOFF.search(m.group(0))
                if h:   # a frame split over two events keeps its last wire time, once
                    handoff_ns = int(h.group(1))
                    handoffs[handoff_ns] = (max(handoffs.get(handoff_ns, (0,))[0], times[i]), m.group(1))
                    for emit_ns in map(int, m.group(1).split(b",")):
                        step_handoff[emit_ns] = handoff_ns
            per_pkt.update(hits.values())
        for emit_ns, (wire_ns, count) in step_tokens.items():
            lat.extend([wire_ns - emit_ns] * count)
            event_rows.append(dict(flow=flow_id, emit_ns=emit_ns, wire_ns=wire_ns, tokens=count)
                              | ({"handoff_ns": step_handoff[emit_ns]} if emit_ns in step_handoff else {}))
        for handoff_ns, (wire_ns, steps) in handoffs.items():
            handoff_lat.append(wire_ns - handoff_ns)
            relay_lat.extend(handoff_ns - int(x) for x in steps.split(b","))
    lat.sort(); handoff_lat.sort(); relay_lat.sort()
    dropped = None
    if args.tcpdump_stderr:
        with open(args.tcpdump_stderr) as stderr:
            m = re.search(r"(\d+) packets dropped by kernel", stderr.read())
            dropped = int(m.group(1)) if m else None
    us = lambda ns: round(ns / 1000, 1)
    # Per-event sizes divide by SSE events: the stamped ones in latency windows, all data events in an
    # unstamped capture (syscalls windows, whose events carry no timestamp comments).
    n_events = sse_events or data_events
    out = {
        "capture_s": round((t_last - t_first) / 1e9, 2) if n_pkts else 0,
        "connections": len(flows), "packets": n_pkts,
        "dropped_by_kernel": dropped, "sequence_gaps": gaps, "retransmits": retrans,
        "duplicate_segments": duplicates, "ambiguous_overlaps": retrans - duplicates,
        "data_events": data_events, "stamped_events": sse_events,
        "stamped_tokens": len(lat),
        "tokens_per_event": round(len(lat) / sse_events, 3) if sse_events else None,
        "egress_clock": "pcap-realtime",
        "captured_bytes": wire_bytes,
        "negative_latencies": sum(1 for x in lat if x < 0),
        "packets_per_event": round(n_pkts / n_events, 3) if n_events else None,
        "payload_bytes_per_event": round(payload_bytes / n_events, 1) if n_events else None,
        "wire_bytes_per_event": round(wire_bytes / n_events, 1) if n_events else None,
        "events_per_packet": {str(k): v for k, v in sorted(per_pkt.items())[:8]},
        "emit_to_wire_us": {k: us(pct(lat, p)) for k, p in
                            (("p50", .5), ("p90", .9), ("p99", .99), ("p99.9", .999))} | {"min": us(lat[0]), "max": us(lat[-1])} if lat else None,
    }
    spread = lambda xs: {k: us(pct(xs, q)) for k, q in (("p50", .5), ("p90", .9), ("p99", .99), ("p99.9", .999))} \
        | {"min": us(xs[0]), "max": us(xs[-1])} if xs else None
    out["handoff_stamped_events"] = len(handoff_lat)
    out["handoff_to_wire_us"] = spread(handoff_lat)          # per event: frontend's share
    out["step_to_handoff_us"] = spread(relay_lat)            # per token: SGLang output path + Python relay
    out["stall_episodes"] = stall_episodes(event_rows) if event_rows else None
    if args.events_out:
        with open(args.events_out, "w") as output:
            for row in event_rows:
                output.write(json.dumps(row) + "\n")
    print(json.dumps(out, indent=2))
    if require_steps and (not lat or dropped != 0 or gaps or retrans != duplicates or out["negative_latencies"]):
        raise SystemExit("unusable tcpdump capture: check scheduler stamps, packet loss, overlaps and clock")

if __name__ == "__main__":
    main()
