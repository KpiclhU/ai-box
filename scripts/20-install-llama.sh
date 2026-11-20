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

# llama-server downloads GGUFs itself (-hf, POST /models, the UI's model manager) with
# its own HTTPS client. CMake still builds without OpenSSL headers, but the binary then
# refuses every https:// request and the download dies as "resolves no file to download".
if ! pkg-config --exists openssl 2>/dev/null && [ ! -f /usr/include/openssl/ssl.h ]; then
  echo "warning: OpenSSL development headers not found (sudo apt install libssl-dev)." >&2
  echo "         The build will work, but -hf and web-UI downloads will fail with" >&2
  echo "         'HTTPS is not supported'. Install them first if you want those." >&2
fi

case "$BACKEND" in
  rocm|vulkan|both) ;;
  *) die "unknown backend '$BACKEND' (expected rocm, vulkan or both)" ;;
esac

if [ "$BACKEND" = "rocm" ] || [ "$BACKEND" = "both" ]; then
  # Locate a usable ROCm tree. ROCm 10.x installs the real thing under
  # /opt/rocm/core-<ver>/ and keeps /opt/rocm/{bin,lib,llvm} as update-alternatives,
  # which can lag behind or still point at an older release.
  ROCM_ROOT=""
  for prefix in "${ROCM_PATH:-}" "$(hipconfig -R 2>/dev/null || true)" /opt/rocm/core-* /opt/rocm; do
    [ -n "$prefix" ] && [ -d "$prefix" ] || continue
    if [ -x "$prefix/lib/llvm/bin/hipcc" ] || [ -x "$prefix/bin/hipcc" ]; then
      ROCM_ROOT="$prefix"
      break
    fi
  done
  # hipcc is not on PATH in every non-login shell (systemd units, `ssh box cmd`).
  for d in "$ROCM_ROOT/bin" "$ROCM_ROOT/lib/llvm/bin"; do
    [ -n "$ROCM_ROOT" ] && [ -d "$d" ] && PATH="$d:$PATH"
  done
  if [ -n "$ROCM_ROOT" ]; then
    export PATH ROCM_PATH="$ROCM_ROOT" HIP_PATH="$ROCM_ROOT"
  fi

  if ! command -v hipcc >/dev/null; then
    codename="$(. /etc/os-release 2>/dev/null && printf '%s' "${VERSION_CODENAME:-}" || true)"
    codename="${codename:-noble}"
    cat >&2 <<EOF
error: hipcc not found. The HIP build needs the ROCm user-space toolchain.

  sudo apt install -y "linux-headers-\$(uname -r)"
  codename=\$(. /etc/os-release; echo "\$VERSION_CODENAME")     # ${codename} on this box
  url=https://repo.radeon.com/amdgpu-install/latest/ubuntu/\$codename
  file=\$(wget -qO- "\$url/" | grep -o 'amdgpu-install_[0-9.]*-1_all\.deb' | head -1)
  wget "\$url/\$file"
  sudo apt install -y "./\$file"
  sudo amdgpu-install -y --usecase=rocm --no-dkms
  sudo usermod -aG render,video "\$(id -un)"   # then log out and back in

Two reasons the obvious command 404s:
  - the repo path is the distro codename (jammy 22.04, noble 24.04, resolute 26.04),
    not "latest" nor another release's codename;
  - wget does not expand URL wildcards, so amdgpu-install_*_all.deb requests a literal '*'.
Directory listing: https://repo.radeon.com/amdgpu-install/latest/ubuntu/

Then re-run this script, or use the Vulkan backend instead (no sudo, no ROCm):
  ./scripts/20-install-llama.sh vulkan
EOF
    exit 1
  fi

  # The HIP runtime alone is not enough: CMake's HIP language support needs
  # hip-lang-config.cmake, packaged separately from the runtime in ROCm 10.x.
  hip_lang=""
  for root in "$ROCM_ROOT" /opt/rocm/core-* /opt/rocm; do
    [ -n "$root" ] && [ -d "$root" ] || continue
    for sub in lib lib64; do
      if [ -f "$root/$sub/cmake/hip-lang/hip-lang-config.cmake" ]; then
        hip_lang="$root/$sub/cmake/hip-lang/hip-lang-config.cmake"
        ROCM_ROOT="$root"
        break 2
      fi
    done
  done
  if [ -z "$hip_lang" ]; then
    cat >&2 <<EOF
error: hipcc is installed but the HIP CMake package is not.

CMake stops with "The ROCm root directory ... does not contain the HIP runtime CMake
package" when hip-lang-config.cmake is absent. On ROCm 10.x that file ships in a
separate development package, which 'amdgpu-install --usecase=rocm' can leave out;
the ROCm path in the error is correct, the package is missing.

  apt-cache search '^amdrocm' | grep -E 'dev|devel'
  sudo apt install amdrocm-core-dev<version>-gfx1151    # name from the search above
  ls /opt/rocm/core-*/lib/cmake/hip-lang/hip-lang-config.cmake    # must exist

Looked in ${ROCM_ROOT:-/opt/rocm} and /opt/rocm/core-*.
If an older ROCm is still installed, /opt/rocm/bin,lib,llvm may be stale alternatives:
  update-alternatives --display rocm-lib

The Vulkan backend needs none of this:
  ./scripts/20-install-llama.sh vulkan
EOF
    exit 1
  fi
  echo "ROCm root: $ROCM_ROOT"
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
    -DLLAMA_OPENSSL=ON \
    -DLLAMA_BUILD_TESTS=OFF \
    "$@"
  say "Building $name ($JOBS jobs)"
  cmake --build "$dir" -j"$JOBS" --target llama-server llama-cli llama-bench
  local bin="$dir/bin/llama-server"
  [ -x "$bin" ] || die "build finished but $bin is missing"
  echo "built: $bin"
}

if [ "$BACKEND" = "rocm" ] || [ "$BACKEND" = "both" ]; then
  build rocm "$SRC/build" -DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1151 \
    -DCMAKE_PREFIX_PATH="$ROCM_ROOT" -DCMAKE_HIP_COMPILER_ROCM_ROOT="$ROCM_ROOT"
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
  1. get a model:   hf download <repo> --include '<glob>' --local-dir ~/ai/models  (docs/07)
  2. install units: sudo ./scripts/50-install-services.sh
  3. check:         curl -s localhost:8080/health && ./scripts/90-bench.sh
EOF
