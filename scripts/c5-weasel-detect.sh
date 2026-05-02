#!/usr/bin/env bash
# c5-weasel-detect.sh — flag PASS rows in c5-visual-diff.md that hedge.
#
# Visual diffs fail when the agent writes "approximately matches" / "looks
# similar" in a PASS row. That phrasing inflates the PASS count and hides
# real differences from Gate C5 + the self-fix loop. Decisive verdicts only.
#
# Single source of truth for the banned list — c5-coverage-check.sh shells
# out to this script, so adding or removing a term here propagates.
#
# Usage:
#   c5-weasel-detect.sh --report <path-to-c5-visual-diff.md>
#
# Exit codes:
#   0 — clean (no weasel words in PASS rows)
#   1 — at least one PASS row contains a banned term
#   64 — bad usage
#   65 — report not found

set -euo pipefail

REPORT=""

# Single source of truth. Everything matched case-insensitively as a substring.
WEASEL_TERMS=(
  "approximately"
  "roughly"
  "looks similar"
  "close enough"
  "minor difference"
  "slightly"
  "nearly"
  "almost identical"
)

print_usage() {
  cat <<'USAGE' >&2
usage: c5-weasel-detect.sh --report <path-to-c5-visual-diff.md>

Greps PASS rows in a C5 visual-diff markdown table for hedging language.
Banned terms (case-insensitive): approximately, roughly, looks similar,
close enough, minor difference, slightly, nearly, almost identical.

Hits are printed as `file:line: <term>`. Exit 1 if any hit, 0 otherwise.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --report)  REPORT="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$REPORT" ] || { print_usage; exit 64; }
[ -f "$REPORT" ] || { echo "FAIL: report not found: $REPORT" >&2; exit 65; }

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_RST=""
fi

HITS=0

# A "PASS row" is any markdown table row whose pipe-delimited cells contain
# the literal token PASS surrounded by whitespace/pipes. Excludes header
# separators (`|---|---|`) automatically because they have no PASS token.
while IFS= read -r line_info; do
  ln="${line_info%%:*}"
  content="${line_info#*:}"
  for term in "${WEASEL_TERMS[@]}"; do
    # Case-insensitive substring match.
    if printf '%s' "$content" | grep -qiF -- "$term"; then
      echo "${REPORT}:${ln}: ${C_RED}${term}${C_RST}"
      HITS=$((HITS+1))
    fi
  done
done < <(grep -nE '^\|.*[[:space:]\|]PASS[[:space:]\|]' "$REPORT" || true)

if [ "$HITS" -gt 0 ]; then
  echo "FAIL: $HITS weasel-word hit(s) in PASS rows"
  exit 1
fi

echo "${C_GRN}PASS${C_RST}: no weasel words in PASS rows of $REPORT"
exit 0
