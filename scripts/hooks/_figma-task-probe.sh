#!/usr/bin/env bash
# _figma-task-probe.sh — shared helper used by every figma-to-swiftui hook.
#
# Detection rule (URL + activity, plus explicit bypass):
#
#   Real figma implementation task = (A) user pasted a real Figma file URL
#   in their own chat text, AND (B) the assistant actually performed UI
#   work this session — either invoked a Figma MCP tool, or wrote/edited
#   a .swift file. If A is missing → not a figma task. If A is present
#   but B is missing → planning / review / discussion only, bypass to
#   avoid false-positive blocking on every Stop forever.
#
#   Explicit override: if any transcript block (user text, assistant tool
#   input, tool_result) references a .swift path containing the literal
#   marker `_NoFigma_`, the run is treated as not-a-figma-task and gates
#   are skipped. This matches the bypass docs printed by
#   figma-to-swiftui-stop-gate.sh.
#
# Why this shape — observed failure modes:
#
#   1. MCP figma server instructions ARE injected into every session that
#      has the figma MCP registered globally. Those instructions contain
#      example URLs like `figma.com/design/:fileKey/...` and tool-name
#      listings. A loose grep over the raw transcript would flag every
#      unrelated session that happened to have figma MCP installed.
#
#   2. Tool definitions in the system prompt (`mcp__figma-assets__*`,
#      `mcp__figma-desktop__*`) appear as plain text in the system
#      reminder, NOT as actual tool_use blocks. We match tool_use names
#      directly rather than raw text to avoid false positives from this.
#
#   3. Reading skill source files (`cat scripts/hooks/<name>.sh`,
#      `Read SKILL.md`) puts figma references into tool_result content.
#      That's documentation flowing through the agent, not user intent.
#
#   4. Planning / review sessions where the user pastes a Figma URL as
#      *reference* (e.g. "review this plan against the design") used to
#      block every Stop forever because the URL stayed in transcript
#      history. Adding the activity gate (Figma MCP invocation OR .swift
#      write) closes that loop — pure markdown / discussion work bypasses.
#
# Trade-off: if the user invokes `/figma-to-swiftui` WITHOUT pasting a URL
# the hooks will NOT fire. In practice the slash command always carries a
# URL (canonical entry pattern in SKILL.md Step A1), so the gap is narrow.
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

# Strip system-injected blocks before matching user text:
#   - <system-reminder>...</system-reminder>: MCP server instructions, hook
#     reminders, environment context. Never user-typed.
#   - <command-name>...</command-name>: the slash-command name only.
SYSTEM_REMINDER_RE = re.compile(r'<system-reminder>.*?</system-reminder>', re.DOTALL)
COMMAND_NAME_RE    = re.compile(r'<command-name>.*?</command-name>',       re.DOTALL)

# Figma MCP tool names — covers known namespaces:
#   mcp__figma__*, mcp__plugin_figma_figma__*, mcp__figma-assets__*,
#   mcp__figma-desktop__*, mcp__Figma__*
FIGMA_TOOL_RE = re.compile(
    r'^mcp__(?:[A-Za-z0-9_\-]*[Ff]igma[A-Za-z0-9_\-]*)__'
    r'(get_design_context|get_screenshot|get_metadata|get_variable_defs|get_figjam|'
    r'figma_build_registry|figma_extract_tokens|figma_extract_fills|'
    r'figma_export_assets|figma_export_assets_unified|figma_list_assets|'
    r'upload_assets|use_figma|generate_figma_design|create_design_system_rules)'
)

# Explicit bypass marker: a .swift path containing _NoFigma_ anywhere in
# transcript (matches the bypass docs printed by figma-to-swiftui-stop-gate.sh).
NOFIGMA_RE = re.compile(r'_NoFigma_[A-Za-z0-9_\-]*\.swift')

# Detect .swift Write/Edit in assistant tool_use inputs — real UI work signal.
SWIFT_PATH_RE = re.compile(r'\.swift\b')

state = {
    "url_in_user_text": False,
    "figma_tool_invoked": False,
    "swift_file_touched": False,
    "nofigma_marker": False,
}

def scan_for_marker(text):
    if text and NOFIGMA_RE.search(text):
        state["nofigma_marker"] = True

try:
    with open(TRANSCRIPT_PATH) as f:
        for line in f:
            try:
                entry = json.loads(line)
            except Exception:
                continue
            msg = entry.get("message") or {}
            role = msg.get("role")
            content = msg.get("content")
            if not content:
                continue
            blocks = content if isinstance(content, list) else [{"type": "text", "text": content}]
            for block in blocks:
                if not isinstance(block, dict):
                    continue
                btype = block.get("type")
                if btype == "text":
                    text = block.get("text", "") or ""
                    scan_for_marker(text)
                    if role == "user":
                        stripped = SYSTEM_REMINDER_RE.sub('', text)
                        stripped = COMMAND_NAME_RE.sub('', stripped)
                        if URL_RE.search(stripped):
                            state["url_in_user_text"] = True
                elif btype == "tool_use":
                    name = block.get("name", "") or ""
                    if FIGMA_TOOL_RE.match(name):
                        state["figma_tool_invoked"] = True
                    inp = block.get("input")
                    if isinstance(inp, dict):
                        inp_str = json.dumps(inp)
                        scan_for_marker(inp_str)
                        if name in ("Write", "Edit", "NotebookEdit"):
                            fp = inp.get("file_path", "")
                            if isinstance(fp, str) and SWIFT_PATH_RE.search(fp):
                                state["swift_file_touched"] = True
                elif btype == "tool_result":
                    tc = block.get("content")
                    if isinstance(tc, str):
                        scan_for_marker(tc)
                    elif isinstance(tc, list):
                        for sub in tc:
                            if isinstance(sub, dict) and sub.get("type") == "text":
                                scan_for_marker(sub.get("text", "") or "")
except (FileNotFoundError, PermissionError):
    pass

# Decision tree:
#   1. Explicit _NoFigma_ marker in any transcript block → bypass (matches
#      the docs printed by figma-to-swiftui-stop-gate.sh).
#   2. No real Figma URL in user text → not a figma task at all.
#   3. URL pasted but ZERO actual UI work happened in this session
#      (no Figma MCP tool invocation AND no .swift file Write/Edit) →
#      planning / review / discussion only, bypass to avoid false positives
#      on every Stop in a session that just references the URL.
#   4. URL + (MCP call OR .swift write) → real figma implementation task,
#      enforce Phase A/B/C gates.
if state["nofigma_marker"]:
    print("no")
    sys.exit(0)
if not state["url_in_user_text"]:
    print("no")
    sys.exit(0)
if not state["figma_tool_invoked"] and not state["swift_file_touched"]:
    print("no")
    sys.exit(0)
print("yes")
PY
  )
  if [ "$RESULT" = "yes" ]; then
    echo "yes"
    exit 0
  fi
fi

echo "no"
exit 0
