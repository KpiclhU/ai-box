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
#
# The bind only happens once a default-deny firewall is in place: a wildcard bind
# with nothing in front of it is reachable by every device on the network. With
# no such firewall this script leaves both services on 127.0.0.1 and exits
# non-zero. If something else already limits the ports (firewalld, nftables, a
# VLAN ACL), assert that instead:
#   sudo AI_BOX_UNFIREWALLED=1 ./scripts/80-lan-access.sh --proxy 192.168.1.10
set -euo pipefail

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

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }
# "Active" is not enough: with a default-allow incoming policy an `allow from`
# rule describes one of the many hosts that may connect, so it restricts nothing.
ufw_default_deny() { ufw status verbose 2>/dev/null | grep -q '^Default: deny (incoming)'; }

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

# Restart one unit, and only if it is actually running. Called solely for files
# whose HOST changed, so a refused run — or a re-run that changes nothing — leaves
# a loaded model alone.
restart_unit() { # <unit>
  if [ "$1" = comfyui ]; then
    if systemctl is-enabled --quiet comfyui 2>/dev/null || systemctl is-active --quiet comfyui 2>/dev/null; then
      systemctl restart comfyui && echo "  restarted comfyui (HOST now $(env_get "$COMFY_ENV" HOST))"
    else
      echo "  comfyui is not enabled; HOST applies on next start"
    fi
  elif systemctl is-active --quiet "$1" 2>/dev/null; then
    systemctl restart "$1" && echo "  restarted $1 (HOST now $(env_get "$CONFIG_DIR/$1.env" HOST))"
  else
    echo "  $1 is not running; HOST applies on next start"
  fi
}

# Revert always moves the files back, so it restarts whatever is up.
restart_units() {
  local unit
  unit="$(active_llama_unit)"
  if [ -n "$unit" ]; then
    restart_unit "$unit"
  else
    echo "llama-server/llama-router are not running; the HOST change applies on next start"
  fi
  restart_unit comfyui
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

# ---- firewall, BEFORE the bind ----------------------------------------------
# A wildcard bind with no firewall in front of it stays reachable by every device
# on the network for as long as the services run, so the rules go in first and
# the bind only follows if they are real.
say "Firewall"
LAN_BIND=0
if ufw_active && ufw_default_deny; then
  GUARD=ufw
elif [ "${AI_BOX_UNFIREWALLED:-0}" = 1 ]; then
  GUARD=override
elif ufw_active; then
  GUARD=allow-policy
elif command -v ufw >/dev/null 2>&1; then
  GUARD=inactive
else
  GUARD=absent
fi

case "$GUARD" in
  ufw)
    LAN_BIND=1
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  would allow $PROXY -> $LLM_PORT/tcp, $COMFY_PORT/tcp (incoming denied by default)"
    else
      ufw allow from "$PROXY" to any port "$LLM_PORT" proto tcp >/dev/null
      ufw allow from "$PROXY" to any port "$COMFY_PORT" proto tcp >/dev/null
      echo "  allowed $PROXY -> $LLM_PORT/tcp, $COMFY_PORT/tcp; incoming denied by default"
      ufw status | grep -E "($LLM_PORT|$COMFY_PORT)/tcp" | sed 's/^/    /' || true
    fi
    ;;
  override)
    LAN_BIND=1
    echo "  AI_BOX_UNFIREWALLED=1: no ufw rule added — :$LLM_PORT and :$COMFY_PORT"
    echo "  must already be limited to $PROXY by something else. Verify that first."
    ;;
  allow-policy)
    echo "  not binding the LAN: ufw is active but its default incoming policy is"
    echo "  allow, so 'ufw allow from $PROXY' would not restrict anything."
    ;;
  inactive)
    echo "  not binding the LAN: ufw is installed but not active, so the ports would"
    echo "  be reachable from the whole network."
    ;;
  absent)
    echo "  not binding the LAN: ufw is not installed, so the ports would be"
    echo "  reachable from the whole network."
    ;;
esac

if [ "$LAN_BIND" -eq 1 ]; then HOST_=0.0.0.0; else HOST_=127.0.0.1; fi

if [ "$DRY_RUN" -eq 1 ]; then
  say "Would change in $CONFIG_DIR"
  echo "  llama-server.env / llama-router.env: HOST=$HOST_   (port $LLM_PORT)"
  echo "  comfyui.env:                        HOST=$HOST_   (port $COMFY_PORT)"
  echo "  then restart only the units whose HOST changed"
  say "Would write $SNIPPET"
  render_snippet
  [ "$HASH_OK" -eq 1 ] || echo "
  warning: no caddy/htpasswd/python-bcrypt here, so the hash is a placeholder.
  Run on the Caddy box: caddy hash-password --plaintext '<password>'"
  exit 0
fi

# ---- apply ------------------------------------------------------------------
say "HOST=$HOST_ in the service env files"
CHANGED=()
for f in "$LLAMA_ENV" "$ROUTER_ENV" "$COMFY_ENV"; do
  [ -f "$f" ] || continue
  if [ "$(env_get "$f" HOST)" = "$HOST_" ]; then
    echo "  $(basename "$f"): already HOST=$HOST_"
    continue
  fi
  set_env "$f" HOST "$HOST_"
  echo "  $(basename "$f"): HOST=$HOST_"
  CHANGED+=("$(basename "$f" .env)")
done
if [ ${#CHANGED[@]} -eq 0 ]; then
  echo "  nothing to restart — every service was already on $HOST_"
else
  for u in "${CHANGED[@]}"; do restart_unit "$u"; done
fi

say "Writing the site blocks for the Caddy box"
install -d -o "$TARGET_USER" -g "$TARGET_USER" -m 755 "$CONFIG_DIR" 2>/dev/null || true
render_snippet > "$SNIPPET"
chown "$TARGET_USER:$TARGET_USER" "$SNIPPET" 2>/dev/null || true
chmod 644 "$SNIPPET"
echo "  $SNIPPET"

if [ "$LAN_BIND" -eq 0 ]; then
  cat <<EOF

Nothing was published: llama-server and ComfyUI are back on 127.0.0.1, so Caddy
will answer 502. That is deliberate — a wildcard bind is only safe once the rest
of the network is blocked, and nothing here is doing the blocking yet.

Fix it on this box, then re-run this script:

  sudo ufw allow OpenSSH
  sudo ufw default deny incoming
  sudo ufw enable
  sudo ufw allow from $PROXY to any port $LLM_PORT proto tcp
  sudo ufw allow from $PROXY to any port $COMFY_PORT proto tcp

Check: ufw status verbose     # want: Status: active, Default: deny (incoming)

If a different firewall (firewalld, nftables, a VLAN ACL) already limits these
ports to $PROXY, assert that instead and re-run:

  sudo AI_BOX_UNFIREWALLED=1 $0 --proxy $PROXY
EOF
  exit 1
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

cat <<EOF
Notes:
  - Undo everything here: sudo $0 --revert
  - Do not port-forward ${LLM_PORT}/${COMFY_PORT} on your router; only the Caddy
    box should reach them.
  - Open WebUI is unaffected (it talks to 127.0.0.1) — but do not run this legacy layout
    alongside scripts/81-front-door.sh; they publish different surfaces.
EOF
