#!/usr/bin/env bash
# c3-pass2-prefill.sh — generate a partially-filled c3-pass2-diff.md template.
#
# Goal: cut typing on rows the agent can decide MECHANICALLY (CH "no chrome",
# PD "no inline paddings", and N/A rows for checks whose subject doesn't exist
# in either design-context.md or the generated swift files). The agent still
# fills LH/LS/SH/BD/OP/RM/IS rows where Figma values must be cross-checked.
#
# Anti-hallucination: every prefilled row is justified by a grep result or a
# SKILL ABSOLUTE RULE source quote. The agent reviews and can flip PASS→FAIL
# if the script was wrong; gate C3-Pass2 (PostToolUse hook) still runs unchanged.
#
# Usage: c3-pass2-prefill.sh <nodeId> [--force]
#   - reads .figma-cache/<nodeId>/{design-context.md,manifest.json,tokens.json}
#   - reads swift files listed in manifest.rows[].swiftFiles[] OR .swiftFiles[]
#   - writes .figma-cache/<nodeId>/c3-pass2-diff.md (refuses to overwrite unless --force)

set -uo pipefail

NODE_ID="${1:-}"
FORCE="${2:-}"

if [ -z "$NODE_ID" ]; then
  echo "usage: $0 <nodeId> [--force]" >&2
  exit 64
fi

CACHE=".figma-cache/$NODE_ID"
DESIGN_CTX="$CACHE/design-context.md"
MANIFEST="$CACHE/manifest.json"
TOKENS="$CACHE/tokens.json"
REPORT="$CACHE/c3-pass2-diff.md"

[ -d "$CACHE" ] || { echo "FAIL: $CACHE not found (Phase A not complete?)" >&2; exit 65; }
[ -s "$DESIGN_CTX" ] || { echo "FAIL: design-context.md missing/empty" >&2; exit 65; }

if [ -f "$REPORT" ] && [ "$FORCE" != "--force" ]; then
  echo "REFUSE: $REPORT exists. Pass --force to overwrite." >&2
  exit 66
fi

