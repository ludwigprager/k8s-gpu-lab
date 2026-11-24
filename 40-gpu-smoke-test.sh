#!/usr/bin/env bash
# Step 40: proves that a pod can use the GPU (CUDA vectorAdd, prints "Test PASSED").
source "$(dirname "$0")/lib.sh"
need_bin kubectl

log "GPU smoke test (CUDA vectorAdd)"
kubectl delete pod cuda-vectoradd -n default --ignore-not-found >/dev/null
render "$ROOT/manifests/gpu-smoke.yaml" | kubectl apply -f -

if ! kubectl wait pod/cuda-vectoradd -n default \
      --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m; then
  kubectl describe pod cuda-vectoradd -n default | tail -n 20 || true
  kubectl logs cuda-vectoradd -n default || true
  die "GPU smoke test failed"
fi

kubectl logs cuda-vectoradd -n default | tail -n 3
kubectl delete pod cuda-vectoradd -n default >/dev/null
log "GPU smoke test passed"
