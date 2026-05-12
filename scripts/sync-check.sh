#!/usr/bin/env bash
# sync-check.sh — verify every script in scripts/ obeys the 4-position
# cross-file sync rule documented in CLAUDE.md "Khi sửa script".
#
# Anti-orphan enforcement: catches the bug class that bit ikxcodegen-wrap.sh
# + xcodeproj-add-files.sh (added in commits, never wired into install.sh /
# doctor.sh, sat unreachable for weeks).
#
# Four positions (per CLAUDE.md):
#   (a) install.sh — SCRIPTS_SRC glob includes the script
#   (b) doctor.sh §7 — first list under $SCRIPTS_DIR loop
#   (c) doctor.sh §7 — second list under $INSTALLED_SCRIPTS_DIR loop
#   (d) doctor.sh §9 — drift glob includes the script
#   (e) Referenced in ≥1 SKILL.md / references/*.md (anti-orphan)
#
# Meta scripts (install.sh, doctor.sh, bootstrap.sh, sync-check.sh) are
# exempt — they ARE the wiring, not the wired.
#
# Usage:
#   scripts/sync-check.sh                  # verify everything
#   scripts/sync-check.sh --quiet           # only print FAILs
#   scripts/sync-check.sh --script <name>   # check single script
#
# Exit codes:
#   0 — all scripts properly wired
#   1 — one or more gaps found
#  64 — bad usage

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_DIR="$REPO_ROOT/scripts"
HOOKS_DIR="$SCRIPTS_DIR/hooks"

QUIET=0
SINGLE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --script) SINGLE="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

# Meta scripts that ARE the sync wiring — exempt from check
META_SCRIPTS=("install.sh" "doctor.sh" "bootstrap.sh" "sync-check.sh")

is_meta() {
  local s="$1"
  for m in "${META_SCRIPTS[@]}"; do
    [ "$s" = "$m" ] && return 0
  done
  return 1
}

# Collect target scripts
if [ -n "$SINGLE" ]; then
  TARGETS=("$SINGLE")
else
  TARGETS=()
  while IFS= read -r p; do
    name=$(basename "$p")
    is_meta "$name" && continue
    TARGETS+=("$name")
  done < <(find "$SCRIPTS_DIR" -maxdepth 1 -name "*.sh" -type f | sort)
fi

FAIL_COUNT=0
PASS_COUNT=0

check_position_a() {
  # install.sh SCRIPTS_SRC glob
  local name="$1"
  local prefix="${name%%-*}"  # e.g. "c5-foo" → "c5", "preflight-bar" → "preflight"
  # Globs in install.sh: b0a-*.sh, b0b-*.sh, c1-*.sh, c3-*.sh, c5-*.sh,
  # c6-*.sh, c7-*.sh, preflight-*.sh — OR explicit script names.
  if grep -qE "SCRIPTS_SRC.*${prefix}-\*\.sh|SCRIPTS_SRC.*${prefix}-" "$REPO_ROOT/scripts/install.sh" 2>/dev/null; then
    return 0
  fi
  if grep -qF "$name" "$REPO_ROOT/scripts/install.sh" 2>/dev/null; then
    return 0
  fi
  return 1
}

