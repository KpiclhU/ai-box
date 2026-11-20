#!/usr/bin/env bash
# 80-lan-access.sh — expose the web UIs to your LAN behind HTTP basic auth.
#
#   sudo ./scripts/80-lan-access.sh                 # generates a password
#   sudo ./scripts/80-lan-access.sh --password 'a long passphrase'
#   sudo ./scripts/80-lan-access.sh --hostnames ai.lan comfy.lan
#   sudo ./scripts/80-lan-access.sh --dry-run       # print the config only
#   sudo ./scripts/80-lan-access.sh --remove        # stop exposing
#
# llama-server stays on 127.0.0.1:8080 and ComfyUI on 127.0.0.1:8188; Caddy
# listens on the LAN and proxies to them, asking for a password first.
#
# An existing Caddy is reused: the site blocks go into their own file and only
# one "import" line is added to your Caddyfile. Caddy is reloaded, not
# restarted, so your other sites keep serving. An SSH tunnel still works.
set -euo pipefail

CADDY_DIR="${AI_BOX_CADDY_DIR:-/etc/caddy}"   # override is for the test suite
CADDYFILE="$CADDY_DIR/Caddyfile"
SNIPPET="$CADDY_DIR/ai-box.caddy"
MARK="# ai-box LAN access (managed by scripts/80-lan-access.sh)"
IMPORT_LINE="import $SNIPPET"

CADDY_USER="ai"
PASSWORD=""
LLM_PORT=8090
COMFY_PORT=8190
LLM_HOST=""
COMFY_HOST=""
DRY_RUN=0
REMOVE=0
GENERATED=0

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
die() { echo "error: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --user)      CADDY_USER="${2:-}"; shift ;;
    --password)  PASSWORD="${2:-}"; shift ;;
    --ports)     LLM_PORT="${2:-}"; COMFY_PORT="${3:-}"; shift 2 ;;
    --hostnames) LLM_HOST="${2:-}"; COMFY_HOST="${3:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=1 ;;
    --remove)    REMOVE=1 ;;
    -h|--help)   usage 0 ;;
    *)           die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

[ -n "$CADDY_USER" ] || die "--user cannot be empty"
if [ -n "$LLM_HOST" ]; then
  [ -n "$COMFY_HOST" ] || die "--hostnames needs two names, e.g. --hostnames ai.lan comfy.lan"
else
  case "$LLM_PORT$COMFY_PORT" in
    ''|*[!0-9]*) die "--ports takes two port numbers, e.g. --ports 8090 8190" ;;
  esac
  [ "$LLM_PORT" != "$COMFY_PORT" ] || die "the two ports must differ"
fi

# AI_BOX_CADDY_DIR is the test-suite override and also lifts the root check.
if [ "$DRY_RUN" -eq 0 ] && [ -z "${AI_BOX_CADDY_DIR:-}" ]; then
  [ "$(id -u)" -eq 0 ] || die "needs root: sudo $0 --password '...'"
fi

have_caddy() { command -v caddy >/dev/null 2>&1; }
has_unit()   { command -v systemctl >/dev/null 2>&1 && systemctl cat caddy >/dev/null 2>&1; }

reload_caddy() {
  if has_unit; then
    systemctl reload caddy 2>/dev/null || systemctl restart caddy
  else
    echo "note: caddy is not managed by systemd here; reload it yourself (e.g. docker exec <ctr> caddy reload --config /etc/caddy/Caddyfile)" >&2
    return 0
  fi
}

