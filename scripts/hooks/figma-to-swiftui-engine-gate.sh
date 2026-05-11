#!/usr/bin/env bash
# PreToolUse hook for Bash
#
# Blocks raw `xcodebuild build|test|archive|clean` and `xcrun simctl` build/run
# commands when Engine A (xcode MCP) is available. Forces the agent through the
# mcp__xcode__BuildProject / RenderPreview path that bypasses the SPM resolve
# hang + simctl cold start.
#
# Detection scope:
#   - Only enforces during a figma-to-swiftui session (transcript path probed
#     the same way as figma-to-swiftui-stop-gate.sh). Outside figma sessions,
#     xcodebuild calls are allowed verbatim.
#
# Allowed verbatim (read-only inspect, never the build path):
#   xcodebuild -list, -version, -showsdks, -showBuildSettings, -help
#   xcrun simctl list, devicetypes, runtimes, getenv
#
# Bypass for legitimate Engine B uses:
#   ALLOW_XCODEBUILD=1 xcodebuild ...      (env-var prefix; hook checks raw command)
#
# Exit codes:
#   0 — allow
#   2 — block (stderr shown to Claude)

set -uo pipefail

INPUT=$(cat)

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')

# Empty command → allow (nothing to gate).
[ -z "$COMMAND" ] && exit 0

# ── 1. Session scope — only enforce during a figma-to-swiftui session ────────
# Delegate detection to the shared probe (transcript figma signal / user
# message / cache). Fail-open when probe says "no" — don't gate `xcodebuild`
# on unrelated iOS projects.
PROBE="$(dirname "$0")/_figma-task-probe.sh"
IS_FIGMA="no"
if [ -x "$PROBE" ]; then
  IS_FIGMA=$(printf '%s' "$INPUT" | "$PROBE" 2>/dev/null || echo "no")
fi
[ "$IS_FIGMA" != "yes" ] && exit 0

# ── 2. Bypass via env-var prefix ──────────────────────────────────────────────
# Agent that genuinely needs xcodebuild (debugging the build engine itself,
# investigating an SPM issue, etc.) can run it as:
#   ALLOW_XCODEBUILD=1 xcodebuild ...
case "$COMMAND" in
  *ALLOW_XCODEBUILD=1*) exit 0 ;;
esac

# ── 3. Inspect command for build/run intent ───────────────────────────────────
# Word-bounded match for build verbs. This handles two cases the previous
# substring scheme got wrong:
#   - `xcodebuild -showBuildSettings` — "Build" inside a flag name is NOT a
#     standalone verb, regex \b(build|...)\b doesn't match (no word boundary
#     between "show" and "Build" — both are word chars). Stays allowed.
#   - `xcodebuild -list && xcodebuild build` — compound command with a build
#     segment. The first allow-list pattern *xcodebuild*-list* used to win
#     and bypass the entire gate. Now: presence of \bbuild\b anywhere in
#     the command (with xcodebuild also present) flips NEEDS_GATE; compound
#     commands no longer slip through.
#
# Read-only forms (`-list`, `-version`, `-showsdks`, `-showBuildSettings`,
# `-help`, `simctl list`, `simctl getenv`) never contain the verb words so
# they fall through NEEDS_GATE=0 and exit naturally — no allow-list needed.
NEEDS_GATE=0
if printf '%s' "$COMMAND" | grep -qE '\bxcodebuild\b' \
   && printf '%s' "$COMMAND" | grep -qiE '\b(build|test|archive|clean|run)\b'; then
  NEEDS_GATE=1
fi
if printf '%s' "$COMMAND" | grep -qE '\bsimctl\b' \
   && printf '%s' "$COMMAND" | grep -qE '\b(boot|install|launch)\b'; then
  NEEDS_GATE=1
fi
# simctl io screenshot specifically — verb "screenshot" with "io" subcommand.
if printf '%s' "$COMMAND" | grep -qE '\bsimctl\b.*\bio\b.*\bscreenshot\b'; then
  NEEDS_GATE=1
fi

[ "$NEEDS_GATE" = "0" ] && exit 0

# ── 4. Probe Engine A availability ────────────────────────────────────────────
MCPBRIDGE_OK=0
xcrun mcpbridge --help >/dev/null 2>&1 && MCPBRIDGE_OK=1
XCODE_RUNNING=0
pgrep -x Xcode >/dev/null 2>&1 && XCODE_RUNNING=1

# Engine A unavailable → legitimate Engine B run, allow.
if [ "$MCPBRIDGE_OK" = "0" ] || [ "$XCODE_RUNNING" = "0" ]; then
  exit 0
fi

# ── 5. Engine A available — block and surface guidance ───────────────────────
{
  echo "BLOCKED: Engine A (xcode MCP) is available — raw \`xcodebuild\` / \`xcrun simctl\` would be a regression."
  echo ""
  echo "Detected command (intent: build / install / launch / capture):"
  echo "  $COMMAND"
  echo ""
  echo "Engine A path (preferred — bypasses SPM resolve hang and simctl cold start):"
  echo "  mcp__xcode__BuildProject          — full project build (writes structured diagnostics)"
  echo "  mcp__xcode__RenderPreview         — #Preview snapshot for C5 visual diff"
  echo "  mcp__xcode__XcodeListWindows      — discover workspace tab id"
  echo "  mcp__xcode__XcodeListNavigatorIssues / GetBuildLog — read failures"
  echo "  mcp__xcode__XcodeRefreshCodeIssuesInFile — sub-second compile-error catch"
  echo ""
  echo "If these tools aren't visible in your toolbox yet (deferred), load them in bulk:"
  echo "  ToolSearch query=\"xcode\" max_results=30"
  echo ""
  echo "Confirm engine choice with:"
  echo "  scripts/c5-engine-select.sh --screen-file <path-to-screen.swift> --explain"
  echo ""
  echo "Legitimate Engine B reasons (debug SPM, archive for distribution, etc.):"
  echo "  prefix the command with ALLOW_XCODEBUILD=1, e.g."
  echo "    ALLOW_XCODEBUILD=1 xcodebuild -scheme Foo -destination 'platform=iOS Simulator,...' build"
  echo "  The bypass is logged in the transcript; use it sparingly."
} >&2

exit 2
