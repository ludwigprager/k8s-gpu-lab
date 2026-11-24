#!/usr/bin/env bash
# Step 30: cluster add-ons via Helm. Safe to re-run (helm upgrade --install).
#   GPU Operator      device plugin, GPU feature discovery, DCGM exporter
#   kube-prometheus   Prometheus only (vLLM metrics for KEDA)
#   KEDA + HTTP add-on  scale-to-zero for model1 and app1
#   traefik           ingress controller
source "$(dirname "$0")/lib.sh"
need kubectl
need helm

log "Adding Helm repositories"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add traefik https://traefik.github.io/charts >/dev/null
helm repo update >/dev/null

log "Installing NVIDIA GPU Operator (host driver, toolkit=$GPU_OPERATOR_TOOLKIT)"
helm upgrade --install gpu-operator nvidia/gpu-operator \
  --namespace gpu-operator --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled="$GPU_OPERATOR_TOOLKIT" \
  --wait --timeout 15m

log "Waiting for nodes to report nvidia.com/gpu"
for _ in $(seq 60); do
  [[ "$(gpu_allocatable)" -gt 0 ]] && break
  sleep 10
done
[[ "$(gpu_allocatable)" -gt 0 ]] || die "no nvidia.com/gpu after 10 min: kubectl -n gpu-operator get pods"
log "GPUs allocatable: $(gpu_allocatable)"

log "Installing kube-prometheus-stack (Prometheus only)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.enabled=false \
  --set alertmanager.enabled=false \
  --set nodeExporter.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 10m

log "Installing KEDA + HTTP add-on"
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace --wait --timeout 10m
# Long timeouts: the first request after idle waits for app1 AND a cold model1.
# Check these value names against the chart version you get (helm show values).
helm upgrade --install http-add-on kedacore/keda-add-ons-http \
  --namespace keda \
  --set interceptor.replicas.waitTimeout=120s \
  --set interceptor.responseHeaderTimeout=900s \
  --wait --timeout 10m

log "Installing traefik (ingress controller)"
helm upgrade --install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --set service.type=ClusterIP \
  --set providers.kubernetesIngress.allowExternalNameServices=true \
  --wait --timeout 10m

log "Platform installed"
helm list -A
