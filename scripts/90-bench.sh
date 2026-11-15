#!/usr/bin/env bash
# 90-bench.sh — measure this machine instead of trusting a table.
#
#   ./scripts/90-bench.sh                       # uses MODEL from the service env
#   ./scripts/90-bench.sh ~/ai/models/x.gguf
#
# Runs llama-bench for every build present (rocm, vulkan) and appends results to
# bench/YYYY-MM-DD.md.
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/bench/$(date +%F).md"
ENV_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/ai-box/llama-server.env"

MODEL="${1:-${MODEL:-}}"
if [ -z "$MODEL" ] && [ -f "$ENV_FILE" ]; then
  # shellcheck disable=SC1090
  MODEL="$(. "$ENV_FILE" && echo "${MODEL:-}")"
fi
[ -n "$MODEL" ] && [ -f "$MODEL" ] || {
  echo "usage: $0 /path/to/model.gguf    (or set MODEL in $ENV_FILE)" >&2
  exit 1
}

PP="${PP:-512}"
TG="${TG:-128}"
mkdir -p "$(dirname "$OUT")"

{
  echo "## $(date -Is)"
  echo
  echo "- model: \`$(basename "$MODEL")\`"
  echo "- kernel: \`$(uname -r)\`"
  echo "- gtt pages: \`$(cat /sys/module/ttm/parameters/pages_limit 2>/dev/null || echo unknown)\`"
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
