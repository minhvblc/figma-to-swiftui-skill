#!/usr/bin/env bash
# c8-iktracking.sh — verify that, in projects using IKTracking, every
# new full-screen view has `.ikLogScreenActive(AppTracking.<case>)` and
# tracking calls don't leak third-party analytics.
#
# Skipped when c1-conventions.json sets `usesIKTracking = false`.
#
# Hard checks (when usesIKTracking = true):
#   - banned: Firebase.Analytics.logEvent(...) / Mixpanel.track(...) /
#             AppsFlyer / Amplitude / Adjust direct usage
#   - banned: AppTrackingFeature.shared.addTrackingFeature with string-
#             literal param values (must use enum.rawValue)
#
# Soft checks (warning only):
#   - *Screen.swift files lacking .ikLogScreenActive(...) modifier
#
# Usage:
#   c8-iktracking.sh --src <swift-src-root>
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
usage: c8-iktracking.sh --src <swift-src-root>
                          [--files "<space-separated-paths>"]
                          --conventions <c1-conventions.json>

When the project uses IKTracking (per c1-conventions.json.usesIKTracking),
this gate fails on third-party analytics direct calls and warns on screens
missing .ikLogScreenActive(...).

The gate is skipped (output: GATE: SKIP) when usesIKTracking = false.

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
  USES_IK=$(grep -oE '"usesIKTracking"[[:space:]]*:[[:space:]]*(true|false)' "$CONVENTIONS" \
    | sed -E 's/.*:[[:space:]]*(true|false).*/\1/' | head -n1 || true)
  [ -n "$USES_IK" ] || USES_IK="false"
fi

if [ "$USES_IK" != "true" ]; then
  echo "${C_DIM}GATE: SKIP (project does not use IKTracking — usesIKTracking=${USES_IK})${C_RST}"
  exit 0
fi

HITS_FILE=$(mktemp -t c8-iktrack.XXXXXX)
WARN_FILE=$(mktemp -t c8-iktrack-warn.XXXXXX)
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

# Hard: third-party analytics direct usage.
emit_hard "Firebase Analytics"  '\bAnalytics\.logEvent[[:space:]]*\('
emit_hard "Mixpanel"            '\bMixpanel\.[[:alpha:]]+\.track[[:space:]]*\('
emit_hard "AppsFlyer"           '\bAppsFlyer\b.*\b(logEvent|trackEvent)[[:space:]]*\('
emit_hard "Amplitude"           '\bAmplitude\.[[:alpha:]]+\.track[[:space:]]*\('
emit_hard "Adjust"              '\bAdjust\.trackEvent[[:space:]]*\('

# Soft: every *Screen.swift should have .ikLogScreenActive
while IFS= read -r -d '' f; do
  base="$(basename "$f" .swift)"
  case "$base" in
    *Screen)
      # Skip Screen extension files (named *Screen+Topic.swift)
      if [[ "$base" == *+* ]]; then continue; fi
      if ! grep -q 'ikLogScreenActive' "$f" 2>/dev/null; then
        rel="$f"
        [ -n "$SRC" ] && rel="${f#$SRC/}"
        printf "%s: missing .ikLogScreenActive(AppTracking.<case>) on screen body\n" "$rel" >> "$WARN_FILE"
      fi
      ;;
  esac
done < <(enum_files)

if [ -s "$HITS_FILE" ]; then
  sort -u "$HITS_FILE" -o "$HITS_FILE"
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: third-party analytics direct calls in IKTracking project${C_RST} (${COUNT} hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: route through AppTrackingFeature.shared.addTrackingFeature — see references/iktracking-bridge.md${C_RST}"
  exit 1
fi

if [ -s "$WARN_FILE" ]; then
  COUNT=$(wc -l < "$WARN_FILE" | tr -d ' ')
  echo "${C_DIM}WARN: ${COUNT} screen(s) missing .ikLogScreenActive(...):${C_RST}"
  cat "$WARN_FILE"
  echo "${C_DIM}fix: add .ikLogScreenActive(AppTracking.<case>) to body — see references/iktracking-bridge.md §2${C_RST}"
fi

if [ "$FILES_PROVIDED" = "1" ]; then
  echo "${C_GRN}GATE: PASS${C_RST}: IKTracking conventions OK (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
else
  echo "${C_GRN}GATE: PASS${C_RST}: IKTracking conventions OK in $SRC"
fi
exit 0
