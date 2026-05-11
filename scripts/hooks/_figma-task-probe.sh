#!/usr/bin/env bash
# _figma-task-probe.sh — shared helper used by every figma-to-swiftui hook.
#
# Closes the chicken-and-egg gap: before this probe, hooks only fired when
# .figma-cache/ already existed. An agent that skipped Phase A entirely
# never created the cache → every gate slept → user got a "from Figma" run
# with no Figma artifacts, no asset export, no visual diff.
#
# Detection signals (any one → "yes"):
#
#   (1) Transcript shows a figma-to-swiftui skill invocation OR a Figma MCP
#       tool call — same pattern as figma-to-swiftui-stop-gate.sh.
#
#   (2) Transcript contains the word "figma" anywhere (case-insensitive,
#       word-bounded). Catches user messages like "làm màn này từ figma"
#       OR "from figma" OR "figma.com/..." OR MCP server names mentioned
#       in the agent's own thinking. False positives are an acceptable
#       cost — the hook's response (force mode-detect + Phase A) is short
#       and the agent can clearly explain to the user if a generic iOS
#       task got caught by accident.
#
#   (3) PWD or any ancestor (up to 6 levels) contains a .figma-cache/
#       directory. Once the cache exists, the project is unambiguously
#       in a figma task.
#
# Usage:
#   IS_FIGMA=$(printf '%s' "$INPUT" | "$(dirname "$0")/_figma-task-probe.sh")
#   case "$IS_FIGMA" in yes) ...enforce... ;; *) exit 0 ;; esac
#
# Reads JSON hook input from stdin (transcript_path is parsed out). Stdout:
# the literal string "yes" or "no". Exit code always 0.

set -uo pipefail

INPUT=$(cat)

# (1) + (2) transcript signal
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
  # Strict-figma signal — tool_use names / skill names that conclusively
  # indicate a figma session.
  STRICT_SIGNAL='"skill":[[:space:]]*"figma-to-swiftui|"skill":[[:space:]]*"figma-flow-to-swiftui-feature|"name":[[:space:]]*"mcp__[A-Za-z0-9_]*[Ff]igma|"name":[[:space:]]*"figma_(extract_tokens|extract_fills|export_assets|export_assets_unified|build_registry|list_assets)|figma\.com/'
  if grep -qE "$STRICT_SIGNAL" "$TRANSCRIPT_PATH" 2>/dev/null; then
    echo "yes"
    exit 0
  fi
  # Broad-figma signal — the literal word "figma" (case-insensitive, word-
  # bounded). Catches user messages mentioning Figma without using the URL.
  if grep -qiE '\bfigma\b' "$TRANSCRIPT_PATH" 2>/dev/null; then
    echo "yes"
    exit 0
  fi
fi

# (3) cache exists up the tree
D="$PWD"
for _ in 1 2 3 4 5 6; do
  if [ -d "$D/.figma-cache" ]; then
    echo "yes"
    exit 0
  fi
  PARENT=$(dirname "$D")
  [ "$PARENT" = "$D" ] && break
  D="$PARENT"
done

echo "no"
exit 0
