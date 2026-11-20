#!/usr/bin/env bash
# 80-lan-access.sh — publish the UIs through a Caddy that runs on ANOTHER box.
#
#   sudo ./scripts/80-lan-access.sh --proxy 192.168.1.10
#   sudo ./scripts/80-lan-access.sh --proxy 192.168.1.10 \
#        --hostnames ai.example.com comfy.example.com
#   sudo ./scripts/80-lan-access.sh --dry-run --proxy 192.168.1.10
#   sudo ./scripts/80-lan-access.sh --revert
#
# This box keeps no proxy of its own. It binds llama-server and ComfyUI to the
# LAN, lets only the Caddy host through the firewall, and writes the site blocks
# that the Caddy box should import. Authentication happens there.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="${HOME}"
CONFIG_DIR="${AI_BOX_CONFIG_DIR:-$TARGET_HOME/.config/ai-box}"   # override is for the test suite
SNIPPET="$CONFIG_DIR/caddy-ai-box.caddy"

PROXY=""
AI_IP=""
LLM_NAME=""
COMFY_NAME=""
PROXY_LLM_PORT=8090
PROXY_COMFY_PORT=8190
CADDY_USER="ai"
PASSWORD=""
DRY_RUN=0
REVERT=0
GENERATED=0

usage() { sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --proxy)     PROXY="${2:-}"; shift ;;
    --ai-ip)     AI_IP="${2:-}"; shift ;;
    --hostnames) LLM_NAME="${2:-}"; COMFY_NAME="${3:-}"; shift 2 ;;
    --proxy-ports) PROXY_LLM_PORT="${2:-}"; PROXY_COMFY_PORT="${3:-}"; shift 2 ;;
    --user)      CADDY_USER="${2:-}"; shift ;;
    --password)  PASSWORD="${2:-}"; shift ;;
    --dry-run)   DRY_RUN=1 ;;
    --revert)    REVERT=1 ;;
    -h|--help)   usage 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# AI_BOX_CONFIG_DIR is the test-suite override and also lifts the root check.
if [ "$DRY_RUN" -eq 0 ] && [ -z "${AI_BOX_CONFIG_DIR:-}" ]; then
  [ "$(id -u)" -eq 0 ] || die "needs root: sudo $0 --proxy <caddy-host>"
fi

# ---- env file helpers -------------------------------------------------------
env_get() { # <file> <KEY> [default]
  local v
  v="$(grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' | tr -d '"' || true)"
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "${3:-}"
}

set_env() { # <file> <KEY> <value>
  [ -f "$1" ] || return 0
  if grep -qE "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    printf '\n%s=%s\n' "$2" "$3" >> "$1"
  fi
}

LLAMA_ENV="$CONFIG_DIR/llama-server.env"
ROUTER_ENV="$CONFIG_DIR/llama-router.env"
COMFY_ENV="$CONFIG_DIR/comfyui.env"
[ -f "$LLAMA_ENV" ] || [ -f "$ROUTER_ENV" ] || die "no llama env file in $CONFIG_DIR — run ./scripts/50-install-services.sh first"
[ -f "$COMFY_ENV" ] || die "no comfyui.env in $CONFIG_DIR — run ./scripts/50-install-services.sh first"

LLM_PORT="$(env_get "$LLAMA_ENV" PORT "$(env_get "$ROUTER_ENV" PORT 8080)")"
COMFY_PORT="$(env_get "$COMFY_ENV" PORT 8188)"

active_llama_unit() {
  if systemctl is-active --quiet llama-router 2>/dev/null; then
    echo llama-router
  elif systemctl is-active --quiet llama-server 2>/dev/null; then
    echo llama-server
  fi
}

restart_units() {
  local unit
  unit="$(active_llama_unit)"
  if [ -n "$unit" ]; then
    systemctl restart "$unit" && echo "restarted $unit (HOST now $(env_get "$CONFIG_DIR/$unit.env" HOST))"
  else
    echo "llama-server/llama-router are not running; the HOST change applies on next start"
  fi
  if systemctl is-enabled --quiet comfyui 2>/dev/null || systemctl is-active --quiet comfyui 2>/dev/null; then
    systemctl restart comfyui && echo "restarted comfyui (HOST now $(env_get "$COMFY_ENV" HOST))"
  else
    echo "comfyui is not enabled; the HOST change applies on next start"
  fi
}

