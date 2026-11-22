#!/usr/bin/env bash
# 30-install-comfyui.sh — ComfyUI in a venv with ROCm PyTorch wheels.
#
#   ./scripts/30-install-comfyui.sh
#
# The wheel index is the part that matters: rocm6.x wheels contain no gfx1151
# kernels and produce "HIP error: invalid device function".
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
COMFY="$AI_HOME/comfyui"
PY_INDEX="${PY_INDEX:-https://download.pytorch.org/whl/rocm7.2}"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v git >/dev/null || die "git missing"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
  || die "Python 3.10+ required (python3 --version)"
python3 -m venv --help >/dev/null 2>&1 || die "python3-venv missing: sudo apt install python3-venv"

say "Source"
if [ -d "$COMFY/.git" ]; then
  git -C "$COMFY" fetch --depth=1 origin master
  git -C "$COMFY" reset --hard origin/master
  echo "updated $COMFY to $(git -C "$COMFY" rev-parse --short HEAD)"
else
  mkdir -p "$AI_HOME"
  git clone https://github.com/comfyanonymous/ComfyUI "$COMFY"
fi

say "Python environment"
if [ ! -x "$COMFY/.venv/bin/python" ]; then
  python3 -m venv "$COMFY/.venv"
fi
# shellcheck disable=SC1091
. "$COMFY/.venv/bin/activate"
python -m pip install --upgrade pip wheel

say "PyTorch (ROCm)"
if [ -f "$COMFY/constraints.txt" ]; then
  echo "using pinned constraints from a previous successful install"
  pip install -c "$COMFY/constraints.txt" torch torchvision torchaudio --index-url "$PY_INDEX"
else
  pip install torch torchvision torchaudio --index-url "$PY_INDEX"
fi

say "ComfyUI requirements"
pip install -r "$COMFY/requirements.txt"

say "Verify"
python - <<'PY'
import sys, torch
print("torch     ", torch.__version__)
print("hip       ", torch.version.hip)
print("available ", torch.cuda.is_available())
if not torch.cuda.is_available():
    sys.exit("torch cannot see the GPU. Usually: wrong wheel index (need rocm7.2+), "
             "kernel older than 6.18.4, or /dev/kfd not accessible (render/video groups).")
print("device    ", torch.cuda.get_device_name(0))
PY

say "Model directories"
mkdir -p "$COMFY/models"/{checkpoints,diffusion_models,text_encoders,vae,unet,loras,upscale_models,clip_vision}
echo "ready: $COMFY/models"

# A working pin set is worth more than a fresh resolve next time.
if [ ! -f "$COMFY/constraints.txt" ]; then
  pip freeze > "$COMFY/constraints.txt"
  echo "pinned installed versions to $COMFY/constraints.txt"
fi

cat <<EOF

Next:
  1. Put the checkpoint the shipped workflow expects in $COMFY/models/checkpoints
     (./scripts/96-comfy-models.sh download stabilityai/stable-diffusion-xl-base-1.0 \
        'sd_xl_base_1.0.safetensors' checkpoints  does it)
     That repo is gated: accept its licence on the Hugging Face page and run
     'hf auth login' once first, or the download answers 401.
  2. sudo ./scripts/50-install-services.sh
  3. open http://127.0.0.1:8188 and generate once by hand — the first run compiles
     kernels and can take 10-25 minutes. Do not kill it.
EOF
