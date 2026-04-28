#!/usr/bin/env bash
# PreToolUse hook for Write/Edit on *.swift
# Blocks Swift view-file writes when the working directory looks like a figma-to-swiftui task
# but Phase A artifacts are missing for ANY screen in the cache.
#
# Phase A artifacts required per <screen-cache>/:
#   - manifest.json with phaseA: "done"  (Phase A actually completed)
#   - design-context.md non-empty, no "truncated" markers (real Figma copy/layout available)
#   - tokens.json present (or symlinked from _shared) — real Figma color/font tokens
#   - screenshot.png valid PNG — visual ground truth
#
# Rationale: every "build succeeded but doesn't match Figma" failure traces back to one of
# these four artifacts being absent at codegen time. The agent invents copy, invents tokens,
# guesses layout. Hard-block the write until Phase A is real.
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

# Iterate every screen-cache subdirectory (excluding _shared) and check the four artifacts.
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

  # 1. manifest.json with phaseA: "done"
  MANIFEST="$DIR/manifest.json"
  if [ ! -f "$MANIFEST" ]; then
    PROBLEMS+="    - manifest.json missing\n"
  else
    PHASE_A=$(jq -r '.phaseA // empty' "$MANIFEST" 2>/dev/null)
    if [ "$PHASE_A" != "done" ]; then
      # Allow legacy minimal manifests with non-empty assetList (back-compat with older runs)
      ASSET_COUNT=$(jq -r '(.assetList // []) | length' "$MANIFEST" 2>/dev/null || echo 0)
      if [ "${ASSET_COUNT:-0}" -lt 1 ]; then
        PROBLEMS+="    - manifest.phaseA != \"done\" and assetList empty\n"
      fi
      # Even with legacy manifest, the other three artifacts are still required below.
    fi
  fi

  # 2. design-context.md non-empty, no truncation
  DCTX="$DIR/design-context.md"
  if [ ! -s "$DCTX" ]; then
    PROBLEMS+="    - design-context.md missing or empty (run get_design_context for this screen)\n"
  elif grep -qi "truncated\|TRUNCATED" "$DCTX"; then
    PROBLEMS+="    - design-context.md is truncated (split the screen into sections and re-fetch)\n"
  fi

  # 3. tokens.json (real file or symlink to _shared)
  TOKENS="$DIR/tokens.json"
  SHARED_TOKENS="$CACHE_ROOT/_shared/tokens.json"
  if [ ! -e "$TOKENS" ] && [ ! -e "$SHARED_TOKENS" ]; then
    PROBLEMS+="    - tokens.json missing (run figma_extract_tokens or get_variable_defs once for this fileKey, save to _shared/tokens.json)\n"
  fi

  # 4. screenshot.png valid PNG
  SHOT="$DIR/screenshot.png"
  if [ ! -f "$SHOT" ]; then
    PROBLEMS+="    - screenshot.png missing (run get_screenshot at scale 3 for this screen)\n"
  elif ! file "$SHOT" 2>/dev/null | grep -q "PNG image data"; then
    PROBLEMS+="    - screenshot.png is not a valid PNG\n"
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
  echo "BLOCKED: figma-to-swiftui Phase A artifacts incomplete."
  echo ""
  echo "Cache: $CACHE_ROOT"
  echo "Screens passing: $PASSED_COUNT / $TOTAL"
  echo ""
  echo "Failing screens:"
  printf "%b" "$FAILED"
  echo ""
  echo "A clean compile is not the bar — Figma fidelity is. Without these four"
  echo "artifacts you will invent copy, invent tokens, and guess layout. Stop now."
  echo ""
  echo "Required Phase A per screen (run figma-to-swiftui Step A3 in full):"
  echo "  1. get_design_context(fileKey, nodeId)         → design-context.md"
  echo "  2. get_screenshot(fileKey, nodeId) at scale 3  → screenshot.png"
  echo "  3. figma_extract_tokens(fileKey)               → tokens.json (cache once in _shared/)"
  echo "  4. figma_build_registry(fileKey, nodeId)       → registry.json"
  echo "  5. Write manifest.json with phaseA: \"done\""
  echo ""
  echo "Then re-run Gate A (BASH block in figma-to-swiftui SKILL.md Step A3)."
  echo "Only after Gate A prints 'GATE: PASS (Phase A)' may you write Swift view files."
  echo ""
  echo "If you intentionally want to skip Phase A for ONE screen (e.g. shared-component"
  echo "scaffolding that doesn't render Figma UI), name the file with prefix '_NoFigma_'"
  echo "in its directory path, or write to a path that is not under a directory containing"
  echo "a .figma-cache/ — both bypass this hook by design."
} >&2

exit 2
