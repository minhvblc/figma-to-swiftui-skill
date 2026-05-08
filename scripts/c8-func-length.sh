#!/usr/bin/env bash
# c8-func-length.sh — verify function length limits.
#
# Hard fail at >50 lines. Warning at >30 lines. SwiftUI `body: some View`
# is exempt (it's allowed to compose subviews).
#
# Usage:
#   c8-func-length.sh --src <swift-src-root>
#                     [--files "<space-separated-paths>"]
#                     [--warn-threshold 30] [--fail-threshold 50]
#
# Scope:
#   --files takes precedence over --src. When --files is the empty string,
#   the gate prints `GATE: SKIP (no session-generated swift files)` and
#   exits 0 — used by stop-hook session-scope mode (no agent writes = no
#   work to verify).
#   When --files is set with paths and --src is also set, --src is used for
#   relative-path display only; the file walk is scoped to --files.
#
# Exit codes:
#   0 — PASS or SKIP
#   1 — at least one function exceeds fail threshold
#   64 — bad usage
#   65 — input not found

set -euo pipefail

SRC=""
FILES=""
FILES_PROVIDED=0
WARN_T=30
FAIL_T=50

print_usage() {
  cat <<'USAGE' >&2
usage: c8-func-length.sh --src <swift-src-root>
                          [--files "<space-separated-paths>"]
                          [--warn-threshold 30] [--fail-threshold 50]

Counts function-body lines (from opening { of the func decl to its
matching closing }). SwiftUI 'body: some View' is exempt — its children
are checked instead via the per-subview view-length rule.

Counted: the body block including blank lines and comments.
Excluded: function signature line itself.

Hard fail at fail-threshold; warning at warn-threshold.

Pass --files "" to explicitly skip (session-scope with no swift writes).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)             SRC="${2:-}"; shift 2 ;;
    --files)           FILES="${2:-}"; FILES_PROVIDED=1; shift 2 ;;
    --warn-threshold)  WARN_T="${2:-30}"; shift 2 ;;
    --fail-threshold)  FAIL_T="${2:-50}"; shift 2 ;;
    -h|--help)         print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

# Scope resolution.
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

HITS_FILE=$(mktemp -t c8-funlen.XXXXXX)
WARN_FILE=$(mktemp -t c8-funlen-warn.XXXXXX)
trap 'rm -f "$HITS_FILE" "$WARN_FILE"' EXIT

# Portable awk (BSD-safe). For each Swift file, walk every line:
#   - if not in_func: detect 'func NAME' (skip 'var body: some View')
#   - inside func: count body lines; track brace depth
# Emits to stdout: file:startLine:funcName:bodyLines:LEVEL
analyze_file() {
  awk -v file="$1" -v warn="$WARN_T" -v fail="$FAIL_T" '
    function count_char(s, ch,    n, i, c) {
      n = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == ch) n++
      }
      return n
    }

    function emit(name, start, body_lines) {
      level = ""
      if (body_lines >= fail) level = "FAIL"
      else if (body_lines >= warn) level = "WARN"
      if (level != "") {
        printf("%s:%d:%s:%d:%s\n", file, start, name, body_lines, level)
      }
    }

    BEGIN {
      in_func = 0
      func_start = 0
      func_name = ""
      func_body = 0
      brace_depth = 0
    }

    {
      line = $0

      if (in_func == 0) {
        # Look for "func NAME(...)" — skip if line is part of a comment.
        # Strip leading whitespace.
        stripped = line
        sub(/^[ \t]*/, "", stripped)
        # Skip comment-only lines.
        if (stripped ~ /^\/\//) next
        # Match a func declaration. We require space after "func " and an
        # identifier following.
        if (line ~ /[[:space:]]func[[:space:]]+[A-Za-z_]/ || line ~ /^func[[:space:]]+[A-Za-z_]/) {
          # Extract func name: after the keyword "func".
          tail = line
          sub(/.*func[[:space:]]+/, "", tail)
          name = tail
          # Trim at first non-identifier char.
          gsub(/[^A-Za-z0-9_].*$/, "", name)
          if (name == "") name = "?"
          func_name = name
          func_start = NR
          func_body = 0
          in_func = 1
          # Count braces on the same line.
          n_open = count_char(line, "{")
          n_close = count_char(line, "}")
          if (n_open > 0) {
            brace_depth = n_open - n_close
            if (brace_depth <= 0) {
              # Empty body or { } on same line.
              emit(func_name, func_start, 0)
              in_func = 0
              brace_depth = 0
            }
          } else {
            brace_depth = 0
          }
          next
        }
        next
      }

      # in_func == 1
      if (brace_depth == 0) {
        # body brace not opened yet (multi-line declaration); look for {
        n_open = count_char(line, "{")
        n_close = count_char(line, "}")
        if (n_open > 0) {
          brace_depth = n_open - n_close
        }
        next
      }

      # already inside body
      func_body++
      n_open = count_char(line, "{")
      n_close = count_char(line, "}")
      brace_depth += (n_open - n_close)
      if (brace_depth <= 0) {
        emit(func_name, func_start, func_body)
        in_func = 0
        brace_depth = 0
        func_name = ""
      }
    }
  ' "$1"
}

enum_files() {
  if [ "$FILES_PROVIDED" = "1" ]; then
    # Word-split FILES on whitespace; emit each existing *.swift file null-separated.
    for f in $FILES; do
      [ -n "$f" ] && [ -f "$f" ] && [[ "$f" == *.swift ]] && printf '%s\0' "$f"
    done
  else
    find "$SRC" -name '*.swift' -type f -print0 2>/dev/null
  fi
}

while IFS= read -r -d '' file; do
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    severity="${line##*:}"
    case "$severity" in
      FAIL) printf "%s\n" "$line" >> "$HITS_FILE" ;;
      WARN) printf "%s\n" "$line" >> "$WARN_FILE" ;;
    esac
  done < <(analyze_file "$file")
done < <(enum_files)

# Report warnings.
if [ -s "$WARN_FILE" ]; then
  COUNT=$(wc -l < "$WARN_FILE" | tr -d ' ')
  echo "${C_YEL}WARN${C_RST}: ${COUNT} function(s) exceed ${WARN_T} lines (refactor recommended):"
  awk -F: '{ printf "  %s:%s  %s — %s lines\n", $1, $2, $3, $4 }' "$WARN_FILE"
fi

if [ -s "$HITS_FILE" ]; then
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: ${COUNT} function(s) exceed ${FAIL_T} lines${C_RST}:"
  awk -F: -v ft="$FAIL_T" '{ printf "  %s:%s  %s — %s lines (max %s)\n", $1, $2, $3, $4, ft }' "$HITS_FILE"
  echo "${C_DIM}fix: extract helper methods or split the function — see references/swift-style.md §2${C_RST}"
  exit 1
fi

if [ "$FILES_PROVIDED" = "1" ]; then
  echo "${C_GRN}GATE: PASS${C_RST}: all functions ≤ ${FAIL_T} lines (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
else
  echo "${C_GRN}GATE: PASS${C_RST}: all functions ≤ ${FAIL_T} lines in $SRC"
fi
exit 0
