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

# ── Session-aware bypass ─────────────────────────────────────────────────────
# A leftover .figma-cache/ from a prior session should not block unrelated
# future tasks (xcstrings translate, refactors, debugging, etc.). Read the
# Stop hook payload from stdin and look at the live transcript: if the
# current session has not invoked the figma-to-swiftui workflow (skill or
# Figma MCP tools), allow stop.
PAYLOAD=""
if ! [ -t 0 ]; then
  PAYLOAD=$(cat 2>/dev/null || true)
fi
TRANSCRIPT_PATH=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null || true)

if [ -n "$TRANSCRIPT_PATH" ] && [ -r "$TRANSCRIPT_PATH" ]; then
  # Match real workflow activity in tool_use blocks:
  #   - Skill calls for figma-to-swiftui / figma-flow-to-swiftui-feature
  #   - MCP tool calls whose name contains "figma" (Figma desktop, plugin,
  #     figma-assets servers, etc.)
  #   - Direct figma-assets tool calls (figma_extract_tokens,
  #     figma_export_assets[_unified], figma_build_registry)
  FIGMA_SIGNAL='"skill":[[:space:]]*"figma-to-swiftui|"skill":[[:space:]]*"figma-flow-to-swiftui-feature|"name":[[:space:]]*"mcp__[A-Za-z0-9_]*[Ff]igma|"name":[[:space:]]*"figma_(extract_tokens|export_assets|export_assets_unified|build_registry)'
  if ! grep -qE "$FIGMA_SIGNAL" "$TRANSCRIPT_PATH" 2>/dev/null; then
    exit 0
  fi
fi

PROJECT_ROOT=$(dirname "$CACHE_ROOT")

# Locate scripts dir (sibling to hooks dir).
SCRIPT_DIR="$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)"
[ -d "$SCRIPT_DIR" ] || SCRIPT_DIR="$HOME/.claude/hooks/.."

C6_SCRIPT="$SCRIPT_DIR/c6-asset-completeness.sh"
C7_SCRIPT="$SCRIPT_DIR/c7-no-system-chrome.sh"
C5_COV_SCRIPT="$SCRIPT_DIR/c5-coverage-check.sh"
C8_CONV_SCRIPT="$SCRIPT_DIR/c8-conventions-gate.sh"
C8_VM_SCRIPT="$SCRIPT_DIR/c8-vm-pattern.sh"
C8_FUN_SCRIPT="$SCRIPT_DIR/c8-func-length.sh"
C8_IKNAV_SCRIPT="$SCRIPT_DIR/c8-iknavigation.sh"
C8_IKFONT_SCRIPT="$SCRIPT_DIR/c8-ikfont.sh"

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
for cand in \
  "$HOME/.claude/scripts/c8-conventions-gate.sh" \
  "$HOME/.claude/c8-conventions-gate.sh" \
  "$PROJECT_ROOT/scripts/c8-conventions-gate.sh"; do
  [ -x "$cand" ] && C8_CONV_SCRIPT="$cand" && break
done
for cand in \
  "$HOME/.claude/scripts/c8-vm-pattern.sh" \
  "$HOME/.claude/c8-vm-pattern.sh" \
  "$PROJECT_ROOT/scripts/c8-vm-pattern.sh"; do
  [ -x "$cand" ] && C8_VM_SCRIPT="$cand" && break
done
for cand in \
  "$HOME/.claude/scripts/c8-func-length.sh" \
  "$HOME/.claude/c8-func-length.sh" \
  "$PROJECT_ROOT/scripts/c8-func-length.sh"; do
  [ -x "$cand" ] && C8_FUN_SCRIPT="$cand" && break
done
for cand in \
  "$HOME/.claude/scripts/c8-iknavigation.sh" \
  "$HOME/.claude/c8-iknavigation.sh" \
  "$PROJECT_ROOT/scripts/c8-iknavigation.sh"; do
  [ -x "$cand" ] && C8_IKNAV_SCRIPT="$cand" && break
done
for cand in \
  "$HOME/.claude/scripts/c8-ikfont.sh" \
  "$HOME/.claude/c8-ikfont.sh" \
  "$PROJECT_ROOT/scripts/c8-ikfont.sh"; do
  [ -x "$cand" ] && C8_IKFONT_SCRIPT="$cand" && break
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