# ---- revert -----------------------------------------------------------------
if [ "$REVERT" -eq 1 ]; then
  for f in "$LLAMA_ENV" "$ROUTER_ENV" "$COMFY_ENV"; do
    [ -f "$f" ] && set_env "$f" HOST 127.0.0.1
  done
  restart_units
  if [ -f "$SNIPPET" ]; then
    rm -f "$SNIPPET"
    echo "deleted $SNIPPET — remove its import line from the Caddy box too"
  fi
  if command -v ufw >/dev/null 2>&1; then
    for p in "$LLM_PORT" "$COMFY_PORT"; do
      ufw status 2>/dev/null | grep -Eq "^$p/tcp .*ALLOW" && ufw status 2>/dev/null \
        | awk -v p="$p" '$1==p"/tcp" && $2=="ALLOW" && $3=="Anywhere"{found=1} END{exit !found}' \
        && echo "note: ufw still has a rule for $p/tcp — check: ufw status numbered" || true
    done
  fi
  echo "ai-box is back on 127.0.0.1 only."
  exit 0
fi

[ -n "$PROXY" ] || die "give the Caddy host: --proxy 192.168.1.10 (or a CIDR like 192.168.1.0/24)"
printf '%s' "$PROXY" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' \
  || die "--proxy wants an IPv4 address or CIDR, got: $PROXY"

if [ -n "$AI_IP" ]; then
  printf '%s' "$AI_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "--ai-ip wants an IPv4 address"
else
  AI_IP="$( (hostname -I 2>/dev/null || true) | awk '{print $1}' || true)"
  [ -n "$AI_IP" ] || die "could not work out this box's IP; pass --ai-ip 192.168.1.50"
fi

# ---- password ---------------------------------------------------------------
if [ -z "$PASSWORD" ]; then
  if command -v openssl >/dev/null 2>&1; then
    PASSWORD="$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
  elif command -v python3 >/dev/null 2>&1; then
    PASSWORD="$(python3 -c 'import secrets,string;a=string.ascii_letters+string.digits;print("".join(secrets.choice(a) for _ in range(24)))')"
  else
    die "no openssl or python3 to generate a password; pass --password"
  fi
  GENERATED=1
fi

# bcrypt, from whatever is available here. Apache's htpasswd emits $2y$, which
# is the same algorithm; Caddy/Go verify it under the $2a$ spelling.
hash_password() {
  if command -v caddy >/dev/null 2>&1; then
    caddy hash-password --plaintext "$1"
  elif command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nbBC 14 "$CADDY_USER" "$1" | cut -d: -f2- | sed 's/^\$2y\$/\$2a\$/'
  elif python3 -c 'import bcrypt' 2>/dev/null; then
    python3 -c 'import bcrypt,sys;print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(rounds=14)).decode())' "$1"
  else
    return 1
  fi
}

HASH=""
HASH_OK=0
if HASH="$(hash_password "$PASSWORD" 2>/dev/null)" && [ -n "$HASH" ]; then
  HASH_OK=1
else
  HASH="__BCRYPT_HASH__"
fi

