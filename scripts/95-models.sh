#!/usr/bin/env bash
# 95-models.sh — manage the GGUF library through llama-server's router mode.
#
#   ./scripts/95-models.sh list
#   ./scripts/95-models.sh load <model>
#   ./scripts/95-models.sh unload <model>
#   ./scripts/95-models.sh download <user>/<repo>[:quant]
#   ./scripts/95-models.sh reload
#
# A <model> is whatever `list` prints: a .gguf file name for files under MODELS_DIR,
# or user/repo:quant for entries in the Hugging Face cache.
#
# This talks to the router, so llama-router.service has to be the running unit:
#   sudo systemctl disable --now llama-server
#   sudo systemctl enable --now llama-router
set -euo pipefail

BASE="${LLM_BASE_URL:-http://127.0.0.1:8080}"
BASE="${BASE%/}"
TIMEOUT="${TIMEOUT:-30}"

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

router_hint() {
  cat >&2 <<'EOF'
/model management only exists in router mode (llama-router.service):
  sudo systemctl disable --now llama-server
  sudo systemctl enable --now llama-router
  ./scripts/95-models.sh list
EOF
}

json_model() { python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1]}))' "$1"; }

model_state() { # <spec> -> one status word
  curl -sS --max-time "$TIMEOUT" "$BASE/models" | python3 -c '
import json, sys

spec = sys.argv[1].lower()
try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    print("unknown")
    raise SystemExit(0)
for entry in payload.get("data", []):
    if str(entry.get("id", "")).lower() == spec:
        status = entry.get("status") or {}
        print(status.get("value", "?") if isinstance(status, dict) else status)
        break
else:
    print("unknown")
' "$1" 2>/dev/null || echo unknown
}

cmd_list() {
  local raw
  raw="$(curl -sS --max-time "$TIMEOUT" "$BASE/models")" || {
    echo "error: cannot reach $BASE" >&2
    exit 1
  }
  printf '%s' "$raw" | python3 -c '
import json, sys

try:
    payload = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit("router returned non-JSON; is llama-server running?")

if isinstance(payload, dict) and payload.get("error"):
    err = payload["error"]
    print(err.get("message", err) if isinstance(err, dict) else err, file=sys.stderr)
    print("hint: /models only exists in router mode (llama-router.service)", file=sys.stderr)
    raise SystemExit(1)

rows = payload.get("data", []) if isinstance(payload, dict) else []
if not rows:
    print("no models found: check MODELS_DIR in ~/.config/ai-box/llama-router.env")
    raise SystemExit(0)

print("%-11s  %s" % ("status", "model"))
for entry in rows:
    status = entry.get("status") or {}
    value = status.get("value", "?") if isinstance(status, dict) else str(status)
    print("%-11s  %s" % (value, entry.get("id", "?")))
'
}

cmd_action() { # <verb> <endpoint> <model>
  local verb="$1" endpoint="$2" name="${3:-}" body response
  [ -n "$name" ] || usage 1
  body="$(json_model "$name")"
  response="$(curl -sS --max-time "${LOAD_TIMEOUT:-1800}" -X POST "$BASE$endpoint" \
    -H 'Content-Type: application/json' -d "$body" || true)"
  if [ -z "$response" ]; then
    router_hint
    exit 1
  fi
  echo "$verb $name -> $response"
  case "$response" in
    *'"success":true'*|*'"success": true'*) ;;
    *) echo "router did not confirm it; see: journalctl -u llama-router -n 50" >&2; exit 1 ;;
  esac
}

cmd_download() {
  local spec="${1:-}" body response state last="" waited=0
  [ -n "$spec" ] || usage 1
  body="$(json_model "$spec")"
  if ! response="$(curl -sS --max-time "$TIMEOUT" -X POST "$BASE/models" \
      -H 'Content-Type: application/json' -d "$body")"; then
    router_hint
    exit 1
  fi
  echo "requested $spec -> $response"
  echo "polling status; Ctrl-C is safe, re-running resumes the download"
  while [ "$waited" -lt 3600 ]; do
    state="$(model_state "$spec")"
    if [ "$state" != "$last" ]; then
      echo "  $state"
      last="$state"
    fi
    case "$state" in
      downloading|unknown) sleep 5; waited=$((waited + 5)) ;;
      *) break ;;
    esac
  done
  echo "final state: $state"
}

case "${1:-list}" in
  list) cmd_list ;;
  load) cmd_action load /models/load "${2:-}" ;;
  unload) cmd_action unload /models/unload "${2:-}" ;;
  download) cmd_download "${2:-}" ;;
  reload) curl -sS --max-time "$TIMEOUT" "$BASE/models?reload=1" >/dev/null && echo "model list reloaded" ;;
  -h|--help|help) usage 0 ;;
  *) usage 1 ;;
esac
