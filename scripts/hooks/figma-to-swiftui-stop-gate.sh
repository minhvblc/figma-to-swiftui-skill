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

# Read hook payload from stdin.
PAYLOAD=""
if ! [ -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
fi

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

# ── Session-aware detection ──────────────────────────────────────────────────
# Use the shared probe (transcript figma signal / user message / cache).
# Two outcomes:
#   IS_FIGMA == "yes" AND no cache → block stop, agent skipped Phase A entirely
#   IS_FIGMA == "no"  AND no cache → not a figma task, allow stop
PROBE="$(dirname "$0")/_figma-task-probe.sh"
IS_FIGMA="no"
if [ -x "$PROBE" ]; then
  IS_FIGMA=$(printf '%s' "$PAYLOAD" | "$PROBE" 2>/dev/null || echo "no")
fi

if [ -z "$CACHE_ROOT" ]; then
  if [ "$IS_FIGMA" != "yes" ]; then
    exit 0
  fi
  # Figma task per probe but no .figma-cache/ on disk → agent attempted
  # the run without Phase A at all. This is the failure mode the user
  # reported ("skill không tôn trọng Figma, MCP không chạy"). Block.
  {
    echo "Done-Gate violated: figma task detected (transcript shows a Figma"
    echo "URL or figma-MCP tool/skill use) but no .figma-cache/ on disk — Phase"
    echo "A was never run. The skill does not respect Figma when this happens."
    echo ""
    echo "Required to declare done (minimum):"
    echo "  Phase 0  scripts/mode-detect.sh <projectFolder> --write-cache"
    echo "             greenfield-ikame → scripts/ikxcodegen-scaffold.sh"
    echo "             greenfield-vanilla → scripts/vanilla-scaffold.sh"
    echo "  Phase A  per screen: figma_build_registry + get_design_context"
    echo "             + get_screenshot + figma_extract_tokens"
    echo "             + figma_extract_fills + get_metadata"
    echo "             + manifest.phaseA = \"done\""
    echo "  Phase B  per screen: figma_export_assets_unified(autoDiscover: true)"
    echo "             → every eIC*/eImage* exported into Assets.xcassets"
    echo "             + manifest.phaseB = \"done\""
    echo "  Phase C  self-check passes (Pass 2/3/3b) + C5 build + render"
    echo "             + manifest.verification.c5.gate = \"PASS\""
    echo ""
    echo "If this run is NOT actually a figma task (probe false positive),"
    echo "use a .swift path containing _NoFigma_ — that bypasses the gates."
  } >&2
  exit 2
fi

# Cache exists — apply original session-aware bypass: if probe says no
# (cache is leftover from a prior unrelated session), allow stop.
if [ "$IS_FIGMA" != "yes" ]; then
  exit 0
fi

PROJECT_ROOT=$(dirname "$CACHE_ROOT")

# Locate scripts dir (sibling to hooks dir).
SCRIPT_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -d "$SCRIPT_DIR" ] || SCRIPT_DIR="$HOME/.claude/hooks/.."

C6_SCRIPT="$SCRIPT_DIR/c6-asset-completeness.sh"
C7_SCRIPT="$SCRIPT_DIR/c7-no-system-chrome.sh"

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

PHASE_A_DONE_COUNT=0
PHASE_A_WIP_COUNT=0
PHASE_A_WIP_LIST=""
SCREEN_TOTAL=0
for DIR in "${SCREEN_DIRS[@]}"; do
  BASE=$(basename "$DIR")
  [ "$BASE" = "_shared" ] && continue
  SCREEN_TOTAL=$((SCREEN_TOTAL+1))

  MANIFEST="$DIR/manifest.json"
  [ ! -f "$MANIFEST" ] && continue

  # WIP screens — manifest.json exists but phaseA isn't "done". Track them
  # so the per-flow summary surfaces partial runs (was silently skipped via
  # `continue` before).
  PHASE_A=$(jq -r '.phaseA // empty' "$MANIFEST" 2>/dev/null)
  if [ "$PHASE_A" != "done" ]; then
    PHASE_A_WIP_COUNT=$((PHASE_A_WIP_COUNT+1))
    PHASE_A_WIP_LIST+="$BASE (phaseA=${PHASE_A:-unset}), "
    continue
  fi
  PHASE_A_DONE_COUNT=$((PHASE_A_DONE_COUNT+1))

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

  # ── 2b. Engine choice regression check ───────────────────────────────────────
  # Flag when C5 was completed via Engine B (xcodebuild) despite Engine A
  # (xcode MCP) being available. Engine A is the default on Xcode 26+ fleets
  # — picking Engine B means slower builds, simctl cold-start, and SPM resolve
  # hang. This is informational (does NOT block stop), but raises visibility
  # so the user can re-run with Engine A.
  if [ "$C5_OK" = "1" ] && [ -z "$SKIPPED" ]; then
    ENGINE=$(jq -r '.verification.c5.engine // empty' "$MANIFEST" 2>/dev/null)
    if [ "$ENGINE" = "xcodebuild" ]; then
      ENGINE_A_AVAIL=0
      xcrun mcpbridge --help >/dev/null 2>&1 && pgrep -x Xcode >/dev/null 2>&1 && ENGINE_A_AVAIL=1
      if [ "$ENGINE_A_AVAIL" = "1" ]; then
        PROBLEMS+="    - C5 used Engine B (xcodebuild) but Engine A is available — re-run with mcp__xcode__BuildProject / RenderPreview for the speed wins. Probe with: scripts/c5-engine-select.sh --explain\n"
      fi
    fi
  fi

  if [ -n "$PROBLEMS" ]; then
    VIOLATIONS+="  $BASE/\n${PROBLEMS}"
  fi
