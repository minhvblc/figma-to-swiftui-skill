#!/usr/bin/env bash
# PreToolUse hook for Bash
#
# Blocks `vanilla-scaffold.sh` invocations when mode-detect classified the
# project as `greenfield-ikame` AND the user has not explicitly opted out
# (mode.json.userOptOutIkame != true).
#
# Closes the failure mode: agent runs `mode-detect.sh` → gets
# `greenfield-ikame`, then ignores the result and runs `vanilla-scaffold`
# anyway. The Ikame fleet's `ikxcodegen` template wires Podfile + xcconfig +
# IKCoreApp/IKNavigation conventions that vanilla cannot reproduce; falling
# through to vanilla silently produces a project the team cannot maintain.
#
# Allowed verbatim:
#   - vanilla-scaffold.sh when mode != greenfield-ikame (vanilla, brownfield-*)
#   - vanilla-scaffold.sh when mode == greenfield-ikame AND
#     mode.json.userOptOutIkame == true (explicit opt-out persisted by
#     `mode-detect.sh --opt-out-ikame --write-cache`)
#   - Anything that isn't `vanilla-scaffold.sh` (this gate is single-purpose)
#
# Detection scope:
#   - Only enforces during a figma-to-swiftui session (transcript probe via
#     _figma-task-probe.sh). Outside figma sessions, vanilla-scaffold runs
#     verbatim.
#
# Exit codes:
#   0 — allow
#   2 — block (stderr shown to Claude)

set -uo pipefail

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$COMMAND" ] && exit 0

# ── 1. Detect vanilla-scaffold.sh in the command ──────────────────────────────
case "$COMMAND" in
  *vanilla-scaffold.sh*) ;;
  *) exit 0 ;;
esac

# ── 2. Session scope — only enforce during a figma-to-swiftui session ────────
PROBE="$(dirname "$0")/_figma-task-probe.sh"
IS_FIGMA="no"
if [ -x "$PROBE" ]; then
  IS_FIGMA=$(printf '%s' "$INPUT" | "$PROBE" 2>/dev/null || echo "no")
fi
[ "$IS_FIGMA" != "yes" ] && exit 0

# ── 3. Resolve project folder from command args ───────────────────────────────
# Look for the first positional arg after `vanilla-scaffold.sh` that doesn't
# start with `-`. Fall back to $PWD when no positional arg is parseable.
PROJECT_ARG=$(printf '%s' "$COMMAND" | awk '
  {
    pos = match($0, /vanilla-scaffold\.sh[[:space:]]+/)
    if (pos == 0) next
    rest = substr($0, RSTART + RLENGTH)
    n = split(rest, parts, /[[:space:]]+/)
    for (i = 1; i <= n; i++) {
      if (parts[i] !~ /^-/ && parts[i] != "") { print parts[i]; exit }
    }
  }
')

PROJECT_DIR=""
if [ -n "$PROJECT_ARG" ] && [ -d "$PROJECT_ARG" ]; then
  PROJECT_DIR="$PROJECT_ARG"
else
  PROJECT_DIR="$PWD"
fi

# ── 4. Locate mode.json by walking up from PROJECT_DIR ───────────────────────
MODE_JSON=""
DIR="$PROJECT_DIR"
while [ -n "$DIR" ] && [ "$DIR" != "/" ]; do
  if [ -s "$DIR/.figma-cache/_shared/mode.json" ]; then
    MODE_JSON="$DIR/.figma-cache/_shared/mode.json"
    break
  fi
  DIR=$(dirname "$DIR")
done

# No mode.json on disk → mode-gate.sh already blocks Swift writes until
# mode-detect runs. This gate only enforces post-classification; pre-detect,
# vanilla-scaffold may legitimately be the agent setting up the project.
# Fail-open here.
[ -z "$MODE_JSON" ] && exit 0

MODE=$(jq -r '.mode // empty' "$MODE_JSON" 2>/dev/null)
OPT_OUT=$(jq -r '.userOptOutIkame // false' "$MODE_JSON" 2>/dev/null)

# ── 5. Apply rule ─────────────────────────────────────────────────────────────
if [ "$MODE" = "greenfield-ikame" ] && [ "$OPT_OUT" != "true" ]; then
  {
    echo "BLOCKED: project is greenfield-ikame — vanilla-scaffold.sh is not the right tool."
    echo ""
    echo "mode.json:       $MODE_JSON"
    echo "mode:            $MODE"
    echo "userOptOutIkame: $OPT_OUT (must be true to use vanilla path here)"
    echo ""
    echo "ikxcodegen is on PATH, which means this machine is on the Ikame fleet."
    echo "The MANDATORY scaffold is:"
    echo ""
    echo "  scripts/ikxcodegen-scaffold.sh <ProjectName>"
    echo ""
    echo "If you genuinely need vanilla here (rare — e.g. building a non-Ikame"
    echo "app on an Ikame-fleet machine), surface the choice to the user first,"
    echo "then re-run mode-detect with --opt-out-ikame to persist the opt-out:"
    echo ""
    echo "  scripts/mode-detect.sh <projectFolder> --write-cache --opt-out-ikame"
    echo ""
    echo "After mode.json.userOptOutIkame == true, vanilla-scaffold.sh runs"
    echo "verbatim."
  } >&2
  exit 2
fi

exit 0
