#!/usr/bin/env bash
# PreToolUse hook for Write/Edit on *.swift — block content BEFORE it lands.
#
# Catches the four most common ABSOLUTE RULE violations as the agent is about
# to write them, instead of relying on c6-asset-completeness.sh / c7-no-system-chrome.sh
# being run after the fact (which the agent often skips).
#
# Banned patterns:
#
#   1. Image(systemName: "<sym>")  outside the allow-list, with no
#      `// allow-systemName:` opt-in comment on the same/previous line.
#      Allow-list (no comment required):
#        chevron.backward, chevron.left, chevron.right, chevron.up, chevron.down
#        square.and.arrow.up
#        xmark.circle.fill
#        keyboard*
#
#   2. iOS system-chrome redraws:
#        Text("9:41")           — status-bar clock
#        FakeStatusBar / DynamicIslandView / NotchView / HomeIndicator structs
#        Capsule()...frame(...height: 1..6...)  — home-indicator lookalike
#        Image(systemName: "wifi" | "battery.*" | "cellularbars" | "antenna.*")
#
#   3. Hand-drawn substitutes for Figma icons (heuristic only, warn):
#        Text("G") / Text("F") / Text("Y") inside a frame ≤ 32pt — letter-as-logo
#        Path { ... }.stroke(...) / .fill(...) standing alone (not inside a known shape extension)
#
#   4. Text(...).frame(width: <num>) without `// Figma fixed-width:` justification
#      Reading Figma's measured visual width on a hug-mode Text and emitting
#      .frame(width: 200) ships truncation as soon as content grows. Default is
#      hug (no frame) or fill (.frame(maxWidth: .infinity)). See visual-fidelity.md
#      §7 #9 + anti-patterns.md §8.
#
#   5. Screen-root .padding(.top, 44|47|59|64|67|79|88) without
#      `// safe-area-adjusted:` comment — likely double-counts iOS safe-area inset
#      (Figma frame includes status-bar mockup; raw Figma y already accounts for
#      it; SwiftUI then adds another inset). See visual-fidelity.md §7 #12 +
#      anti-patterns.md §9. Same set checked on Spacer().frame(height:).
#
#   6. Image("...").frame(maxWidth: .infinity, ...) chain missing both
#      .resizable() AND a content-mode modifier (.scaledToFill / .scaledToFit /
#      .aspectRatio(_:contentMode:)) — image stays at intrinsic size leaving
#      blank gap, OR distorts anisotropically. See visual-fidelity.md §7 #11 +
#      anti-patterns.md §10.
#
#   7. Device-frame bezel — `.cornerRadius(N)` / `.clipShape(.rect(cornerRadius: N))` /
#      `.clipShape(RoundedRectangle(cornerRadius: N))` / any `cornerRadius: N`
#      with N ≥ 30, without `// allow-screen-corner-radius:` justification.
#      iPhone bezel is ~47pt (non-Pro) / ~55pt (Pro / Pro Max) and rendered by
#      hardware; UI corner radii rarely exceed ~24pt. Threshold 30pt blocks the
#      "I copied the rounded outline of the entire frame onto the root view"
#      bug while leaving room for legit hero-card radii (≤ 24pt) plus an explicit
#      escape comment for the rare exceptions. See visual-fidelity.md §7 #13 +
#      anti-patterns.md §11.
#
#   8. Button-bloat from inner Text maxWidth — `Text(...).frame(maxWidth: .infinity)`
#      whose enclosing scope is a `Button { ... }` body, without
#      `// allow-text-fill:` justification. SwiftUI propagates fill-width
#      requests outward; a Text or HStack inside a Button asking for fill
#      makes the Button itself fill the available width, overriding the
#      caller's `.padding(.horizontal, N)`. Visual result: button extends
#      edge-to-edge ignoring the designer's side margins (Figma showed a
#      343pt button on a 393pt iPhone; simulator shows 393pt button). The
#      width modifier MUST live on the Button's OUTER frame, sourced from
#      the Button node's own Figma `primaryAxisSizingMode`. See
#      visual-fidelity.md §7 #14 + §"`.frame(maxWidth: .infinity)` cascade trap"
#      + anti-patterns.md §12 + layout-translation.md §"Button sizing-mode → SwiftUI".
#
# Only enforces inside a figma task — i.e. there's a .figma-cache/ in the file's
# tree (walking up). Files marked with `_NoFigma_` segment in their path bypass.
#
# Exit codes:
#   0 — allow
#   2 — block (stderr is shown to Claude as a system reminder)

