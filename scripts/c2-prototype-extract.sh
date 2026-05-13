#!/usr/bin/env bash
# c2-prototype-extract.sh — extract Figma prototype wiring (button → screen edges)
# from the cached metadata.json into a normalized flow graph.
#
# Captures the two ways designers express navigation intent in Figma:
#
#   1. PROTOTYPE INTERACTIONS — the authoritative source. Drawn in the
#      Prototype tab: a node gets `interactions[]` with `trigger`
#      (ON_CLICK / ON_DRAG / AFTER_TIMEOUT / MOUSE_ENTER / ...) and
#      `actions[]` each with `type=NODE`, `destinationId`, `navigation`
#      (NAVIGATE / OVERLAY / BACK / SCROLL_TO / CHANGE_TO), and an optional
#      `transition` (SMART_ANIMATE / DISSOLVE / INSTANT_TRANSITION / ...).
#
#   2. CONNECTOR NODES — designer-drawn arrows between frames (rare in
#      Figma, common in FigJam). Node `type=CONNECTOR` with
#      `connectorStart.endpointNodeId` + `connectorEnd.endpointNodeId`,
#      and an optional `text.characters` label. Treated as a SECONDARY
#      hint — useful when interactions[] is empty but the designer still
#      sketched the flow.
#
# Manual decorative arrows drawn as plain VECTOR strokes (no endpoint
# attachment) CANNOT be parsed — they have no semantic destination. If
# the prototype graph is empty AND the screenshot shows arrows, those
# arrows are probably decoration only. Surface a warning so the agent
# can ask the designer to wire prototype mode.
#
# For each wire we resolve `fromScreen`/`toScreen` by walking ancestors
# of `fromNodeId`/`toNodeId` up to the nearest screen-sized FRAME
# (width 300-1200pt, height 500-1500pt — the iOS device-class range).
# This gives the agent a button → screen map ready to consume.
#
# Output: `.figma-cache/<nodeId>/prototype-wires.json`
#
# Usage:
#   c2-prototype-extract.sh --cache <.figma-cache/nodeId>
#
# Exit:
#   0 — extraction ran (may have 0 wires; check warnings[])
#  64 — bad usage / cache missing
#  65 — metadata.json present but unparseable

set -uo pipefail

CACHE=""

print_usage() {
  cat <<'USAGE' >&2
usage: c2-prototype-extract.sh --cache <.figma-cache/nodeId>

Reads `metadata.json` (from Phase A Step 4 `get_metadata`) and emits
`prototype-wires.json` with a normalized list of every Figma prototype
interaction + CONNECTOR arrow rooted in the cached subtree. Resolves
each wire's source/destination back to the nearest screen-sized FRAME
ancestor so the agent has a button → screen map.

Always writes the output file (even when empty). 0-wire result is a
valid signal — designer didn't wire prototype mode for this subtree.
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
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 64; }

META="$CACHE/metadata.json"
OUT="$CACHE/prototype-wires.json"

if [ ! -f "$META" ]; then
  # No metadata cached — Phase A Step 4 didn't run, or the agent skipped
  # get_metadata. Emit a placeholder so downstream consumers don't have
  # to special-case missing files.
  python3 - "$OUT" <<'PY'
import json, os, sys, datetime
out_path = sys.argv[1]
payload = {
    "schemaVersion": 1,
    "fileKey":       None,
    "rootNodeId":    None,
    "extractedAt":   datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "wires":         [],
    "screens":       [],
    "warnings":      ["metadata.json missing — run get_metadata in Phase A Step 4 first"],
}
tmp = out_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out_path)
PY
  echo "SKIP: metadata.json missing — wrote empty prototype-wires.json with warning"
  exit 0
fi

python3 - "$META" "$OUT" <<'PY'
import json, os, sys, datetime

meta_path, out_path = sys.argv[1], sys.argv[2]

try:
    with open(meta_path) as f:
        meta = json.load(f)
except json.JSONDecodeError as e:
    print(f"FAIL: metadata.json unparseable: {e}", file=sys.stderr)
    sys.exit(65)

