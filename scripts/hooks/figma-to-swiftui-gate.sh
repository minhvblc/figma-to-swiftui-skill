#!/usr/bin/env bash
# PreToolUse hook for Write/Edit on *.swift
# Blocks Swift view-file writes when the working directory looks like a figma-to-swiftui task
# but Phase A OR Phase B artifacts are incomplete for ANY screen in the cache.
#
# Phase A artifacts required per <screen-cache>/:
#   - manifest.json with phaseA: "done"
#   - design-context.md non-empty, no "truncated" markers
#   - tokens.json present (or symlinked from _shared)
#   - screenshot.png valid PNG
#   - screenshot-cmp.png valid PNG, long-side ≤2000px (sips -Z 2000 sibling for many-image C5 compare)
#   - registry.json present with rootNode (proves figma_build_registry ran)
#   - fills.json present with "nodes" key (proves figma_extract_fills ran — required
#     for background image + gradient overlay fidelity per references/fills-handling.md)
#
# Phase B artifacts required per <screen-cache>/:
#   - manifest.phaseB: "done"
#   - manifest.rows[] non-empty
#   - No row has status: "failed"
#   - Coverage: every registry.taggedAssets[].nodeId has a matching manifest.rows[]
#     entry with status == "done". Missing tagged assets = agent skipped Phase B for
#     icons that ARE in Figma (the exact failure mode this hook exists to prevent —
#     "downloaded 2 raster + 1 SVG, built the rest with SwiftUI shapes").
#
# Rationale: every "build succeeded but doesn't match Figma" failure traces back to
# either Phase A artifacts being absent (agent invents copy/tokens) OR Phase B asset
# export being skipped (agent substitutes SF Symbols / hand-drawn shapes for Figma
# icons). Hard-block the write until BOTH phases are real.
#
# Escape hatch: paths containing the segment `_NoFigma_` bypass this hook (for
# scaffolding files unrelated to Figma UI — e.g. a shared NetworkClient).
#
# Exit codes:
#   0 — allow
#   2 — block (stderr is shown to Claude as a system reminder)

set -uo pipefail

INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only act on *.swift writes.
case "$FILE_PATH" in
  *.swift) ;;
  *) exit 0 ;;
esac

# Escape hatch — path explicitly opted out.
case "$FILE_PATH" in
  *_NoFigma_*) exit 0 ;;
esac

# Probe FIRST — is the CURRENT session a figma task? (Transcript-derived
# only. A stale .figma-cache/ from a prior unrelated session must not
# trigger enforcement on today's unrelated Swift writes.)
PROBE="$(dirname "$0")/_figma-task-probe.sh"
IS_FIGMA="no"
if [ -x "$PROBE" ]; then
  IS_FIGMA=$(printf '%s' "$INPUT" | "$PROBE" 2>/dev/null || echo "no")
fi
[ "$IS_FIGMA" != "yes" ] && exit 0

# Walk up looking for .figma-cache.
DIR=$(dirname "$FILE_PATH" 2>/dev/null || echo "")
CACHE_ROOT=""
while [ -n "$DIR" ] && [ "$DIR" != "/" ]; do
  if [ -d "$DIR/.figma-cache" ]; then
    CACHE_ROOT="$DIR/.figma-cache"
    break
  fi
  DIR=$(dirname "$DIR")
done

if [ -z "$CACHE_ROOT" ] && [ -d "$PWD/.figma-cache" ]; then
  CACHE_ROOT="$PWD/.figma-cache"
fi

