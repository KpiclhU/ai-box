#!/usr/bin/env bash
# 20-install-llama.sh — build llama.cpp for gfx1151.
#
#   ./scripts/20-install-llama.sh rocm     # HIP build (default; best prompt processing)
#   ./scripts/20-install-llama.sh vulkan   # Vulkan build (often better decode tok/s)
#   ./scripts/20-install-llama.sh both
#
# Both builds land side by side, so you can benchmark them against each other.
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
SRC="$AI_HOME/llama.cpp"
BACKEND="${1:-rocm}"
JOBS="${JOBS:-$(nproc)}"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v git   >/dev/null || die "git missing: sudo apt install git"
command -v cmake >/dev/null || die "cmake missing: sudo apt install cmake"
command -v ninja >/dev/null || command -v make >/dev/null || die "ninja or make required"

case "$BACKEND" in
  rocm|vulkan|both) ;;
  *) die "unknown backend '$BACKEND' (expected rocm, vulkan or both)" ;;
esac

if [ "$BACKEND" = "rocm" ] || [ "$BACKEND" = "both" ]; then
  if ! command -v hipcc >/dev/null; then
    cat >&2 <<'EOF'
error: hipcc not found. The HIP build needs the ROCm user-space toolchain.

  sudo apt install -y "linux-headers-$(uname -r)"
  wget https://repo.radeon.com/amdgpu-install/latest/ubuntu/noble/amdgpu-install_*_all.deb
  sudo apt install -y ./amdgpu-install_*_all.deb
  sudo amdgpu-install -y --usecase=rocm --no-dkms
  sudo usermod -aG render,video "$(id -un)"  # then log out and back in

Check the current ROCm install page for your distro's repo path if the URL 404s.
Then re-run this script, or use the Vulkan backend instead:
  ./scripts/20-install-llama.sh vulkan
EOF
    exit 1
  fi
fi

if [ "$BACKEND" = "vulkan" ] || [ "$BACKEND" = "both" ]; then
  command -v glslc >/dev/null || echo "warning: glslc not found (apt install glslc) — the Vulkan build will fail" >&2
fi

say "Source"
if [ -d "$SRC/.git" ]; then
  git -C "$SRC" fetch --depth=1 origin master
  git -C "$SRC" reset --hard origin/master
  echo "updated $SRC to $(git -C "$SRC" rev-parse --short HEAD)"
else
  mkdir -p "$AI_HOME"
  git clone --depth=1 https://github.com/ggml-org/llama.cpp "$SRC"
  echo "cloned into $SRC"
fi

build() {
  local name="$1" dir="$2"; shift 2
  say "Configuring $name build"
  cmake -S "$SRC" -B "$dir" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLAMA_CURL=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    "$@"
  say "Building $name ($JOBS jobs)"
  cmake --build "$dir" -j"$JOBS" --target llama-server llama-cli llama-bench
  local bin="$dir/bin/llama-server"
  [ -x "$bin" ] || die "build finished but $bin is missing"
  echo "built: $bin"
}

if [ "$BACKEND" = "rocm" ] || [ "$BACKEND" = "both" ]; then
  build rocm "$SRC/build" -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151
fi

if [ "$BACKEND" = "vulkan" ] || [ "$BACKEND" = "both" ]; then
  build vulkan "$SRC/build-vulkan" -DGGML_VULKAN=ON
fi

say "Smoke test"
if [ "$BACKEND" = "vulkan" ]; then
  BIN="$SRC/build-vulkan/bin/llama-server"
else
  BIN="$SRC/build/bin/llama-server"
fi
if [ -x "$BIN" ]; then
  "$BIN" --version 2>&1 | head -5 || true
fi

cat <<EOF

Next:
  1. get a model:   ./scripts/60-download-models.sh coder-q6
  2. install units: sudo ./scripts/50-install-services.sh
  3. check:         curl -s localhost:8080/health && ./scripts/90-bench.sh
EOF
