#!/usr/bin/env bash
# PostToolUse hook for Write/Edit on c3-pass2-diff.md
# Auto-runs Gate C3-Pass2 (figma-to-swiftui/references/verification-loop.md §4.1)
# every time the agent writes a Pass 2 diff report. Surfaces structural
# problems and anti-hallucination failures immediately, so the agent fixes
# the report instead of moving on with an invalid one.
#
# Exit codes:
#   0 — silent (file is not a Pass 2 report, or gate PASS with no high FAILs)
#   2 — surface output to agent (gate FAIL, or gate PASS but high FAILs found)

set -uo pipefail

INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only act on c3-pass2-diff.md (and per-attempt snapshots).
case "$FILE_PATH" in
  *c3-pass2-diff.md|*c3-pass2-diff.attempt-*.md) ;;
  *) exit 0 ;;
esac

REPORT="$FILE_PATH"
[ -s "$REPORT" ] || exit 0

CACHE_DIR=$(dirname "$REPORT")
DESIGN_CTX="$CACHE_DIR/design-context.md"

# Pull listed swift files from the report header so we can validate File:Line refs.
SWIFT_FILES=$(awk '
  /^codeFiles:/   { flag=1; next }
  /^[A-Za-z]/     { flag=0 }
  flag && /^ *- / { sub(/^ *- /, ""); print }
' "$REPORT")

FAIL=0
OUT=""

# 1. Required structure
if grep -q '^nodeId:'      "$REPORT" \
   && grep -q '^attempt:'  "$REPORT" \
   && grep -q '^## Findings' "$REPORT" \
   && grep -q '^## Summary'  "$REPORT"; then
  OUT+="PASS: report structure\n"
else
  OUT+="FAIL: report missing required sections (nodeId / attempt / Findings / Summary)\n"
  FAIL=1
fi

# 2. Every required check letter appears in a Findings row
MISSING=""
for code in LH LS SH BD OP RM IS DV BG TR GR SA CH PD BS; do
  grep -qE "^\| *[0-9]+ *\| *${code} *\|" "$REPORT" || MISSING="$MISSING $code"
done
if [ -z "$MISSING" ]; then
  OUT+="PASS: all 15 check letters covered\n"
else
  OUT+="FAIL: missing check letters:$MISSING\n"
  FAIL=1
fi

# 3. Row count
ROW_COUNT=$(grep -cE '^\| *[0-9]+ *\|' "$REPORT")
if [ "${ROW_COUNT:-0}" -ge 12 ]; then
  OUT+="PASS: $ROW_COUNT rows\n"
else
  OUT+="FAIL: only $ROW_COUNT rows (need >=12)\n"
  FAIL=1
fi

# 4. Anti-hallucination: ≥50% of `quoted` strings actually appear in design-context.md
if [ -s "$DESIGN_CTX" ]; then
  QUOTED=$(awk -F'|' '/^\| *[0-9]+ *\|/ { print $6 }' "$REPORT" \
            | grep -oE '`[^`]+`' | sed 's/`//g')
  TOTAL_Q=$(printf '%s\n' "$QUOTED" | grep -c .)
  HIT_Q=0
  if [ "${TOTAL_Q:-0}" -gt 0 ]; then
    while IFS= read -r q; do
      [ -z "$q" ] && continue
      grep -qF "$q" "$DESIGN_CTX" 2>/dev/null && HIT_Q=$((HIT_Q+1))
    done <<< "$QUOTED"
    PCT=$(( HIT_Q * 100 / TOTAL_Q ))
    if [ "$PCT" -ge 50 ]; then
      OUT+="PASS: $PCT% quotes verified ($HIT_Q/$TOTAL_Q)\n"
    else
      OUT+="FAIL: only $PCT% quotes match design-context.md ($HIT_Q/$TOTAL_Q) — anti-hallucination check failed\n"
      FAIL=1
    fi
  fi
fi

# 5. File:Line refs point to real files (line-number bound check is best-effort)
BAD_REFS=""
while IFS='|' read -r _ _idx _check _section _spec _quote _code file_line match_col _sev; do
  match=$(echo "$match_col" | tr -d ' ')
  ref=$(echo "$file_line" | tr -d ' ')
  [ "$match" != "PASS" ] && [ "$match" != "FAIL" ] && continue
  [ -z "$ref" ] || [ "$ref" = "-" ] && continue
  fname="${ref%%:*}"
  lineno="${ref##*:}"
  found=""
  for s in $SWIFT_FILES; do
    case "$s" in
      *"$fname") found="$s"; break ;;
      "$fname")  found="$s"; break ;;
    esac
  done
  if [ -z "$found" ]; then
    BAD_REFS="$BAD_REFS $ref(file)"
  else
    # Resolve relative to cache dir's project root if not absolute
    fpath="$found"
    [ "${fpath:0:1}" != "/" ] && fpath="$(cd "$CACHE_DIR/../.." 2>/dev/null && pwd)/$fpath"
    if [ -f "$fpath" ]; then
      total=$(wc -l < "$fpath" 2>/dev/null || echo 0)
      [ -n "$total" ] && [ "$lineno" -gt "$total" ] 2>/dev/null \
        && BAD_REFS="$BAD_REFS $ref(line>$total)"
    fi
  fi
done < <(grep -E '^\| *[0-9]+ *\|' "$REPORT")

if [ -z "$BAD_REFS" ]; then
  OUT+="PASS: file:line refs valid\n"
else
  OUT+="FAIL: invalid file:line refs:$BAD_REFS\n"
  FAIL=1
fi

# 6. High-severity FAIL count (informational — drives self-fix loop)
HIGH_FAILS=$(grep -cE '\| *FAIL *\| *high *\|' "$REPORT")
OUT+="INFO: $HIGH_FAILS high-severity FAIL rows\n"

if [ $FAIL -eq 0 ]; then
  if [ "${HIGH_FAILS:-0}" -gt 0 ]; then
    {
      echo "Gate C3-Pass2: GATE PASS, but $HIGH_FAILS high-severity FAIL rows present."
      echo ""
      printf "%b" "$OUT"
      echo ""
      echo "Trigger self-fix loop per references/verification-loop.md §4.3:"
      echo "  - snapshot to c3-pass2-diff.attempt-<N>.md"
      echo "  - edit ONLY the file:line cited in each FAIL row (no refactoring)"
      echo "  - re-run Pass 2 from scratch"
    } >&2
    exit 2
  fi
  exit 0
fi

{
  echo "Gate C3-Pass2: GATE FAIL — c3-pass2-diff.md is structurally invalid."
  echo ""
  printf "%b" "$OUT"
  echo ""
  echo "Fix the report (do NOT touch code). After 2 consecutive regen failures,"
  echo "ASK the user — see references/verification-loop.md §4.1."
} >&2
exit 2
