import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location(
    "checks", Path(__file__).resolve().parents[1] / "scripts/checks.py"
)
cloud = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cloud)


class CloudWindow(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.summary = {
            "tokens_per_s": 16000, "tokens_in_window": 160000, "window_s": 10,
            "tokens_per_event": 1, "content_events_in_window": 160000,
            "client": {"errors_or_incomplete": 0, "requests": 4096, "window": {
                "chunk_gap_ms": {"p99": 140}, "clock_offset_drift_ns": 200,
            }},
            "gates": {"client_cpu_busy_max_pct": 42, "engine_cpu_busy_mean_pct": 61, "steal_max_pct": 0},
            "engine_log": {"decode_log_lines": 7, "running_req_min": 2048, "cuda_graph_lines": {"True": 7}},
        }
        self.points = [dict(t_ns=i * 10**9, tokens=i * 16000, inflight=2048) for i in range(0, 11, 2)]
        (self.path / "expected-prompts.txt").write_text("4096\n")
        (self.path / "worker-id.txt").write_text("584 111\n")
        (self.path / "worker-after-launch.log").write_text("Decode batch, token usage: 0.81\n")
        self.pidstat("client", 42)
        self.pidstat("worker", 65)

    def pidstat(self, name, cpu):
        (self.path / f"pidstat_{name}.txt").write_text(
            f"Average:  1000  584  -  33.00   0.00   0.00   0.00   {cpu:.2f}     -   python\n"
            f"Average:  1000  -  584   33.00   0.00   0.00   0.00   {cpu:.2f}     -   |__python\n"
        )

    def check(self, mode="cpu"):
        for name, content in (("snap_a", self.points[0]), ("snap_b", self.points[-1]), ("summary", self.summary)):
            (self.path / f"{name}.json").write_text(json.dumps(content))
        with (self.path / "load-samples.jsonl").open("w") as stream:
            for point in self.points[1:-1]:
                stream.write(json.dumps(point) + "\n")
        return cloud.window(self.path, 2048, mode, 10)

    def test_valid_steady_window(self):
        self.assertEqual(self.check()["errors"], [])

    def test_first_rental_pattern_fails_even_with_good_token_rate(self):
        self.summary["tokens_per_event"] = 4.1
        self.summary["content_events_in_window"] = 39024
        self.pidstat("worker", 97)
        gate = self.check()
        # Worker grouping on a gateway arm is reported; the saturated relay still rejects the window.
        self.assertTrue(any("tokens per client event" in msg for msg in gate["warnings"]))
        self.assertIn("engine or relay host CPU is saturated", gate["errors"])

    def test_busy_scheduler_does_not_hide_real_relay_headroom(self):
        with (self.path / "pidstat_worker.txt").open("a") as stream:
            stream.write("Average: 1000 665 - 99 1 0 0 100 - sglang::schedul\n")
            stream.write("Average: 1000 - 665 99 1 0 0 100 - |__sglang::schedul\n")
        gate = self.check()
        self.assertEqual(gate["errors"], [])
        self.assertEqual(gate["relay_or_direct_server_thread_peak_pct"], 65)
        self.assertEqual(gate["engine_thread_peak_pct"], 100)

    def test_two_healthy_endpoints_can_hide_a_mid_window_load_drop(self):
        self.points[3]["inflight"] = 1638
        self.points[3]["tokens"] -= 26000
        errors = self.check()["errors"]
        self.assertTrue(any("active requests" in msg for msg in errors))
        self.assertTrue(any("decode delivery stalled" in msg for msg in errors))

    def test_late_retraction_is_rejected(self):
        (self.path / "worker-after-launch.log").write_text("KV cache pool is full. Retract requests.\n")
        self.assertTrue(any("including during drain" in msg for msg in self.check()["errors"]))

    def test_positive_but_incomplete_capture_is_rejected(self):
        self.summary["wire"] = dict(stamped_tokens=1000, dropped_by_kernel=0, sequence_gaps=0,
                                    ambiguous_overlaps=0, negative_latencies=0,
                                    emit_to_wire_us={"p99.9": 20_000})
        self.assertTrue(any("stamp coverage" in msg for msg in self.check("latency")["errors"]))

    def test_saturated_client_rejects_the_window(self):
        self.pidstat("client", 93)
        self.assertIn("client CPU is saturated", self.check()["errors"])

    def test_relays_must_keep_up_with_direct_and_match_between_arms(self):
        direct = {"tokens_per_s": 15500, "client_events_per_s": 15500, "tokens_per_event": 1}
        slow_relay = {"tokens_per_s": 15100, "client_events_per_s": 5400, "tokens_per_event": 2.8}
        problems, notes = cloud.compare(direct, slow_relay, True)
        self.assertEqual(problems, [])
        self.assertTrue(any("routed client_events_per_s" in msg for msg in notes))
        slow_tokens = slow_relay | {"tokens_per_s": 12000}
        self.assertTrue(any("routed tokens_per_s" in msg for msg in cloud.compare(direct, slow_tokens, True)[0]))
        same_grouping = direct | {"client_events_per_s": 14500}
        self.assertEqual(cloud.compare(direct, same_grouping, True), ([], []))
        # Between gateway arms, events may differ by up to 10% and tokens by up to 5%.
        self.assertEqual(cloud.compare(direct, same_grouping, False)[0], [])
        uneven = cloud.compare(direct, direct | {"client_events_per_s": 13000, "tokens_per_event": 1.2}, False)
        self.assertEqual(uneven[0], [])
        self.assertTrue(any("client_events_per_s" in msg for msg in uneven[1]))
        self.assertTrue(cloud.compare(direct, direct | {"tokens_per_s": 14500}, False)[0])

    def test_saturated_direct_server_is_a_finding_not_a_rejection(self):
        self.summary["engine"] = "sglang-direct"
        self.pidstat("worker", 99)
        gate = self.check()
        self.assertEqual(gate["errors"], [])
        self.assertTrue(any("no-gateway path is at its CPU limit" in msg for msg in gate["warnings"]))
        # A lagging direct server still fails on delivery.
        self.summary["tokens_per_event"] = 1.6
        self.assertTrue(any("tokens per client event" in msg for msg in self.check()["errors"]))

    def test_saturated_gateway_relay_is_still_rejected(self):
        self.summary["engine"] = "sglang"
        self.pidstat("worker", 99)
        self.assertIn("engine or relay host CPU is saturated", self.check()["errors"])

    def test_direct_sampler_only_uses_unified_decode_tokens(self):
        data = '\n'.join((
            'sglang:realtime_tokens_total{mode="decode",engine_type="unified"} 125000',
            'sglang:realtime_tokens_total{engine_type="unified",mode="prefill"} 70000',
            'sglang:num_running_reqs{engine_type="unified"} 2048',
        ))
        self.assertEqual(cloud.metrics(data, "sglang-direct"), {"tokens": 125000, "inflight": 2048})
