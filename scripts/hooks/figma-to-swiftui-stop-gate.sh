#!/usr/bin/env bash
# Stop hook — block session termination when figma-to-swiftui's C5 Done-Gate
# is unsatisfied (figma-to-swiftui SKILL.md Key Principle #12).
#
# For every .figma-cache/<nodeId>/manifest.json found under cwd (walks up 5 levels),
# requires one of:
#   - manifest.verification.c5.gate == "PASS"
#   - manifest.verification.c5.skipped IN ("no_project", "simctl_error", "ci_environment")
#
# Only screens with phaseB == "done" are gated — pre-Phase-B caches are
# in-progress work, not finished tasks.
#
# Exit codes:
#   0 — allow stop
#   2 — block stop (stderr shown to agent)

set -uo pipefail

CACHE_ROOT=""
D="$PWD"
for _ in 1 2 3 4 5 6; do
  if [ -d "$D/.figma-cache" ]; then
    CACHE_ROOT="$D/.figma-cache"
    break
  fi
  PARENT=$(dirname "$D")
  [ "$PARENT" = "$D" ] && break
  D="$PARENT"
done

# Not a figma task → allow stop.
[ -z "$CACHE_ROOT" ] && exit 0

shopt -s nullglob
SCREEN_DIRS=( "$CACHE_ROOT"/*/ )
shopt -u nullglob

[ ${#SCREEN_DIRS[@]} -eq 0 ] && exit 0

VIOLATIONS=""

for DIR in "${SCREEN_DIRS[@]}"; do
  BASE=$(basename "$DIR")
  [ "$BASE" = "_shared" ] && continue

  MANIFEST="$DIR/manifest.json"
  [ ! -f "$MANIFEST" ] && continue

  # Only enforce Done-Gate once Phase B has actually completed.
  PHASE_B=$(jq -r '.phaseB // empty' "$MANIFEST" 2>/dev/null)
  [ "$PHASE_B" != "done" ] && continue

  GATE=$(jq -r '.verification.c5.gate // empty' "$MANIFEST" 2>/dev/null)
  SKIPPED=$(jq -r '.verification.c5.skipped // empty' "$MANIFEST" 2>/dev/null)

  case "$GATE" in
    PASS) continue ;;
  esac
  case "$SKIPPED" in
    no_project|simctl_error|ci_environment) continue ;;
  esac

  VIOLATIONS+="  $BASE/  (gate=${GATE:-unset}, skipped=${SKIPPED:-unset})\n"
done

[ -z "$VIOLATIONS" ] && exit 0

{
  echo "Done-Gate violated (figma-to-swiftui Key Principle #12)."
  echo ""
  echo "Phase B is complete but C5 (build + simulator + visual diff) has not been"
  echo "satisfied for these screens:"
  printf "%b" "$VIOLATIONS"
  echo ""
  echo "A task is NOT complete until each screen has either:"
  echo "  - manifest.verification.c5.gate == \"PASS\", OR"
  echo "  - manifest.verification.c5.skipped set to one of:"
  echo "      no_project | simctl_error | ci_environment   (system-detected only)"
  echo ""
  echo "Run Step C5 from figma-to-swiftui SKILL.md:"
  echo "  build → simctl boot → install → launch → screenshot → write c5-visual-diff.md"
  echo "  → run Gate C5"
  echo ""
  echo "User phrases like \"skip C5\" / \"bỏ qua C5\" / \"không cần build\" are NOT"
  echo "honored — only the three system reasons above bypass this gate."
} >&2
exit 2
