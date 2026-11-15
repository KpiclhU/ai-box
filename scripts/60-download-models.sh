#!/usr/bin/env bash
# 60-download-models.sh — pull model weights from Hugging Face.
#
#   ./scripts/60-download-models.sh --list
#   ./scripts/60-download-models.sh coder-q6        # ~25 GB, coding default
#   ./scripts/60-download-models.sh chat-q4         # ~18 GB, Discord chat
#   ./scripts/60-download-models.sh sdxl            # ~7 GB, into ComfyUI
#   ./scripts/60-download-models.sh <repo> '<glob>' # anything else
#
# Filenames inside GGUF repos change between quant uploads, so presets use globs.
# Always glance at the repo's file list before a 25 GB pull.
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
MODELS="$AI_HOME/models"
COMFY_CKPT="$AI_HOME/comfyui/models/checkpoints"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

list_presets() {
  cat <<'EOF'
preset       repo                                          glob            approx   destination
coder-q6     unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF     *Q6_K*          ~25 GB   ~/ai/models
coder-q4     unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF     *Q4_K*          ~18 GB   ~/ai/models
chat-q4      unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF      *Q4_K_M*        ~18 GB   ~/ai/models
gpt-oss-20b  ggml-org/gpt-oss-20b-GGUF                     *MXFP4*         ~12 GB   ~/ai/models
sdxl         stabilityai/stable-diffusion-xl-base-1.0      sd_xl_base_1.0  ~7 GB    ComfyUI/checkpoints
flux-schnell city96/FLUX.1-schnell-gguf                    *Q8*            ~13 GB   ~/ai/models
EOF
}

CLI=""
if command -v hf >/dev/null 2>&1; then
  CLI="hf"
elif command -v huggingface-cli >/dev/null 2>&1; then
  CLI="huggingface-cli"
fi

if [ "${1:-}" = "--list" ] || [ "${1:-}" = "-l" ] || [ "$#" -eq 0 ]; then
  list_presets
  [ -z "$CLI" ] && cat <<'EOF'

huggingface CLI not found. Install it with one of:
  pipx install "huggingface_hub[cli]"
  python3 -m venv ~/.venvs/hf && ~/.venvs/hf/bin/pip install "huggingface_hub[cli]"
EOF
  exit 0
fi

[ -n "$CLI" ] || { echo "error: install huggingface_hub CLI first (pipx install 'huggingface_hub[cli]')" >&2; exit 1; }

preset="$1"
repo=""
glob=""
dest=""

case "$preset" in
  coder-q6)     repo="unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"; glob="*Q6_K*";        dest="$MODELS" ;;
  coder-q4)     repo="unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF"; glob="*Q4_K*";        dest="$MODELS" ;;
  chat-q4)      repo="unsloth/Qwen3-30B-A3B-Instruct-2507-GGUF";  glob="*Q4_K_M*";      dest="$MODELS" ;;
  gpt-oss-20b)  repo="ggml-org/gpt-oss-20b-GGUF";                 glob="*MXFP4*";       dest="$MODELS" ;;
  sdxl)         repo="stabilityai/stable-diffusion-xl-base-1.0";  glob="sd_xl_base_1.0"; dest="$COMFY_CKPT" ;;
  flux-schnell) repo="city96/FLUX.1-schnell-gguf";                glob="*Q8*";          dest="$MODELS" ;;
  *)
    repo="$1"
    glob="${2:-}"
    dest="${3:-$MODELS}"
    [ -n "$glob" ] || { echo "usage: $0 <repo> '<glob>' [dest]" >&2; exit 1; }
    ;;
esac

mkdir -p "$dest"

# Gated repos (Flux.1-dev) need a token; without one the download fails with 401.
if [ -z "${HF_TOKEN:-}" ] && [ ! -f "$HOME/.cache/huggingface/token" ]; then
  echo "note: no Hugging Face token found. Public repos work; gated ones need: hf auth login"
fi

say "Downloading $repo"
echo "glob: $glob"
echo "dest: $dest"
echo

if [ "$CLI" = "hf" ]; then
  hf download "$repo" --include "$glob" --local-dir "$dest"
else
  huggingface-cli download "$repo" --include "$glob" --local-dir "$dest"
fi

say "Done"
find "$dest" -maxdepth 2 -newermt '-2 hours' \( -name '*.gguf' -o -name '*.safetensors' \) \
  -printf '%s\t%p\n' 2>/dev/null | awk -F'\t' '{printf "  %.1f GB  %s\n", $1/1073741824, $2}' || true

cat <<'EOF'

Next:
  - point llama-server at it:  $EDITOR ~/.config/ai-box/llama-server.env
                               systemctl restart llama-server
  - SDXL checkpoints go in ~/ai/comfyui/models/checkpoints/ automatically
EOF
