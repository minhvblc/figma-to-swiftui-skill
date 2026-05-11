#!/usr/bin/env bash
# mode-detect.sh — Classify a project folder into one of four modes that
# downstream skill logic + hooks branch on. Mode is persisted to
# .figma-cache/_shared/mode.json so subsequent hook invocations can read it
# without re-probing.
#
# Modes:
#   greenfield                Empty/non-existent project. Skill must scaffold.
#                             Sub-types:
#                               greenfield-ikame    when ikxcodegen is on PATH
#                                                   AND the user explicitly opts
#                                                   in (mode.json.userChose).
#                               greenfield-vanilla  default for empty greenfield
#                                                   when ikxcodegen unavailable
#                                                   OR user opts out.
#
#   brownfield-ikame          Existing project with Podfile that lists IKCoreApp
#                             OR any *.swift imports IKCoreApp. The Ikame
#                             umbrella conventions (IKNavigation/IKMacros/etc.)
#                             apply.
#
#   brownfield-vanilla        Existing project with NO Ikame umbrella. Vanilla
#                             SwiftUI patterns (NavigationStack, @Observable,
#                             explicit color/font enums) apply.
#
#   ambiguous                 Existing project but classification unclear (e.g.
#                             half-Ikame, partial scaffolds, mixed sources).
#                             Skill MUST stop and ask the user before scaffolding.
#
# Usage:
#   scripts/mode-detect.sh <project-folder> [--explain] [--write-cache]
#
# Output (stdout):
#   {"mode": "<one of above>", "confidence": 0.0..1.0, "signals": [...]}
#
# Exit codes:
#   0 — classification produced (incl. ambiguous)
#   1 — bad usage

set -uo pipefail

PROJECT=""
EXPLAIN=0
WRITE_CACHE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --explain) EXPLAIN=1; shift ;;
    --write-cache) WRITE_CACHE=1; shift ;;
    -h|--help)
      sed -n '2,30p' "$0" >&2
      exit 0
      ;;
    *) [ -z "$PROJECT" ] && PROJECT="$1" && shift || { shift; } ;;
  esac
done

if [ -z "$PROJECT" ]; then
  echo "usage: mode-detect.sh <project-folder> [--explain] [--write-cache]" >&2
  exit 1
fi

SIGNALS=()
add_signal() { SIGNALS+=("$1"); }

# Greenfield = no Xcode project AND no Podfile AND no Swift sources OR project
# folder doesn't exist.
GREENFIELD=0
if [ ! -d "$PROJECT" ]; then
  GREENFIELD=1
  add_signal "project_folder_missing"
else
  if [ -z "$(find "$PROJECT" -maxdepth 3 -name '*.xcodeproj' -o -name '*.xcworkspace' 2>/dev/null | head -1)" ] \
     && [ -z "$(find "$PROJECT" -maxdepth 3 -name 'Podfile' 2>/dev/null | head -1)" ] \
     && [ -z "$(find "$PROJECT" -maxdepth 5 -name '*.swift' 2>/dev/null | head -1)" ]; then
    GREENFIELD=1
    add_signal "no_xcodeproj_no_podfile_no_swift"
  fi
fi

# Ikame umbrella probe.
IKAME=0
if [ -d "$PROJECT" ]; then
  if find "$PROJECT" -maxdepth 5 -name 'Podfile' -print 2>/dev/null | xargs grep -l "pod ['\"]IKCoreApp['\"]" 2>/dev/null | head -1 | grep -q . ; then
    IKAME=1
    add_signal "podfile_lists_IKCoreApp"
  fi
  if find "$PROJECT" -maxdepth 8 -name '*.swift' 2>/dev/null | xargs grep -l '^import IKCoreApp\b' 2>/dev/null | head -1 | grep -q . ; then
    IKAME=1
    add_signal "swift_imports_IKCoreApp"
  fi
fi

IKXCODEGEN_AVAILABLE=0
command -v ikxcodegen >/dev/null 2>&1 && IKXCODEGEN_AVAILABLE=1
[ $IKXCODEGEN_AVAILABLE -eq 1 ] && add_signal "ikxcodegen_on_PATH"

# Classification.
MODE=""
CONFIDENCE="0.5"
if [ $GREENFIELD -eq 1 ]; then
  if [ $IKXCODEGEN_AVAILABLE -eq 1 ]; then
    # Greenfield + ikxcodegen on PATH → user is on the Ikame fleet (the CLI
    # ships only via gitlab.ikameglobal.com Mint install). Default to the
    # Ikame scaffold path with high confidence; the skill still ASKS the user
    # to confirm before running ikxcodegen (one-line Y/n), but it does NOT
    # silently fall back to vanilla. Use --explain to see the next-step.
    MODE="greenfield-ikame"
    CONFIDENCE="0.85"
    add_signal "ikxcodegen_available — default path, confirm with user before scaffolding"
  else
    MODE="greenfield-vanilla"
    CONFIDENCE="0.90"
  fi
elif [ $IKAME -eq 1 ]; then
  MODE="brownfield-ikame"
  CONFIDENCE="0.95"
else
  # Existing project but no Ikame signals — usually vanilla, but possible
  # partial scaffold. Confidence lower.
  if [ -d "$PROJECT" ] && [ -n "$(find "$PROJECT" -maxdepth 5 -name '*.xcodeproj' 2>/dev/null | head -1)" ]; then
    MODE="brownfield-vanilla"
    CONFIDENCE="0.85"
  else
    MODE="ambiguous"
    CONFIDENCE="0.40"
    add_signal "no_clear_signals — skill should stop and ask before scaffolding"
  fi
fi

# Format signals as JSON array.
SIGNALS_JSON=""
for s in "${SIGNALS[@]:-}"; do
  if [ -n "$SIGNALS_JSON" ]; then SIGNALS_JSON+=","; fi
  SIGNALS_JSON+="\"$(printf '%s' "$s" | sed 's/"/\\"/g')\""
done
OUT="{\"mode\":\"$MODE\",\"confidence\":$CONFIDENCE,\"signals\":[${SIGNALS_JSON}]}"

if [ $EXPLAIN -eq 1 ]; then
  echo "mode-detect.sh report"
  echo "  project: $PROJECT"
  echo "  mode: $MODE (confidence $CONFIDENCE)"
  echo "  signals:"
  for s in "${SIGNALS[@]:-}"; do echo "    - $s"; done
  echo ""
  case "$MODE" in
    greenfield-ikame)
      echo "next: ASK USER (one-line Y/n): \"Detected Ikame fleet (ikxcodegen on PATH). Scaffold via ikxcodegen? [Y/n]\""
      echo "      Y / default → scripts/ikxcodegen-scaffold.sh <ProjectName>"
      echo "      n → scripts/vanilla-scaffold.sh <ProjectName> (rare — only when user opts out explicitly)"
      ;;
    greenfield-vanilla)
      echo "next: run scripts/vanilla-scaffold.sh <ProjectName>"
      ;;
    brownfield-ikame)
      echo "next: load conventions per references/ikame-decision-table.md"
      ;;
    brownfield-vanilla)
      echo "next: run convention-probe and load conventions per references/swiftui-pro-bridge.md"
      ;;
    ambiguous)
      echo "next: STOP and ask user. Do not scaffold over an existing project of unknown topology."
      ;;
  esac
else
  echo "$OUT"
fi

if [ $WRITE_CACHE -eq 1 ] && [ -d "$PROJECT" ]; then
  mkdir -p "$PROJECT/.figma-cache/_shared"
  printf '%s\n' "$OUT" > "$PROJECT/.figma-cache/_shared/mode.json"
fi
