#!/usr/bin/env bash
# Full teardown: stops everything the lab started. Afterwards `rm -rf` of the clone leaves
# nothing behind, and a fresh clone + ./10-start.sh restores everything.
# Best-effort: every step runs even if an earlier one fails.
#   stopped: a port-forward left over from 80-test.sh, the kind cluster (node containers +
#            their volumes, so every workload in it), the "kind" Docker network if nothing
#            else uses it; kubeconfig (it only points at the deleted cluster)
#   kept:    the downloads, all inside the clone, so rm -rf takes them: .bin/ (tools),
#            .helm/ (chart repo cache), MODEL_CACHE_DIR (models; the originals in
#            LOCAL_MODELS_SRC are never touched, the cache holds hard links)
#   never:   removing Docker images on the host (kindest/node, golang, ...): they stay in the
#            image cache for the next 10-start.sh. Images pulled inside the kind node (vllm,
#            GPU Operator, ...) live in the node's containerd and go with the cluster.
#   printed: `sudo ./host-settings.sh off` if the lab's host settings are on (never run here)
source "$(dirname "$0")/lib.sh"
set +e

# 80-test.sh's port-forward normally ends with its trap; this catches one from a killed run
if pkill -f "kubectl -n traefik port-forward svc/traefik $LOCAL_PORT:80"; then
  log "Stopped a leftover port-forward on :$LOCAL_PORT"
fi

log "Deleting kind cluster $CLUSTER_NAME (all workloads in it)"
delete_cluster

if docker network inspect kind >/dev/null 2>&1; then
  if [[ "$(docker network inspect kind -f '{{len .Containers}}')" == 0 ]]; then
    log "Removing Docker network kind (unused)"
    docker network rm kind >/dev/null
  else
    warn "Docker network kind still has containers (another kind cluster?), kept"
  fi
fi

log "Removing kubeconfig (tools in .bin/ and caches are kept)"
rm -f "$ROOT/kubeconfig"

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

# Host settings: changed by the user for nvkind (see 20-create-cluster.sh), so reverting
# them is the user's call too: other GPU setups on this host may rely on them.
if default_runtime_ok || volume_mounts_ok || inotify_ours; then
  printf '\nThe host settings for this lab are still on. If nothing else on this host needs them,\nrevert them in a terminal (before you delete the clone, it holds the script):\n\n  sudo %s/host-settings.sh off\n\n' "$ROOT"
fi
