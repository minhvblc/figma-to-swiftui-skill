#!/usr/bin/env bash
# PreToolUse hook for Write|Edit on *.swift
#
# Detects asset symbol references where an inner `x` sits between two
# digits (e.g. `Image(.icAIBackground375x812)`) AND the matching
# manifest.json exportName is the same shape. Xcode's auto-generated
# `ImageResource` symbol uppercases the inner `x` between digits, so the
# above MUST be written as `Image(.icAIBackground375X812)` for the build
# to compile. Otherwise: `Type 'ImageResource' has no member …`.
#
# Closes Round-2 gap G29. Bible Widgets App session — 9 references
# across 3 files needed manual regex bulk-fix because no gate caught it
# at write time. Engine A's BuildProject surfaced it only AFTER the
# file landed; that's expensive feedback.
#
# Allowed verbatim:
#   - Image(.X) / Image("X") where X has no inner-digit `x` pattern
#   - Image(.X) where X has inner-digit `x` AND no matching uppercase
#     variant exists in any manifest or .xcassets (rare; usually means
#     the agent invented the symbol; the asset-export gate will catch
#     it separately)
#   - // allow-asset-case: <reason> comment same or previous line
#
# Detection scope:
#   - Only enforces inside a figma-to-swiftui session
#     (transcript probe via _figma-task-probe.sh).
#   - Skip when path contains _NoFigma_.
#
# Exit codes:
#   0 — allow
#   2 — block (stderr shown to Claude with suggested fix)

set -uo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

case "$FILE_PATH" in
  *.swift) ;;
  *) exit 0 ;;
esac

case "$FILE_PATH" in
  *_NoFigma_*) exit 0 ;;
esac

# ── 1. Session scope ──────────────────────────────────────────────────────────
PROBE="$(dirname "$0")/_figma-task-probe.sh"
IS_FIGMA="no"
if [ -x "$PROBE" ]; then
  IS_FIGMA=$(printf '%s' "$INPUT" | "$PROBE" 2>/dev/null || echo "no")
fi
[ "$IS_FIGMA" != "yes" ] && exit 0

# ── 2. Build post-edit content into TMP ──────────────────────────────────────
TMP=$(mktemp -t figma-asset-case.XXXXXX) || exit 0
trap 'rm -f "$TMP"' EXIT

case "$TOOL" in
  Write)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')
    [ -z "$CONTENT" ] && exit 0
    printf '%s' "$CONTENT" > "$TMP"
    ;;
  Edit)
    OLD=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // empty')
    NEW=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty')
    REPLACE_ALL=$(printf '%s' "$INPUT" | jq -r '.tool_input.replace_all // false')
    if [ ! -f "$FILE_PATH" ]; then
      [ -z "$NEW" ] && exit 0
      printf '%s' "$NEW" > "$TMP"
    else
      python3 - "$FILE_PATH" "$OLD" "$NEW" "$REPLACE_ALL" "$TMP" <<'PY' 2>/dev/null || cp "$FILE_PATH" "$TMP"
import sys
src_path, old_str, new_str, replace_all_str, out_path = sys.argv[1:6]
replace_all = replace_all_str.lower() == "true"
with open(src_path, 'r') as f:
    src = f.read()
if old_str == "":
    out = src + new_str
elif replace_all:
    out = src.replace(old_str, new_str)
else:
    idx = src.find(old_str)
    out = src if idx < 0 else src[:idx] + new_str + src[idx+len(old_str):]
with open(out_path, 'w') as f:
    f.write(out)
PY
    fi
    ;;
  *)
    exit 0
    ;;
esac

[ ! -s "$TMP" ] && exit 0

# ── 3. Scan for `Image(.X)` / `Image("X")` with inner-digit `x` ──────────────
HITS=$(grep -nE 'Image\([[:space:]]*(\.[A-Za-z_][A-Za-z0-9_]*[0-9]x[0-9][A-Za-z0-9_]*|"[A-Za-z_][A-Za-z0-9_]*[0-9]x[0-9][A-Za-z0-9_]*")' "$TMP" 2>/dev/null || true)

[ -z "$HITS" ] && exit 0

# ── 4. has_allow_case helper ─────────────────────────────────────────────────
has_allow_case() {
  local lineno="$1"
  local cur prev
  cur=$(sed -n "${lineno}p" "$TMP" 2>/dev/null || true)
  printf '%s' "$cur" | grep -q '// *allow-asset-case' && return 0
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    printf '%s' "$prev" | grep -q '// *allow-asset-case' && return 0
  fi
  return 1
}

# ── 5. Build report — each hit gets the corrected suggestion ─────────────────
VIOLATIONS=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  # Extract symbol from `.X` form
  symbol=$(printf '%s\n' "$content" | grep -oE 'Image\([[:space:]]*\.[A-Za-z_][A-Za-z0-9_]*' | head -1 | sed -E 's/^Image\([[:space:]]*\.//')
  if [ -z "$symbol" ]; then
    # Try `"X"` form
    symbol=$(printf '%s\n' "$content" | grep -oE 'Image\([[:space:]]*"[A-Za-z_][A-Za-z0-9_]*"' | head -1 | sed -E 's/^Image\([[:space:]]*"//; s/"$//')
  fi
  [ -z "$symbol" ] && continue

  has_allow_case "$lineno" && continue

  # Skip if the symbol doesn't actually have inner-digit `x` (defensive
  # double-check — grep may have matched a different `Image(...)` on the
  # same line).
  if ! printf '%s' "$symbol" | grep -qE '[0-9]x[0-9]'; then
    continue
  fi

  # Suggested fix: uppercase every inner-digit `x` to `X`.
  fixed=$(printf '%s' "$symbol" | sed -E 's/([0-9])x([0-9])/\1X\2/g')
  # Double-pass for runs of x's, e.g. 1x2x3 → 1X2x3 → 1X2X3.
  fixed=$(printf '%s' "$fixed" | sed -E 's/([0-9])x([0-9])/\1X\2/g')

  VIOLATIONS+="  line $lineno: Image(.$symbol) → Image(.$fixed)  (Xcode uppercases inner-digit 'x' to 'X' in ImageResource symbols)\n"
done <<< "$HITS"

[ -z "$VIOLATIONS" ] && exit 0

{
  echo "BLOCKED [figma-asset-symbol-case]: $(basename "$FILE_PATH")"
  printf "%b" "$VIOLATIONS"
  echo ""
  echo "Why: Xcode 15+'s auto-generated 'ImageResource' symbol converts inner 'x'"
  echo "between digits to 'X'. The Asset Catalog still names the imageset with"
  echo "lowercase 'x', but the Swift symbol exposed to your code is uppercase."
  echo "Writing the lowercase form fails to compile at the call site."
  echo ""
  echo "Fix: replace each Image(.<symbol>) with the suggested Image(.<fixed>) form."
  echo "If this name is genuinely all-lowercase intentionally (rare), add"
  echo "  // allow-asset-case: <reason>"
  echo "on the line or the line above."
} >&2

exit 2
