# shellcheck shell=bash
# Shared helpers, sourced by the numbered scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config.env; values already set in the environment win.
while IFS='=' read -r key value; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  # shellcheck disable=SC2163  # exporting the variable named by $key is intended
  if [[ -z "${!key+x}" ]]; then export "$key=$value"; else export "$key"; fi
done < "$ROOT/config.env"

# Everything the scripts write stays inside the clone (rm -rf of it leaves no residue):
# pinned tools first in PATH, repo-local kubeconfig and helm state.
export PATH="$ROOT/.bin:$PATH"
export KUBECONFIG="$ROOT/kubeconfig"
export HELM_CACHE_HOME="$ROOT/.helm/cache" HELM_CONFIG_HOME="$ROOT/.helm/config" HELM_DATA_HOME="$ROOT/.helm/data"

# MODEL_CACHE_DIR may be relative to the repo; this is its absolute path.
MODEL_CACHE_PATH="$(cd "$ROOT" && realpath -m "$MODEL_CACHE_DIR")"
# vLLM runs as the host user, so everything it writes into the cache stays removable
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
export MODEL_CACHE_PATH HOST_UID HOST_GID

# Only ${VAR} of these names is substituted; any other "$" in the manifests stays as is.
SUBST_VARS='NAMESPACE MODEL_ID VLLM_IMAGE GPU_MEM_UTIL MAX_MODEL_LEN MODEL_MAX_REPLICAS APP1_IMAGE APP1_HOST CUDA_SAMPLE_IMAGE GPU_RUNTIME_CLASS CLUSTER_NAME HOST_UID HOST_GID'

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

# host prerequisites only (docker, curl, nvidia-ctk); nothing is ever installed on the host
need() { command -v "$1" >/dev/null || die "missing command: $1 ${2:-}"; }
# tools downloaded by 15-install-tools.sh: only the copy in ./.bin counts, never a host one
need_bin() { [[ -x "$ROOT/.bin/$1" ]] || die "missing $ROOT/.bin/$1 (run ./15-install-tools.sh)"; }

# Pure bash instead of envsubst (no host package). Quoted pattern and replacement: literal,
# so values containing "&", "*" or "\" are inserted unchanged.
render() {
  local text var
  text="$(<"$1")"
  for var in $SUBST_VARS; do
    text="${text//"\${$var}"/"${!var}"}"
  done
  printf '%s\n' "$text"
}

gpu_allocatable() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
    | awk '{s += $1} END {print s + 0}'
}

# kind node containers carry this label (checked on kind v0.31.0 nodes)
kind_nodes() { docker ps -aq --filter "label=io.x-k8s.kind.cluster=$CLUSTER_NAME"; }

# nvkind has no delete command: kind deletes nodes + their volumes; the label is the
# fallback when ./.bin is already gone (rm -f -v: the nodes' anonymous /var volumes)
delete_cluster() {
  if command -v kind >/dev/null; then kind delete cluster --name "$CLUSTER_NAME"; fi
  kind_nodes | xargs -r docker rm -f -v >/dev/null
}

# Host settings the lab needs (changed only by the user: sudo ./host-settings.sh on|off)
NVCONF=/etc/nvidia-container-runtime/config.toml
default_runtime_ok() { [[ "$(docker info --format '{{.DefaultRuntime}}')" == "nvidia" ]]; }
volume_mounts_ok()   { grep -Eq '^\s*accept-nvidia-visible-devices-as-volume-mounts\s*=\s*true' "$NVCONF" 2>/dev/null; }
inotify_ok() {
  (( $(sysctl -n fs.inotify.max_user_instances) >= 512 )) &&
  (( $(sysctl -n fs.inotify.max_user_watches) >= 524288 ))
}
# set by host-settings.sh only; values above the minimum set by someone else are not ours to revert
inotify_ours() { [[ -f /etc/sysctl.d/90-g1-k8s-gpu-lab.conf ]]; }
