#!/usr/bin/env bash
# c5-coverage-check.sh — run the structural checks for Gate C5.
#
# Encapsulates the gate logic so the BASH block in verification-loop.md stays
# short. Does NOT screenshot, does NOT compile — those are upstream of this
# script. Only verifies the artifacts that prove the agent walked the
# 6-step C5.6 procedure.
#
# Checks (each emits one PASS/FAIL line):
#   1. c5-sections.md exists, non-empty, ≥1 section row, ≥4 unless justified
#   2. c5-census.md exists, non-empty
#   3. crops/ directory exists with ≥ 2 × section count PNG files
#   4. c5-visual-diff.md exists, non-empty
#   5. Free-form "## What's wrong" block present
#   6. Structured 3-axis diff rows ≥ 3 × section count
#   7. "## Negative spot-check" block present, both A: lines answered
#   8. "## 4-anchor proportional check" present, all 4 rows non-empty
#   9. "## Attestation" present
#  10. No weasel words in PASS rows (delegates to c5-weasel-detect.sh)
#
# Usage:
#   c5-coverage-check.sh --cache <.figma-cache/nodeId>
#
# Exit codes:
#   0 — all checks pass
#   1 — at least one check failed
#   64 — bad usage
#   65 — cache dir not found

set -euo pipefail

CACHE=""

print_usage() {
  cat <<'USAGE' >&2
usage: c5-coverage-check.sh --cache <.figma-cache/nodeId>

Runs the structural checks for Gate C5.6 against the given cache directory.
Prints one PASS/FAIL line per check, then a summary. Exit 0 iff every check
passes. Does NOT compile or screenshot — those run upstream.

Expected artifacts in the cache:
  c5-sections.md, c5-census.md, c5-visual-diff.md,
  crops/<N>-<slug>-figma.png, crops/<N>-<slug>-sim.png
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)   CACHE="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 65; }

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_RST=""
fi

SECTIONS="$CACHE/c5-sections.md"
CENSUS="$CACHE/c5-census.md"
DIFF="$CACHE/c5-visual-diff.md"
CROPS="$CACHE/crops"

FAIL=0
ok()   { echo "${C_GRN}PASS${C_RST}: $1"; }
bad()  { echo "${C_RED}FAIL${C_RST}: $1"; FAIL=1; }

# 1. Sections file
SECTION_COUNT=0
if [ ! -s "$SECTIONS" ]; then
  bad "c5-sections.md missing or empty ($SECTIONS)"
else
  # Count table data rows (skip header + separator). A data row is a line
  # starting with `|` whose first cell is a number.
  SECTION_COUNT=$(grep -cE '^\| *[0-9]+ *\|' "$SECTIONS" || true)
  if [ "$SECTION_COUNT" -lt 1 ]; then
    bad "c5-sections.md has no data rows"
  elif [ "$SECTION_COUNT" -lt 4 ] && ! grep -q '^## Why fewer than 4' "$SECTIONS"; then
    bad "c5-sections.md has only $SECTION_COUNT rows and no '## Why fewer than 4' justification"
  else
    ok "c5-sections.md: $SECTION_COUNT section row(s)"
  fi
fi

# 2. Census file
if [ ! -s "$CENSUS" ]; then
  bad "c5-census.md missing or empty ($CENSUS)"
else
  ok "c5-census.md present"
fi

# 3. Crops directory: ≥ 2 × section count PNGs (figma + sim per section).
EXPECTED_CROPS=$((SECTION_COUNT * 2))
if [ "$SECTION_COUNT" -lt 1 ]; then
  bad "crops/ — section count is 0, cannot validate"
elif [ ! -d "$CROPS" ]; then
  bad "crops/ directory missing ($CROPS)"