# ---- site blocks for the Caddy box ------------------------------------------
# Global options ({ email ... }, storage) stay in that box's own Caddyfile; an
# imported file may only contain site blocks.
render_snippet() {
  if [ -n "$LLM_NAME" ]; then
    cat <<EOF
# Generated by ai-box/scripts/80-lan-access.sh — paste on the Caddy box.
# Caddy gets certificates for these names automatically (DNS must point here).
$LLM_NAME {
	basic_auth {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy ${AI_IP}:${LLM_PORT} {
		flush_interval -1
	}
}

$COMFY_NAME {
	basic_auth {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy ${AI_IP}:${COMFY_PORT}
}
EOF
  else
    cat <<EOF
# Generated by ai-box/scripts/80-lan-access.sh — paste on the Caddy box.
# Plain HTTP on the proxy's LAN address; use --hostnames for TLS.
:${PROXY_LLM_PORT} {
	basic_auth {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy ${AI_IP}:${LLM_PORT} {
		flush_interval -1
	}
}

:${PROXY_COMFY_PORT} {
	basic_auth {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy ${AI_IP}:${COMFY_PORT}
}
EOF
  fi
}

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }

if [ "$DRY_RUN" -eq 1 ]; then
  say "Would change in $CONFIG_DIR"
  echo "  llama-server.env / llama-router.env: HOST=0.0.0.0   (port $LLM_PORT)"
  echo "  comfyui.env:                        HOST=0.0.0.0   (port $COMFY_PORT)"
  echo "  then restart the running llama unit and comfyui"
  say "Would write $SNIPPET"
  render_snippet
  say "Firewall"
  if ufw_active; then
    echo "  ufw allow from $PROXY to any port $LLM_PORT proto tcp"
    echo "  ufw allow from $PROXY to any port $COMFY_PORT proto tcp"
  else
    echo "  ufw is NOT active — nothing would restrict :$LLM_PORT / :$COMFY_PORT to $PROXY"
  fi
  [ "$HASH_OK" -eq 1 ] || echo "
  warning: no caddy/htpasswd/python-bcrypt here, so the hash is a placeholder.
  Run on the Caddy box: caddy hash-password --plaintext '<password>'"
  exit 0
fi

# ---- apply ------------------------------------------------------------------
say "Binding the services to the LAN"
for f in "$LLAMA_ENV" "$ROUTER_ENV" "$COMFY_ENV"; do
  [ -f "$f" ] || continue
  set_env "$f" HOST 0.0.0.0
  echo "  $(basename "$f"): HOST=0.0.0.0"
done
restart_units

say "Writing the site blocks for the Caddy box"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 755 "$CONFIG_DIR" 2>/dev/null || true
render_snippet > "$SNIPPET"
chown "$TARGET_USER:$TARGET_USER" "$SNIPPET" 2>/dev/null || true
chmod 644 "$SNIPPET"
echo "  $SNIPPET"

say "Firewall"
if ufw_active; then
  ufw allow from "$PROXY" to any port "$LLM_PORT" proto tcp >/dev/null
  ufw allow from "$PROXY" to any port "$COMFY_PORT" proto tcp >/dev/null
  echo "  allowed $PROXY -> $LLM_PORT/tcp, $COMFY_PORT/tcp (nothing else changed)"
  UFW_DONE=1
else
  UFW_DONE=0
  echo "  ufw is not active, so :$LLM_PORT and :$COMFY_PORT are open to the whole LAN."
fi

# ---- report -----------------------------------------------------------------
if [ -n "$LLM_NAME" ]; then
  LLM_URL="https://$LLM_NAME"
  COMFY_URL="https://$COMFY_NAME"
else
  LLM_URL="http://<caddy-box>:${PROXY_LLM_PORT}"
  COMFY_URL="http://<caddy-box>:${PROXY_COMFY_PORT}"
fi

cat <<EOF

ai-box now serves these to the Caddy host only:
  ${AI_IP}:${LLM_PORT}    llama.cpp chat UI, /v1 API, /models, /tools
  ${AI_IP}:${COMFY_PORT}    ComfyUI

On the Caddy box:
  1. copy the file over:
       scp ${TARGET_USER}@$(hostname):${SNIPPET} /etc/caddy/caddy-ai-box.caddy
  2. add one line to its Caddyfile:
       import /etc/caddy/caddy-ai-box.caddy
  3. sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy

Then open:
  ${LLM_URL}
  ${COMFY_URL}

EOF

if [ "$HASH_OK" -ne 1 ]; then
  cat <<EOF
The hash in that file is a placeholder. On the Caddy box run
  caddy hash-password --plaintext '<the password below>'
and paste the result over __BCRYPT_HASH__ (twice). (Installing apache2-utils here
would let the script do it: ./scripts/80-lan-access.sh --proxy ${PROXY} again.)

EOF
fi

if [ "$GENERATED" -eq 1 ]; then
  cat <<EOF
Generated password (shown once, store it in your password manager):
  $PASSWORD

Change it with: sudo $0 --proxy $PROXY --user $CADDY_USER --password 'new one'

EOF
fi

if [ "$UFW_DONE" -eq 0 ]; then
  cat <<EOF
Because no firewall is restricting these ports, anything on your network can use
the model. To limit it to the Caddy host:
  sudo ufw allow OpenSSH
  sudo ufw allow from $PROXY to any port $LLM_PORT proto tcp
  sudo ufw allow from $PROXY to any port $COMFY_PORT proto tcp
  sudo ufw default deny incoming
  sudo ufw enable
then re-run this script so the rules are verified. Check with: ufw status

EOF
fi

cat <<EOF
Notes:
  - Undo everything here: sudo $0 --revert
  - Do not port-forward ${LLM_PORT}/${COMFY_PORT} on your router; only the Caddy
    box should reach them.
  - The Discord bot is unaffected (it talks to 127.0.0.1).
EOF
