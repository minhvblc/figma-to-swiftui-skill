#!/usr/bin/env bash
# c2-fills-stops-index.sh — normalize fills.json gradient stops for L2 lookup.
#
# L2 trace (c3-token-trace.sh) previously only verified gradient PRESENCE (any
# GRADIENT_LINEAR/RADIAL fill in fills.json → PASS). That passes trivially when
# code emits `LinearGradient(colors: [.red, .blue], ...)` against a Figma
# gradient `[#1a1a1a@0, #ffffff@1]` — visually wrong, statically green.
#
# This script flattens every fill stack in fills.json into a per-nodeId
# lookup of { type, stops[] (sorted by position) }, so L2 can match each
# `.background(LinearGradient(...))` row against Figma's exact stops via
# the row's `nodeIdHint` (set via `// Figma: <id>` comment).
#
# Output schema (`.figma-cache/<nodeId>/c2-fills-stops.json`):
#   {
#     "schemaVersion": 1,
#     "byNodeId": {
#       "12:345": [
#         {
#           "type":  "GRADIENT_LINEAR",
#           "opacity": 1.0,
#           "stops": [
#             {"pos": 0.0, "hex": "#1a1a1a", "opacity": 1.0},
#             {"pos": 1.0, "hex": "#ffffff", "opacity": 0.8}
#           ]
#         },
#         {
#           "type":  "IMAGE",
#           "imageUrl": "https://..."
#         }
#       ]
#     }
#   }
#
# A node can have multiple fills stacked (e.g. solid + gradient overlay) — we
# preserve order. L2 picks the topmost GRADIENT_* fill when matching a
# `.background(LinearGradient(...))` Swift row.
#
# Usage:
#   c2-fills-stops-index.sh --cache <.figma-cache/nodeId>
#
# Exit:
#   0 — c2-fills-stops.json written (empty {} when fills.json absent or has no gradients)
#  64 — bad usage

set -uo pipefail

CACHE=""

print_usage() {
  cat <<'USAGE' >&2
usage: c2-fills-stops-index.sh --cache <.figma-cache/nodeId>

Flattens fills.json into per-nodeId gradient-stop lookups. L2 trace consumes
this to verify .background(LinearGradient(...)) stops match Figma exactly,
not just that "any gradient exists".
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

SRC="$CACHE/fills.json"
OUT="$CACHE/c2-fills-stops.json"

python3 - "$SRC" "$OUT" <<'PY'
import json, os, sys

src, out = sys.argv[1], sys.argv[2]

try:
    with open(src) as f:
        fills = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    fills = None

by_node = {}

if fills:
    # fills.json shape from figma_extract_fills: { "nodes": [{ "id":"X", "fills":[...] }, ...] }
    nodes = fills.get("nodes") or []
    for n in nodes:
        nid = n.get("id") or n.get("nodeId")
        if not nid:
            continue
        row_fills = []
        for f_ in (n.get("fills") or []):
            ftype = (f_.get("type") or f_.get("kind") or "").upper()
            opacity = f_.get("opacity")
            if opacity is None:
                opacity = 1.0
            if ftype.startswith("GRADIENT") or "GRADIENT" in ftype:
                # Normalize stops: position + hex + opacity, sorted by position
                raw_stops = f_.get("stops") or f_.get("gradientStops") or []
                stops = []
                for s in raw_stops:
                    pos = s.get("position")
                    if pos is None:
                        pos = s.get("offset")
                    # Color may be {r,g,b,a} dict OR direct hex string
                    color = s.get("color") or {}
                    hex_val = None
                    if isinstance(color, str):
                        hex_val = color.lower()
                    elif isinstance(color, dict):
                        if "hex" in color:
                            hex_val = str(color["hex"]).lower()
                        elif {"r", "g", "b"}.issubset(color.keys()):
                            r = int(round(float(color["r"]) * 255))
                            g = int(round(float(color["g"]) * 255))
                            b = int(round(float(color["b"]) * 255))
                            hex_val = "#{:02x}{:02x}{:02x}".format(r, g, b)
                    stop_opacity = s.get("opacity")
                    if stop_opacity is None and isinstance(color, dict) and "a" in color:
                        stop_opacity = float(color["a"])
                    if stop_opacity is None:
                        stop_opacity = 1.0
                    if pos is not None and hex_val:
                        stops.append({
                            "pos":     float(pos),
                            "hex":     hex_val,
                            "opacity": float(stop_opacity),
                        })
                stops.sort(key=lambda s_: s_["pos"])
                row_fills.append({
                    "type":     ftype,
                    "opacity":  float(opacity),
                    "stops":    stops,
                })
            elif ftype == "IMAGE":
                row_fills.append({
                    "type":     "IMAGE",
                    "opacity":  float(opacity),
                    "imageUrl": f_.get("imageUrl") or f_.get("url") or None,
                })
            elif ftype == "SOLID":
                # Capture solid for completeness; L2 typically matches solid via
                # tokens.json instead, but having it here means gradient-vs-solid
                # mismatch ('code says LinearGradient, Figma says SOLID') is
                # detectable.
                color = f_.get("color") or {}
                hex_val = None
                if isinstance(color, str):
                    hex_val = color.lower()
                elif isinstance(color, dict):
                    if "hex" in color:
                        hex_val = str(color["hex"]).lower()
                    elif {"r", "g", "b"}.issubset(color.keys()):
                        r = int(round(float(color["r"]) * 255))
                        g = int(round(float(color["g"]) * 255))
                        b = int(round(float(color["b"]) * 255))
                        hex_val = "#{:02x}{:02x}{:02x}".format(r, g, b)
                row_fills.append({
                    "type":     "SOLID",
                    "opacity":  float(opacity),
                    "hex":      hex_val,
                })
        if row_fills:
            by_node[nid] = row_fills

output = {
    "schemaVersion": 1,
    "byNodeId": by_node,
}

tmp = out + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(output, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out)

# Summary
gradient_count = sum(
    1
    for fills_ in by_node.values()
    for f_ in fills_
    if str(f_.get("type", "")).startswith("GRADIENT")
)
image_count = sum(
    1
    for fills_ in by_node.values()
    for f_ in fills_
    if f_.get("type") == "IMAGE"
)
solid_count = sum(
    1
    for fills_ in by_node.values()
    for f_ in fills_
    if f_.get("type") == "SOLID"
)
print(f"WROTE: {out}")
print(f"  nodes indexed: {len(by_node)}")
print(f"  fills:         gradient={gradient_count} image={image_count} solid={solid_count}")
PY
RC=$?
exit $RC
