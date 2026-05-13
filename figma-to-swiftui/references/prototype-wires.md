# Prototype Wires — Figma → cached navigation graph

How the skill captures the **wiring designers draw in Figma** ("tap this button → go to that screen") into a deterministic, machine-readable graph the downstream skills can consume.

## What gets captured

Two sources, in priority order:

1. **Prototype interactions** (authoritative). Drawn in Figma's **Prototype** tab. Each node carries `interactions[]`; each interaction has a `trigger` (`ON_CLICK` / `ON_DRAG` / `AFTER_TIMEOUT` / `MOUSE_ENTER` / ...) and `actions[]` (`NAVIGATE` / `OVERLAY` / `BACK` / `SCROLL_TO` / `CHANGE_TO` / `URL` / `CLOSE`). This is the canonical source — every wire here is a real navigation contract.

2. **Connector nodes** (secondary hint). Designer-drawn arrows in FigJam, or the rare Figma CONNECTOR. Has `connectorStart.endpointNodeId` + `connectorEnd.endpointNodeId` and an optional text label. Useful when prototype mode is empty but the designer sketched the flow on canvas.

What is **NOT** captured:

- Plain VECTOR strokes drawn between frames. These look like arrows visually but have no endpoint attachment — they are decoration, not data. The script emits a warning when the prototype graph is empty and asks the designer to wire prototype mode.

## Cache file

`.figma-cache/<nodeId>/prototype-wires.json`

```json
{
  "schemaVersion": 1,
  "fileKey": "abc123",
  "rootNodeId": "1:1",
  "extractedAt": "2026-05-13T10:00:00Z",
  "wires": [
    {
      "source":        "interaction",
      "fromNodeId":    "5:24",
      "fromNodeName":  "ContinueButton",
      "fromNodeType":  "INSTANCE",
      "fromScreenId":  "1:2",
      "fromScreenName":"OnboardingScreen",
      "trigger":       "ON_CLICK",
      "actionType":    "NODE",
      "navigation":    "NAVIGATE",
      "transition":    "SMART_ANIMATE",
      "toNodeId":      "3:1",
      "toNodeName":    "HomeScreen",
      "toNodeType":    "FRAME",
      "toScreenId":    "3:1",
      "toScreenName":  "HomeScreen",
      "toResolved":    true,
      "url":           null
    },
    {
      "source":        "connector",
      "fromNodeId":    "1:2",
      "toNodeId":      "3:1",
      "annotation":    "after login",
      "trigger":       null,
      "actionType":    null,
      "navigation":    null,
      "transition":    null,
      "toNodeName":    "HomeScreen",
      "toScreenId":    "3:1",
      "toScreenName":  "HomeScreen",
      "toResolved":    true
    }
  ],
  "screens": [
    { "nodeId": "1:2", "name": "OnboardingScreen", "width": 375, "height": 812 },
    { "nodeId": "3:1", "name": "HomeScreen",       "width": 375, "height": 812 }
  ],
  "warnings": []
}
```

### Field reference

| Field | Meaning |
|---|---|
| `source` | `interaction` (Prototype tab) or `connector` (CONNECTOR node arrow) |
| `fromNodeId` / `fromNodeName` | Source node — typically a button / tap target |
| `fromNodeType` | Figma node type (`INSTANCE` / `FRAME` / `RECTANGLE` / ...) — useful for filtering to interactive elements |
| `fromScreenId` / `fromScreenName` | Nearest ancestor FRAME with screen-sized dims (320-1200 W × 500-1500 H) — the screen the source belongs to |
| `trigger` | `ON_CLICK` / `ON_DRAG` / `MOUSE_ENTER` / `MOUSE_LEAVE` / `MOUSE_UP` / `MOUSE_DOWN` / `AFTER_TIMEOUT` / `ON_HOVER` / `ON_PRESS` |
| `actionType` | `NODE` (most navigation), `BACK` (system back), `URL` (open external link), `CLOSE` (dismiss overlay) |
| `navigation` | `NAVIGATE` (push), `OVERLAY` (modal), `BACK`, `SCROLL_TO`, `CHANGE_TO` (swap content) |
| `transition` | `SMART_ANIMATE` / `DISSOLVE` / `INSTANT_TRANSITION` / `SLIDE_IN` / `SLIDE_OUT` / `MOVE_IN` / `MOVE_OUT` / `PUSH` |
| `toNodeId` / `toNodeName` | Destination node id + name (when resolved) |
| `toScreenId` / `toScreenName` | Destination screen (when the destination is itself a screen-sized FRAME) |
| `toResolved` | `false` when `toNodeId` was OUTSIDE the cached subtree (re-run `get_metadata` at a higher root to resolve) |
| `url` | External URL when `actionType=URL`; else null |
| `annotation` | CONNECTOR's text label (designer's note about the edge) |