done

# ── Global Phase A coverage check ───────────────────────────────────────────
# If this is a figma task (probe yes) but NO screen has Phase A done, the
# agent never actually ran Phase A on disk — even though the cache directory
# exists. Surface this distinctly because the per-screen loop skips silently
# in that case (continue when phaseA != "done").
if [ "$PHASE_A_DONE_COUNT" = "0" ]; then
  VIOLATIONS+="  (flow-level)\n"
  if [ "$SCREEN_TOTAL" = "0" ]; then
    VIOLATIONS+="    - No screen-cache directories under $CACHE_ROOT/ (Phase A never started for any screen)\n"
  else
    VIOLATIONS+="    - $SCREEN_TOTAL screen-cache dir(s) found but ZERO have manifest.phaseA = \"done\"\n"
  fi
  VIOLATIONS+="    - Run Phase A per screen: figma_build_registry + get_design_context + get_screenshot + figma_extract_tokens + figma_extract_fills + get_metadata, persist phaseA: \"done\"\n"
  VIOLATIONS+="    - Then Phase B: figma_export_assets_unified(autoDiscover: true) to populate Assets.xcassets, persist phaseB: \"done\"\n"
fi

# ── Partial-flow WIP surfacing (Gap F) ─────────────────────────────────────
# Some screens have Phase A done, others are work-in-progress. Don't silently
# accept stop — list the WIP screens so the user (and agent) sees the partial
# state explicitly. This is a soft block: the user can decide to ship partial
# or finish the WIP screens.
if [ "$PHASE_A_DONE_COUNT" -gt 0 ] && [ "$PHASE_A_WIP_COUNT" -gt 0 ]; then
  WIP_LIST_TRIMMED="${PHASE_A_WIP_LIST%, }"
  VIOLATIONS+="  (flow-level)\n"
  VIOLATIONS+="    - $PHASE_A_WIP_COUNT screen(s) in-progress (phaseA != \"done\"): $WIP_LIST_TRIMMED\n"
  VIOLATIONS+="    - Finish Phase A for those screens or remove their cache dirs if no longer in scope\n"
fi

# ── Project-wide C6 + C7 (run once, not per-screen) ─────────────────────────
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

# ── Timing summary (informational, both PASS and FAIL paths) ────────────────
# Aggregate per-screen manifest.timing into one line so the user knows where
# wall-time went without running timing-report.sh manually. Silent when no
# screen has timing data.
print_timing_summary() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$CACHE_ROOT" <<'PY' 2>/dev/null
import json, os, sys
root = sys.argv[1]
totals = {"phaseA": 0, "phaseB": 0, "c2": 0, "c3Pass2": 0, "c5": 0, "other": 0}
total_ms = 0
n_screens = 0
have_data = False
for entry in sorted(os.listdir(root)):
    sub = os.path.join(root, entry)
    if not os.path.isdir(sub) or entry == "_shared":
        continue
    mp = os.path.join(sub, "manifest.json")
    if not os.path.isfile(mp):
        continue
    try:
        m = json.load(open(mp))
    except Exception:
        continue
    t = m.get("timing") or {}
    if not isinstance(t, dict):
        continue
    n_screens += 1
    for key in list(t.keys()):
        if key == "_history":
            continue
        block = t.get(key) or {}
        ms = block.get("ms") if isinstance(block, dict) else None
        if not isinstance(ms, int):
            continue
        have_data = True
        if key in totals:
            totals[key] += ms
        else:
            totals["other"] += ms
        if not key.startswith(("c1", "c3Pass3", "c5_6")):
            total_ms += ms
if not have_data:
    sys.exit(0)
secs = total_ms / 1000.0
def s(ms): return f"{ms/1000:.1f}s" if isinstance(ms, int) and ms > 0 else "-"
parts = []
for k in ("phaseA", "phaseB", "c2", "c3Pass2", "c5", "other"):
    if totals[k] > 0:
        parts.append(f"{k}={s(totals[k])}")
print(f"  Wall-time total: {secs:.1f}s across {n_screens} screen(s) — " + ", ".join(parts))
PY
}

TIMING_LINE=$(print_timing_summary)

# Done — assemble report.
if [ -z "$VIOLATIONS" ] && [ -z "$PROJECT_PROBLEMS" ]; then
  if [ -n "$TIMING_LINE" ]; then
    {
      echo "Done-Gate satisfied."
      echo "$TIMING_LINE"
    } >&2
  fi
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
  if [ -n "$TIMING_LINE" ]; then
    echo ""
    echo "$TIMING_LINE"
  fi
} >&2
exit 2
