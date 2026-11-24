#!/usr/bin/env bash
# Step 20: kind cluster with GPU access, created with nvkind.
#   --setup-host  apply the two host settings (sudo) if missing
#   --recreate    delete an existing cluster of the same name first
# Without --recreate an existing cluster is kept and only verified.
source "$(dirname "$0")/lib.sh"

SETUP_HOST=false
RECREATE=false
for arg in "$@"; do
  case "$arg" in
    --setup-host) SETUP_HOST=true ;;
    --recreate)   RECREATE=true ;;
    *) die "unknown option: $arg" ;;
  esac
done

need docker
need kubectl
need nvidia-ctk "(NVIDIA Container Toolkit on the host)"

# ---------------------------------------------------------------- host settings
NVCONF=/etc/nvidia-container-runtime/config.toml

default_runtime_ok() { [[ "$(docker info --format '{{.DefaultRuntime}}')" == "nvidia" ]]; }
volume_mounts_ok()   { grep -Eq '^\s*accept-nvidia-visible-devices-as-volume-mounts\s*=\s*true' "$NVCONF" 2>/dev/null; }

log "Checking host settings"
if ! default_runtime_ok || ! volume_mounts_ok; then
  if [[ "$SETUP_HOST" == true ]]; then
    warn "applying host settings (sudo); Docker restarts, running containers stop briefly"
    sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
    sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place
    sudo systemctl restart docker
    if ! default_runtime_ok || ! volume_mounts_ok; then die "host settings still not active"; fi
  else
    default_runtime_ok || warn "Docker default runtime is not 'nvidia'"
    volume_mounts_ok   || warn "accept-nvidia-visible-devices-as-volume-mounts is not true in $NVCONF"
    die "host not prepared. Run once with --setup-host, or manually:
   sudo nvidia-ctk runtime configure --runtime=docker --set-as-default
   sudo nvidia-ctk config --set accept-nvidia-visible-devices-as-volume-mounts=true --in-place
   sudo systemctl restart docker"
  fi
fi
log "Host OK (default runtime nvidia, volume-mount GPU selection on)"

need nvkind "(run ./15-install-tools.sh)"
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
    kind_nodes | xargs -r docker rm -f -v >/dev/null   # -v: the nodes' anonymous /var volumes
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
  if docker exec "$node" nvidia-smi -L 2>/dev/null; then
    gpu_nodes=$((gpu_nodes + 1))
    docker exec "$node" grep -q nvidia /etc/containerd/config.toml \
      || warn "node $node sees the GPU, but containerd has no 'nvidia' runtime"
  fi
done
[[ "$gpu_nodes" -gt 0 ]] || die "no node sees a GPU; check: nvkind cluster print-gpus --name=$CLUSTER_NAME"

# RuntimeClass used by the GPU pods (the GPU Operator also creates it; harmless if it exists)
kubectl apply -f - <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: $GPU_RUNTIME_CLASS
handler: nvidia
EOF

log "Cluster ready: $gpu_nodes node(s) with GPU"
kubectl get nodes
