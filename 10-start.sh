#!/usr/bin/env bash
# Brings everything up, step by step. Each step can also be run on its own.
# Works on a fresh clone; ./99-teardown.sh reverses it.
#   ./10-start.sh                first run / re-run (keeps an existing cluster)
#   ./10-start.sh --setup-host   also apply the NVIDIA host settings (sudo, restarts Docker)
#   ./10-start.sh --recreate     delete and recreate the kind cluster
set -euo pipefail
cd "$(dirname "$0")"
start=$SECONDS

./11-create-dirs.sh           # model cache dir + hard links to local models
./15-install-tools.sh         # nvkind, kubectl, helm (pinned) into ./.bin
./20-create-cluster.sh "$@"   # kind cluster with GPU access (nvkind), cache mounted as /models
./30-install-platform.sh      # GPU Operator, Prometheus, KEDA + HTTP add-on, traefik
./40-gpu-smoke-test.sh        # CUDA vectorAdd pod on the GPU
./50-deploy-apps.sh           # model1 (vLLM) + app1

elapsed=$((SECONDS - start))
cat <<EOF

Done in $((elapsed / 60)) min $((elapsed % 60)) s. Next:
  ./80-test.sh "Why is the sky blue?"   one request through Ingress -> KEDA -> app1 -> model1
  ./90-delete.sh                        remove apps (--all: platform, --cluster: whole cluster)
  ./99-teardown.sh                      remove everything; then the clone can be deleted
  export KUBECONFIG=\$PWD/kubeconfig     use kubectl/helm by hand (tools in ./.bin)
Both deployments scale to 0 when idle: app1 after ~15 min, model1 ~10 min later.
EOF
