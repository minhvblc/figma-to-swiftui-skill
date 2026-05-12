#!/usr/bin/env bash
# c6-asset-completeness.sh — verify every Figma-tagged asset landed in the
# Asset Catalog AND that no `Image(systemName:)` substituted for a Figma
# asset.
#
# Two checks (both must pass):
#   1. Every taggedAssets[].exportName in the registry has a matching
#      *.imageset/ directory under --xcassets (recursive). Missing imagesets
#      mean the unified-export path skipped an asset.
#   2. `Image(systemName:` appears in --src only when the call is on the
#      allow-list OR carries an explicit `// allow-systemName:` opt-in
#      (same line or previous line). Anything else is a banned substitution.
#
# Usage:
#   c6-asset-completeness.sh --registry <path> --xcassets <path> --src <path>
#
# Exit codes:
#   0 — pass (no missing assets, no systemName violations)
#   1 — fail (one or more missing assets and/or unauthorized systemName)
#   64 — bad usage
#   65 — input not found / not parsable

set -euo pipefail

REGISTRY=""
XCASSETS=""
SRC=""

print_usage() {
  cat <<'USAGE' >&2
usage: c6-asset-completeness.sh --registry <path-to-registry.json> \
                                --xcassets <path-to-Assets.xcassets> \
                                --src <path-to-swift-src-root>

Verifies every taggedAssets[].exportName has a matching *.imageset/ directory
under --xcassets, and that every `Image(systemName:` in --src is allow-listed
or carries an explicit `// allow-systemName:` opt-in.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --registry) REGISTRY="${2:-}"; shift 2 ;;
    --xcassets) XCASSETS="${2:-}"; shift 2 ;;
    --src)      SRC="${2:-}";      shift 2 ;;
    -h|--help)  print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

if [ -z "$REGISTRY" ] || [ -z "$XCASSETS" ] || [ -z "$SRC" ]; then
  print_usage
  exit 64
fi

[ -s "$REGISTRY" ]  || { echo "FAIL: registry not found or empty: $REGISTRY" >&2; exit 65; }
[ -d "$XCASSETS" ]  || { echo "FAIL: xcassets is not a directory: $XCASSETS" >&2; exit 65; }
[ -d "$SRC" ]       || { echo "FAIL: src is not a directory: $SRC"           >&2; exit 65; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 65; }

# Color helpers — only when stdout is a TTY.
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

# 1. Missing imagesets — strict version ───────────────────────────────────────
# Three layers of check per registry-tagged asset:
#   (a) `.imageset/` directory exists under XCASSETS
#   (b) directory has Contents.json
#   (c) directory has at least one PNG of size > 0
#
# Layer (c) closes the "empty imageset" failure mode where
# figma_export_assets_unified created the wrapper directory but the actual
# render call failed silently — c6 used to PASS because the directory
# existed; Xcode then errored at build time with "Asset X has no image
# representation".
EXPORT_NAMES=$(jq -r '(.taggedAssets // [])[] | select(.exportName != null) | .exportName' "$REGISTRY")
MISSING_ASSETS=()  # imageset directory not found
EMPTY_ASSETS=()    # imageset exists but no PNG > 0 bytes
NO_CONTENTS=()     # imageset exists but Contents.json missing
TOTAL_REG=0
while IFS= read -r name; do
  [ -z "$name" ] && continue
  TOTAL_REG=$((TOTAL_REG + 1))
  found=$(find "$XCASSETS" -type d -name "${name}.imageset" -maxdepth 6 2>/dev/null | head -1)
  if [ -z "$found" ]; then
    MISSING_ASSETS+=("$name")
    continue
  fi
  if [ ! -f "$found/Contents.json" ]; then
    NO_CONTENTS+=("$name|$found")
    continue
  fi
  # Verify at least one PNG with size > 0 in this imageset
  png_count=$(find "$found" -maxdepth 1 -type f -name '*.png' -size +0c 2>/dev/null | wc -l | tr -d ' ')
  if [ "${png_count:-0}" -eq 0 ]; then
    EMPTY_ASSETS+=("$name|$found")
  fi
done <<EOF
$EXPORT_NAMES
EOF

