#!/usr/bin/env bash
# 90-bench.sh — measure this machine instead of trusting a table.
#
#   ./scripts/90-bench.sh                       # uses MODEL from the service env
#   ./scripts/90-bench.sh ~/ai/models/x.gguf
#
# Runs llama-bench for every build present (rocm, vulkan) and appends results to
# bench/YYYY-MM-DD.md. Stop llama-server first: it already holds the model in GTT.
# Override the check with BENCH_ALLOW_BUSY=1.
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/bench/$(date +%F).md"
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ai-box/llama-server.env"

MODEL="${1:-${MODEL:-}}"
if [ -z "$MODEL" ] && [ -f "$ENV_FILE" ]; then
  # Read just MODEL= instead of sourcing the file: it also holds values with spaces
  # (LLAMA_EXTRA_ARGS="--ctx-size 32768 ...") that must not be executed by a shell.
  MODEL="$(sed -n 's/^[[:space:]]*MODEL=//p' "$ENV_FILE" | head -n 1)"
  MODEL="${MODEL%$'\r'}"
  MODEL="${MODEL%\"}"; MODEL="${MODEL#\"}"
  MODEL="${MODEL%\'}"; MODEL="${MODEL#\'}"
  case "$MODEL" in
    '~/'*) MODEL="$HOME/${MODEL#\~/}" ;;
  esac
fi
[ -n "$MODEL" ] && [ -f "$MODEL" ] || {
  echo "usage: $0 /path/to/model.gguf    (or set MODEL in $ENV_FILE)" >&2
  exit 1
}

# A running server already holds a model in GTT, so a second copy will fail to allocate
# even though "Total VRAM" is reported as the full GTT limit.
if [ "${BENCH_ALLOW_BUSY:-0}" != "1" ] && command -v systemctl >/dev/null 2>&1; then
  for unit in llama-server llama-router; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
      echo "$unit is running and holds a model in GPU memory." >&2
      echo "  stop it first:  sudo systemctl stop $unit" >&2
      echo "  start it again: sudo systemctl start $unit" >&2
      echo "  measure anyway: BENCH_ALLOW_BUSY=1 $0" >&2
      exit 1
    fi
  done
fi

PP="${PP:-512}"
TG="${TG:-128}"
mkdir -p "$(dirname "$OUT")"

{
  echo "## $(date -Is)"
  echo
  echo "- model: \`$(basename "$MODEL")\`"
  echo "- kernel: \`$(uname -r)\`"
  echo "- gtt pages: \`$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo unknown)\`"
  echo "- gtt used: \`$(awk '/mem_info_gtt_used/{print $2; exit}' /sys/kernel/debug/dri/0/amd_mem_info 2>/dev/null || true)\` bytes"
  echo "- gov: \`$(command -v powerprofilesctl >/dev/null && powerprofilesctl get 2>/dev/null || echo unknown)\`"
  echo
} >> "$OUT"

for build in build build-vulkan; do
  BIN="$AI_HOME/llama.cpp/$build/bin/llama-bench"
  [ -x "$BIN" ] || continue
  label="rocm"
  if [ "$build" = "build-vulkan" ]; then
    label="vulkan"
  fi
  echo "== $label =="
  echo "### $label" >> "$OUT"
  echo '```' >> "$OUT"
  "$BIN" -m "$MODEL" -ngl 999 -fa 1 -p "$PP" -n "$TG" 2>&1 | tee -a "$OUT"
  echo '```' >> "$OUT"
  echo >> "$OUT"
done

echo
echo "appended to $OUT"
echo "compare backends: decode (tg) and prefill (pp) often have different winners."
