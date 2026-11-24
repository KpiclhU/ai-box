#!/usr/bin/env bash
# 80-lan-access.sh — publish llama-server and ComfyUI to the LAN, firewall first.
#
#   sudo ./scripts/80-lan-access.sh
#   sudo ./scripts/80-lan-access.sh --lan 192.168.150.0/24
#   sudo ./scripts/80-lan-access.sh --dry-run
#   sudo ./scripts/80-lan-access.sh --revert
#
# There is no proxy in front of this box: the two services are the surface. After
# this script both listen on 0.0.0.0 and ufw allows only the given subnet, so a
# device outside it gets nothing.
#
# What that means for security: llama-server and ComfyUI have no accounts of
# their own. Every device inside the subnet can read and drive both, and that is
# the design — the subnet is the boundary. Do not port-forward 8080 or 8188.
#
# The bind only happens once a default-deny firewall is in place: a wildcard bind
# with nothing in front of it is reachable by every device that can reach the
# network. With no such firewall this script leaves both services on 127.0.0.1
# and exits non-zero. If something else already limits the ports (a VLAN ACL, a
# router rule), assert that instead:
#   sudo AI_BOX_UNFIREWALLED=1 ./scripts/80-lan-access.sh --lan 192.168.150.0/24
set -euo pipefail

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="${HOME}"
CONFIG_DIR="${AI_BOX_CONFIG_DIR:-$TARGET_HOME/.config/ai-box}"   # override is for the test suite

LAN="192.168.150.0/24"
DRY_RUN=0
REVERT=0

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }
# "Active" is not enough: with a default-allow incoming policy an `allow from`
# rule describes one of the many hosts that may connect, so it restricts nothing.
ufw_default_deny() { ufw status verbose 2>/dev/null | grep -q '^Default: deny (incoming)'; }

while [ $# -gt 0 ]; do
  case "$1" in
    --lan)      LAN="${2:-}"; [ -n "$LAN" ] || die "--lan needs a CIDR (try --help)"; shift ;;
    --dry-run)  DRY_RUN=1 ;;
    --revert)   REVERT=1 ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  if [ $# -gt 0 ]; then shift; fi
done

printf '%s' "$LAN" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$' \
  || die "--lan wants an IPv4 CIDR such as 192.168.150.0/24, got: $LAN"

# AI_BOX_CONFIG_DIR is the test-suite override and also lifts the root check.
if [ "$DRY_RUN" -eq 0 ] && [ -z "${AI_BOX_CONFIG_DIR:-}" ]; then
  [ "$(id -u)" -eq 0 ] || die "needs root: sudo $0 --lan $LAN"
fi

# ---- env file helpers -------------------------------------------------------
env_get() { # <file> <KEY> [default]
  local v
  v="$(grep -E "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r"' || true)"
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
[ -f "$LLAMA_ENV" ] || [ -f "$ROUTER_ENV" ] \
  || die "no llama env file in $CONFIG_DIR — run ./scripts/50-install-services.sh first"
[ -f "$COMFY_ENV" ] \
  || die "no comfyui.env in $CONFIG_DIR — run ./scripts/50-install-services.sh first"

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
  if command -v ufw >/dev/null 2>&1; then
    for p in "$LLM_PORT" "$COMFY_PORT"; do
      if ufw status 2>/dev/null | grep -qE "^$p/tcp .*ALLOW"; then
        ufw delete allow from "$LAN" to any port "$p" proto tcp >/dev/null 2>&1 \
          && echo "  removed the ufw rule for $p/tcp from $LAN"
      fi
    done
  fi
  echo "ai-box is back on 127.0.0.1 only."
  exit 0
fi

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
      echo "  would allow $LAN -> $LLM_PORT/tcp, $COMFY_PORT/tcp (incoming denied by default)"
    else
      ufw allow from "$LAN" to any port "$LLM_PORT" proto tcp >/dev/null
      ufw allow from "$LAN" to any port "$COMFY_PORT" proto tcp >/dev/null
      echo "  allowed $LAN -> $LLM_PORT/tcp, $COMFY_PORT/tcp; incoming denied by default"
      ufw status | grep -E "($LLM_PORT|$COMFY_PORT)/tcp" | sed 's/^/    /' || true
    fi
    ;;
  override)
    LAN_BIND=1
    echo "  AI_BOX_UNFIREWALLED=1: no ufw rule added — :$LLM_PORT and :$COMFY_PORT"
    echo "  must already be limited to $LAN by something else. Verify that first."
    ;;
  allow-policy)
    echo "  not binding the LAN: ufw is active but its default incoming policy is"
    echo "  allow, so 'ufw allow from $LAN' would not restrict anything."
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

if [ "$LAN_BIND" -eq 0 ]; then
  cat <<EOF

Nothing was published: llama-server and ComfyUI are back on 127.0.0.1, so no
other machine can reach them. That is deliberate — a wildcard bind is only safe
once the rest of the network is blocked, and nothing here is doing the blocking
yet.

Fix it on this box, then re-run this script:

  sudo ufw allow OpenSSH
  sudo ufw default deny incoming
  sudo ufw enable
  sudo ufw allow from $LAN to any port $LLM_PORT proto tcp
  sudo ufw allow from $LAN to any port $COMFY_PORT proto tcp

Check: ufw status verbose     # want: Status: active, Default: deny (incoming)

If a different firewall (a VLAN ACL, a router rule) already limits these ports
to $LAN, assert that instead and re-run:

  sudo AI_BOX_UNFIREWALLED=1 $0 --lan $LAN
EOF
  exit 1
fi

# ---- report -----------------------------------------------------------------
LAN_IP="$( (hostname -I 2>/dev/null || true) | awk '{print $1}' || true)"
[ -n "$LAN_IP" ] || LAN_IP="<this-box-ip>"

cat <<EOF

ai-box now serves this to $LAN and nothing else:
  ${LAN_IP}:${LLM_PORT}    llama.cpp chat UI, /v1 API, /health, /props
  ${LAN_IP}:${COMFY_PORT}    ComfyUI

  curl -s http://${LAN_IP}:${LLM_PORT}/health
  curl -s -o /dev/null -w '%{http_code}\n' http://${LAN_IP}:${COMFY_PORT}/system_stats

Both have no login of their own. Anyone on the subnet can use the model and
drive ComfyUI; a device on another network cannot reach either port. Do not
port-forward ${LLM_PORT} or ${COMFY_PORT} on your router.

Undo: sudo $0 --revert
EOF