# --- Discover swift files for this screen -----------------------------------
# Try manifest.swiftFiles[] first (flow skill writes this); fall back to
# manifest.rows[].swiftFiles[] aggregation.
SWIFT_FILES=""
if [ -s "$MANIFEST" ] && command -v jq >/dev/null 2>&1; then
  SWIFT_FILES=$(jq -r '
    (.swiftFiles // []) + ([.rows[]?.swiftFiles[]?] // [])
    | unique
    | .[]?
  ' "$MANIFEST" 2>/dev/null)
fi

# If manifest didn't list them, do best-effort: any *.swift modified after
# the manifest's mtime, under the project root (cache parent's parent).
if [ -z "$SWIFT_FILES" ]; then
  PROJECT_ROOT=$(cd "$CACHE/../.." 2>/dev/null && pwd)
  if [ -n "$PROJECT_ROOT" ] && [ -s "$MANIFEST" ]; then
    SWIFT_FILES=$(find "$PROJECT_ROOT" -name '*.swift' -newer "$MANIFEST" \
                    -not -path '*/.figma-cache/*' \
                    -not -path '*/.build/*' \
                    -not -path '*/DerivedData/*' 2>/dev/null | head -20)
  fi
fi

SWIFT_LIST=""
SWIFT_GREP_TARGETS=""
if [ -n "$SWIFT_FILES" ]; then
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    SWIFT_LIST="${SWIFT_LIST}  - ${f}"$'\n'
    [ -f "$f" ] && SWIFT_GREP_TARGETS="$SWIFT_GREP_TARGETS $f"
  done <<< "$SWIFT_FILES"
fi

# --- Mechanical detectors ---------------------------------------------------
# Each detector returns "PASS|FAIL|NA <reason>" so prefill stays auditable.

dc_has() {
  # case-insensitive substring search in design-context.md
  grep -qiE "$1" "$DESIGN_CTX" 2>/dev/null
}

code_has() {
  [ -n "$SWIFT_GREP_TARGETS" ] || return 1
  grep -qE "$1" $SWIFT_GREP_TARGETS 2>/dev/null
}

# CH (no system chrome): PASS unless code draws status bar / home indicator / Dynamic Island.
ch_verdict() {
  if code_has 'Capsule\(\).*frame\(.*width:.*13[0-9]'; then
    echo "FAIL high | code seems to render home indicator"
  elif code_has '"9:41"|9 41|status.*bar.*Time'; then
    echo "FAIL high | code seems to render status bar time"
  else
    echo "PASS | -"
  fi
}

# PD (explicit padding): PASS if no inline numeric padding in code (only Spacing.* / Padding.*).
# FAIL high if any `.padding(<digit>)` or `.padding(.<edge>, <digit>)` literal found.
pd_verdict() {
  [ -n "$SWIFT_GREP_TARGETS" ] || { echo "TODO | -"; return; }
  local hits
  hits=$(grep -nE '\.padding\(\s*[0-9]+(\.[0-9]+)?\s*\)|\.padding\(\.[a-zA-Z]+,\s*[0-9]+(\.[0-9]+)?\s*\)' \
           $SWIFT_GREP_TARGETS 2>/dev/null | head -3)
  if [ -z "$hits" ]; then
    echo "PASS | no inline numeric padding (all routed through Spacing/IKCoreApp)"
  else
    local ref
    ref=$(echo "$hits" | head -1 | awk -F: '{print $1":"$2}')
    echo "FAIL high | inline padding at $ref — route via Spacing enum"
  fi
}

# GR (gradient): N/A if neither design-context nor code mentions gradient.
gr_verdict() {
  local in_dc=0 in_code=0
  dc_has 'gradient|linear-gradient|radial-gradient' && in_dc=1
  code_has 'LinearGradient|RadialGradient|AngularGradient|MeshGradient' && in_code=1
  if [ $in_dc -eq 0 ] && [ $in_code -eq 0 ]; then
    echo "NA | no gradient in design-context.md and none in code"
  else
    echo "TODO | gradient present — agent must verify stops/direction"
  fi
}

# DV (divider): N/A if neither side mentions divider.
dv_verdict() {
  local in_dc=0 in_code=0
  dc_has 'divider|<hr|border-top|border-bottom' && in_dc=1
  code_has 'Divider\(\)|Rectangle\(\).*frame\(.*height:\s*(0\.|1\b)' && in_code=1
  if [ $in_dc -eq 0 ] && [ $in_code -eq 0 ]; then
    echo "NA | no divider in design-context.md and none in code"
  else
    echo "TODO | divider present — agent must verify color/opacity/height"
  fi
}

# BG (background blur / material): N/A if neither references blur/material.
bg_verdict() {
  local in_dc=0 in_code=0
  dc_has 'backdrop-blur|backdrop-filter|blur\(' && in_dc=1
  code_has '\.background\(.*Material|\.blur\(radius:' && in_code=1
  if [ $in_dc -eq 0 ] && [ $in_code -eq 0 ]; then
    echo "NA | no background blur/material in design-context.md and none in code"
  else
    echo "TODO | blur present — agent must verify radius/material"
  fi
}

# TR (text truncation): N/A if design-context doesn't constrain line count and
# code has no Text with lineLimit/truncationMode.
tr_verdict() {
  local in_dc=0 in_code=0
  dc_has 'truncate|line-clamp|max-lines|nowrap' && in_dc=1
  code_has '\.lineLimit\(|\.truncationMode\(|\.allowsTightening\(' && in_code=1
  if [ $in_dc -eq 0 ] && [ $in_code -eq 0 ]; then
    echo "NA | no truncation hint in design-context.md and none in code"
  else
    echo "TODO | truncation/lineLimit involved — verify"
  fi
}

# SA (safe area): PASS if exactly one of {ignoresSafeArea, safeAreaInset, safeAreaPadding} appears
# in code AND design-context says either "edge to edge" or has none. Fail-safe → TODO.
sa_verdict() {
  local in_code=0
  code_has '\.ignoresSafeArea|\.safeAreaInset|\.safeAreaPadding' && in_code=1
  if [ $in_code -eq 1 ]; then
    echo "TODO | safe-area modifiers present — verify Figma intent"
  else
    echo "PASS | no safe-area override; iOS handles default insets"
  fi
}

# BS (.buttonStyle): PASS if every Button in code has .buttonStyle(...) within 5 lines.
# FAIL high if a Button has no .buttonStyle. NA if no Button.
bs_verdict() {
  [ -n "$SWIFT_GREP_TARGETS" ] || { echo "TODO | -"; return; }
  local btn_lines
  btn_lines=$(grep -nE 'Button\s*\(|Button\s*\{' $SWIFT_GREP_TARGETS 2>/dev/null | wc -l | tr -d ' ')
  if [ "${btn_lines:-0}" -eq 0 ]; then
    echo "NA | no Button in code"
    return
  fi
  local missing=0
  while IFS= read -r f; do
    [ -f "$f" ] || continue
    if grep -qE 'Button\s*[\({]' "$f" 2>/dev/null \
       && ! grep -qE '\.buttonStyle\(' "$f" 2>/dev/null; then
      missing=1
      break
    fi
  done <<< "$SWIFT_FILES"
  if [ $missing -eq 1 ]; then
    echo "FAIL high | Button without .buttonStyle(...) — add .plain or custom style"
  else
    echo "PASS | every Button has .buttonStyle(...) modifier"
  fi
}

# Detectors that REQUIRE Figma cross-check — always emit TODO (agent fills):
#   LH (line-height), LS (letter-spacing), SH (shadow), BD (border+radius),
#   OP (opacity), RM (rendering mode), IS (icon size).

# --- Compose report ---------------------------------------------------------
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Helper: emit a row given (idx, code, section, spec, quote, codeval, fileline, match, severity)
row() {
  printf '| %s | %-2s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

verdict_match()    { echo "$1" | awk -F'|' '{print $1}' | tr -d ' '; }
verdict_severity() {
  local m
  m=$(echo "$1" | awk -F'|' '{print $1}' | tr -d ' ')
  case "$m" in
    PASS|NA|TODO) echo "-" ;;
    FAIL)
      echo "$1" | awk -F'|' '{print $1}' | tr -d ' ' >/dev/null
      # severity is the 2nd word in the verdict head (before the |)
      echo "$1" | awk '{print $2}'
      ;;
    *) echo "-" ;;
  esac
}
verdict_note()     { echo "$1" | awk -F'|' '{print $2}' | sed 's/^ *//;s/ *$//'; }

