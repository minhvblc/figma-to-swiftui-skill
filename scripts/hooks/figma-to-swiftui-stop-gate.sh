#!/usr/bin/env bash
# Stop hook — block session termination when figma-to-swiftui's Done-Gate is unsatisfied.
#
# Enforces the full set of completion gates per figma-to-swiftui SKILL.md
# Key Principle #12 + Mandatory Output Checklist:
#
#   For every .figma-cache/<nodeId>/ found under cwd (walks up 5 levels) where
#   Phase A has been started (manifest.json with phaseA: "done"):
#
#     1. manifest.phaseB == "done" AND rows[] non-empty
#        (Phase B was completed — assets exported)
#     2. C6 — c6-asset-completeness.sh passes against (registry, xcassets, src)
#        (every tagged asset landed; no banned Image(systemName:))
#     3. C7 — c7-no-system-chrome.sh passes against src
#        (no status-bar / home-indicator redraws)
#     4. C5 — manifest.verification.c5.gate == "PASS"
#        OR manifest.verification.c5.skipped IN
#           (no_project, simctl_error, ci_environment, no_entry_path)
#        AND c5-coverage-check.sh passes (when not skipped)
#
# Removing the previous "phaseB == done" precondition closes the lock-out
# escape: prior versions allowed stop when Phase B was simply skipped.
# Now: if Phase A ran, the agent must complete Phase B + verification or
# explicitly abort with a system skip reason.
#
# Exit codes:
#   0 — allow stop
#   2 — block stop (stderr shown to agent)

set -uo pipefail

# Locate cache root (walk up 6 levels).
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

PROJECT_ROOT=$(dirname "$CACHE_ROOT")

# Locate scripts dir (sibling to hooks dir).
SCRIPT_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -d "$SCRIPT_DIR" ] || SCRIPT_DIR="$HOME/.claude/hooks/.."

C6_SCRIPT="$SCRIPT_DIR/c6-asset-completeness.sh"
C7_SCRIPT="$SCRIPT_DIR/c7-no-system-chrome.sh"
C5_COV_SCRIPT="$SCRIPT_DIR/c5-coverage-check.sh"

# Walk fall-back paths if the relative resolution missed (the user may have
# installed scripts to ~/.claude/hooks/ + a separate scripts/ next to it).
for cand in \
  "$HOME/.claude/scripts/c6-asset-completeness.sh" \
  "$HOME/.claude/c6-asset-completeness.sh" \
  "$PROJECT_ROOT/scripts/c6-asset-completeness.sh"; do
  [ -x "$cand" ] && C6_SCRIPT="$cand" && break
done
for cand in \
  "$HOME/.claude/scripts/c7-no-system-chrome.sh" \
  "$HOME/.claude/c7-no-system-chrome.sh" \
  "$PROJECT_ROOT/scripts/c7-no-system-chrome.sh"; do
  [ -x "$cand" ] && C7_SCRIPT="$cand" && break
done
for cand in \
  "$HOME/.claude/scripts/c5-coverage-check.sh" \
  "$HOME/.claude/c5-coverage-check.sh" \
  "$PROJECT_ROOT/scripts/c5-coverage-check.sh"; do
  [ -x "$cand" ] && C5_COV_SCRIPT="$cand" && break
done

