#!/usr/bin/env bash
# c5-capture.sh — capture C5.5 simulator screenshot AND emit the
# C5.5b comparison-safe pair (≤2000px long-side) in one call.
#
# Replaces the manual sequence in figma-to-swiftui/SKILL.md C5.5/C5.5b:
#   sleep 2
#   xcrun simctl io <udid> screenshot c5-simulator.png
#   sips -Z 2000 c5-simulator.png --out c5-simulator-cmp.png
#   sips -Z 2000 screenshot.png      --out screenshot-cmp.png   # if missing
#
# Output guarantees (matches Gate C5 expectations in verification-loop.md §5.7):
#   - <cache>/c5-simulator.png        — raw simctl capture (PNG)
#   - <cache>/c5-simulator-cmp.png    — long-side ≤ 2000px (many-image safe)
#   - <cache>/screenshot-cmp.png      — re-derived if missing or > 2000px
#
# Usage:
#   c5-capture.sh --cache <.figma-cache/nodeId> --udid <simulator-udid>
#                 [--settle <seconds=2>] [--no-figma-cmp]
#
# Engine guard: this script is the Engine B (xcodebuild + simctl) path. When
# manifest.verification.c5.engine == "xcode-mcp" (Engine A), it refuses and
# points the agent at mcp__xcode__RenderPreview. Engine selection lives in
# scripts/c5-engine-select.sh.
#
# Exit codes:
#   0 — all three files present and valid PNG
#   1 — at least one capture / shrink step failed
#  64 — bad usage
#  65 — simctl / sips missing OR cache dir missing
#  66 — engine mismatch (run picked Engine A; use mcp__xcode__RenderPreview)

set -uo pipefail

CACHE=""
UDID=""
SETTLE=2
DO_FIGMA_CMP=1

print_usage() {
  cat <<'USAGE' >&2
usage: c5-capture.sh --cache <.figma-cache/nodeId> --udid <simulator-udid>
                     [--settle <seconds=2>] [--no-figma-cmp]

Captures the simulator screenshot for C5.5 and produces the comparison-safe
PNG pair for C5.5b in one call. Always re-derives screenshot-cmp.png from
screenshot.png unless --no-figma-cmp is passed (use that when the Figma
screenshot was already shrunk by a prior run / by figma_export_assets_unified
fallbackScale=2).

The settle time defaults to 2s — same as the SKILL.md sleep call. Bump it
for slow-launching apps. Ignore it (set to 0) when the simulator was already
running and warm.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)         CACHE="${2:-}"; shift 2 ;;
    --udid)          UDID="${2:-}"; shift 2 ;;
    --settle)        SETTLE="${2:-2}"; shift 2 ;;
    --no-figma-cmp)  DO_FIGMA_CMP=0; shift ;;
    -h|--help)       print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -n "$UDID" ]  || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 65; }

command -v xcrun >/dev/null 2>&1 || { echo "FAIL: xcrun missing (Xcode CLT not installed?)" >&2; exit 65; }
command -v sips  >/dev/null 2>&1 || { echo "FAIL: sips missing (macOS only)" >&2; exit 65; }

# Engine guard — refuse when this run was already pinned to Engine A
# (xcode MCP). c5-capture.sh is the Engine B (xcodebuild + simctl) path;
# Engine A doesn't need simctl screenshots because mcp__xcode__RenderPreview
# returns a canvas-sized PNG directly.
if [ -f "$CACHE/manifest.json" ] && command -v jq >/dev/null 2>&1; then
  ENGINE=$(jq -r '.verification.c5.engine // empty' "$CACHE/manifest.json" 2>/dev/null)
  if [ "$ENGINE" = "xcode-mcp" ]; then
    {
      echo "REFUSED: this run picked Engine A (xcode MCP) — c5-capture.sh is Engine B only."
      echo ""
      echo "Manifest: $CACHE/manifest.json — verification.c5.engine = \"xcode-mcp\""
      echo ""
      echo "Engine A path (use these instead, no bash helper needed):"
      echo "  mcp__xcode__BuildProject       — full project build"
      echo "  mcp__xcode__RenderPreview      — snapshot the screen's #Preview directly"
      echo "  (writes c5-render.png to your cache; skip the sips -Z 2000 shrink, the PNG"
      echo "   is already canvas-sized.)"
      echo ""
      echo "If you genuinely need Engine B for this screen (e.g. screen has no #Preview"
      echo "and you must verify on a real simulator), re-pick the engine first:"
      echo "  bash scripts/c5-engine-select.sh --screen-file <path> --explain"
      echo "  jq '.verification.c5.engine = \"xcodebuild\"' $CACHE/manifest.json > $CACHE/manifest.json.tmp && mv $CACHE/manifest.json.tmp $CACHE/manifest.json"
    } >&2
    exit 66
  fi
