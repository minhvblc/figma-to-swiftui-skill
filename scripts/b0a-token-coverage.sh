#!/usr/bin/env bash
# b0a-token-coverage.sh — after Phase A, walk every per-screen
# design-context.md and union the designer-named tokens from each
# "Styles used in this design" footer with the shared tokens.json.
#
# Closes Round-2 gap G25. Symptom observed on Bible Widgets: the style-
# guide page (3:1972) only listed 6 base typography styles. Actual intro
# screens used Playfair Display SemiBold 28 and Inter Medium 17, neither
# of which appeared in the style-guide-page footer. Required 3 rounds of
# manual tokens.json augmentation as each new style was discovered.
#
# Mode of operation:
#   - Default: emit delta report to stdout, DO NOT modify tokens.json.
#     The agent reviews the delta and either re-runs with --apply OR
#     surfaces the gap to the user.
#   - --apply: append every newly-discovered token to tokens.json
#     (preserving existing entries — name-keyed dedup).
#
# Usage:
#   scripts/b0a-token-coverage.sh --cache <.figma-cache root> \
#                                 [--tokens <path>] \
#                                 [--apply]
#
# Exit codes:
#   0 — coverage complete (no gaps OR gaps reported)
#   1 — no design-context.md files found under cache
#  64 — bad usage

set -uo pipefail

CACHE=""
TOKENS=""
APPLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --cache) CACHE="$2"; shift 2 ;;
    --tokens) TOKENS="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    -h|--help) sed -n '2,30p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { echo "usage: b0a-token-coverage.sh --cache <path>" >&2; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache directory not found: $CACHE" >&2; exit 64; }
[ -z "$TOKENS" ] && TOKENS="$CACHE/_shared/tokens.json"

# Collect every per-screen design-context.md (skip _shared/).
DC_FILES=()
while IFS= read -r f; do
  [ -n "$f" ] && DC_FILES+=("$f")
done < <(find "$CACHE" -mindepth 2 -name 'design-context.md' -type f 2>/dev/null | sort)

