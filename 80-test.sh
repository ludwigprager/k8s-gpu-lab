#!/usr/bin/env bash
# Sends one question through the full chain:
# localhost -> traefik -> KEDA interceptor -> app1 -> model1
# Usage: ./20-test.sh "Why is the sky blue?"
source "$(dirname "$0")/lib.sh"
need_bin kubectl
need curl

question="${1:-Explain in one sentence what a GPU does.}"

kubectl -n traefik port-forward svc/traefik "$LOCAL_PORT:80" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null' EXIT
sleep 2

log "Replicas before:"
kubectl -n "$NAMESPACE" get deploy app1 model1

log "Asking: $question  (can take minutes if app1/model1 are at 0)"
curl -sS --max-time 1200 -G "http://localhost:$LOCAL_PORT/ask" \
  -H "Host: $APP1_HOST" --data-urlencode "q=$question"
echo

log "Replicas after:"
kubectl -n "$NAMESPACE" get deploy app1 model1
