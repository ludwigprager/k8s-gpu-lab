# kind config template for nvkind (Go template + sprig, values from 20-create-cluster.sh).
# Based on nvkind's default-config-template.yaml, plus the model cache mount on every worker.
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
{{- range $.workers }}
- role: worker
  {{- $devices := .devices }}
  {{- if not (kindIs "slice" $devices) }}
    {{- $devices = list .devices }}
  {{- end }}
  extraMounts:
    # model1's Hugging Face cache (MODEL_CACHE_DIR), reaches the vLLM pod via a hostPath PV
    - hostPath: {{ $.modelCache }}
      containerPath: /models
    # We inject all NVIDIA GPUs using the nvidia-container-runtime.
    # This requires `accept-nvidia-visible-devices-as-volume-mounts = true` be set
    # in `/etc/nvidia-container-runtime/config.toml`
    {{- range $d := $devices }}
    - hostPath: /dev/null
      containerPath: /var/run/nvidia-container-devices/{{ $d }}
    {{- end }}
{{- end }}
