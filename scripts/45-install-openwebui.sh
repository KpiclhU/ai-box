#!/usr/bin/env bash
# 45-install-openwebui.sh — Open WebUI as a native install (uv, no Docker).
#
#   ./scripts/45-install-openwebui.sh
#   OPENWEBUI_PYTHON=3.11 ./scripts/45-install-openwebui.sh   # if 3.12 is rejected
#
# Installs into $AI_HOME/openwebui/venv with a uv-managed Python, because Ubuntu
# 26.04's system Python is newer than Open WebUI's supported range. No sudo: the
# venv and the service's data directory both live in your home.
#
# The unit, the env file and the data directory are created by
# 50-install-services.sh; this script only builds the environment.
set -euo pipefail

AI_HOME="${AI_HOME:-$HOME/ai}"
APP="$AI_HOME/openwebui"
VENV="$APP/venv"
PY_VERSION="${OPENWEBUI_PYTHON:-3.12}"
UV="${UV:-$HOME/.local/bin/uv}"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v curl >/dev/null || die "curl missing: sudo apt install curl"

# ---- uv ---------------------------------------------------------------------
say "uv"
if ! command -v uv >/dev/null 2>&1 && [ -x "$UV" ]; then
  export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v uv >/dev/null 2>&1; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi
command -v uv >/dev/null || die "uv installed but not on PATH — add ~/.local/bin to PATH"
uv --version

# ---- python + venv ----------------------------------------------------------
say "Python $PY_VERSION (uv-managed)"
uv python install "$PY_VERSION"
mkdir -p "$APP"
if [ -x "$VENV/bin/python" ]; then
  have="$("$VENV/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
  if [ "$have" != "$PY_VERSION" ]; then
    echo "existing venv is Python $have, want $PY_VERSION — recreating it"
    rm -rf "$VENV"
  fi
fi
[ -x "$VENV/bin/python" ] || uv venv --python "$PY_VERSION" "$VENV"

# ---- open-webui -------------------------------------------------------------
# shellcheck disable=SC1091
. "$VENV/bin/activate"
say "Open WebUI"
uv pip install --upgrade pip >/dev/null
uv pip install --upgrade open-webui || {
  cat >&2 <<'EOF'
error: Open WebUI did not install.

That is almost always the Python version: upstream supports 3.11-3.12, and a
very new interpreter has no wheels. Re-run with an explicit one:

  rm -rf ~/ai/openwebui/venv
  OPENWEBUI_PYTHON=3.11 ./scripts/45-install-openwebui.sh
EOF
  exit 1
}

say "Verify"
"$VENV/bin/open-webui" --help >/dev/null || die "open-webui command did not run"
echo "open-webui $("$VENV/bin/python" -c 'import importlib.metadata as m; print(m.version("open-webui"))' 2>/dev/null || echo installed)"

mkdir -p "$AI_HOME/data/openwebui"

cat <<EOF

Installed in $VENV

Next:
  sudo ./scripts/50-install-services.sh     # writes openwebui.env + the unit, starts it
  curl -s -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:3000/   # 200

50-install-services.sh prints the admin email and a generated password. That
account is created on the first start, so no sign-up page is needed and
ENABLE_SIGNUP stays false. Change the password after signing in.

Then:
  Admin -> Settings -> Users -> one account per person
  Admin -> Settings -> Images is already pointed at ComfyUI with the SDXL workflow
  (50 writes the workflow and its node map); docs/12 covers the Flux variant.

The UI binds 127.0.0.1:3000. 81-front-door.sh opens it to the Caddy VM and only
moves the bind to 0.0.0.0 once a default-deny firewall is in place; with ufw
inactive it leaves the bind on loopback and prints what to fix.
EOF
