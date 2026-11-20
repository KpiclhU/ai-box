#!/usr/bin/env bash
# 00-preflight.sh — read-only health report for an ai-box install.
# Nothing here changes state. Run it before and after each phase.
#
#   ./scripts/00-preflight.sh
set -uo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mfail\033[0m  %s\n' "$*"; }
info() { printf '  .....  %s\n' "$*"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

pages_to_gib() { awk -v p="${1:-0}" 'BEGIN { printf "%.1f", p * 4096 / 1073741824 }'; }

head_ "Host"
printf '  kernel    %s\n' "$(uname -r)"
printf '  distro    %s\n' "$( (. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME") || echo unknown)"
printf '  cpu       %s\n' "$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null || echo unknown)"
printf '  memory    %s\n' "$(awk '/MemTotal/{printf "%.0f GiB total, %.0f GiB available\n", $2/1048576, $7/1048576}' /proc/meminfo)"
printf '  ai home   %s\n' "$AI_HOME"

head_ "Kernel requirements"
kmaj=$(uname -r | cut -d. -f1)
kmin=$(uname -r | cut -d. -f2)
if [ "$kmaj" -gt 6 ] || { [ "$kmaj" -eq 6 ] && [ "$kmin" -ge 18 ]; }; then
  ok "kernel >= 6.18 (ROCm Strix Halo fixes present)"
elif [ "$kmaj" -eq 6 ] && [ "$kmin" -ge 15 ]; then
  warn "kernel 6.15-6.17: desktop works, ROCm may hit KFD bugs — prefer >= 6.18.4"
else
  bad "kernel too old for gfx1151 — upgrade before installing anything"
fi

head_ "GPU"
if lspci -nn 2>/dev/null | grep -qiE 'vga|display'; then
  lspci -nn | grep -iE 'vga|display' | sed 's/^/  .....  /'
  if lspci -nn | grep -qi '1002'; then ok "AMD display device present"; else warn "no AMD display device found"; fi
else
  bad "lspci found nothing (is pciutils installed?)"
fi

[ -e /dev/kfd ] && ok "/dev/kfd present" || bad "/dev/kfd missing — amdgpu/KFD did not initialise (ROCm will not work)"
ls /dev/dri/renderD* >/dev/null 2>&1 && ok "render nodes: $(ls /dev/dri/renderD* | tr '\n' ' ')" || bad "no /dev/dri/renderD* nodes"

# $USER is not always set (sudo -i, systemd, some SSH setups); ask the kernel instead.
ME="$(id -un)"
if id -nG "$ME" | tr ' ' '\n' | grep -qxE 'render|video'; then
  ok "$ME is in render/video groups"
else
  warn "$ME not in render/video — run: sudo usermod -aG render,video $ME (then log out)"
fi

head_ "GPU-addressable memory"
if [ -r /sys/module/ttm/parameters/pages_limit ]; then
  pl=$(cat /sys/module/ttm/parameters/pages_limit)
  pp=$(cat /sys/module/ttm/parameters/page_pool_size 2>/dev/null || echo "?")
  gib=$(pages_to_gib "$pl")
  if [ "${pl:-0}" -ge 11000000 ] 2>/dev/null; then
    ok "ttm.pages_limit=$pl (~${gib} GiB), page_pool_size=$pp"
  else
    warn "ttm.pages_limit=$pl (~${gib} GiB) — that is near the 50% default"
    warn "run: sudo ./scripts/10-gpu-memory.sh 48 && sudo reboot"
  fi
else
  warn "cannot read ttm parameters (kernel module name may differ)"
fi
grep -q 'ttm.pages_limit' /proc/cmdline && info "cmdline: $(grep -o 'ttm\.[a-z_]*=[0-9]*' /proc/cmdline | tr '\n' ' ')" || info "no ttm.* on kernel cmdline"

head_ "Graphics / compute stack"
# GUI probes need a session. Over SSH $DISPLAY and $WAYLAND_DISPLAY are unset, so
# glxinfo fails with "unable to open display" — that says nothing about the GPU.
# Judge the device from the kernel, and only run GL checks when there is a session.
if [ -d /sys/class/drm ]; then
  for card in /sys/class/drm/card[0-9]*; do
    [ -e "$card/device/vendor" ] || continue
    vendor=$(cat "$card/device/vendor" 2>/dev/null)
    device=$(cat "$card/device/device" 2>/dev/null)
    driver=$(basename "$(readlink -f "$card/device/driver" 2>/dev/null)")
    if [ "$vendor" = "0x1002" ]; then
      ok "$(basename "$card"): AMD $vendor:$device driver=${driver:-none}"
    else
      info "$(basename "$card"): $vendor:$device driver=${driver:-none}"
    fi
  done
