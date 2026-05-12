#!/usr/bin/env bash
# c8-color-call-form.sh — verify every Color literal uses the right call
# form for its token category:
#
#   - Light-only tokens (emitted as `extension Color { static let X = ... }`
#     in DesignSystem/Color+Tokens.swift) MUST be referenced as `Color.X`.
#   - Dual-mode tokens (emitted as `Assets.xcassets/Colors/X.colorset`
#     with universal + dark appearances) MUST be referenced as
#     `Color(.X)`. (Xcode 15+ generates ColorResource symbols when
#     `provides-namespace: false` is set on the Colors group.)
#
# Closes Round-2 gap G28 (color-call-form ambiguity). Symptom on Bible
# Widgets: `b0b-tokens-codegen.sh` emitted some tokens as static let
# (light-only) and others as colorsets (dual-mode). Agent wrote
# `Color(.appBlack)` (assuming colorset) but appBlack was light-only →
# compile error `Reference to member 'appBlack' cannot be resolved
# without a contextual type`. Affected 3 files, required bulk rewrite.
#
# Usage:
#   scripts/c8-color-call-form.sh --src <swift-src-root>
#                                 [--color-tokens <Color+Tokens.swift>]
#                                 [--xcassets <Assets.xcassets>]
#
# Auto-discovery: when --color-tokens / --xcassets are omitted, the
# script searches under --src up to depth 6 for the canonical files.
#
# Exit codes:
#   0 — PASS (no mismatched call forms)
#   1 — FAIL (one or more wrong-form references)
#  64 — bad usage

set -uo pipefail

SRC=""
COLOR_TOKENS=""
XCASSETS=""

while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="$2"; shift 2 ;;
    --color-tokens) COLOR_TOKENS="$2"; shift 2 ;;
    --xcassets) XCASSETS="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$SRC" ] || { echo "usage: c8-color-call-form.sh --src <path>" >&2; exit 64; }
[ -d "$SRC" ] || { echo "FAIL: --src not a directory: $SRC" >&2; exit 64; }

# Auto-discovery
if [ -z "$COLOR_TOKENS" ]; then
  COLOR_TOKENS=$(find "$SRC" -maxdepth 6 -type f -name 'Color+Tokens.swift' 2>/dev/null | head -1)
fi
if [ -z "$XCASSETS" ]; then
  XCASSETS=$(find "$SRC" -maxdepth 6 -type d -name '*.xcassets' 2>/dev/null | head -1)
fi

# ── Build name sets ───────────────────────────────────────────────────────────
# Light-only set: `static let X` inside `extension Color { ... }` blocks of
# Color+Tokens.swift. Use a python parse for robustness — bash sed on
# Swift extensions is fragile.
LIGHT_ONLY=""
if [ -n "$COLOR_TOKENS" ] && [ -f "$COLOR_TOKENS" ]; then
  LIGHT_ONLY=$(python3 - "$COLOR_TOKENS" <<'PY' 2>/dev/null
import re, sys
text = open(sys.argv[1]).read()
# Match `static let X` AND `static let X = Color(...)` — both forms.
names = re.findall(r'static\s+let\s+([A-Za-z_][A-Za-z0-9_]*)', text)
for n in sorted(set(names)):
    print(n)
PY
  )
fi

# Dual-mode set: colorset directory names under <xcassets>/**/*.colorset.
DUAL_MODE=""
if [ -n "$XCASSETS" ] && [ -d "$XCASSETS" ]; then
  DUAL_MODE=$(find "$XCASSETS" -type d -name '*.colorset' 2>/dev/null \
              | sed -E 's|.*/||; s|\.colorset$||' \
              | sort -u)
fi

LIGHT_COUNT=$(printf '%s\n' "$LIGHT_ONLY" | grep -c . || echo 0)
DUAL_COUNT=$(printf '%s\n' "$DUAL_MODE" | grep -c . || echo 0)

# Both empty → nothing to check (project doesn't have token codegen yet).
# Emit SKIP rather than PASS so it's visible the gate didn't actually run.
if [ "$LIGHT_COUNT" -eq 0 ] && [ "$DUAL_COUNT" -eq 0 ]; then
  echo "SKIP: neither Color+Tokens.swift static lets nor Colors.xcassets colorsets found"
  echo "  COLOR_TOKENS: ${COLOR_TOKENS:-<not found>}"
  echo "  XCASSETS:     ${XCASSETS:-<not found>}"
  exit 0