else
  CROP_PNGS=$(find "$CROPS" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')
  if [ "$CROP_PNGS" -lt "$EXPECTED_CROPS" ]; then
    bad "crops/ has $CROP_PNGS PNG(s); expected ≥ $EXPECTED_CROPS (2 per section)"
  else
    # Validate every file is a real PNG, not a 0-byte placeholder. Catches agents
    # who run `touch fake.png` to satisfy the count check.
    INVALID=0
    while IFS= read -r f; do
      if ! file "$f" 2>/dev/null | grep -q 'PNG image data'; then
        bad "crops/$(basename "$f") is not a valid PNG"
        INVALID=$((INVALID + 1))
      fi
    done < <(find "$CROPS" -maxdepth 1 -name '*.png')
    if [ "$INVALID" -eq 0 ]; then
      ok "crops/: $CROP_PNGS valid PNG(s) (≥ $EXPECTED_CROPS expected)"
    fi
  fi
fi

# 4. Diff file
if [ ! -s "$DIFF" ]; then
  bad "c5-visual-diff.md missing or empty ($DIFF)"
  echo
  if [ "$FAIL" -eq 0 ]; then echo "GATE: PASS"; else echo "GATE: FAIL"; fi
  exit "$FAIL"
fi
ok "c5-visual-diff.md present"

# 5. Free-form "what's wrong" block
if grep -qE "^## What's wrong" "$DIFF"; then
  ok "## What's wrong block present"
else
  bad "## What's wrong (free-form) block missing"
fi

# 6. Structured diff rows ≥ 3 × section count
if [ "$SECTION_COUNT" -ge 1 ]; then
  DIFF_ROWS=$(grep -cE '^\| *[0-9]+ *\|' "$DIFF" || true)
  EXPECTED_ROWS=$((SECTION_COUNT * 3))
  if [ "$DIFF_ROWS" -lt "$EXPECTED_ROWS" ]; then
    bad "c5-visual-diff.md has $DIFF_ROWS data rows; expected ≥ $EXPECTED_ROWS (3 per section: PR/LY/ST)"
  else
    ok "c5-visual-diff.md: $DIFF_ROWS rows (≥ $EXPECTED_ROWS expected)"
  fi
fi

# 7. Negative spot-check Q&A
if grep -q '^## Negative spot-check' "$DIFF"; then
  A_COUNT=$(awk '
    /^## Negative spot-check/   { in_block=1; next }
    /^## /                      { in_block=0 }
    in_block && /^A:/           { c++ }
    END { print c+0 }
  ' "$DIFF")
  if [ "$A_COUNT" -ge 2 ]; then
    ok "## Negative spot-check: $A_COUNT answer(s)"
  else
    bad "## Negative spot-check has $A_COUNT 'A:' line(s); expected 2"
  fi
else
  bad "## Negative spot-check block missing"
fi

# 8. 4-anchor proportional check — must have 4 populated rows.
if grep -q '^## 4-anchor proportional check' "$DIFF"; then
  # Count rows in the anchor block whose first cell starts with a letter
  # (not a digit, since this table's first column is the anchor name).
  POP_ROWS=$(awk '
    /^## 4-anchor proportional check/ { in_block=1; next }
    /^## /                            { in_block=0 }
    in_block && /^\| *[A-Za-z]/ {
      # split on |, trim, count non-empty data cells. Skip header row
      # (first cell == "anchor" or contains the literal word "anchor"
      # without coordinates) only when other cells are empty.
      n=split($0, cells, "|")
      # Cells 2..n-1 are data cells (1 and n are pre/post-pipe empties).
      empties=0; total=0
      for (i=2; i<n; i++) {
        v=cells[i]; gsub(/^ +| +$/, "", v)
        total++
        if (v=="") empties++
      }
      if (total>=4 && empties==0) print
    }
  ' "$DIFF" | wc -l | tr -d ' ')
  if [ "$POP_ROWS" -ge 4 ]; then
    ok "## 4-anchor proportional check: $POP_ROWS populated row(s)"
  else
    bad "## 4-anchor proportional check has $POP_ROWS populated row(s); expected ≥ 4"
  fi
else
  bad "## 4-anchor proportional check block missing"
fi

# 9. Attestation
if grep -q '^## Attestation' "$DIFF"; then
  ok "## Attestation block present"
else
  bad "## Attestation block missing"
fi

# 10. Weasel detector — delegate to the standalone script.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WEASEL="$SCRIPT_DIR/c5-weasel-detect.sh"
if [ -x "$WEASEL" ]; then
  if "$WEASEL" --report "$DIFF" >/dev/null 2>&1; then
    ok "no weasel words in PASS rows"
  else
    bad "weasel words found in PASS rows (run c5-weasel-detect.sh --report $DIFF for details)"
  fi
else
  bad "c5-weasel-detect.sh missing or not executable at $WEASEL"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "GATE: PASS (C5.6 coverage)"
  exit 0
else
  echo "GATE: FAIL (C5.6 coverage)"
  exit 1
fi
