#!/usr/bin/env bash
# c2-extract-design-context.sh — normalize design-context.md → c2-extracted.json.
#
# Parses the JSX/Tailwind output of `get_design_context` once into a structured
# JSON that L2 trace can grep cheaply. Avoids re-parsing markdown on every
# trace row.
#
# Output schema (`.figma-cache/<nodeId>/c2-extracted.json`):
#   {
#     "schemaVersion": 1,
#     "sourceFile": "design-context.md",
#     "hexLiterals": ["#1a1a1a", "#0066ff"],          # lowercased, deduped
#     "tailwindClasses": {
#       "spacing": ["p-6", "px-4", "gap-4"],          # p|px|py|pt|pr|pb|pl|m|mx|...|gap[-xy]
#       "color":   ["text-gray-400", "bg-[#1a1a1a]"],
#       "size":    ["w-20", "h-80", "text-2xl"]
#     },
#     "textSegments": ["Welcome back", "Sign in"],    # raw text content
#     "textSegmentsNormalized": ["welcome back", ...], # casefold + smart-quote normalized
#     "cssVars": {"--text-primary": "#1a1a1a"},
#     "nodeIdRefs": ["1234:5678"]
#   }
#
# Usage:
#   c2-extract-design-context.sh --cache <.figma-cache/nodeId>
#
# Exit:
#   0 — c2-extracted.json written
#   1 — design-context.md missing or empty
#  64 — bad usage

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

CACHE=""

print_usage() {
  cat <<'USAGE' >&2
usage: c2-extract-design-context.sh --cache <.figma-cache/nodeId>

Parses design-context.md into c2-extracted.json with normalized hex
literals, Tailwind classes, text segments, CSS vars, and nodeId refs.
Cheap grep substrate for L2 token trace.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)   CACHE="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 64; }

SRC="$CACHE/design-context.md"
OUT="$CACHE/c2-extracted.json"

if [ ! -s "$SRC" ]; then
  echo "FAIL: design-context.md missing or empty at $SRC" >&2
  exit 1
fi

python3 - "$SRC" "$OUT" <<'PY'
import json, os, re, sys
from html import unescape

src, out = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()

# ── 1. Hex literals ──────────────────────────────────────────────────────────
HEX_RE = re.compile(r'#[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?\b')
hex_literals = sorted({m.group(0).lower() for m in HEX_RE.finditer(text)})

# ── 2. Tailwind classes (grouped) ────────────────────────────────────────────
# Spacing: p[xytrbl]?-N, m[xytrbl]?-N, gap[-xy]?-N, space-[xy]-N
SPACING_RE = re.compile(r'\b(?:p[xytrbl]?|m[xytrbl]?|gap(?:-[xy])?|space-[xy])-(\d+(?:\.\d+)?)\b')
spacing_classes = sorted({m.group(0) for m in SPACING_RE.finditer(text)})

# Color: text-<name>, bg-<name>, border-<name>, fill-<name>, stroke-<name>, ring-<name>,
#        plus arbitrary-value forms text-[#...], bg-[#...], etc.
COLOR_RE = re.compile(
    r'\b(?:text|bg|border|fill|stroke|ring|placeholder|caret|divide|accent)-'
    r'(?:\[#[0-9a-fA-F]{3,8}\]|\[var\(--[a-zA-Z0-9_-]+\)\]|[a-zA-Z]+-?\d+|[a-zA-Z]+)\b'
)
color_classes = sorted({m.group(0) for m in COLOR_RE.finditer(text)})

# Size: w-N, h-N, min-w-N, max-w-N, min-h-N, max-h-N, text-<size>, leading-<n>
SIZE_RE = re.compile(
    r'\b(?:w|h|min-w|max-w|min-h|max-h)-(?:full|screen|auto|\[[^\]]+\]|\d+(?:\.\d+)?)\b'
    r'|\btext-(?:xs|sm|base|lg|xl|[2-9]xl|\[\d+px\])\b'
    r'|\bleading-(?:none|tight|snug|normal|relaxed|loose|\d+|\[[^\]]+\])\b'
)
size_classes = sorted({m.group(0) for m in SIZE_RE.finditer(text)})

# ── 3. Text segments (between JSX tags) ─────────────────────────────────────
# Match text content of <Tag>...content...</Tag> and `<Tag>{`text`}</Tag>`.
# Strip nested JSX expressions {var} but keep raw text.
TEXT_RE = re.compile(
    r'>([^<{}]+?)<',
    re.DOTALL,
)
text_segments_raw = []
seen = set()
for m in TEXT_RE.finditer(text):
    seg = m.group(1).strip()
    # Skip whitespace-only and code-like segments
    if not seg or len(seg) < 2:
        continue
    # Skip pure-symbol segments (commas, colons, etc.)
    if re.fullmatch(r'[\s,.:;\-—–_(){}[\]<>=+/]+', seg):
        continue
    seg = unescape(seg)
    if seg in seen:
        continue
    seen.add(seg)
    text_segments_raw.append(seg)

# Normalize for case-insensitive + smart-quote match
def normalize_text(s):
    s = s.replace("‘", "'").replace("’", "'")
    s = s.replace("“", '"').replace("”", '"')
    s = s.replace("–", "-").replace("—", "-")
    s = re.sub(r'\s+', ' ', s).strip()
    return s.casefold()

text_segments_normalized = sorted({normalize_text(t) for t in text_segments_raw if normalize_text(t)})

# ── 4. CSS vars (--name: value;) ────────────────────────────────────────────
CSS_VAR_RE = re.compile(r'(--[a-zA-Z0-9_-]+)\s*:\s*([^;}\n]+)[;}\n]?')
css_vars = {}
for m in CSS_VAR_RE.finditer(text):
    name = m.group(1).strip()
    val = m.group(2).strip().rstrip(';').strip()
    css_vars[name] = val

# ── 5. Figma nodeId refs (data-node-id="...") ──────────────────────────────
NODEID_RE = re.compile(r'data-node-id\s*=\s*["\']([0-9]+:[0-9]+)["\']')
node_id_refs = sorted({m.group(1) for m in NODEID_RE.finditer(text)})
# Also pick up plain "1234:5678" comment-style refs
PLAIN_NODE_RE = re.compile(r'\b(\d+:\d+)\b')
for m in PLAIN_NODE_RE.finditer(text):
    if m.group(1) not in node_id_refs:
        node_id_refs.append(m.group(1))
node_id_refs = sorted(set(node_id_refs))

extracted = {
    "schemaVersion": 1,
    "sourceFile": "design-context.md",
    "hexLiterals": hex_literals,
    "tailwindClasses": {
        "spacing": spacing_classes,
        "color":   color_classes,
        "size":    size_classes,
    },
    "textSegments": text_segments_raw,
    "textSegmentsNormalized": text_segments_normalized,
    "cssVars": css_vars,
    "nodeIdRefs": node_id_refs,
}

tmp = out + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(extracted, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out)

print(f"WROTE: {out}")
print(f"  hexLiterals:   {len(hex_literals)}")
print(f"  tailwind:      spacing={len(spacing_classes)} color={len(color_classes)} size={len(size_classes)}")
print(f"  textSegments:  {len(text_segments_raw)}")
print(f"  cssVars:       {len(css_vars)}")
print(f"  nodeIdRefs:    {len(node_id_refs)}")
PY
RC=$?
exit $RC
