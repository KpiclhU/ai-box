#!/usr/bin/env bash
# 81-front-door.sh — publish Open WebUI through a Caddy on ANOTHER box.
#
#   sudo ./scripts/81-front-door.sh
#   sudo ./scripts/81-front-door.sh --caddy-ip 192.168.150.13 \
#        --hostname ai.pilchlab.ca --ai-ip 192.168.150.40
#   sudo ./scripts/81-front-door.sh --dry-run
#   sudo ./scripts/81-front-door.sh --revert
#
# One site, one port. Open WebUI (:3000) is the only thing that leaves the box;
# llama-server (:8080) and ComfyUI (:8188) are forced back to loopback, because
# ComfyUI has no authentication and llama-server's UI is only for admins over SSH.
# Open WebUI ends up on 0.0.0.0 because Caddy is on another machine — but only
# after a default-deny firewall is in place. With no such firewall this script
# leaves the bind on 127.0.0.1 and exits non-zero rather than publish :3000 to
# every device on the network.
#
# If something other than ufw already limits :3000 (firewalld, nftables, a VLAN
# ACL), assert that and skip the gate:
#   sudo AI_BOX_UNFIREWALLED=1 ./scripts/81-front-door.sh --caddy-ip ... --hostname ...
#
# The snippet this writes goes on the Caddy box and is imported from its Caddyfile.
set -euo pipefail

TARGET_USER="${SUDO_USER:-${USER:-$(id -un)}}"
TARGET_HOME="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6 || true)"
[ -n "$TARGET_HOME" ] || TARGET_HOME="${HOME}"
CONFIG_DIR="${AI_BOX_CONFIG_DIR:-$TARGET_HOME/.config/ai-box}"
SNIPPET="$CONFIG_DIR/caddy-ai-box.caddy"

CADDY_IP="192.168.150.13"
AI_IP=""
HOSTNAME_="ai.pilchlab.ca"
WEB_PORT=3000
TLS_MODE="internal"          # internal | acme
DRY_RUN=0
REVERT=0

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }
say() { printf '\n\033[1m%s\033[0m\n' "$*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --caddy-ip)  CADDY_IP="${2:-}"; shift ;;
    --ai-ip)     AI_IP="${2:-}"; shift ;;
    --hostname)  HOSTNAME_="${2:-}"; shift ;;
    --port)      WEB_PORT="${2:-}"; shift ;;
    --tls)       TLS_MODE="${2:-}"; shift ;;
    --dry-run)   DRY_RUN=1 ;;
    --revert)    REVERT=1 ;;
    -h|--help)   usage 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

# AI_BOX_CONFIG_DIR is the test-suite override and also lifts the root check.
if [ "$DRY_RUN" -eq 0 ] && [ -z "${AI_BOX_CONFIG_DIR:-}" ]; then
  [ "$(id -u)" -eq 0 ] || die "needs root: sudo $0"
fi

env_set() { # <file> <KEY> <value>
  [ -f "$1" ] || return 0
  if grep -qE "^$2=" "$1"; then
    sed -i "s|^$2=.*|$2=$3|" "$1"
  else
    printf '%s=%s\n' "$2" "$3" >> "$1"
  fi
}

ufw_active() { command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; }

# "Active" is not enough: with a default-allow incoming policy an `allow from`
# rule describes one of the many hosts that may connect, so it restricts nothing.
ufw_default_deny() { ufw status verbose 2>/dev/null | grep -q '^Default: deny (incoming)'; }

# Delete every ufw rule that opens <port>/tcp, whatever its source. The legacy
# layout wrote `allow from <cidr> to any port 8080`, which `ufw --force delete
# allow 8080/tcp` does not match — so go by rule number instead.
ufw_close_port() {
  local port="$1" n nums
  ufw_active || return 0
  for _ in 1 2 3; do   # rule numbers shift as they are deleted
    nums="$(ufw status numbered 2>/dev/null | awk -v port="$port/tcp" '
      /ALLOW/ {
        num = ""
        for (i = 1; i <= NF; i++) {
          f = $i
          gsub(/^\[|\]$/, "", f)
          if (num == "" && f ~ /^[0-9]+$/) num = f
          if (f == port) { if (num != "") print num; break }
        }
      }' | sort -rn)"
    [ -n "$nums" ] || return 0
    for n in $nums; do ufw --force delete "$n" >/dev/null 2>&1 || true; done
  done
  return 0
}

