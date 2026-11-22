#!/usr/bin/env bash
# 50-install-services.sh — render and install the systemd units.
#
#   sudo ./scripts/50-install-services.sh
#
# Units are templates in systemd/ with __USER__, __HOME__, __AI_HOME__, __REPO__,
# __CONFIG_DIR__, __OPENCLAW_BIN__. This script substitutes them, writes the env files
# under ~/.config/ai-box, and enables what it can actually start.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
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
# --ctx-size is the TOTAL across --parallel slots: 131072 / 2 = a 64k window per request.
# q8_0 KV halves what it costs in memory and needs --flash-attn on. Lower --ctx-size if a
# load starts failing; raise --parallel only together with the total.
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --alias local"
EOF
    echo "wrote $LLAMA_ENV (model: $(basename "$MODEL"))"
  else
    cat > "$LLAMA_ENV" <<EOF
# No GGUF found under $AI_HOME/models at install time.
# Download one (see docs/07-models.md), set MODEL, then:
#   systemctl enable --now llama-server
MODEL=
HOST=127.0.0.1
PORT=8080
# --ctx-size is the TOTAL across --parallel slots: 131072 / 2 = a 64k window per request.
# q8_0 KV halves what it costs in memory and needs --flash-attn on. Lower --ctx-size if a
# load starts failing; raise --parallel only together with the total.
LLAMA_EXTRA_ARGS="--ctx-size 131072 --cache-type-k q8_0 --cache-type-v q8_0 --n-gpu-layers 999 --flash-attn on --jinja --parallel 2 --alias local"
EOF
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

# ---- openclaw env -----------------------------------------------------------
# PORT and the shared secret only. Bind mode, auth mode, provider and model live in
# ~/.openclaw/openclaw.json, which onboarding owns — do not edit it from here.
OPENCLAW_ENV="$CONFIG_DIR/openclaw.env"
if [ ! -f "$OPENCLAW_ENV" ]; then
  TOKEN="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  cat > "$OPENCLAW_ENV" <<EOF
# OpenClaw gateway. Edit and: systemctl restart openclaw-gateway
# Shared secret for the Control UI and CLI clients (gateway.auth.token):
#   sudo grep OPENCLAW_GATEWAY_TOKEN $CONFIG_DIR/openclaw.env
OPENCLAW_GATEWAY_TOKEN=$TOKEN
PORT=18789
# Keep the loopback default and reach the UI with an SSH tunnel or Tailscale Serve.
# Bind/auth/provider/model: ~/.openclaw/openclaw.json — see docs/11-openclaw.md
EOF
  echo "wrote $OPENCLAW_ENV"
else
  echo "$OPENCLAW_ENV exists, left untouched"
fi

chown "$TARGET_USER:$TARGET_USER" "$CONFIG_DIR"/*.env
chmod 600 "$CONFIG_DIR"/*.env

# ---- openclaw binary --------------------------------------------------------
# npm's global bin directory is not on systemd's default PATH, so the unit needs the
# absolute path substituted. A login shell also covers nvm/volta installations.
OPENCLAW_BIN="$(sudo -u "$TARGET_USER" bash -lc 'command -v openclaw' 2>/dev/null || true)"
if [ -z "$OPENCLAW_BIN" ] && [ -x /usr/local/bin/openclaw ]; then
  OPENCLAW_BIN=/usr/local/bin/openclaw
fi

# ---- render units -----------------------------------------------------------
say "Installing units into $UNIT_DIR"
for unit in llama-server llama-router comfyui ai-discord-bot openclaw-gateway; do
  if [ "$unit" = openclaw-gateway ] && [ -z "$OPENCLAW_BIN" ]; then
    echo "skipped openclaw-gateway: openclaw not installed (scripts/60-install-openclaw.sh)"
    continue
  fi
  src="$REPO/systemd/${unit}.service"
  [ -f "$src" ] || die "missing $src"
  sed -e "s|__USER__|$TARGET_USER|g" \
      -e "s|__HOME__|$TARGET_HOME|g" \
      -e "s|__AI_HOME__|$AI_HOME|g" \
      -e "s|__REPO__|$REPO|g" \
      -e "s|__CONFIG_DIR__|$CONFIG_DIR|g" \
      -e "s|__OPENCLAW_BIN__|$OPENCLAW_BIN|g" \
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

if [ -z "$OPENCLAW_BIN" ]; then
  echo "skipped openclaw-gateway: not installed (scripts/60-install-openclaw.sh, docs/11)"
elif [ -f "$TARGET_HOME/.openclaw/openclaw.json" ]; then
  systemctl enable openclaw-gateway.service
  systemctl restart openclaw-gateway.service || true
  echo "openclaw-gateway enabled (Control UI on 127.0.0.1:18789, token in openclaw.env)"
else
  echo "skipped openclaw-gateway: installed but not onboarded — run: openclaw onboard"
fi

cat <<EOF

Status:
  systemctl status llama-server comfyui ai-discord-bot openclaw-gateway --no-pager
  journalctl -u llama-server -f

Endpoints:
  http://127.0.0.1:8080/health        llama.cpp
  http://127.0.0.1:8080               llama.cpp chat UI (MCP tools), over the SSH tunnel
  http://127.0.0.1:8188               ComfyUI
  http://127.0.0.1:18789              OpenClaw Control UI (token in openclaw.env)

Multi-model (every GGUF in $AI_HOME/models, one port):
  sudo systemctl disable --now llama-server
  sudo systemctl enable --now llama-router
  curl -s localhost:8080/models | jq
EOF
