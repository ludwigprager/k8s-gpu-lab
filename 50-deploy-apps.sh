#!/usr/bin/env bash
# Step 50: deploys model1 (vLLM) and app1 into $NAMESPACE. Safe to re-run.
source "$(dirname "$0")/lib.sh"
need_bin kubectl

log "Deploying app1 + model1 into namespace $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Secret: generated once, never stored in git
if ! kubectl -n "$NAMESPACE" get secret model1-secrets >/dev/null 2>&1; then
  kubectl -n "$NAMESPACE" create secret generic model1-secrets \
    --from-literal=VLLM_API_KEY="$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" \
    --from-literal=HF_TOKEN="$HF_TOKEN"
fi

kubectl -n "$NAMESPACE" create configmap app1-code --from-file="$ROOT/app1/app.py" \
  --dry-run=client -o yaml | kubectl apply -f -

# A PV whose claim was deleted (90-delete.sh) stays "Released" and never binds again.
# Deleting the PV object only; the files on the host are untouched (hostPath, Retain).
pv="model1-cache-$NAMESPACE"
if [[ "$(kubectl get pv "$pv" -o jsonpath='{.status.phase}' 2>/dev/null)" == Released ]]; then
  kubectl delete pv "$pv" >/dev/null
fi

render "$ROOT/manifests/model1.yaml" | kubectl apply -f -
render "$ROOT/manifests/app1.yaml"   | kubectl apply -f -
kubectl -n "$NAMESPACE" rollout restart deployment/app1 >/dev/null   # pick up app.py changes

log "Waiting for model1 (first start pulls a ~8-10 GB image and downloads the model)"
kubectl -n "$NAMESPACE" rollout status deployment/model1 --timeout=30m
kubectl -n "$NAMESPACE" rollout status deployment/app1 --timeout=5m

kubectl -n "$NAMESPACE" get deploy,scaledobject,httpscaledobject,ingress
