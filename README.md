# Egress at Line Rate: mock mode

This branch runs the frontend benchmark without a GPU. It compares stock Dynamo 1.6.2 with the optimized Dynamo
frontend in front of Dynamo's mock engine. The `main` branch has the GPU benchmark with real SGLang.

## What mock mode is

- **The engine is Dynamo's own mock engine** (`dynamo.mocker`), not a GPU and not SGLang. It is part of Dynamo and is
  written in Rust. There is no Python layer between the engine and the frontend: frames go from the mock engine's
  Rust code to the frontend over Dynamo's TCP response plane.
- **Fixed timing** (`config/mocker-fixed.json`): every stream gets one token every 50 ms, one token per SSE event.
  At 2048 streams that is about 41000 events per second, so the frontend is busy. The engine needs one core.
- **The client is a custom load generator** (`loadgen/`, Rust). It holds N streams open on keep-alive HTTP/1.1
  connections, records the arrival time of every SSE event, and does no tokenization or JSON parsing, so its own
  CPU cost stays small. Each request asks for 1024 ± 300 tokens with `ignore_eos`.
- **The model** is only a name and a tokenizer (Qwen/Qwen3-0.6B). No weights are loaded.

Mock mode measures the frontend when it is busy. On a single GPU with real SGLang, the frontend gets about 9000
events per second and is mostly idle, so the results differ (see the report).

## Requirements

- Linux x86-64 with at least 6 physical cores on one NUMA node (tested on an i7-9750H laptop). No GPU.
- Ubuntu 24.04, sudo, and about 20 GB of free disk.

## Set up and run

```
git clone --recurse-submodules -b mock-mode https://github.com/ayush-sb/sarvam-egress.git && cd sarvam-egress
./setup.sh --mock                      # about 5 min: published builds, tokenizer, load generator
sudo ./bench-mode.sh on                # keeps other work off the measured cores
./bench.sh --mock --quick --rounds 3   # 2048 streams, three CPU windows per arm
./bench.sh --mock --rounds 3           # 256, 512, 1024 and 2048 streams
sudo ./bench-mode.sh off               # when finished (a reboot also does this)
```

`./bench.sh --mock --resume results/bench-<time>` continues a stopped run. Each run writes
`results/bench-<time>/table.md`.

## Cores

`setup.sh --mock` writes `config/cpus.local.sh`: frontend 3 cores, mock engine 1 core, load generator 2 cores (1 on a
6-core machine; it may use both SMT threads), and the rest for the system. To change it:

```
sudo ./bench-mode.sh off
scripts/detect-cpus.py --frontend 3 --worker 1 --client 2
sudo ./bench-mode.sh on
```

Stock Dynamo starts one Tokio worker per allowed core, so it runs three on three frontend cores.

## What it measures

- Two arms, stock and optimized, share one mock engine and alternate in 20 s windows.
- CPU windows run without a profiler or a capture. A flame graph and the syscall counts come from separate windows.
- The token rates of a pair must match within 5% (10% in instrumented windows). A rejected window or pair is
  measured again, up to three times. CPU results are medians of the CPU windows.
- Gateway CPU is the user and system time of the frontend process. Client p99 is the gap between consecutive SSE
  events of a stream, from the load generator's arrival times.
- Not measured in mock mode: emit-to-wire latency (the mock engine has no emit timestamps), and SGLang alone (the
  mock engine has no HTTP server of its own).

## The optimized frontend

The optimized arm uses the patches in `patches/optimized/` and the settings in `config/optimized.env`, with one
change: mock mode runs it with two Tokio workers (`OPTIMIZED_WORKER_THREADS` in `config/mock.env`). The cloud preset
uses one worker at about 9000 events per second. At 41000 events per second, one worker raises client p99.

The published optimized build was trained (PGO) on SGLang traffic on the cloud machine. A build trained on mock
traffic gives somewhat different numbers.
