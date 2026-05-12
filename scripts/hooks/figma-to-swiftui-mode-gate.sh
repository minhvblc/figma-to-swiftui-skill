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

# Probe FIRST — current session must show a transcript-side figma signal.
# A stale .figma-cache/ on disk from a prior unrelated session is NOT
# enough to enforce mode-detect on today's unrelated writes.
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

# Figma task + no cache on disk → synthesize $PWD as project root so the
# "mode.json missing" branch below points to where mode-detect should write.
if [ -z "$CACHE_ROOT" ]; then
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

# ── 2. mode.json must parse — fail closed if jq returns empty for a
#       non-empty file (corrupted JSON, truncated write, manual edit gone
#       wrong). Previously this silently fell through and allowed the write.
MODE=$(jq -r '.mode // empty' "$MODE_JSON" 2>/dev/null)
CONFIRMED=$(jq -r '.userConfirmed // false' "$MODE_JSON" 2>/dev/null)
OPT_OUT_IKAME=$(jq -r '.userOptOutIkame // false' "$MODE_JSON" 2>/dev/null)
if [ -s "$MODE_JSON" ] && [ -z "$MODE" ]; then
  {
    echo "BLOCKED: mode.json exists but jq could not extract .mode."
    echo ""
    echo "File:   $MODE_JSON"
    echo "Likely: corrupted JSON, truncated write, or hand-edit gone wrong."
    echo ""
    echo "Fix:"
    echo "  cat $MODE_JSON      # inspect"
    echo "  bash scripts/mode-detect.sh <projectFolder> --write-cache  # regenerate"
  } >&2
  exit 2
fi

# ── 3. mode == ambiguous needs explicit user confirmation ────────────────────
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

# ── 4. mode == greenfield-* needs a scaffold to have produced an .xcodeproj ──
# Scaffold scripts (vanilla-scaffold.sh, ikxcodegen-wrap.sh) write Swift files
# via bash heredocs / CLI delegation, NOT via Write/Edit tool calls — so the
# hook never sees those writes. Any Write/Edit on *.swift that DOES reach this
# hook is the agent writing feature code, and that requires a real .xcodeproj
# to live inside. We block immediately when no .xcodeproj exists, regardless
# of phase: phase-gating leaked the failure mode where the agent started Phase
# B / C without scaffolding first.
case "$MODE" in
  greenfield-ikame|greenfield-vanilla)
    PROJECT_ROOT=$(dirname "$CACHE_ROOT")
    XCODEPROJ=$(find "$PROJECT_ROOT" -maxdepth 4 -type d -name '*.xcodeproj' 2>/dev/null | head -1)
    if [ -z "$XCODEPROJ" ]; then
      {
        echo "BLOCKED: greenfield mode ($MODE) but no .xcodeproj found under $PROJECT_ROOT."
        echo ""
        echo "Scaffold has not run yet. Feature Swift writes require a real Xcode"
        echo "project. Run the scaffold step before any further Write/Edit:"
        echo ""
        case "$MODE" in
          greenfield-ikame)
            if [ "$OPT_OUT_IKAME" = "true" ]; then
              echo "  scripts/vanilla-scaffold.sh <projectFolder>"
              echo ""
              echo "  (mode.json.userOptOutIkame = true is set, so vanilla path is allowed.)"
            else
              echo "  scripts/ikxcodegen-scaffold.sh <ProjectName>"
              echo ""
              echo "  MANDATORY — ikxcodegen is on PATH, so this machine is on the Ikame"
              echo "  fleet. ikxcodegen creates a Podfile + xcconfig + GoogleService-Info"
              echo "  plist and runs pod install. No Y/n confirmation needed."
              echo ""
              echo "  To override (rare — non-Ikame app on an Ikame-fleet machine):"
              echo "    scripts/mode-detect.sh <projectFolder> --write-cache --opt-out-ikame"
              echo "  then re-attempt vanilla-scaffold.sh."
            fi
            ;;
          greenfield-vanilla)
            echo "  scripts/vanilla-scaffold.sh <projectFolder>"
            ;;
        esac
      } >&2
      exit 2
    fi
    ;;
esac

exit 0
