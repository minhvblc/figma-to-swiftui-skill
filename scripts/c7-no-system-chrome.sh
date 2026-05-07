#!/usr/bin/env bash
# c7-no-system-chrome.sh — verify generated SwiftUI does NOT redraw iOS
# system chrome (status bar, home indicator, Dynamic Island, notch) or
# the iPhone bezel (rounded outline of the entire frame, ~47–55pt).
#
# iOS / hardware renders all of these. Drawing them in SwiftUI duplicates
# what the OS shows and breaks on real devices. This script greps for the
# canonical patterns we have seen agents emit by mistake.
#
# Usage:
#   c7-no-system-chrome.sh --src <path-to-swift-src-root>
#
# Exit codes:
#   0 — clean (no chrome redraws)
#   1 — at least one match found
#   64 — bad usage
#   65 — input not found

set -euo pipefail

SRC=""

print_usage() {
  cat <<'USAGE' >&2
usage: c7-no-system-chrome.sh --src <path-to-swift-src-root>

Greps for status-bar / home-indicator / Dynamic Island / notch redraws in
SwiftUI source. iOS renders system chrome; the SwiftUI view must NEVER
redraw it. Each hit is printed as `file:line: <pattern>`.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)     SRC="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$SRC" ] || { print_usage; exit 64; }
[ -d "$SRC" ] || { echo "FAIL: src is not a directory: $SRC" >&2; exit 65; }

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_DIM=""; C_RST=""
fi

HITS_FILE=$(mktemp -t c7-hits.XXXXXX)
trap 'rm -f "$HITS_FILE"' EXIT

emit() {
  # emit <pattern-label> <grep-args ...>
  local label="$1"; shift
  grep -RHn --include='*.swift' "$@" "$SRC" 2>/dev/null \
    | awk -v label="$label" -F: '{
        file=$1; line=$2;
        $1=""; $2="";
        sub(/^::[[:space:]]*/, "");
        printf "%s:%s: [%s] %s\n", file, line, label, $0
      }' >> "$HITS_FILE" || true
}

# 1. Banned identifiers — case-sensitive substring on .swift files.
#    Word-boundary regex so we don't trip on Apple APIs (e.g.
#    `ToolbarItem(placement: .dynamicIsland)` is OK, but `DynamicIsland(...)`
#    used as a custom view name is not).
emit "FakeStatusBar"     -E 'FakeStatusBar'
emit "HomeIndicator"     -E '\bHomeIndicator\b'
emit "DynamicIsland-view" -E '\bDynamicIsland(View)?\b\s*\('
emit "NotchView"         -E '\bNotchView\b'
# *StatusBar* view names — but exclude UIKit's UIStatusBar surface (any
# identifier that contains "StatusBar" as a name fragment).
emit "StatusBarView" -E '\b[A-Za-z0-9_]*StatusBar[A-Za-z0-9_]*\b' \
  | true # include all and filter below
# Filter out UIStatusBar (Apple) hits the previous emit may have collected.
if [ -s "$HITS_FILE" ]; then
  grep -v 'UIStatusBar' "$HITS_FILE" > "$HITS_FILE.tmp" && mv "$HITS_FILE.tmp" "$HITS_FILE" || true
fi

# 2. Banned regex patterns.
#    a) Status-bar clock: Text("9:41") or Text("12:34")
emit "status-clock"  -E 'Text\(\s*"[0-9]{1,2}:[0-9]{2}"\s*\)'
#    b) Status-bar icons: Image(systemName: "wifi" / "cellularbars" / "battery.*")
emit "statusbar-icon" -E 'Image\(systemName:\s*"(wifi|cellularbars|battery\.[^"]*)"'
#    c) Home-indicator-ish capsule: Capsule().<...>.frame(...height: 1..6)
#       The two-modifier window catches `.frame(...).frame(...)` patterns too.
emit "home-indicator" -E 'Capsule\(\)[^)]{0,200}\.frame\([^)]*height:\s*[1-6]\b'

