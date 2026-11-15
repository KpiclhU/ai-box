#!/usr/bin/env bash
# 50-install-services.sh — render and install the systemd units.
#
#   sudo ./scripts/50-install-services.sh
#
# Units are templates in systemd/ with __USER__, __HOME__, __AI_HOME__, __REPO__,
# __CONFIG_DIR__. This script substitutes them, writes the env files under
# ~/.config/ai-box, and enables what it can actually start.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
AI_HOME="${AI_HOME:-$TARGET_HOME/ai}"
CONFIG_DIR="$TARGET_HOME/.config/ai-box"
UNIT_DIR=/etc/systemd/system

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "needs root: sudo $0"
[ -n "$TARGET_HOME" ] || die "could not resolve home directory for $TARGET_USER"
[ -d "$REPO/systemd" ] || die "systemd/ directory not found in $REPO"

say "Preparing $CONFIG_DIR"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 755 "$CONFIG_DIR"

# ---- llama-server env -------------------------------------------------------
LLAMA_ENV="$CONFIG_DIR/llama-server.env"
if [ ! -f "$LLAMA_ENV" ]; then
  MODEL="$(find "$AI_HOME/models" -maxdepth 1 -name '*.gguf' -size +1G 2>/dev/null | sort | head -1 || true)"
  if [ -n "$MODEL" ]; then
    cat > "$LLAMA_ENV" <<EOF
# llama.cpp server configuration. Edit and: systemctl restart llama-server
# The model path must be absolute and contain no spaces.
MODEL=$MODEL
HOST=127.0.0.1
PORT=8080
LLAMA_EXTRA_ARGS=--ctx-size 32768 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --alias local
EOF
    echo "wrote $LLAMA_ENV (model: $(basename "$MODEL"))"
  else
    cat > "$LLAMA_ENV" <<EOF
# No GGUF found under $AI_HOME/models at install time.
# Download one (./scripts/60-download-models.sh coder-q6), set MODEL, then:
#   systemctl enable --now llama-server
MODEL=
HOST=127.0.0.1
PORT=8080
LLAMA_EXTRA_ARGS=--ctx-size 32768 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --alias local
EOF
    echo "wrote $LLAMA_ENV (no model yet — service will not be started)"
  fi
else
  echo "$LLAMA_ENV exists, left untouched"
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
COMFY_EXTRA_ARGS=--use-pytorch-cross-attention
EOF
  echo "wrote $COMFY_ENV"
else
  echo "$COMFY_ENV exists, left untouched"
fi

chown "$TARGET_USER:$TARGET_USER" "$CONFIG_DIR"/*.env
chmod 600 "$CONFIG_DIR"/*.env

# ---- render units -----------------------------------------------------------
say "Installing units into $UNIT_DIR"
for unit in llama-server comfyui ai-discord-bot; do
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

systemctl enable comfyui.service
systemctl restart comfyui.service || true
echo "comfyui enabled"

if [ -f "$REPO/.env" ] && ! grep -q '^DISCORD_TOKEN=YOUR_BOT_TOKEN_HERE' "$REPO/.env"; then
  systemctl enable ai-discord-bot.service
  systemctl restart ai-discord-bot.service || true
  echo "ai-discord-bot enabled"
else
  echo "skipped ai-discord-bot: set DISCORD_TOKEN in $REPO/.env first"
fi

cat <<EOF

Status:
  systemctl status llama-server comfyui ai-discord-bot --no-pager
  journalctl -u llama-server -f

Endpoints:
  http://127.0.0.1:8080/health        llama.cpp
  http://127.0.0.1:8188               ComfyUI
EOF