set -uo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

# Pull content the agent is about to write. Write tool: tool_input.content.
# Edit tool: tool_input.new_string. Anything else: skip.
case "$TOOL" in
  Write)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')
    ;;
  Edit)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty')
    ;;
  *)
    exit 0
    ;;
esac

# Only act on *.swift writes/edits.
case "$FILE_PATH" in
  *.swift) ;;
  *) exit 0 ;;
esac

# Escape hatch — file path opted out.
case "$FILE_PATH" in
  *_NoFigma_*) exit 0 ;;
esac

# Only enforce inside a figma task (walk up looking for .figma-cache).
DIR=$(dirname "$FILE_PATH" 2>/dev/null || echo "")
FIGMA_TASK=0
while [ -n "$DIR" ] && [ "$DIR" != "/" ]; do
  if [ -d "$DIR/.figma-cache" ]; then
    FIGMA_TASK=1
    break
  fi
  DIR=$(dirname "$DIR")
done

if [ "$FIGMA_TASK" = "0" ] && [ -d "$PWD/.figma-cache" ]; then
  FIGMA_TASK=1
fi

[ "$FIGMA_TASK" = "0" ] && exit 0

# Empty content (rare — Edit with empty new_string is delete) → allow.
[ -z "$CONTENT" ] && exit 0

# Stash content in a temp file so we can grep with line numbers.
TMP=$(mktemp -t figma-banned.XXXXXX) || exit 0
trap 'rm -f "$TMP"' EXIT
printf '%s' "$CONTENT" > "$TMP"

VIOLATIONS=""
add_violation() {
  VIOLATIONS+="  $1\n"
}

# ─── Check 1: Image(systemName: ...) outside allow-list ────────────────────────
ALLOW_REGEX='^(chevron\.(backward|left|right|up|down)|square\.and\.arrow\.up|xmark\.circle\.fill|keyboard.*)$'

while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  symbol=$(printf '%s\n' "$content" | sed -nE 's/.*systemName:[[:space:]]*"([^"]+)".*/\1/p' | head -1)

  # Same-line allow comment?
  if printf '%s' "$content" | grep -q '// allow-systemName:'; then
    continue
  fi
  # Previous-line allow comment?
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    if printf '%s' "$prev" | grep -q '// allow-systemName:'; then
      continue
    fi
  fi

  # Allow-list match?
  if [ -n "$symbol" ] && [[ "$symbol" =~ $ALLOW_REGEX ]]; then
    continue
  fi

  add_violation "line $lineno: Image(systemName: \"${symbol:-?}\") — Figma asset expected, not SF Symbol"
done < <(grep -nE 'Image\(\s*systemName:' "$TMP" 2>/dev/null || true)

# ─── Check 2: iOS system chrome redraws ────────────────────────────────────────

