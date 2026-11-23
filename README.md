# Egress at Line Rate

This repository measures the per-token CPU cost of the NVIDIA Dynamo 1.6.2 frontend (the gateway between SGLang and
the client) and holds a set of Dynamo changes that cut that cost. A benchmark compares three arms under the same load:
SGLang's own HTTP server (no gateway), stock Dynamo and the optimized Dynamo frontend.

## Requirements

- One NVIDIA Blackwell GPU (tested on an RTX PRO 6000 Blackwell, 96 GB). The default model uses FP8 weights with an
  NVFP4 KV cache, which needs Blackwell.
- Ubuntu 24.04, sudo, and about 150 GB of free disk.
- At least 9 physical CPU cores on one NUMA node (tested on 32 vCPUs).

## Set up and run

```
git clone --recurse-submodules https://github.com/ayush-sb/sarvam-egress.git && cd sarvam-egress
./setup.sh                      # 5-10 min: downloads the published builds and the model
sudo ./bench-mode.sh on         # keeps other work off the measured cores
./bench.sh --quick --rounds 3   # 2048 streams, about 1 h
sudo ./bench-mode.sh off        # when finished (a reboot also does this)
```

| Command | What it runs |
|---|---|
| `./bench.sh --quick --rounds 3` | 2048 streams, three CPU windows per arm (recommended) |
| `./bench.sh --rounds 3` | 256, 512, 1024 and 2048 streams, three CPU windows per arm (about 2.5 h) |
| `./bench.sh --levels "512 2048"` | Other levels (2048 is required) |
| `./bench.sh --resume results/bench-<time>` | Continue a stopped run |
| `./setup.sh --from-source` | Build both Dynamo libraries on this machine, with PGO training (about 45 min) |

Each run writes `results/bench-<time>/table.md`. It has every measure per level and arm, links to one flame graph
per arm and level, and the run settings. Setup output goes to `build/setup.log`.

## Cores

`setup.sh` writes `config/cpus.local.sh` for the machine (`scripts/detect-cpus.py`). The default layout uses one NUMA
node: frontend 3 cores, SGLang worker 4 cores, benchmark client 2 cores, and all other CPUs for the system. The SMT
siblings of the frontend and worker cores go offline in benchmark mode.

To change the layout, write the file again and restart benchmark mode:

```
sudo ./bench-mode.sh off
scripts/detect-cpus.py --frontend 2 --worker 4 --client 2
sudo ./bench-mode.sh on
```

Benchmark mode reads the same file, so change the layout this way and not with environment variables. Stock Dynamo
starts one Tokio worker per allowed core, so the number of frontend cores also sets the number of Tokio workers for
stock.

## Method

- The two Dynamo arms share one SGLang worker and alternate in 20 s windows at a steady load.
- CPU windows run without a profiler or a capture. Flame graphs, syscall counts and latency come from separate
  windows.
- The token rates of a stock and optimized pair must match within 5% (10% in instrumented windows). A rejected window
  or pair is measured again, up to three times.
- CPU results are medians of the CPU windows.
- Gateway CPU is the user and system time of the frontend process (for SGLang alone, its HTTP server). Client p99 is
  the gap between SSE events. Emit-to-wire runs from the engine step of a token to the tcpdump capture of its SSE
  event.

## The optimized frontend

- `patches/optimized/`: the Dynamo changes, applied in the order of `series` to the pinned Dynamo commit
  (`dynamo/`, v1.6.2).
- `config/optimized.env`: the settings for the optimized arm. Each line has a comment. Remove a line to turn that
  setting off. The settings take effect when the frontend restarts.
- Field boxing and the ThinLTO + PGO build are part of the optimized library. The stock library has neither.
- `patches/instrumentation/`: timestamps for the latency measurements, in Dynamo's SGLang worker and in SGLang's output
  streamer (the engine step). They are active only in latency windows.

## Build from source

`./setup.sh` downloads the published builds. `./setup.sh --from-source` builds both Dynamo libraries on the machine
instead (about 45 min on the cloud machine). It needs the GPU, because PGO training serves the model. The steps:

1. `scripts/build-dynamo.sh vanilla`: stock Dynamo 1.6.2 at the pinned commit, with Dynamo's own build settings.
2. `scripts/build-dynamo.sh train`: the optimized source (`patches/optimized/` in `series` order) with ThinLTO,
   instrumented for PGO.
3. `scripts/train-pgo.sh`: SGLang serves the model, the instrumented frontend runs with `config/optimized.env`, and
   SGLang's benchmark client sends 512 and then 2048 streams. The profiles merge into `build/pgo/merged.profdata`.
4. `scripts/build-dynamo.sh optimized`: the optimized library, with ThinLTO and PGO.
5. `scripts/stage-builds.sh`: lays out `build/` for the benchmark and checks that both libraries import.

Each library builds in a git worktree of `dynamo/` under `build/src/`, so `dynamo/` itself does not change. Compiler
output goes to `build/build-<variant>.log`. `build/provenance.txt` says whether the libraries were downloaded or built.

After a change to `patches/optimized/`, delete `build/src/optimized` and `build/pgo`, then run
`./setup.sh --from-source` again. The patches go on again, and a new PGO profile is trained for the new code.

## Layout

| Path | Contents |
|---|---|
| `setup.sh`, `bench.sh`, `bench-mode.sh` | Setup, the benchmark and benchmark mode |
| `scripts/` | The sweep, measurement, checks, analysis, build and PGO training |
| `config/` | Model, release, optimized preset, pinned SGLang packages and the prompt set |
| `patches/` | Dynamo changes and instrumentation |
| `tests/` | Tests for the checks and the analysis |