# 3. Device-frame bezel — `.cornerRadius(N)` / `.clipShape(.rect(cornerRadius: N))` /
#    `.clipShape(RoundedRectangle(cornerRadius: N))` / `RoundedRectangle(cornerRadius: N)`
#    where N ≥ 30, applied at the screen-root level and meant to mimic the iPhone
#    bezel. iPhone bezel is hardware (47pt for non-Pro, 55pt for Pro/Pro Max);
#    UI corner radii rarely exceed ~24pt. Threshold 30pt catches both classes
#    without snagging legit hero-card radii (typically ≤ 24).
#
#    Honor `// allow-screen-corner-radius:` on same or previous line.
#
#    Heuristic: scan all *.swift; flag any radius literal ≥ 30 without escape
#    comment. False positives (e.g. a legit 32pt hero card) are handled by the
#    escape comment, with a brief justification.
BEZEL_HITS=$(grep -RHnE --include='*.swift' \
  '\.cornerRadius[[:space:]]*\([[:space:]]*[0-9]+|cornerRadius:[[:space:]]*[0-9]+' \
  "$SRC" 2>/dev/null \
  | awk -F: '
      {
        file=$1; lineno=$2
        rest=""
        for (i=3; i<=NF; i++) rest = rest (i==3 ? "" : ":") $i
        # Extract numeric radius from one of the two forms.
        val=-1
        if (match(rest, /\.cornerRadius[[:space:]]*\([[:space:]]*[0-9]+/)) {
          chunk=substr(rest, RSTART, RLENGTH)
          if (match(chunk, /[0-9]+/)) val = substr(chunk, RSTART, RLENGTH) + 0
        } else if (match(rest, /cornerRadius:[[:space:]]*[0-9]+/)) {
          chunk=substr(rest, RSTART, RLENGTH)
          if (match(chunk, /[0-9]+/)) val = substr(chunk, RSTART, RLENGTH) + 0
        }
        if (val < 30) next
        # Same-line escape comment?
        if (rest ~ /\/\/[[:space:]]*allow-screen-corner-radius:/) next
        # Defer prev-line check to bash (needs file read).
        printf "%s\t%d\t%d\t%s\n", file, lineno, val, rest
      }
    ' 2>/dev/null || true)

if [ -n "$BEZEL_HITS" ]; then
  while IFS=$'\t' read -r file lineno val rest; do
    [ -z "$file" ] && continue
    # Previous-line escape?
    if [ "$lineno" -gt 1 ]; then
      prev=$(sed -n "$((lineno - 1))p" "$file" 2>/dev/null || true)
      if printf '%s' "$prev" | grep -q '// *allow-screen-corner-radius:'; then
        continue
      fi
    fi
    printf '%s:%d: [bezel-radius=%d] %s\n' "$file" "$lineno" "$val" "$rest" >> "$HITS_FILE"
  done <<< "$BEZEL_HITS"
fi

# Dedupe + sort hits.
if [ -s "$HITS_FILE" ]; then
  sort -u "$HITS_FILE" -o "$HITS_FILE"
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}SYSTEM CHROME REDRAWS DETECTED${C_RST} ($COUNT hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix:${C_RST}"
  echo "${C_DIM}  - status bar / home indicator / Dynamic Island lookalikes → delete; iOS renders them.${C_RST}"
  echo "${C_DIM}  - bezel-radius hits (corner radius ≥ 30pt) → remove from screen-root; the iPhone${C_RST}"
  echo "${C_DIM}    bezel is hardware. If a presented sheet / inner card legitimately needs ≥ 30pt,${C_RST}"
  echo "${C_DIM}    add // allow-screen-corner-radius: <reason> on the same or previous line.${C_RST}"
  echo "${C_DIM}  - See SKILL.md \"ABSOLUTE RULE — Do NOT draw iOS system chrome\" + anti-patterns.md §11.${C_RST}"
  exit 1
fi

echo "${C_GRN}PASS${C_RST}: no system chrome redraws found in $SRC"
exit 0
