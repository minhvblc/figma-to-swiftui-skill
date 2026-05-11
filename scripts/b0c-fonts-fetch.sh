#!/usr/bin/env bash
# b0c-fonts-fetch.sh — auto-download custom fonts named in tokens.json so
# Font.custom("X-Y", ...) calls don't silently fall back to system fonts.
#
# Fix-spec D from SKILL_IMPROVEMENT_PLAN.md. Bible Widgets session: tokens
# named Inter + Playfair Display but no font files in bundle → all
# Font.custom() calls fell back to system serif/sans, breaking pixel match.
#
# Curated mirror table — known Google Fonts / open-source font sources.
# Adding a new family requires extending the case statement below.
#
# Usage:
#   scripts/b0c-fonts-fetch.sh --tokens <path> --output <Resources/Fonts dir>
#
# Exit codes:
#   0 — all fonts fetched
#   1 — one or more fonts failed to download
#   2 — unknown font family (no mirror entry) — STOP, ask user
#  64 — bad usage

set -uo pipefail

TOKENS=""
OUTPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --tokens) TOKENS="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$TOKENS" ] || { echo "usage: b0c-fonts-fetch.sh --tokens <json> --output <dir>" >&2; exit 64; }
[ -n "$OUTPUT" ] || { echo "FAIL: --output required" >&2; exit 64; }
[ -f "$TOKENS" ] || { echo "FAIL: tokens.json not found at $TOKENS" >&2; exit 64; }

mkdir -p "$OUTPUT"

# Extract font families from tokens.json. Supports two shapes:
#   1. fontFamilies: { primary: "Inter", display: "Playfair Display" }  (Bible Widgets shape)
#   2. fontFamily: "Inter"  (single-family legacy shape)
# Parses with python3 for robustness.
FAMILIES=$(python3 -c "
import json, sys
try:
    data = json.load(open('$TOKENS'))
except Exception as e:
    print(f'PARSE_ERROR:{e}', file=sys.stderr)
    sys.exit(2)

fams = set()
if isinstance(data.get('fontFamilies'), dict):
    fams.update(data['fontFamilies'].values())
if isinstance(data.get('fontFamilies'), list):
    fams.update(data['fontFamilies'])
if 'fontFamily' in data:
    fams.add(data['fontFamily'])
# Also collect from typography[].family if present
for entry in data.get('typography', []):
    if 'family' in entry:
        fams.add(entry['family'])

for f in sorted(fams):
    print(f)
")

if [ -z "$FAMILIES" ]; then
  echo "No custom fonts in tokens.json — nothing to fetch."
  exit 0
fi

# Weights to fetch per family. Could be parameterized later; for now hard-coded
# minimal set matching what Bible Widgets needed.
FETCH_INTER_WEIGHTS="Regular Medium SemiBold Bold"
FETCH_PLAYFAIR_WEIGHTS="SemiBold Bold"

FAIL_COUNT=0
FETCHED=()

while IFS= read -r family; do
  echo "Fetching: $family"
  case "$family" in
    "Inter")
      for w in $FETCH_INTER_WEIGHTS; do
        url="https://github.com/rsms/inter/raw/v4.0/docs/font-files/Inter-${w}.otf"
        dest="$OUTPUT/Inter-${w}.otf"
        if curl -sLfo "$dest" "$url" 2>/dev/null; then
          size=$(wc -c < "$dest" | tr -d ' ')
          if [ "$size" -gt 50000 ]; then
            echo "  ✓ Inter-${w}.otf ($size bytes)"
            FETCHED+=("Inter-${w}.otf")
          else
            echo "  ✘ Inter-${w}.otf — suspiciously small ($size bytes)"
            rm -f "$dest"
            FAIL_COUNT=$((FAIL_COUNT+1))
          fi
        else
          echo "  ✘ Inter-${w}.otf — curl failed"
          FAIL_COUNT=$((FAIL_COUNT+1))
        fi
      done
      ;;
    "Playfair Display")
      for w in $FETCH_PLAYFAIR_WEIGHTS; do
        url="https://github.com/google/fonts/raw/main/ofl/playfairdisplay/static/PlayfairDisplay-${w}.ttf"
        dest="$OUTPUT/PlayfairDisplay-${w}.ttf"
        if curl -sLfo "$dest" "$url" 2>/dev/null; then
          size=$(wc -c < "$dest" | tr -d ' ')
          if [ "$size" -gt 50000 ]; then
            echo "  ✓ PlayfairDisplay-${w}.ttf ($size bytes)"
            FETCHED+=("PlayfairDisplay-${w}.ttf")
          else
            rm -f "$dest"
            FAIL_COUNT=$((FAIL_COUNT+1))
          fi
        else
          FAIL_COUNT=$((FAIL_COUNT+1))
        fi
      done
      ;;
    *)
      echo "  ✘ Unknown font family '$family' — no mirror entry"
      echo "  Action: extend b0c-fonts-fetch.sh case statement, OR add manually to $OUTPUT"
      FAIL_COUNT=$((FAIL_COUNT+1))
      ;;
  esac
done <<< "$FAMILIES"

# Emit manifest
echo
echo "fetched=${#FETCHED[@]} failed=$FAIL_COUNT"
if [ $FAIL_COUNT -eq 0 ]; then
  echo "GATE: PASS (b0c-fonts-fetch)"
  exit 0
elif [ ${#FETCHED[@]} -gt 0 ]; then
  echo "GATE: FAIL (partial fetch — $FAIL_COUNT missing)"
  exit 1
else
  echo "GATE: FAIL (no fonts fetched — unknown families)"
  exit 2
fi
