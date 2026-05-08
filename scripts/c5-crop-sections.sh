#!/usr/bin/env bash
# c5-crop-sections.sh — produce per-section crop pairs for the C5.6 visual
# diff. Both the Figma reference and the simulator screenshot get cropped
# to the same bbox (parsed from c5-sections.md, in canvas-percentage), then
# normalized to a common width so the agent sees them at comparable scale.
#
# Without per-section crops, small sections (a section header, a 5-icon
# strip) occupy a few percent of the full canvas and routinely escape
# vision review. Cropping each section to its own image forces the agent
# to actually look at it.
#
# Usage:
#   c5-crop-sections.sh --cache <.figma-cache/nodeId> [--width 1024]
#
# Inputs (must exist in --cache):
#   screenshot.png        Figma render (Phase A)
#   c5-simulator.png      simulator capture (Step C5.5)
#   c5-sections.md        section inventory (Step C5.6.1)
#
# Outputs:
#   crops/<N>-<slug>-figma.png
#   crops/<N>-<slug>-sim.png
#
# Tool selection: prefer ImageMagick (`magick` then `convert`) for accurate
# percentage-based cropping; fall back to macOS `sips`. Exit 2 if neither.

set -euo pipefail

CACHE=""
TARGET_WIDTH=1024

print_usage() {
  cat <<'USAGE' >&2
usage: c5-crop-sections.sh --cache <.figma-cache/nodeId> [--width 1024]

For each section in <cache>/c5-sections.md, crop both screenshot.png (Figma)
and c5-simulator.png (actual) to that section's bbox and normalize to a
common width. Output: crops/<N>-<slug>-figma.png and -sim.png.

bbox_pct format in c5-sections.md is `x:N y:N w:N h:N` where N is a
percentage (0-100) of the canvas. Resolution-agnostic on purpose.

Tools: prefers ImageMagick (`magick` or `convert`); falls back to `sips`.
Exit 2 if neither is available.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)   CACHE="${2:-}";        shift 2 ;;
    --width)   TARGET_WIDTH="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 65; }

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_DIM=""; C_RST=""
fi

FIGMA="$CACHE/screenshot.png"
SIM="$CACHE/c5-simulator.png"
SECTIONS="$CACHE/c5-sections.md"
OUT="$CACHE/crops"

[ -s "$FIGMA"    ] || { echo "FAIL: $FIGMA missing or empty"    >&2; exit 65; }
[ -s "$SIM"      ] || { echo "FAIL: $SIM missing or empty"      >&2; exit 65; }
[ -s "$SECTIONS" ] || { echo "FAIL: $SECTIONS missing or empty" >&2; exit 65; }

# Tool detection.
TOOL=""
if   command -v magick  >/dev/null 2>&1; then TOOL="magick"
elif command -v convert >/dev/null 2>&1; then TOOL="convert"
elif command -v sips    >/dev/null 2>&1; then TOOL="sips"
else
  echo "${C_RED}FAIL${C_RST}: need ImageMagick (magick/convert) or sips; none found" >&2
  exit 2
fi
echo "${C_DIM}using $TOOL${C_RST}"

mkdir -p "$OUT"

# slugify "Top nav bar" → "top-nav-bar"
slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

# Get image dimensions in `WxH`.
img_dims() {
  local f="$1"
  if command -v identify >/dev/null 2>&1; then
    identify -format '%wx%h' "$f"
    return
  fi
  if command -v sips >/dev/null 2>&1; then
    sips -g pixelWidth -g pixelHeight "$f" 2>/dev/null \
      | awk '/pixelWidth/  { w=$2 }
             /pixelHeight/ { h=$2 }
             END { print w "x" h }'
    return
  fi
  echo "0x0"
}

