#!/usr/bin/env bash
# c3-static-checks.sh — run Pass 3, Pass 3b, and Pass 4 Part A in one call.
#
# Replaces the three separate bash blocks in figma-to-swiftui/SKILL.md
# Step C3 (Pass 3 asset substitution + Pass 3b system chrome + Pass 4
# swiftui-pro Review). Same greps, same exit semantics — just consolidated
# so the agent pays one bash startup instead of three, and so re-runs after
# self-fix loop iterations are cheap.
#
# Each section prints its own GATE: PASS / FAIL / REVIEW lines (REVIEW is
# informational, does NOT fail the driver). The driver exits 1 if any
# enforcing check failed.
#
# Pass 4 Part B (the manual structural walk per file) is NOT in this script —
# it requires agent reading + judgment. Keep doing that by hand against
# references/swiftui-pro-bridge.md §4.
#
# Usage:
#   c3-static-checks.sh --files "<space-separated swift paths>" --target <iOS-major>
#   c3-static-checks.sh --files-from <file-with-paths-one-per-line> --target 16
#
# Exit codes:
#   0 — Pass 3 + 3b + Pass 4 Part A bash sweep all clean
#   1 — at least one enforcing check failed
#  64 — bad usage
#  65 — input file missing or empty file list

set -uo pipefail

FILES=""
FILES_FROM=""
TARGET=""

print_usage() {
  cat <<'USAGE' >&2
usage: c3-static-checks.sh
       --files "<space-separated swift paths>"
       --target <iOS-major>
   or
       --files-from <list-file>   # one path per line
       --target <iOS-major>

Runs Pass 3 (asset substitution scan), Pass 3b (system chrome scan), and
Pass 4 Part A (12-check swiftui-pro bash sweep) — same greps as the SKILL.md
blocks, consolidated. Pass 4 Part B (manual structural walk) is separate.

Target is the iOS deployment major (e.g. 16 / 17 / 18). iOS 16 fallback
checks fire when target < 17; iOS 18 checks when target < 18.

Exit 0 if every enforcing check passes (informational REVIEW lines do not
fail). Exit 1 if any FAIL.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --files)      FILES="${2:-}"; shift 2 ;;
    --files-from) FILES_FROM="${2:-}"; shift 2 ;;
    --target)     TARGET="${2:-}"; shift 2 ;;
    -h|--help)    print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

# Resolve file list.
if [ -n "$FILES_FROM" ]; then
  [ -s "$FILES_FROM" ] || { echo "FAIL: --files-from is empty: $FILES_FROM" >&2; exit 65; }
  # Read each line, skip blanks/comments, validate existence later.
  FILES=$(grep -v '^[[:space:]]*\(#\|$\)' "$FILES_FROM" | tr '\n' ' ')
fi

[ -n "$FILES"  ] || { print_usage; exit 64; }
[ -n "$TARGET" ] || { print_usage; exit 64; }
case "$TARGET" in
  ''|*[!0-9]*) echo "FAIL: --target must be a number (got: $TARGET)" >&2; exit 64 ;;
esac

# Validate every path. A dangling path is a bigger bug than a violation —
# fail loud so the user fixes the manifest, not the agent's grep.
MISSING=""
for f in $FILES; do
  [ -f "$f" ] || MISSING="$MISSING $f"
done
if [ -n "$MISSING" ]; then
  echo "FAIL: missing swift file(s):$MISSING" >&2
  exit 65
fi

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

FAIL=0
ok()   { echo "${C_GRN}PASS${C_RST}: $1"; }
bad()  { echo "${C_RED}FAIL${C_RST}: $1"; FAIL=1; }
warn() { echo "${C_YEL}REVIEW${C_RST}: $1"; }

# ──────────────────────────────────────────────────────────────────────────
echo "== Pass 3 — asset substitution =="
# (Only enforcing check; SF Symbol allow-list is enforced by the
# banned-pattern PreToolUse hook, not by this grep — this grep is the
# session-end safety net.)
HITS=$(grep -nE 'Image\(systemName:' $FILES 2>/dev/null || true)
if [ -z "$HITS" ]; then
  ok "no SF Symbol substitution"