# ---- remove -----------------------------------------------------------------
if [ "$REMOVE" -eq 1 ]; then
  if [ -f "$CADDYFILE" ] && grep -qF "$MARK" "$CADDYFILE"; then
    cp -a "$CADDYFILE" "$CADDYFILE.ai-box-tmp"
    # Drop the marker comment and the import line that follows it, keep the rest.
    awk -v m="$MARK" '
      $0 == m { skip = 1; next }
      skip && $0 ~ /^import .*ai-box\.caddy$/ { skip = 0; next }
      { skip = 0; print }
    ' "$CADDYFILE.ai-box-tmp" > "$CADDYFILE"
    rm -f "$CADDYFILE.ai-box-tmp"
    if have_caddy && ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
      die "removing the import left an invalid $CADDYFILE — check it with: caddy validate --config $CADDYFILE"
    fi
    reload_caddy || die "caddy reload failed after removing the import"
    echo "removed the ai-box import from $CADDYFILE"
  else
    echo "no ai-box import found in $CADDYFILE; nothing to undo there"
  fi
  rm -f "$SNIPPET"
  echo "LAN access removed; your other sites and the SSH tunnel are untouched."
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
fi

# ---- caddy binary -----------------------------------------------------------
EXISTING=0
[ -f "$CADDYFILE" ] && EXISTING=1

if have_caddy; then
  HASH="$(caddy hash-password --plaintext "$PASSWORD")"
elif [ "$DRY_RUN" -eq 1 ]; then
  HASH='$2a$14$PLACEHOLDERPLACEHOLDERPLACEHOLDERPLACEHOLDERPLACEHOLDE'
  echo "note: caddy is not installed; printing the config with a placeholder hash" >&2
else
  echo "No caddy found. Installing the Ubuntu package..." >&2
  apt-get install -y caddy >/dev/null || die "could not install caddy; run: sudo apt-get update && sudo apt-get install -y caddy"
  HASH="$(caddy hash-password --plaintext "$PASSWORD")"
fi

# Caddy 2.8 renamed basicauth to basic_auth; 2.9 dropped the old name.
DIRECTIVE="basic_auth"
if have_caddy && ! caddy version | grep -Eq 'v?2\.([89]|[1-9][0-9])'; then
  DIRECTIVE="basicauth"
fi

