"""Checks for the per-event, windowed and gate outputs of analyze.py, wire_latency.py and table.py."""
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
TICK = os.sysconf("SC_CLK_TCK")
R0 = 1_700_000_000_000_000_000            # realtime ns at the window start
OFFSET = R0 - 100 * 10**9                 # realtime - monotonic: the window is monotonic 100 s .. 110 s

MPSTAT = """Linux 6.8.0 (node) \t11/18/2026 \t_x86_64_\t(10 CPU)

Average:     CPU    %usr   %nice    %sys %iowait    %irq   %soft  %steal  %guest  %gnice   %idle
Average:     all   20.00    0.00    5.00    0.00    0.00    1.00    0.30    0.00    0.00   73.70
Average:       1   10.00    0.00    3.00    0.00    0.00    1.00    0.00    0.00    0.00   86.00
Average:       2   10.00    0.00    3.00    0.00    0.00    1.00    0.00    0.00    0.00   86.00
Average:       3   10.00    0.00    3.00    0.00    0.00    1.00    0.00    0.00    0.00   86.00
Average:       4   80.00    0.00   10.00    0.00    0.00    0.00    0.00    0.00    0.00   10.00
Average:       5   77.00    0.00   10.00    0.00    0.00    0.00    3.00    0.00    0.00   10.00
Average:       6   80.00    0.00   10.00    0.00    0.00    0.00    0.00    0.00    0.00   10.00
Average:       7   80.00    0.00   10.00    0.00    0.00    0.00    0.00    0.00    0.00   10.00
Average:       8   45.00    0.00    5.00    0.00    0.00    0.00    0.00    0.00    0.00   50.00
Average:       9    5.00    0.00    5.00    0.00    0.00    0.00    0.00    0.00    0.00   90.00
"""

WORKER_LOG = (
    "[2026-11-18 10:00:01] Decode batch, #running-req: 2048, #token: 900000, token usage: 0.50, "
    "cuda graph: False, gen throughput (token/s): 14300.00, #queue-req: 0, \n"
    "[2026-11-18 10:00:06] Decode batch, #running-req: 2040, #token: 900000, token usage: 0.51, "
    "cuda graph: False, gen throughput (token/s): 14100.00, #queue-req: 0, \n"
    "[2026-11-18 10:00:07] KV cache pool is full. Retract requests. #retracted_reqs: 1\n"
)


def write_run(d):
    """A CPU-mode run: 1000 tokens and 1 CPU-s in a 10 s window, two client requests."""
    (d / "snap_a.json").write_text(json.dumps(dict(t_ns=R0, frontend_ticks=0, worker_ticks=0, worker_main_ticks=0, tokens=0, inflight=4)))
    (d / "snap_b.json").write_text(json.dumps(dict(t_ns=R0 + 10 * 10**9, frontend_ticks=TICK, worker_ticks=4 * TICK, worker_main_ticks=TICK, tokens=1000, inflight=4)))
    (d / "clock.json").write_text(json.dumps({"realtime_minus_monotonic_ns": [OFFSET, OFFSET + 1000]}))
    (d / "mpstat.txt").write_text(MPSTAT)
    (d / "worker-window.log").write_text(WORKER_LOG)
    # Request 0 starts before the window: arrivals at 96.0, 96.5, ..., 111.0 (20 inside the window).
    # Request 1 starts inside the window: arrivals at 101.5, 101.75, ..., 106.5 (21 inside).
    client = dict(start_times=[95.0, 101.0], ttfts=[1.0, 0.5], itls=[[0.5] * 30, [0.25] * 20],
                  errors=["", ""], completed=2, output_lens=[31, 21])
    (d / "sglang-client.jsonl").write_text(json.dumps(client) + "\n")


def analyze(d, mode="cpu", variant="x"):
    return subprocess.run(
        [sys.executable, str(ROOT / "scripts/analyze.py"), str(d), "--concurrency", "4", "--mode", mode,
         "--engine", "sglang", "--variant", variant, "--frontend-cpus", "1-3", "--engine-cpus", "4-7",
         "--client-cpus", "8,9"], capture_output=True, text=True)


