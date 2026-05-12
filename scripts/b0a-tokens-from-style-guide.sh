#!/usr/bin/env bash
# b0a-tokens-from-style-guide.sh — bootstrap tokens.json from a single
# Figma style-guide page's design-context.md.
#
# Closes Round-2 gap G24. The existing `b0a-tokens-from-design-context.sh`
# walks EVERY design-context.md under the cache root and merges hex/size
# literals. That's the right tool for "I have Phase A done for many
# screens, synthesize tokens from everything". But the canonical pre-
# Phase-A workflow is "fetch the style guide first → emit tokens →
# implement screens". For that, we need a one-file extractor that ALSO
# reads the "Styles used in this design" footer (designer-named tokens),
# not just raw hex/size literals.
#
# Usage:
#   scripts/b0a-tokens-from-style-guide.sh --design-context <path> \
#                                          [--output <tokens.json>]
#
# Input: a design-context.md file the agent already fetched via
#   mcp__figma-desktop__get_design_context(fileKey, styleGuideNodeId, ...)
# and saved to disk.
#
# Output: tokens.json with the same shape as figma_extract_tokens (colors,
# typography, fontFamilies), tagged `"source": "fallback-style-guide"`.
#
# Exit codes:
#   0 — tokens.json synthesized
#   1 — input file empty / unreadable
#  64 — bad usage

set -uo pipefail

DESIGN_CONTEXT=""
OUTPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --design-context) DESIGN_CONTEXT="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$DESIGN_CONTEXT" ] || { echo "usage: b0a-tokens-from-style-guide.sh --design-context <path>" >&2; exit 64; }
[ -s "$DESIGN_CONTEXT" ] || { echo "FAIL: design-context.md not found or empty: $DESIGN_CONTEXT" >&2; exit 1; }

if [ -z "$OUTPUT" ]; then
  # Default: place next to design-context.md, under _shared/ if cache layout.
  PARENT=$(dirname "$DESIGN_CONTEXT")
  if [ -d "$PARENT/../_shared" ]; then
    OUTPUT="$PARENT/../_shared/tokens.json"
  else
    OUTPUT="$PARENT/tokens.json"
  fi
fi

python3 - "$DESIGN_CONTEXT" "$OUTPUT" <<'PY'
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

dc_path, out_path = sys.argv[1], sys.argv[2]
text = Path(dc_path).read_text(errors='ignore')

# Hex and font-size literals throughout the doc.
HEX_RE = re.compile(r'#([0-9A-Fa-f]{8}|[0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})\b')
FONT_SIZE_RE = re.compile(r'\btext-\[(\d+)px\]|\bsize:\s*(\d+)\b')
FONT_FAMILY_RE = re.compile(r"font-\[\'([^\']+)\'\]|family:\s*[\"']([^\"']+)[\"']")

# "Styles used in this design" / "*Styles used*" footer entries.
# MCPFigma renders one of:
#   - **Color/Background/Primary** (`appBgPrimary`): #FFFFFF
#   - `Heading 1` Inter SemiBold 56 / 64 / -1.12
# We accept both shapes.
FOOTER_HEADERS = (
    r'## Styles used in this design',
    r'\*Styles used in this design\*',
    r'### Styles used',
    r'## Styles used',
)
footer_re = re.compile(r'(' + '|'.join(FOOTER_HEADERS) + r')(.*)\Z', re.DOTALL | re.IGNORECASE)
footer_match = footer_re.search(text)
footer_text = footer_match.group(2) if footer_match else ""

# Designer-named color entries from footer:
#   `appBgPrimary`: #FFFFFF      → swiftName=appBgPrimary, hex=#FFFFFF
#   Color/Background/Primary (`appBgPrimary`): #FFFFFF
NAMED_COLOR_RE = re.compile(
    r'`([A-Za-z_][A-Za-z0-9_]*)`[^#\n]*?(#[0-9A-Fa-f]{3,8})',
    re.IGNORECASE
)
# Designer-named typography entries from footer:
#   `headingLargeTitle` Inter SemiBold 28 / 34 / -0.56
#   `Heading 1` Inter SemiBold 56 / 64 / -1.12
NAMED_TYPO_RE = re.compile(
    r'`([A-Za-z_][A-Za-z0-9_ /]*?)`\s+'
    r'([A-Za-z][A-Za-z0-9 ]*?)\s+'             # font family
    r'(Thin|ExtraLight|Light|Regular|Medium|SemiBold|Bold|ExtraBold|Black)\s+'
    r'(\d+(?:\.\d+)?)'                          # size
    r'(?:\s*/\s*(\d+(?:\.\d+)?))?'              # optional line height
    r'(?:\s*/\s*(-?\d+(?:\.\d+)?))?',           # optional tracking
)

