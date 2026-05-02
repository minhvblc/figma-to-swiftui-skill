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
#   - registry.json present with rootNode (proves figma_build_registry ran)
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

# Walk up looking for .figma-cache. If none, this is not a figma task — allow.
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

if [ -z "$CACHE_ROOT" ]; then
  exit 0
fi

# Iterate every screen-cache subdirectory (excluding _shared) and check artifacts.
shopt -s nullglob
SCREEN_DIRS=( "$CACHE_ROOT"/*/ )
shopt -u nullglob

# No screen subdirs → cache empty, treat as not-a-figma-task. Allow.
if [ ${#SCREEN_DIRS[@]} -eq 0 ]; then
  exit 0
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

  REG="$DIR/registry.json"
  if [ ! -s "$REG" ] || ! grep -q '"rootNode"' "$REG" 2>/dev/null; then
    PROBLEMS+="    - registry.json missing or invalid (run figma_build_registry — mandatory)\n"
  fi

  # ─── Phase B artifacts (only check when manifest exists) ──────────────────────
  if [ -f "$MANIFEST" ]; then
    PHASE_B=$(jq -r '.phaseB // empty' "$MANIFEST" 2>/dev/null)
    ROWS_LEN=$(jq -r '(.rows // []) | length' "$MANIFEST" 2>/dev/null || echo 0)
    FAILED_ROWS=$(jq -r '[(.rows // [])[] | select(.status == "failed") | .nodeId] | join(", ")' "$MANIFEST" 2>/dev/null)

    if [ "$PHASE_B" != "done" ]; then
      PROBLEMS+="    - manifest.phaseB != \"done\" (run figma_export_assets_unified with autoDiscover: true, persist phaseB: \"done\")\n"
    fi

    if [ "${ROWS_LEN:-0}" -lt 1 ]; then
      PROBLEMS+="    - manifest.rows[] empty (Phase B never ran — every visible icon/logo/illustration must be a row)\n"
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
