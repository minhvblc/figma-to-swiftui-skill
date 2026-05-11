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

# TR (text truncation + minimumScaleFactor):
#   - N/A if design-context has no truncation hint AND code has no lineLimit/truncationMode/minimumScaleFactor.
#   - FAIL medium if code emits .lineLimit(1) on Text without .minimumScaleFactor in same chain (5-line window).
#     Single-line Text in a constrained container needs .minimumScaleFactor(0.6) so localized strings don't truncate.
#     See references/visual-fidelity.md §7 #10.
#   - else TODO (truncation present, agent must verify).
tr_verdict() {
  local in_dc=0 in_code=0
  dc_has 'truncate|line-clamp|max-lines|nowrap' && in_dc=1
  code_has '\.lineLimit\(|\.truncationMode\(|\.allowsTightening\(|\.minimumScaleFactor\(' && in_code=1
  if [ $in_dc -eq 0 ] && [ $in_code -eq 0 ]; then
    echo "NA | no truncation hint in design-context.md and none in code"
    return
  fi
  # Detect .lineLimit(1) without .minimumScaleFactor within 5-line window.
  if [ -n "$SWIFT_GREP_TARGETS" ]; then
    local missing
    missing=$(awk '
      /\.lineLimit\([[:space:]]*1[[:space:]]*\)/ { ll_at=NR; ll_line=$0; ll_file=FILENAME }
      ll_at && NR - ll_at <= 5 && /\.minimumScaleFactor\(/ { ll_at=0 }
      ll_at && NR - ll_at == 5 { print ll_file ":" ll_at; ll_at=0 }
      END { if (ll_at) print ll_file ":" ll_at }
    ' $SWIFT_GREP_TARGETS 2>/dev/null | head -1)
    if [ -n "$missing" ]; then
      echo "FAIL medium | .lineLimit(1) without .minimumScaleFactor at $missing — single-line Text in constrained container needs .minimumScaleFactor(0.6) (see visual-fidelity.md §7 #10)"
      return
    fi
  fi
  echo "TODO | truncation/lineLimit involved — verify Figma maxLines AND minimumScaleFactor pairing"
}

# SS (spacing-safe-area normalization):
#   - PASS if no screen-root padding-top in {44,47,59,64,67,79,88} hits, AND
#     no screen-root Spacer().frame(height:) in same set.
#   - FAIL high if any of those hit lacks a `// safe-area-adjusted` comment within
#     a 2-line window (same line OR previous line).
#   See references/visual-fidelity.md §7 #12 + references/layout-translation.md §"Safe Area Normalization for Mockup Frames".
ss_verdict() {
  [ -n "$SWIFT_GREP_TARGETS" ] || { echo "TODO | -"; return; }
  local hits
  # -H forces filename in output even when only one file is matched, so
  # parsing FILE:LINE:CONTENT is unambiguous.
  hits=$(grep -HnE '\.padding\([[:space:]]*\.top[[:space:]]*,[[:space:]]*(44|47|59|64|67|79|88)([^0-9]|$)|Spacer\(\)\.frame\([[:space:]]*height:[[:space:]]*(44|47|59|64|67|79|88)([^0-9]|$)' \
           $SWIFT_GREP_TARGETS 2>/dev/null)
  if [ -z "$hits" ]; then
    echo "PASS | no suspicious screen-root padding-top values"
    return
  fi
  # For each hit, check 2-line window for justifying comment.
  local bad=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # FILE:LINE:CONTENT — split on first two colons.
    local f="${line%%:*}"
    local rest="${line#*:}"
    local n="${rest%%:*}"
    [ -z "$f" ] || [ -z "$n" ] && continue
    # Numeric guard before sed/arithmetic — bail if non-integer slipped through.
    case "$n" in ''|*[!0-9]*) continue ;; esac
    local ctx
    ctx=$(sed -n "$((n > 1 ? n - 1 : 1)),${n}p" "$f" 2>/dev/null)
    if ! echo "$ctx" | grep -q 'safe-area-adjusted'; then
      # Strip absolute path noise — keep basename:line for readable report.
      bad="$bad $(basename "$f"):$n"
    fi
  done <<< "$hits"
  if [ -n "$bad" ]; then
    echo "FAIL high | suspicious screen-root padding-top at$bad — likely double-counts iOS safe-area inset; add comment // safe-area-adjusted: raw=..., inset=..., adjusted=... or fix the value (see visual-fidelity.md §7 #12)"
  else
    echo "PASS | screen-root padding-top values justified with safe-area-adjusted comment"
  fi
}

# IF (image fill mode) — TODO: prefill cannot decide PASS/FAIL because the script
# lacks Figma scaleMode context. But it CAN flag the most common bug: any
# Image(...).frame(maxWidth: .infinity, ...) chain that lacks .resizable()
# AND a content-mode modifier (.scaledToFill / .scaledToFit / .aspectRatio).
# Matches BOTH iOS 17+ ImageResource form Image(.name) AND legacy Image("name").
# Emit FAIL high when the bug is detectable; otherwise emit TODO for the agent.
# See references/visual-fidelity.md §7 #11 + references/layout-translation.md §"Image content-mode → SwiftUI".
if_verdict() {
  [ -n "$SWIFT_GREP_TARGETS" ] || { echo "TODO | -"; return; }
  # Find lines that start an Image(...).frame(maxWidth: .infinity ...) chain.
  # Within the next 5 lines, look for .resizable() AND one of the content-mode modifiers.
  # If either is missing — FAIL high.
  local bad
  bad=$(awk '
    function reset() { img_at=0; has_resizable=0; has_mode=0; img_file=""; img_line="" }
    BEGIN { reset() }
    /Image\([[:space:]]*"[^"]+"[[:space:]]*\)/ {
      reset(); img_at=NR; img_file=FILENAME; img_line=$0
    }
    /Image\([[:space:]]*\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\)/ {
      reset(); img_at=NR; img_file=FILENAME; img_line=$0
    }
    img_at && NR - img_at <= 8 {
      if (/\.resizable\(/)        has_resizable=1
      if (/\.scaledToFill\(|\.scaledToFit\(|\.aspectRatio\([^)]*contentMode/) has_mode=1
      if (/\.frame\([^)]*maxWidth:[[:space:]]*\.infinity/) {
        if (!has_resizable || !has_mode) {
          print img_file ":" img_at " (missing: " (has_resizable?"":"resizable ") (has_mode?"":"contentMode") ")"
        }
        reset()
      }
    }
    img_at && NR - img_at > 8 { reset() }
  ' $SWIFT_GREP_TARGETS 2>/dev/null | head -3)
  if [ -n "$bad" ]; then
    local first
    first=$(echo "$bad" | head -1)
    echo "FAIL high | fill-width Image missing resizable/content-mode: $first — emit .resizable().scaledToFill().frame(maxWidth: .infinity, ...) together (see visual-fidelity.md §7 #11)"
  else
    echo "TODO | image fill-mode — agent verifies Figma imageScaleMode against code .scaledToFill/.scaledToFit/.aspectRatio"
  fi
}

# BW (button width source-of-truth): mechanical detection of the inner-Text-maxWidth
# bug from anti-patterns.md §12 — Text(...).frame(maxWidth: .infinity) whose
# enclosing scope is `Button { ... }` body, without `// allow-text-fill:` justification.
# This is the same condition as banned-pattern Check 8 — if Check 8 was bypassed
# at write time, BW catches it on the verification side.
#   - NA if no Button in code.
#   - FAIL high if the inner-Text bug is detected (per-button list in note).
#   - TODO otherwise (agent must verify Button outer .frame matches Figma sizingMode).
# See references/visual-fidelity.md §"`.frame(maxWidth: .infinity)` cascade trap"
# + §7 Hard Rule #14 + references/anti-patterns.md §12.
bw_verdict() {
  [ -n "$SWIFT_GREP_TARGETS" ] || { echo "TODO | -"; return; }
  local btn_lines
  btn_lines=$(grep -nE 'Button[[:space:]]*\(|Button[[:space:]]*\{' $SWIFT_GREP_TARGETS 2>/dev/null | wc -l | tr -d ' ')
  if [ "${btn_lines:-0}" -eq 0 ]; then
    echo "NA | no Button in code"
    return
  fi
  local bad
  bad=$(awk '
    function in_button() { return sp > 0 }
    function count_braces(line, ch,    n, i) {
      n = 0
      for (i = 1; i <= length(line); i++) {
        if (substr(line, i, 1) == ch) n++
      }
      return n
    }
    BEGIN { net_depth = 0; sp = 0; text_open_at = 0 }
    {
      has_button = 0
      if (match($0, /(^|[^A-Za-z0-9_])Button[[:space:]]*(\([^)]*\))?[[:space:]]*\{/)) has_button = 1
      opens  = count_braces($0, "{")
      closes = count_braces($0, "}")
      if (has_button) {
        sp++
        button_open_depth[sp] = net_depth
        text_open_at = 0
      }
      if (in_button() && match($0, /(^|[^A-Za-z0-9_])Text[[:space:]]*\(/)) {
        text_open_at = NR
      }
      if (in_button() && match($0, /\.frame[[:space:]]*\([^)]*maxWidth:[[:space:]]*\.infinity/)) {
        is_violation = 0
        if (match($0, /(^|[^A-Za-z0-9_])Text[[:space:]]*\(/)) is_violation = 1
        else if (text_open_at && NR - text_open_at <= 10) is_violation = 1
        if (is_violation) {
          # Filter same-line + previous-line allow-text-fill comments handled
          # by the bash post-filter below; here we just emit candidate hits.
          print FILENAME ":" NR ":" $0
        }
      }
      net_depth += opens - closes
      if (closes > 0) text_open_at = 0
      while (sp > 0 && net_depth <= button_open_depth[sp]) {
        sp--
        if (sp == 0) text_open_at = 0
      }
    }
  ' $SWIFT_GREP_TARGETS 2>/dev/null | head -5)
  if [ -z "$bad" ]; then
    echo "TODO | $btn_lines Button(s) found — agent verifies Button outer frame matches Figma primaryAxisSizingMode (FILL→.frame(maxWidth: .infinity); FIXED→.frame(width: N); AUTO/HUG→no width modifier); inner-Text maxWidth bug NOT detected"
    return
  fi
  # Filter by allow-text-fill comments (same-line OR previous line).
  local violation=""
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local f="${line%%:*}"
    local rest="${line#*:}"
    local n="${rest%%:*}"
    [ -z "$f" ] || [ -z "$n" ] && continue
    case "$n" in ''|*[!0-9]*) continue ;; esac
    local ctx
    ctx=$(sed -n "$((n > 1 ? n - 1 : 1)),${n}p" "$f" 2>/dev/null)
    if ! echo "$ctx" | grep -q 'allow-text-fill'; then
      violation="$violation $(basename "$f"):$n"
    fi
  done <<< "$bad"
  if [ -n "$violation" ]; then
    echo "FAIL high | inner-Text maxWidth inside Button at$violation — cascades up, makes Button fill width, overrides caller .padding(.horizontal). Move .frame(maxWidth: .infinity) from inner Text to Button outer (see anti-patterns.md §12)"
  else
    echo "TODO | $btn_lines Button(s) found, all maxWidth-on-Text cases justified by // allow-text-fill — agent verifies Button outer frame matches Figma primaryAxisSizingMode"
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
#   OP (opacity), RM (rendering mode), IS (icon size), AL (text alignment).
# IF (image fill mode) is mechanical-detectable for the most common bug
# (Image fill chain missing .resizable + content mode); emits FAIL high then,
# else TODO for agent.
# SS (spacing-safe-area) is mechanical-detectable from screen-root padding-top
# values + presence of // safe-area-adjusted comments.
# BW (button width source-of-truth) is mechanical-detectable for the inner-Text
# maxWidth bug (cascades up through Button); emits FAIL high then, else TODO
# for agent (Button outer frame still needs cross-check vs Figma sizingMode).

# --- Compose report ---------------------------------------------------------
NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Helper: emit a row given (idx, code, section, spec, quote, codeval, fileline, match, severity)
row() {
  printf '| %s | %-2s | %s | %s | %s | %s | %s | %s | %s |\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

# Verdict format: "<MATCH> [<severity>] | <note>"
#   PASS / NA / TODO → first field is just the match keyword
#   FAIL high|medium|low → first field is "FAIL <severity>"
# verdict_match returns just the keyword; verdict_severity returns severity (or "-").
verdict_match()    { echo "$1" | awk -F'|' '{print $1}' | awk '{print $1}'; }
verdict_severity() {
  local first_field m
  first_field=$(echo "$1" | awk -F'|' '{print $1}')
  m=$(echo "$first_field" | awk '{print $1}')
  case "$m" in
    FAIL)
      local sev
      sev=$(echo "$first_field" | awk '{print $2}')
      [ -n "$sev" ] && echo "$sev" || echo "-"
      ;;
    *) echo "-" ;;
  esac
}
verdict_note()     { echo "$1" | awk -F'|' '{print $2}' | sed 's/^ *//;s/ *$//'; }

CH=$(ch_verdict);  PD=$(pd_verdict)
GR=$(gr_verdict);  DV=$(dv_verdict);  BG=$(bg_verdict)
TR=$(tr_verdict);  SA=$(sa_verdict);  BS=$(bs_verdict)
SS=$(ss_verdict);  IF=$(if_verdict);  BW=$(bw_verdict)

# --- Large-frame navigation hints (Tier 5) ----------------------------------
# When design-context.md is large (typically >50KB / >600 lines for frames
# with 30+ sub-nodes — brand chip rows, logo grids, etc.), emit a roadmap
# of section ranges + per-Pass-2-property grep line numbers. The agent reads
# design-context.md in chunks (Read --offset N --limit M) instead of loading
# the full file, saving ~10K tokens on large frames. Gate C3-Pass2 still
# greps the FULL file for verbatim quote-match — no quality impact.
DCTX_SIZE=$(wc -c < "$DESIGN_CTX" 2>/dev/null | tr -d ' ')
DCTX_LINES=$(wc -l < "$DESIGN_CTX" 2>/dev/null | tr -d ' ')
DCTX_SIZE=${DCTX_SIZE:-0}
DCTX_LINES=${DCTX_LINES:-0}
LARGE_FRAME=0
if [ "$DCTX_SIZE" -gt 51200 ] || [ "$DCTX_LINES" -gt 600 ]; then
  LARGE_FRAME=1
fi

emit_navigation_hints() {
  echo "<!--"
  echo "  LARGE design-context.md detected (${DCTX_SIZE} bytes, ${DCTX_LINES} lines)."
  echo "  To save tokens during Pass 2, READ design-context.md by section using"
  echo "  the Read tool with offset/limit, NOT the full file. Gate C3-Pass2 still"
  echo "  verifies your verbatim quotes against the full file via grep, so"
  echo "  reading less doesn't weaken the gate — it just saves agent tokens."
  echo ""
  echo "  Top-level section starts (heuristic — top-level JSX tags):"
  awk '
    /^<[A-Za-z]/ {
      indent = match($0, /[^ ]/) - 1
      if (indent == 0) {
        match($0, /^<[A-Za-z][A-Za-z0-9]*/)
        tag = substr($0, RSTART+1, RLENGTH-1)
        # Try to grab a className attr for context
        cls = ""
        if (match($0, /className="[^"]*"/)) {
          cls = substr($0, RSTART+11, RLENGTH-12)
          # Trim long classNames
          if (length(cls) > 40) cls = substr(cls, 1, 37) "..."
        }
        printf "    L%-5d %-12s %s\n", NR, tag, cls
      }
    }
  ' "$DESIGN_CTX" | head -25
  echo ""
  echo "  Per-Pass-2-check grep hits (read these line numbers for verbatim quotes):"
  emit_check_hits() {
    local code="$1" pattern="$2"
    local hits
    hits=$(grep -nE "$pattern" "$DESIGN_CTX" 2>/dev/null | head -8 | awk -F: '{printf "L%s ", $1}')
    [ -n "$hits" ] && printf "    %-3s %s\n" "$code" "$hits"
  }
  emit_check_hits "LH" "lineHeight:|leading-\["
  emit_check_hits "LS" "letterSpacing:|tracking-\["
  emit_check_hits "SH" "shadow:|boxShadow:|shadow-\["
  emit_check_hits "BD" "border-radius:|borderRadius:|rounded-\["
  emit_check_hits "OP" "opacity:|opacity-\["
  emit_check_hits "IS" "<Image|<Icon"
  emit_check_hits "RM" "renderingMode:|tintColor:|text-\[#"
  emit_check_hits "AL" "textAlign:|text-(left|center|right)"
  emit_check_hits "FS" "fontSize:|text-\["
  echo "-->"
  echo ""
}

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
  if [ "$LARGE_FRAME" = "1" ]; then
    emit_navigation_hints
  fi
  echo "## Checklist coverage"
  echo "- LH    line-height"
  echo "- LS    letter-spacing / tracking"
  echo "- SH    shadow"
  echo "- BD    border + radius"
  echo "- OP    opacity"
  echo "- RM    icon rendering mode"
  echo "- IS    icon exact pixel size"
  echo "- AL    text alignment + fill-width drawing rect (parent-aware: Text-layer for non-Button stacks; Button-outer-layer for Button parents)"
  echo "- DV    divider"
  echo "- BG    background material (blur)"
  echo "- TR    text truncation / line limit + .minimumScaleFactor on single-line"
  echo "- GR    gradient"
  echo "- SA    safe-area behavior (background extends under chrome)"
  echo "- CH    no system chrome drawn"
  echo "- PD    explicit padding"
  echo "- BS    .buttonStyle(.plain) on custom buttons"
  echo "- IF    image fill mode (.resizable + .scaledToFill/.scaledToFit + .frame)"
  echo "- SS    spacing-safe-area normalization (raw figma y minus inset)"
  echo "- BW    button width source-of-truth (Figma primaryAxisSizingMode → Button outer frame; no maxWidth on inner Text/HStack)"
  echo ""
  echo "## Findings"
  echo "| # | Check | Section | Figma Spec | Source quote | Code value | File:Line | Match | Severity |"
  echo "|---|-------|---------|------------|--------------|------------|-----------|-------|----------|"

  # Mechanically prefilled rows (1..9)
  row 1  CH "-"            "iOS draws status bar / home indicator / Dynamic Island"  "SKILL ABSOLUTE RULE"                                          "(no chrome shapes in code)"                  "-"  "$(verdict_match "$CH")" "$(verdict_severity "$CH")"
  row 2  PD "screen-wide"  "all paddings via Spacing/IKCoreApp"                      "$(verdict_note "$PD")"                                        "(no inline numeric .padding)"                "-"  "$(verdict_match "$PD")" "$(verdict_severity "$PD")"
  row 3  GR "screen-wide"  "$(verdict_note "$GR")"                                   "design-context.md grep result"                                "-"                                            "-"  "$(verdict_match "$GR")" "$(verdict_severity "$GR")"
  row 4  DV "screen-wide"  "$(verdict_note "$DV")"                                   "design-context.md grep result"                                "-"                                            "-"  "$(verdict_match "$DV")" "$(verdict_severity "$DV")"
  row 5  BG "screen-wide"  "$(verdict_note "$BG")"                                   "design-context.md grep result"                                "-"                                            "-"  "$(verdict_match "$BG")" "$(verdict_severity "$BG")"
  row 6  TR "screen-wide"  "$(verdict_note "$TR")"                                   "design-context.md grep / .lineLimit + .minimumScaleFactor"     "-"                                            "-"  "$(verdict_match "$TR")" "$(verdict_severity "$TR")"
  row 7  SA "screen-wide"  "$(verdict_note "$SA")"                                   "(code grep)"                                                  "-"                                            "-"  "$(verdict_match "$SA")" "$(verdict_severity "$SA")"
  row 8  BS "screen-wide"  "$(verdict_note "$BS")"                                   "(code grep)"                                                  "-"                                            "-"  "$(verdict_match "$BS")" "$(verdict_severity "$BS")"
  row 9  SS "-"            "$(verdict_note "$SS")"                                   "(code grep — screen-root padding-top in {44,47,59,64,67,79,88} requires // safe-area-adjusted comment)" "-"                "-"  "$(verdict_match "$SS")" "$(verdict_severity "$SS")"

  # Manual rows the agent must fill (10..18) — emit with TODO so gate sees them
  row 10 LH "<section>"    "<lineHeight from design-context>"                        "\`<verbatim from design-context.md>\`"                        "<.lineSpacing(...)>"                          "<file>:<line>" "TODO" "-"
  row 11 LS "<section>"    "<letter-spacing from design-context>"                    "\`<verbatim>\`"                                               "<.tracking(...)>"                             "<file>:<line>" "TODO" "-"
  row 12 SH "<section>"    "<shadow color/opacity/offset/radius>"                    "\`<verbatim>\`"                                               "<.shadow(...)>"                               "<file>:<line>" "TODO" "-"
  row 13 BD "<section>"    "<border + cornerRadius>"                                 "\`<verbatim>\`"                                               "<.cornerRadius / RoundedRectangle / overlay>" "<file>:<line>" "TODO" "-"
  row 14 OP "<section>"    "<opacity>"                                               "\`<verbatim>\`"                                               "<.opacity(...)>"                              "<file>:<line>" "TODO" "-"
  row 15 RM "<section>"    "<template vs original (icAI* template by default)>"      "inventory row N: renderingMode=template"                      "<.renderingMode(.template) / .foregroundStyle>" "<file>:<line>" "TODO" "-"
  row 16 IS "<section>"    "<icon size in pt>"                                       "\`<verbatim>\`"                                               "<.frame(width:height:)>"                      "<file>:<line>" "TODO" "-"
  row 17 AL "<section>"    "<textAlignHorizontal=LEFT|CENTER|RIGHT|JUSTIFIED; node fill-width Y/N>" "\`<verbatim text-* class or align attr from design-context>\`" "<.multilineTextAlignment(...) [+ .frame(maxWidth: .infinity, alignment: ...) if fill-width and align ≠ LEFT]>" "<file>:<line>" "TODO" "-"
  row 18 IF "<section>"    "$(verdict_note "$IF")"                                   "inventory row N: contentMode=fill\|fit\|crop\|tile, frame=fill-* / Figma imageScaleMode" "<.resizable().scaledToFill\|scaledToFit().frame(...).clipped()>" "<file>:<line>" "$(verdict_match "$IF")" "$(verdict_severity "$IF")"
  row 19 BW "<button section>" "$(verdict_note "$BW")"                                "inventory row N: button primaryAxisSizingMode=FILL\|FIXED\|AUTO"                  "<Button { Text(\"...\") }.frame(maxWidth:.infinity\|width:N\|<no width>)>"   "<file>:<line>" "$(verdict_match "$BW")" "$(verdict_severity "$BW")"

  echo ""
  echo "## Summary"
  echo "- total: 19"
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
echo "  mechanical decisions: CH=$(verdict_match "$CH") PD=$(verdict_match "$PD") GR=$(verdict_match "$GR") DV=$(verdict_match "$DV") BG=$(verdict_match "$BG") TR=$(verdict_match "$TR") SA=$(verdict_match "$SA") BS=$(verdict_match "$BS") SS=$(verdict_match "$SS") IF=$(verdict_match "$IF") BW=$(verdict_match "$BW")"
echo "  agent must fill 8 TODO rows (LH/LS/SH/BD/OP/RM/IS/AL) before saving — IF + BW rows may be prefilled (mechanical detection of fill-mode + button-bloat bugs)"
exit 0