else
  bad "SF Symbol used where Figma asset expected:"
  echo "$HITS"
fi

# ──────────────────────────────────────────────────────────────────────────
echo
echo "== Pass 3b — system chrome =="
CHROME=$(grep -nE '"9:41"|Image\(systemName: "(wifi|battery|cellularbars|antenna|dot\.radiowaves)"\)|StatusBar|HomeIndicator|DynamicIsland' $FILES 2>/dev/null || true)
if [ -z "$CHROME" ]; then
  ok "no system-chrome drawing"
else
  bad "system chrome drawn in view (delete — iOS renders it):"
  echo "$CHROME"
fi

# Visual home-indicator lookalike — Capsule()/RoundedRectangle()/Rectangle
# at width≈134 and height≈5 is the home indicator that iOS already draws.
HOME_IND=$(grep -nE '(Capsule|RoundedRectangle|Rectangle)\(\)[^/]*\.frame\([^)]*width:[[:space:]]*13[0-9]' $FILES 2>/dev/null || true)
if [ -z "$HOME_IND" ]; then
  ok "no home-indicator lookalike"
else
  warn "possible home-indicator redraw (verify visually):"
  echo "$HOME_IND"
fi

# ──────────────────────────────────────────────────────────────────────────
echo
echo "== Pass 4 Part A — swiftui-pro bash sweep (target iOS $TARGET) =="

# (1) Modern API hits — always-on
H_API=$(grep -nE 'foregroundColor\(|fontWeight\(\.bold\)|showsIndicators:|UIScreen\.main\.bounds|onChange\(of:.*\) \{ [^_]' $FILES 2>/dev/null || true)
[ -z "$H_API" ] && ok "(1) api.md (always-on)" || { bad "(1) api.md violations:"; echo "$H_API"; }

# (2) Deprecated cornerRadius — ALWAYS wrong; iOS 16 must use RoundedRectangle.
H_CR=$(grep -nE '\.cornerRadius\(' $FILES 2>/dev/null || true)
[ -z "$H_CR" ] && ok "(2) no .cornerRadius()" || { bad "(2) replace .cornerRadius() with .clipShape(RoundedRectangle(cornerRadius:)) on iOS 16:"; echo "$H_CR"; }

# (3a) iOS 17+ APIs forbidden when target < 17
if [ "$TARGET" -lt 17 ]; then
  H17=$(grep -nE '\.topBarLeading|\.topBarTrailing|\.rect\(cornerRadius:|@Observable\b|@Bindable\b' $FILES 2>/dev/null || true)
  [ -z "$H17" ] && ok "(3a) no iOS 17+ APIs on iOS $TARGET" || { bad "(3a) iOS 17+ API used but target is $TARGET (use fallbacks per swiftui-pro-bridge.md §6):"; echo "$H17"; }
fi

# (3b) iOS 18+ APIs forbidden when target < 18
if [ "$TARGET" -lt 18 ]; then
  H18=$(grep -nE 'Tab\("|@Entry\b' $FILES 2>/dev/null || true)
  [ -z "$H18" ] && ok "(3b) no iOS 18+ APIs on iOS $TARGET" || { bad "(3b) iOS 18+ API used but target is $TARGET:"; echo "$H18"; }
fi

# (4) Views & previews
H_VIEWS=$(grep -nE 'PreviewProvider|AnyView' $FILES 2>/dev/null || true)
[ -z "$H_VIEWS" ] && ok "(4) views.md/performance.md" || { bad "(4) views/perf:"; echo "$H_VIEWS"; }

# (5) Concurrency
H_CON=$(grep -nE 'DispatchQueue\.|Task\.sleep\(nanoseconds:|Task\.detached' $FILES 2>/dev/null || true)
[ -z "$H_CON" ] && ok "(5) swift.md concurrency" || { bad "(5) concurrency:"; echo "$H_CON"; }

