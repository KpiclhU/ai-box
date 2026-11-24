#!/usr/bin/env bash
# 50-install-services.sh — render and install the llama.cpp + ComfyUI systemd units.
#
#   sudo ./scripts/50-install-services.sh
#
# Units are templates in systemd/ with __USER__, __HOME__, __AI_HOME__, __REPO__,
# __CONFIG_DIR__. This script substitutes them, writes the env files under
# ~/.config/ai-box, and enables what it can actually start.
#
# Both services come up on 127.0.0.1. Moving them onto the LAN is a separate,
# deliberate step — ./scripts/80-lan-access.sh — because that bind is only safe
# once a firewall limits it to one subnet.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
AI_HOME="${AI_HOME:-$TARGET_HOME/ai}"
CONFIG_DIR="$TARGET_HOME/.config/ai-box"
UNIT_DIR=/etc/systemd/system
UNITS="llama-server llama-router comfyui"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage 0 ;;
    *)         die "unknown argument: $1 (try --help)" ;;
  esac
  if [ $# -gt 0 ]; then shift; fi
done

[ "$(id -u)" -eq 0 ] || die "needs root: sudo $0"
[ -n "$TARGET_HOME" ] || die "could not resolve home directory for $TARGET_USER"
[ -d "$REPO/systemd" ] || die "systemd/ directory not found in $REPO"

say "Preparing $CONFIG_DIR"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 755 "$CONFIG_DIR"

# ---- llama-server env -------------------------------------------------------
LLAMA_ENV="$CONFIG_DIR/llama-server.env"
if [ ! -f "$LLAMA_ENV" ]; then
  MODEL="$(find "$AI_HOME/models" -maxdepth 1 -name '*.gguf' -size +1G 2>/dev/null | sort | head -1 || true)"
  {
    if [ -n "$MODEL" ]; then
      printf '# llama.cpp server configuration. Edit and: systemctl restart llama-server\n'
      printf '# The model path must be absolute and contain no spaces.\n'
      printf 'MODEL=%s\n' "$MODEL"
    else
      printf '# No GGUF found under %s at install time.\n' "$AI_HOME/models"
      printf '# Download one (see docs/07-models.md), set MODEL, then:\n'
      printf '#   systemctl enable --now llama-server\n'
      printf 'MODEL=\n'
    fi
    cat <<'EOF'
HOST=127.0.0.1
PORT=8080
# --ctx-size is the TOTAL across --parallel slots: 131072 / 2 = a 64k window per request.
# q8_0 KV halves what it costs in memory and needs --flash-attn on. Lower --ctx-size if a
# load starts failing; raise --parallel only together with the total.
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --alias local"
EOF
  } > "$LLAMA_ENV"
  if [ -n "$MODEL" ]; then
    echo "wrote $LLAMA_ENV (model: $(basename "$MODEL"))"
  else
    echo "wrote $LLAMA_ENV (no model yet — service will not be started)"
  fi
else
  echo "$LLAMA_ENV exists, left untouched"
fi

# ---- llama-router env -------------------------------------------------------
ROUTER_ENV="$CONFIG_DIR/llama-router.env"
if [ ! -f "$ROUTER_ENV" ]; then
  cat > "$ROUTER_ENV" <<EOF
# Multi-model router configuration. Edit and: systemctl restart llama-router
# Model names are the .gguf file names under MODELS_DIR; the UI lists what it can see
MODELS_DIR=$AI_HOME/models
# 1 is right for ~48 GiB of GTT: two 24 GB models do not fit in memory at once.
MODELS_MAX=1
HOST=127.0.0.1
PORT=8080
# --ctx-size is the TOTAL across --parallel slots: 131072 / 2 = a 64k window per request.
# q8_0 KV halves what it costs in memory and needs --flash-attn on. Lower --ctx-size if a
# load starts failing; raise --parallel only together with the total.
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2"
EOF
  echo "wrote $ROUTER_ENV"
else
  echo "$ROUTER_ENV exists, left untouched"
fi

# ---- comfyui env ------------------------------------------------------------
COMFY_ENV="$CONFIG_DIR/comfyui.env"
if [ ! -f "$COMFY_ENV" ]; then
  cat > "$COMFY_ENV" <<EOF
# ComfyUI runtime environment. Edit and: systemctl restart comfyui
MIOPEN_FIND_MODE=FAST
TORCH_BLAS_PREFER_HIPBLASLT=1
TORCH_ROCM_AOTRITON_ENABLE=1
FLASH_ATTENTION_TRITON_AMD_ENABLE=1
PYTORCH_ALLOC_CONF=expandable_segments:True
HOST=127.0.0.1
PORT=8188
COMFY_EXTRA_ARGS="--use-pytorch-cross-attention"
EOF
  echo "wrote $COMFY_ENV"
else
  echo "$COMFY_ENV exists, left untouched"
fi

for f in "$LLAMA_ENV" "$ROUTER_ENV" "$COMFY_ENV"; do
  [ -f "$f" ] || continue
  chown "$TARGET_USER:$TARGET_USER" "$f"
  chmod 600 "$f"
done

# ---- render units -----------------------------------------------------------
say "Installing units into $UNIT_DIR"
for unit in $UNITS; do
  src="$REPO/systemd/${unit}.service"
  [ -f "$src" ] || die "missing $src"
  sed -e "s|__USER__|$TARGET_USER|g" \
      -e "s|__HOME__|$TARGET_HOME|g" \
      -e "s|__AI_HOME__|$AI_HOME|g" \
      -e "s|__REPO__|$REPO|g" \
      -e "s|__CONFIG_DIR__|$CONFIG_DIR|g" \
      "$src" > "$UNIT_DIR/${unit}.service"
  echo "installed $UNIT_DIR/${unit}.service"
done

systemctl daemon-reload

# ---- enable what can run ----------------------------------------------------
say "Enabling"
if grep -q '^MODEL=.' "$LLAMA_ENV" 2>/dev/null; then
  systemctl enable llama-server.service
  systemctl restart llama-server.service || true
  echo "llama-server enabled (may still be loading the model)"
else
  echo "skipped llama-server: no MODEL set in $LLAMA_ENV"
fi

if [ -x "$AI_HOME/comfyui/.venv/bin/python" ]; then
  systemctl enable comfyui.service
  systemctl restart comfyui.service || true
  echo "comfyui enabled"
else
  echo "skipped comfyui: run ./scripts/30-install-comfyui.sh first"
fi

say "Done"
cat <<EOF
  llama-server   http://127.0.0.1:8080   /v1, /health, /props
  comfyui        http://127.0.0.1:8188   /prompt, /history/<id>, /view
  config         $CONFIG_DIR
  logs           journalctl -u llama-server -f

Both are loopback-only until you publish them:

  sudo ./scripts/80-lan-access.sh --lan 192.168.150.0/24

That script puts the ufw rule in place first and only then moves HOST to
0.0.0.0, so the ports are never open without the firewall covering them.
EOF
