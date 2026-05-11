#!/usr/bin/env bash
# PreToolUse hook for Write/Edit on *.swift — block content BEFORE it lands.
#
# Improvements in this revision:
#   P0-4: For Edit operations, simulate the post-edit file by reading the
#         existing file from disk and applying the old_string → new_string
#         replacement. Then run violation checks against the simulated full
#         file. This lets prev-line `// allow-systemName:` comments be seen
#         even when they live outside the Edit's diff window. Previously the
#         hook only saw the diff snippet, blocking legitimate edits.
#
#   P0-5: Terse output by default — 1-line BLOCK per violation + 1 doc URL.
#         Set HOOK_VERBOSE=1 to dump the full reference text (the old behavior).
#
# Original responsibilities preserved:
#
#   1. Image(systemName: "<sym>") outside allow-list, no `// allow-systemName:` comment
#   2. iOS system-chrome redraws (status bar, home indicator, etc.)
#   3. Hand-drawn substitutes (letter-as-logo)
#   4. Text(...).frame(width: <num>) without `// Figma fixed-width:` justification
#   5. Screen-root .padding(.top, 44|47|59|64|67|79|88) without `// safe-area-adjusted:`
#   6. Image(...).frame(maxWidth: .infinity) missing .resizable() + content-mode
#   7. cornerRadius ≥ 30 without `// allow-screen-corner-radius:`
#   8. Text(...).frame(maxWidth: .infinity) inside Button without `// allow-text-fill:`
#
# Only enforces inside a figma task — i.e. there's a .figma-cache/ in the file's
# tree (walking up). Files marked with `_NoFigma_` segment bypass.
#
# Exit codes:
#   0 — allow
#   2 — block (stderr is shown to Claude as a system reminder)

set -uo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')

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

# ─── P0-4: Build the content to check ──────────────────────────────────────────
# Goal: produce a TMP file that represents what the file WILL look like after
# the operation lands. For Write, that's the supplied content. For Edit, that's
# the existing file with old_string substituted for new_string at the first
# match (Edit's semantics).
#
# Line numbers in violations refer to the post-edit file, so the agent can jq
# straight to the line. Previous-line allow-comment checks work even when the
# comment lives outside the Edit's diff window.

TMP=$(mktemp -t figma-banned.XXXXXX) || exit 0
trap 'rm -f "$TMP"' EXIT

case "$TOOL" in
  Write)
    CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty')
    [ -z "$CONTENT" ] && exit 0
    printf '%s' "$CONTENT" > "$TMP"
    ;;
  Edit)
    OLD=$(printf '%s' "$INPUT" | jq -r '.tool_input.old_string // empty')
    NEW=$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty')
    REPLACE_ALL=$(printf '%s' "$INPUT" | jq -r '.tool_input.replace_all // false')
    if [ ! -f "$FILE_PATH" ]; then
      # File doesn't exist yet on disk — fall back to the diff snippet to avoid
      # missing checks entirely. Agent should have Written first; surface as a
      # softer warning by checking new_string in isolation.
      [ -z "$NEW" ] && exit 0
      printf '%s' "$NEW" > "$TMP"
    else
      # Simulate post-edit by reading file + applying replacement. We use python
      # for safe literal string replacement (vs sed which interprets regex
      # metachars in $OLD).
      python3 - "$FILE_PATH" "$OLD" "$NEW" "$REPLACE_ALL" "$TMP" <<'PY' 2>/dev/null || cp "$FILE_PATH" "$TMP"
import sys
src_path, old_str, new_str, replace_all_str, out_path = sys.argv[1:6]
replace_all = replace_all_str.lower() == "true"
with open(src_path, 'r') as f:
    src = f.read()
if old_str == "":
    out = src + new_str
elif replace_all:
    out = src.replace(old_str, new_str)
else:
    # Single replacement: same as Edit's default semantics. Edit would error if
    # old_str isn't found; we mirror that by emitting src unchanged (no false
    # positives).
    idx = src.find(old_str)
    out = src if idx < 0 else src[:idx] + new_str + src[idx+len(old_str):]
with open(out_path, 'w') as f:
    f.write(out)
PY
    fi
    ;;
  *)
    exit 0
    ;;
esac

# Sanity: empty TMP → allow.
[ ! -s "$TMP" ] && exit 0

VIOLATIONS=""
add_violation() {
  VIOLATIONS+="  $1\n"
}

# Helper: check if line `n` or line `n-1` in $TMP contains the given allow comment.
has_allow_comment() {
  local lineno="$1" comment_pattern="$2"
  local cur prev
  cur=$(sed -n "${lineno}p" "$TMP" 2>/dev/null || true)
  if printf '%s' "$cur" | grep -q "$comment_pattern"; then return 0; fi
  if [ "$lineno" -gt 1 ]; then
    prev=$(sed -n "$((lineno - 1))p" "$TMP" 2>/dev/null || true)
    if printf '%s' "$prev" | grep -q "$comment_pattern"; then return 0; fi
  fi
  return 1
}

