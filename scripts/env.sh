# Shared settings for the scripts. Source it, do not run it.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Which cores each process gets. setup.sh writes config/cpus.local.sh for this machine
# (scripts/detect-cpus.py); the defaults below are for the development laptop.
[ -f "$ROOT/config/cpus.local.sh" ] && source "$ROOT/config/cpus.local.sh"
export HOUSEKEEPING_CPUS=${HOUSEKEEPING_CPUS:-0,6}   # the OS and everything not under test
export FRONTEND_CPUS=${FRONTEND_CPUS:-1,2,3}         # the Dynamo frontend
export WORKER_CPUS=${WORKER_CPUS:-4}                 # the SGLang worker
export CLIENT_CPUS=${CLIENT_CPUS:-5,11}              # the benchmark client
export OFFLINE_CPUS=${OFFLINE_CPUS-7 8 9 10}         # SMT siblings of the frontend and worker cores

export DYN_PY="$ROOT/.venv/bin/python"
export HTTP_PORT=${HTTP_PORT:-8000}
export RUN_DIR=${RUN_DIR:-$ROOT/results/service}     # logs and pid files of the running services
# No etcd or NATS: Dynamo uses file-based discovery and TCP request and response planes.
export DYN_DISCOVERY_BACKEND=file DYN_FILE_KV="$RUN_DIR/discovery" DYN_REQUEST_PLANE=tcp DYN_RESPONSE_PLANE=tcp
# Not as root: sudo ./bench-mode.sh sources this file, and a root-owned results/ would lock out the benchmark.
[ "$(id -u)" -eq 0 ] || mkdir -p "$RUN_DIR"