fi

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_DIM=""; C_RST=""
fi

SIM_PNG="$CACHE/c5-simulator.png"
SIM_CMP="$CACHE/c5-simulator-cmp.png"
FIG_PNG="$CACHE/screenshot.png"
FIG_CMP="$CACHE/screenshot-cmp.png"

ok()  { echo "${C_GRN}PASS${C_RST}: $1"; }
bad() { echo "${C_RED}FAIL${C_RST}: $1"; }

# Helper — return long-side pixel dimension of $1 via sips, "?" on failure.
long_side() {
  sips -g pixelWidth -g pixelHeight "$1" 2>/dev/null \
    | awk '/pixel(Width|Height)/ {print $2}' | sort -n | tail -1
}

# 0. Ensure sim is Booted before attempting screenshot. Fix-spec G — Bible
#    Widgets session hit "Unable to lookup in current state: Shutdown" errors
#    repeatedly because sim drifted to Shutdown between operations.
ensure_booted() {
  for attempt in 1 2 3; do
    state=$(xcrun simctl list devices 2>/dev/null \
      | grep -F "$UDID" \
      | grep -oE '\((Booted|Shutdown|Booting|Shutting Down)\)' | tr -d '()')
    case "$state" in
      Booted) return 0 ;;
      Shutdown|Shutting\ Down)
        xcrun simctl boot "$UDID" 2>/dev/null || true
        sleep $((attempt * 2))
        ;;
      Booting|*) sleep $((attempt * 2)) ;;
    esac
  done
  return 1
}

if ! ensure_booted; then
  bad "sim $UDID not Booted after 3 attempts (state: $state)"
  hint "Manual recovery: xcrun simctl shutdown $UDID && xcrun simctl boot $UDID"
  exit 1
fi

# 1. Settle. SKILL.md uses `sleep 2`. Make it a parameter so warm-sim runs
#    can skip it.
if [ "$SETTLE" != "0" ] 2>/dev/null; then
  sleep "$SETTLE"
fi

# 2. simctl screenshot, with retry on transient stuck-state errors.
#    Fix-spec G — Bible Widgets session: "request to open com.X failed" /
#    "Unable to lookup in current state" errors required manual shutdown+boot
#    cycles. Built into the script now: 3 attempts with 2s/4s/8s backoff.
SIMCTL_ERR=$(mktemp -t c5-capture-err.XXXXXX)
trap 'rm -f "$SIMCTL_ERR"' EXIT

capture_ok=0
for attempt in 1 2 3; do
  if xcrun simctl io "$UDID" screenshot "$SIM_PNG" 2>"$SIMCTL_ERR"; then
    capture_ok=1
    break
  fi

  err_msg=$(cat "$SIMCTL_ERR" 2>/dev/null)
  echo "${C_DIM}simctl attempt $attempt failed: $err_msg${C_RST}"

  # Stuck-state recovery on final attempt: full sim restart cycle
  if [ $attempt -eq 3 ]; then
    if echo "$err_msg" | grep -qE "Unable to lookup|state: Shutdown"; then
      echo "${C_DIM}Last attempt: recovering with shutdown+boot...${C_RST}"
      xcrun simctl shutdown "$UDID" 2>/dev/null || true
      sleep 2
      xcrun simctl boot "$UDID" 2>/dev/null || true
      sleep 4
      if xcrun simctl io "$UDID" screenshot "$SIM_PNG" 2>"$SIMCTL_ERR"; then
        capture_ok=1
      fi
    fi
  else
    sleep $((attempt * 2))
  fi
