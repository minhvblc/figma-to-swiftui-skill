#!/usr/bin/env bash
# c6-asset-completeness.sh — verify every Figma-tagged asset landed in the
# Asset Catalog, the SwiftUI Image(.X) refs match registry exportNames
# (including size suffix), and no `Image(systemName:)` substituted for a
# Figma asset.
#
# Checks (all must pass):
#   1. Every taggedAssets[].exportName in registry has a matching *.imageset/
#      with Contents.json + ≥1 PNG > 0 bytes under --xcassets.
#   2. `Image(systemName:` in --src is allow-listed OR carries `// allow-systemName:`.
#   3. (Plan §3.5 Check A — manifest status) Every `manifest.rows[].status`
#      across --manifest-glob is `"done"`. Non-done rows mean the export
#      failed silently and the agent's Swift code references something that
#      isn't on disk — this check catches it.
#   4. (Plan §3.5 Check B — Swift Image(.X) refs) Every `Image(.X)` literal
#      in --src has a matching `<X>.imageset/` directory. Catches typos and
#      stale references after rename.
#   5. (Plan §3.5 Check C — size-suffix mismatch) When registry has
#      `icAIArrow24x24` but Swift code references `Image(.icAIArrow)`, flag
#      it — the stripped form is a common agent failure mode after which
#      it tends to fall back to `Image(systemName:)`. See SKILL.md §C4
#      "Size-suffix awareness".
#
# Usage:
#   c6-asset-completeness.sh --registry <path> --xcassets <path> --src <path>
#                            [--manifest-glob "<.figma-cache/*/manifest.json>"]
#
# Exit codes:
#   0 — pass (no missing/empty assets, no systemName/manifest/size-suffix violations)
#   1 — fail (one or more failures)
#   64 — bad usage
#   65 — input not found / not parsable

set -uo pipefail

REGISTRY=""
XCASSETS=""
SRC=""
MANIFEST_GLOB=""

print_usage() {
  cat <<'USAGE' >&2
usage: c6-asset-completeness.sh --registry <path-to-registry.json> \
                                --xcassets <path-to-Assets.xcassets> \
                                --src <path-to-swift-src-root> \
                                [--manifest-glob "<glob-of-manifest.json>"]

Verifies registry → xcassets coverage, no banned Image(systemName:),
manifest.json status==done (when --manifest-glob given), Swift Image(.X)
refs match xcassets imagesets, and size-suffix is preserved in Swift refs.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --registry)      REGISTRY="${2:-}";      shift 2 ;;
    --xcassets)      XCASSETS="${2:-}";      shift 2 ;;
    --src)           SRC="${2:-}";           shift 2 ;;
    --manifest-glob) MANIFEST_GLOB="${2:-}"; shift 2 ;;
    -h|--help)       print_usage; exit 0 ;;
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

# 3. Manifest status (Plan §3.5 Check A) ─────────────────────────────────────
# When --manifest-glob is provided, scan every manifest.json for rows with
# status != "done". Failed exports leave the agent's Image(.X) refs dangling.
MANIFEST_FAILED=()
if [ -n "$MANIFEST_GLOB" ]; then
  # Use python for cross-shell globbing + JSON parse
  MANIFEST_REPORT=$(python3 - "$MANIFEST_GLOB" <<'PY' 2>/dev/null
import glob, json, sys
pattern = sys.argv[1]
issues = []
for path in glob.glob(pattern):
    try:
        with open(path) as f:
            data = json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        continue
    for row in (data.get("rows") or []):
        status = row.get("status", "unknown")
        if status != "done":
            name = row.get("exportName") or row.get("friendlyName") or row.get("nodeId") or "?"
            reason = row.get("reason") or ""
            issues.append(f"{path}|{name}|{status}|{reason}")
print("\n".join(issues))
PY
)
  while IFS= read -r entry; do
    [ -z "$entry" ] && continue
    MANIFEST_FAILED+=("$entry")
  done <<EOF
