#!/usr/bin/env bash
# c8-iknavigation.sh — verify that, in projects using IKNavigation, the
# generated SwiftUI does NOT introduce vanilla NavigationStack APIs.
#
# Skipped when c1-conventions.json sets `usesIKNavigation = false`.
#
# Hard checks (when usesIKNavigation = true):
#   - banned: NavigationStack, NavigationLink, .navigationDestination, NavigationPath
#   - require: files dispatching navigation declare @Environment(\.ikNavigationable)
#
# Usage:
#   c8-iknavigation.sh --src <swift-src-root>
#                      [--files "<space-separated-paths>"]
#                      --conventions <c1-conventions.json>
#
# Scope: --files takes precedence over --src. Empty --files = SKIP (session
# mode with no swift writes).
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
usage: c8-iknavigation.sh --src <swift-src-root>
                            [--files "<space-separated-paths>"]
                            --conventions <c1-conventions.json>

When the project uses IKNavigation (per c1-conventions.json.usesIKNavigation),
this gate fails on any vanilla NavigationStack / NavigationLink /
.navigationDestination / NavigationPath usage in newly-generated files.

The gate is skipped (output: GATE: SKIP) when usesIKNavigation = false or
the conventions file is missing.

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
  USES_IK=$(grep -oE '"usesIKNavigation"[[:space:]]*:[[:space:]]*(true|false)' "$CONVENTIONS" \
    | sed -E 's/.*:[[:space:]]*(true|false).*/\1/' | head -n1 || true)
  [ -n "$USES_IK" ] || USES_IK="false"
fi

if [ "$USES_IK" != "true" ]; then
  echo "${C_DIM}GATE: SKIP (project uses NavigationStack — usesIKNavigation=${USES_IK})${C_RST}"
  exit 0
fi

HITS_FILE=$(mktemp -t c8-iknav.XXXXXX)
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

run_grep() {
  if [ "$FILES_PROVIDED" = "1" ]; then
    while IFS= read -r -d '' f; do
      grep -HnE "$1" "$f" 2>/dev/null || true
    done < <(enum_files)
  else
    grep -RHnE --include='*.swift' "$1" "$SRC" 2>/dev/null || true
  fi
}

emit() {
  local label="$1"; shift
  run_grep "$1" \
    | awk -v label="$label" -F: '{
        file=$1; line=$2;
        $1=""; $2="";
        sub(/^::[[:space:]]*/, "");
        printf "%s:%s: [%s] %s\n", file, line, label, $0
      }' >> "$HITS_FILE" || true
}

emit "NavigationStack"      '\bNavigationStack[ \t]*[({]'
emit "NavigationLink"       '\bNavigationLink[ \t]*[({]'
emit "navigationDestination" '\.navigationDestination[ \t]*\('
emit "NavigationPath"       '\bNavigationPath\b'

if [ -s "$HITS_FILE" ]; then
  sort -u "$HITS_FILE" -o "$HITS_FILE"
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: vanilla NavigationStack APIs detected in IKNavigation project${C_RST} (${COUNT} hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: use @Environment(\\.ikNavigationable) + navigation.push(to:) — see references/iknavigation-bridge.md${C_RST}"
  exit 1
fi

# Soft check: any view that owns a route should access ikNavigationable.
# Emit warning only — not all views need to dispatch (subviews bind to parent).
WARN_FILE=$(mktemp -t c8-iknav-warn.XXXXXX)
trap 'rm -f "$HITS_FILE" "$WARN_FILE"' EXIT

while IFS= read -r -d '' f; do
  if grep -q 'navigation\.\(push\|sheet\|fullScreenCover\|finish\|pop\|replace\)' "$f" 2>/dev/null; then
    if ! grep -q 'ikNavigationable' "$f"; then
      if [ -n "$SRC" ]; then
        rel="${f#$SRC/}"
      else
        rel="$f"
      fi
      printf "%s: dispatches navigation without @Environment(\\.ikNavigationable)\n" "$rel" >> "$WARN_FILE"
    fi
  fi
done < <(enum_files)

if [ -s "$WARN_FILE" ]; then
  COUNT=$(wc -l < "$WARN_FILE" | tr -d ' ')
  echo "${C_DIM}WARN: ${COUNT} file(s) call navigation methods without declaring @Environment(\\.ikNavigationable):${C_RST}"
  cat "$WARN_FILE"
fi

if [ "$FILES_PROVIDED" = "1" ]; then
  echo "${C_GRN}GATE: PASS${C_RST}: IKNavigation conventions OK (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
else
  echo "${C_GRN}GATE: PASS${C_RST}: IKNavigation conventions OK in $SRC"
fi
exit 0