# 2a. Status-bar clock literal
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: Text(\"9:41\") — status bar is rendered by iOS, do not redraw"
done < <(grep -nE 'Text\(\s*"9:4[0-9]"' "$TMP" 2>/dev/null || true)

# 2b. Status-bar SF Symbols (wifi/battery/cellularbars/antenna). Honor allow comment.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  symbol=$(printf '%s\n' "$content" | sed -nE 's/.*systemName:[[:space:]]*"([^"]+)".*/\1/p' | head -1)

  # Same-line allow comment?
  if printf '%s' "$content" | grep -q '// allow-systemName:'; then
    continue
  fi
  # Previous-line allow comment?
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    if printf '%s' "$prev" | grep -q '// allow-systemName:'; then
      continue
    fi
  fi

  add_violation "line $lineno: Image(systemName: \"$symbol\") — status-bar glyph, iOS renders it"
done < <(grep -nE 'Image\([[:space:]]*systemName:[[:space:]]*"(wifi|battery|cellularbars|antenna)' "$TMP" 2>/dev/null || true)

# 2c. Banned struct names (FakeStatusBar / HomeIndicator / NotchView / DynamicIslandView)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  match=$(printf '%s\n' "${line#*:}" | grep -oE '(FakeStatusBar|HomeIndicator|NotchView|DynamicIslandView)' | head -1)
  add_violation "line $lineno: '$match' — iOS renders system chrome, custom struct redrawing it is banned"
done < <(grep -nE '\b(struct|class)\s+(FakeStatusBar|HomeIndicator|NotchView|DynamicIslandView)\b' "$TMP" 2>/dev/null || true)

# 2d. Home-indicator capsule lookalike. Two heuristics combined:
#   (a) single line: `Capsule(...)...frame(...height: 1..6...)`
#   (b) multi-line:  `Capsule(...)` followed within 3 lines by `.frame(...height: 1..6...)`
# BSD awk on macOS doesn't support \s — use [[:space:]]* instead.

# (a) single-line — grep with PCRE-friendly extended regex.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: Capsule() with height≤6pt — looks like a home-indicator redraw, iOS renders it"
done < <(grep -nE 'Capsule[[:space:]]*\(.*frame[[:space:]]*\([^)]*height:[[:space:]]*[1-6]([^0-9]|$)' "$TMP" 2>/dev/null || true)

# (b) multi-line — awk with POSIX-only regex.
HI_HITS=$(awk '
  /Capsule[[:space:]]*\(/ { capsule_at=NR }
  /frame[[:space:]]*\([^)]*height:[[:space:]]*[1-6]([^0-9]|$)/ {
    if (capsule_at && NR != capsule_at && NR - capsule_at <= 3) {
      print NR ": " $0
    }
  }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: Capsule() within 3 lines of small-height frame — likely home-indicator redraw"
done <<< "$HI_HITS"

# ─── Check 3: hand-drawn letter-as-logo (heuristic) ────────────────────────────
# Pattern: Text("X") where X is single uppercase letter, near `.frame(width: ≤32`.
# Likely a logo placeholder. Warn but don't block — could be legitimate initial display.
LETTER_HITS=$(awk '
  /Text\([[:space:]]*"[A-Z]"[[:space:]]*\)/ { letter_at=NR; letter_line=$0 }
  /frame[[:space:]]*\([^)]*width:[[:space:]]*([0-9]|[12][0-9]|3[0-2])([^0-9]|$)/ {
    if (letter_at && NR - letter_at <= 4) {
      print letter_at ": " letter_line " (frame at " NR ")"
      letter_at=0
    }
  }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: Text(\"<letter>\") near small frame — possible letter-as-logo substitution, use Figma asset"
done <<< "$LETTER_HITS"

# ─── Check 4: Text(...).frame(width: <num>) without justification ──────────────
# Detects Text("...") followed within 5 lines by .frame(width: <number>) where
# no `// Figma fixed-width:` comment is on the same line OR within a 2-line
# window. Banned by visual-fidelity.md §7 #9 + anti-patterns.md §8.
#
# Heuristic: a Text(...) construction ANYWHERE before a .frame(width: <num>)
# within the next 5 lines — but avoid false positives by also requiring no
# `Image\(` or `Color\(` between them (those frames are legitimate).
TXTW_HITS=$(awk '
  function reset() { txt_at=0; txt_line=""; saw_other=0 }
  BEGIN { reset() }
  # Handle Text(...) — start a fresh window. Do NOT use `next` so frame check
  # on the SAME line can also fire (the most common case is Text("x").frame(width:)
  # chained on one line).
  /Text\(/ {
    reset()
    txt_at=NR; txt_line=$0
  }
  # Track non-Text constructs that own legitimate fixed widths (Image, Color, ...).
  # Skip the Text bookkeeping when we see those so the frame check below does
  # NOT misattribute their widths to the Text. Note: Text does not contain
  # Image/Color/etc., so this rule never fires on the Text line itself.
  txt_at && /Image\(|Color\(|RoundedRectangle\(|Rectangle\(|Capsule\(|Circle\(|Ellipse\(|Spacer\(|Divider\(/ {
    saw_other=1
  }
  # The frame(width: ...) test fires on every line within a 5-line window after
  # Text(...), INCLUDING the same line (because we did not `next` above).
  txt_at && /\.frame\([[:space:]]*width:[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*[,)]/ {
    if (saw_other) { reset(); next }
    print NR ": " $0 " (Text at " txt_at ")"
    reset()
  }
  txt_at && NR - txt_at > 5 { reset() }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  # Same-line allow comment?
  if printf '%s' "$content" | grep -q '// Figma fixed-width:'; then
    continue
  fi
  # Previous-line allow comment?
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    if printf '%s' "$prev" | grep -q '// Figma fixed-width:'; then
      continue
    fi
  fi
  add_violation "line $lineno: Text(...).frame(width: ...) without // Figma fixed-width: comment — Text default is hug or fill, never numeric width (anti-patterns.md §8)"
done <<< "$TXTW_HITS"

# ─── Check 5: padding(.top, N) double-counting safe area ───────────────────────
# Suspicious values: 44, 47, 59, 64, 67, 79, 88. Same set on Spacer().frame(height:).
# Allow when `// safe-area-adjusted:` comment is on same line or previous line.
SAFE_HITS=$(grep -nE '\.padding\([[:space:]]*\.top[[:space:]]*,[[:space:]]*(44|47|59|64|67|79|88)([^0-9]|$)|Spacer\(\)\.frame\([[:space:]]*height:[[:space:]]*(44|47|59|64|67|79|88)([^0-9]|$)' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  # Same-line allow comment?
  if printf '%s' "$content" | grep -q '// safe-area-adjusted'; then
    continue
  fi
  # Previous-line allow comment?
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    if printf '%s' "$prev" | grep -q '// safe-area-adjusted'; then
      continue
    fi
  fi
  add_violation "line $lineno: suspicious safe-area-sized padding/spacer value — likely double-counts iOS inset; add // safe-area-adjusted: raw=..., inset=..., adjusted=... or fix the math (anti-patterns.md §9)"
done <<< "$SAFE_HITS"

# ─── Check 6: Image("...").frame(maxWidth: .infinity) chain missing resizable+contentMode ───
# Walk Image(...) constructions; within next 8 lines, look for .frame(maxWidth: .infinity).
# When seen, verify .resizable AND content-mode (.scaledToFill / .scaledToFit /
# .aspectRatio(_:contentMode:)) appear in the same 8-line window. Missing either → violation.
# Image(systemName:) is excluded — already handled by check 1 + chrome rules.
IMGFILL_HITS=$(awk '
  function reset() { img_at=0; img_line=""; has_resizable=0; has_mode=0 }
  BEGIN { reset() }
  /Image\([[:space:]]*"[^"]+"[[:space:]]*\)/ {
    reset()
    img_at=NR; img_line=$0
  }
  img_at && NR - img_at <= 8 {
    if (/\.resizable\(/)        has_resizable=1
    if (/\.scaledToFill\(|\.scaledToFit\(|\.aspectRatio\([^)]*contentMode/) has_mode=1
    if (/\.frame\([^)]*maxWidth:[[:space:]]*\.infinity/) {
      missing=""
      if (!has_resizable) missing=missing " resizable"
      if (!has_mode)      missing=missing " contentMode"
      if (missing != "") {
        print img_at ": " img_line " (missing:" missing ", frame at " NR ")"
      }
      reset()
    }
  }
  img_at && NR - img_at > 8 { reset() }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: fill-width Image missing .resizable() and/or content-mode modifier — emit .resizable().scaledToFill().frame(maxWidth: .infinity, ...).clipped() together (anti-patterns.md §10)"
done <<< "$IMGFILL_HITS"

# ─── Check 8: Text(...).frame(maxWidth: .infinity) inside Button { ... } ──────
# SwiftUI propagates fill-width requests outward — a Text inside a Button asking
# for maxWidth: .infinity makes the Button itself fill the available width, which
# overrides the caller's `.padding(.horizontal, N)`. Width modifier MUST live on
# the Button's OUTER frame, sourced from the Button's own Figma primaryAxisSizingMode.
# Allow `// allow-text-fill: <reason>` on same line OR previous line.
# Multi-line modifier chains (Text on one line, .frame on a chained line within
# 10 lines) are caught by tracking text_open_at. A `}` between Text and .frame
# breaks the chain (the .frame is on whatever just closed, not on the Text).
# Brace-depth tracking via a stack pops the Button when net_depth returns to its
# threshold. BSD awk on macOS lacks \< (word boundary) — use [^A-Za-z0-9_] guard.
BTNFILL_HITS=$(awk '
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
        print NR ":" $0
      }
    }
    net_depth += opens - closes
    if (closes > 0) text_open_at = 0
    while (sp > 0 && net_depth <= button_open_depth[sp]) {
      sp--
      if (sp == 0) text_open_at = 0
    }
  }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  # Same-line allow comment?
  if printf '%s' "$content" | grep -q '// *allow-text-fill'; then
    continue
  fi
  # Previous-line allow comment?
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    if printf '%s' "$prev" | grep -q '// *allow-text-fill'; then
      continue
    fi
  fi
  add_violation "line $lineno: Text(...).frame(maxWidth: .infinity) inside Button — cascades up, makes the Button fill width and overrides caller .padding(.horizontal). Move maxWidth to Button outer frame OR add // allow-text-fill: <reason> (anti-patterns.md §12)"
done <<< "$BTNFILL_HITS"

# ─── Check 7: device-frame bezel — cornerRadius ≥ 30 without justification ─────
# Catches `.cornerRadius(N)`, `.clipShape(.rect(cornerRadius: N))`,
# `.clipShape(RoundedRectangle(cornerRadius: N))`, and bare
# `RoundedRectangle(cornerRadius: N)` literals where N ≥ 30. iPhone bezel is
# ~47pt (non-Pro) / ~55pt (Pro / Pro Max); UI corner radii rarely exceed ~24pt.
# Allow `// allow-screen-corner-radius: <reason>` on same line OR previous line.
BEZEL_HITS=$(awk '
  {
    val = -1
    if (match($0, /\.cornerRadius[[:space:]]*\([[:space:]]*[0-9]+/)) {
      chunk = substr($0, RSTART, RLENGTH)
      if (match(chunk, /[0-9]+/)) val = substr(chunk, RSTART, RLENGTH) + 0
    } else if (match($0, /cornerRadius:[[:space:]]*[0-9]+/)) {
      chunk = substr($0, RSTART, RLENGTH)
      if (match(chunk, /[0-9]+/)) val = substr(chunk, RSTART, RLENGTH) + 0
    }
    if (val >= 30) {
      print NR ":" val ":" $0
    }
  }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  rest="${line#*:}"
  val="${rest%%:*}"
  content="${rest#*:}"
  # Same-line allow comment?
  if printf '%s' "$content" | grep -q '// *allow-screen-corner-radius:'; then
    continue
  fi
  # Previous-line allow comment?
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    if printf '%s' "$prev" | grep -q '// *allow-screen-corner-radius:'; then
      continue
    fi
  fi
  add_violation "line $lineno: cornerRadius=${val}pt ≥ 30 — likely mimicking the iPhone bezel (hardware renders it). Remove from screen-root, OR add // allow-screen-corner-radius: <reason> if a presented sheet / inner card legitimately needs ≥ 30pt (anti-patterns.md §11)"
done <<< "$BEZEL_HITS"

# Done.
if [ -z "$VIOLATIONS" ]; then
  exit 0
fi

{
  echo "BLOCKED: figma-to-swiftui banned-pattern detector"
  echo ""
  echo "File: $FILE_PATH"
  echo "Tool: $TOOL"
  echo ""
  echo "Violations in pending content:"
  printf "%b" "$VIOLATIONS"
  echo ""
  echo "ABSOLUTE RULES violated (figma-to-swiftui/SKILL.md):"
  echo "  1. Every visible icon/logo/illustration MUST come from Figma. SF Symbols,"
  echo "     hand-drawn shapes, letter-as-logo are BANNED substitutes."
  echo "  2. iOS system chrome (status bar, home indicator, Dynamic Island, notch)"
  echo "     is rendered by iOS, AND the iPhone bezel (~47–55pt rounded outline of"
  echo "     the entire frame) is rendered by hardware. Drawing either is a bug."
  echo "  3. Text fixed-width / safe-area double-count / Image fill-mode missing"
  echo "     ship truncation, layout drift, and blank gaps respectively."
  echo "     See visual-fidelity.md §7 #9-#13 and anti-patterns.md §8-§11."
  echo ""
  echo "Fix:"
  echo "  - Re-run figma_export_assets_unified(autoDiscover: true) for any missing"
  echo "    icon. Then use Image(\"icAI<Name>\") at the call site."
  echo "  - For status-bar / home-indicator areas, use .ignoresSafeArea / .safeAreaInset"
  echo "    on the layout — never draw the chrome itself."
  echo "  - If a system glyph is genuinely correct (e.g. ShareLink icon, search clear),"
  echo "    add // allow-systemName: <reason> on the same line OR the previous line."
  echo "  - Text default is hug (no .frame width) or fill (.frame(maxWidth: .infinity))."
  echo "    Numeric .frame(width: N) on Text needs // Figma fixed-width: <reason>."
  echo "    Single-line constrained Text also needs .minimumScaleFactor(0.6)."
  echo "  - Screen-root .padding(.top, N) where N ∈ {44,47,59,64,67,79,88} likely"
  echo "    double-counts iOS safe-area inset. Subtract inset from raw Figma y first."
  echo "    If intentional, add // safe-area-adjusted: raw=..., inset=..., adjusted=..."
  echo "  - Fill-* Image needs all three modifiers together: .resizable() + content"
  echo "    mode (.scaledToFill / .scaledToFit / .aspectRatio) + .frame(...).clipped()."
  echo "  - cornerRadius ≥ 30pt at screen-root almost always copies the iPhone bezel"
  echo "    (the hardware curves the corners for free; clipping again produces a"
  echo "    visible \"double bezel\" gutter on device). Remove it from the root view,"
  echo "    OR add // allow-screen-corner-radius: <reason> for a presented sheet /"
  echo "    inner card whose Figma node legitimately specifies that radius."
  echo "  - Text(...).frame(maxWidth: .infinity) inside Button { ... } cascades up"
  echo "    and makes the Button fill the screen, overriding caller .padding(.horizontal)."
  echo "    Move maxWidth to the Button's OUTER frame:"
  echo "        Button { Text(\"...\") }.frame(maxWidth: .infinity)"
  echo "    Source the width from the Button node's own Figma primaryAxisSizingMode"
  echo "    (FILL/FIXED/AUTO). For asymmetric content use HStack { Text; Spacer; Image }."
  echo "    Rare exceptions: add // allow-text-fill: <reason> on the same line or"
  echo "    the line above. See anti-patterns.md §12."
  echo ""
  echo "Disclosing the bypass in your final summary does NOT redeem it. The rule is"
  echo "STOP and surface BEFORE acting. See SKILL.md §\"ABSOLUTE RULE — Assets come"
  echo "from Figma\" and §\"ABSOLUTE RULE — Do NOT draw iOS system chrome\"."
} >&2

exit 2