colors = OrderedDict()           # swiftName → {lightHex}
typography = OrderedDict()       # swiftName → {fontFamily, fontWeight, fontSize, lineHeightPx, letterSpacing}
font_families = set()
raw_hex_counts = OrderedDict()   # hex → count (full doc, for fallback)

# Pass 1: named entries from footer.
for m in NAMED_COLOR_RE.finditer(footer_text):
    name = m.group(1)
    hex_lit = m.group(2).upper()
    if len(hex_lit) == 4:  # #RGB
        hex_lit = '#' + ''.join(c * 2 for c in hex_lit[1:])
    elif len(hex_lit) == 9:  # #RRGGBBAA — drop alpha for now
        hex_lit = hex_lit[:7]
    colors[name] = {"swiftName": name, "lightHex": hex_lit, "darkHex": None}

for m in NAMED_TYPO_RE.finditer(footer_text):
    raw_name, family, weight, size, lh, tracking = m.groups()
    name = re.sub(r'[^A-Za-z0-9]+', '', raw_name)
    name = name[0].lower() + name[1:] if name else raw_name
    entry = {
        "swiftName": name,
        "fontFamily": family.strip(),
        "fontWeight": weight,
        "fontSize": float(size),
    }
    if lh is not None:
        entry["lineHeightPx"] = float(lh)
    if tracking is not None:
        entry["letterSpacing"] = float(tracking)
    typography[name] = entry
    font_families.add(family.strip())

# Pass 2: hex/size literals from the WHOLE doc — useful when the footer is
# absent (some MCPFigma builds omit it) or when designer didn't tag colors.
for m in HEX_RE.finditer(text):
    hex_lit = m.group(1).upper()
    if len(hex_lit) == 3:
        hex_lit = ''.join(c * 2 for c in hex_lit)
    elif len(hex_lit) == 8:
        hex_lit = hex_lit[:6]
    raw_hex_counts[f"#{hex_lit}"] = raw_hex_counts.get(f"#{hex_lit}", 0) + 1

for m in FONT_FAMILY_RE.finditer(text):
    family = m.group(1) or m.group(2)
    if family and 'sans-serif' not in family and 'serif' != family:
        font_families.add(family)

# If named-pass produced nothing for colors, synthesize from raw hex.
if not colors:
    for i, (hex_val, _) in enumerate(
        sorted(raw_hex_counts.items(), key=lambda kv: -kv[1])
    ):
        colors[f"color{i+1}"] = {
            "swiftName": f"color{i+1}",
            "lightHex": hex_val,
            "darkHex": None,
        }

# If named-pass produced no typography, synthesize per size.
if not typography:
    sizes = set()
    for m in FONT_SIZE_RE.finditer(text):
        s = m.group(1) or m.group(2)
        if s:
            sizes.add(int(s))
    for s in sorted(sizes):
        typography[f"size{s}"] = {
            "swiftName": f"size{s}",
            "fontSize": s,
        }

out = {
    "source": "fallback-style-guide",
    "_note": "Synthesized by b0a-tokens-from-style-guide.sh from a single design-context.md. Use this when figma_extract_tokens is 403 and a style-guide-page exists.",
    "_inputDesignContext": dc_path,
    "fontFamilies": sorted(font_families),
    "colors": list(colors.values()),
    "typography": list(typography.values()),
    "spacing": [],
    "radius": [],
}

Path(out_path).parent.mkdir(parents=True, exist_ok=True)
Path(out_path).write_text(json.dumps(out, indent=2) + "\n")
print(f"Wrote {out_path}")
print(f"  colors:     {len(out['colors'])}")
print(f"  typography: {len(out['typography'])}")
print(f"  font families: {out['fontFamilies']}")
PY

echo "GATE: PASS (b0a-tokens-from-style-guide — fallback active)"
exit 0
