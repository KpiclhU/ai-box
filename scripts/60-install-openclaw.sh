#!/usr/bin/env bash
# 60-install-openclaw.sh — install the OpenClaw CLI and prepare it for this box.
#
#   ./scripts/60-install-openclaw.sh              # install, write the provider patch, print next steps
#   ./scripts/60-install-openclaw.sh --model X    # pin the model id instead of discovering it
#   ./scripts/60-install-openclaw.sh --check      # report only, change nothing
#   ./scripts/60-install-openclaw.sh --force      # rewrite an existing patch file
#
# No sudo. A global npm install into a root-owned prefix is refused with the exact
# command to run instead. Node is not installed here: the official installer
# provisions it, or you install it yourself — both are in docs/11-openclaw.md.
#
# What it touches: npm's global prefix, and ~/.config/ai-box/openclaw-provider.patch.json5.
# It does not run onboarding and it does not edit ~/.openclaw/openclaw.json.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/ai-box"
PATCH="$CONFIG_DIR/openclaw-provider.patch.json5"
BASE_URL="http://127.0.0.1:8080/v1"
MODEL=""
CHECK=0
FORCE=0

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --model) [ "$#" -ge 2 ] || die "--model needs a value"; MODEL="$2"; shift 2 ;;
    --base-url) [ "$#" -ge 2 ] || die "--base-url needs a value"; BASE_URL="$2"; shift 2 ;;
    --check) CHECK=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

command -v curl >/dev/null || die "curl missing: sudo apt install curl"

# ---- node -------------------------------------------------------------------
say "Node"
if command -v node >/dev/null 2>&1; then
  NODE_V="$(node -p 'process.versions.node')"
  NODE_MAJ="${NODE_V%%.*}"
  NODE_REST="${NODE_V#*.}"
  NODE_MIN="${NODE_REST%%.*}"
  echo "node $NODE_V"
  NODE_OK=0
  if [ "$NODE_MAJ" -gt 26 ]; then NODE_OK=1; fi
  if [ "$NODE_MAJ" -eq 26 ] && [ "$NODE_MIN" -ge 1 ]; then NODE_OK=1; fi
  if [ "$NODE_MAJ" -eq 24 ] && [ "$NODE_MIN" -ge 16 ]; then NODE_OK=1; fi
  if [ "$NODE_OK" -eq 0 ]; then
    die "OpenClaw needs Node 24.16+ or 26.1+ (26 recommended); this is $NODE_V.
Either install Node 26, or re-run the official installer so it provisions one:
  curl -fsSL https://openclaw.ai/install.sh | bash"
  fi
  # 24.22.1+ / 26.12.1+ are the security-patched lines the docs recommend.
  if [ "$NODE_MAJ" -eq 24 ] && [ "$NODE_MIN" -lt 22 ]; then
    echo "note: 24.22.1+ is the patched 24.x line — consider a newer 24.x or Node 26"
  fi
else
  die "node not found.
Two supported ways (docs/11-openclaw.md):
  curl -fsSL https://openclaw.ai/install.sh | bash     # provisions Node on Linux, then onboards
  # or install Node yourself, then re-run this script"
fi

command -v npm >/dev/null || die "npm missing alongside node — check your Node install"

# ---- openclaw ---------------------------------------------------------------
say "OpenClaw"
if command -v openclaw >/dev/null 2>&1; then
  echo "already installed: $(openclaw --version 2>/dev/null || echo 'version unknown')"
  if [ "$CHECK" -eq 1 ]; then CHECK_ONLY=1; else CHECK_ONLY=0; fi
else
  if [ "$CHECK" -eq 1 ]; then
    echo "not installed (--check: nothing changed)"
    exit 0
  fi
  # npm 12 blocks package lifecycle scripts by default; 11.16+ accepts the opt-in;
  # 11.15 and earlier reject the flag outright. `npm approve-scripts` does not work
  # for a global install, so it has to be on the install command.
  NPM_V="$(npm --version)"
  NPM_MAJ="${NPM_V%%.*}"
  NPM_REST="${NPM_V#*.}"
  NPM_MIN="${NPM_REST%%.*}"
  ALLOW=""
  if [ "$NPM_MAJ" -ge 12 ]; then ALLOW="--allow-scripts=openclaw"; fi
  if [ "$NPM_MAJ" -eq 11 ] && [ "$NPM_MIN" -ge 16 ]; then ALLOW="--allow-scripts=openclaw"; fi
  echo "npm $NPM_V${ALLOW:+ ($ALLOW)}"

  PREFIX="$(npm prefix -g 2>/dev/null || true)"
  [ -n "$PREFIX" ] || die "could not resolve npm's global prefix: npm prefix -g"
  if [ ! -w "$PREFIX" ]; then
    die "npm's global prefix $PREFIX is not writable by $(id -un), and this script does not sudo.
