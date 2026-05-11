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
#   (1) STRICT — transcript shows a figma-to-swiftui skill invocation,
#       a Figma MCP tool call, OR a literal "figma.com/" URL. These are
#       conclusive: the agent (or user) explicitly referenced Figma.
#
#   (2) BROAD — transcript contains the word "figma" anywhere (case-
#       insensitive, word-bounded). Catches user messages like "làm màn
#       này từ figma" before the agent has invoked any tool. Suppressed
#       by --strict.
#
#   (3) CACHE — PWD or any ancestor (up to 6 levels) contains a
#       .figma-cache/ directory. Once the cache exists, the project is
#       unambiguously in a figma task.
#
# Skill-repo bypass: when both `figma-to-swiftui/SKILL.md` AND
# `figma-flow-to-swiftui-feature/SKILL.md` exist together up the tree, we
# are inside this skill's own development repo (e.g. minh editing SKILL.md
# right now). Every signal would false-positive. Echo "no" immediately.
#
# Usage:
#   IS_FIGMA=$(printf '%s' "$INPUT" | "$(dirname "$0")/_figma-task-probe.sh" [--strict])
#   case "$IS_FIGMA" in yes) ...enforce... ;; *) exit 0 ;; esac
#
# Flags:
#   --strict   Drop signal 2 (broad word match). Used by Stop hook so a
#              session-wide block requires a strict signal, not just any
#              mention of "figma" in transcript.
#
# Reads JSON hook input from stdin (transcript_path is parsed out). Stdout:
# the literal string "yes" or "no". Exit code always 0.

set -uo pipefail

STRICT=0
case "${1:-}" in
  --strict) STRICT=1 ;;
esac

INPUT=$(cat)

# ── Skill-repo bypass ───────────────────────────────────────────────────────
# When the user is INSIDE this skill's source repo (editing SKILL.md,
# updating a hook, writing reference docs), transcripts naturally contain
# "figma" all over the place. We must NOT block the dev workflow.
# Heuristic: both SKILL.md files are co-located up the tree.
D="$PWD"
for _ in 1 2 3 4 5 6; do
  if [ -f "$D/figma-to-swiftui/SKILL.md" ] && [ -f "$D/figma-flow-to-swiftui-feature/SKILL.md" ]; then
    echo "no"
    exit 0
  fi
  PARENT=$(dirname "$D")
  [ "$PARENT" = "$D" ] && break
  D="$PARENT"
done

# (1) + (2) transcript signal
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
  # Strict-figma signal — tool_use names / skill names / Figma URL that
  # conclusively indicate a figma session.
  STRICT_SIGNAL='"skill":[[:space:]]*"figma-to-swiftui|"skill":[[:space:]]*"figma-flow-to-swiftui-feature|"name":[[:space:]]*"mcp__[A-Za-z0-9_]*[Ff]igma|"name":[[:space:]]*"figma_(extract_tokens|extract_fills|export_assets|export_assets_unified|build_registry|list_assets)|figma\.com/'
  if grep -qE "$STRICT_SIGNAL" "$TRANSCRIPT_PATH" 2>/dev/null; then
    echo "yes"
    exit 0
  fi
  # Broad signal — the literal word "figma" anywhere. Suppressed by --strict.
  if [ "$STRICT" = "0" ]; then
    if grep -qiE '\bfigma\b' "$TRANSCRIPT_PATH" 2>/dev/null; then
      echo "yes"
      exit 0
    fi
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