# ─── Check 1: Image(systemName: ...) outside allow-list ────────────────────────
ALLOW_REGEX='^(chevron\.(backward|left|right|up|down)|square\.and\.arrow\.up|xmark\.circle\.fill|keyboard.*)$'

while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  symbol=$(printf '%s\n' "$content" | sed -nE 's/.*systemName:[[:space:]]*"([^"]+)".*/\1/p' | head -1)

  has_allow_comment "$lineno" '// *allow-systemName:' && continue
  if [ -n "$symbol" ] && [[ "$symbol" =~ $ALLOW_REGEX ]]; then continue; fi

  add_violation "line $lineno: Image(systemName: \"${symbol:-?}\") — needs Figma asset OR // allow-systemName: comment"
done < <(grep -nE 'Image\(\s*systemName:' "$TMP" 2>/dev/null || true)

# ─── Check 2a: Status-bar clock literal ────────────────────────────────────────
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: Text(\"9:41\") — status bar rendered by iOS, do not redraw"
done < <(grep -nE 'Text\(\s*"9:4[0-9]"' "$TMP" 2>/dev/null || true)

# ─── Check 2b: Status-bar SF Symbols ───────────────────────────────────────────
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  symbol=$(printf '%s\n' "$content" | sed -nE 's/.*systemName:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
  has_allow_comment "$lineno" '// *allow-systemName:' && continue
  add_violation "line $lineno: Image(systemName: \"$symbol\") — status-bar glyph, iOS renders it"
done < <(grep -nE 'Image\([[:space:]]*systemName:[[:space:]]*"(wifi|battery|cellularbars|antenna)' "$TMP" 2>/dev/null || true)

# ─── Check 2c: Banned struct names ─────────────────────────────────────────────
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  match=$(printf '%s\n' "${line#*:}" | grep -oE '(FakeStatusBar|HomeIndicator|NotchView|DynamicIslandView)' | head -1)
  add_violation "line $lineno: '$match' — iOS renders system chrome, custom struct redrawing it is banned"
done < <(grep -nE '\b(struct|class)\s+(FakeStatusBar|HomeIndicator|NotchView|DynamicIslandView)\b' "$TMP" 2>/dev/null || true)

# ─── Check 2d: Home-indicator capsule lookalike ────────────────────────────────
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  content="${line#*:}"
  width=$(printf '%s\n' "$content" | sed -nE 's/.*width:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  if [ -n "$width" ]; then
    if [ "$width" -lt 100 ] || [ "$width" -gt 180 ]; then continue; fi
  fi
  add_violation "line $lineno: Capsule()+thin frame in home-indicator zone — use RoundedRectangle for thin progress/separator"
done < <(grep -nE 'Capsule[[:space:]]*\(.*frame[[:space:]]*\([^)]*height:[[:space:]]*[1-6]([^0-9]|$)' "$TMP" 2>/dev/null || true)

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
  content="${line#*:}"
  width=$(printf '%s\n' "$content" | sed -nE 's/.*width:[[:space:]]*([0-9]+).*/\1/p' | head -1)
  if [ -n "$width" ]; then
    if [ "$width" -lt 100 ] || [ "$width" -gt 180 ]; then continue; fi
  fi
  add_violation "line $lineno: Capsule()+thin-height nearby — likely home-indicator redraw"
done <<< "$HI_HITS"

# ─── Check 3: hand-drawn letter-as-logo ────────────────────────────────────────
LETTER_HITS=$(awk '
  /Text\([[:space:]]*"[A-Z]"[[:space:]]*\)/ { letter_at=NR; letter_line=$0 }
  /frame[[:space:]]*\([^)]*width:[[:space:]]*([0-9]|[12][0-9]|3[0-2])([^0-9]|$)/ {
    if (letter_at && NR - letter_at <= 4) {
      print letter_at ": " letter_line
      letter_at=0
    }
  }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: Text(\"<letter>\") near small frame — possible letter-as-logo, use Figma asset"
done <<< "$LETTER_HITS"

# ─── Check 4: Text(...).frame(width: <num>) without justification ──────────────
TXTW_HITS=$(awk '
  function reset() { txt_at=0; txt_line=""; saw_other=0 }
  BEGIN { reset() }
  /Text\(/ {
    reset()
    txt_at=NR; txt_line=$0
  }
  txt_at && /Image\(|Color\(|RoundedRectangle\(|Rectangle\(|Capsule\(|Circle\(|Ellipse\(|Spacer\(|Divider\(/ {
    saw_other=1
  }
  txt_at && /\.frame\([[:space:]]*width:[[:space:]]*[0-9]+(\.[0-9]+)?[[:space:]]*[,)]/ {
    if (saw_other) { reset(); next }
    print NR ": " $0
    reset()
  }
  txt_at && NR - txt_at > 5 { reset() }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  has_allow_comment "$lineno" '// Figma fixed-width:' && continue
  add_violation "line $lineno: Text(...).frame(width: ...) without // Figma fixed-width: — Text default is hug or fill"
done <<< "$TXTW_HITS"

# ─── Check 5: padding(.top, N) double-counting safe area ───────────────────────
SAFE_HITS=$(grep -nE '\.padding\([[:space:]]*\.top[[:space:]]*,[[:space:]]*(44|47|59|64|67|79|88)([^0-9]|$)|Spacer\(\)\.frame\([[:space:]]*height:[[:space:]]*(44|47|59|64|67|79|88)([^0-9]|$)' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  has_allow_comment "$lineno" '// safe-area-adjusted' && continue
  add_violation "line $lineno: suspicious safe-area-sized padding — likely double-counts inset, add // safe-area-adjusted: comment"
done <<< "$SAFE_HITS"

# ─── Check 6: Image(...).frame(maxWidth: .infinity) missing resizable+contentMode ───
IMGFILL_HITS=$(awk '
  function reset() { img_at=0; img_line=""; has_resizable=0; has_mode=0 }
  BEGIN { reset() }
  /Image\([[:space:]]*"[^"]+"[[:space:]]*\)/ {
    reset()
    img_at=NR; img_line=$0
  }
  /Image\([[:space:]]*\.[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\)/ {
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
        print img_at ": " img_line " (missing:" missing ")"
      }
      reset()
    }
  }
  img_at && NR - img_at > 8 { reset() }
' "$TMP" 2>/dev/null || true)
while IFS= read -r line; do
  [ -z "$line" ] && continue
  lineno="${line%%:*}"
  add_violation "line $lineno: fill-width Image missing .resizable()/.scaledToFit/.scaledToFill"
done <<< "$IMGFILL_HITS"

# ─── Check 8: Text(...).frame(maxWidth: .infinity) inside Button { ... } ──────
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
  has_allow_comment "$lineno" '// *allow-text-fill' && continue
  add_violation "line $lineno: Text(maxWidth: .infinity) inside Button — cascades to Button width, move maxWidth to outer .frame on Button"
done <<< "$BTNFILL_HITS"

# ─── Check 7: cornerRadius ≥ 30 without justification ──────────────────────────
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
  has_allow_comment "$lineno" '// *allow-screen-corner-radius:' && continue
  add_violation "line $lineno: cornerRadius=${val}pt ≥ 30 — likely copies iPhone bezel, remove or add // allow-screen-corner-radius:"
done <<< "$BEZEL_HITS"

# Done.
if [ -z "$VIOLATIONS" ]; then
  exit 0
fi

# ─── P0-5: terse output by default, verbose only when HOOK_VERBOSE=1 ───────────
{
  if [ "${HOOK_VERBOSE:-0}" = "1" ]; then
    # Legacy verbose format — full reference text. Kept for users who explicitly
    # opt in via HOOK_VERBOSE=1.
    echo "BLOCKED: figma-to-swiftui banned-pattern detector"
    echo ""
    echo "File: $FILE_PATH"
    echo "Tool: $TOOL"
    echo ""
    echo "Violations:"
    printf "%b" "$VIOLATIONS"
    echo ""
    echo "Fix paths:"
    echo "  - Image(systemName) → use Figma asset OR add // allow-systemName: <reason>"
    echo "  - System chrome → use .ignoresSafeArea / .safeAreaInset, never draw"
    echo "  - Text width → numeric width needs // Figma fixed-width: <reason>"
    echo "  - .padding(.top, 44/47/59/...) → use // safe-area-adjusted: or fix math"
    echo "  - Fill Image → .resizable().scaledToFit/.scaledToFill().frame(...).clipped()"
    echo "  - cornerRadius ≥ 30 → remove or add // allow-screen-corner-radius:"
    echo "  - Text maxWidth: .infinity inside Button → move to Button outer .frame"
    echo ""
    echo "Docs: ~/.claude/skills/figma-to-swiftui/references/{anti-patterns.md,visual-fidelity.md}"
    echo "Verbose mode: HOOK_VERBOSE=1 ↑"
  else
    # Terse default: one-line BLOCK header, violations, single doc URL.
    echo "BLOCKED [figma-banned-pattern]: $(basename "$FILE_PATH")"
    printf "%b" "$VIOLATIONS"
    echo "Fix hints (set HOOK_VERBOSE=1 for full reference):"
    echo "  • SF Symbol → use Figma asset OR add // allow-systemName: <reason>"
    echo "  • Width violations → see anti-patterns.md §8-§12"
    echo "Docs: ~/.claude/skills/figma-to-swiftui/references/anti-patterns.md"
  fi
} >&2

exit 2
