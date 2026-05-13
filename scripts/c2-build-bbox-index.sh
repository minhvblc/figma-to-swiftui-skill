#!/usr/bin/env bash
# c2-build-bbox-index.sh — flatten metadata.json node tree into c2-bbox-index.json.
#
# L2 token trace walks the metadata tree on every frame row to find a matching
# bbox. For large screens (50-100+ nodes) that's wasteful. Pre-compute a flat
# nodeId → bbox index once per Phase A, reuse on every L2 invocation.
#
# Output schema (`.figma-cache/<nodeId>/c2-bbox-index.json`):
#   {
#     "schemaVersion": 1,
#     "byNodeId": {
#       "1234:5700": {"w": 80, "h": 80, "x": 16, "y": 24, "name": "Logo", "type": "INSTANCE"},
#       "1234:5701": {"w": 280, "h": 30, "x": 56, "y": 124, "name": "Title", "type": "TEXT"}
#     },
#     "byBboxKey": {
#       "80x80":   ["1234:5700", "1234:5710"],
#       "280x30":  ["1234:5701"]
#     },
#     "missingBboxNodes": ["1234:5680 (SECTION)", "1234:5690 (BOOLEAN_OPERATION)"],
#     "stats": {"total": 42, "withBbox": 40, "coverage": 0.95}
#   }
#
# Usage:
#   c2-build-bbox-index.sh --cache <.figma-cache/nodeId>
#
# Exit:
#   0 — c2-bbox-index.json written
#   1 — metadata.json missing or invalid
#  64 — bad usage

set -uo pipefail

CACHE=""

print_usage() {
  cat <<'USAGE' >&2
usage: c2-build-bbox-index.sh --cache <.figma-cache/nodeId>

Flattens metadata.json tree into a nodeId → bbox map and a bbox-key →
nodeId[] reverse index. L2 trace looks up by hint nodeId in O(1) rather
than walking the tree per frame row.
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

SRC="$CACHE/metadata.json"
OUT="$CACHE/c2-bbox-index.json"

if [ ! -s "$SRC" ]; then
  echo "FAIL: metadata.json missing or empty at $SRC" >&2
  exit 1
fi

python3 - "$SRC" "$OUT" <<'PY'
import json, os, sys

src, out = sys.argv[1], sys.argv[2]
with open(src) as f:
    try:
        data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"FAIL: metadata.json invalid JSON: {e}", file=sys.stderr)
        sys.exit(1)

by_node_id = {}
by_bbox_key = {}
missing_bbox = []
total = 0
with_bbox = 0

def walk(node):
    global total, with_bbox
    if not isinstance(node, dict):
        return
    total += 1
    bbox = node.get("absoluteBoundingBox") or node.get("bbox") or node.get("box")
    node_id = node.get("id") or node.get("nodeId")
    node_type = node.get("type", "")
    name = node.get("name", "")

    if isinstance(bbox, dict) and isinstance(bbox.get("width"), (int, float)) and isinstance(bbox.get("height"), (int, float)):
        with_bbox += 1
        w = float(bbox["width"])
        h = float(bbox["height"])
        x = float(bbox.get("x", 0))
        y = float(bbox.get("y", 0))
        if node_id:
            # Round to 0.1pt for stable key
            by_node_id[node_id] = {
                "w": round(w, 2),
                "h": round(h, 2),
                "x": round(x, 2),
                "y": round(y, 2),
                "name": name,
                "type": node_type,
            }
            # Bbox key uses integer dims for fuzzy match
            key = f"{int(round(w))}x{int(round(h))}"
            by_bbox_key.setdefault(key, []).append(node_id)
    elif node_type not in {"DOCUMENT", "CANVAS"}:
        # Note nodes without bbox (likely SECTION / BOOLEAN_OPERATION / weird)
        if node_id:
            missing_bbox.append(f"{node_id} ({node_type})")

    for ch in (node.get("children") or []):
        walk(ch)

root = data.get("rootNode") or data.get("document") or data
walk(root)

coverage = (with_bbox / max(total, 1))

index = {
    "schemaVersion": 1,
    "byNodeId": by_node_id,
    "byBboxKey": by_bbox_key,
    "missingBboxNodes": missing_bbox[:20],
    "stats": {
        "total": total,
        "withBbox": with_bbox,
        "coverage": round(coverage, 3),
    },
}

tmp = out + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(index, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out)

print(f"WROTE: {out}")
print(f"  nodes: {total} ({with_bbox} with bbox, {coverage*100:.0f}% coverage)")
print(f"  byBboxKey: {len(by_bbox_key)} unique dim pairs")
if missing_bbox:
    print(f"  missingBbox: {len(missing_bbox)} nodes (e.g. {missing_bbox[0]})")
PY
RC=$?
exit $RC
