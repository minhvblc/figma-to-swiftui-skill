#!/usr/bin/env bash
# c7-no-system-chrome.sh — verify generated SwiftUI does NOT redraw iOS
# system chrome (status bar, home indicator, Dynamic Island, notch).
#
# iOS renders these. Drawing them in SwiftUI duplicates what the OS shows
# and breaks on real devices. This script greps for the canonical patterns
# we have seen agents emit by mistake.
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

# Dedupe + sort hits.
if [ -s "$HITS_FILE" ]; then
  sort -u "$HITS_FILE" -o "$HITS_FILE"
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}SYSTEM CHROME REDRAWS DETECTED${C_RST} ($COUNT hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: delete these views — iOS renders status bar / home indicator / Dynamic Island. See SKILL.md \"ABSOLUTE RULE — Do NOT draw iOS system chrome\".${C_RST}"
  exit 1
fi

echo "${C_GRN}PASS${C_RST}: no system chrome redraws found in $SRC"
exit 0
