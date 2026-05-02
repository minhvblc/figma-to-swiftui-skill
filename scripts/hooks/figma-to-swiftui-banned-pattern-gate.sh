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
  echo "     is rendered by iOS. Drawing it is always a bug."
  echo ""
  echo "Fix:"
  echo "  - Re-run figma_export_assets_unified(autoDiscover: true) for any missing"
  echo "    icon. Then use Image(\"icAI<Name>\") at the call site."
  echo "  - For status-bar / home-indicator areas, use .ignoresSafeArea / .safeAreaInset"
  echo "    on the layout — never draw the chrome itself."
  echo "  - If a system glyph is genuinely correct (e.g. ShareLink icon, search clear),"
  echo "    add // allow-systemName: <reason> on the same line OR the previous line."
  echo ""
  echo "Disclosing the bypass in your final summary does NOT redeem it. The rule is"
  echo "STOP and surface BEFORE acting. See SKILL.md §\"ABSOLUTE RULE — Assets come"
  echo "from Figma\" and §\"ABSOLUTE RULE — Do NOT draw iOS system chrome\"."
} >&2

exit 2
