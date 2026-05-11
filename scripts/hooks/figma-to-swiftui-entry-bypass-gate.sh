#!/usr/bin/env bash
# PreToolUse hook on app-entry / root-navigation Swift files.
#
# Detects C5 verification-integrity bypass: editing the app's launch surface
# (App.swift / ContentView.swift / RootView.swift) to "jump" to a non-default
# screen so the agent can `simctl io screenshot` it without driving the
# simulator. Banned per verification-loop.md §"C5 Verification Integrity".
#
# Revision (P0-5 + P1-3):
#   - Terse output, HOOK_VERBOSE=1 for full reference text.
#   - Mode-aware (c1-conventions.json `mode: "scaffold"` → WARN exit 0
#     instead of BLOCK exit 2). Greenfield scaffolds still get the warning
#     in their face, but the file lands so initial flow wiring can proceed.
#
# Exit codes: 0 allow (also for scaffold WARNs), 2 block.

set -uo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

case "$TOOL" in
  Write) CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty') ;;
  Edit)  CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty') ;;
  *)     exit 0 ;;
esac

BASE=$(basename "$FILE_PATH" 2>/dev/null || echo "")
case "$BASE" in
  *App.swift|*ContentView.swift|*RootView.swift|*MainView.swift|*AppRouter.swift|*AppCoordinator.swift) ;;
  *) exit 0 ;;
esac
case "$FILE_PATH" in *_NoFigma_*) exit 0 ;; esac

# Walk up looking for .figma-cache.
DIR=$(dirname "$FILE_PATH" 2>/dev/null || echo "")
PROJECT_ROOT=""
while [ -n "$DIR" ] && [ "$DIR" != "/" ]; do
  if [ -d "$DIR/.figma-cache" ]; then PROJECT_ROOT="$DIR"; break; fi
  DIR=$(dirname "$DIR")
done
if [ -z "$PROJECT_ROOT" ] && [ -d "$PWD/.figma-cache" ]; then PROJECT_ROOT="$PWD"; fi
[ -z "$PROJECT_ROOT" ] && exit 0

[ -z "$CONTENT" ] && exit 0

# Read MODE from c1-conventions.json for P1-3 mode-awareness.
MODE="production"
CONV=""
[ -f "$PROJECT_ROOT/.figma-cache/_shared/c1-conventions.json" ] \
  && CONV="$PROJECT_ROOT/.figma-cache/_shared/c1-conventions.json"
if [ -z "$CONV" ]; then
  shopt -s nullglob
  for d in "$PROJECT_ROOT"/.figma-cache/*/; do
    [ -f "$d/c1-conventions.json" ] && CONV="$d/c1-conventions.json" && break
  done
  shopt -u nullglob
fi
if [ -n "$CONV" ] && [ -f "$CONV" ]; then
  v=$(grep -oE '"mode"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONV" | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)
  [ -n "$v" ] && MODE="$v"
fi

TMP=$(mktemp -t figma-entry.XXXXXX) || exit 0
trap 'rm -f "$TMP"' EXIT
printf '%s' "$CONTENT" > "$TMP"

VIOLATIONS=""
add_violation() { VIOLATIONS+="  $1\n"; }

# Pattern 1: initial/current/verify-step state assignments.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: ${line#*:}"
done < <(grep -nE '(initialStep|initialScreen|initialRoute|currentStep|verifyStep|verifyScreen|debugStep|debugRoute)[^=]*=([^=]|$)' "$TMP" 2>/dev/null || true)

# Pattern 2: VERIFY_ROUTE / --initial-screen / launch-arg overrides.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: ${line#*:}"
done < <(grep -nE 'VERIFY_ROUTE|VERIFY_SCREEN|--initial-screen|--initial-route|LaunchEnvironment\[.*VERIFY' "$TMP" 2>/dev/null || true)

# Pattern 3: #if DEBUG within 8 lines of URL/onOpenURL.
P3=$(awk '
  /^[[:space:]]*#if[[:space:]]+DEBUG/ { debug_at=NR; debug_line=$0 }
  /onOpenURL|URLScheme|urlScheme|deepLink|deep_link/ {
    if (debug_at && NR - debug_at <= 8) {
      print debug_at ": " debug_line
      debug_at=0
    }
  }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: debug-only deep link nearby"
done <<< "$P3"

# Pattern 4: ProcessInfo VERIFY_ key.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: ${line#*:}"
done < <(grep -nE 'ProcessInfo\.processInfo\.environment\[[[:space:]]*"VERIFY' "$TMP" 2>/dev/null || true)

[ -z "$VIOLATIONS" ] && exit 0

# Escape: legitimate flow state marker.
if grep -q 'figma-entry-bypass-gate: legitimate-flow-state' "$TMP" 2>/dev/null; then
  exit 0
fi

# P1-3 + P0-5: mode-aware terse output.
TAG="figma-entry-bypass"
HEADER=""
EXIT_CODE=2
if [ "$MODE" = "scaffold" ]; then
  HEADER="WARN [$TAG, scaffold mode]: $BASE — fix before production switch"
  EXIT_CODE=0
else
  HEADER="BLOCKED [$TAG]: $BASE"
fi

{
  if [ "${HOOK_VERBOSE:-0}" = "1" ]; then
    echo "$HEADER"
    echo ""
    echo "File: $FILE_PATH"
    echo ""
    echo "Suspicious patterns:"
    printf "%b" "$VIOLATIONS"
    echo ""
    echo "These look like C5 verification entry-path bypasses (verification-loop.md §C5 Integrity)."
    echo "Allowed alternatives to reach a screen during verification:"
    echo "  - Use the ios-simulator-verify skill (drives via accessibility ids)."
    echo "  - Use computer-use MCP with request_access for Simulator."
    echo "  - Use existing #Preview / test target."
    echo "  - If none available: set manifest.verification.c5.skipped = \"no_entry_path\"."
    echo ""
    echo "Legitimate non-bypass edit? Add comment:"
    echo "  // figma-entry-bypass-gate: legitimate-flow-state"
  else
    echo "$HEADER"
    printf "%b" "$VIOLATIONS"
    echo "Bypass legit? Add: // figma-entry-bypass-gate: legitimate-flow-state"
    echo "Docs: ~/.claude/skills/figma-to-swiftui/references/verification-loop.md (C5 Integrity)"
  fi
} >&2

exit "$EXIT_CODE"
