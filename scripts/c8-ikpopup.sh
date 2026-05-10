#!/usr/bin/env bash
# c8-ikpopup.sh — verify that, in projects using IKPopup, vanilla SwiftUI
# popup APIs (.sheet, .alert, .fullScreenCover, .confirmationDialog,
# UIAlertController) are not used as the default. Allowed only with an
# inline justification comment per references/ikame-decision-table.md D-507.
#
# Skipped when c1-conventions.json sets `usesIKPopup = false`.
#
# Hard checks (when usesIKPopup = true):
#   - banned without `// allow-vanilla-popup:` justification within 3 lines
#     above the call site:
#       .sheet(isPresented:)  .sheet(item:)
#       .fullScreenCover(isPresented:)  .fullScreenCover(item:)
#       .alert(isPresented:)  .alert(...)
#       .confirmationDialog(...)
#       UIAlertController(...)
#
# Usage:
#   c8-ikpopup.sh --src <swift-src-root>
#                 [--files "<space-separated-paths>"]
#                 --conventions <c1-conventions.json>
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
usage: c8-ikpopup.sh --src <swift-src-root>
                       [--files "<space-separated-paths>"]
                       --conventions <c1-conventions.json>

When the project uses IKPopup (per c1-conventions.json.usesIKPopup), this
gate fails on vanilla SwiftUI popup APIs unless they are justified with
an inline `// allow-vanilla-popup: <reason>` comment within 3 lines above.

The gate is skipped (output: GATE: SKIP) when usesIKPopup = false.

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
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_DIM=""; C_RST=""
fi

USES_IK="false"
if [ -n "$CONVENTIONS" ] && [ -f "$CONVENTIONS" ]; then
  USES_IK=$(grep -oE '"usesIKPopup"[[:space:]]*:[[:space:]]*(true|false)' "$CONVENTIONS" \
    | sed -E 's/.*:[[:space:]]*(true|false).*/\1/' | head -n1 || true)
  [ -n "$USES_IK" ] || USES_IK="false"
fi

if [ "$USES_IK" != "true" ]; then
  echo "${C_DIM}GATE: SKIP (project does not use IKPopup — usesIKPopup=${USES_IK})${C_RST}"
  exit 0
fi

HITS_FILE=$(mktemp -t c8-ikpopup.XXXXXX)
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

# For each file, find banned popup-API call sites and check whether a
# `// allow-vanilla-popup:` comment appears within 3 lines above. If not,
# emit a violation.
check_file() {
  local f="$1"
  local rel="$f"
  if [ -n "$SRC" ]; then
    rel="${f#$SRC/}"
  fi

  # Use awk to track line numbers and look-back for justification comment.
  awk -v file="$rel" '
    {
      lines[NR] = $0
    }
    END {
      for (i = 1; i <= NR; i++) {
        line = lines[i]
        api = ""
        if (match(line, /\.sheet\([[:space:]]*(isPresented|item):/))            api = ".sheet(...)"
        else if (match(line, /\.fullScreenCover\([[:space:]]*(isPresented|item):/)) api = ".fullScreenCover(...)"
        else if (match(line, /\.alert\([[:space:]]*(isPresented|".+",[[:space:]]*isPresented|".+",[[:space:]]*item)/)) api = ".alert(...)"
        else if (match(line, /\.confirmationDialog\(/))                          api = ".confirmationDialog(...)"
        else if (match(line, /UIAlertController\(/))                              api = "UIAlertController(...)"

        if (api == "") continue

        justified = 0
        start = (i - 3 < 1) ? 1 : i - 3
        for (j = start; j < i; j++) {
          if (lines[j] ~ /\/\/[[:space:]]*allow-vanilla-popup:/) {
            justified = 1
            break
          }
        }
        if (!justified) {
          printf "%s:%d: vanilla popup API %s without // allow-vanilla-popup: justification\n", file, i, api
        }
      }
    }
  ' "$f" >> "$HITS_FILE" || true
}

while IFS= read -r -d '' f; do
  check_file "$f"
done < <(enum_files)

if [ -s "$HITS_FILE" ]; then
  sort -u "$HITS_FILE" -o "$HITS_FILE"
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: vanilla SwiftUI popup APIs without justification${C_RST} (${COUNT} hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: route through IKPopup.shared.showPopup — see references/ikpopup-bridge.md${C_RST}"
  echo "${C_DIM}     OR add inline comment // allow-vanilla-popup: <reason> per D-507${C_RST}"
  exit 1
fi

if [ "$FILES_PROVIDED" = "1" ]; then
  echo "${C_GRN}GATE: PASS${C_RST}: IKPopup conventions OK (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
else
  echo "${C_GRN}GATE: PASS${C_RST}: IKPopup conventions OK in $SRC"
fi
exit 0
