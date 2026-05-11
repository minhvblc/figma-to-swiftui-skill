#!/usr/bin/env bash
# PreToolUse hook for Write|Edit on *.swift
#
# Blocks the first Swift Write/Edit in a figma-to-swiftui task until the
# project's mode has been detected (scripts/mode-detect.sh --write-cache),
# AND when mode == "ambiguous", until the user has explicitly confirmed
# scaffolding (mode.json.userConfirmed == true).
#
# Closes the failure mode where the agent jumps straight to Phase A
# (figma_build_registry) without running mode-detect, then writes Swift
# files into a folder layout that has NOT been scaffolded by ikxcodegen
# (for greenfield-ikame) — producing files outside any .xcodeproj and
# silently violating the Ikame scaffold contract.
#
# Detection scope:
#   - Walk up from the Swift file path (and from $PWD) looking for
#     .figma-cache/ — only enforces when a figma task is active.
#   - Skip when path contains _NoFigma_ (same escape hatch as gate.sh).
#
# Exit codes:
#   0 — allow
#   2 — block (stderr shown to Claude)

set -uo pipefail

INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

case "$FILE_PATH" in
  *.swift) ;;
  *) exit 0 ;;
esac

case "$FILE_PATH" in
  *_NoFigma_*) exit 0 ;;
esac

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

# Cache missing → ask probe whether this is a figma task by any other signal.
# If yes, fabricate the expected mode.json path so the "missing" branch fires
# below with the right guidance. If no, exit 0 (non-figma session).
if [ -z "$CACHE_ROOT" ]; then
  PROBE="$(dirname "$0")/_figma-task-probe.sh"
  IS_FIGMA="no"
  if [ -x "$PROBE" ]; then
    IS_FIGMA=$(printf '%s' "$INPUT" | "$PROBE" 2>/dev/null || echo "no")
  fi
  [ "$IS_FIGMA" != "yes" ] && exit 0
  # Synthesize an expected cache path so the message below points to where
  # mode-detect should write. Use the project root inferred from FILE_PATH
  # (parent of "<project>/Screens/<Name>/<Name>Screen.swift" etc.) — walk
  # up 4 levels max, prefer the dir directly under $PWD if reachable.
  CACHE_ROOT="$PWD/.figma-cache"
fi

MODE_JSON="$CACHE_ROOT/_shared/mode.json"

# ── 1. mode.json must exist ──────────────────────────────────────────────────
if [ ! -s "$MODE_JSON" ]; then
  {
    echo "BLOCKED: project mode not yet detected."
    echo ""
    echo "Cache: $CACHE_ROOT"
    echo "Missing: $MODE_JSON"
    echo ""
    echo "Before any Swift Write/Edit, run mode-detect on the iOS project folder"
    echo "and persist the result. This decides whether the run uses ikxcodegen,"
    echo "vanilla scaffold, or skips scaffolding (brownfield)."
    echo ""
    echo "  scripts/mode-detect.sh <projectFolder> --write-cache"
    echo ""
    echo "Then, per the result:"
    echo "  greenfield-ikame    → ASK USER, then scripts/ikxcodegen-scaffold.sh <Name>"
    echo "  greenfield-vanilla  → scripts/vanilla-scaffold.sh <Name>"
    echo "  brownfield-ikame    → no scaffold; load conventions from c1-probe"
    echo "  brownfield-vanilla  → no scaffold; load conventions from c1-probe"
    echo "  ambiguous           → STOP, ask the user before scaffolding over"
    echo "                        existing files; set mode.json.userConfirmed = true"
    echo "                        when the user OK's it"
    echo ""
    echo "Run scripts/mode-detect.sh --help for the full classification rules."
  } >&2
  exit 2
fi

# ── 2. mode == ambiguous needs explicit user confirmation ────────────────────
MODE=$(jq -r '.mode // empty' "$MODE_JSON" 2>/dev/null)
CONFIRMED=$(jq -r '.userConfirmed // false' "$MODE_JSON" 2>/dev/null)
if [ "$MODE" = "ambiguous" ] && [ "$CONFIRMED" != "true" ]; then
  {
    echo "BLOCKED: project mode is \"ambiguous\" — explicit user confirmation required."
    echo ""
    echo "Cache: $CACHE_ROOT"
    echo "mode.json: $MODE_JSON"
    echo ""
    echo "scripts/mode-detect.sh could not classify the target folder (mixed"
    echo "signals or partial scaffold). Ask the user verbatim before writing"
    echo "any Swift file:"
    echo ""
    echo "  \"Folder has unclear topology (partial scaffold / mixed sources)."
    echo "   I won't write any Swift until you confirm: scaffold over existing"
    echo "   files OR stop and inspect manually?\""
    echo ""
    echo "When the user OK's, persist: jq '. + {userConfirmed: true}' on $MODE_JSON"
    echo "and re-attempt the write."
  } >&2
  exit 2
fi

# ── 3. mode == greenfield-* needs a scaffold to have produced an .xcodeproj ──
# Skip this check when the agent is writing the very first scaffold-output
# files — they MUST land before .xcodeproj exists on disk for a brief window.
# Heuristic: scaffold writes happen inside the cache's parent project root and
# do NOT require .xcodeproj. After scaffold, .xcodeproj is present. We only
# enforce this rule when the agent has already begun feature Swift writes
# (manifest.phaseA == "done" on any screen cache).
case "$MODE" in
  greenfield-ikame|greenfield-vanilla)
    PROJECT_ROOT=$(dirname "$CACHE_ROOT")
    # Look for any .xcodeproj under project root (max 4 levels).
    XCODEPROJ=$(find "$PROJECT_ROOT" -maxdepth 4 -type d -name '*.xcodeproj' 2>/dev/null | head -1)
    if [ -z "$XCODEPROJ" ]; then
      # Are we past Phase A on any screen? If so, scaffold is overdue.
      shopt -s nullglob
      SCREEN_DIRS=( "$CACHE_ROOT"/*/ )
      shopt -u nullglob
      PAST_PHASE_A=0
      for d in "${SCREEN_DIRS[@]}"; do
        BASE=$(basename "$d")
        [ "$BASE" = "_shared" ] && continue
        PA=$(jq -r '.phaseA // empty' "$d/manifest.json" 2>/dev/null)
        [ "$PA" = "done" ] && PAST_PHASE_A=1 && break
      done
      if [ "$PAST_PHASE_A" = "1" ]; then
        {
          echo "BLOCKED: greenfield mode ($MODE) but no .xcodeproj found under $PROJECT_ROOT."
          echo ""
          echo "Phase A is complete on at least one screen, so scaffold should already"
          echo "have run. Run the scaffold step before any further Swift Write/Edit:"
          echo ""
          case "$MODE" in
            greenfield-ikame)
              echo "  scripts/ikxcodegen-scaffold.sh <ProjectName>"
              echo ""
              echo "Confirm with the user first (Y/n) — ikxcodegen creates a Podfile,"
              echo "runs pod install, and wires xcconfig + GoogleService-Info plist."
              ;;
            greenfield-vanilla)
              echo "  scripts/vanilla-scaffold.sh <ProjectName>"
              ;;
          esac
        } >&2
        exit 2
      fi
    fi
    ;;
esac

exit 0
