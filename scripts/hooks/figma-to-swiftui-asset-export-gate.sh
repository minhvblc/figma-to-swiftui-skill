#!/usr/bin/env bash
# PreToolUse hook for Write|Edit on *.swift
#
# Blocks Swift writes that reference an asset symbol (Image(.X), Image("X"))
# when X is not actually present in Assets.xcassets and not in any Phase B
# manifest. Closes the failure mode where the agent invents asset references
# from the design-context.md inventory before figma_export_assets_unified
# has actually exported the PNG into the catalog — Xcode then errors
# "ImageResource has no member 'X'" at build time, which only surfaces in
# Engine A build, not at Write time.
#
# Allowed verbatim:
#   - Image(systemName: ...)  — handled by figma-to-swiftui-banned-pattern-gate.sh
#   - Image(.X) where X exists as <Assets.xcassets>/.../X.imageset/
#   - Image("X") where X.imageset/ exists (legacy string form; banned-pattern
#     gate handles this separately for figma sessions, this gate piggybacks)
#   - Any line carrying `// allow-asset-stub: <reason>` comment (on same
#     line or previous line)
#   - Symbols that match an exportName / friendlyName in any
#     <project>/.figma-cache/<screen>/manifest.json (Phase B might have
#     run for a different screen; the asset is still pending xcassets
#     import via the next figma_export_assets_unified call)
#
# Detection scope:
#   - Only enforces inside a figma-to-swiftui session — i.e. the user has
#     pasted a Figma URL in their chat (transcript scan via the strict
#     _figma-task-probe.sh helper). Outside figma sessions, Swift writes
#     run verbatim.
#   - Skip when path contains _NoFigma_.
#
# Exit codes:
#   0 — allow
#   2 — block (stderr shown to Claude)

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

# ── 2. Build the post-edit content into TMP ──────────────────────────────────
# Same pattern as figma-to-swiftui-banned-pattern-gate.sh — simulate the
# post-edit file so prev-line allow comments work even when they live
# outside the diff window.
TMP=$(mktemp -t figma-asset-export.XXXXXX) || exit 0
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

# ── 3. Find candidate Image references ───────────────────────────────────────
# Two forms we gate:
#   Image(.symbolName)         — Xcode-generated ImageResource symbol
#   Image("symbolName")        — legacy string-name form
# We do NOT gate Image(systemName: …) here — banned-pattern-gate.sh owns it.
#
# grep emits "lineno:content" rows; we then extract the symbol per row.
ASSET_HITS=$(grep -nE 'Image\([[:space:]]*(\.[A-Za-z_][A-Za-z0-9_]*|"[A-Za-z_][A-Za-z0-9_]*")' "$TMP" 2>/dev/null \
            | grep -v 'systemName:' || true)

[ -z "$ASSET_HITS" ] && exit 0

# ── 4. Locate the project root + collect known asset symbols ────────────────
# Walk up from FILE_PATH to find .figma-cache/. Project root = parent of cache.
DIR=$(dirname "$FILE_PATH" 2>/dev/null || echo "")
PROJECT_ROOT=""
while [ -n "$DIR" ] && [ "$DIR" != "/" ]; do
  if [ -d "$DIR/.figma-cache" ]; then
    PROJECT_ROOT="$DIR"
    break
  fi
  DIR=$(dirname "$DIR")
done

[ -z "$PROJECT_ROOT" ] && [ -d "$PWD/.figma-cache" ] && PROJECT_ROOT="$PWD"
[ -z "$PROJECT_ROOT" ] && PROJECT_ROOT="$PWD"

CONVENTIONS_JSON="$PROJECT_ROOT/.figma-cache/_shared/c1-conventions.json"

