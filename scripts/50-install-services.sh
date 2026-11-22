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

# ---- openwebui env ----------------------------------------------------------
# The front door. It talks to llama-server and ComfyUI over loopback, so neither of
# those needs to leave the box. WEBUI_URL is the origin the Caddy VM publishes.
OPENWEBUI_ENV="$CONFIG_DIR/openwebui.env"
PUBLIC_URL="${AI_BOX_PUBLIC_URL:-https://ai.pilchlab.ca}"

# Open WebUI creates this account on its first start, while ENABLE_SIGNUP stays
# false. Relying on the first sign-up page is version-dependent: older releases
# gate it on ENABLE_SIGNUP and lock you out. WEBUI_ADMIN_* is not.
ADMIN_EMAIL="${OPENWEBUI_ADMIN_EMAIL:-admin@ai-box.local}"
ADMIN_NAME="${OPENWEBUI_ADMIN_NAME:-Admin}"
ADMIN_PASSWORD="${OPENWEBUI_ADMIN_PASSWORD:-}"
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(openssl rand -hex 12 2>/dev/null || head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi

# The shipped SDXL graph, minified onto one line so systemd can read it back as
# one value. Open WebUI overwrites the model node with IMAGE_GENERATION_MODEL,
# so an empty model would send ckpt_name="" and fail the first image.
WORKFLOW_FILE="$REPO/workflows/openwebui-sdxl.api.json"
WORKFLOW_JSON=""
if [ -f "$WORKFLOW_FILE" ] && command -v python3 >/dev/null 2>&1; then
  WORKFLOW_JSON="$(python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), separators=(",",":")))' "$WORKFLOW_FILE" 2>/dev/null || true)"
fi
# No negative_prompt mapping: the inline chat path sends null for it, and ComfyUI
# rejects null for a STRING input. The graph carries its own negative prompt.
COMFY_NODES_JSON='[{"type":"prompt","key":"text","node_ids":["6"]},{"type":"model","key":"ckpt_name","node_ids":["4"]},{"type":"width","key":"width","node_ids":["5"]},{"type":"height","key":"height","node_ids":["5"]},{"type":"steps","key":"steps","node_ids":["3"]},{"type":"seed","key":"seed","node_ids":["3"]}]'

if [ ! -f "$OPENWEBUI_ENV" ]; then
  SECRET="$(openssl rand -hex 32 2>/dev/null || head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
  cat > "$OPENWEBUI_ENV" <<EOF
# Open WebUI. Edit and: systemctl restart open-webui
# Loopback until 81-front-door.sh has a default-deny firewall covering :3000; it
# adds the rule first and then flips this to 0.0.0.0 for the Caddy VM. Do not set
# 0.0.0.0 by hand: this port has no authentication gate of its own in front of it
# other than Open WebUI's login, and nothing else on this box faces the LAN.
HOST=127.0.0.1
PORT=3000
# Keep this secret. Changing it logs every user out.
WEBUI_SECRET_KEY=$SECRET
WEBUI_URL=$PUBLIC_URL
# The first account. Created at startup while sign-ups stay off; the password
# line is removed once the account exists. Change the password after signing in.
WEBUI_ADMIN_EMAIL=$ADMIN_EMAIL
WEBUI_ADMIN_PASSWORD=$ADMIN_PASSWORD
WEBUI_ADMIN_NAME=$ADMIN_NAME
# Accounts are created by the admin; nobody self-registers.
ENABLE_SIGNUP=false
# Per-user API keys, used by openGym and scripts through the /openai endpoint.
ENABLE_API_KEYS=true
ENABLE_VERSION_UPDATE_CHECK=false
ENABLE_OLLAMA_API=false
DATA_DIR=$AI_HOME/data/openwebui
# Image generation: ComfyUI on this box. Workflows and node maps: docs/12.
ENABLE_IMAGE_GENERATION=true
IMAGE_GENERATION_ENGINE=comfyui
COMFYUI_BASE_URL=http://127.0.0.1:8188
IMAGE_GENERATION_MODEL=sd_xl_base_1.0.safetensors
IMAGE_SIZE=1024x1024
IMAGE_STEPS=28
EOF
  if [ -n "$WORKFLOW_JSON" ]; then
    {
      echo "# Shipped SDXL graph and node map, so the first image needs no import."
      printf 'COMFYUI_WORKFLOW=%s\n' "$WORKFLOW_JSON"
      printf 'COMFYUI_WORKFLOW_NODES=%s\n' "$COMFY_NODES_JSON"
    } >> "$OPENWEBUI_ENV"
  else
    echo "warning: could not read $WORKFLOW_FILE — import the workflow in Admin -> Settings -> Images" >&2
  fi
  echo "wrote $OPENWEBUI_ENV"
else
  echo "$OPENWEBUI_ENV exists, left untouched"
fi

chown "$TARGET_USER:$TARGET_USER" "$CONFIG_DIR"/*.env
chmod 600 "$CONFIG_DIR"/*.env

# Chat history, users and settings live here, not in the venv.
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 700 "$AI_HOME/data/openwebui"

# ---- render units -----------------------------------------------------------
say "Installing units into $UNIT_DIR"
for unit in llama-server llama-router comfyui open-webui; do
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

if [ -x "$AI_HOME/openwebui/venv/bin/open-webui" ]; then
  systemctl enable open-webui.service
  systemctl restart open-webui.service || true
  echo "open-webui enabled (127.0.0.1:3000; publish with scripts/81-front-door.sh)"

  if grep -q '^WEBUI_ADMIN_PASSWORD=' "$OPENWEBUI_ENV" 2>/dev/null; then
    echo
    echo "Open WebUI admin, created on this first start:"
    echo "  email    $(sed -n 's/^WEBUI_ADMIN_EMAIL=//p' "$OPENWEBUI_ENV" | tail -1)"
    echo "  password $(sed -n 's/^WEBUI_ADMIN_PASSWORD=//p' "$OPENWEBUI_ENV" | tail -1)"
    echo "  (change it after signing in; it is only read while no user exists)"

    # /api/config carries "onboarding" only while no user exists. Once that key
    # is gone the account is there, so the bootstrap password can leave the file.
    if command -v curl >/dev/null 2>&1; then
      OW_PORT="$(sed -n 's/^PORT=//p' "$OPENWEBUI_ENV" | tail -1)"
      OW_PORT="${OW_PORT:-3000}"
      cfg=""
      for _ in $(seq 1 30); do
        cfg="$(curl -s --max-time 2 "http://127.0.0.1:$OW_PORT/api/config" 2>/dev/null || true)"
        [ -n "$cfg" ] && break
        sleep 2
      done
      if [ -n "$cfg" ] && ! printf '%s' "$cfg" | grep -q '"onboarding"'; then
        sed -i '/^WEBUI_ADMIN_PASSWORD=/d' "$OPENWEBUI_ENV"
        chown "$TARGET_USER:$TARGET_USER" "$OPENWEBUI_ENV" 2>/dev/null || true
        chmod 600 "$OPENWEBUI_ENV" 2>/dev/null || true
        echo "  admin account confirmed; removed the bootstrap password from openwebui.env"
      elif [ -n "$cfg" ]; then
        echo "  warning: the service is up but has no account yet. A cold first start"
        echo "  can take a minute; re-run this script to look again, or check:"
        echo "    journalctl -u open-webui -n 80 --no-pager"
      else
        echo "  warning: could not confirm the admin account; check:"
        echo "    systemctl status open-webui --no-pager"
      fi
    fi
  fi
else
  echo "skipped open-webui: run ./scripts/45-install-openwebui.sh first"
fi

cat <<EOF

Status:
  systemctl status llama-server comfyui open-webui --no-pager
  journalctl -u llama-server -f

Endpoints:
  http://127.0.0.1:3000               Open WebUI — chat and images (the front door)
  http://127.0.0.1:8080/health        llama.cpp
  http://127.0.0.1:8080               llama.cpp's own chat UI, admin/debug over SSH
  http://127.0.0.1:8188               ComfyUI, admin only over SSH (no auth of its own)

Publish through the Caddy VM:
  sudo ./scripts/81-front-door.sh --caddy-ip <caddy-ip> --hostname <name>

Multi-model (every GGUF in $AI_HOME/models, one port):
  sudo systemctl disable --now llama-server
  sudo systemctl enable --now llama-router
  curl -s localhost:8080/models | jq
EOF