# Figma task confirmed by probe + no cache on disk → agent skipped Phase A.
# Block with the Phase 0 + Phase A + Phase B checklist verbatim.
if [ -z "$CACHE_ROOT" ]; then
  {
    echo "BLOCKED: figma task detected (transcript shows a Figma URL or figma-MCP tool/skill use) but no Phase A artifacts on disk."
    echo ""
    echo "You're about to Write a .swift file BEFORE running the figma-to-swiftui workflow. Do Phase 0 → Phase A → Phase B FIRST."
    echo ""
    echo "PHASE 0 (pre-flight, run once per project):"
    echo "  bash scripts/mode-detect.sh <projectFolder> --write-cache"
    echo "    → greenfield-ikame: ASK USER \"Scaffold via ikxcodegen? [Y/n]\", then"
    echo "        bash scripts/ikxcodegen-scaffold.sh <ProjectName>"
    echo "    → greenfield-vanilla: bash scripts/vanilla-scaffold.sh <ProjectName>"
    echo "    → brownfield-*: no scaffold; proceed to Phase A"
    echo "    → ambiguous: STOP, ask user, then set mode.json.userConfirmed = true"
    echo ""
    echo "PHASE A per screen (mandatory before any .swift Write):"
    echo "  1. mcp__figma-assets__figma_build_registry(fileKey, rootNodeId, depth=10)"
    echo "     → .figma-cache/<nodeId>/registry.json"
    echo "  2. mcp__figma-desktop__get_design_context(fileKey, nodeId)"
    echo "     → .figma-cache/<nodeId>/design-context.md"
    echo "  3. mcp__figma-desktop__get_screenshot(fileKey, nodeId, scale=3)"
    echo "     → .figma-cache/<nodeId>/screenshot.png + sips -Z 2000 screenshot-cmp.png"
    echo "  4. mcp__figma-assets__figma_extract_tokens(fileKey)"
    echo "     → .figma-cache/_shared/tokens.json"
    echo "  5. mcp__figma-assets__figma_extract_fills(fileKey, nodeId, depth=10)"
    echo "     → .figma-cache/<nodeId>/fills.json"
    echo "  6. mcp__figma-desktop__get_metadata(fileKey, nodeId)"
    echo "     → .figma-cache/<nodeId>/metadata.json"
    echo "  7. Persist .figma-cache/<nodeId>/manifest.json with phaseA: \"done\""
    echo ""
    echo "PHASE B per screen (asset export, mandatory before any .swift Write):"
    echo "  mcp__figma-assets__figma_export_assets_unified("
    echo "    fileKey, nodeId, outputDir, sharedAssetsDir,"
    echo "    assetCatalogPath: \"<project>/Resources/Assets.xcassets\","
    echo "    autoDiscover: true)"
    echo "  → Every eIC*/eImage* in the screen subtree exports to xcassets."
    echo "  → Persist manifest.phaseB: \"done\" + rows[]: [...]"
    echo ""
    echo "ABSOLUTE RULE — every icon/logo/illustration in the generated Swift"
    echo "code MUST trace to a Figma node exported via figma_export_assets_unified."
    echo "SF Symbols (Image(systemName:)), hand-drawn Shape/Path, Text(\"G\") for"
    echo "logos, or any \"simplified\" substitute are BANNED. Missing asset → STOP"
    echo "and re-fetch from Figma, never improvise."
    echo ""
    echo "If this is NOT a figma task (probe false-positive — e.g. user mentioned"
    echo "Figma in passing but the current request is unrelated), bypass per-file:"
    echo "  place the file under a path containing _NoFigma_ (e.g."
    echo "  $(dirname "$FILE_PATH")/_NoFigma_/$(basename "$FILE_PATH"))."
  } >&2
  exit 2
fi

# Iterate every screen-cache subdirectory (excluding _shared) and check artifacts.
shopt -s nullglob
SCREEN_DIRS=( "$CACHE_ROOT"/*/ )
shopt -u nullglob

# Count real screen dirs (excluding _shared).
SCREEN_COUNT=0
for D in "${SCREEN_DIRS[@]}"; do
  BASE=$(basename "$D")
  [ "$BASE" = "_shared" ] && continue
  SCREEN_COUNT=$((SCREEN_COUNT+1))
done

# No screen subdirs → cache only contains _shared (mode-detect ran but
# Phase A never started). Block with the Phase A checklist — probe at
# top of script already confirmed this is a figma task.
if [ "$SCREEN_COUNT" = "0" ]; then
  {
    echo "BLOCKED: figma task with .figma-cache/ but no screen-level Phase A artifacts."
    echo ""
    echo "$CACHE_ROOT/ exists (Phase 0 mode-detect ran), but no <nodeId>/ subdir"
    echo "has run Phase A. You cannot Write Swift yet — every visible icon must"
    echo "trace to a Figma node and that requires Phase A first."
    echo ""
    echo "Run Phase A per screen:"
    echo "  1. figma_build_registry → registry.json"
    echo "  2. get_design_context   → design-context.md"
    echo "  3. get_screenshot       → screenshot.png"
    echo "  4. figma_extract_tokens → _shared/tokens.json"
    echo "  5. figma_extract_fills  → fills.json"
    echo "  6. get_metadata         → metadata.json"
    echo "  7. Persist manifest.json (phaseA: \"done\")"
    echo ""
    echo "Then Phase B (figma_export_assets_unified with autoDiscover: true)"
    echo "to export every eIC*/eImage* into Assets.xcassets."
    echo ""
    echo "Cache root: $CACHE_ROOT"
  } >&2
  exit 2
fi

FAILED=""
PASSED_COUNT=0
TOTAL=0

