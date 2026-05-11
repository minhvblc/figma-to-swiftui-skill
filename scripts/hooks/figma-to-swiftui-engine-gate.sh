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
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')

# Empty command → allow (nothing to gate).
[ -z "$COMMAND" ] && exit 0

# ── 1. Session scope — only enforce during a figma-to-swiftui session ────────
# Two signals (either flips it on; both off → allow). Outside a figma session,
# the agent might be doing iOS coding for a different task and `xcodebuild`
# is legitimate — let it pass.
#
#   (a) Transcript shows a figma-to-swiftui skill call or figma MCP tool call
#       (mirrors the signal grep in figma-to-swiftui-stop-gate.sh).
#   (b) Current working directory (or any ancestor up to 6 levels) contains
#       a .figma-cache/ — the unambiguous on-disk signature of a figma task.
#
# When neither signal is present, fail open (allow). Don't gate `xcodebuild`
# on unrelated projects.
IN_FIGMA_SESSION=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
  FIGMA_SIGNAL='"skill":[[:space:]]*"figma-to-swiftui|"skill":[[:space:]]*"figma-flow-to-swiftui-feature|"name":[[:space:]]*"mcp__[A-Za-z0-9_]*[Ff]igma|"name":[[:space:]]*"figma_(extract_tokens|export_assets|export_assets_unified|build_registry)'
  if grep -qE "$FIGMA_SIGNAL" "$TRANSCRIPT_PATH" 2>/dev/null; then
    IN_FIGMA_SESSION=1
  fi
fi
if [ "$IN_FIGMA_SESSION" = "0" ]; then
  D="$PWD"
  for _ in 1 2 3 4 5 6; do
    if [ -d "$D/.figma-cache" ]; then
      IN_FIGMA_SESSION=1
      break
    fi
    PARENT=$(dirname "$D")
    [ "$PARENT" = "$D" ] && break
    D="$PARENT"
  done
fi

[ "$IN_FIGMA_SESSION" = "0" ] && exit 0

# ── 2. Bypass via env-var prefix ──────────────────────────────────────────────
# Agent that genuinely needs xcodebuild (debugging the build engine itself,
# investigating an SPM issue, etc.) can run it as:
#   ALLOW_XCODEBUILD=1 xcodebuild ...
case "$COMMAND" in
  *ALLOW_XCODEBUILD=1*) exit 0 ;;
esac

# ── 3. Inspect command for build/run intent ───────────────────────────────────
# Look for the build keywords on the same word as xcodebuild OR within the
# command following it. We match liberally on a substring basis; the read-only
# allow-list below pre-empts the false positives.
NEEDS_GATE=0
case "$COMMAND" in
  *xcodebuild*build*)   NEEDS_GATE=1 ;;
  *xcodebuild*test*)    NEEDS_GATE=1 ;;
  *xcodebuild*archive*) NEEDS_GATE=1 ;;
  *xcodebuild*clean*)   NEEDS_GATE=1 ;;
  *xcodebuild*run*)     NEEDS_GATE=1 ;;
  *xcrun*simctl*boot*)         NEEDS_GATE=1 ;;
  *xcrun*simctl*install*)      NEEDS_GATE=1 ;;
  *xcrun*simctl*launch*)       NEEDS_GATE=1 ;;
  *xcrun*simctl*io*screenshot*) NEEDS_GATE=1 ;;
esac

[ "$NEEDS_GATE" = "0" ] && exit 0

# Allow-list pre-empts the gate: read-only inspection commands stay free.
case "$COMMAND" in
  *xcodebuild*-list*)              exit 0 ;;
  *xcodebuild*-version*)           exit 0 ;;
  *xcodebuild*-showsdks*)          exit 0 ;;
  *xcodebuild*-showBuildSettings*) exit 0 ;;
  *xcodebuild*-help*)              exit 0 ;;
  *xcrun*simctl*list*)             exit 0 ;;
  *xcrun*simctl*getenv*)           exit 0 ;;
esac

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