crop_pct() {
  # crop_pct <input> <output> <x_pct> <y_pct> <w_pct> <h_pct> <target_width>
  local in="$1" out="$2" xp="$3" yp="$4" wp="$5" hp="$6" tw="$7"
  case "$TOOL" in
    magick|convert)
      # ImageMagick supports %-based geometry directly.
      "$TOOL" "$in" -crop "${wp}%x${hp}%+$(printf '%.0f' "$(echo "$xp" | awk '{printf "%.4f", $1}')")%+$(printf '%.0f' "$(echo "$yp" | awk '{printf "%.4f", $1}')")%" +repage "$out.tmp.png" 2>/dev/null || true
      # The %+offset syntax is fragile across IM versions; fall back to
      # absolute pixels computed from the source dims.
      if [ ! -s "$out.tmp.png" ]; then
        local dims w h x y cw ch
        dims=$(img_dims "$in"); w="${dims%x*}"; h="${dims#*x}"
        x=$(awk -v p="$xp" -v W="$w" 'BEGIN { printf "%.0f", p*W/100 }')
        y=$(awk -v p="$yp" -v H="$h" 'BEGIN { printf "%.0f", p*H/100 }')
        cw=$(awk -v p="$wp" -v W="$w" 'BEGIN { printf "%.0f", p*W/100 }')
        ch=$(awk -v p="$hp" -v H="$h" 'BEGIN { printf "%.0f", p*H/100 }')
        "$TOOL" "$in" -crop "${cw}x${ch}+${x}+${y}" +repage "$out.tmp.png"
      fi
      "$TOOL" "$out.tmp.png" -resize "${tw}x" "$out"
      rm -f "$out.tmp.png"
      ;;
    sips)
      # sips can't do percentages — convert to pixels first.
      local dims w h x y cw ch
      dims=$(img_dims "$in"); w="${dims%x*}"; h="${dims#*x}"
      if [ -z "$w" ] || [ "$w" = "0" ]; then
        echo "FAIL: could not read dims of $in" >&2; return 1
      fi
      x=$(awk -v p="$xp" -v W="$w" 'BEGIN { printf "%.0f", p*W/100 }')
      y=$(awk -v p="$yp" -v H="$h" 'BEGIN { printf "%.0f", p*H/100 }')
      cw=$(awk -v p="$wp" -v W="$w" 'BEGIN { printf "%.0f", p*W/100 }')
      ch=$(awk -v p="$hp" -v H="$h" 'BEGIN { printf "%.0f", p*H/100 }')
      # sips --cropOffset / --cropToHeightWidth: copy first, then crop, then resize.
      cp "$in" "$out.tmp.png"
      sips --cropOffset "$y" "$x" "$out.tmp.png" >/dev/null 2>&1 || true
      sips -c "$ch" "$cw" "$out.tmp.png" >/dev/null
      sips -Z "$tw" "$out.tmp.png" --out "$out" >/dev/null
      rm -f "$out.tmp.png"
      ;;
  esac
}

# Parse section rows from c5-sections.md.
# Expected schema (markdown table):
#   | # | section            | bbox_pct                  | expected_count | notes ... |
#
# Two-phase: parse → crop. Parsing builds a task list; cropping launches
# each (figma + sim) as a background subshell. Both crops per section are
# independent, all section pairs are independent — net wall-time becomes
# max(per-job time) instead of sum. On a 5-section screen with sips the
# typical saving is ~70% (3-6s → 1-2s).
#
# Per-job output is captured to per-task log files so the final printed
# output stays in deterministic section order regardless of which job
# finished first.