for DIR in "${SCREEN_DIRS[@]}"; do
  BASE=$(basename "$DIR")
  # Skip the _shared dir — that's not a screen.
  [ "$BASE" = "_shared" ] && continue
  TOTAL=$((TOTAL+1))

  PROBLEMS=""

  MANIFEST="$DIR/manifest.json"

  # ─── Phase A artifacts ────────────────────────────────────────────────────────
  if [ ! -f "$MANIFEST" ]; then
    PROBLEMS+="    - manifest.json missing\n"
  else
    PHASE_A=$(jq -r '.phaseA // empty' "$MANIFEST" 2>/dev/null)
    if [ "$PHASE_A" != "done" ]; then
      PROBLEMS+="    - manifest.phaseA != \"done\" (run Phase A end-to-end, persist phaseA: \"done\")\n"
    fi
  fi

  DCTX="$DIR/design-context.md"
  if [ ! -s "$DCTX" ]; then
    PROBLEMS+="    - design-context.md missing or empty (run get_design_context for this screen)\n"
  elif grep -qi "truncated\|TRUNCATED" "$DCTX"; then
    PROBLEMS+="    - design-context.md is truncated (split the screen into sections and re-fetch)\n"
  fi

  TOKENS="$DIR/tokens.json"
  SHARED_TOKENS="$CACHE_ROOT/_shared/tokens.json"
  if [ ! -e "$TOKENS" ] && [ ! -e "$SHARED_TOKENS" ]; then
    PROBLEMS+="    - tokens.json missing (run figma_extract_tokens once for this fileKey, save to _shared/tokens.json)\n"
  fi

  SHOT="$DIR/screenshot.png"
  if [ ! -f "$SHOT" ]; then
    PROBLEMS+="    - screenshot.png missing (run get_screenshot at scale 3 for this screen)\n"
  elif ! file "$SHOT" 2>/dev/null | grep -q "PNG image data"; then
    PROBLEMS+="    - screenshot.png is not a valid PNG\n"
  fi

  CMP="$DIR/screenshot-cmp.png"
  if [ ! -f "$CMP" ]; then
    PROBLEMS+="    - screenshot-cmp.png missing (run: sips -Z 2000 $SHOT --out $CMP — required for C5 many-image compare)\n"
  elif ! file "$CMP" 2>/dev/null | grep -q "PNG image data"; then
    PROBLEMS+="    - screenshot-cmp.png is not a valid PNG\n"
  else
    LONG=$(sips -g pixelWidth -g pixelHeight "$CMP" 2>/dev/null | awk '/pixel(Width|Height)/ {print $2}' | sort -n | tail -1)
    if [ -n "$LONG" ] && [ "$LONG" -gt 2000 ]; then
      PROBLEMS+="    - screenshot-cmp.png long-side=$LONG (>2000, would trigger Claude many-image limit; re-run sips -Z 2000)\n"
    fi
  fi

  REG="$DIR/registry.json"
  if [ ! -s "$REG" ] || ! grep -q '"rootNode"' "$REG" 2>/dev/null; then
    PROBLEMS+="    - registry.json missing or invalid (run figma_build_registry — mandatory)\n"
  fi

  FILLS="$DIR/fills.json"
  if [ ! -f "$FILLS" ] || ! grep -q '"nodes"' "$FILLS" 2>/dev/null; then
    PROBLEMS+="    - fills.json missing or invalid (run figma_extract_fills — needed for background image + gradient overlay fidelity, see references/fills-handling.md)\n"
  fi

  # ─── Phase B artifacts (only check when manifest exists) ──────────────────────
  if [ -f "$MANIFEST" ]; then
    PHASE_B=$(jq -r '.phaseB // empty' "$MANIFEST" 2>/dev/null)
    ROWS_LEN=$(jq -r '(.rows // []) | length' "$MANIFEST" 2>/dev/null || echo 0)
    FAILED_ROWS=$(jq -r '[(.rows // [])[] | select(.status == "failed") | .nodeId] | join(", ")' "$MANIFEST" 2>/dev/null)
    NO_TAGGED=$(jq -r '.noTaggedAssets // false' "$MANIFEST" 2>/dev/null)

    if [ "$PHASE_B" != "done" ]; then
      PROBLEMS+="    - manifest.phaseB != \"done\" (run figma_export_assets_unified with autoDiscover: true, persist phaseB: \"done\")\n"
    fi

    # Empty rows[] is OK when the screen has no tagged Figma raster assets
    # (legitimate for PIN-entry, text-only, vector-only screens). Two ways to
    # opt out:
    #   1. Explicit: manifest.noTaggedAssets = true
    #   2. Auto-detect: registry.taggedAssets is empty for the whole flow OR
    #      the screen has no descendants in registry.taggedAssets[]
    # Otherwise empty rows = Phase B never ran and is a real failure.
    if [ "${ROWS_LEN:-0}" -lt 1 ] && [ "$NO_TAGGED" != "true" ]; then
      AUTO_NO_TAGGED="false"
      if [ -s "$REG" ] && grep -q '"taggedAssets"' "$REG"; then
        TAGGED_TOTAL=$(jq -r '(.taggedAssets // []) | length' "$REG" 2>/dev/null || echo 0)
        if [ "${TAGGED_TOTAL:-0}" -eq 0 ]; then
          AUTO_NO_TAGGED="true"
        fi
      fi
      if [ "$AUTO_NO_TAGGED" != "true" ]; then
        PROBLEMS+="    - manifest.rows[] empty (Phase B never ran — every visible icon/logo/illustration must be a row; if this screen genuinely has no tagged assets, set manifest.noTaggedAssets = true)\n"
      fi
    fi

    if [ -n "$FAILED_ROWS" ]; then
      PROBLEMS+="    - manifest.rows[] has failed entries: $FAILED_ROWS (resolve before writing Swift)\n"
    fi

    # Coverage: every registry.taggedAssets[].nodeId must be in manifest.rows[] with status: "done".
    if [ -s "$REG" ] && grep -q '"taggedAssets"' "$REG"; then
      UNCOVERED=$(python3 - "$REG" "$MANIFEST" <<'PY' 2>/dev/null
import json, sys
try:
    reg = json.load(open(sys.argv[1]))
    man = json.load(open(sys.argv[2]))
except Exception:
    sys.exit(0)
tagged = {a.get("nodeId") for a in (reg.get("taggedAssets") or []) if a.get("nodeId")}
done   = {r.get("nodeId") for r in (man.get("rows") or []) if r.get("status") == "done"}
missing = sorted(tagged - done)
if missing:
    print(",".join(missing))
PY
)
      if [ -n "$UNCOVERED" ]; then
        COUNT=$(echo "$UNCOVERED" | tr ',' '\n' | wc -l | tr -d ' ')
        PROBLEMS+="    - $COUNT tagged asset(s) in registry NOT exported to manifest.rows[] as done: $UNCOVERED\n"
        PROBLEMS+="      → re-run figma_export_assets_unified with autoDiscover:true; do NOT substitute with Image(systemName:) or hand-drawn shapes\n"
      fi
    fi
  fi

  if [ -n "$PROBLEMS" ]; then
    FAILED+="  $BASE/\n${PROBLEMS}"
  else
    PASSED_COUNT=$((PASSED_COUNT+1))
  fi
