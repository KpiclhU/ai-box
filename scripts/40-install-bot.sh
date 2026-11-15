#!/usr/bin/env bash
# 40-install-bot.sh — Python venv + deps for the Discord bot.
#
#   ./scripts/40-install-bot.sh
#
# Does not touch your token. It only prepares bot/.venv and tells you what to put
# in .env.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOT="$REPO/bot"
VENV="$BOT/.venv"

die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

command -v python3 >/dev/null || die "python3 missing"
python3 -m venv --help >/dev/null 2>&1 || die "python3-venv missing: sudo apt install python3-venv"

say "Virtual environment"
[ -x "$VENV/bin/python" ] || python3 -m venv "$VENV"
# shellcheck disable=SC1091
. "$VENV/bin/activate"
python -m pip install --upgrade pip wheel
pip install -r "$BOT/requirements.txt"

say "Imports"
"$VENV/bin/python" - <<'PY'
import discord, httpx, dotenv
print("discord.py", discord.__version__)
print("httpx     ", httpx.__version__)
print("dotenv    ", getattr(dotenv, "__version__", "ok"))
PY

say "Configuration"
if [ ! -f "$REPO/.env" ]; then
  cp "$BOT/.env.example" "$REPO/.env"
  chmod 600 "$REPO/.env"
  echo "created $REPO/.env from bot/.env.example"
else
  echo "$REPO/.env already exists, left untouched"
fi

if grep -q '^DISCORD_TOKEN=YOUR_BOT_TOKEN_HERE' "$REPO/.env" 2>/dev/null; then
  cat <<EOF

The token is still a placeholder. To finish:
  1. https://discord.com/developers/applications -> New Application -> Bot -> Reset Token
  2. $EDITOR $REPO/.env      # set DISCORD_TOKEN and DISCORD_GUILD_ID
  3. sudo $REPO/scripts/50-install-services.sh
EOF
else
  echo "token appears to be set; continue with 50-install-services.sh"
fi