# ---- config -----------------------------------------------------------------
# The snippet holds only site blocks: global options ({ admin ... }, email,
# storage) may appear once per config and belong to your Caddyfile, not here.
render_snippet() { # <directive-name>
  if [ -n "$LLM_HOST" ]; then
    cat <<EOF
# Managed by ai-box/scripts/80-lan-access.sh — change the script, not this file.
$LLM_HOST {
	$1 {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy 127.0.0.1:8080 {
		flush_interval -1
	}
}

$COMFY_HOST {
	$1 {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy 127.0.0.1:8188
}
EOF
  else
    cat <<EOF
# Managed by ai-box/scripts/80-lan-access.sh — change the script, not this file.
:${LLM_PORT} {
	$1 {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy 127.0.0.1:8080 {
		flush_interval -1
	}
}

:${COMFY_PORT} {
	$1 {
		${CADDY_USER} ${HASH}
	}
	reverse_proxy 127.0.0.1:8188
}
EOF
  fi
}

# Bare :port blocks collide with whatever else already owns that port.
port_free() { # <port>
  command -v ss >/dev/null 2>&1 || return 0
  ! ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$1\$"
}

if [ -z "$LLM_HOST" ] && [ "$DRY_RUN" -eq 0 ] && has_unit; then
  port_free "$LLM_PORT" || die "port $LLM_PORT is already in use; pick another with --ports, or use --hostnames"
  port_free "$COMFY_PORT" || die "port $COMFY_PORT is already in use; pick another with --ports, or use --hostnames"
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "# --- $SNIPPET ---"
  render_snippet "$DIRECTIVE"
  if [ "$EXISTING" -eq 1 ] && ! grep -qF "$IMPORT_LINE" "$CADDYFILE" 2>/dev/null; then
    echo
    echo "# --- appended to $CADDYFILE ---"
    echo "$MARK"
    echo "$IMPORT_LINE"
  fi
  if [ "$GENERATED" -eq 1 ] && [ -z "$PASSWORD" ]; then :; fi
  exit 0
fi

# ---- install ----------------------------------------------------------------
mkdir -p "$CADDY_DIR"

# A brand-new install needs a Caddyfile of its own.
if [ ! -f "$CADDYFILE" ]; then
  printf '%s\n' '{' '	admin off' '}' > "$CADDYFILE"
  echo "created $CADDYFILE"
fi

render_snippet "$DIRECTIVE" > "$SNIPPET"
ORIG_IMPORTED=0
grep -qF "$IMPORT_LINE" "$CADDYFILE" && ORIG_IMPORTED=1

if [ "$ORIG_IMPORTED" -eq 0 ]; then
  cp -a "$CADDYFILE" "$CADDYFILE.ai-box-tmp"
  printf '\n%s\n%s\n' "$MARK" "$IMPORT_LINE" >> "$CADDYFILE"
fi

if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
  # Retry once with the other directive spelling before giving up.
  if [ "$DIRECTIVE" = "basic_auth" ]; then DIRECTIVE="basicauth"; else DIRECTIVE="basic_auth"; fi
  render_snippet "$DIRECTIVE" > "$SNIPPET"
  if ! caddy validate --config "$CADDYFILE" --adapter caddyfile >/dev/null 2>&1; then
    if [ "$ORIG_IMPORTED" -eq 0 ]; then mv "$CADDYFILE.ai-box-tmp" "$CADDYFILE"; fi
    rm -f "$SNIPPET"
    die "caddy rejected the config: caddy validate --config $CADDYFILE"
  fi
fi
rm -f "$CADDYFILE.ai-box-tmp"

if ! reload_caddy; then
  # Restore the Caddyfile so your other sites keep their old config.
  if [ "$ORIG_IMPORTED" -eq 0 ] && [ -f "$CADDYFILE" ]; then
    sed -i "\|$IMPORT_LINE|d" "$CADDYFILE" 2>/dev/null || true
  fi
  die "caddy did not accept the reload: journalctl -u caddy -n 50"
fi
systemctl is-active --quiet caddy 2>/dev/null || true

# ---- report -----------------------------------------------------------------
if [ -n "$LLM_HOST" ]; then
  LLM_URL="$LLM_HOST"
  COMFY_URL="$COMFY_HOST"
else
  # hostname -I is busybox/GNU specific, so never let it abort the script.
  LAN_IP="$( (hostname -I 2>/dev/null || true) | awk '{print $1}' || true)"
  [ -n "$LAN_IP" ] || LAN_IP="$(hostname 2>/dev/null || echo localhost)"
  LLM_URL="http://$LAN_IP:$LLM_PORT"
  COMFY_URL="http://$LAN_IP:$COMFY_PORT"
fi

cat <<EOF

LAN access is up through your existing Caddy (user: $CADDY_USER).
Site blocks: $SNIPPET   (imported from $CADDYFILE)

  $LLM_URL     llama.cpp chat UI, /v1 API, /models
  $COMFY_URL     ComfyUI

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
  - Your other sites were not touched, and caddy was reloaded, not restarted.
  - Plain HTTP on your LAN: the password is only base64 on the wire. On a
    shared network use --hostnames with names your Caddy already has
    certificates for.
  - Undo: sudo $0 --remove
  - The tunnel still works: ssh -N -L 8080:127.0.0.1:8080 -L 8188:127.0.0.1:8188 $(id -un)@$(hostname)
  - Do not expose these on your router. For access from outside use a VPN
    (WireGuard/Tailscale), not port forwarding.
EOF

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
  if [ -n "$LLM_HOST" ]; then
    cat <<EOF

ufw is active and your Caddy already serves 80/443, so nothing new to open.
EOF
  else
    cat <<EOF

ufw is active, so the new ports are still blocked. Allow them from your LAN:
  sudo ufw allow $LLM_PORT/tcp
  sudo ufw allow $COMFY_PORT/tcp
EOF
  fi
fi
