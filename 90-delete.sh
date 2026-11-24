#!/usr/bin/env bash
# Cleanup inside the cluster. For a full teardown (cluster, tools, kubeconfig) see 99-teardown.sh.
#   ./90-delete.sh            remove app1 + model1 (namespace + cache PV object; the cached
#                             files in MODEL_CACHE_DIR on the host are kept)
#   ./90-delete.sh --all      also uninstall the platform charts
#   ./90-delete.sh --cluster  delete the whole kind cluster
source "$(dirname "$0")/lib.sh"

case "${1:-}" in
  --cluster)
    log "Deleting kind cluster $CLUSTER_NAME"
    kind_nodes | xargs -r docker rm -f -v >/dev/null   # -v: the nodes' anonymous /var volumes
    exit 0
    ;;
  ""|--all) ;;
  *) die "unknown option: $1" ;;
esac

need kubectl
log "Deleting namespace $NAMESPACE (app1, model1) and PV model1-cache-$NAMESPACE"
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait
kubectl delete pv "model1-cache-$NAMESPACE" --ignore-not-found

if [[ "${1:-}" == "--all" ]]; then
  need helm
  log "Uninstalling platform charts"
  helm uninstall traefik -n traefik || true
  helm uninstall http-add-on -n keda || true
  helm uninstall keda -n keda || true
  helm uninstall kube-prometheus-stack -n monitoring || true
  helm uninstall gpu-operator -n gpu-operator || true
fi
