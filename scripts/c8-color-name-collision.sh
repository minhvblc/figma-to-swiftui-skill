#!/usr/bin/env bash
# c8-color-name-collision.sh — scan Assets.xcassets for colorset names that
# shadow SwiftUI's built-in Color symbols. Produces "primary"/"secondary"
# warnings on every build if violated.
#
# Fix-spec C from SKILL_IMPROVEMENT_PLAN.md. Bible Widgets session shipped
# `primary` + `secondary` colorsets that conflicted with `Color.primary` /
# `Color.secondary` — 2 warnings every build until renamed to `appPrimary`
# / `appSecondary`.
#
# Banned colorset names (case-insensitive) — SwiftUI Color built-ins:
#   primary, secondary, accent (system),
#   red, green, blue, gray, orange, pink, purple, yellow,
#   black, white, clear, indigo, mint, teal, cyan, brown
#
# Use case: run as part of c8-all.sh AND wired into PostToolUse hook.
#
# Usage:
#   scripts/c8-color-name-collision.sh --src <project-folder>
#
# Exit codes:
#   0 — no collisions
#   1 — one or more colorsets shadow SwiftUI built-ins
#  64 — bad usage

set -uo pipefail

SRC=""

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$SRC" ] || { echo "usage: c8-color-name-collision.sh --src <folder>" >&2; exit 64; }
[ -d "$SRC" ] || { echo "FAIL: $SRC not a directory" >&2; exit 64; }

# Banned names (lowercase, exact match)
BANNED=(
  primary secondary accent
  red green blue gray orange pink purple yellow
  black white clear indigo mint teal cyan brown
)

FAIL_COUNT=0

# Scan all .colorset folders under .xcassets
while IFS= read -r colorset_dir; do
  name=$(basename "$colorset_dir" .colorset)
  name_lower=$(echo "$name" | tr '[:upper:]' '[:lower:]')

  for banned in "${BANNED[@]}"; do
    if [ "$name_lower" = "$banned" ]; then
      echo "✘ $colorset_dir — name '$name' shadows SwiftUI Color.$banned"
      echo "  Fix: rename to 'app${name^}' (e.g. appPrimary, appSecondary)"
      FAIL_COUNT=$((FAIL_COUNT+1))
      break
    fi
  done
done < <(find "$SRC" -type d -name "*.colorset" 2>/dev/null)

if [ $FAIL_COUNT -eq 0 ]; then
  echo "GATE: PASS (c8-color-name-collision)"
  exit 0
else
  echo "GATE: FAIL: $FAIL_COUNT colorset(s) shadow SwiftUI built-in Color names"
  echo "Rationale: SwiftUI ships built-ins 'Color.primary', 'Color.secondary', etc."
  echo "Same-named colorsets produce 'conflicting Color symbol' warnings every build"
  echo "and silently lose to the built-in when used as Color(\"name\")."
  echo "See: figma-to-swiftui/references/swiftui-pro/colors.md (banned names section)"
  exit 1
fi