# (6) Manual Binding(get:set:)
H_BIND=$(grep -nE 'Binding\(get:.*set:' $FILES 2>/dev/null || true)
[ -z "$H_BIND" ] && ok "(6) data.md bindings" || { bad "(6) manual Binding(get:set:):"; echo "$H_BIND"; }

# (7) Deprecated navigation
H_NAV=$(grep -nE 'NavigationView\b|NavigationLink\(destination:' $FILES 2>/dev/null || true)
[ -z "$H_NAV" ] && ok "(7) navigation.md" || { bad "(7) deprecated navigation:"; echo "$H_NAV"; }

# (8) Image without label or decorative marker (within 5-line window)
ORPHAN_IMAGE=$(python3 - "$FILES" <<'PY' 2>/dev/null
import re, pathlib, sys
files = sys.argv[1].split()
for f in files:
    try:
        text = pathlib.Path(f).read_text()
    except Exception:
        continue
    lines = text.splitlines()
    for i, line in enumerate(lines, 1):
        if re.search(r'Image\([\"\.]', line) and 'decorative' not in line and 'systemName:' not in line:
            window = '\n'.join(lines[i-1:i+5])
            if 'accessibilityLabel' not in window and 'accessibilityHidden' not in window:
                print(f'{f}:{i}: {line.strip()}')
PY
)
[ -z "$ORPHAN_IMAGE" ] && ok "(8) image accessibility" || { warn "(8) images missing label/decorative:"; echo "$ORPHAN_IMAGE"; }

# (9) Force unwrap (informational)
H_BANG=$(grep -nE '![\.[]' $FILES 2>/dev/null | grep -v '!=' | grep -v '//' || true)
[ -z "$H_BANG" ] && ok "(9) no force unwraps" || warn "(9) force unwraps (verify each is unrecoverable):"

# (10) Text concatenation with +
H_TXT=$(grep -nE 'Text\([^)]+\)\s*\+\s*Text\(' $FILES 2>/dev/null || true)
[ -z "$H_TXT" ] && ok "(10) no Text +" || { bad "(10) Text concatenation with +:"; echo "$H_TXT"; }

# (11) onTapGesture for actions (REVIEW — should be Button unless tap location/count needed)
H_TAP=$(grep -nE '\.onTapGesture\s*\{' $FILES 2>/dev/null || true)
[ -z "$H_TAP" ] && ok "(11) no onTapGesture for actions" || warn "(11) onTapGesture — convert to Button unless tap location/count needed:"

# (12) iOS 16 fallback comment marker presence (when target < 17)
if [ "$TARGET" -lt 17 ]; then
  CHROME_NAV=$(grep -nE 'navigationBarLeading|navigationBarTrailing|RoundedRectangle\(cornerRadius:' $FILES 2>/dev/null || true)
  if [ -n "$CHROME_NAV" ]; then
    MISSING_MARK=$(echo "$CHROME_NAV" | while IFS= read -r line; do
      [ -z "$line" ] && continue
      f=$(echo "$line" | cut -d: -f1)
      n=$(echo "$line" | cut -d: -f2)
      ctx=$(sed -n "$((n-2)),$((n+2))p" "$f" 2>/dev/null)
      echo "$ctx" | grep -q "iOS 16 fallback" || echo "$line"
    done)
    if [ -z "$MISSING_MARK" ]; then
      ok "(12) iOS 16 fallback markers present"
    else
      warn "(12) iOS 16 fallback used but missing comment marker:"
      echo "$MISSING_MARK"
    fi
  else
    ok "(12) no iOS 16 fallback APIs to mark"
  fi
fi

# ──────────────────────────────────────────────────────────────────────────
echo
if [ "$FAIL" -eq 0 ]; then
  echo "${C_GRN}GATE: PASS${C_RST} (Pass 3 + 3b + Pass 4 Part A)"
  exit 0
else
  echo "${C_RED}GATE: FAIL${C_RST} (Pass 3 + 3b + Pass 4 Part A) — DO NOT proceed to C4"
  exit 1
fi
