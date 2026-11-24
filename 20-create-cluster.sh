#!/usr/bin/env bash
# Step 20: kind cluster with GPU access, created with nvkind.
#   --recreate    delete an existing cluster of the same name first
# Without --recreate an existing cluster is kept and only verified.
# Missing NVIDIA host settings are printed as a sudo command line; this script never runs sudo.
source "$(dirname "$0")/lib.sh"

RECREATE=false
for arg in "$@"; do
  case "$arg" in
    --recreate)   RECREATE=true ;;
    *) die "unknown option: $arg" ;;
  esac
done

need docker
need_bin kubectl
need nvidia-ctk "(NVIDIA Container Toolkit on the host)"

# ---------------------------------------------------------------- host settings
# The numbered scripts never run sudo: changing the host is the user's step (host-settings.sh).
log "Checking host settings"
default_runtime_ok || warn "Docker default runtime is not 'nvidia'"
volume_mounts_ok   || warn "accept-nvidia-visible-devices-as-volume-mounts is not true in $NVCONF"
inotify_ok         || warn "inotify limits too low for kind (max_user_instances < 512 or max_user_watches < 524288)"
if ! default_runtime_ok || ! volume_mounts_ok || ! inotify_ok; then
  printf '\nThe host is not prepared for this lab. Run this once in a terminal:\n\n  sudo %s/host-settings.sh on\n\n' "$ROOT" >&2
  default_runtime_ok || printf '%s\n' \
    "It restarts Docker, which briefly stops all running containers (those with a restart policy" \
    "come back), and 'nvidia' becomes the default runtime for every container on this host." >&2
  die "then re-run ./10-start.sh"
fi
log "Host OK (default runtime nvidia, volume-mount GPU selection on, inotify limits raised)"

need_bin nvkind
need_bin kind
[[ -d "$MODEL_CACHE_PATH" ]] || die "$MODEL_CACHE_PATH missing (run ./11-create-dirs.sh)"

# ---------------------------------------------------------------- cluster
exists() { [[ -n "$(kind_nodes)" ]]; }
# a cluster from before the model cache mount existed has to be recreated
has_cache_mount() {
  docker inspect "${CLUSTER_NAME}-worker" \
    -f '{{range .Mounts}}{{.Source}}:{{.Destination}} {{end}}' 2>/dev/null \
    | grep -q "$MODEL_CACHE_PATH:/models "
}

if exists; then
  if [[ "$RECREATE" == true ]]; then
    log "Deleting existing cluster $CLUSTER_NAME"
    delete_cluster
  elif ! has_cache_mount; then
    die "cluster $CLUSTER_NAME has no $MODEL_CACHE_PATH -> /models mount; run with --recreate"
  else
    log "Cluster $CLUSTER_NAME exists, keeping it (use --recreate to start fresh)"
  fi
fi

if ! exists; then
  log "Creating cluster $CLUSTER_NAME with nvkind (control plane + GPU worker, $MODEL_CACHE_PATH -> /models)"
  values="$ROOT/.bin/nvkind-values.yaml"
  cat > "$values" <<EOF
modelCache: $MODEL_CACHE_PATH
workers:
- devices: all
EOF
  nvkind cluster create --name="$CLUSTER_NAME" \
    --config-template="$ROOT/kind/nvkind-config.tpl" --config-values="$values"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

# ---------------------------------------------------------------- verify
log "Verifying GPU access inside the nodes"
gpu_nodes=0
for node in $(kubectl get nodes -o name | cut -d/ -f2); do
  # the control plane has no nvidia-smi at all: ask quietly, print only for GPU nodes
  if out="$(docker exec "$node" sh -c 'command -v nvidia-smi >/dev/null && nvidia-smi -L' 2>/dev/null)"; then
    echo "$node: $out"
    gpu_nodes=$((gpu_nodes + 1))
    # the toolkit writes a drop-in (conf.d/99-nvidia.toml): check the effective config, not config.toml
    docker exec "$node" containerd config dump 2>/dev/null | grep -q 'runtimes\.nvidia\]' \
      || warn "node $node sees the GPU, but containerd has no 'nvidia' runtime"
  fi
done
[[ "$gpu_nodes" -gt 0 ]] || die "no node sees a GPU; check: nvkind cluster print-gpus --name=$CLUSTER_NAME"

# RuntimeClass used by the GPU pods. nvkind (and later the GPU Operator) create it already;
# create it only if missing, since apply on their object warns about a missing annotation.
if ! kubectl get runtimeclass "$GPU_RUNTIME_CLASS" >/dev/null 2>&1; then
  kubectl apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: $GPU_RUNTIME_CLASS
handler: nvidia
EOF
fi

log "Cluster ready: $gpu_nodes node(s) with GPU"
kubectl get nodes