check_position_b() {
  # doctor.sh §7 first list — extract first `for script in ... ; do` block
  local name="$1"
  local doctor="$REPO_ROOT/scripts/doctor.sh"
  # Pluck the FIRST `for script in` block via awk state machine
  local block
  block=$(awk '
    /^for script in/ { capturing=1 }
    capturing { print; if (/;[[:space:]]*do$/) { exit } }
  ' "$doctor")
  echo "$block" | grep -qF "$name" && return 0
  return 1
}

check_position_c() {
  # doctor.sh §7 second list — the `for script in` block AFTER first one
  local name="$1"
  local doctor="$REPO_ROOT/scripts/doctor.sh"
  local block
  block=$(awk '
    /^for script in/ { count++; if (count == 1) skip=1; else skip=0; next }
    skip && /;[[:space:]]*do$/ { skip=0; next }
    /  for script in/ { capturing=1 }
    capturing { print; if (/;[[:space:]]*do$/) { exit } }
  ' "$doctor")
  echo "$block" | grep -qF "$name" && return 0
  return 1
}

check_position_d() {
  # doctor.sh §9 drift glob — match either by script-prefix glob or by exact name
  local name="$1"
  local prefix="${name%%-*}"
  local doctor="$REPO_ROOT/scripts/doctor.sh"
  # Locate the §9 `for src in` block (different from §7's `for script in`)
  local block
  block=$(awk '
    /^[[:space:]]*for src in/ { capturing=1 }
    capturing { print; if (/;[[:space:]]*do$/) { exit } }
  ' "$doctor")
  echo "$block" | grep -qE "SCRIPTS_REPO.*${prefix}-\*\.sh|SCRIPTS_REPO.*${prefix}-|SCRIPTS_REPO.*${name}" && return 0
  return 1
}

check_position_e() {
  # Mentioned in ≥1 doc (SKILL.md or references/*.md)
  local name="$1"
  grep -rlF "$name" \
    "$REPO_ROOT/figma-to-swiftui/" \
    "$REPO_ROOT/figma-flow-to-swiftui-feature/" \
    "$REPO_ROOT/docs/" \
    "$REPO_ROOT/CLAUDE.md" 2>/dev/null | head -1 | grep -q . && return 0
  return 1
}

report_script() {
  local name="$1"
  local gaps=()
  check_position_a "$name" || gaps+=("a:install.sh glob")
  check_position_b "$name" || gaps+=("b:doctor.sh §7 first list")
  check_position_c "$name" || gaps+=("c:doctor.sh §7 second list")
  check_position_d "$name" || gaps+=("d:doctor.sh §9 drift glob")
  check_position_e "$name" || gaps+=("e:reference-doc mention")

  if [ ${#gaps[@]} -eq 0 ]; then
    [ $QUIET -eq 0 ] && echo "✓ $name"
    PASS_COUNT=$((PASS_COUNT+1))
  else
    echo "✘ $name missing: ${gaps[*]}"
    FAIL_COUNT=$((FAIL_COUNT+1))
  fi
}

echo "sync-check: scanning $(echo "${#TARGETS[@]}") scripts..."
for s in "${TARGETS[@]}"; do
  report_script "$s"
done

# Also check hooks — every hook must be in install.sh GATES list + doctor.sh
# §8 EXPECTED_HOOKS array.
echo
echo "sync-check: scanning hooks..."
HOOK_FAIL=0
for hp in "$HOOKS_DIR"/*.sh; do
  hname=$(basename "$hp")
  [ "$hname" = "_figma-task-probe.sh" ] && continue  # internal helper

  if ! grep -qF "$hname" "$REPO_ROOT/scripts/install.sh" 2>/dev/null; then
    echo "✘ hooks/$hname missing from install.sh GATES"
    HOOK_FAIL=$((HOOK_FAIL+1))
  fi
  if ! grep -qF "$hname" "$REPO_ROOT/scripts/doctor.sh" 2>/dev/null; then
    echo "✘ hooks/$hname missing from doctor.sh §8 EXPECTED_HOOKS"
    HOOK_FAIL=$((HOOK_FAIL+1))
  fi
done

echo
TOTAL_FAIL=$((FAIL_COUNT + HOOK_FAIL))
if [ $TOTAL_FAIL -eq 0 ]; then
  echo "GATE: PASS ($PASS_COUNT scripts + $(ls "$HOOKS_DIR"/*.sh 2>/dev/null | wc -l | xargs) hooks all wired)"
  exit 0
else
  echo "GATE: FAIL: $TOTAL_FAIL sync gaps detected"
  echo "Fix: see CLAUDE.md 'Đồng bộ cross-file' checklist."
  exit 1
fi