# ── 5. C8 — Coding-conventions gates (project-wide) ────────────────────────────
# Pick a c1-conventions.json from the cache (single-screen runs put it under the
# screen folder; flow runs put it under _shared/). When neither exists, the
# project-agnostic c8 gates still run but the conditional ones (iknavigation /
# ikfont) treat absent JSON as their `false` / `null` default and emit SKIP.
CONV_JSON=""
[ -f "$CACHE_ROOT/_shared/c1-conventions.json" ] && CONV_JSON="$CACHE_ROOT/_shared/c1-conventions.json"
if [ -z "$CONV_JSON" ]; then
  for d in "${SCREEN_DIRS[@]}"; do
    [ -f "$d/c1-conventions.json" ] && CONV_JSON="$d/c1-conventions.json" && break
  done
fi

# ── Session-scope: pull list of files this session generated ────────────────
# PostToolUse hook (figma-to-swiftui-c8-gate.sh) appends every Write/Edit'd
# .swift file to .figma-cache/session-files.json. We pass that list to the
# C8 gates as --files so they don't flag pre-existing tech debt outside
# the agent's scope.
#
# Empty list → C8 content gates SKIP (the only files this session touched
# were non-swift artifacts, e.g. manifest.json / cache files).
# Missing file → fall back to project-wide --src mode (legacy behavior, used
# when the user runs stop-gate manually outside a figma session).
SESSION_FILES_JSON="$CACHE_ROOT/session-files.json"
SESSION_FILES=""
USE_FILES_MODE=0
if [ -f "$SESSION_FILES_JSON" ] && command -v python3 >/dev/null 2>&1; then
  SESSION_FILES=$(python3 - "$SESSION_FILES_JSON" <<'PY' 2>/dev/null
import json, sys, os
try:
    data = json.load(open(sys.argv[1]))
    files = [f for f in (data.get("files") or []) if isinstance(f, str) and os.path.isfile(f)]
    print(" ".join(files))
except Exception:
    print("")
PY
)
  USE_FILES_MODE=1
fi

c8_args() {
  if [ -n "$CONV_JSON" ]; then
    printf -- '--conventions %s' "$CONV_JSON"
  else
    # Conventions JSON missing — pass /dev/null so the gate falls to its
    # default (skip when conditional flag absent).
    printf -- '--conventions /dev/null'
  fi
}

# Build the scope args for a C8 gate. --files mode: pass --src for rel-path
# display + --files for the actual scope. Legacy --src mode: just --src.
c8_scope_args() {
  local root="$1"
  if [ "$USE_FILES_MODE" = "1" ]; then
    printf -- '--src %s --files %s' "$root" "$(printf '%q' "$SESSION_FILES")"
  else
    printf -- '--src %s' "$root"
  fi
}

run_c8() {
  local script="$1" name="$2" with_conv="$3" root="$4"
  [ -x "$script" ] || return 0
  [ -d "$root" ] || return 0
  local scope_args; scope_args=$(c8_scope_args "$root")
  local conv_args=""
  [ "$with_conv" = "1" ] && conv_args=$(c8_args)
  # shellcheck disable=SC2086
  if ! eval "$script" $scope_args $conv_args >/dev/null 2>&1; then
    PROJECT_PROBLEMS+="  - C8 ${name} failing — run:\n"
    PROJECT_PROBLEMS+="      $script $scope_args $conv_args\n"
  fi
}

# c8-conventions-gate inspects FOLDER STRUCTURE (Screens/<X>Screen/<X>Screen.swift)
# so it receives PROJECT_ROOT for the parent-view check (legacy mode only —
# in --files mode the gate restricts itself to screen folders containing
# session files).
# c8-vm-pattern, c8-func-length, c8-iknavigation, c8-ikfont, c8-weak-self
# only care about file contents, so SRC_ROOT is fine for legacy mode.
run_c8 "$C8_CONV_SCRIPT"   "conventions (folder + naming)" 1 "$PROJECT_ROOT"
run_c8 "$C8_VM_SCRIPT"     "viewmodel pattern"             0 "$SRC_ROOT"
run_c8 "$C8_FUN_SCRIPT"    "function length"               0 "$SRC_ROOT"
run_c8 "$C8_IKNAV_SCRIPT"  "IKNavigation (conditional)"    1 "$SRC_ROOT"
run_c8 "$C8_IKFONT_SCRIPT" "IKFont (conditional)"          1 "$SRC_ROOT"

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
        if not key.startswith(("c1", "c3Pass3", "c3Pass4", "c3Pass5", "c5_6")):
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
  echo "  - C5.6 coverage check passing (sections / census / diff / attestation)"
  echo "  - C6 (registry ↔ xcassets, no banned systemName) passing"
  echo "  - C7 (no system chrome redraws) passing"
  echo "  - C8 (project-structure / viewmodel / function-length / IKNavigation / IKFont) passing"
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