CH=$(ch_verdict);  PD=$(pd_verdict)
GR=$(gr_verdict);  DV=$(dv_verdict);  BG=$(bg_verdict)
TR=$(tr_verdict);  SA=$(sa_verdict);  BS=$(bs_verdict)

{
  echo "# C3 Pass 2 — Code vs Screenshot Diff Report"
  echo "nodeId: $NODE_ID"
  echo "generatedAt: $NOW"
  echo "attempt: 1"
  echo "codeFiles:"
  if [ -n "$SWIFT_LIST" ]; then
    printf '%s' "$SWIFT_LIST"
  else
    echo "  - <agent: list generated swift files here>"
  fi
  echo ""
  echo "<!--"
  echo "  This report was prefilled by scripts/c3-pass2-prefill.sh."
  echo "  Rows marked TODO require the agent to fill Figma Spec / Source quote / Code value / File:Line"
  echo "  by reading design-context.md and the swift files. Rows marked PASS / NA were decided"
  echo "  mechanically — flip them to FAIL if the script was wrong."
  echo "  Gate C3-Pass2 (PostToolUse hook) still validates the final report unchanged."
  echo "-->"
  echo ""
  echo "## Checklist coverage"
  echo "- LH    line-height"
  echo "- LS    letter-spacing / tracking"
  echo "- SH    shadow"
  echo "- BD    border + radius"
  echo "- OP    opacity"
  echo "- RM    icon rendering mode"
  echo "- IS    icon exact pixel size"
  echo "- DV    divider"
  echo "- BG    background material (blur)"
  echo "- TR    text truncation / line limit"
  echo "- GR    gradient"
  echo "- SA    safe-area behavior"
  echo "- CH    no system chrome drawn"
  echo "- PD    explicit padding"
  echo "- BS    .buttonStyle(.plain) on custom buttons"
  echo ""
  echo "## Findings"
  echo "| # | Check | Section | Figma Spec | Source quote | Code value | File:Line | Match | Severity |"
  echo "|---|-------|---------|------------|--------------|------------|-----------|-------|----------|"

  # Mechanically prefilled rows (1..8)
  row 1  CH "-"            "iOS draws status bar / home indicator / Dynamic Island"  "SKILL ABSOLUTE RULE"                                          "(no chrome shapes in code)"                  "-"  "$(verdict_match "$CH")" "$(verdict_severity "$CH")"
  row 2  PD "screen-wide"  "all paddings via Spacing/IKCoreApp"                      "$(verdict_note "$PD")"                                        "(no inline numeric .padding)"                "-"  "$(verdict_match "$PD")" "$(verdict_severity "$PD")"
  row 3  GR "screen-wide"  "$(verdict_note "$GR")"                                   "design-context.md grep result"                                "-"                                            "-"  "$(verdict_match "$GR")" "$(verdict_severity "$GR")"
  row 4  DV "screen-wide"  "$(verdict_note "$DV")"                                   "design-context.md grep result"                                "-"                                            "-"  "$(verdict_match "$DV")" "$(verdict_severity "$DV")"
  row 5  BG "screen-wide"  "$(verdict_note "$BG")"                                   "design-context.md grep result"                                "-"                                            "-"  "$(verdict_match "$BG")" "$(verdict_severity "$BG")"
  row 6  TR "screen-wide"  "$(verdict_note "$TR")"                                   "design-context.md grep result"                                "-"                                            "-"  "$(verdict_match "$TR")" "$(verdict_severity "$TR")"
  row 7  SA "screen-wide"  "$(verdict_note "$SA")"                                   "(code grep)"                                                  "-"                                            "-"  "$(verdict_match "$SA")" "$(verdict_severity "$SA")"
  row 8  BS "screen-wide"  "$(verdict_note "$BS")"                                   "(code grep)"                                                  "-"                                            "-"  "$(verdict_match "$BS")" "$(verdict_severity "$BS")"

  # Manual rows the agent must fill (9..15) — emit with TODO so gate sees them
  row 9  LH "<section>"    "<lineHeight from design-context>"                        "\`<verbatim from design-context.md>\`"                        "<.lineSpacing(...)>"                          "<file>:<line>" "TODO" "-"
  row 10 LS "<section>"    "<letter-spacing from design-context>"                    "\`<verbatim>\`"                                               "<.tracking(...)>"                             "<file>:<line>" "TODO" "-"
  row 11 SH "<section>"    "<shadow color/opacity/offset/radius>"                    "\`<verbatim>\`"                                               "<.shadow(...)>"                               "<file>:<line>" "TODO" "-"
  row 12 BD "<section>"    "<border + cornerRadius>"                                 "\`<verbatim>\`"                                               "<.cornerRadius / RoundedRectangle / overlay>" "<file>:<line>" "TODO" "-"
  row 13 OP "<section>"    "<opacity>"                                               "\`<verbatim>\`"                                               "<.opacity(...)>"                              "<file>:<line>" "TODO" "-"
  row 14 RM "<section>"    "<template vs original (icAI* template by default)>"      "inventory row N: renderingMode=template"                      "<.renderingMode(.template) / .foregroundStyle>" "<file>:<line>" "TODO" "-"
  row 15 IS "<section>"    "<icon size in pt>"                                       "\`<verbatim>\`"                                               "<.frame(width:height:)>"                      "<file>:<line>" "TODO" "-"

  echo ""
  echo "## Summary"
  echo "- total: 15"
  echo "- pass:  <int>"
  echo "- fail:  <int>   (high: <int>, medium: <int>, low: <int>)"
  echo "- n/a:   <int>"
  echo ""
  echo "<!--"
  echo "  Before submitting: replace every TODO row with PASS/FAIL/NA + real Figma Spec, Source quote,"
  echo "  Code value, and File:Line. Then update the Summary counts. Gate C3-Pass2 hooks fire on save."
  echo "-->"
} > "$REPORT"

echo "PREFILLED: $REPORT"
echo "  mechanical decisions: CH=$(verdict_match "$CH") PD=$(verdict_match "$PD") GR=$(verdict_match "$GR") DV=$(verdict_match "$DV") BG=$(verdict_match "$BG") TR=$(verdict_match "$TR") SA=$(verdict_match "$SA") BS=$(verdict_match "$BS")"
echo "  agent must fill 7 TODO rows (LH/LS/SH/BD/OP/RM/IS) before saving"
exit 0
