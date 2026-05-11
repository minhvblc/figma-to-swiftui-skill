#!/usr/bin/env bash
# c8-fonts-registered.sh — verify every Font.custom("X-Y", ...) literal in
# Swift code has a matching font file in Resources/Fonts/ AND is listed in
# Info.plist UIAppFonts. Catches the silent-system-fallback bug.
#
# Fix-spec D enforcement (Bible Widgets session: AppFont.swift referenced
# "Inter-Medium" etc. but no font files were in bundle, so iOS silently
# used system fonts — Figma typography never matched).
#
# Usage:
#   scripts/c8-fonts-registered.sh --src <project-folder>
#
# Exit codes:
#   0 — all referenced fonts present + registered
#   1 — at least one font referenced in code but not registered/bundled
#  64 — bad usage

set -uo pipefail

SRC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$SRC" ] || { echo "usage: c8-fonts-registered.sh --src <folder>" >&2; exit 64; }
[ -d "$SRC" ] || { echo "FAIL: $SRC not a directory" >&2; exit 64; }

# Find Info.plist
INFO=$(find "$SRC" -maxdepth 4 -name "Info.plist" -not -path "*/Pods/*" -not -path "*/build/*" 2>/dev/null | head -1)
if [ -z "$INFO" ]; then
  echo "GATE: SKIP (no Info.plist found in $SRC)"
  exit 0
fi

# Find Fonts directory
FONTS_DIR=$(find "$SRC" -maxdepth 4 -type d -name "Fonts" -not -path "*/Pods/*" 2>/dev/null | head -1)

# Extract PostScript names referenced in code via Font.custom("...") OR
# .custom("...") (Swift type-inference shorthand). Both are valid SwiftUI
# Font.custom call sites.
REFERENCED=$(grep -rohE '(Font)?\.custom\("[^"]+"' "$SRC" --include="*.swift" 2>/dev/null \
  | sed -E 's/(Font)?\.custom\("([^"]+)"/\2/' | sort -u)

if [ -z "$REFERENCED" ]; then
  echo "GATE: SKIP (no Font.custom references in code)"
  exit 0
fi

# Read UIAppFonts from Info.plist
REGISTERED=$(python3 -c "
import plistlib
try:
    data = plistlib.loads(open('$INFO', 'rb').read())
    for f in data.get('UIAppFonts', []):
        print(f)
except Exception:
    pass
")

FAIL_COUNT=0
while IFS= read -r ps_name; do
  # PostScript name → expected filename (.otf or .ttf)
  # Convention: "Inter-Medium" → Inter-Medium.otf or Inter-Medium.ttf
  # In Info.plist UIAppFonts: lists basenames with extension.
  found_in_plist=0
  for candidate in "$ps_name.otf" "$ps_name.ttf"; do
    if echo "$REGISTERED" | grep -qF "$candidate"; then
      found_in_plist=1
      break
    fi
  done

  found_on_disk=0
  if [ -n "$FONTS_DIR" ]; then
    if [ -f "$FONTS_DIR/$ps_name.otf" ] || [ -f "$FONTS_DIR/$ps_name.ttf" ]; then
      found_on_disk=1
    fi
  fi

  if [ $found_in_plist -eq 1 ] && [ $found_on_disk -eq 1 ]; then
    echo "✓ $ps_name (UIAppFonts + on disk)"
  else
    gap=""
    [ $found_in_plist -eq 0 ] && gap="$gap UIAppFonts"
    [ $found_on_disk -eq 0 ] && gap="$gap Resources/Fonts"
    echo "✘ $ps_name — missing from:$gap"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
done <<< "$REFERENCED"

if [ $FAIL_COUNT -eq 0 ]; then
  echo "GATE: PASS (c8-fonts-registered)"
  exit 0
else
  echo "GATE: FAIL: $FAIL_COUNT font(s) referenced in code but not properly registered"
  echo "Fix: scripts/b0c-fonts-fetch.sh + scripts/b0d-info-plist-fonts.sh"
  exit 1
fi
