#!/usr/bin/env bash
# Step 30: cluster add-ons via Helm, at the chart versions pinned in config.env.
# Safe to re-run (helm upgrade --install).
#   GPU Operator      device plugin, GPU feature discovery, DCGM exporter
#   kube-prometheus   Prometheus only (vLLM metrics for KEDA)
#   KEDA + HTTP add-on  scale-to-zero for model1 and app1
#   traefik           ingress controller
source "$(dirname "$0")/lib.sh"
need_bin kubectl
need_bin helm

log "Adding Helm repositories"
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia >/dev/null
helm repo add kedacore https://kedacore.github.io/charts >/dev/null
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add traefik https://traefik.github.io/charts >/dev/null
helm repo update >/dev/null

log "Installing NVIDIA GPU Operator $GPU_OPERATOR_CHART_VERSION (host driver, toolkit=$GPU_OPERATOR_TOOLKIT)"
helm upgrade --install gpu-operator nvidia/gpu-operator --version "$GPU_OPERATOR_CHART_VERSION" \
  --namespace gpu-operator --create-namespace \
  --set driver.enabled=false \
  --set toolkit.enabled="$GPU_OPERATOR_TOOLKIT" \
  --wait --timeout 15m

# 20 min: on a fresh cluster every operator image is pulled first, and a busy line slows that down
log "Waiting for nodes to report nvidia.com/gpu"
for _ in $(seq 120); do
  [[ "$(gpu_allocatable)" -gt 0 ]] && break
  sleep 10
done
[[ "$(gpu_allocatable)" -gt 0 ]] || die "no nvidia.com/gpu after 20 min: kubectl -n gpu-operator get pods"
log "GPUs allocatable: $(gpu_allocatable)"

log "Installing kube-prometheus-stack $KUBE_PROMETHEUS_CHART_VERSION (Prometheus only)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --version "$KUBE_PROMETHEUS_CHART_VERSION" \
  --namespace monitoring --create-namespace \
  --set grafana.enabled=false \
  --set alertmanager.enabled=false \
  --set nodeExporter.enabled=false \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 10m

log "Installing KEDA $KEDA_CHART_VERSION + HTTP add-on $KEDA_HTTP_CHART_VERSION"
helm upgrade --install keda kedacore/keda --version "$KEDA_CHART_VERSION" \
  --namespace keda --create-namespace --wait --timeout 10m
# Long timeouts: the first request after idle waits for app1 AND a cold model1.
#   readinessTimeout       how long the interceptor holds a request while app1 scales from 0
#   responseHeaderTimeout  how long app1 may take to answer (it waits for a cold model1)
helm upgrade --install http-add-on kedacore/keda-add-ons-http --version "$KEDA_HTTP_CHART_VERSION" \
  --namespace keda \
  --set interceptor.readinessTimeout=120s \
  --set interceptor.responseHeaderTimeout=900s \
  --wait --timeout 10m

log "Installing traefik $TRAEFIK_CHART_VERSION (ingress controller)"
# ClusterIP: no host port; 80-test.sh reaches it with a port-forward
helm upgrade --install traefik traefik/traefik --version "$TRAEFIK_CHART_VERSION" \
  --namespace traefik --create-namespace \
  --set service.spec.type=ClusterIP \
  --set providers.kubernetesIngress.allowExternalNameServices=true \
  --wait --timeout 10m

log "Platform installed"
helm list -A
