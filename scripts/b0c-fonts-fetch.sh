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

# Extract font families from tokens.json. Supports three shapes:
#   1. fontFamilies: { primary: "Inter", display: "Playfair Display" }  (Bible Widgets shape)
#   2. fontFamily: "Inter"  (single-family legacy shape)
#   3. typography[].fontFamily  (MCPFigma 0.3.0+ output schema) OR
#      typography[].family      (pre-0.3.0 / hand-rolled fallback shape)
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
# Collect from typography[] — try fontFamily (MCPFigma 0.3.0+) first,
# fall back to family. Without the fontFamily branch, a tokens.json
# emitted by MCPFigma 0.3.0+ would parse as having zero custom fonts and
# the script would early-exit with 'No custom fonts in tokens.json',
# silently leaving Font.custom() calls to fall back to system fonts.
for entry in data.get('typography', []):
    name = entry.get('fontFamily') or entry.get('family')
    if name:
        fams.add(name)

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

# Mirror URL precheck — HEAD request before download. -fsLI suppresses output,
# follows redirects, returns non-zero on 4xx/5xx. A dead mirror should fail
# fast with a precise error instead of partial-fetching empty files.
verify_url() {
  local url="$1" label="$2"
  if curl -fsLI "$url" >/dev/null 2>&1; then
    return 0
  fi
  echo "  ✘ $label — precheck failed (HEAD $url returned non-2xx)"
  echo "      mirror likely dead; update b0c-fonts-fetch.sh URLs"
  return 1
}

FAIL_COUNT=0
FETCHED=()

# Inter v4.x reorganized — fonts now ship inside the release zip artifact
# under extras/ttf/ instead of the legacy docs/font-files/ path. Pull the
# whole release zip once per call and extract the needed weights.
fetch_inter() {
  local archive_url="https://github.com/rsms/inter/releases/download/v4.0/Inter-4.0.zip"
  local tmp_zip; tmp_zip=$(mktemp -t inter-release.XXXXXX.zip)
  local tmp_dir; tmp_dir=$(mktemp -d -t inter-release.XXXXXX)
  trap 'rm -rf "$tmp_zip" "$tmp_dir"' RETURN

  if ! verify_url "$archive_url" "Inter release zip"; then
    for w in $FETCH_INTER_WEIGHTS; do FAIL_COUNT=$((FAIL_COUNT+1)); done
    return 1
  fi

  if ! curl -fsLo "$tmp_zip" "$archive_url" 2>/dev/null; then
    echo "  ✘ Inter release zip — curl failed"
    for w in $FETCH_INTER_WEIGHTS; do FAIL_COUNT=$((FAIL_COUNT+1)); done
    return 1
  fi
  if ! unzip -qo "$tmp_zip" -d "$tmp_dir" 2>/dev/null; then
    echo "  ✘ Inter release zip — unzip failed"
    for w in $FETCH_INTER_WEIGHTS; do FAIL_COUNT=$((FAIL_COUNT+1)); done
    return 1
  fi

  for w in $FETCH_INTER_WEIGHTS; do
    local src; src=$(find "$tmp_dir" -name "Inter-${w}.ttf" -type f 2>/dev/null | head -1)
    [ -z "$src" ] && src=$(find "$tmp_dir" -name "Inter-${w}.otf" -type f 2>/dev/null | head -1)
    if [ -n "$src" ]; then
      local ext="${src##*.}"
      local dest="$OUTPUT/Inter-${w}.${ext}"
      cp "$src" "$dest"
      local size; size=$(wc -c < "$dest" | tr -d ' ')
      if [ "$size" -gt 50000 ]; then
        echo "  ✓ Inter-${w}.${ext} ($size bytes)"
        FETCHED+=("Inter-${w}.${ext}")
      else
        echo "  ✘ Inter-${w} — extracted file unexpectedly small ($size bytes)"
        rm -f "$dest"
        FAIL_COUNT=$((FAIL_COUNT+1))
      fi
    else
      echo "  ✘ Inter-${w} — not in release zip"
      FAIL_COUNT=$((FAIL_COUNT+1))
    fi
  done
}

# Playfair Display ships a variable font at the top of the directory; the
# legacy static/ subdir was removed in 2024-Q4. The variable file covers
# all weights via the `wght` axis; SwiftUI Font.custom("PlayfairDisplay",
# size: ...) with `.fontWeight(.semibold)` resolves the right glyph cut.
fetch_playfair() {
  local url="https://github.com/google/fonts/raw/main/ofl/playfairdisplay/PlayfairDisplay%5Bwght%5D.ttf"
  local dest="$OUTPUT/PlayfairDisplay.ttf"

  if ! verify_url "$url" "PlayfairDisplay variable font"; then
    FAIL_COUNT=$((FAIL_COUNT+1))
    return 1
  fi
  if ! curl -fsLo "$dest" "$url" 2>/dev/null; then
    echo "  ✘ PlayfairDisplay.ttf — curl failed"
    FAIL_COUNT=$((FAIL_COUNT+1))
    return 1
  fi
  local size; size=$(wc -c < "$dest" | tr -d ' ')
  if [ "$size" -gt 100000 ]; then
    echo "  ✓ PlayfairDisplay.ttf (variable font, $size bytes)"
    FETCHED+=("PlayfairDisplay.ttf")
  else
    echo "  ✘ PlayfairDisplay.ttf — suspiciously small ($size bytes)"
    rm -f "$dest"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

while IFS= read -r family; do
  echo "Fetching: $family"
  case "$family" in
    "Inter") fetch_inter ;;
    "Playfair Display") fetch_playfair ;;
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
