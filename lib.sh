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

# Only these variables are substituted; any other "$" in the manifests stays as is.
# shellcheck disable=SC2016  # literal ${VAR} list for envsubst
SUBST_VARS='${NAMESPACE} ${MODEL_ID} ${VLLM_IMAGE} ${GPU_MEM_UTIL} ${MAX_MODEL_LEN} ${MODEL_MAX_REPLICAS} ${APP1_IMAGE} ${APP1_HOST} ${CUDA_SAMPLE_IMAGE} ${GPU_RUNTIME_CLASS} ${CLUSTER_NAME} ${HOST_UID} ${HOST_GID}'

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mxx %s\033[0m\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null || die "missing command: $1 ${2:-}"; }

render() { envsubst "$SUBST_VARS" < "$1"; }

gpu_allocatable() {
  kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' \
    | awk '{s += $1} END {print s + 0}'
}

# kind node containers carry this label; nvkind has no delete command
kind_nodes() { docker ps -aq --filter "label=io.x-k8s.io/kind.cluster=$CLUSTER_NAME"; }
