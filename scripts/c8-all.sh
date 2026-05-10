#!/usr/bin/env bash
# c8-all.sh — run all six c8-* gates in parallel and aggregate the result.
#
# Replaces the sequential Pass 5 block in figma-to-swiftui/SKILL.md Step C3
# Pass 5 — same six checks, same exit semantics, just parallelized so they
# don't pay six bash-startup hits in series. The individual c8-* scripts are
# kept and remain callable on their own; this driver only wraps them.
#
# Each sub-gate prints its own GATE: PASS / FAIL / SKIP line. The driver
# collects them, prints them in deterministic order (so logs diff cleanly
# between runs), and exits non-zero if any sub-gate exited non-zero EXCEPT
# for c8-weak-self.sh which is informational (warn-only) per SKILL.md.
#
# Usage:
#   c8-all.sh --src <swift-src-root> --conventions <c1-conventions.json>
#
# Exit codes:
#   0 — every enforcing gate passed (or skipped)
#   1 — at least one enforcing gate failed
#  64 — bad usage
#  65 — src dir missing

set -uo pipefail

SRC=""
CONVENTIONS=""

print_usage() {
  cat <<'USAGE' >&2
usage: c8-all.sh --src <swift-src-root> --conventions <c1-conventions.json>

Runs Pass 5 — c8-conventions-gate / c8-vm-pattern / c8-func-length /
c8-iknavigation / c8-ikfont / c8-weak-self — in parallel. Output is
deterministic (sub-gate output is buffered to a temp file, then printed in
fixed order). Same enforcement semantics as the sequential block in
figma-to-swiftui/SKILL.md Step C3 Pass 5.

c8-weak-self is informational; its exit code does NOT fail the driver.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)         SRC="${2:-}"; shift 2 ;;
    --conventions) CONVENTIONS="${2:-}"; shift 2 ;;
    -h|--help)     print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$SRC" ] || { print_usage; exit 64; }
[ -d "$SRC" ] || { echo "FAIL: src is not a directory: $SRC" >&2; exit 65; }

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Sub-gates the driver knows about. Tuple shape:
#   <slug> <relative-script> <enforcing|informational> <wants-conventions>
# Order here is the print order, not the run order — runs are parallel.
GATES=(
  "conventions:c8-conventions-gate.sh:enforcing:yes"
  "vm-pattern:c8-vm-pattern.sh:enforcing:no"
  "func-length:c8-func-length.sh:enforcing:no"
  "iknavigation:c8-iknavigation.sh:enforcing:yes"
  "ikfont:c8-ikfont.sh:enforcing:yes"
  "ikpopup:c8-ikpopup.sh:enforcing:yes"
  "ikfeedback:c8-ikfeedback.sh:enforcing:yes"
  "iktracking:c8-iktracking.sh:enforcing:yes"
  "iklocalized:c8-iklocalized.sh:enforcing:yes"
  "weak-self:c8-weak-self.sh:informational:no"
)

# Verify every sub-gate is on disk + executable before kicking off parallel
# runs. A missing sub-gate is a bigger problem than a violation — fail loud.
MISSING=""
for entry in "${GATES[@]}"; do
  IFS=":" read -r _slug script _enforce _wants <<< "$entry"
  path="$SCRIPT_DIR/$script"
  [ -x "$path" ] || MISSING="$MISSING $script"
done
if [ -n "$MISSING" ]; then
  echo "${C_RED}FAIL${C_RST}: missing or non-executable c8-* sub-gate(s):${MISSING}" >&2
  echo "${C_DIM}fix: re-run scripts/install.sh${C_RST}" >&2
  exit 1
fi

WORK=$(mktemp -d -t c8-all.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Kick off every sub-gate in parallel. Each writes to a per-slug stdout file
# and stores its exit code in a per-slug status file.
PIDS=()
for entry in "${GATES[@]}"; do
  IFS=":" read -r slug script _enforce wants_conv <<< "$entry"
  outfile="$WORK/${slug}.out"
  statusfile="$WORK/${slug}.status"

  args=(--src "$SRC")
  if [ "$wants_conv" = "yes" ] && [ -n "$CONVENTIONS" ]; then
    args+=(--conventions "$CONVENTIONS")
  fi

  (
    "$SCRIPT_DIR/$script" "${args[@]}" >"$outfile" 2>&1
    echo $? >"$statusfile"
  ) &
  PIDS+=($!)
done

# Wait for everyone. `wait` with no args waits for ALL background jobs.
wait "${PIDS[@]}" 2>/dev/null || true

# Print sub-gate output in declared order so diffs across runs are stable.
FAIL=0
for entry in "${GATES[@]}"; do
  IFS=":" read -r slug _script enforce _wants <<< "$entry"
  outfile="$WORK/${slug}.out"
  statusfile="$WORK/${slug}.status"
  status=$(cat "$statusfile" 2>/dev/null || echo "?")

  echo "── ${slug} (status: ${status}, ${enforce}) ──"
  if [ -s "$outfile" ]; then
    cat "$outfile"
  else
    echo "${C_DIM}(no output)${C_RST}"
  fi
  echo

  if [ "$enforce" = "enforcing" ] && [ "$status" != "0" ]; then
    FAIL=1
  fi
done

if [ "$FAIL" -eq 0 ]; then
  echo "${C_GRN}GATE: PASS${C_RST} (Pass 5 — coding conventions, all enforcing gates clean)"
  exit 0
else
  echo "${C_RED}GATE: FAIL${C_RST} (Pass 5 — see sub-gate output above)"
  exit 1
fi
