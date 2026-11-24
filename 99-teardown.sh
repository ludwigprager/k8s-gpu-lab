#!/usr/bin/env bash
# Full teardown: afterwards `rm -rf` of the clone leaves nothing behind, and a fresh
# clone + ./10-start.sh restores everything (local models are re-linked, the rest downloaded).
# Best-effort: every step runs even if an earlier one fails.
#   removed: kind cluster (node containers + their volumes), the "kind" Docker network if
#            nothing else uses it, kubeconfig, .helm/, .bin/
#   kept:    MODEL_CACHE_DIR (downloaded models; inside the clone by default, so rm -rf takes it).
#            The originals in LOCAL_MODELS_SRC are never touched: the cache holds hard links.
#   left:    Docker images (kindest/node, vllm, golang, ...), like every image you pull
source "$(dirname "$0")/lib.sh"
set +e

log "Deleting kind cluster $CLUSTER_NAME"
kind_nodes | xargs -r docker rm -f -v >/dev/null   # -v: the nodes' anonymous /var volumes

if docker network inspect kind >/dev/null 2>&1; then
  if [[ "$(docker network inspect kind -f '{{len .Containers}}')" == 0 ]]; then
    log "Removing Docker network kind (unused)"
    docker network rm kind >/dev/null
  else
    warn "Docker network kind still has containers (another kind cluster?), kept"
  fi
fi

log "Removing kubeconfig, .helm/, .bin/"
rm -rf "$ROOT/kubeconfig" "$ROOT/.helm" "$ROOT/.bin"

# Files not owned by the user would make `rm -rf` of the clone fail without sudo.
# vLLM runs as the host user, so this only catches leftovers (e.g. an older root pod).
if [[ -d "$MODEL_CACHE_PATH" ]] && [[ -n "$(find "$MODEL_CACHE_PATH" ! -user "$HOST_UID" -print -quit)" ]]; then
  log "Giving foreign-owned files in $MODEL_CACHE_PATH back to $(id -un)"
  docker run --rm -v "$MODEL_CACHE_PATH:/cache" "$GO_IMAGE" chown -R "$HOST_UID:$HOST_GID" /cache
fi

case "$MODEL_CACHE_PATH" in
  "$ROOT"/*) log "Teardown done. rm -rf $ROOT now leaves no residue." ;;
  *)         log "Teardown done. Model cache outside the clone, kept: $MODEL_CACHE_PATH" ;;
esac
