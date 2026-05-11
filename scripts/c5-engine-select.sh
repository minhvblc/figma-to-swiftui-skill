#!/usr/bin/env bash
# c5-engine-select.sh — pick the C5 engine (Engine A: xcode MCP,
# Engine B: xcodebuild + simctl). Deterministic probe replacing the
# "probe via Claude Code's tool registry" prose in
# figma-to-swiftui/SKILL.md §C5.0.
#
# The agent calls this once at C5 start, parses the JSON, and stashes
# the result into manifest.verification.c5.engine.
#
# Engine A is preferred — bypasses `xcodebuild -list` SPM resolve hang
# and `simctl boot/install/launch` cold start. Requires Xcode 26+
# (ships `xcrun mcpbridge`) AND Xcode running with the target project
# open AND the screen file carrying a `#Preview { ... }` block.
#
# Engine B (xcodebuild + simctl) is the universal fallback.
#
# Usage:
#   c5-engine-select.sh [--screen-file <path-to-*Screen.swift>] [--explain]
#
# Stdout (default):
#   single-line JSON:
#     {"engine":"xcode-mcp"|"xcodebuild",
#      "reason":"...",
#      "preReqs":{"mcpbridge":bool,"xcodeRunning":bool,"previewBlock":bool|null}}
#
# Stdout (--explain):
#   human-readable report instead of JSON.
#
# Exit codes:
#   0  — probe ran, engine selected (read stdout for which)
#   64 — bad usage
#   65 — environment failure (no xcrun / no python3)

set -uo pipefail

SCREEN_FILE=""
EXPLAIN=0

print_usage() { sed -n '2,30p' "$0" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --screen-file) SCREEN_FILE="${2:-}"; shift 2 ;;
    --explain)     EXPLAIN=1; shift ;;
    -h|--help)     print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

command -v xcrun >/dev/null 2>&1 || { echo "FAIL: xcrun not found (Xcode CLT missing)" >&2; exit 65; }

# ── Probe 1 — xcrun mcpbridge (Xcode 26+ ships it) ────────────────────────────
MCPBRIDGE_OK=0
if xcrun mcpbridge --help >/dev/null 2>&1; then
  MCPBRIDGE_OK=1
fi

# ── Probe 2 — Xcode.app running (mcpbridge needs a live session) ──────────────
XCODE_RUNNING=0
if pgrep -x Xcode >/dev/null 2>&1; then
  XCODE_RUNNING=1
fi

# ── Probe 3 — screen file carries a #Preview block (optional) ─────────────────
# 1 = has #Preview, 0 = no #Preview, 2 = not probed (no --screen-file)
PREVIEW_OK=2
if [ -n "$SCREEN_FILE" ]; then
  if [ -f "$SCREEN_FILE" ]; then
    if grep -qE '^[[:space:]]*#Preview[[:space:]]*\{?' "$SCREEN_FILE" 2>/dev/null; then
      PREVIEW_OK=1
    else
      PREVIEW_OK=0
    fi
  else
    PREVIEW_OK=0
  fi
fi

# ── Decision tree ─────────────────────────────────────────────────────────────
ENGINE="xcodebuild"
REASON=""
if [ $MCPBRIDGE_OK -eq 0 ]; then
  REASON="xcrun mcpbridge unavailable (Xcode < 26?). Engine A requires Xcode 26+. Install/update from the App Store and re-run."
elif [ $XCODE_RUNNING -eq 0 ]; then
  REASON="Xcode is not running. Start Xcode (open the target .xcworkspace/.xcodeproj) and re-run for Engine A. Falling back to Engine B."
elif [ $PREVIEW_OK -eq 0 ]; then
  REASON="Screen file lacks a top-level #Preview { ... } block. C2 emit must add one (canonical for Ikame + non-Ikame). Falling back to Engine B."
else
  ENGINE="xcode-mcp"
  if [ $PREVIEW_OK -eq 1 ]; then
    REASON="Xcode 26 mcpbridge OK + Xcode running + screen has #Preview. Engine A selected."
  else
    REASON="Xcode 26 mcpbridge OK + Xcode running. Screen #Preview not probed (no --screen-file). Engine A selected."
  fi
fi

# Map PREVIEW_OK to a JSON literal.
case $PREVIEW_OK in
  1) PREVIEW_JSON="true" ;;
  0) PREVIEW_JSON="false" ;;
  *) PREVIEW_JSON="null" ;;
esac

emit_json() {
  printf '{"engine":"%s","reason":"%s","preReqs":{"mcpbridge":%s,"xcodeRunning":%s,"previewBlock":%s}}\n' \
    "$ENGINE" \
    "$(printf '%s' "$REASON" | sed 's/"/\\"/g')" \
    "$([ $MCPBRIDGE_OK -eq 1 ] && echo true || echo false)" \
    "$([ $XCODE_RUNNING -eq 1 ] && echo true || echo false)" \
    "$PREVIEW_JSON"
}

if [ $EXPLAIN -eq 1 ]; then
  echo "c5-engine-select.sh report"
  echo "  xcrun mcpbridge available : $([ $MCPBRIDGE_OK -eq 1 ] && echo yes || echo no)"
  echo "  Xcode app running         : $([ $XCODE_RUNNING -eq 1 ] && echo yes || echo no)"
  case $PREVIEW_OK in
    1) echo "  Screen has #Preview block : yes ($SCREEN_FILE)" ;;
    0) echo "  Screen has #Preview block : no  ($SCREEN_FILE) — add a #Preview { ... } in C2" ;;
    *) echo "  Screen has #Preview block : (not probed — pass --screen-file <path>)" ;;
  esac
  echo "  Selected engine           : $ENGINE"
  echo "  Reason                    : $REASON"
  echo ""
  case "$ENGINE" in
    xcode-mcp)
      echo "next: stash 'xcode-mcp' in manifest.verification.c5.engine"
      echo "      Required Xcode MCP tools (load via ToolSearch if deferred):"
      echo "        select:mcp__xcode__BuildProject,mcp__xcode__RenderPreview,"
      echo "               mcp__xcode__XcodeListWindows,mcp__xcode__XcodeListNavigatorIssues,"
      echo "               mcp__xcode__GetBuildLog,mcp__xcode__XcodeRefreshCodeIssuesInFile"
      echo "      Skip: xcodebuild + simctl + sips -Z 2000 (RenderPreview returns canvas-sized PNG)."
      ;;
    xcodebuild)
      echo "next: stash 'xcodebuild' in manifest.verification.c5.engine"
      echo "      Run Engine B steps C5.1..C5.6 per SKILL.md / verification-loop.md §5."
      [ $MCPBRIDGE_OK -eq 0 ] && echo "      To unlock Engine A: update to Xcode 26+ from the App Store."
      [ $MCPBRIDGE_OK -eq 1 ] && [ $XCODE_RUNNING -eq 0 ] && echo "      To unlock Engine A: open Xcode with the target project, then re-run."
      [ $MCPBRIDGE_OK -eq 1 ] && [ $XCODE_RUNNING -eq 1 ] && [ $PREVIEW_OK -eq 0 ] && echo "      To unlock Engine A: add a #Preview { ... } block to the screen file."
      ;;
  esac
else
  emit_json
fi

exit 0