done

# All screens passed → allow.
if [ -z "$FAILED" ]; then
  exit 0
fi

# At least one screen has missing artifacts → block.
{
  echo "BLOCKED: figma-to-swiftui Phase A/B artifacts incomplete."
  echo ""
  echo "Cache: $CACHE_ROOT"
  echo "Screens passing: $PASSED_COUNT / $TOTAL"
  echo ""
  echo "Failing screens:"
  printf "%b" "$FAILED"
  echo ""
  echo "A clean compile is not the bar — Figma fidelity is. Without these artifacts"
  echo "you will invent copy, invent tokens, guess layout, and substitute SF Symbols"
  echo "or hand-drawn shapes for icons that ARE in Figma. Stop now."
  echo ""
  echo "Required Phase A per screen (figma-to-swiftui Step A3 in full):"
  echo "  1. get_design_context(fileKey, nodeId)         → design-context.md"
  echo "  2. get_screenshot(fileKey, nodeId) at scale 3  → screenshot.png"
  echo "  2b. sips -Z 2000 screenshot.png                → screenshot-cmp.png (≤2000px for C5 many-image compare)"
  echo "  3. figma_extract_tokens(fileKey)               → tokens.json (cache once in _shared/)"
  echo "  4. get_metadata(fileKey, nodeId)               → metadata.json"
  echo "  5. figma_build_registry(fileKey, rootNodeId)   → registry.json"
  echo "  6. Persist manifest.json with phaseA: \"done\""
  echo ""
  echo "Required Phase B per screen (figma-to-swiftui Step B3):"
  echo "  1. Build Visual Inventory from screenshot + registry.taggedAssets[]"
  echo "  2. Call figma_export_assets_unified(autoDiscover: true)"
  echo "  3. Every registry.taggedAssets[] entry MUST land in manifest.rows[] with status: \"done\""
  echo "  4. Persist manifest.json with phaseB: \"done\""
  echo ""
  echo "If you intentionally want to skip Figma artifacts for a non-UI scaffolding"
  echo "file (NetworkClient, AppDelegate, etc.), include the segment '_NoFigma_' in"
  echo "the file path — that bypasses this hook by design."
} >&2

exit 2
