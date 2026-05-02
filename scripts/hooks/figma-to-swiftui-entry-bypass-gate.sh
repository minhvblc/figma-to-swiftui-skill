#!/usr/bin/env bash
# PreToolUse hook for Write/Edit on app-entry / root-navigation Swift files.
#
# Detects the most common C5 verification-integrity bypass: editing the app's
# launch surface (App.swift / ContentView.swift / RootView.swift) to "jump"
# to a non-default screen so the agent can `simctl io screenshot` it without
# driving the simulator. Banned per
# figma-to-swiftui/references/verification-loop.md §"C5 Verification Integrity".
#
# Triggers when ALL of the following hold:
#   1. File path matches *App.swift / *ContentView.swift / *RootView.swift /
#      *MainView.swift / *AppRouter.swift (heuristic for root navigation surface).
#   2. File lives inside a project whose tree contains .figma-cache/ — i.e. a
#      figma-to-swiftui task is in progress.
#   3. The pending content (Write.content or Edit.new_string) contains a pattern
#      that strongly suggests a verification entry-path manipulation:
#        - `initialStep`, `initialScreen`, `currentStep`, `verifyStep` set to a
#          string literal naming a screen (e.g. `currentStep = .pinSetup`).
#        - `VERIFY_ROUTE`, `--initial-screen`, `--initial-route` in launch args.
#        - `#if DEBUG` block adding deep-link parsing or route override.
#        - `LaunchEnvironment` set with `VERIFY_*` keys.
#
# Exit codes:
#   0 — allow (no pattern matched, OR legitimate non-bypass edit)
#   2 — block + stderr (pattern matched, treat as banned bypass)

set -uo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

case "$TOOL" in
  Write)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')
    ;;
  Edit)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty')
    ;;
  *)
    exit 0
    ;;
esac

# Filter by file name. Use basename to avoid path-component false positives.
BASE=$(basename "$FILE_PATH" 2>/dev/null || echo "")
case "$BASE" in
  *App.swift|*ContentView.swift|*RootView.swift|*MainView.swift|*AppRouter.swift|*AppCoordinator.swift) ;;
  *) exit 0 ;;
esac

# Escape hatch.
case "$FILE_PATH" in
  *_NoFigma_*) exit 0 ;;
esac

# Require a figma task context.
DIR=$(dirname "$FILE_PATH" 2>/dev/null || echo "")
FIGMA_TASK=0
while [ -n "$DIR" ] && [ "$DIR" != "/" ]; do
  if [ -d "$DIR/.figma-cache" ]; then
    FIGMA_TASK=1
    break
  fi
  DIR=$(dirname "$DIR")
done

if [ "$FIGMA_TASK" = "0" ] && [ -d "$PWD/.figma-cache" ]; then
  FIGMA_TASK=1
fi

[ "$FIGMA_TASK" = "0" ] && exit 0

# Empty content → allow.
[ -z "$CONTENT" ] && exit 0

# Detect bypass patterns. Each pattern is a regex; first match wins.
TMP=$(mktemp -t figma-entry.XXXXXX) || exit 0
trap 'rm -f "$TMP"' EXIT
printf '%s' "$CONTENT" > "$TMP"

VIOLATIONS=""

# Pattern 1: initial/current/verify-step state assignments / declarations.
# Match the keyword on a line that also contains a single `=` (assignment, not `==`).
# Allows `var initialStep: Step = .x` and `currentStep = .x` while rejecting `if x == .y`.
P1=$(grep -nE '(initialStep|initialScreen|initialRoute|currentStep|verifyStep|verifyScreen|debugStep|debugRoute)[^=]*=([^=]|$)' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  VIOLATIONS+="  line $lineno: ${line#*:}\n"
done <<< "$P1"

# Pattern 2: VERIFY_ROUTE / --initial-screen / launch-arg overrides.
P2=$(grep -nE 'VERIFY_ROUTE|VERIFY_SCREEN|--initial-screen|--initial-route|LaunchEnvironment\[.*VERIFY' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  VIOLATIONS+="  line $lineno: ${line#*:}\n"
done <<< "$P2"

# Pattern 3: #if DEBUG block adding deep-link / URL handler. Heuristic — match
# `#if DEBUG` within 8 lines of `URL`/`urlScheme`/`onOpenURL` in this file.
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
  VIOLATIONS+="  line $lineno: $(echo "${line#*:}" | head -c 80) ... — looks like a debug-only deep link\n"
done <<< "$P3"

# Pattern 4: ProcessInfo.processInfo.environment lookup with VERIFY-ish key.
P4=$(grep -nE 'ProcessInfo\.processInfo\.environment\[[[:space:]]*"VERIFY' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  VIOLATIONS+="  line $lineno: ${line#*:}\n"
done <<< "$P4"

if [ -z "$VIOLATIONS" ]; then
  exit 0
fi

{
  echo "BLOCKED: figma-to-swiftui entry-path bypass detector"
  echo ""
  echo "File: $FILE_PATH"
  echo "Tool: $TOOL"
  echo ""
  echo "Suspicious patterns in pending content:"
  printf "%b" "$VIOLATIONS"
  echo ""
  echo "These patterns look like a C5 verification entry-path bypass — banned by"
  echo "references/verification-loop.md §\"C5 Verification Integrity\":"
  echo ""
  echo "  Adding a launch-arg / env-var route override / debug-only deep-link parser"
  echo "  / mutating the app's initial step in source so the simulator boots into a"
  echo "  non-default screen for screenshotting — these all bypass real navigation,"
  echo "  ship a debug entrypoint into the binary, and produce screenshots that do"
  echo "  not reflect the real journey."
  echo ""
  echo "Allowed paths to reach a non-default screen during C5:"
  echo "  - Use an existing #Preview / scheme / test target the project already ships."
  echo "  - Use the ios-simulator-verify skill (drives via accessibility identifiers)."
  echo "  - Use the computer-use MCP with request_access for Simulator."
  echo "  - If none of the above is available: set"
  echo "      manifest.verification.c5.skipped = \"no_entry_path\""
  echo "    and surface the limitation truthfully to the user."
  echo ""
  echo "If this edit is genuinely NOT a verification bypass (e.g. you are wiring up"
  echo "the real onboarding flow's initial state), include the comment"
  echo "    // figma-entry-bypass-gate: legitimate-flow-state"
  echo "on the same line as the assignment, OR include the segment '_NoFigma_' in"
  echo "the file path. Both bypass this hook by design."
} >&2

# Final escape: if the agent already added the legitimate-flow-state marker
# anywhere in the new content, allow.
if grep -q 'figma-entry-bypass-gate: legitimate-flow-state' "$TMP" 2>/dev/null; then
  exit 0
fi

exit 2