class AnalyzeTests(unittest.TestCase):
    def test_window_cut_per_event_and_flags(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            write_run(d)
            proc = analyze(d)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            s = json.loads((d / "summary.json").read_text())
            window = s["client"]["window"]
            self.assertEqual(window["content_events"], 41)
            self.assertEqual(window["requests_started"], 1)
            self.assertEqual(window["chunk_gap_ms"]["p50"], 500.0)      # 20 gaps of 250 ms, 20 of 500 ms
            self.assertEqual(s["serving_cpu_s_per_1m_tokens"], {"engine": 3000.0, "worker_main": 1000.0, "frontend": 1000.0, "total": 5000.0})
            self.assertAlmostEqual(s["tokens_per_event"], 1000 / 41, places=3)
            self.assertAlmostEqual(s["frontend_cpu_us_per_event"], 1e6 / 41, places=1)
            self.assertEqual(s["cpu_steal_pct"]["5"] if "5" in s["cpu_steal_pct"] else s["cpu_steal_pct"][5], 3.0)
            self.assertEqual(s["gates"]["engine_cpu_busy_mean_pct"], 90.0)
            self.assertEqual(s["gates"]["client_cpu_busy_max_pct"], 50.0)
            self.assertEqual(s["engine_log"]["running_req_min"], 2040)
            self.assertEqual(s["engine_log"]["cuda_graph_lines"], {"False": 2})
            self.assertEqual(s["engine_log"]["retraction_lines"], 1)
            self.assertEqual(set(s["flags"]), {"engine-cpu-saturated", "steal", "grouped-frames",
                                               "requests-started-in-window", "kv-retractions",
                                               "decode-without-cuda-graph"})



def pcap(segments):
    data = bytearray(struct.pack("<IHHIIII", 0xA1B23C4D, 2, 4, 0, 0, 65535, 1))
    for port, seq, ts, payload in segments:
        ip = bytearray(20); ip[0] = 0x45; struct.pack_into(">H", ip, 2, 40 + len(payload)); ip[9] = 6
        ip[12:20] = b"\x7f\0\0\x01" * 2
        tcp = bytearray(20); struct.pack_into(">HHI", tcp, 0, 8000, port, seq); tcp[12] = 0x50
        packet = b"\0" * 12 + b"\x08\x00" + ip + tcp + payload
        data += struct.pack("<IIII", ts // 10**9, ts % 10**9, len(packet), len(packet)) + packet
    return data


class WireTests(unittest.TestCase):
    def test_handoff_split(self):
        ms = 1_000_000
        segments, seq = [], 1000
        for i in range(10):
            step = R0 + i * 100 * ms
            handoff = step + 200 * ms                 # 200 ms in SGLang's output path and the relay
            event = f'data: {{"choices":[]}}\n: step={step},{step}\n: handoff={handoff}\n\n'.encode()
            segments.append((30001, seq, handoff + 2 * ms, event))     # 2 ms from handoff to the wire
            seq += len(event)
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "x.pcap").write_bytes(pcap(segments))
            (d / "err").write_text("0 packets dropped by kernel\n")
            proc = subprocess.run([sys.executable, str(ROOT / "scripts/wire_latency.py"), str(d / "x.pcap"),
                                   str(d / "err"), "--require-step-stamps"], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            s = json.loads(proc.stdout)
            self.assertEqual(s["stamped_tokens"], 20)
            self.assertEqual(s["handoff_stamped_events"], 10)
            self.assertEqual(s["handoff_to_wire_us"]["p50"], 2000.0)
            self.assertEqual(s["step_to_handoff_us"]["p99"], 200000.0)
            self.assertEqual(s["emit_to_wire_us"]["p50"], 202000.0)

    def test_unstamped_capture_sizes(self):
        # Syscalls windows: no timestamp comments, but bytes per event must still be reported.
        event = b'data: {"choices":[{"delta":{"content":"hi"}}]}\n\n'
        segments = [(30001, 1000 + i * len(event), R0 + i * 1_000_000, event) for i in range(50)]
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "x.pcap").write_bytes(pcap(segments))
            (d / "err").write_text("0 packets dropped by kernel\n")
            proc = subprocess.run([sys.executable, str(ROOT / "scripts/wire_latency.py"), str(d / "x.pcap"), str(d / "err")],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            s = json.loads(proc.stdout)
            self.assertEqual(s["data_events"], 50)
            self.assertEqual(s["stamped_events"], 0)
            self.assertEqual(s["payload_bytes_per_event"], float(len(event)))
            self.assertIsNone(s["tokens_per_event"])

    def test_grouping_and_stall_episodes(self):
        ms = 1_000_000
        steps = [R0 + i * 100 * ms for i in range(6)]
        # Step latency (slowest stream): 5, 150, 300, 5, 120, 5 ms -> two episodes over 100 ms, one over 250 ms.
        delay = [5, 150, 300, 5, 120, 5]
        segments = []
        for port in (30001, 30002):
            seq = 1000
            for i, step in enumerate(steps):
                # Stream 30001 carries two tokens of the step in one event (grouped frames).
                stamps = f"{step},{step}" if port == 30001 else f"{step}"
                event = f'data: {{"choices":[]}}\n: step={stamps}\n\n'.encode()
                wire = step + (delay[i] if port == 30001 else 1) * ms
                segments.append((port, seq, wire, event))
                seq += len(event)
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / "x.pcap").write_bytes(pcap(sorted(segments, key=lambda s: s[2])))
            (d / "err").write_text("0 packets dropped by kernel\n")
            proc = subprocess.run([sys.executable, str(ROOT / "scripts/wire_latency.py"), str(d / "x.pcap"),
                                   str(d / "err"), "--require-step-stamps"], capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            s = json.loads(proc.stdout)
            self.assertEqual(s["stamped_tokens"], 18)
            self.assertEqual(s["stamped_events"], 12)
            self.assertEqual(s["tokens_per_event"], 1.5)
            stalls = s["stall_episodes"]
            self.assertEqual(stalls["steps"], 6)
            self.assertEqual(stalls["over_100ms"]["episodes"], 2)
            self.assertEqual(stalls["over_100ms"]["slow_steps"], 3)
            self.assertEqual(stalls["over_100ms"]["worst_ms"], 300.0)
            self.assertEqual(stalls["over_100ms"]["longest_span_ms"], 100.0)
            self.assertEqual(stalls["over_250ms"]["episodes"], 1)


def summary(variant, cpu_s_per_1m, tokens_per_event=None, mode="cpu", wire=None):
    s = {"concurrency": 2048, "mode": mode, "engine": "sglang", "variant": variant, "gateway": True,
         "gateway_cores": 3, "tokens_per_s": 14000, "frontend_cpu_s_per_1m_tokens": cpu_s_per_1m,
         "tokens_per_frontend_core_s": round(1e6 / cpu_s_per_1m), "frontend_cores_busy": 0.4,
         "worker_cores_busy": 3.0, "client": {"chunk_gap_ms": {"p50": 140, "p99": 900}, "ttft_ms": {"p50": 2000}}}
    s["client"]["window"] = {"chunk_gap_ms": {"p50": 140, "p99": 300}}
    if tokens_per_event:
        s["tokens_per_event"] = tokens_per_event
        s["frontend_cpu_us_per_event"] = cpu_s_per_1m * tokens_per_event
        s["flags"] = ["grouped-frames"] if tokens_per_event > 1.2 else []
    if wire:
        s["wire"] = wire
    return s


class TableTests(unittest.TestCase):
    def build(self, runs):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, s in runs.items():
                (root / name).mkdir()
                (root / name / "summary.json").write_text(json.dumps(s))
            proc = subprocess.run([sys.executable, str(ROOT / "scripts/table.py"), str(root), "base"],
                                  capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            return proc.stdout, json.loads((root / "table.json").read_text())

    def test_per_event_ratio_window_gap_and_latency_detail(self):
        wire = lambda p999, episodes: {"emit_to_wire_us": {"p50": 1e6, "p99": 1.9e6, "p99.9": p999},
                                       "tokens_per_event": 3.0, "stall_episodes": {"over_100ms": {"episodes": episodes, "worst_ms": 2100.0},
                                                                                   "over_250ms": {"episodes": 1}}}
        text, rows = self.build({
            "a1": summary("base", 28.0, 2.2), "a2": summary("base", 28.0, 2.2),
            "b1": summary("cand", 25.0, 3.0), "b2": summary("cand", 25.0, 3.0),
            "al1": summary("base", 1.0, mode="latency", wire=wire(2.0e6, 3)),
            "al2": summary("base", 1.0, mode="latency", wire=wire(2.2e6, 5)),
        })
        base = next(r for r in rows if r["variant"] == "base")
        self.assertEqual(base["gap_p99_ms"], 300)
        self.assertEqual(base["latency_windows"], 2)
        self.assertEqual(base["e2w_p999_us"], 2.1e6)
        self.assertEqual(base["stall_episodes_100ms"], 4)
        self.assertIn("(**1.12x**)", text)                         # tokens per gateway core-second
        self.assertIn("| Gateway CPU µs per event | 61.6 (61.6–61.6) | 75.0 (75.0–75.0) |", text)   # per event worse
        self.assertIn("Stall episodes per window", text)



if __name__ == "__main__":
    unittest.main()