## How the script extracts

`scripts/c2-prototype-extract.sh --cache <.figma-cache/nodeId>` walks `metadata.json` (from Phase A Step 4 `get_metadata`). The walk is shape-tolerant — it recurses into any object that looks like a Figma node (has both `id` and `type`), so it handles both `/v1/files/:key` and `/v1/files/:key/nodes` response shapes from the Figma REST API.

For each wire:
1. Record source node id/name/type.
2. Walk ancestors to find the **nearest screen-sized FRAME** (320 ≤ W ≤ 1200, 500 ≤ H ≤ 1500). This becomes `fromScreenId`/`fromScreenName`.
3. Resolve `destinationId` (or `endpointNodeId` for CONNECTOR) against the full node table built during the walk. When the destination IS a screen-sized FRAME, it's the target screen.
4. When destination is outside the cached subtree → emit a warning recommending a higher-root `get_metadata`.

The script ALWAYS writes the output file — even when 0 wires were found. Empty wires + a warning is a valid signal: the designer hasn't wired the prototype yet, OR the navigation is expressed only as decorative VECTOR arrows.

## Failure modes

| Symptom | Meaning | Action |
|---|---|---|
| `SKIP: metadata.json missing` | Phase A Step 4 didn't run | Run `get_metadata(fileKey, nodeId)` then re-run extract. |
| 0 wires, no warnings beyond the "no prototype data" generic | Designer didn't wire Prototype mode | Ask the designer to add prototype connections in Figma, OR derive the flow from product doc + manual confirmation. |
| `wire references destinationId=X which is OUTSIDE the cached subtree` | Source is in cache, destination is on a different page / outside the requested root | Re-run `get_metadata` at the file-level root (or a higher common ancestor) so the destination is included. |
| `unsupported action.type='SET_VARIABLE'` (or similar) | Designer used a non-navigation action | Read the warning, ignore for navigation purposes — it doesn't map to a route. |
| `CONNECTOR ... has no endpoint attachments` | Free-floating arrow on canvas | Decorative only — ignore. |

## How the agent uses prototype-wires.json

**Single-screen (figma-to-swiftui).** Optional. Use it to inform per-button `Action` enum cases when the source button is in the screen being implemented. Example: ContinueButton with `navigation=NAVIGATE` → ViewModel `Action.continueTapped` → `send(.continueTapped)` triggers a route in the parent flow.

**Multi-screen (figma-flow-to-swiftui-feature).** Strong signal. The screen graph in Step 3 SHOULD reconcile against `prototype-wires.json`:
- Every `wire` with `source=interaction` is a navigation contract the agent must implement.
- Disagreement between the user-provided brief and `prototype-wires.json` → STOP and ASK the user which is authoritative (design intent vs. business plan).
- When `prototype-wires.json` is empty but the brief lists transitions → proceed with the brief as the source of truth, but flag this in the run summary.

## Manual extraction

Quick check without re-running the skill:

```bash
bash ~/.claude/scripts/c2-prototype-extract.sh --cache .figma-cache/<nodeId>
python3 -c 'import json; d=json.load(open(".figma-cache/<nodeId>/prototype-wires.json"));
print(f"{len(d[\"wires\"])} wires, {len(d[\"screens\"])} screens, {len(d[\"warnings\"])} warnings")
for w in d["wires"]:
    print(f"  {w.get(\"fromScreenName\")} :: {w.get(\"fromNodeName\")} --[{w.get(\"trigger\")}/{w.get(\"navigation\")}]--> {w.get(\"toScreenName\") or w.get(\"toNodeName\")}")'
```

## Scope (current)

Today the script captures the data and caches it. Downstream consumption is **opt-in** — neither SKILL.md hard-requires reading `prototype-wires.json` to ship code yet. That wiring (auto-deriving the screen graph from interactions, generating route enums from wires) is a follow-up scope and tracked separately.