Run it yourself, then re-run this script:
  sudo npm install -g openclaw@latest${ALLOW:+ $ALLOW}"
  fi

  # shellcheck disable=SC2086
  npm install -g openclaw@latest $ALLOW
  command -v openclaw >/dev/null || die "openclaw installed but not on PATH — see npm prefix -g"
  echo "installed: $(openclaw --version)"
  CHECK_ONLY=0
fi

# ---- the model this box actually serves -------------------------------------
say "Model on 127.0.0.1:8080"
if [ -n "$MODEL" ]; then
  echo "pinned by --model: $MODEL"
else
  DISCOVERED=""
  if curl -fsS --max-time 5 "$BASE_URL/models" -o /tmp/openclaw-models.$$ 2>/dev/null; then
    if command -v jq >/dev/null 2>&1; then
      DISCOVERED="$(jq -r '.data[0].id // empty' /tmp/openclaw-models.$$ 2>/dev/null || true)"
    elif command -v python3 >/dev/null 2>&1; then
      DISCOVERED="$(python3 -c 'import json,sys
print(json.load(open(sys.argv[1]))["data"][0]["id"])' \
        /tmp/openclaw-models.$$ 2>/dev/null || true)"
    fi
    rm -f /tmp/openclaw-models.$$
  fi
  if [ -n "$DISCOVERED" ]; then
    MODEL="$DISCOVERED"
    echo "discovered: $MODEL"
  else
    MODEL="local"
    echo "could not reach $BASE_URL/models — falling back to the alias 'local'"
    echo "  (correct for llama-server, whose extra args carry --alias local;"
    echo "   in router mode the id is the .gguf file name)"
    echo "  is the model loaded?  curl -s http://127.0.0.1:8080/health"
  fi
fi

# ---- provider patch ---------------------------------------------------------
say "Provider patch"
install -d -m 755 "$CONFIG_DIR"
if [ -f "$PATCH" ] && [ "$FORCE" -eq 0 ]; then
  echo "$PATCH exists, left untouched (--force to rewrite)"
  echo "it names model id: $(grep -m1 'id:' "$PATCH" | tr -d '",' | awk '{print $2}' || echo '?')"
else
  cat > "$PATCH" <<EOF
// OpenClaw provider entry for this box's llama-server.
// Apply with:  openclaw config patch --file $PATCH
// contextWindow is the per-request window, not the server total:
// llama-server.env runs --ctx-size 131072 --parallel 2, so each request gets 64k.
// OpenClaw's fallback when discovery cannot prove a window is 128000, which is
// twice what this server can hold. timeoutSeconds covers slow local prefill
// (~1.1-1.25k tok/s, docs/04) before the first token appears.
// Arrays replace on patch, so every model you want belongs in this one list.
{
  models: {
    mode: "merge",
    providers: {
      "llama-cpp": {
        baseUrl: "$BASE_URL",
        api: "openai-completions",
        request: { allowPrivateNetwork: true },
        timeoutSeconds: 300,
        models: [
          {
            id: "$MODEL",
            name: "ai-box llama-server",
            reasoning: false,
            input: ["text"],
            cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
            contextWindow: 65536,
            maxTokens: 8192,
          },
        ],
      },
    },
  },
}
EOF
  chmod 644 "$PATCH"
  echo "wrote $PATCH (model id: $MODEL)"
fi

# ---- next steps -------------------------------------------------------------
say "Next"
if [ "${CHECK_ONLY:-0}" -eq 1 ]; then
  echo "--check: nothing was changed."
  exit 0
fi

cat <<EOF
1. Point OpenClaw at the model (recommended: the wizard, it verifies discovery):
     openclaw onboard          # choose "Existing llama-server", then $BASE_URL

   Non-interactive equivalent:
     openclaw onboard --non-interactive --accept-risk --skip-health \\
       --auth-choice llama-cpp-existing-server \\
       --custom-base-url $BASE_URL \\
       --custom-model-id $MODEL

   Do not choose "Managed local server" — it would download its own GGUF and
   compete with llama-server for the same 48 GiB of GTT.

2. Apply the context window and timeout (gateway must not be running):
     openclaw config patch --file $PATCH

3. Select the model and check it:
     openclaw models set llama-cpp/$MODEL
     openclaw models list --provider llama-cpp

4. Add a channel — easiest on a headless box is Telegram (long polling, no ports):
     openclaw channels add --channel telegram

5. Start it the same way as everything else on this box:
     sudo $REPO/scripts/50-install-services.sh
     systemctl status openclaw-gateway --no-pager

Details, remote access and the security model: $REPO/docs/11-openclaw.md
EOF
