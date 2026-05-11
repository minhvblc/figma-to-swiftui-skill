#!/usr/bin/env bash
# b0a-tokens-from-design-context.sh — fallback token extraction when
# figma_extract_tokens returns 403 (file not Enterprise). Parses all
# .figma-cache/<nodeId>/design-context.md files for inline hex literals
# and font sizes, synthesizes a tokens.json.
#
# Fix-spec F from SKILL_IMPROVEMENT_PLAN.md. Bible Widgets session:
# `figma_extract_tokens` 403, had to manually parse design-context for
# colors + typography → 15 min wasted.
#
# Usage:
#   scripts/b0a-tokens-from-design-context.sh <cache-root> [--output <tokens.json>]
#
# Exit codes:
#   0 — tokens.json synthesized
#   1 — no design-context.md found
#  64 — bad usage

set -uo pipefail

CACHE_ROOT=""
OUTPUT=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,15p' "$0" >&2; exit 0 ;;
    *) CACHE_ROOT="$1"; shift ;;
  esac
done

[ -n "$CACHE_ROOT" ] || { echo "usage: b0a-tokens-from-design-context.sh <cache>" >&2; exit 64; }
[ -d "$CACHE_ROOT" ] || { echo "FAIL: $CACHE_ROOT not a directory" >&2; exit 64; }

[ -z "$OUTPUT" ] && OUTPUT="$CACHE_ROOT/_shared/tokens.json"

# Collect design-context files
DC_FILES=$(find "$CACHE_ROOT" -name "design-context.md" 2>/dev/null)
if [ -z "$DC_FILES" ]; then
  echo "FAIL: no design-context.md found under $CACHE_ROOT" >&2
  exit 1
fi

python3 - "$OUTPUT" $DC_FILES <<'PY'
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

out_path = sys.argv[1]
dc_files = sys.argv[2:]

# Extract hex colors (#RRGGBB or #RGB) and font sizes
HEX_RE = re.compile(r'#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})\b')
FONT_SIZE_RE = re.compile(r'\bsize:\s*(\d+)\b|\btext-\[(\d+)px\]')
FONT_FAMILY_RE = re.compile(r'family:\s*["\']([^"\']+)["\']|font-\[\'([^\']+)\'\]')

colors = defaultdict(int)        # hex → count
font_sizes = defaultdict(int)
font_families = defaultdict(int)

for path in dc_files:
    text = Path(path).read_text(errors='ignore')
    for m in HEX_RE.finditer(text):
        hex_lit = m.group(1).upper()
        # normalize #RGB → #RRGGBB
        if len(hex_lit) == 3:
            hex_lit = ''.join(c*2 for c in hex_lit)
        colors[f"#{hex_lit}"] += 1
    for m in FONT_SIZE_RE.finditer(text):
        size = m.group(1) or m.group(2)
        if size:
            font_sizes[int(size)] += 1
    for m in FONT_FAMILY_RE.finditer(text):
        family = m.group(1) or m.group(2)
        if family and 'sans-serif' not in family:
            font_families[family] += 1

# Synthesize tokens.json — assign generic swiftNames by frequency
sorted_colors = sorted(colors.items(), key=lambda kv: -kv[1])
color_entries = []
for i, (hex_val, count) in enumerate(sorted_colors):
    swift_name = f"color{i+1}"
    color_entries.append({
        "swiftName": swift_name,
        "lightHex": hex_val,
        "darkHex": hex_val,
        "_fallbackSource": "design-context",
        "_occurrenceCount": count
    })

typography_entries = []
for i, (size, count) in enumerate(sorted(font_sizes.items())):
    typography_entries.append({
        "swiftName": f"size{size}",
        "size": size,
        "_occurrenceCount": count
    })

out = {
    "source": "fallback-design-context",
    "_note": "Synthesized by b0a-tokens-from-design-context.sh. swiftNames are generic by frequency. Skill should normalize names per Figma node + naming convention.",
    "fontFamilies": list(font_families.keys()),
    "colors": color_entries,
    "typography": typography_entries,
    "spacing": [],
    "radius": []
}

Path(out_path).parent.mkdir(parents=True, exist_ok=True)
Path(out_path).write_text(json.dumps(out, indent=2))
print(f"Wrote {out_path}")
print(f"  colors: {len(color_entries)}")
print(f"  typography: {len(typography_entries)}")
print(f"  font families: {list(font_families.keys())}")
PY

echo "GATE: PASS (b0a-tokens-from-design-context — fallback active)"
exit 0
