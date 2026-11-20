#!/usr/bin/env bash
# 96-comfy-models.sh — list, download and delete ComfyUI models from the terminal.
#
#   ./scripts/96-comfy-models.sh                  # every model file, by folder, with sizes
#   ./scripts/96-comfy-models.sh list checkpoints
#   ./scripts/96-comfy-models.sh dirs             # model paths ComfyUI sees + free space
#   ./scripts/96-comfy-models.sh download <hf-repo> '<glob>' [folder]
#   ./scripts/96-comfy-models.sh url <url> [folder] [filename]
#   ./scripts/96-comfy-models.sh rm <folder> <file>   (add -y to skip the prompt)
#   ./scripts/96-comfy-models.sh free             # POST /free: drop cached weights
#
# Self-hosted ComfyUI has no download endpoint: the built-in Model Library only browses what
# is already under models/, and ComfyUI-Manager adds a catalog UI, not a CLI. This is the
# out-of-band half, and it works whether or not ComfyUI is running.
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
COMFY="${COMFYUI_DIR:-$AI_HOME/comfyui}"
MODELS="$COMFY/models"
BASE="${COMFY_URL:-http://127.0.0.1:8188}"
BASE="${BASE%/}"
ASSUME_YES=0
# <bytes>\t<name> -> a human line, in the unit that suits the file
SIZE_FMT='{ b = $1; if (b >= 1073741824) printf "  %7.2f GB  %s\n", b / 1073741824, $2; else printf "  %7.1f MB  %s\n", b / 1048576, $2 }'

say()   { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()   { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# ComfyUI is the authority on where models live — extra_model_paths.yaml can add directories
# outside the checkout. When it is not running, fall back to the checkout's own models tree.
model_roots() {
  local api d
  if api="$(curl -sS --max-time 3 "$BASE/api/experiment/models" 2>/dev/null)" && [ -n "$api" ]; then
    printf '%s' "$api" | python3 -c '
import json, sys
for folder in json.load(sys.stdin):
    for path in folder.get("folders") or []:
        print("%s\t%s" % (folder.get("name", "?"), path))
' && return 0
  fi
  for d in "$MODELS"/*/; do
    [ -d "$d" ] || continue
    printf '%s\t%s\n' "$(basename "$d")" "${d%/}"
  done
}

# One line per file: <bytes>\t<path relative to the model folder>
scan_folder() {
  find "$1" -maxdepth 2 -type f -size +1M \
    \( -name '*.safetensors' -o -name '*.ckpt' -o -name '*.pt' -o -name '*.pth' \
       -o -name '*.bin' -o -name '*.gguf' -o -name '*.onnx' \) \
    -printf '%s\t%P\n' 2>/dev/null | sort -nr
}

cmd_list() {
  local only="${1:-}" folder dir out shown=0
  while IFS=$'\t' read -r folder dir; do
    [ -n "${folder:-}" ] || continue
    [ -z "$only" ] || [ "$only" = "$folder" ] || continue
    out="$(scan_folder "$dir" | head -40)"
    [ -n "$out" ] || continue
    shown=$((shown + 1))
    say "$folder  ($dir)"
    printf '%s\n' "$out" | awk -F'\t' "$SIZE_FMT"
  done < <(model_roots)
  [ "$shown" -gt 0 ] || echo "no model files found under $MODELS — put one there or use: $0 download ..."
}

cmd_dirs() {
  say "Model roots"
  model_roots | awk -F'\t' '{printf "  %-18s %s\n", $1, $2}'
  printf '\n'
  df -h "$MODELS" 2>/dev/null | tail -1 | awk '{printf "  %s free on %s\n", $4, $6}' || true
}

cmd_download() {
  local repo="${1:-}" glob="${2:-}" folder="${3:-checkpoints}" dest
  [ -n "$repo" ] && [ -n "$glob" ] || usage 1
  command -v hf >/dev/null 2>&1 || command -v huggingface-cli >/dev/null 2>&1 \
    || die "huggingface CLI missing: pipx install 'huggingface_hub[cli]'"
  dest="$MODELS/$folder"
  mkdir -p "$dest"
  say "Downloading $repo"
  echo "glob: $glob"
  echo "dest: $dest"
  echo
  if command -v hf >/dev/null 2>&1; then
    hf download "$repo" --include "$glob" --local-dir "$dest"
  else
    huggingface-cli download "$repo" --include "$glob" --local-dir "$dest"
  fi
  say "Added to $folder"
  find "$dest" -maxdepth 2 -type f -newermt '-3 hours' \
    \( -name '*.safetensors' -o -name '*.gguf' -o -name '*.ckpt' -o -name '*.pt' \) \
    -printf '%s\t%P\n' 2>/dev/null | sort -nr | awk -F'\t' "$SIZE_FMT" || true
  echo
  echo "ComfyUI picks it up on its next refresh: reload the page, or $0 list $folder"
}

cmd_url() {
  local url="${1:-}" folder="${2:-checkpoints}" name="${3:-}" dest
  [ -n "$url" ] || usage 1
  [ -n "$name" ] || name="$(basename "${url%%\?*}")"
  dest="$MODELS/$folder"
  mkdir -p "$dest"
  say "Fetching $name"
  case "$url" in
    *civitai.com*)
      case "$url" in
        *token=*) ;;
        *) echo "note: Civitai needs a token — append ?token=<key> to the URL" >&2 ;;
      esac
      ;;
  esac
  curl -fL --retry 3 --retry-delay 2 -C - --progress-bar -o "$dest/$name" "$url"
  echo
  echo "-> $dest/$name"
}

cmd_rm() {
  local folder="${1:-}" file="${2:-}" path answer
  [ -n "$folder" ] && [ -n "$file" ] || usage 1
  path="$MODELS/$folder/$file"
  [ -f "$path" ] || die "no such file: $path  (try: $0 list $folder)"
  if [ "$ASSUME_YES" -eq 0 ]; then
    printf 'delete %s (%s)? [y/N] ' "$path" "$(du -h "$path" | cut -f1)"
    read -r answer || answer=""
    case "${answer:-}" in
      [yY]*) ;;
      *) echo "kept"; return 0 ;;
    esac
  fi
  rm -f "$path"
  echo "removed $path"
}

cmd_free() {
  curl -sS --max-time 10 -X POST "$BASE/free" \
    -H 'Content-Type: application/json' \
    -d '{"unload_models":true,"free_memory":true}' \
    || die "ComfyUI not reachable at $BASE"
  echo "ComfyUI unloaded its models; the queue is untouched"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -y|--yes) ASSUME_YES=1; shift ;;
    *) break ;;
  esac
done

case "${1:-list}" in
  list)     cmd_list "${2:-}" ;;
  dirs)     cmd_dirs ;;
  download) cmd_download "${2:-}" "${3:-}" "${4:-}" ;;
  url)      cmd_url "${2:-}" "${3:-}" "${4:-}" ;;
  rm)       cmd_rm "${2:-}" "${3:-}" ;;
  free)     cmd_free ;;
  -h|--help|help) usage 0 ;;
  *)        usage 1 ;;
esac
