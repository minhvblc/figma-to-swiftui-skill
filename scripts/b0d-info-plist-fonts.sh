#!/usr/bin/env bash
# b0d-info-plist-fonts.sh — register fetched fonts in Info.plist's
# UIAppFonts array. Idempotent: re-runs are safe.
#
# Fix-spec D (continued). Without this, font files in Resources/Fonts/
# are NOT loaded by iOS at runtime, even if bundled. UIAppFonts is the
# manifest the OS reads to register .otf/.ttf at app launch.
#
# Usage:
#   scripts/b0d-info-plist-fonts.sh --info <Info.plist path> --fonts <Fonts dir>
#
# Exit codes:
#   0 — UIAppFonts in sync with Fonts dir contents
#   1 — write failed
#  64 — bad usage

set -uo pipefail

INFO_PLIST=""
FONTS_DIR=""

while [ $# -gt 0 ]; do
  case "$1" in
    --info) INFO_PLIST="$2"; shift 2 ;;
    --fonts) FONTS_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$INFO_PLIST" ] || { echo "FAIL: --info required" >&2; exit 64; }
[ -n "$FONTS_DIR" ] || { echo "FAIL: --fonts required" >&2; exit 64; }
[ -f "$INFO_PLIST" ] || { echo "FAIL: $INFO_PLIST not found" >&2; exit 64; }
[ -d "$FONTS_DIR" ] || { echo "FAIL: $FONTS_DIR not a directory" >&2; exit 64; }

# Collect font filenames (basename only, per UIAppFonts spec)
FONT_FILES=()
while IFS= read -r f; do
  FONT_FILES+=("$(basename "$f")")
done < <(find "$FONTS_DIR" -maxdepth 1 \( -name "*.otf" -o -name "*.ttf" \) | sort)

if [ ${#FONT_FILES[@]} -eq 0 ]; then
  echo "No font files in $FONTS_DIR — nothing to register"
  exit 0
fi

# Use plutil to inject UIAppFonts. plutil -insert UIAppFonts xml '<array>...</array>'
# is the official path, but it fails if UIAppFonts already exists. We use
# python3 + plistlib for robustness (handles both create and replace).
python3 - "$INFO_PLIST" "${FONT_FILES[@]}" <<'PY'
import plistlib
import sys
from pathlib import Path

plist_path = sys.argv[1]
fonts = sys.argv[2:]

p = Path(plist_path)
data = plistlib.loads(p.read_bytes())

existing = set(data.get('UIAppFonts', []))
new = set(fonts)

merged = sorted(existing | new)
data['UIAppFonts'] = merged

p.write_bytes(plistlib.dumps(data))

print(f"UIAppFonts: {len(merged)} font(s) registered")
for f in merged:
    marker = "+" if f in new and f not in existing else " "
    print(f"  {marker} {f}")
PY

if [ $? -ne 0 ]; then
  echo "GATE: FAIL: plist write failed"
  exit 1
fi

echo "GATE: PASS (b0d-info-plist-fonts)"
exit 0