done

if [ $capture_ok -eq 0 ]; then
  bad "simctl screenshot exited non-zero for udid=$UDID after 3 retries + recovery"
  if [ -s "$SIMCTL_ERR" ]; then
    echo "${C_DIM}simctl stderr:${C_RST}"
    cat "$SIMCTL_ERR"
  fi
  hint "See: ~/.claude/skills/figma-to-swiftui/references/c5-sim-reliability.md"
  exit 1
fi

# 3. Validate raw PNG. simctl can write a non-PNG file when device is in
#    a weird state (recovering from boot, etc.). Catch it before downstream
#    gates see a corrupted file.
if ! file "$SIM_PNG" 2>/dev/null | grep -q "PNG image data"; then
  bad "$SIM_PNG is not a valid PNG (simctl wrote something else?)"
  exit 1
fi
ok "$(basename "$SIM_PNG")"

# 4. Shrink to ≤2000px long-side for C5.6 many-image reads.
SIM_LONG=$(long_side "$SIM_PNG")
if [ -n "$SIM_LONG" ] && [ "$SIM_LONG" -le 2000 ] 2>/dev/null; then
  # Already small enough — copy verbatim instead of re-encoding.
  cp "$SIM_PNG" "$SIM_CMP"
  ok "$(basename "$SIM_CMP") (verbatim copy, $SIM_LONG px)"
else
  if ! sips -Z 2000 "$SIM_PNG" --out "$SIM_CMP" >/dev/null 2>&1; then
    bad "sips shrink failed for $SIM_PNG"
    exit 1
  fi
  NEW_LONG=$(long_side "$SIM_CMP")
  if [ -z "$NEW_LONG" ] || [ "$NEW_LONG" -gt 2000 ] 2>/dev/null; then
    bad "$SIM_CMP long-side=$NEW_LONG (expected ≤2000)"
    exit 1
  fi
  ok "$(basename "$SIM_CMP") (shrunk to $NEW_LONG px)"
fi

# 5. Figma comparison-safe sibling. Always re-derive when stale or missing,
#    unless --no-figma-cmp explicitly opts out.
if [ "$DO_FIGMA_CMP" = "1" ]; then
  if [ ! -s "$FIG_PNG" ]; then
    bad "$FIG_PNG missing — Phase A did not save the Figma screenshot. Re-run get_screenshot."
    exit 1
  fi

  NEED_REFRESH=1
  if [ -s "$FIG_CMP" ]; then
    FIG_CMP_LONG=$(long_side "$FIG_CMP")
    if [ -n "$FIG_CMP_LONG" ] && [ "$FIG_CMP_LONG" -le 2000 ] 2>/dev/null; then
      # Compare modification times — if cmp newer than original, reuse.
      if [ "$FIG_CMP" -nt "$FIG_PNG" ]; then
        ok "$(basename "$FIG_CMP") (cached, $FIG_CMP_LONG px)"
        NEED_REFRESH=0
      fi
    fi
  fi

  if [ "$NEED_REFRESH" = "1" ]; then
    FIG_LONG=$(long_side "$FIG_PNG")
    if [ -n "$FIG_LONG" ] && [ "$FIG_LONG" -le 2000 ] 2>/dev/null; then
      cp "$FIG_PNG" "$FIG_CMP"
      ok "$(basename "$FIG_CMP") (verbatim copy, $FIG_LONG px)"
    else
      if ! sips -Z 2000 "$FIG_PNG" --out "$FIG_CMP" >/dev/null 2>&1; then
        bad "sips shrink failed for $FIG_PNG"
        exit 1
      fi
      NEW_FIG_LONG=$(long_side "$FIG_CMP")
      ok "$(basename "$FIG_CMP") (shrunk to $NEW_FIG_LONG px)"
    fi
  fi
fi

echo "${C_GRN}DONE${C_RST}: capture + comparison-safe pair ready at $CACHE"
exit 0