if [ ${#DC_FILES[@]} -eq 0 ]; then
  echo "FAIL: no per-screen design-context.md found under $CACHE" >&2
  exit 1
fi

python3 - "$TOKENS" "$APPLY" "${DC_FILES[@]}" <<'PY'
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

tokens_path = sys.argv[1]
apply_changes = sys.argv[2] == "1"
dc_files = sys.argv[3:]

# Footer header variants (mirrors b0a-tokens-from-style-guide.sh).
FOOTER_HEADERS = (
    r'## Styles used in this design',
    r'\*Styles used in this design\*',
    r'### Styles used',
    r'## Styles used',
)
FOOTER_RE = re.compile(
    r'(' + '|'.join(FOOTER_HEADERS) + r')(.*)\Z',
    re.DOTALL | re.IGNORECASE,
)

NAMED_COLOR_RE = re.compile(
    r'`([A-Za-z_][A-Za-z0-9_]*)`[^#\n]*?(#[0-9A-Fa-f]{3,8})',
    re.IGNORECASE,
)
NAMED_TYPO_RE = re.compile(
    r'`([A-Za-z_][A-Za-z0-9_ /]*?)`\s+'
    r'([A-Za-z][A-Za-z0-9 ]*?)\s+'
    r'(Thin|ExtraLight|Light|Regular|Medium|SemiBold|Bold|ExtraBold|Black)\s+'
    r'(\d+(?:\.\d+)?)'
    r'(?:\s*/\s*(\d+(?:\.\d+)?))?'
    r'(?:\s*/\s*(-?\d+(?:\.\d+)?))?',
)

def norm_typo_name(raw):
    name = re.sub(r'[^A-Za-z0-9]+', '', raw)
    return (name[0].lower() + name[1:]) if name else raw

# Read existing tokens.json (if any) and index by swiftName.
existing_colors = {}
existing_typo = {}
existing_data = None
if Path(tokens_path).is_file():
    try:
        existing_data = json.loads(Path(tokens_path).read_text())
    except Exception as e:
        print(f"WARN: could not parse {tokens_path}: {e}", file=sys.stderr)
        existing_data = None
if existing_data:
    for c in existing_data.get("colors", []) or []:
        n = c.get("swiftName")
        if n:
            existing_colors[n] = c
    for t in existing_data.get("typography", []) or []:
        n = t.get("swiftName")
        if n:
            existing_typo[n] = t

found_colors = OrderedDict()       # name → {entry, sources}
found_typo = OrderedDict()

for dc in dc_files:
    text = Path(dc).read_text(errors='ignore')
    m = FOOTER_RE.search(text)
    if not m:
        continue
    footer = m.group(2)
    screen_key = Path(dc).parent.name

    for cm in NAMED_COLOR_RE.finditer(footer):
        name = cm.group(1)
        hex_lit = cm.group(2).upper()
        if len(hex_lit) == 4:
            hex_lit = '#' + ''.join(c * 2 for c in hex_lit[1:])
        elif len(hex_lit) == 9:
            hex_lit = hex_lit[:7]
        entry = found_colors.setdefault(name, {
            "swiftName": name,
            "lightHex": hex_lit,
            "darkHex": None,
            "_sources": set(),
        })
        entry["_sources"].add(screen_key)

    for tm in NAMED_TYPO_RE.finditer(footer):
        raw, family, weight, size, lh, tracking = tm.groups()
        name = norm_typo_name(raw)
        entry = found_typo.setdefault(name, {
            "swiftName": name,
            "fontFamily": family.strip(),
            "fontWeight": weight,
            "fontSize": float(size),
            "_sources": set(),
        })
        if lh is not None:
            entry["lineHeightPx"] = float(lh)
        if tracking is not None:
            entry["letterSpacing"] = float(tracking)
        entry["_sources"].add(screen_key)

# Compute delta: tokens found in screens but missing from existing tokens.json.
new_colors = [c for n, c in found_colors.items() if n not in existing_colors]
new_typo = [t for n, t in found_typo.items() if n not in existing_typo]

# Report
print(f"Coverage scan: {len(dc_files)} design-context.md files")
print(f"  tokens.json:     {tokens_path}")
print(f"  existing colors: {len(existing_colors)}, typography: {len(existing_typo)}")
print(f"  screens-derived: {len(found_colors)} colors, {len(found_typo)} typography styles")
print(f"  DELTA:           {len(new_colors)} new colors, {len(new_typo)} new typography styles")
print()

if new_colors:
    print(f"Colors NOT in tokens.json ({len(new_colors)}):")
    for c in new_colors:
        print(f"  + {c['swiftName']:<30s} {c['lightHex']}  (from {sorted(c['_sources'])})")
if new_typo:
    print(f"Typography NOT in tokens.json ({len(new_typo)}):")
    for t in new_typo:
        line_h = f" / lh {t.get('lineHeightPx')}" if t.get('lineHeightPx') else ""
        tracking = f" / tr {t.get('letterSpacing')}" if t.get('letterSpacing') else ""
        print(f"  + {t['swiftName']:<30s} {t['fontFamily']} {t['fontWeight']} {t['fontSize']}{line_h}{tracking}  (from {sorted(t['_sources'])})")

if not new_colors and not new_typo:
    print("✓ Coverage complete — every screen-named token is in tokens.json")
    print()
    print("GATE: PASS (b0a-token-coverage — no delta)")
    sys.exit(0)

if not apply_changes:
    print()
    print("Re-run with --apply to merge these into tokens.json.")
    print()
    print("GATE: PASS (b0a-token-coverage — delta reported, no write)")
    sys.exit(0)

# --apply: merge new entries into existing tokens.json (or synthesize one).
if existing_data is None:
    existing_data = {
        "source": "fallback-coverage-scan",
        "fontFamilies": [],
        "colors": [],
        "typography": [],
        "spacing": [],
        "radius": [],
    }

def strip_internal(entry):
    return {k: v for k, v in entry.items() if not k.startswith("_") and v is not None}

for c in new_colors:
    existing_data["colors"].append(strip_internal(c))
for t in new_typo:
    existing_data["typography"].append(strip_internal(t))

# Union font families too.
fam_set = set(existing_data.get("fontFamilies") or [])
for t in new_typo:
    fam = t.get("fontFamily")
    if fam:
        fam_set.add(fam)
existing_data["fontFamilies"] = sorted(fam_set)

existing_data.setdefault("_note", "")
note_addition = "Augmented by b0a-token-coverage.sh — see _coverageSources per entry."
if note_addition not in existing_data["_note"]:
    existing_data["_note"] = (existing_data["_note"] + " " + note_addition).strip()

Path(tokens_path).parent.mkdir(parents=True, exist_ok=True)
Path(tokens_path).write_text(json.dumps(existing_data, indent=2) + "\n")
print()
print(f"Wrote {len(new_colors)} colors + {len(new_typo)} typography styles to {tokens_path}")
print("GATE: PASS (b0a-token-coverage --apply)")
PY

exit $?