if [ ${#MISSING_ASSETS[@]} -gt 0 ]; then
  echo "${C_RED}MISSING IMAGESETS${C_RST} (registry says $TOTAL_REG tagged, ${#MISSING_ASSETS[@]} not in xcassets):"
  for name in "${MISSING_ASSETS[@]}"; do
    echo "  - $name.imageset (expected under $XCASSETS)"
  done
fi

if [ ${#NO_CONTENTS[@]} -gt 0 ]; then
  echo "${C_RED}IMAGESETS WITHOUT Contents.json${C_RST} (${#NO_CONTENTS[@]}):"
  for entry in "${NO_CONTENTS[@]}"; do
    name="${entry%%|*}"
    path="${entry#*|}"
    echo "  - $name.imageset at $path (re-run figma_export_assets_unified for this nodeId)"
  done
fi

if [ ${#EMPTY_ASSETS[@]} -gt 0 ]; then
  echo "${C_RED}EMPTY IMAGESETS${C_RST} — directory exists but no PNG of size > 0 (${#EMPTY_ASSETS[@]}):"
  for entry in "${EMPTY_ASSETS[@]}"; do
    name="${entry%%|*}"
    path="${entry#*|}"
    echo "  - $name.imageset at $path (export rendered empty — check Figma node for visibility / errors)"
  done
fi

# 2. systemName violations ────────────────────────────────────────────────────
# Allow-list (no comment required):
#   - chevron.backward / chevron.left when file uses NavigationStack/.toolbar
#   - square.and.arrow.up (ShareLink)
#   - xmark.circle.fill (.searchable clear)
#   - keyboard*  (keyboard control names)
ALLOW_REGEX_NAVCHEV='^(chevron\.backward|chevron\.left)$'
ALLOW_REGEX_SHARE='^square\.and\.arrow\.up$'
ALLOW_REGEX_SEARCH='^xmark\.circle\.fill$'
ALLOW_REGEX_KEYBOARD='^keyboard'

VIOLATIONS=()

# Capture matches with file:line. -n line nums; -H file names.
SYSTEM_HITS=$(grep -RHn --include='*.swift' -E 'Image\(\s*systemName:' "$SRC" 2>/dev/null || true)

while IFS= read -r line; do
  [ -z "$line" ] && continue
  file="${line%%:*}"
  rest="${line#*:}"
  lineno="${rest%%:*}"
  content="${rest#*:}"

  # Extract symbol name out of `systemName: "..."`.
  symbol=$(printf '%s\n' "$content" | sed -nE 's/.*systemName:[[:space:]]*"([^"]+)".*/\1/p' | head -1)

  # Same-line / previous-line allow comment?
  if printf '%s' "$content" | grep -q '// allow-systemName:'; then
    continue
  fi
  if [ "$lineno" -gt 1 ] && [ -f "$file" ]; then
    prev=$(sed -n "$((lineno - 1))p" "$file" 2>/dev/null || true)
    if printf '%s' "$prev" | grep -q '// allow-systemName:'; then
      continue
    fi
  fi

  if [ -n "$symbol" ]; then
    # Plain allow-list (no context required).
    if [[ "$symbol" =~ $ALLOW_REGEX_SHARE ]] \
        || [[ "$symbol" =~ $ALLOW_REGEX_SEARCH ]] \
        || [[ "$symbol" =~ $ALLOW_REGEX_KEYBOARD ]]; then
      continue
    fi
    # Nav chevron: only allowed inside a NavigationStack / .toolbar context (within 50 lines of the file).
    if [[ "$symbol" =~ $ALLOW_REGEX_NAVCHEV ]]; then
      if [ -f "$file" ] && grep -qE 'NavigationStack|\.toolbar' "$file"; then
        continue
      fi
    fi
  fi

  VIOLATIONS+=("$file:$lineno: Image(systemName: \"${symbol:-?}\") — needs Figma asset OR allow comment")
done <<EOF
$SYSTEM_HITS
EOF

if [ ${#VIOLATIONS[@]} -gt 0 ]; then
  echo "${C_RED}SYSTEMNAME VIOLATIONS${C_RST} (${#VIOLATIONS[@]}):"
  for v in "${VIOLATIONS[@]}"; do
    echo "  - $v"
  done
  echo "${C_DIM}fix: replace each with the matching Figma asset (Image(.icAI...) — iOS 17+ auto-generated ImageResource), OR if a system glyph is genuinely correct, add // allow-systemName: <reason> on the line above${C_RST}"
fi

# Summary ──────────────────────────────────────────────────────────────────────
NMISS=${#MISSING_ASSETS[@]}
NEMPTY=${#EMPTY_ASSETS[@]}
NNOCT=${#NO_CONTENTS[@]}
NVIOL=${#VIOLATIONS[@]}
NBAD=$((NMISS + NEMPTY + NNOCT))
if [ "$NBAD" -eq 0 ] && [ "$NVIOL" -eq 0 ]; then
  echo "${C_GRN}PASS${C_RST}: $TOTAL_REG registry assets match xcassets (all imagesets have ≥1 PNG > 0 bytes); 0 systemName violations."
  exit 0
fi
echo "${C_RED}FAIL${C_RST}: $NMISS missing + $NEMPTY empty + $NNOCT no-Contents-json + $NVIOL systemName violations"
exit 1