# 4a. Asset Catalog path — read pinned value first, fall back to find.
ASSET_CATALOG=""
if [ -s "$CONVENTIONS_JSON" ]; then
  ASSET_CATALOG=$(python3 -c "
import json
try:
    with open('$CONVENTIONS_JSON') as f:
        data = json.load(f)
    print(data.get('assetCatalogPath', '') or '')
except Exception:
    print('')
" 2>/dev/null)
fi
if [ -z "$ASSET_CATALOG" ] || [ ! -d "$ASSET_CATALOG" ]; then
  ASSET_CATALOG=$(find "$PROJECT_ROOT" -maxdepth 6 -type d -name '*.xcassets' 2>/dev/null | head -1)
fi

# 4b. Build the allow-set: imageset names + colorset names from the catalog
#     PLUS every exportName / friendlyName in any cached manifest.
KNOWN_SET=$(python3 - "$ASSET_CATALOG" "$PROJECT_ROOT" <<'PY' 2>/dev/null
import json, os, sys
asset_catalog, project_root = sys.argv[1], sys.argv[2]
known = set()

# Scan Asset Catalog for imageset / colorset / symbolset names.
if asset_catalog and os.path.isdir(asset_catalog):
    for dirpath, dirnames, _ in os.walk(asset_catalog):
        for d in dirnames:
            for suffix in (".imageset", ".colorset", ".symbolset"):
                if d.endswith(suffix):
                    known.add(d[: -len(suffix)])

# Scan every .figma-cache/<screen>/manifest.json for exportName + friendlyName.
cache_root = os.path.join(project_root, ".figma-cache")
if os.path.isdir(cache_root):
    for entry in os.listdir(cache_root):
        if entry == "_shared":
            continue
        mp = os.path.join(cache_root, entry, "manifest.json")
        if not os.path.isfile(mp):
            continue
        try:
            with open(mp) as f:
                m = json.load(f)
        except Exception:
            continue
        for r in m.get("rows", []) or []:
            for k in ("exportName", "friendlyName"):
                v = r.get(k)
                if v:
                    known.add(v)

for name in sorted(known):
    print(name)
PY
)

# ── 5. Helper: has allow-asset-stub comment? ─────────────────────────────────
has_allow_stub() {
  local lineno="$1"
  local cur prev
  cur=$(sed -n "${lineno}p" "$TMP" 2>/dev/null || true)
  printf '%s' "$cur" | grep -q '// *allow-asset-stub' && return 0
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    printf '%s' "$prev" | grep -q '// *allow-asset-stub' && return 0
  fi
  return 1
}

# ── 6. Validate each asset reference ─────────────────────────────────────────
VIOLATIONS=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"

  # Extract the symbol from either `.X` form or `"X"` form
  symbol=$(printf '%s\n' "$content" | sed -nE 's/.*Image\([[:space:]]*\.([A-Za-z_][A-Za-z0-9_]*).*/\1/p' | head -1)
  if [ -z "$symbol" ]; then
    symbol=$(printf '%s\n' "$content" | sed -nE 's/.*Image\([[:space:]]*"([A-Za-z_][A-Za-z0-9_]*)".*/\1/p' | head -1)
  fi
  [ -z "$symbol" ] && continue

  has_allow_stub "$lineno" && continue

  # Match against known set
  if printf '%s\n' "$KNOWN_SET" | grep -qFx "$symbol"; then
    continue
  fi

  VIOLATIONS+="  line $lineno: Image(.$symbol) — not in Asset Catalog and not in any manifest.json\n"
done <<< "$ASSET_HITS"

[ -z "$VIOLATIONS" ] && exit 0

# ── 7. Report ─────────────────────────────────────────────────────────────────
{
  echo "BLOCKED [figma-asset-export]: $(basename "$FILE_PATH")"
  printf "%b" "$VIOLATIONS"
  echo ""
  echo "Fix paths:"
  echo "  1. Run Phase B for this screen — figma_export_assets_unified(autoDiscover: true, …)"
  echo "     will export the PNG into ${ASSET_CATALOG:-<assetCatalogPath>} and Xcode will"
  echo "     auto-generate the ImageResource symbol."
  echo "  2. If the symbol is a deliberate stub (e.g. placeholder until designer publishes"
  echo "     the node), add  // allow-asset-stub: <reason>  on the line or the line above."
  echo ""
  echo "Reference: figma-to-swiftui/SKILL.md §Phase B + references/asset-handling.md"
} >&2

exit 2