fi

if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
  if command -v glxinfo >/dev/null; then
    renderer=$(glxinfo -B 2>/dev/null | grep -m1 'OpenGL renderer' | sed 's/.*: *//')
    [ -n "$renderer" ] && ok "GL renderer: $renderer" || warn "glxinfo ran but reported no renderer"
  else
    info "glxinfo not installed (apt install mesa-utils) — optional"
  fi
else
  info "no display session (DISPLAY/WAYLAND_DISPLAY unset) — skipping GL check"
fi

if command -v vulkaninfo >/dev/null; then
  dev=$(vulkaninfo --summary 2>/dev/null | grep -m1 -i 'deviceName' | sed 's/.*= *//')
  if [ -n "$dev" ]; then
    ok "Vulkan device: $dev"
  elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    warn "vulkaninfo found no device"
  else
    info "vulkaninfo listed no device without a display session — usually harmless over SSH"
  fi
else
  info "vulkaninfo not installed (apt install vulkan-tools)"
fi
command -v rocminfo >/dev/null && { rocminfo 2>/dev/null | grep -q gfx1151 && ok "rocminfo sees gfx1151" || warn "rocminfo present but no gfx1151 agent"; } || warn "ROCm not installed (needed for the HIP build and ComfyUI)"
command -v rocm-smi >/dev/null && ok "rocm-smi present" || info "rocm-smi not present"

head_ "Software"
for bin in git cmake ninja hipcc glslc jq; do
  command -v "$bin" >/dev/null 2>&1 && info "$bin: $(command -v "$bin")" || warn "$bin missing"
done
[ -x "$AI_HOME/llama.cpp/build/bin/llama-server" ] && ok "llama-server (rocm build) present" || warn "no llama-server at $AI_HOME/llama.cpp/build/bin"
[ -x "$AI_HOME/llama.cpp/build-vulkan/bin/llama-server" ] && ok "llama-server (vulkan build) present" || true
[ -x "$AI_HOME/comfyui/.venv/bin/python" ] && ok "ComfyUI venv present" || warn "no ComfyUI venv at $AI_HOME/comfyui/.venv"

head_ "Models on disk"
if [ -d "$AI_HOME/models" ]; then
  found=0
  while IFS= read -r f; do
    found=1
    info "$(du -h "$f" | cut -f1)  $f"
  done < <(find "$AI_HOME/models" -maxdepth 1 -name '*.gguf' -size +100M 2>/dev/null | head -10)
  [ "$found" -eq 0 ] && warn "no GGUF files in $AI_HOME/models"
else
  warn "$AI_HOME/models does not exist yet"
fi
[ -d "$AI_HOME/comfyui/models/checkpoints" ] && info "checkpoints: $(find "$AI_HOME/comfyui/models/checkpoints" -maxdepth 1 \( -name '*.safetensors' -o -name '*.ckpt' \) 2>/dev/null | wc -l) file(s)"

head_ "Services"
for unit in llama-server comfyui ai-discord-bot; do
  if systemctl list-unit-files "${unit}.service" >/dev/null 2>&1 && systemctl cat "${unit}.service" >/dev/null 2>&1; then
    state=$(systemctl is-active "${unit}.service" 2>/dev/null || true)
    case "$state" in
      active) ok "$unit: active" ;;
      *)      warn "$unit: ${state:-unknown}" ;;
    esac
  else
    info "$unit: not installed"
  fi
done

head_ "Live endpoints"
if command -v curl >/dev/null; then
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8080/health || echo 000)
  [ "$code" = "200" ] && ok "llama-server http://127.0.0.1:8080/health -> $code" || info "llama-server health -> $code"
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://127.0.0.1:8188/system_stats || echo 000)
  [ "$code" = "200" ] && ok "ComfyUI http://127.0.0.1:8188 -> $code" || info "ComfyUI -> $code"
fi

head_ "Disk"
df -h "$AI_HOME" 2>/dev/null | tail -1 | awk '{printf "  .....  %s avail on %s\n", $4, $6}'

printf '\n'
[ -e /dev/kfd ] && ok "preflight complete" || warn "preflight complete, but /dev/kfd is missing — fix that first"