# Figma's REST API returns one of a few shapes depending on the endpoint:
#   /v1/files/:key                   → top-level {"document": {...node tree...}, ...}
#   /v1/files/:key/nodes?ids=...     → top-level {"nodes": {"<id>": {"document": {...}, ...}}}
# figma-desktop's get_metadata may further wrap or unwrap. Walk every
# object that looks like a Figma node (has both `id` and `type`) and
# accumulate findings.
def walk(obj, parent_chain, screens, wires, all_nodes, warnings):
    """Recurse arbitrary JSON. `parent_chain` is the list of ancestor
    (id, name, type, width, height) tuples — used for screen attribution
    and for the screens[] inventory."""
    if isinstance(obj, dict):
        node_id   = obj.get("id")
        node_type = obj.get("type")
        if node_id and isinstance(node_type, str):
            name  = obj.get("name") or ""
            bbox  = obj.get("absoluteBoundingBox") or {}
            w     = bbox.get("width")
            h     = bbox.get("height")
            new_chain = parent_chain + [(node_id, name, node_type, w, h)]
            all_nodes[node_id] = {"name": name, "type": node_type, "w": w, "h": h}

            # Screen detection: FRAME whose bounding box is in the
            # iOS device-class range (320-1200 W × 500-1500 H). We are
            # generous on the upper end to catch tablet & landscape mocks.
            if node_type == "FRAME" and isinstance(w, (int, float)) and isinstance(h, (int, float)):
                if 300 <= w <= 1200 and 500 <= h <= 1500:
                    screens.append({"nodeId": node_id, "name": name, "width": w, "height": h})

            # Source 1: prototype interactions ----------------------------
            for interaction in (obj.get("interactions") or []):
                trigger = (interaction.get("trigger") or {}).get("type")
                for action in (interaction.get("actions") or []):
                    a_type = action.get("type")
                    if a_type not in ("NODE", "BACK", "URL", "CLOSE"):
                        # SET_VARIABLE / CONDITIONAL / OPEN_FILE / etc. — not a
                        # nav edge we can turn into navigation code. Record as
                        # warning so the agent at least knows it exists.
                        warnings.append(
                            f"unsupported action.type={a_type!r} on node {node_id} ({name!r})"
                        )
                        continue
                    dest_id = action.get("destinationId")
                    nav     = action.get("navigation")
                    transition = ((action.get("transition") or {}).get("type"))
                    wire = {
                        "source":        "interaction",
                        "fromNodeId":    node_id,
                        "fromNodeName":  name,
                        "fromNodeType":  node_type,
                        "trigger":       trigger,
                        "actionType":    a_type,
                        "navigation":    nav,
                        "transition":    transition,
                        "toNodeId":      dest_id,
                        "url":           action.get("url"),
                    }
                    # Screen attribution: nearest FRAME ancestor in chain with
                    # screen-sized bbox. We resolve `toScreenId/Name` in a
                    # second pass once all_nodes is fully built.
                    fs = nearest_screen(new_chain)
                    if fs is not None:
                        wire["fromScreenId"]   = fs[0]
                        wire["fromScreenName"] = fs[1]
                    wires.append(wire)

            # Source 2: CONNECTOR nodes -----------------------------------
            if node_type == "CONNECTOR":
                start = obj.get("connectorStart") or {}
                end   = obj.get("connectorEnd")   or {}
                label_text = ((obj.get("text") or {}).get("characters")) or obj.get("name")
                from_id = start.get("endpointNodeId")
                to_id   = end.get("endpointNodeId")
                if from_id or to_id:
                    wires.append({
                        "source":        "connector",
                        "fromNodeId":    from_id,
                        "toNodeId":      to_id,
                        "annotation":    label_text,
                        "trigger":       None,
                        "actionType":    None,
                        "navigation":    None,
                        "transition":    None,
                    })
                else:
                    warnings.append(
                        f"CONNECTOR {node_id} ({name!r}) has no endpoint attachments — "
                        f"likely a free-floating arrow, cannot resolve targets"
                    )

            # Recurse into children
            for child in (obj.get("children") or []):
                walk(child, new_chain, screens, wires, all_nodes, warnings)
        else:
            # Not a node — recurse into every value (handles the
            # /v1/files/:key/nodes wrapper shape).
            for v in obj.values():
                walk(v, parent_chain, screens, wires, all_nodes, warnings)
    elif isinstance(obj, list):
        for item in obj:
            walk(item, parent_chain, screens, wires, all_nodes, warnings)


def nearest_screen(chain):
    """Walk chain from leaf to root; return the first (id, name) that
    looks like a screen-sized FRAME, else None."""
    for nid, name, ntype, w, h in reversed(chain):
        if ntype == "FRAME" and isinstance(w, (int, float)) and isinstance(h, (int, float)):
            if 300 <= w <= 1200 and 500 <= h <= 1500:
                return (nid, name)
    return None


screens   = []
wires     = []
all_nodes = {}
warnings  = []

walk(meta, [], screens, wires, all_nodes, warnings)

# De-duplicate screens (a frame may appear multiple times if metadata
# was returned via a wrapper shape).
seen = set()
unique_screens = []
for s in screens:
    key = s["nodeId"]
    if key in seen: continue
    seen.add(key)
    unique_screens.append(s)
screens = unique_screens

