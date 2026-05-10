#!/usr/bin/env bash
# c8-ikfeedback.sh — verify that, in projects using Ikame feedback
# (IKLoading / IKHaptics / AppUtils toast), generated SwiftUI does NOT
# fall back to UIKit / iOS-native equivalents.
#
# Skipped when c1-conventions.json sets `usesIKFeedback = false`.
#
# Hard checks (when usesIKFeedback = true):
#   - banned: UIImpactFeedbackGenerator / UISelectionFeedbackGenerator /
#             UINotificationFeedbackGenerator
#   - banned: .sensoryFeedback(...) view modifier (iOS 17+ haptics)
#   - banned: third-party toast/HUD imports (SwiftMessages, SVProgressHUD,
#             MBProgressHUD)
#
# Soft checks (warning only):
#   - IKLoading.showLoading() without paired IKLoading.dismissLoading()
#     in same file (defer counts)
#
# Usage:
#   c8-ikfeedback.sh --src <swift-src-root>
#                    [--files "<space-separated-paths>"]
#                    --conventions <c1-conventions.json>
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
usage: c8-ikfeedback.sh --src <swift-src-root>
                          [--files "<space-separated-paths>"]
                          --conventions <c1-conventions.json>

When the project uses Ikame feedback (per c1-conventions.json.usesIKFeedback),
this gate fails on UIImpactFeedbackGenerator / UISelectionFeedbackGenerator /
.sensoryFeedback(...) / third-party HUD imports.

The gate is skipped (output: GATE: SKIP) when usesIKFeedback = false.

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
  USES_IK=$(grep -oE '"usesIKFeedback"[[:space:]]*:[[:space:]]*(true|false)' "$CONVENTIONS" \
    | sed -E 's/.*:[[:space:]]*(true|false).*/\1/' | head -n1 || true)
  [ -n "$USES_IK" ] || USES_IK="false"
fi

if [ "$USES_IK" != "true" ]; then
  echo "${C_DIM}GATE: SKIP (project does not use Ikame feedback — usesIKFeedback=${USES_IK})${C_RST}"
  exit 0
fi

HITS_FILE=$(mktemp -t c8-ikfb.XXXXXX)
WARN_FILE=$(mktemp -t c8-ikfb-warn.XXXXXX)
trap 'rm -f "$HITS_FILE" "$WARN_FILE"' EXIT

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

# Hard violations.
emit_hard "UIImpactFeedback"     '\bUIImpactFeedbackGenerator\b'
emit_hard "UISelectionFeedback"  '\bUISelectionFeedbackGenerator\b'
emit_hard "UINotificationFeedback" '\bUINotificationFeedbackGenerator\b'
emit_hard "sensoryFeedback"      '\.sensoryFeedback[[:space:]]*\('
emit_hard "SwiftMessages"        '\bimport[[:space:]]+SwiftMessages\b'
emit_hard "SVProgressHUD"        '\bimport[[:space:]]+SVProgressHUD\b'
emit_hard "MBProgressHUD"        '\bimport[[:space:]]+MBProgressHUD\b'

# Soft warning: IKLoading.showLoading without paired dismissLoading
# (or `defer { IKLoading.dismissLoading() }`) in same file.
while IFS= read -r -d '' f; do
  if grep -q 'IKLoading\.showLoading' "$f" 2>/dev/null; then
    if ! grep -qE 'IKLoading\.dismissLoading|defer[^{]*IKLoading\.dismissLoading' "$f" 2>/dev/null; then
      rel="$f"
      [ -n "$SRC" ] && rel="${f#$SRC/}"
      printf "%s: IKLoading.showLoading() without paired dismissLoading (or defer)\n" "$rel" >> "$WARN_FILE"
    fi
  fi
done < <(enum_files)

if [ -s "$HITS_FILE" ]; then
  sort -u "$HITS_FILE" -o "$HITS_FILE"
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: non-Ikame feedback APIs in IKFeedback project${C_RST} (${COUNT} hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: use IKHaptics / IKLoading / AppUtils.shared.showAppBottomToast — see references/ikfeedback-bridge.md${C_RST}"
  exit 1
fi

if [ -s "$WARN_FILE" ]; then
  COUNT=$(wc -l < "$WARN_FILE" | tr -d ' ')
  echo "${C_DIM}WARN: ${COUNT} file(s) call IKLoading.showLoading() without paired dismiss:${C_RST}"
  cat "$WARN_FILE"
fi

if [ "$FILES_PROVIDED" = "1" ]; then
  echo "${C_GRN}GATE: PASS${C_RST}: Ikame feedback conventions OK (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
else
  echo "${C_GRN}GATE: PASS${C_RST}: Ikame feedback conventions OK in $SRC"
fi
exit 0