# ---- revert -----------------------------------------------------------------
if [ "$REVERT" -eq 1 ]; then
  if [ -f "$SNIPPET" ]; then
    rm -f "$SNIPPET"
    echo "deleted $SNIPPET — remove its import line from the Caddy box too"
  fi
  if [ -f "$CONFIG_DIR/openwebui.env" ] && [ "$DRY_RUN" -eq 0 ]; then
    env_set "$CONFIG_DIR/openwebui.env" HOST 127.0.0.1
    chown "$TARGET_USER:$TARGET_USER" "$CONFIG_DIR"/*.env 2>/dev/null || true
    chmod 600 "$CONFIG_DIR"/*.env 2>/dev/null || true
    echo "openwebui.env: HOST back to 127.0.0.1"
  fi
  if [ "$DRY_RUN" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
    systemctl restart open-webui 2>/dev/null || true
  fi
  if command -v ufw >/dev/null 2>&1 && [ "$DRY_RUN" -eq 0 ]; then
    ufw --force delete allow from "$CADDY_IP" to any port "$WEB_PORT" proto tcp >/dev/null 2>&1 || true
    echo "removed the ufw rule for $CADDY_IP -> $WEB_PORT"
  fi
  echo "The box still serves Open WebUI on 127.0.0.1:$WEB_PORT; nothing is published."
  exit 0
fi

# ---- address ----------------------------------------------------------------
printf '%s' "$CADDY_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' \
  || die "--caddy-ip wants an IPv4 address, got: $CADDY_IP"
printf '%s' "$HOSTNAME_" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$' \
  || die "--hostname wants a DNS name, got: $HOSTNAME_"
case "$TLS_MODE" in internal|acme) ;; *) die "--tls is internal or acme" ;; esac

if [ -n "$AI_IP" ]; then
  printf '%s' "$AI_IP" | grep -Eq '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || die "--ai-ip wants an IPv4 address"
else
  AI_IP="$( (hostname -I 2>/dev/null || true) | awk '{print $1}' || true)"
  [ -n "$AI_IP" ] || die "could not work out this box's IP; pass --ai-ip 192.168.150.40"
fi

[ -f "$CONFIG_DIR/comfyui.env" ] || die "no comfyui.env in $CONFIG_DIR — run ./scripts/50-install-services.sh first"
[ -f "$CONFIG_DIR/openwebui.env" ] || die "no openwebui.env in $CONFIG_DIR — install Open WebUI first (scripts/45 + 50)"

# ---- the box side: loopback for the backends, LAN for nobody -----------------
say "Keeping llama-server and ComfyUI on loopback"
for f in "$CONFIG_DIR/llama-server.env" "$CONFIG_DIR/llama-router.env" "$CONFIG_DIR/comfyui.env"; do
  [ -f "$f" ] || continue
  if grep -qE '^HOST=127\.0\.0\.1$' "$f"; then
    echo "  $(basename "$f"): already 127.0.0.1"
  elif [ "$DRY_RUN" -eq 1 ]; then
    echo "  would set HOST=127.0.0.1 in $(basename "$f")"
  else
    env_set "$f" HOST 127.0.0.1
    echo "  $(basename "$f"): HOST set back to 127.0.0.1"
  fi
done

# The reverse proxy needs the origin it is served from, or uploaded links and
# password-reset style links point at localhost.
say "Setting WEBUI_URL=https://$HOSTNAME_"
if [ "$DRY_RUN" -eq 1 ]; then
  echo "  would set WEBUI_URL in openwebui.env"
else
  env_set "$CONFIG_DIR/openwebui.env" WEBUI_URL "https://$HOSTNAME_"
fi

# ---- firewall, BEFORE the bind ----------------------------------------------
# A wildcard bind with no firewall in front of it is reachable by every device on
# the network for as long as the service runs, so the rule goes in first and the
# bind only follows if that rule is real.
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
      echo "  would allow $CADDY_IP -> $WEB_PORT/tcp (incoming denied by default)"
      echo "  would close any allow rule for 8080/8188"
    else
      ufw allow from "$CADDY_IP" to any port "$WEB_PORT" proto tcp >/dev/null
      for p in 8080 8188; do ufw_close_port "$p"; done
      echo "  allowed $CADDY_IP -> $WEB_PORT/tcp; incoming denied by default"
      ufw status | grep -E "($WEB_PORT|8080|8188)/tcp" | sed 's/^/    /' || true
    fi
    ;;
  override)
    LAN_BIND=1
    echo "  AI_BOX_UNFIREWALLED=1: no ufw rule added — :$WEB_PORT must already be"
    echo "  limited to $CADDY_IP by something else. Verify that before relying on it."
    ;;
  allow-policy)
    echo "  not binding the LAN: ufw is active but its default incoming policy is"
    echo "  allow, so 'ufw allow from $CADDY_IP' would not restrict anything."
    ;;
  inactive)
    echo "  not binding the LAN: ufw is installed but not active, so :$WEB_PORT would"
    echo "  be reachable from the whole network."
    ;;
  absent)
    echo "  not binding the LAN: ufw is not installed, so :$WEB_PORT would be"
    echo "  reachable from the whole network."
    ;;
esac

# Caddy is on another host, so 127.0.0.1 makes every proxied request fail. Only
# take the wildcard bind once the guard above proves something covers it.
say "Opening :$WEB_PORT to $CADDY_IP (Open WebUI binds all interfaces)"
if [ "$DRY_RUN" -eq 1 ]; then
  if [ "$LAN_BIND" -eq 1 ]; then
    echo "  would set HOST=0.0.0.0 in openwebui.env"
  else
    echo "  would keep HOST=127.0.0.1 in openwebui.env (nothing in front of :$WEB_PORT)"
  fi
elif [ "$LAN_BIND" -eq 1 ]; then
  env_set "$CONFIG_DIR/openwebui.env" HOST 0.0.0.0
  echo "  openwebui.env: HOST=0.0.0.0; ufw allows only $CADDY_IP to port $WEB_PORT"
else
  env_set "$CONFIG_DIR/openwebui.env" HOST 127.0.0.1
  echo "  openwebui.env: HOST=127.0.0.1 — nothing is published"
fi
# sed -i runs as root here; put the files back under the service user so the
# units can still read them.
if [ "$DRY_RUN" -eq 0 ]; then
  chown "$TARGET_USER:$TARGET_USER" "$CONFIG_DIR"/*.env 2>/dev/null || true
  chmod 600 "$CONFIG_DIR"/*.env 2>/dev/null || true
fi

# ---- Caddy snippet ----------------------------------------------------------
if [ "$TLS_MODE" = internal ]; then
  TLS_BLOCK='	# Private address, so ACME cannot reach it: Caddy'"'"'s local CA (step 2 below).
	tls internal'
else
  TLS_BLOCK='	# Needs DNS-01 or a publicly reachable 80/443.
	tls {
		# dns <provider> <token>
	}'
fi

render_snippet() {
  cat <<EOF
# Generated by ai-box/scripts/81-front-door.sh — paste on the Caddy box.
# One site: Open WebUI. The model and ComfyUI are loopback-only on ai-box.

$HOSTNAME_ {
$TLS_BLOCK

	reverse_proxy $AI_IP:$WEB_PORT {
		flush_interval -1
	}
}
EOF
}

say "Site block for the Caddy box"
if [ "$DRY_RUN" -eq 1 ]; then
  render_snippet
else
  mkdir -p "$CONFIG_DIR"
  render_snippet > "$SNIPPET"
  chown "$TARGET_USER:$TARGET_USER" "$SNIPPET" 2>/dev/null || true
  chmod 644 "$SNIPPET"
  echo "wrote $SNIPPET"
fi

# ---- restart the front door -------------------------------------------------
if [ "$DRY_RUN" -eq 0 ] && command -v systemctl >/dev/null 2>&1; then
  systemctl restart open-webui 2>/dev/null && echo "restarted open-webui" || true
fi

if [ "$LAN_BIND" -eq 0 ] && [ "$DRY_RUN" -eq 0 ]; then
  cat <<EOF

Nothing was published: Open WebUI is back on 127.0.0.1:$WEB_PORT, so Caddy will
answer 502. That is deliberate — a wildcard bind is only safe once the rest of
the network is blocked, and nothing here is doing the blocking yet.

Fix it on this box, then re-run this script:

  sudo ufw allow OpenSSH
  sudo ufw default deny incoming
  sudo ufw enable
  sudo ufw allow from $CADDY_IP to any port $WEB_PORT proto tcp

Check: ufw status verbose     # want: Status: active, Default: deny (incoming)

If a different firewall (firewalld, nftables, a VLAN ACL) already limits
:$WEB_PORT to $CADDY_IP, assert that instead and re-run:

  sudo AI_BOX_UNFIREWALLED=1 $0 --caddy-ip $CADDY_IP --hostname $HOSTNAME_
EOF
  exit 1
fi

cat <<EOF

First: ${HOSTNAME_} must resolve to ${CADDY_IP} from the PC that opens it
(local DNS, or an A record on a public zone).

Now, on the Caddy box (${CADDY_IP}):

  1. Copy the snippet and import it:
       scp $TARGET_USER@$AI_IP:$SNIPPET /tmp/caddy-ai-box.caddy
       sudo mv /tmp/caddy-ai-box.caddy /etc/caddy/caddy-ai-box.caddy
       # add this one line to that VM's /etc/caddy/Caddyfile:
       #   import /etc/caddy/caddy-ai-box.caddy
       sudo caddy validate --config /etc/caddy/Caddyfile && sudo systemctl reload caddy

EOF

if [ "$TLS_MODE" = internal ]; then
  cat <<EOF
  2. Trust this site's certificate on Windows. Caddy's local CA lives on the VM:
       sudo cat /var/lib/caddy/.local/share/caddy/pki/authorities/local/root.crt > root.crt
     Copy root.crt to the PC, then in an Administrator prompt:
       certutil -addstore -f Root root.crt
     (or push it to every PC by GPO/Intune — do not click through the warning instead)

EOF
fi

cat <<EOF
  3. Open https://$HOSTNAME_ from a Windows PC and sign in with the admin email and
     password printed by 50-install-services.sh. Sign-ups are already off; create
     one account per person under Admin -> Settings -> Users.

Verify from the box:
  ss -ltnp | grep -E ':(3000|8080|8188)\\b'     # 3000 on 0.0.0.0; 8080/8188 on 127.0.0.1
  curl -s -o /dev/null -w '%{http_code}\\n' http://127.0.0.1:$WEB_PORT/
EOF