# Second pass: resolve toNodeName / toScreenId / toScreenName for every
# wire by looking up the destination in all_nodes. Destinations outside
# the cached subtree (e.g. a frame on a different page) will not be in
# all_nodes — flag those.
screen_ids = {s["nodeId"] for s in screens}
for w in wires:
    # Resolve source name when missing (CONNECTOR wires only record
    # fromNodeId from endpointNodeId — fill in the name from all_nodes
    # so the agent can read the wire without cross-referencing).
    if w.get("fromNodeName") is None and w.get("fromNodeId"):
        src_info = all_nodes.get(w["fromNodeId"])
        if src_info:
            w["fromNodeName"] = src_info["name"]
            w["fromNodeType"] = src_info["type"]
            # When the source IS a screen-sized FRAME, attribute it as
            # the screen too (common for CONNECTOR arrows that wire
            # frame-to-frame rather than button-to-frame).
            if w["fromNodeId"] in screen_ids:
                w["fromScreenId"]   = w["fromNodeId"]
                w["fromScreenName"] = src_info["name"]

    dest = w.get("toNodeId")
    if not dest:
        continue
    info = all_nodes.get(dest)
    if not info:
        w["toNodeName"]   = None
        w["toResolved"]   = False
        warnings.append(
            f"wire from {w.get('fromNodeId')} ({w.get('fromNodeName')!r}) "
            f"references destinationId={dest} which is OUTSIDE the cached "
            f"subtree — re-run get_metadata at a higher root to resolve"
        )
        continue
    w["toNodeName"] = info["name"]
    w["toNodeType"] = info["type"]
    w["toResolved"] = True
    # Destination IS itself a screen-sized FRAME → it IS the target screen
    if dest in screen_ids:
        w["toScreenId"]   = dest
        w["toScreenName"] = info["name"]
    # Destination is a sub-element inside a screen → would need a second
    # walk to find ancestor; we don't store the chain per node yet. Mark
    # unresolved so the agent knows to look it up manually if needed.
    else:
        w["toScreenId"]   = None
        w["toScreenName"] = None

# Detect "no prototype data at all" — distinguishes a healthy run (0 wires
# because designer didn't wire prototype) from a degraded one (metadata
# was reduced and stripped the interaction fields before reaching us).
if not wires:
    # If we found any node at all and NONE had interactions/CONNECTOR,
    # that's the "designer didn't wire" case — leave as informational.
    # If all_nodes is empty too, metadata.json was unusable.
    if all_nodes:
        warnings.append(
            "no prototype interactions or CONNECTOR nodes found in the cached subtree. "
            "Either the designer hasn't wired the prototype in Figma yet, OR the arrows "
            "in the canvas are plain VECTOR strokes (decorative — not parseable). "
            "Ask the designer to use Figma Prototype mode (or FigJam Connector) to make "
            "the navigation graph machine-readable."
        )
    else:
        warnings.append(
            "metadata.json contained no Figma nodes — verify it was produced by "
            "`get_metadata` and not a different MCP."
        )

# Try to surface fileKey / rootNodeId. Figma's REST shapes vary; check a
# few common spots. Worst case both stay None.
file_key = meta.get("fileKey") or meta.get("file_key")
root_id  = None
if "document" in meta and isinstance(meta["document"], dict):
    root_id = meta["document"].get("id")
elif "nodes" in meta and isinstance(meta["nodes"], dict):
    keys = list(meta["nodes"].keys())
    if keys:
        root_id = keys[0]
if not root_id:
    # Fall back to the cache directory name (typically `<rootNodeId>` with
    # `:` URL-escaped). Best-effort only.
    cache_dir = os.path.basename(os.path.dirname(out_path))
    if cache_dir:
        root_id = cache_dir

payload = {
    "schemaVersion": 1,
    "fileKey":       file_key,
    "rootNodeId":    root_id,
    "extractedAt":   datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "wires":         wires,
    "screens":       screens,
    "warnings":      warnings,
}

tmp = out_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(payload, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out_path)

interaction_count = sum(1 for w in wires if w["source"] == "interaction")
connector_count   = sum(1 for w in wires if w["source"] == "connector")
unresolved        = sum(1 for w in wires if not w.get("toResolved", False))
print(f"OK: extracted {len(wires)} wire(s) — interactions={interaction_count}, "
      f"connectors={connector_count}, unresolvedDest={unresolved}; "
      f"screens={len(screens)}; warnings={len(warnings)}")
for w in warnings[:5]:
    print(f"  ⚠ {w}")
if len(warnings) > 5:
    print(f"  ⚠ … (+{len(warnings) - 5} more in prototype-wires.json)")
PY
RC=$?
exit $RC
