#!/usr/bin/env bash
# c3-static-checks.sh — run Pass 3 and Pass 3b in one call.
#
# Replaces the two separate bash blocks in figma-to-swiftui/SKILL.md
# Step C3 (Pass 3 asset substitution + Pass 3b system chrome). Same greps,
# same exit semantics — just consolidated so the agent pays one bash
# startup instead of two, and so re-runs after self-fix loop iterations
# are cheap.
#
# Each section prints its own GATE: PASS / FAIL / REVIEW lines (REVIEW is
# informational, does NOT fail the driver). The driver exits 1 if any
# enforcing check failed.
#
# Usage:
#   c3-static-checks.sh --files "<space-separated swift paths>"
#   c3-static-checks.sh --files-from <file-with-paths-one-per-line>
#
# Exit codes:
#   0 — Pass 3 + 3b all clean
#   1 — at least one enforcing check failed
#  64 — bad usage
#  65 — input file missing or empty file list

set -uo pipefail

FILES=""
FILES_FROM=""

print_usage() {
  cat <<'USAGE' >&2
usage: c3-static-checks.sh
       --files "<space-separated swift paths>"
   or
       --files-from <list-file>   # one path per line

Runs Pass 3 (asset substitution scan) and Pass 3b (system chrome scan) —
same greps as the SKILL.md blocks, consolidated.

Exit 0 if every enforcing check passes (informational REVIEW lines do not
fail). Exit 1 if any FAIL.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --files)      FILES="${2:-}"; shift 2 ;;
    --files-from) FILES_FROM="${2:-}"; shift 2 ;;
    -h|--help)    print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

# Resolve file list.
if [ -n "$FILES_FROM" ]; then
  [ -s "$FILES_FROM" ] || { echo "FAIL: --files-from is empty: $FILES_FROM" >&2; exit 65; }
  # Read each line, skip blanks/comments, validate existence later.
  FILES=$(grep -v '^[[:space:]]*\(#\|$\)' "$FILES_FROM" | tr '\n' ' ')
fi

[ -n "$FILES"  ] || { print_usage; exit 64; }

# Validate every path. A dangling path is a bigger bug than a violation —
# fail loud so the user fixes the manifest, not the agent's grep.
MISSING=""
for f in $FILES; do
  [ -f "$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  echo "FAIL: missing swift file(s):$MISSING" >&2
  exit 65
fi

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

FAIL=0
ok()   { echo "${C_GRN}PASS${C_RST}: $1"; }
bad()  { echo "${C_RED}FAIL${C_RST}: $1"; FAIL=1; }
warn() { echo "${C_YEL}REVIEW${C_RST}: $1"; }

# ──────────────────────────────────────────────────────────────────────────
echo "== Pass 3 — asset substitution =="
# (Only enforcing check; SF Symbol allow-list is enforced by the
# banned-pattern PreToolUse hook, not by this grep — this grep is the
# session-end safety net.)
HITS=$(grep -nE 'Image\(systemName:' $FILES 2>/dev/null || true)
if [ -z "$HITS" ]; then
  ok "no SF Symbol substitution"
else
  bad "SF Symbol used where Figma asset expected:"
  echo "$HITS"
fi

# ──────────────────────────────────────────────────────────────────────────
echo
echo "== Pass 3b — system chrome =="
CHROME=$(grep -nE '"9:41"|Image\(systemName: "(wifi|battery|cellularbars|antenna|dot\.radiowaves)"\)|StatusBar|HomeIndicator|DynamicIsland' $FILES 2>/dev/null || true)
if [ -z "$CHROME" ]; then
  ok "no system-chrome drawing"
else
  bad "system chrome drawn in view (delete — iOS renders it):"
  echo "$CHROME"
fi

# Visual home-indicator lookalike — Capsule()/RoundedRectangle()/Rectangle
# at width≈134 and height≈5 is the home indicator that iOS already draws.
HOME_IND=$(grep -nE '(Capsule|RoundedRectangle|Rectangle)\(\)[^/]*\.frame\([^)]*width:[[:space:]]*13[0-9]' $FILES 2>/dev/null || true)
if [ -z "$HOME_IND" ]; then
  ok "no home-indicator lookalike"
else
  warn "possible home-indicator redraw (verify visually):"
  echo "$HOME_IND"
fi

# ──────────────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  echo "${C_GRN}GATE: PASS${C_RST} (Pass 3 + 3b)"
  exit 0
else
  echo "${C_RED}GATE: FAIL${C_RST} (Pass 3 + 3b) — DO NOT proceed to C4"
  exit 1
fi
