#!/usr/bin/env bash
# c8-iklocalized.sh — verify that, in projects using .ikLocalized()
# extension, generated SwiftUI follows the two-paths convention from
# references/iklocalized-bridge.md (D-801..D-806).
#
# Skipped when c1-conventions.json sets `usesIKLocalized = false`.
#
# Hard checks (when usesIKLocalized = true):
#   - banned: Text("...".ikLocalized()) — double-localize anti-pattern
#             (calls Text(_: String) overload which doesn't auto-localize)
#   - banned: Text(LocalizedStringKey("...")) — manual constructor
#   - banned: NSLocalizedString(...)
#   - banned: String(localized: ...)
#
# Soft checks (warning only):
#   - static let <name>: String = "..." without .ikLocalized() (heuristic;
#     name suggests user-facing label). False-positive risk — agent may
#     suppress with `// not-user-facing: <reason>` comment.
#
# Usage:
#   c8-iklocalized.sh --src <swift-src-root>
#                     [--files "<space-separated-paths>"]
#                     --conventions <c1-conventions.json>
#
# Exit codes:
#   0 — PASS or SKIP
#   1 — at least one hard violation
#   64 — bad usage
#   65 — input not found

set -euo pipefail

SRC=""
FILES=""
FILES_PROVIDED=0
CONVENTIONS=""

print_usage() {
  cat <<'USAGE' >&2
usage: c8-iklocalized.sh --src <swift-src-root>
                          [--files "<space-separated-paths>"]
                          --conventions <c1-conventions.json>

When the project uses .ikLocalized() (per c1-conventions.json.usesIKLocalized),
this gate fails on:
  - Text("...".ikLocalized())     — double-localize anti-pattern
  - Text(LocalizedStringKey(...)) — manual constructor
  - NSLocalizedString(...)
  - String(localized: ...)

The gate is skipped (output: GATE: SKIP) when usesIKLocalized = false.

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
  USES_IK=$(grep -oE '"usesIKLocalized"[[:space:]]*:[[:space:]]*(true|false)' "$CONVENTIONS" \
    | sed -E 's/.*:[[:space:]]*(true|false).*/\1/' | head -n1 || true)
  [ -n "$USES_IK" ] || USES_IK="false"
fi

if [ "$USES_IK" != "true" ]; then
  echo "${C_DIM}GATE: SKIP (project does not use .ikLocalized — usesIKLocalized=${USES_IK})${C_RST}"
  exit 0
fi

HITS_FILE=$(mktemp -t c8-ikloc.XXXXXX)
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

emit_hard() {
  local label="$1"; local pattern="$2"
  run_grep "$pattern" \
    | awk -v label="$label" -F: '{
        file=$1; line=$2;
        $1=""; $2="";
        sub(/^::[[:space:]]*/, "");
        printf "%s:%s: [%s] %s\n", file, line, label, $0
      }' >> "$HITS_FILE" || true
}

# Hard: double-localize anti-pattern.
# Matches: Text("...".ikLocalized())  including .ikLocalized( ... )  variants
emit_hard "double-localize"        'Text\([[:space:]]*"[^"]*"\.ikLocalized\('

# Hard: manual LocalizedStringKey constructor.
emit_hard "manual LocalizedStringKey" 'LocalizedStringKey\([[:space:]]*"'

# Hard: NSLocalizedString.
emit_hard "NSLocalizedString"      '\bNSLocalizedString[[:space:]]*\('

# Hard: String(localized:).
emit_hard "String(localized:)"     '\bString\([[:space:]]*localized:'

# Hard: Text(.symbolKey) — Ikame doesn't use the symbol-key API.
# Heuristic: Text(.<lowerCaseIdentifier>) at start of line/expr.
# Note: this can false-positive on Text(viewModel.someState) — narrow further.
emit_hard "Text(.symbolKey)"       'Text\([[:space:]]*\.[a-z][[:alnum:]_]+[[:space:]]*[,)]'

if [ -s "$HITS_FILE" ]; then
  sort -u "$HITS_FILE" -o "$HITS_FILE"
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: localization anti-patterns in IKLocalized project${C_RST} (${COUNT} hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: see references/iklocalized-bridge.md §2 (the two paths)${C_RST}"
  echo "${C_DIM}     - Text(\"...\")             — direct, SwiftUI auto-localizes${C_RST}"
  echo "${C_DIM}     - \"...\".ikLocalized()      — for String constants and non-Text APIs${C_RST}"
  exit 1
fi

if [ "$FILES_PROVIDED" = "1" ]; then
  echo "${C_GRN}GATE: PASS${C_RST}: IKLocalized conventions OK (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
else
  echo "${C_GRN}GATE: PASS${C_RST}: IKLocalized conventions OK in $SRC"
fi
exit 0
