#!/usr/bin/env bash
# 10-gpu-memory.sh — raise GPU-addressable memory on a unified-memory AMD APU.
#
# Keeps the BIOS carve-out small and raises the TTM/GTT limit, which is what AMD
# recommends for Strix Halo. Nothing is permanently removed from the OS the way a
# large BIOS reservation would be.
#
#   sudo ./scripts/10-gpu-memory.sh 48      # 48 GiB (recommended for a 64 GB box)
#   sudo ./scripts/10-gpu-memory.sh 44 --dry-run
#
# Reboot afterwards. Undo with: sudo ./scripts/10-gpu-memory.sh --remove
set -euo pipefail

DEFAULT_GIB=48
GRUB_FILE=/etc/default/grub
DRY_RUN=0
REMOVE=0
GIB=""

usage() { sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --remove)  REMOVE=1 ;;
    -h|--help) usage 0 ;;
    --) shift; break ;;
    -*) echo "unknown flag: $1" >&2; usage 1 ;;
    *)  GIB="$1" ;;
  esac
  shift
done

if [ "$(id -u)" -ne 0 ]; then
  echo "needs root: sudo $0 ${GIB:-$DEFAULT_GIB}" >&2
  exit 1
fi

if [ "$REMOVE" -eq 0 ]; then
  GIB="${GIB:-$DEFAULT_GIB}"
  case "$GIB" in
    ''|*[!0-9]*) echo "argument must be an integer number of GiB, got: $GIB" >&2; exit 1 ;;
  esac
  if [ "$GIB" -lt 8 ] || [ "$GIB" -gt 56 ]; then
    echo "refusing $GIB GiB: valid range on a 64 GB box is 8..56" >&2
    exit 1
  fi
  if [ "$GIB" -gt 52 ]; then
    echo "warning: $GIB GiB leaves under ~12 GB for the OS. Model loads may be OOM-killed." >&2
  fi
fi

if [ ! -f "$GRUB_FILE" ]; then
  echo "$GRUB_FILE not found — this script targets Debian/Ubuntu GRUB." >&2
  echo "Fedora: add the same parameters with grubby, e.g.:" >&2
  echo "  sudo grubby --update-kernel=ALL --args='ttm.pages_limit=12582912 ttm.page_pool_size=12582912'" >&2
  exit 1
fi

PAGES=0
if [ "$REMOVE" -eq 0 ]; then
  PAGES=$(( GIB * 262144 ))   # 4 KiB pages per GiB
fi

backup="${GRUB_FILE}.ai-box.$(date +%Y%m%d%H%M%S)"
cp -a "$GRUB_FILE" "$backup"
echo "backed up $GRUB_FILE -> $backup"

PAGES="$PAGES" REMOVE="$REMOVE" DRY_RUN="$DRY_RUN" python3 - "$GRUB_FILE" <<'PY'
import os, re, sys, pathlib

path = pathlib.Path(sys.argv[1])
remove = os.environ["REMOVE"] == "1"
dry = os.environ["DRY_RUN"] == "1"
pages = os.environ.get("PAGES", "0")

key = "GRUB_CMDLINE_LINUX_DEFAULT"
pattern = re.compile(r'^([ \t]*%s=)("?)(.*?)\2[ \t]*$' % key, re.M)

text = path.read_text()
match = pattern.search(text)
if not match:
    sys.exit("could not find GRUB_CMDLINE_LINUX_DEFAULT in %s" % path)

current = match.group(3).split()
drop = {"ttm.pages_limit", "ttm.page_pool_size", "amdgpu.gttsize"}
kept = [t for t in current if t.split("=")[0] not in drop]

if not remove:
    kept += ["ttm.pages_limit=%s" % pages, "ttm.page_pool_size=%s" % pages]

new_line = '%s"%s"' % (match.group(1), " ".join(kept))
old_line = match.group(0)
print("old: %s" % old_line)
print("new: %s" % new_line)

if dry:
    print("(dry run — %s not modified)" % path)
    sys.exit(0)

path.write_text(text[:match.start()] + new_line + text[match.end():])
PY

if [ "$DRY_RUN" -eq 1 ]; then
  echo "dry run: no bootloader update performed"
  exit 0
fi

if command -v update-grub >/dev/null 2>&1; then
  update-grub
else
  echo "update-grub not found; run your distro's GRUB regeneration manually" >&2
  exit 1
fi

if [ "$REMOVE" -eq 1 ]; then
  echo
  echo "ttm parameters removed. Reboot to restore the default (50% of RAM) limit."
else
  echo
  echo "GPU-addressable memory set to ${GIB} GiB (${PAGES} pages of 4 KiB)."
  echo "Reboot, then verify:"
  echo "  cat /sys/module/ttm/parameters/pages_limit    # expect ${PAGES}"
  echo "  ./scripts/00-preflight.sh"
fi
