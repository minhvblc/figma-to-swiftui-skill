#!/usr/bin/env bash
# c8-ikfont.sh — verify that, when the project has an IKFont (or AppFont)
# enum, generated SwiftUI uses it instead of raw Font.system / Font.custom.
#
# Skipped when c1-conventions.json has `ikFontEnum = null`.
#
# Hard checks (when ikFontEnum is set):
#   - banned: .font(.system(size: ...)) without @ScaledMetric
#   - banned: Font.custom("..." size: ...) when project has the enum
#
# Usage:
#   c8-ikfont.sh --src <swift-src-root> --conventions <c1-conventions.json>
#
# Exit codes:
#   0 — PASS or SKIP
#   1 — at least one violation
#   64 — bad usage
#   65 — input not found

set -euo pipefail

SRC=""
FILES=""
FILES_PROVIDED=0
CONVENTIONS=""

print_usage() {
  cat <<'USAGE' >&2
usage: c8-ikfont.sh --src <swift-src-root>
                     [--files "<space-separated-paths>"]
                     --conventions <c1-conventions.json>

When the project has an IKFont / AppFont / Typography enum (per
c1-conventions.json.ikFontEnum), this gate fails on raw .font(.system(size:))
or Font.custom() in newly-generated files.

The gate is skipped when ikFontEnum is null or the conventions file is missing.

Pass --files "" to explicitly skip (session-scope with no swift writes).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)         SRC="${2:-}"; shift 2 ;;
    --files)       FILES="${2:-}"; FILES_PROVIDED=1; shift 2 ;;
    --conventions) CONVENTIONS="${2:-}"; shift 2 ;;
    -h|--help)     print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

if [ "$FILES_PROVIDED" = "1" ] && [ -z "$FILES" ]; then
  echo "GATE: SKIP (no session-generated swift files)"
  exit 0
fi
if [ "$FILES_PROVIDED" = "0" ] && [ -z "$SRC" ]; then
  print_usage; exit 64
fi
if [ -n "$SRC" ] && [ ! -d "$SRC" ]; then
  echo "FAIL: src is not a directory: $SRC" >&2; exit 65
fi

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

IKFONT="null"
if [ -n "$CONVENTIONS" ] && [ -f "$CONVENTIONS" ]; then
  IKFONT=$(grep -oE '"ikFontEnum"[[:space:]]*:[[:space:]]*(null|"[^"]+")' "$CONVENTIONS" \
    | sed -E 's/.*:[[:space:]]*(null|"[^"]*")[[:space:]]*,?$/\1/' | head -n1 || true)
  [ -n "$IKFONT" ] || IKFONT="null"
fi

if [ "$IKFONT" = "null" ] || [ -z "$IKFONT" ]; then
  echo "${C_DIM}GATE: SKIP (no IKFont/AppFont/Typography enum in project)${C_RST}"
  exit 0
fi

# Strip quotes for display.
IKFONT_NAME=$(printf "%s" "$IKFONT" | sed -E 's/^"//;s/"$//')

HITS_FILE=$(mktemp -t c8-ikfont.XXXXXX)
trap 'rm -f "$HITS_FILE"' EXIT

enum_files() {
  if [ "$FILES_PROVIDED" = "1" ]; then
    for f in $FILES; do
      [ -n "$f" ] && [ -f "$f" ] && [[ "$f" == *.swift ]] && printf '%s\0' "$f"
    done
  else
    find "$SRC" -name '*.swift' -type f -print0 2>/dev/null
  fi
}

# 1. .font(.system(size: N)) without @ScaledMetric in the same file.
while IFS= read -r -d '' f; do
  if grep -qE '\.font\([[:space:]]*\.system\([[:space:]]*size:' "$f"; then
    if ! grep -qE '@ScaledMetric' "$f"; then
      if [ -n "$SRC" ]; then
        rel="${f#$SRC/}"
      else
        rel="$f"
      fi
      grep -nE '\.font\([[:space:]]*\.system\([[:space:]]*size:' "$f" \
        | awk -v file="$rel" -v ikf="$IKFONT_NAME" -F: '{
            line=$1; sub(/^[0-9]+:/, "", $0);
            printf "%s:%s: raw .font(.system(size:)) — use %s.<token>\n", file, line, ikf
          }' >> "$HITS_FILE"
    fi
  fi
done < <(enum_files)

# 2. Font.custom("...") — banned when IKFont enum exists.
if [ "$FILES_PROVIDED" = "1" ]; then
  while IFS= read -r -d '' f; do
    grep -HnE 'Font\.custom\(' "$f" 2>/dev/null || true
  done < <(enum_files) \
    | awk -v ikf="$IKFONT_NAME" -F: '{
        file=$1; line=$2;
        $1=""; $2="";
        sub(/^::[[:space:]]*/, "");
        printf "%s:%s: Font.custom() — use %s.<token> instead — %s\n", file, line, ikf, $0
      }' >> "$HITS_FILE" || true
else
  grep -RHnE --include='*.swift' 'Font\.custom\(' "$SRC" 2>/dev/null \
    | awk -v ikf="$IKFONT_NAME" -F: '{
        file=$1; line=$2;
        $1=""; $2="";
        sub(/^::[[:space:]]*/, "");
        printf "%s:%s: Font.custom() — use %s.<token> instead — %s\n", file, line, ikf, $0
      }' >> "$HITS_FILE" || true
fi

if [ -s "$HITS_FILE" ]; then
  sort -u "$HITS_FILE" -o "$HITS_FILE"
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: raw fonts in project that has '${IKFONT_NAME}' enum${C_RST} (${COUNT} hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: route through ${IKFONT_NAME}.<token> — see references/swiftui-pro-bridge.md §1b${C_RST}"
  exit 1
fi

if [ "$FILES_PROVIDED" = "1" ]; then
  echo "${C_GRN}GATE: PASS${C_RST}: typography routes through ${IKFONT_NAME} (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
else
  echo "${C_GRN}GATE: PASS${C_RST}: typography routes through ${IKFONT_NAME} in $SRC"
fi
exit 0