$MANIFEST_REPORT
EOF

  if [ ${#MANIFEST_FAILED[@]} -gt 0 ]; then
    echo "${C_RED}MANIFEST EXPORT FAILURES${C_RST} (${#MANIFEST_FAILED[@]}):"
    for entry in "${MANIFEST_FAILED[@]}"; do
      path="${entry%%|*}"; rest="${entry#*|}"
      name="${rest%%|*}";    rest="${rest#*|}"
      status="${rest%%|*}";  reason="${rest#*|}"
      echo "  - $name in $path (status=$status${reason:+, reason=$reason})"
    done
    echo "${C_DIM}fix: re-run figma_export_assets_unified(autoDiscover: true) for the cache and verify status==done for every row${C_RST}"
  fi
fi

# 4. Swift Image(.X) refs (Plan §3.5 Check B) ────────────────────────────────
# Every `Image(.someIdentifier)` literal in src must have a matching
# `someIdentifier.imageset/` under xcassets. Catches typos + stale refs
# after a Figma layer rename + agent fall-back patterns.
IMAGE_REFS=$(grep -RhEo --include='*.swift' 'Image\(\s*\.[A-Za-z][A-Za-z0-9_]*' "$SRC" 2>/dev/null \
  | sed -E 's/.*\.([A-Za-z][A-Za-z0-9_]*).*/\1/' \
  | sort -u)
DANGLING_REFS=()
while IFS= read -r ident; do
  [ -z "$ident" ] && continue
  # Skip SwiftUI built-in shapes that look like Image(.X) but are actually
  # Image(systemName-equivalent shorthand) — none exist today, but defensive.
  found=$(find "$XCASSETS" -type d -name "${ident}.imageset" -maxdepth 6 2>/dev/null | head -1)
  if [ -z "$found" ]; then
    DANGLING_REFS+=("$ident")
  fi
done <<EOF
$IMAGE_REFS
EOF

if [ ${#DANGLING_REFS[@]} -gt 0 ]; then
  echo "${C_RED}DANGLING Image(.X) REFS${C_RST} (${#DANGLING_REFS[@]}):"
  for ident in "${DANGLING_REFS[@]}"; do
    # Find call sites
    sites=$(grep -RHnE --include='*.swift' "Image\(\s*\.${ident}\b" "$SRC" 2>/dev/null | head -3)
    echo "  - .${ident} (no ${ident}.imageset in xcassets)"
    if [ -n "$sites" ]; then
      echo "$sites" | sed 's/^/      /'
    fi
  done
fi

# 5. Size-suffix mismatch (Plan §3.5 Check C) ────────────────────────────────
# When registry has `icAIArrow24x24` but Swift refs `Image(.icAIArrow)`, the
# agent likely stripped the suffix. The dangling ref check above catches
# the imageset-not-found case; this specifically flags the registry-vs-code
# size-suffix divergence so the fix suggestion is precise.
SUFFIX_MISMATCHES=()
SIZE_SUFFIX_RE='^([A-Za-z][A-Za-z0-9_]*?)([0-9]+x[0-9]+)$'

# Build a map of stripped-name → fully-suffixed-name(s) from the registry
REG_WITH_SUFFIX=$(jq -r '
  ((.taggedAssets // [])[] | select(.exportName != null) | .exportName)
' "$REGISTRY" 2>/dev/null | grep -E "$SIZE_SUFFIX_RE" || true)

while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  # Only check refs that DON'T already have a size suffix (those are correct)
  if [[ "$ref" =~ $SIZE_SUFFIX_RE ]]; then
    continue
  fi
  # Look for a registry exportName starting with this ref + a size suffix
  matched=$(echo "$REG_WITH_SUFFIX" | grep -E "^${ref}[0-9]+x[0-9]+$" | head -3)
  if [ -n "$matched" ]; then
    # Flag if the bare ref has NO matching imageset (the dangling check
    # already would have flagged it; we add precise size-suffix advice).
    bare_found=$(find "$XCASSETS" -type d -name "${ref}.imageset" -maxdepth 6 2>/dev/null | head -1)
    if [ -z "$bare_found" ]; then
      suggested=$(echo "$matched" | tr '\n' ',' | sed 's/,$//')
      SUFFIX_MISMATCHES+=("$ref|$suggested")
    fi
  fi
done <<EOF
$IMAGE_REFS
EOF

if [ ${#SUFFIX_MISMATCHES[@]} -gt 0 ]; then
  echo "${C_RED}SIZE-SUFFIX MISMATCH${C_RST} (${#SUFFIX_MISMATCHES[@]}):"
  for entry in "${SUFFIX_MISMATCHES[@]}"; do
    ref="${entry%%|*}"
    sug="${entry#*|}"
    echo "  - Image(.${ref}) — registry has size-suffixed form(s): $sug"
    echo "${C_DIM}      fix: use the suffixed name verbatim. See SKILL.md §C4 'Size-suffix awareness'.${C_RST}"
  done
fi

# Summary ──────────────────────────────────────────────────────────────────────
NMISS=${#MISSING_ASSETS[@]}
NEMPTY=${#EMPTY_ASSETS[@]}
NNOCT=${#NO_CONTENTS[@]}
NVIOL=${#VIOLATIONS[@]}
NMFAIL=${#MANIFEST_FAILED[@]}
NDANGLE=${#DANGLING_REFS[@]}
NSUFFIX=${#SUFFIX_MISMATCHES[@]}
NBAD=$((NMISS + NEMPTY + NNOCT))
NEXTRA=$((NMFAIL + NDANGLE + NSUFFIX))
if [ "$NBAD" -eq 0 ] && [ "$NVIOL" -eq 0 ] && [ "$NEXTRA" -eq 0 ]; then
  echo "${C_GRN}PASS${C_RST}: $TOTAL_REG registry assets match xcassets; 0 systemName violations; 0 manifest failures; 0 dangling Image(.X) refs; 0 size-suffix mismatches."
  exit 0
fi
echo "${C_RED}FAIL${C_RST}: $NMISS missing + $NEMPTY empty + $NNOCT no-Contents-json + $NVIOL systemName + $NMFAIL manifest-failed + $NDANGLE dangling-ref + $NSUFFIX size-suffix-mismatch"
exit 1
