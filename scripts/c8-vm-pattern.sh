#!/usr/bin/env bash
# c8-vm-pattern.sh — verify every *ViewModel.swift in the run follows the
# State + Action + send(_:) reducer pattern documented in
# `figma-to-swiftui/references/viewmodel-pattern.md`.
#
# Hard checks:
#   - class is annotated with @MainActor (somewhere in the file)
#   - has `enum Action` nested
#   - has `func send(_ action: Action)`
#   - if file references `route`, has `enum Route` nested
#   - rejects a top-level `struct ViewState` wrapping all @Published cells
#     (flat-state rule)
#
# Usage:
#   c8-vm-pattern.sh --src <swift-src-root>
#
# Exit codes:
#   0 — PASS
#   1 — at least one ViewModel violates the pattern
#   64 — bad usage
#   65 — input not found

set -euo pipefail

SRC=""

print_usage() {
  cat <<'USAGE' >&2
usage: c8-vm-pattern.sh --src <swift-src-root>

Verifies every *ViewModel.swift conforms to the canonical reducer shape:
@MainActor + enum Action + func send(_:) + (if any route is referenced)
enum Route. See references/viewmodel-pattern.md.
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
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

HITS_FILE=$(mktemp -t c8-vm.XXXXXX)
WARN_FILE=$(mktemp -t c8-vm-warn.XXXXXX)
trap 'rm -f "$HITS_FILE" "$WARN_FILE"' EXIT

violation() { printf "%s\n" "$1" >> "$HITS_FILE"; }
warn()      { printf "%s\n" "$1" >> "$WARN_FILE"; }

while IFS= read -r -d '' file; do
  rel="${file#$SRC/}"
  base="$(basename "$file" .swift)"

  # 1. @MainActor on the class — search for `@MainActor` token anywhere
  #    near the class declaration (within 40 chars before).
  if ! grep -qE '@MainActor' "$file"; then
    violation "$rel: ViewModel class must be annotated @MainActor (see viewmodel-pattern.md §3d)"
  fi

  # 2. final (warning only)
  if ! grep -qE '\bfinal\s+class\b' "$file" && ! grep -qE '@Observable[[:space:]]+(@MainActor[[:space:]]+)?(final[[:space:]]+)?class' "$file"; then
    warn "$rel: ViewModel class is not declared 'final' (recommended)"
  fi

  # 3. enum Action present (allow public / private / fileprivate / internal)
  if ! grep -qE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+)?enum[[:space:]]+Action\b' "$file"; then
    violation "$rel: ViewModel must declare nested 'enum Action' (see viewmodel-pattern.md §3b)"
  fi

  # 4. func send(_ action: Action) present
  if ! grep -qE 'func[[:space:]]+send\([[:space:]]*_[[:space:]]+action[[:space:]]*:[[:space:]]*Action[[:space:]]*\)' "$file"; then
    violation "$rel: ViewModel must declare 'func send(_ action: Action)' (see viewmodel-pattern.md §1)"
  fi

  # 5. enum Route required when file references `route` cell
  if grep -qE '\b(route|dismissRoute)\b' "$file"; then
    if ! grep -qE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+)?enum[[:space:]]+Route\b' "$file"; then
      violation "$rel: ViewModel references 'route' but has no nested 'enum Route' (see viewmodel-pattern.md §3c)"
    fi
  fi

  # 6. Flat-state rule: if file has a `struct ViewState` (or similar) AND
  #    that struct contains all @Published cells, fail.
  if grep -qE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+)?struct[[:space:]]+(ViewState|State)\b' "$file"; then
    # Count @Published occurrences inside the file.
    pub_count=$(grep -cE '^[[:space:]]*@Published\b' "$file" || true)
    if [ "$pub_count" -le 1 ]; then
      violation "$rel: ViewModel wraps state in 'struct ViewState' / 'struct State' — flatten to per-property @Published (see viewmodel-pattern.md §3a)"
    fi
  fi

  # 7. Banned: per-method @MainActor instead of class-level
  if grep -qE '^[[:space:]]*@MainActor[[:space:]]+func\b' "$file"; then
    if ! grep -qE '@MainActor[[:space:]]+(final[[:space:]]+)?(class|@Observable)' "$file"; then
      violation "$rel: prefer class-level @MainActor over per-method (see viewmodel-pattern.md §3d)"
    fi
  fi

done < <(find "$SRC" -name '*ViewModel.swift' -type f -print0 2>/dev/null)

# Report warnings (do not fail the gate).
if [ -s "$WARN_FILE" ]; then
  COUNT=$(wc -l < "$WARN_FILE" | tr -d ' ')
  echo "${C_YEL}WARN${C_RST} (${COUNT} hint(s)):"
  cat "$WARN_FILE"
fi

if [ -s "$HITS_FILE" ]; then
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: ViewModel pattern violations${C_RST} (${COUNT} hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: see references/viewmodel-pattern.md (canonical shape + rules)${C_RST}"
  exit 1
fi

echo "${C_GRN}GATE: PASS${C_RST}: ViewModel pattern OK in $SRC"
exit 0
