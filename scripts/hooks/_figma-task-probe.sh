#!/usr/bin/env bash
# _figma-task-probe.sh — shared helper used by every figma-to-swiftui hook.
#
# Closes the chicken-and-egg gap: before this probe, hooks only fired when
# .figma-cache/ already existed. An agent that skipped Phase A entirely
# never created the cache → every gate slept → user got a "from Figma" run
# with no Figma artifacts, no asset export, no visual diff.
#
# Detection signals — both must be transcript-derived to scope strictly to
# the CURRENT session. Cache-existence is intentionally NOT a signal: a
# stale .figma-cache/ from a prior session would otherwise false-positive
# unrelated iOS work (the Gap C scenario — user runs the skill once, then
# weeks later opens the same project for a networking refactor and hits
# enforcement against work that has nothing to do with Figma).
#
#   (1) FIGMA URL — transcript contains a Figma app URL with one of the
#       canonical paths (design/file/board/slides/make). The user pasting
#       `https://www.figma.com/design/<fileKey>/...?node-id=...` is the
#       primary entry to a figma-to-swiftui run.
#
#   (2) FIGMA TOOL / SKILL — transcript shows a tool_use of any
#       mcp__figma* tool (figma-desktop, figma-assets) OR a direct
#       figma_* tool call OR a Skill invocation of figma-to-swiftui /
#       figma-flow-to-swiftui-feature. Covers the figma-desktop "current
#       selection" path (no URL needed) AND the slash-command entry.
#       Also covers any later turn in a multi-turn session — once the
#       agent has called a figma tool, every subsequent hook fire still
#       sees the signal in transcript.
#
# Skill-repo bypass: when both `figma-to-swiftui/SKILL.md` AND
# `figma-flow-to-swiftui-feature/SKILL.md` exist together up the tree, we
# are inside this skill's own development repo (e.g. minh editing SKILL.md
# right now). The dev workflow inevitably mentions Figma everywhere; we
# must NOT block it. Echo "no" immediately.
#
# Usage:
#   IS_FIGMA=$(printf '%s' "$INPUT" | "$(dirname "$0")/_figma-task-probe.sh")
#   case "$IS_FIGMA" in yes) ...enforce... ;; *) exit 0 ;; esac
#
# Reads JSON hook input from stdin (transcript_path is parsed out). Stdout:
# the literal string "yes" or "no". Exit code always 0.

set -uo pipefail

INPUT=$(cat)

# ── Skill-repo bypass ───────────────────────────────────────────────────────
# When the user is INSIDE this skill's source repo (editing SKILL.md,
# updating a hook, writing reference docs), transcripts naturally contain
# "figma" all over the place. Skip enforcement entirely.
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

# Transcript signals (1) + (2) — URL paste OR figma tool/skill use
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
  # Figma URL must use Figma's actual app paths (design/file/board/slides/make).
  # Plain `figma.com/` substring would false-match URLs like
  # `mycompany.com/figma.com/foo` or stray prose mentions.
  FIGMA_SIGNAL='figma\.com/(design|file|board|slides|make)/|"skill":[[:space:]]*"figma-to-swiftui|"skill":[[:space:]]*"figma-flow-to-swiftui-feature|"name":[[:space:]]*"mcp__[A-Za-z0-9_]*[Ff]igma|"name":[[:space:]]*"figma_(extract_tokens|extract_fills|export_assets|export_assets_unified|build_registry|list_assets)'
  if grep -qE "$FIGMA_SIGNAL" "$TRANSCRIPT_PATH" 2>/dev/null; then
    echo "yes"
    exit 0
  fi
fi

echo "no"
exit 0