WORK=$(mktemp -d -t c5-crop.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

# Phase 1 — parse sections into a task list.
TASK_COUNT=0
while IFS= read -r row; do
  num=$(  echo "$row" | awk -F'|' '{print $2}' | tr -d ' ')
  name=$( echo "$row" | awk -F'|' '{print $3}' | sed -E 's/^ +| +$//g')
  bbox=$( echo "$row" | awk -F'|' '{print $4}' | sed -E 's/^ +| +$//g')

  case "$num" in ''|*[!0-9]*) continue ;; esac
  [ -n "$name" ] || continue
  [ -n "$bbox" ] || continue

  xp=$(echo "$bbox" | sed -nE 's/.*x:[ ]*([0-9.]+).*/\1/p')
  yp=$(echo "$bbox" | sed -nE 's/.*y:[ ]*([0-9.]+).*/\1/p')
  wp=$(echo "$bbox" | sed -nE 's/.*w:[ ]*([0-9.]+).*/\1/p')
  hp=$(echo "$bbox" | sed -nE 's/.*h:[ ]*([0-9.]+).*/\1/p')
  if [ -z "$xp" ] || [ -z "$yp" ] || [ -z "$wp" ] || [ -z "$hp" ]; then
    echo "${C_RED}skip${C_RST} row $num ($name): cannot parse bbox '$bbox'" >&2
    continue
  fi

  slug=$(slugify "$name")
  fout="$OUT/${num}-${slug}-figma.png"
  sout="$OUT/${num}-${slug}-sim.png"

  # Persist task tuple for phase 2.
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$TASK_COUNT" "$num" "$fout" "$sout" "$xp" "$yp" "$wp" "$hp" >> "$WORK/tasks"
  TASK_COUNT=$((TASK_COUNT+1))
done < <(grep -E '^\| *[0-9]+ *\|' "$SECTIONS")

if [ "$TASK_COUNT" -eq 0 ]; then
  echo "${C_RED}FAIL${C_RST}: no parseable section rows in $SECTIONS" >&2
  exit 1
fi

# Phase 2 — fan out crops in parallel. Each task launches 2 subshells
# (figma + sim). Crops write to unique paths; per-job logs go to $WORK so
# the final report stays in deterministic order.
PIDS=()
while IFS=$'\t' read -r idx num fout sout xp yp wp hp; do
  ( crop_pct "$FIGMA" "$fout" "$xp" "$yp" "$wp" "$hp" "$TARGET_WIDTH" \
      >"$WORK/${idx}.figma.log" 2>&1; echo $? >"$WORK/${idx}.figma.status" ) &
  PIDS+=($!)
  ( crop_pct "$SIM"   "$sout" "$xp" "$yp" "$wp" "$hp" "$TARGET_WIDTH" \
      >"$WORK/${idx}.sim.log" 2>&1; echo $? >"$WORK/${idx}.sim.status" ) &
  PIDS+=($!)
done < "$WORK/tasks"

# Wait for all (plain `wait` works on bash 3.2 / macOS default).
wait "${PIDS[@]}" 2>/dev/null || true

# Phase 3 — print results in deterministic section order.
COUNT=0
FAILED=0
while IFS=$'\t' read -r idx num fout sout _ _ _ _; do
  status_f=$(cat "$WORK/${idx}.figma.status" 2>/dev/null || echo "?")
  status_s=$(cat "$WORK/${idx}.sim.status" 2>/dev/null || echo "?")
  if [ "$status_f" = "0" ] && [ -s "$fout" ]; then
    echo "${C_GRN}wrote${C_RST} $fout"
  else
    echo "${C_RED}FAIL${C_RST}  $fout (status=$status_f)"
    [ -s "$WORK/${idx}.figma.log" ] && sed 's/^/    /' "$WORK/${idx}.figma.log"
    FAILED=$((FAILED+1))
  fi
  if [ "$status_s" = "0" ] && [ -s "$sout" ]; then
    echo "${C_GRN}wrote${C_RST} $sout"
  else
    echo "${C_RED}FAIL${C_RST}  $sout (status=$status_s)"
    [ -s "$WORK/${idx}.sim.log" ] && sed 's/^/    /' "$WORK/${idx}.sim.log"
    FAILED=$((FAILED+1))
  fi
  COUNT=$((COUNT+1))
done < "$WORK/tasks"

if [ "$FAILED" -gt 0 ]; then
  echo "${C_RED}FAIL${C_RST}: $FAILED crop(s) failed (of $((COUNT*2)))"
  exit 1
fi

echo "${C_GRN}done${C_RST}: cropped $COUNT section(s) into $OUT (parallel)"
