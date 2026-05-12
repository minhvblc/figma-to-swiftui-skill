#!/usr/bin/env bash
# _figma-task-probe.sh — shared helper used by every figma-to-swiftui hook.
#
# Detection rule (single, strict):
#
#   The user has pasted a real Figma file URL in one of their own chat
#   messages. That's it. No tool_use signals, no Skill-invocation signals,
#   no cache-existence signals.
#
# Why strict — observed failure modes that broader signals caused:
#
#   1. MCP figma server instructions ARE injected into every session that
#      has the figma MCP registered globally. Those instructions contain
#      example URLs like `figma.com/design/:fileKey/...` and tool-name
#      listings. A loose grep over the raw transcript would flag every
#      unrelated session that happened to have figma MCP installed.
#
#   2. Tool definitions in the system prompt (`mcp__figma-assets__*`,
#      `mcp__figma-desktop__*`) appear as plain text in the system
#      reminder, NOT as actual tool_use blocks. A tool_use-based signal
#      that scanned raw text would still flag them.
#
#   3. Reading skill source files (`cat scripts/hooks/<name>.sh`,
#      `Read SKILL.md`) puts figma references into tool_result content.
#      That's documentation flowing through the agent, not user intent.
#
# Trade-off accepted by this rule: if the user invokes `/figma-to-swiftui`
# (slash command / Skill tool) WITHOUT pasting a URL — relying instead on
# the figma-desktop "current selection" — the hooks will NOT fire. In
# practice the slash command always carries a URL (the canonical entry
# pattern in SKILL.md Step A1), so the gap is narrow. Users on the
# selection-only path can paste the URL alongside ("implement what I have
# selected, file: https://figma.com/design/abc...") to re-enable hooks.
#
# Detection mechanics:
#   - Scan ONLY user `text` content blocks in the transcript JSONL.
#   - Strip `<system-reminder>` and `<command-name>` blocks before matching
#     — system reminders contain MCP instructions and slash-command meta,
#     neither is user-typed.
#   - URL pattern requires an alphanumeric/dash character after the path
#     segment, so template URLs like `figma.com/design/:fileKey` (from
#     docs / MCP instructions inadvertently echoed into user text) don't
#     match.
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

# Single signal — user pasted a Figma URL in their own chat text.
TRANSCRIPT_PATH=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty' 2>/dev/null)
if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
  RESULT=$(python3 - "$TRANSCRIPT_PATH" <<'PY' 2>/dev/null
import json, re, sys

TRANSCRIPT_PATH = sys.argv[1]

# Real Figma URLs have an alphanumeric/dash fileKey after the path segment.
# Template URLs `figma.com/design/:fileKey` (with `:` placeholder) don't
# match — those only appear in MCP server instructions / docs.
URL_RE = re.compile(r'figma\.com/(design|file|board|slides|make)/[A-Za-z0-9\-]')

# Strip system-injected blocks before matching:
#   - <system-reminder>...</system-reminder>: MCP server instructions, hook
#     reminders, environment context. Never user-typed.
#   - <command-name>...</command-name>: the slash-command name only
#     (e.g. "figma-to-swiftui"). The actual URL the user typed lives in
#     <command-args>, which we DO NOT strip — that IS user input.
SYSTEM_REMINDER_RE = re.compile(r'<system-reminder>.*?</system-reminder>', re.DOTALL)
COMMAND_NAME_RE    = re.compile(r'<command-name>.*?</command-name>',       re.DOTALL)

try:
    with open(TRANSCRIPT_PATH) as f:
        for line in f:
            try:
                entry = json.loads(line)
            except Exception:
                continue
            msg = entry.get("message") or {}
            if msg.get("role") != "user":
                continue
            content = msg.get("content")
            if not content:
                continue
            blocks = content if isinstance(content, list) else [{"type": "text", "text": content}]
            for block in blocks:
                if not isinstance(block, dict):
                    continue
                if block.get("type") != "text":
                    # Skip tool_result, image, etc. — only user-typed text counts.
                    continue
                text = block.get("text", "") or ""
                text = SYSTEM_REMINDER_RE.sub('', text)
                text = COMMAND_NAME_RE.sub('', text)
                if URL_RE.search(text):
                    print("yes")
                    sys.exit(0)
except (FileNotFoundError, PermissionError):
    pass
print("no")
PY
  )
  if [ "$RESULT" = "yes" ]; then
    echo "yes"
    exit 0
  fi
fi

echo "no"
exit 0
