#!/usr/bin/env bash
# The host settings this lab needs. The only part of the lab that changes the host, so it is
# not a numbered stage: 10-start.sh never calls it, you run it yourself with sudo.
#   ./host-settings.sh            show the current state (no sudo needed)
#   sudo ./host-settings.sh on    set everything below
#   sudo ./host-settings.sh off   revert everything (99-teardown.sh prints this while anything is on)
#
#   nvidia   Docker default runtime "nvidia"                         (nvkind)
#   mounts   accept-nvidia-visible-devices-as-volume-mounts = true    (nvkind)
#   inotify  fs.inotify.max_user_instances >= 512, max_user_watches >= 524288 (kind: the kubelet,
#            containerd and device plugin in the nodes need more inotify than the 128 default;
#            otherwise "couldn't initialize inotify: too many open files")
#
# Idempotent. Docker is restarted only when its default runtime actually changes, which briefly
# stops all running containers (those with a restart policy come back).
# Standalone on purpose (no lib.sh): everything that runs as root is in this file.
set -euo pipefail

DAEMON_JSON=/etc/docker/daemon.json
NVCONF=/etc/nvidia-container-runtime/config.toml
KEY=accept-nvidia-visible-devices-as-volume-mounts
SYSCTL_FILE=/etc/sysctl.d/90-g1-k8s-gpu-lab.conf
INSTANCES=512
WATCHES=524288

runtime_on() { [[ "$(docker info --format '{{.DefaultRuntime}}')" == nvidia ]]; }
mounts_on()  { grep -Eq "^\s*$KEY\s*=\s*true" "$NVCONF" 2>/dev/null; }
inotify_on() {
  (( $(sysctl -n fs.inotify.max_user_instances) >= INSTANCES )) &&
  (( $(sysctl -n fs.inotify.max_user_watches) >= WATCHES ))
}
state() { if "$@"; then echo on; else echo off; fi; }

show() {
  echo "nvidia   Docker default runtime nvidia:          $(state runtime_on)   ($DAEMON_JSON)"
  echo "mounts   $KEY: $(state mounts_on)   ($NVCONF)"
  echo "inotify  max_user_instances $(sysctl -n fs.inotify.max_user_instances), max_user_watches $(sysctl -n fs.inotify.max_user_watches): $(state inotify_on)$( [[ -f $SYSCTL_FILE ]] && echo "   ($SYSCTL_FILE)")"
}

need_root() { [[ $EUID -eq 0 ]] || { echo "run with sudo: sudo $0 $1" >&2; exit 1; }; }

case "${1:-status}" in
  status)
    show
    ;;
  on)
    need_root on
    command -v nvidia-ctk >/dev/null || { echo "nvidia-ctk missing (NVIDIA Container Toolkit)" >&2; exit 1; }
    mounts_on || nvidia-ctk config --set "$KEY=true" --in-place
    if ! inotify_on; then
      # persistent across reboots; the previous values are kept in the file for "off"
      cat > "$SYSCTL_FILE" <<EOF
# written by g1-k8s-gpu-lab/host-settings.sh (kind needs more inotify than the defaults)
# previous: fs.inotify.max_user_instances=$(sysctl -n fs.inotify.max_user_instances) fs.inotify.max_user_watches=$(sysctl -n fs.inotify.max_user_watches)
fs.inotify.max_user_instances = $INSTANCES
fs.inotify.max_user_watches = $WATCHES
EOF
      sysctl -q -p "$SYSCTL_FILE"
    fi
    if ! runtime_on; then
      nvidia-ctk runtime configure --runtime=docker --set-as-default
      echo "restarting Docker (running containers stop briefly)"
      systemctl restart docker
    fi
    show
    ;;
  off)
    need_root off
    mounts_on && nvidia-ctk config --set "$KEY=false" --in-place
    if [[ -f "$SYSCTL_FILE" ]]; then
      prev="$(sed -n 's/^# previous: //p' "$SYSCTL_FILE")"
      rm -f "$SYSCTL_FILE"
      # shellcheck disable=SC2086  # two key=value words
      [[ -n "$prev" ]] && sysctl -q -w $prev
    fi
    if runtime_on; then
      # nvidia-ctk has no "unset default" and writes sorted keys, so the line always ends with ","
      grep -q '"default-runtime": "nvidia",' "$DAEMON_JSON" \
        || { echo "unexpected format of $DAEMON_JSON, remove \"default-runtime\" by hand" >&2; exit 1; }
      sed -i '/"default-runtime": "nvidia",/d' "$DAEMON_JSON"
      echo "restarting Docker (running containers stop briefly)"
      systemctl restart docker
    fi
    show
    ;;
  *)
    echo "usage: $0 [status|on|off]" >&2
    exit 1
    ;;
esac
