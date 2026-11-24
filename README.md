# g1-k8s-gpu-lab

An app (`app1`) and the LLM it needs (`model1`, served by vLLM) on a local kind
cluster with GPU access, with scale-to-zero for both. When nothing is asking,
the GPU is free.

```
curl -> traefik (Ingress) -> KEDA HTTP interceptor -> app1 -> model1 (vLLM, 1 GPU)
                              wakes app1 from 0       KEDA ScaledObject wakes model1
                                                      while app1 has pods
```

## Requirements

- Linux host with an NVIDIA GPU, driver and NVIDIA Container Toolkit (`nvidia-ctk`)
- `docker`, `envsubst` (gettext-base), `curl`
- nvkind, kubectl and helm are installed at pinned versions into `./.bin` by
  `15-install-tools.sh` (nvkind is built in a golang container); nothing goes onto the host

## Usage

```bash
./10-start.sh --setup-host            # first time: also sets the two NVIDIA host settings (sudo)
./10-start.sh                         # later runs; existing cluster is kept
./80-test.sh "Why is the sky blue?"   # one request through the whole chain
./90-delete.sh [--all|--cluster]      # apps / + platform / whole cluster
./99-teardown.sh                      # everything; afterwards `rm -rf` of the clone leaves no residue
```

Everything the scripts write stays inside the clone: `kubeconfig` (not `~/.kube/config`),
helm state in `.helm/`, tools in `.bin/`, the model cache in `data/`. To use kubectl or
helm by hand: `export KUBECONFIG=$PWD/kubeconfig PATH=$PWD/.bin:$PATH`.

`99-teardown.sh` + `rm -rf` + fresh clone + `10-start.sh` restores the whole lab.
Only Docker images stay behind, like every image you pull.

`--setup-host` makes `nvidia` Docker's default runtime and enables
`accept-nvidia-visible-devices-as-volume-mounts`, then restarts Docker
(running containers stop briefly).

Settings are in `config.env`; any of them can be overridden per call,
e.g. `MODEL_ID=Qwen/Qwen2.5-1.5B-Instruct ./10-start.sh`.

## Steps

`10-start.sh` only calls the steps below; each one can be run on its own.

| Script | Does |
|---|---|
| `11-create-dirs.sh` | creates `MODEL_CACHE_DIR` (default `data/hf-cache`, gitignored) as the current user; hard-links `LOCAL_MODELS` from `LOCAL_MODELS_SRC` into `local/` |
| `15-install-tools.sh` | nvkind, kubectl, helm at the versions in `config.env` into `./.bin` |
| `20-create-cluster.sh` | checks host settings, creates the kind cluster from `kind/nvkind-config.tpl` (GPU worker with `MODEL_CACHE_DIR` mounted as `/models`), verifies `nvidia-smi` in the nodes, creates the `nvidia` RuntimeClass |
| `30-install-platform.sh` | GPU Operator (driver and toolkit off), Prometheus, KEDA + HTTP add-on, traefik |
| `40-gpu-smoke-test.sh` | CUDA vectorAdd pod |
| `50-deploy-apps.sh` | secret, app1 code ConfigMap, `manifests/model1.yaml`, `manifests/app1.yaml` |
| `80-test.sh` | port-forward to traefik, sends `/ask` |
| `90-delete.sh` | cleanup inside the cluster, or `--cluster` |
| `99-teardown.sh` | cluster, unused `kind` network, kubeconfig, `.helm/`, `.bin/`; keeps the model cache |

## Model cache

```
data/hf-cache  --kind extraMounts-->  /models on the GPU worker  --hostPath PV-->  /models in the vLLM pod
```

- Downloads land in `data/hf-cache/hub/` (`HF_HOME=/models`); vLLM and triton compile
  caches next to them. All survive `90-delete.sh` and a recreated cluster.
- vLLM runs as your uid/gid, so every file in there is yours and `rm -rf` works without sudo.
- Models already on disk: list them in `LOCAL_MODELS`, `11-create-dirs.sh` hard-links them
  to `data/hf-cache/local/<name>` (same filesystem, no extra space; deleting the links never
  touches the originals). Serve one with `MODEL_ID=/models/local/<name>`.

## Files

| File | Content |
|---|---|
| `config.env` | tool versions, cluster name, model, model cache, hostnames |
| `kind/nvkind-config.tpl` | kind config template for nvkind (GPU devices + model cache mount) |
| `lib.sh` | config loading, `envsubst` rendering, helpers |
| `manifests/model1.yaml` | hostPath PV + PVC, vLLM Deployment, Service, ServiceMonitor, ScaledObject, NetworkPolicy |
| `manifests/app1.yaml` | Deployment, Service, HTTPScaledObject, Ingress (via KEDA interceptor) |
| `manifests/gpu-smoke.yaml` | CUDA vectorAdd pod |
| `app1/app.py` | test client (Python stdlib), mounted from a ConfigMap |

Manifests contain `${VARS}`; only the variables listed in `lib.sh` (`SUBST_VARS`)
are substituted.
