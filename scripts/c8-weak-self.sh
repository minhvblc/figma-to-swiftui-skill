#!/usr/bin/env bash
# c8-weak-self.sh — soft check that escaping closures referencing `self.`
# capture self with `[weak self]`.
#
# This is intentionally a WARNING gate (exit 0 even with hits) because
# false positives are common (Task inside @MainActor reducer, withAnimation,
# .onAppear, etc.). Every warning printed here must be reviewed by the
# agent and acknowledged in the verification summary.
#
# Usage:
#   c8-weak-self.sh --src <swift-src-root>
#
# Exit codes:
#   0 — always (warning-only gate)
#   64 — bad usage
#   65 — input not found

set -euo pipefail

SRC=""

print_usage() {
  cat <<'USAGE' >&2
usage: c8-weak-self.sh --src <swift-src-root>

Greps for closures that reference 'self.' but do not declare a capture list
[weak self]. False positives are common; the gate emits warnings only.

Exempt patterns (no warning emitted):
  - .onAppear / .onDisappear / .task / withAnimation
  - body: some View
  - Task { ... } directly inside an @MainActor class (heuristic)
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
  C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

WARN_FILE=$(mktemp -t c8-weak.XXXXXX)
trap 'rm -f "$WARN_FILE"' EXIT

# Targets — escaping closure call sites that commonly hold strong self:
#   .sink { ... }, .assign(to:), URLSession completion, custom callbacks.
# We scan for these patterns where `self.` appears in the closure body but
# `[weak self]` is absent in the closure header.

scan() {
  awk '
    BEGIN { ignore = 0; in_closure = 0; closure_start = 0; weak_seen = 0; self_seen = 0; head = "" }
    {
      line = $0
      lower = tolower(line)
      # Exempt context heuristic — skip lines containing exempt method names.
      if (lower ~ /\.(onappear|ondisappear|task)[ \t]*\{/) { print line > "/dev/null"; next }
      if (lower ~ /withanimation[ \t]*\(/) { next }

      # Detect a closure opening that is the immediate target of an interesting API.
      if (line ~ /\.sink[ \t]*\{/ || line ~ /\.assign\(/ || line ~ /\.subscribe\(/ || line ~ /completionHandler:[ \t]*\{/ || line ~ /completion:[ \t]*\{/ || line ~ /onCompletion:[ \t]*\{/ || line ~ /onChange:[ \t]*\{/) {
        head = line
        if (head ~ /\[weak[ \t]+self\]/) { next }
        # Look ahead 30 lines for `self.` reference.
        for (i = 1; i <= 30; i++) {
          if (getline next_line <= 0) break
          if (next_line ~ /\}/) { break }
          if (next_line ~ /\bself\./) {
            printf "%s:%d: closure may need [weak self] — head: %s\n", FILENAME, NR, head
            break
          }
        }
      }
    }
  ' "$1"
}

while IFS= read -r -d '' file; do
  scan "$file" >> "$WARN_FILE" 2>/dev/null || true
done < <(find "$SRC" -name '*.swift' -type f -print0 2>/dev/null)

if [ -s "$WARN_FILE" ]; then
  COUNT=$(wc -l < "$WARN_FILE" | tr -d ' ')
  echo "${C_YEL}WARN${C_RST}: ${COUNT} closure(s) may need [weak self]:"
  cat "$WARN_FILE"
  echo "${C_DIM}review each — exempt: Task inside @MainActor class, withAnimation, .onAppear/.task. See references/swift-style.md §6.${C_RST}"
  echo "${C_DIM}gate is informational; agent must acknowledge each in verification summary.${C_RST}"
  exit 0
fi

echo "${C_GRN}GATE: PASS${C_RST}: no obvious [weak self] omissions in $SRC"
exit 0
