#!/usr/bin/env bash
# 80-lan-access.sh — expose the web UIs to your LAN behind HTTP basic auth.
#
#   sudo ./scripts/80-lan-access.sh --password 'a long passphrase'
#   sudo ./scripts/80-lan-access.sh --user ai --password ... --ports 8090 8190
#   sudo ./scripts/80-lan-access.sh --dry-run          # print the Caddyfile only
#   sudo ./scripts/80-lan-access.sh --remove           # stop exposing, restore Caddy
#
# llama-server stays on 127.0.0.1:8080 and ComfyUI on 127.0.0.1:8188. Caddy
# listens on the LAN and proxies to them, asking for a password first. Nothing
# else is rebound, so an SSH tunnel keeps working exactly as before.
set -euo pipefail

CADDYFILE=/etc/caddy/Caddyfile
BACKUP=/etc/caddy/Caddyfile.ai-box.bak
CADDY_USER="ai"
PASSWORD=""
LLM_PORT=8090
COMFY_PORT=8190
DRY_RUN=0
REMOVE=0

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user)     CADDY_USER="${2:-}"; shift ;;
    --password) PASSWORD="${2:-}"; shift ;;
    --ports)    LLM_PORT="${2:-}"; COMFY_PORT="${3:-}"; shift 2 ;;
    --dry-run)  DRY_RUN=1 ;;
    --remove)   REMOVE=1 ;;
    -h|--help)  usage 0 ;;
    *)          die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ -n "$CADDY_USER" ] || die "--user cannot be empty"
case "$LLM_PORT$COMFY_PORT" in
  ''|*[!0-9]*) die "--ports takes two port numbers, e.g. --ports 8090 8190" ;;
esac
[ "$LLM_PORT" != "$COMFY_PORT" ] || die "the two ports must differ"

if [ "$DRY_RUN" -eq 0 ]; then
  [ "$(id -u)" -eq 0 ] || die "needs root: sudo $0 --password '...'"
fi

# ---- remove -----------------------------------------------------------------
if [ "$REMOVE" -eq 1 ]; then
  if [ -f "$BACKUP" ]; then
    mv "$BACKUP" "$CADDYFILE"
    echo "restored the previous $CADDYFILE"
  elif [ -f "$CADDYFILE" ] && ! grep -q '80-lan-access.sh' "$CADDYFILE"; then
    die "$CADDYFILE was not written by this script, so it was left alone; remove the site blocks by hand"
  else
    cat > "$CADDYFILE" <<'EOF'
# Managed by ai-box/scripts/80-lan-access.sh
{
	admin off
}
EOF
    echo "wrote a minimal $CADDYFILE (nothing proxied)"
  fi
  systemctl disable --now caddy 2>/dev/null || true
  systemctl reload caddy 2>/dev/null || true
  echo "LAN access removed; the SSH tunnel still works."
  exit 0
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
else
  GENERATED=0
fi

# ---- caddy ------------------------------------------------------------------
if command -v caddy >/dev/null 2>&1; then
  HASH="$(caddy hash-password --plaintext "$PASSWORD")"
else
  if [ "$DRY_RUN" -eq 1 ]; then
    HASH='$2a$14$PLACEHOLDERPLACEHOLDERPLACEHOLDERPLACEHOLDERPLACEHOLDE'
    echo "note: caddy is not installed; printing the config with a placeholder hash" >&2
  else
    echo "Installing caddy (Ubuntu package)..." >&2
    apt-get install -y caddy >/dev/null || die "could not install caddy; run: sudo apt-get update && sudo apt-get install -y caddy"
    HASH="$(caddy hash-password --plaintext "$PASSWORD")"
  fi
fi

# Note: $HASH is expanded by the heredoc as a variable, and variable contents are
# not re-expanded, so the $2a$14$... in a bcrypt hash survives untouched.
render() { # <directive-name>
  cat <<EOF
# Managed by ai-box/scripts/80-lan-access.sh — edit the script, not this file.
{
	admin off
}

# llama.cpp: chat UI, /v1 API, /models, /tools
:${LLM_PORT} {
	$1 {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy 127.0.0.1:8080 {
		flush_interval -1
	}
}

# ComfyUI, including its WebSocket
:${COMFY_PORT} {
	$1 {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy 127.0.0.1:8188
}
EOF
}

# Caddy 2.8 renamed basicauth to basic_auth and 2.9 dropped the old name.
DIRECTIVE="basic_auth"
if command -v caddy >/dev/null 2>&1; then
  if ! caddy version | grep -Eq 'v?2\.([89]|[1-9][0-9])'; then
    DIRECTIVE="basicauth"
  fi
fi
CONFIG="$(render "$DIRECTIVE")"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$CONFIG"
  exit 0
fi

# ---- install ----------------------------------------------------------------
if [ -f "$CADDYFILE" ] && [ ! -f "$BACKUP" ]; then
  cp -a "$CADDYFILE" "$BACKUP"
fi
printf '%s\n' "$CONFIG" > "$CADDYFILE"

if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  # The directive name is the one thing that varies between caddy majors.
  if [ "$DIRECTIVE" = "basic_auth" ]; then
    DIRECTIVE="basicauth"
    render "$DIRECTIVE" > "$CADDYFILE"
  else
    DIRECTIVE="basic_auth"
    render "$DIRECTIVE" > "$CADDYFILE"
  fi
  caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null \
    || die "caddy rejected the generated config: caddy validate --config $CADDYFILE"
fi

systemctl enable caddy >/dev/null 2>&1 || true
systemctl restart caddy
sleep 1
systemctl is-active --quiet caddy || die "caddy did not start: journalctl -u caddy -n 50"

# ---- report -----------------------------------------------------------------
LAN_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
[ -n "$LAN_IP" ] || LAN_IP="$(hostname)"

cat <<EOF

LAN access is up, behind basic auth (user: $CADDY_USER).

  http://$LAN_IP:$LLM_PORT     llama.cpp chat UI, /v1 API, /models
  http://$LAN_IP:$COMFY_PORT     ComfyUI

EOF

if [ "$GENERATED" -eq 1 ]; then
  cat <<EOF
Generated password (shown once, store it in your password manager):
  $PASSWORD

Change it with: sudo $0 --user $CADDY_USER --password 'new one'

EOF
fi

cat <<EOF
Notes:
  - Plain HTTP on your LAN: the password is only base64 on the wire. On a
    network you do not fully trust, put a hostname in the config and add
    "tls internal" to each site block so Caddy issues a local certificate.
  - The tunnel still works: ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 $(id -un)@$(hostname)
  - Do not expose these ports on your router. For access from outside, use a
    VPN (Tailscale/WireGuard), not port forwarding.
EOF

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  cat <<EOF

ufw is active, so the new ports are still blocked. Allow them from your LAN:
  sudo ufw allow $LLM_PORT/tcp
  sudo ufw allow $COMFY_PORT/tcp
EOF
fi
