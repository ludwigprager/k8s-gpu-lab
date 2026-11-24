#!/usr/bin/env bash
# Sends one question through the full chain:
# localhost -> traefik -> KEDA interceptor -> app1 -> model1
# Usage: ./80-test.sh "Why is the sky blue?"
source "$(dirname "$0")/lib.sh"
need_bin kubectl
need curl

question="${1:-Explain in one sentence what a GPU does.}"

# The port must be free: if something else listens there, curl would silently talk to it
if (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null; then
  die "port $LOCAL_PORT is already in use; set another LOCAL_PORT (config.env or env)"
fi

kubectl -n traefik port-forward svc/traefik "$LOCAL_PORT:80" >/dev/null 2>&1 &
pf=$!
trap 'kill $pf 2>/dev/null' EXIT
for _ in $(seq 50); do
  (exec 3<>"/dev/tcp/127.0.0.1/$LOCAL_PORT") 2>/dev/null && break
  kill -0 "$pf" 2>/dev/null || die "port-forward to traefik failed"
  sleep 0.1
done

log "Replicas before:"
kubectl -n "$NAMESPACE" get deploy app1 model1

log "Asking: $question  (can take minutes if app1/model1 are at 0)"
# --fail-with-body: an error answer (app1's 502 + {"error": ...}) is shown and fails the script,
# so 10-start.sh stops there instead of reporting "Done"
curl -sS --fail-with-body --max-time 1200 -G "http://127.0.0.1:$LOCAL_PORT/ask" \
  -H "Host: $APP1_HOST" --data-urlencode "q=$question" || { echo; die "no answer through the chain"; }
echo

log "Replicas after:"
kubectl -n "$NAMESPACE" get deploy app1 model1