fi

# ── Helper: is name in a set? ────────────────────────────────────────────────
in_set() {
  local name="$1" set="$2"
  printf '%s\n' "$set" | grep -qFx "$name"
}

# ── Scan Swift for Color.X / Color(.X) literals ──────────────────────────────
VIOL_DUAL_AS_LIGHT=()   # `Color.X` used but X is dual-mode → should be `Color(.X)`
VIOL_LIGHT_AS_DUAL=()   # `Color(.X)` used but X is light-only → should be `Color.X`

# `Color.X` form. BSD sed lacks `\b`, so use grep -oE for name extraction
# (POSIX char class + literal `Color.` prefix). Filter `Color.init|self|Type`
# upstream so the loop only sees real `Color.<tokenName>` literals.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  file="${line%%:*}"; rest="${line#*:}"
  lineno="${rest%%:*}"; content="${rest#*:}"
  match=$(printf '%s\n' "$content" | grep -oE 'Color\.[A-Za-z_][A-Za-z0-9_]*' | head -1)
  name="${match#Color.}"
  [ -z "$name" ] && continue
  # SwiftUI built-ins are NOT in either set; ignore them.
  case "$name" in
    primary|secondary|accentColor|black|white|gray|red|green|blue|orange|pink|purple|yellow|clear|indigo|mint|teal|cyan|brown) continue ;;
  esac
  if in_set "$name" "$DUAL_MODE"; then
    VIOL_DUAL_AS_LIGHT+=("$file:$lineno: Color.$name — colorset (dual-mode), use Color(.$name)")
  fi
done < <(grep -RHnE 'Color\.[A-Za-z_][A-Za-z0-9_]*' --include='*.swift' "$SRC" 2>/dev/null \
         | grep -vE 'Color\.(init|self|Type)\b' || true)

# `Color(.X)` form. Same approach — grep -oE for name extraction.
while IFS= read -r line; do
  [ -z "$line" ] && continue
  file="${line%%:*}"; rest="${line#*:}"
  lineno="${rest%%:*}"; content="${rest#*:}"
  # Extract the part after `Color(` then strip the leading `.`.
  match=$(printf '%s\n' "$content" | grep -oE 'Color\([[:space:]]*\.[A-Za-z_][A-Za-z0-9_]*' | head -1)
  # Strip "Color(<spaces>." prefix to get just the token name.
  name=$(printf '%s\n' "$match" | sed -E 's/^Color\([[:space:]]*\.//')
  [ -z "$name" ] && continue
  if in_set "$name" "$LIGHT_ONLY"; then
    VIOL_LIGHT_AS_DUAL+=("$file:$lineno: Color(.$name) — light-only static let, use Color.$name")
  fi
done < <(grep -RHnE 'Color\([[:space:]]*\.[A-Za-z_][A-Za-z0-9_]*' --include='*.swift' "$SRC" 2>/dev/null || true)

# ── Report ────────────────────────────────────────────────────────────────────
TOTAL_VIOL=$((${#VIOL_DUAL_AS_LIGHT[@]} + ${#VIOL_LIGHT_AS_DUAL[@]}))

if [ "$TOTAL_VIOL" -eq 0 ]; then
  echo "PASS: $LIGHT_COUNT light-only tokens + $DUAL_COUNT dual-mode tokens; all call sites use the matching form."
  echo "GATE: PASS (c8-color-call-form)"
  exit 0
fi

if [ ${#VIOL_DUAL_AS_LIGHT[@]} -gt 0 ]; then
  echo "WRONG FORM — used Color.X for a dual-mode token (${#VIOL_DUAL_AS_LIGHT[@]}):"
  for v in "${VIOL_DUAL_AS_LIGHT[@]}"; do echo "  $v"; done
fi
if [ ${#VIOL_LIGHT_AS_DUAL[@]} -gt 0 ]; then
  echo "WRONG FORM — used Color(.X) for a light-only token (${#VIOL_LIGHT_AS_DUAL[@]}):"
  for v in "${VIOL_LIGHT_AS_DUAL[@]}"; do echo "  $v"; done
fi

echo "GATE: FAIL: $TOTAL_VIOL color call-form violations"
echo "  light-only (Color.X):  $LIGHT_COUNT tokens in $COLOR_TOKENS"
echo "  dual-mode (Color(.X)): $DUAL_COUNT colorsets in $XCASSETS"
exit 1
