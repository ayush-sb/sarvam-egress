#!/usr/bin/env python3
"""Write config/cpus.local.sh for this machine's CPU topology.

  scripts/detect-cpus.py [--frontend 3] [--worker 4] [--client 2] [--node 0] [--print]

Layout, all on one NUMA node so the measured processes share one memory domain:
  housekeeping  first physical core (all its threads) plus every CPU not used below
  frontend      next N cores, one thread each     (their SMT siblings go offline)
  worker        next N cores, one thread each     (their SMT siblings go offline)
  client        next N cores, all threads         (the benchmark client may use both threads)
"""
import argparse, collections, os, subprocess, sys

ap = argparse.ArgumentParser()
ap.add_argument("--frontend", type=int, default=3); ap.add_argument("--worker", type=int, default=4)
ap.add_argument("--client", type=int, default=2); ap.add_argument("--node", type=int, default=0)
ap.add_argument("--print", action="store_true")
a = ap.parse_args()

cores = collections.OrderedDict()            # (socket, core) -> [cpu, ...], for the chosen node
everything = []
for line in subprocess.run(["lscpu", "-p=CPU,CORE,SOCKET,NODE"], capture_output=True, text=True, check=True).stdout.splitlines():
    if line.startswith("#"): continue
    cpu, core, sock, node = (int(x) if x else 0 for x in line.split(","))
    everything.append(cpu)
    if node == a.node: cores.setdefault((sock, core), []).append(cpu)
phys = list(cores.values())
need = 1 + a.frontend + a.worker + a.client
if len(phys) < need:
    need_min = 1 + a.frontend + a.worker + 1
    if len(phys) < need_min:
        sys.exit(f"node {a.node} has {len(phys)} physical cores; the layout needs at least {need_min} "
                 f"(1 housekeeping + {a.frontend} frontend + {a.worker} worker + 1 client). Lower --frontend or --worker.")
    a.client = len(phys) - 1 - a.frontend - a.worker
i = 1
gw = phys[i:i + a.frontend]; i += a.frontend
en = phys[i:i + a.worker]; i += a.worker
cl = phys[i:i + a.client]
frontend = [c[0] for c in gw]; worker = [c[0] for c in en]
client = [x for c in cl for x in c]
offline = [x for c in gw + en for x in c[1:]]
used = set(frontend + worker + client + offline)
house = [c for c in everything if c not in used]
j = lambda v: ",".join(map(str, sorted(v)))
text = f"""# Written by scripts/detect-cpus.py for {os.uname().nodename}: {len(everything)} CPUs, {len(phys)} physical cores on NUMA node {a.node}.
export HOUSEKEEPING_CPUS="${{HOUSEKEEPING_CPUS:-{j(house)}}}"
export FRONTEND_CPUS="${{FRONTEND_CPUS:-{j(frontend)}}}"
export WORKER_CPUS="${{WORKER_CPUS:-{j(worker)}}}"
export CLIENT_CPUS="${{CLIENT_CPUS:-{j(client)}}}"
export OFFLINE_CPUS="${{OFFLINE_CPUS:-{' '.join(map(str, sorted(offline)))}}}"
"""
if a.print: print(text, end="")
else:
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config", "cpus.local.sh")
    os.makedirs(os.path.dirname(path), exist_ok=True); open(path, "w").write(text)
    print(f"wrote {os.path.normpath(path)}:\n{text}", end="")