shopt -s nullglob
SCREEN_DIRS=( "$CACHE_ROOT"/*/ )
shopt -u nullglob

[ ${#SCREEN_DIRS[@]} -eq 0 ] && exit 0

VIOLATIONS=""

# Heuristic: locate the project's Swift sources for C6/C7 checks. Look for
# the first dir under PROJECT_ROOT (max 3 levels) that contains *.swift, OR
# fall back to PROJECT_ROOT itself.
SRC_ROOT=""
SRC_CANDIDATES=$(find "$PROJECT_ROOT" -maxdepth 3 -type f -name '*.swift' 2>/dev/null | head -1)
if [ -n "$SRC_CANDIDATES" ]; then
  SRC_ROOT=$(dirname "$SRC_CANDIDATES")
fi
[ -z "$SRC_ROOT" ] && SRC_ROOT="$PROJECT_ROOT"

# Locate xcassets — first hit under PROJECT_ROOT (max 4 levels).
XCASSETS=$(find "$PROJECT_ROOT" -maxdepth 4 -type d -name '*.xcassets' 2>/dev/null | head -1)

for DIR in "${SCREEN_DIRS[@]}"; do
  BASE=$(basename "$DIR")
  [ "$BASE" = "_shared" ] && continue

  MANIFEST="$DIR/manifest.json"
  [ ! -f "$MANIFEST" ] && continue

  # Only enforce when Phase A actually ran. Pre-Phase-A caches are work-in-progress.
  PHASE_A=$(jq -r '.phaseA // empty' "$MANIFEST" 2>/dev/null)
  [ "$PHASE_A" != "done" ] && continue

  PROBLEMS=""

  # ── 1. Phase B completeness ──────────────────────────────────────────────────
  PHASE_B=$(jq -r '.phaseB // empty' "$MANIFEST" 2>/dev/null)
  ROWS_LEN=$(jq -r '(.rows // []) | length' "$MANIFEST" 2>/dev/null || echo 0)
  if [ "$PHASE_B" != "done" ]; then
    PROBLEMS+="    - phaseB != \"done\" (run figma_export_assets_unified for this screen)\n"
  fi
  if [ "${ROWS_LEN:-0}" -lt 1 ]; then
    PROBLEMS+="    - rows[] empty (no assets exported — Figma icons will be missing)\n"
  fi

  # ── 2. C5 — Done-Gate ────────────────────────────────────────────────────────
  GATE=$(jq -r '.verification.c5.gate // empty' "$MANIFEST" 2>/dev/null)
  SKIPPED=$(jq -r '.verification.c5.skipped // empty' "$MANIFEST" 2>/dev/null)
  C5_OK=0
  case "$GATE" in PASS) C5_OK=1 ;; esac
  case "$SKIPPED" in
    no_project|simctl_error|ci_environment|no_entry_path) C5_OK=1 ;;
  esac
  if [ "$C5_OK" = "0" ]; then
    PROBLEMS+="    - C5 not satisfied (gate=${GATE:-unset}, skipped=${SKIPPED:-unset})\n"
  fi

  # ── 3. C5.6 coverage check (only when not skipped at system level) ───────────
  if [ "$C5_OK" = "1" ] && [ -z "$SKIPPED" ] && [ -x "$C5_COV_SCRIPT" ]; then
    if ! "$C5_COV_SCRIPT" --cache "$DIR" >/dev/null 2>&1; then
      PROBLEMS+="    - C5.6 coverage failing (run: $C5_COV_SCRIPT --cache $DIR)\n"
    fi
  fi

  if [ -n "$PROBLEMS" ]; then
    VIOLATIONS+="  $BASE/\n${PROBLEMS}"
  fi
done

# ── 4. Project-wide C6 + C7 (run once, not per-screen) ─────────────────────────
PROJECT_PROBLEMS=""

# Need at least one screen with a registry to run C6.
FIRST_REG=""
for DIR in "${SCREEN_DIRS[@]}"; do
  BASE=$(basename "$DIR")
  [ "$BASE" = "_shared" ] && continue
  if [ -s "$DIR/registry.json" ]; then
    FIRST_REG="$DIR/registry.json"
    break
  fi
done

if [ -x "$C6_SCRIPT" ] && [ -n "$FIRST_REG" ] && [ -n "$XCASSETS" ] && [ -d "$XCASSETS" ]; then
  if ! "$C6_SCRIPT" --registry "$FIRST_REG" --xcassets "$XCASSETS" --src "$SRC_ROOT" >/dev/null 2>&1; then
    PROJECT_PROBLEMS+="  - C6 (asset completeness) failing — run:\n"
    PROJECT_PROBLEMS+="      $C6_SCRIPT --registry $FIRST_REG --xcassets $XCASSETS --src $SRC_ROOT\n"
  fi
fi

if [ -x "$C7_SCRIPT" ] && [ -d "$SRC_ROOT" ]; then
  if ! "$C7_SCRIPT" --src "$SRC_ROOT" >/dev/null 2>&1; then
    PROJECT_PROBLEMS+="  - C7 (no system chrome) failing — run:\n"
    PROJECT_PROBLEMS+="      $C7_SCRIPT --src $SRC_ROOT\n"
  fi
fi

# Done — assemble report.
if [ -z "$VIOLATIONS" ] && [ -z "$PROJECT_PROBLEMS" ]; then
  exit 0
fi

{
  echo "Done-Gate violated (figma-to-swiftui Key Principle #12 + Mandatory Output Checklist)."
  echo ""
  if [ -n "$VIOLATIONS" ]; then
    echo "Per-screen issues:"
    printf "%b" "$VIOLATIONS"
    echo ""
  fi
  if [ -n "$PROJECT_PROBLEMS" ]; then
    echo "Project-wide issues:"
    printf "%b" "$PROJECT_PROBLEMS"
    echo ""
  fi
  echo "A task is NOT complete until each screen has:"
  echo "  - phaseB == \"done\" with rows[] non-empty (assets exported)"
  echo "  - manifest.verification.c5.gate == \"PASS\", OR"
  echo "  - manifest.verification.c5.skipped set to one of:"
  echo "      no_project | simctl_error | ci_environment | no_entry_path"
  echo "  - C5.6 coverage check passing (sections / census / diff / attestation)"
  echo "  - C6 (registry ↔ xcassets, no banned systemName) passing"
  echo "  - C7 (no system chrome redraws) passing"
  echo ""
  echo "User phrases like \"skip C5\" / \"bỏ qua C5\" / \"không cần build\" are NOT"
  echo "honored — only the four system reasons above bypass C5."
  echo ""
  echo "Adding a launch-arg / env-var route override to make C5 reachable is"
  echo "BANNED — see references/verification-loop.md §\"C5 Verification Integrity\"."
  echo "If the screen is unreachable from launch and no driver is available,"
  echo "set skipped = \"no_entry_path\" and surface that to the user truthfully."
} >&2
exit 2
