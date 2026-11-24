#!/usr/bin/env bash
# Step 15: pinned tools into ./.bin (no sudo, nothing installed on the host).
#   nvkind   built from source in a golang container (needs cgo for go-nvml)
#   kind     KIND_VERSION (nvkind calls the kind CLI)
#   kubectl  KUBECTL_VERSION
#   helm     HELM_VERSION
# Each tool sits behind a checkpoint file naming its version; changing the version re-installs it.
source "$(dirname "$0")/lib.sh"
need docker
need curl

BIN="$ROOT/.bin"
mkdir -p "$BIN"

os="$(uname | tr '[:upper:]' '[:lower:]' | grep -E '^linux$')" || die "unsupported OS: $(uname)"
arch="$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/' | grep -E '^(amd64|arm64)$')" \
  || die "unsupported platform: $(uname -m)"

installed() { [[ -f "$BIN/.checkpoint-$1-$2" ]]; }
mark()      { rm -f "$BIN/.checkpoint-$1-"*; touch "$BIN/.checkpoint-$1-$2"; }

if ! installed nvkind "$NVKIND_VERSION"; then
  log "Building nvkind $NVKIND_VERSION in $GO_IMAGE"
  docker run --rm \
    -u "$(id -u):$(id -g)" -e HOME=/tmp -e GOCACHE=/tmp/go-cache -e GOPATH=/tmp/go \
    -e CGO_ENABLED=1 -e GOBIN=/out -v "$BIN:/out" \
    "$GO_IMAGE" go install "github.com/NVIDIA/nvkind/cmd/nvkind@$NVKIND_VERSION"
  [[ -x "$BIN/nvkind" ]] || die "nvkind build failed"
  mark nvkind "$NVKIND_VERSION"
fi

if ! installed kind "$KIND_VERSION"; then
  log "Downloading kind $KIND_VERSION"
  curl -fsSLo "$BIN/kind" "https://kind.sigs.k8s.io/dl/v$KIND_VERSION/kind-$os-$arch"
  chmod +x "$BIN/kind"
  mark kind "$KIND_VERSION"
fi

if ! installed kubectl "$KUBECTL_VERSION"; then
  log "Downloading kubectl $KUBECTL_VERSION"
  curl -fsSLo "$BIN/kubectl" "https://dl.k8s.io/release/v$KUBECTL_VERSION/bin/$os/$arch/kubectl"
  chmod +x "$BIN/kubectl"
  mark kubectl "$KUBECTL_VERSION"
fi

if ! installed helm "$HELM_VERSION"; then
  log "Downloading helm $HELM_VERSION"
  tmp="$(mktemp -d "$BIN/helm-tmp.XXXX")"
  curl -fsSL "https://get.helm.sh/helm-v$HELM_VERSION-$os-$arch.tar.gz" \
    | tar -xz -C "$tmp" --strip-components=1
  mv "$tmp/helm" "$BIN/helm"
  rm -rf "$tmp"
  mark helm "$HELM_VERSION"
fi

log "Tools in $BIN"
printf '  nvkind  %s\n' "$NVKIND_VERSION"
printf '  kind    %s\n' "$(kind version | cut -d' ' -f2)"
printf '  kubectl %s\n' "$(kubectl version --client -o json | sed -n 's/.*"gitVersion": "\(.*\)".*/\1/p')"
printf '  helm    %s\n' "$(helm version --short)"
