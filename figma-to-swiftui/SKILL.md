---
name: figma-to-swiftui
description: "Build pixel-perfect SwiftUI views from Figma via Figma MCP. Triggers on figma.com URLs, Figma node IDs, a current Figma selection in figma-desktop MCP, and phrases like 'implement/translate/convert Figma to SwiftUI', 'iOS UI from Figma', 'làm UI SwiftUI từ Figma', 'code màn iOS theo Figma', 'làm màn này', 'adapt SwiftUI view to Figma', or a .txt/.md brief paired with Figma work for iOS. Requires Figma MCP. Do NOT trigger for React, web, or Android."
---

# Figma to SwiftUI

Turn Figma nodes into production SwiftUI with pixel-matching fidelity. **Three phases, executed in strict order. Each phase has a mandatory exit gate. You may not start the next phase until the previous gate prints `GATE: PASS`.**

- **Phase A — Discover & Spec.** Fetch the design specification (context, screenshot, tokens, metadata). Cache only.
- **Phase B — Asset Pipeline.** Inventory every visible asset, classify, download as PNG, validate. Cache only.
- **Phase C — Implement.** Write SwiftUI offline from the cache, self-check, copy assets to the project.

**Fidelity playbook (read first, every Phase C):** `references/visual-fidelity.md`.

---

## ABSOLUTE RULE — Assets come from Figma

Every visible icon, logo, illustration, image, and decorative graphic in the screenshot **MUST** be downloaded from Figma in Phase B. No exceptions, no shortcuts.

**Banned substitutions** (treat as bugs, not "approximations"):
- `Image(systemName: ...)` (SF Symbols) for any element that exists as a Figma node
- Colored rectangles / circles / `Text("G")` standing in for real logos
- `Shape` primitives drawn to mimic an icon ("a circle with a checkmark")
- "Simplified" versions of Figma illustrations
- Any phrase like "no Figma PNG/SVG pipeline was set up" — Phase B is mandatory, not optional

**Only allow-listed exceptions** for `Image(systemName:)`:
- iOS system chrome the user explicitly said to keep system-default (back chevron in NavigationStack toolbar, share sheet icons)
- The user explicitly tells you to substitute for a missing asset

**Failure-mode self-check.** If you catch yourself thinking *"SF Symbol is close enough"*, *"the user won't notice"*, *"I'll skip the pipeline this time"*, *"there's no FIGMA_TOKEN so I can't download"*, or *"I'll mark this as approximation in the summary"* — **STOP**. That is the exact failure mode this skill exists to prevent. Go run Phase B. `get_screenshot(fileKey, nodeId)` works without any token and is the default asset downloader.

If an asset truly cannot be fetched (node missing from Figma, MCP returns error after retry), **STOP and tell the user** — do not improvise. Improvisation = task failure.

---

## ABSOLUTE RULE — Do NOT draw iOS system chrome

Figma frames often include a mockup of iOS system chrome (status bar, Dynamic Island, home indicator). **These are rendered by iOS itself.** Drawing them in SwiftUI is always a bug — it duplicates what iOS already shows and breaks on real devices.

**Never draw these, even if they appear in the Figma screenshot:**
- Status bar (time "9:41", Dynamic Island, signal/wifi/battery icons)
- Home indicator (the ~134×5pt horizontal bar at the bottom)
- System keyboard, pull-to-refresh spinner, system nav back chevron
- Native tab bar (`TabView` provides its own), system alerts, page dots

**Recognize them in the screenshot before inventorying.** Strip them out of the Visual Inventory — they are mockup decoration, not content. The SwiftUI view starts below the status bar and ends above the home indicator; iOS handles the rest.

**What to do instead:**
- Status bar area → `.ignoresSafeArea(edges: .top)` on the background only if the design shows content extending behind it; otherwise let the safe area work normally.
- Bottom of screen → leave the home indicator area to iOS. Use `.safeAreaInset(edge: .bottom)` / `.safeAreaPadding` if your content needs padding above it. Do NOT draw a `Capsule()` or `RoundedRectangle()` at (width≈134, height≈5) to mimic it.
- Custom tab bar that IS part of the app (not iOS `TabView`) → fine to implement, but place it with `.safeAreaInset(edge: .bottom)` so iOS keeps the home indicator below it.

**Failure-mode self-check.** If the Visual Inventory has a row like "home indicator bar", "status bar with time 9:41", "Dynamic Island pill" — **delete it** before coding.

## Prerequisites

- Figma MCP connected — **probe first**, don't ask upfront. Call `get_metadata` on the target node (or current selection) as the first MCP action. If the call fails because no MCP is configured, only then pause and ask the user to set it up.
- Figma URL `figma.com/design/:fileKey/:fileName?node-id=...`, or current selection in figma-desktop MCP (no URL needed)
- SwiftUI Xcode project (preferred)
- Optional: `.txt`/`.md` brief — read **before** any Figma call

## Route

| Input | Use |
|---|---|
| 1 node, no doc (or doc = 1 screen) | this skill |
| Multiple nodes / root page / journey | `figma-flow-to-swiftui-feature` (delegates back per screen) |
| Ambiguous | Step 0 + 1b first, then decide |

See `references/source-document.md`.

---

# Phase A — Discover & Spec

Goal: a complete design specification in the cache. **No asset downloads in this phase.**

### Step A0 — Source Document
If a doc is attached, read it first. Extract: goal, screens, actions, states, constraints, out-of-scope. See `references/source-document.md`.

### Step A1 — Parse URL
- `fileKey`: first path segment after `/design/` or `/file/`
- `nodeId`: `node-id` query param; replace `-` with `:` (URLs use `3166-70147`, MCP expects `3166:70147`)
- Reject `/proto/` and `/board/` — ask for a `/design/` link
- figma-desktop: uses selected node automatically

### Step A2 — Screen Discovery (metadata-first)
Run `get_metadata` before Step A3 when the node is not obviously a leaf (root `0:1`, page, "Flow"/"Onboarding"/"All Screens"/"Page" containers, or doc names more screens than URL suggests). Build a candidate screen map with confidence. Hand off to flow skill if result is N screens. See `references/screen-discovery.md`.

### Step A3 — Batch Fetch Spec

Run in parallel where possible; save to `.figma-cache/<nodeId>/`:

1. `get_design_context(fileKey, nodeId, prompt="generate for iOS using SwiftUI")` → `design-context.md`
2. `get_screenshot(fileKey, nodeId)` at **scale 3** (fine details visible) → `screenshot.png` (this is the FRAME screenshot, not asset)
3. `get_variable_defs(fileKey, nodeId)` → `tokens.json` (once per `fileKey` — dedup by copying/symlinking)
4. `get_metadata(fileKey, nodeId)` → `metadata.json` (**always run** — icon nodeIds are here)
5. Optional: Code Connect mapping — only if your Figma MCP exposes such a tool. Skip silently if unavailable.

On truncation: don't retry — fall back to metadata + per-section fetch. See `references/fetch-strategy.md`.

### Gate A — Phase A Exit (BASH, mandatory)

You MUST run this. If it does not print `GATE: PASS`, do NOT start Phase B.

```bash
CACHE=".figma-cache/<nodeId>"
FAIL=0
[ -s "$CACHE/design-context.md" ] && ! grep -q "truncated\|TRUNCATED" "$CACHE/design-context.md" && echo "PASS: design-context" || { echo "FAIL: design-context"; FAIL=1; }
file "$CACHE/screenshot.png" 2>/dev/null | grep -q "PNG image data" && echo "PASS: screenshot" || { echo "FAIL: screenshot"; FAIL=1; }
[ -s "$CACHE/metadata.json" ] && grep -q '"id"' "$CACHE/metadata.json" && echo "PASS: metadata" || { echo "FAIL: metadata"; FAIL=1; }
[ -f "$CACHE/tokens.json" ] && echo "PASS: tokens" || { echo "FAIL: tokens"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase A)" || echo "GATE: FAIL (Phase A)"
```

---

# Phase B — Asset Pipeline

**This is the phase agents skip. Don't.** Goal: every visible icon/logo/illustration/image from the screenshot exists as a validated PNG on disk (and, for tagged assets, also as an `.imageset` inside `Assets.xcassets`).

Phase B has **two asset paths that run side by side**:

1. **MCPFigma path — DEFAULT for designer-tagged assets** (`eIC*`/`eImage*`). `figma_list_assets` discovers them; `figma_export_assets` batch-renders, renames to iOS convention (`icAI<Name>` / `imageAI<Name>`), and writes `.imageset` directly into `Assets.xcassets`. See `references/mcpfigma-setup.md`.
2. **`get_screenshot` path — fallback** for FLATTEN regions, untagged nodes, MCPFigma export errors, and degraded environments (server not configured, token missing).

You always run the probe (B0) and the visual inventory (B1) before any download. The two paths are decided per-row in B2.

### Step B0 — Tagged Asset Probe (MCPFigma)

Goal: get a registry of designer-tagged assets (`eIC*` / `eImage*`) for the current node, **before** you build the visual inventory. Tagged assets short-circuit the inventory's "find a nodeId" step — MCPFigma already has them.

1. **Probe availability:**
   - Call `figma_list_assets(fileKey=<fileKey>, nodeId=<nodeId>, depth=10)`.
   - Tool not registered (server not configured) → set `mcpfigmaAvailable = false`. Print one line: `WARN: figma-assets MCP not configured — Phase B will use get_screenshot for every asset (see references/mcpfigma-setup.md).` Continue with all-fallback path.
   - Auth error → `mcpfigmaAvailable = false`. Same warning, plus: `WARN: FIGMA_ACCESS_TOKEN missing or invalid in figma-assets env`.
   - 200 with empty `matches` AND `warnings` → `mcpfigmaAvailable = true`, but registry is empty (designer hasn't tagged anything in scope). Every inventory row will end up on the `get_screenshot` path. Valid state.
   - 200 with matches and/or warnings → `mcpfigmaAvailable = true`. Stash the response.

2. **Persist the response** to `.figma-cache/<nodeId>/mcpfigma-list.json`. The manifest references this file.

3. **Build the tagged-asset registry** (in memory):
   - Each `match` → row `{ sourceNodeId, figmaName, kind ("icon"|"image"), exportName }`.
   - Each `warning` → log to `.figma-cache/<nodeId>/mcpfigma-warnings.log` and surface to user once at the end of Phase B (do not silently drop). Tell user: *"Designer tagged N nodes but they failed validation: <list>. They will be exported via get_screenshot fallback. To use the MCPFigma fast path, fix the names in Figma."*

4. **Pin `assetCatalogPath`** for this run:
   - 0 `.xcassets` in project → ask user to create one before continuing (no fallback for the import step).
   - 1 `.xcassets` → silent default, tell user which one.
   - N > 1 → interactive prompt; stash answer in `manifest.mcpfigma.assetCatalogPath`.

   On Phase B re-run, prefer the previously stashed value.

5. **Scan `metadata.json` for Lottie placeholders (`eAnim*`)**. MCPFigma's scanner skips these (does not recurse into children) and they do NOT appear in `figma_list_assets.matches` — but they're present in `metadata.json`. Walk the tree, collect every node whose name matches `eAnim[A-Z][A-Za-z0-9_]*`, and stop recursion at each match (children are designer preview keyframes).

   Persist to `.figma-cache/<nodeId>/lottie-placeholders.json`. Each entry: `{ sourceNodeId, figmaName, kind: "lottie-placeholder", frame: { width, height } }`.

   Invalid name (e.g. `eAnimloading` lowercase first char) → log warning, skip the row, surface at end of Phase B. See `references/lottie-placeholders.md` §2 for detection pseudocode.

### Step B1 — Inventory (visual-first)

Open `screenshot.png` and **list every visible non-text element**. Cross-reference three sources:
1. Visual scan of `screenshot.png` (ground truth — start here)
2. `design-context.md`: `<img>` URLs, inline `<svg>`, `imageRef`, `background-image`
3. `metadata.json`: nodes of type `VECTOR`, `BOOLEAN_OPERATION`, `INSTANCE`; names with `icon`, `ic_`, `logo`, `illustration`

Build the inventory table (with B0's tagged-asset registry **and** Lottie placeholder list in mind):

| # | Purpose | NodeId | Tagged | Strategy | Exporter | exportName / friendlyName / lottieName |
|---|---|---|---|---|---|---|
| 1 | Close icon | 3166:70211 | yes (eICClose) | atomic | mcpfigma | icAIClose |
| 2 | Hero illustration | 3166:70200 | no | flatten | get_screenshot | heroArtwork |
| 3 | Facebook logo | 3166:70250 | yes (eICFacebook) | atomic | mcpfigma | icAIFacebook |
| 4 | Decorative blob | 3166:70260 | no | atomic | get_screenshot | logoBlob |
| 5 | Loading animation | 3166:71000 | n/a (eAnimLoading) | lottie-placeholder | none | placeholder_animation |

**Cross-reference rule (run after building the visual rows):**
- For every visual row whose `nodeId` matches a `match` in the B0 tagged-asset registry → set `tagged = yes`, `exporter = mcpfigma`, `exportName = match.exportName`.
- For every visual row whose `nodeId` matches a Lottie placeholder from B0 step 5 → set `strategy = lottie-placeholder`, `exporter = none`, `lottieName = "placeholder_animation"`. **No PNG, no xcassets entry.** See `references/lottie-placeholders.md`.
- Else → `tagged = no`, `exporter = get_screenshot`, set `friendlyName` per the §6 naming rules in `references/asset-handling.md`.
- Then walk both lists the other direction: for every B0 tagged `match` OR Lottie placeholder whose nodeId is **not** in the visual inventory → **STOP, ask the user**. Either the designer tagged a node the screenshot doesn't visibly contain (designer/inventory drift), or your visual scan missed it. Both are bugs.
- If `mcpfigmaAvailable = false`, skip the tagged-asset cross-reference entirely; every non-lottie row gets `exporter = get_screenshot`. The Lottie placeholder scan still runs (it reads `metadata.json`, not MCPFigma).

**Hard rules:**
- Every visible non-text element → one row.
- A visible icon you cannot find a nodeId for → **STOP, ask the user**, do not skip.
- Empty inventory on a screen that visibly has icons/logos → bug, re-scan.
- A tagged node sitting inside a flattened parent region → trust the prefix by default and export the tagged node via MCPFigma per its row. The flattened parent still exports via `get_screenshot`. The result is a duplicated visual atom (once inside the flatten PNG, once as a standalone tagged asset), which is fine — only one is referenced from SwiftUI. To override, the user explicitly says "skip MCPFigma for this node".

### Step B2 — Classify (flatten / decompose / code)

Per region:
- **FLATTEN** (`get_screenshot` on the region → one PNG): composed artwork, layered scene, artistic effects, static content. If a tagged node sits inside the flattened parent, the tagged node still exports via MCPFigma per its inventory row — see B1 cross-reference rule.
- **DECOMPOSE** (atomic icons + SwiftUI compose): icon rows, grids, interactive/dynamic content. Each atom → its own row.
- **CODE** (SwiftUI shapes): only for trivial primitives — rect, circle, gradient, blur material. **Not for icons.** "It looks like a circle with a line" is still an icon — download it.
- **MIXED**: flatten artwork sub-frame, overlay interactive UI in ZStack.
- **LOTTIE-PLACEHOLDER** (no download, codegen `LottieView` stub): pre-classified by B0 step 5 for any node whose name starts with `eAnim*`. Children of the `eAnim*` node are designer preview keyframes — never inventoried, never downloaded. The placeholder's frame size comes from the `eAnim*` node's bounding box. See `references/lottie-placeholders.md`.

Heuristic: "the hero illustration" (1 thing) → flatten; "a row of action icons" (N things) → decompose. **Doubt → flatten.** Never reassemble composed artwork with `.offset()`. Rules: `references/asset-handling.md` §1a.

**Lottie placeholder rows are skipped in both B3a and B3b.** They have no PNG to download, no xcassets entry. Phase C2 generates the `LottieView` stub directly from the manifest metadata.

### Step B3a — Batch export tagged assets (MCPFigma)

Skip this step if `mcpfigmaAvailable = false` OR the tagged-asset registry is empty.

Otherwise, **one** call:

```
figma_export_assets(
  fileKey          = <fileKey>,
  nodeId           = <root nodeId — same as B0's nodeId>,
  outputDir        = ".figma-cache/<nodeId>/assets/_mcpfigma",
  assetCatalogPath = <pinned in B0>,
  nodeIds          = [ ...all tagged sourceNodeIds from inventory whose row is exporter=mcpfigma... ],
  scales           = [2, 3],
  overwrite        = true
)
```

Why pass `nodeIds` explicitly: B1 cross-reference may have flagged a tagged node as "skip via user override". Passing the explicit subset honors that.

Why `assetCatalogPath` not `xcodeProjectPath`: avoids multi-`.xcassets` ambiguity. B0 already pinned the catalog.

`skipIfExistsInCatalog` defaults to `true` server-side — re-runs of Phase B are cheap because already-imported imagesets are skipped. To force re-import (e.g. designer changed the artwork), pass `skipIfExistsInCatalog=false`.

**Imageset folder layout:** MCPFigma creates a sub-folder named after the root node inside the catalog: `Assets.xcassets/<RootNodeName>/icAI<Name>.imageset/...`. SwiftUI's `Image("icAI<Name>")` resolves by name across the whole catalog, so the folder hierarchy is for organization only and does not affect call-site code.

**Process the response:**
- `savedFiles` (the `outputDir` ones) → mark inventory row `status: done`, stash `outputPath` in manifest.
- `assetCatalog.savedFiles` → set `xcassetsImported: true`, stash `imagesetPath` in manifest.
- `errors` (or `assetCatalog.errors`) → mark `status: failed` for that node, **fall back to `get_screenshot` for that one node only** (rewrite its inventory row's `exporter` to `get_screenshot`, generate a `friendlyName`, re-process in B3b).
- `warnings` → log to `mcpfigma-warnings.log` and surface to user.

**Validate every PNG:** `file <path>` on every file in `outputDir` must say `PNG image data`. If anything else, treat as a server bug and fall back per node.

### Step B3b — Per-node fallback (`get_screenshot`)

For every inventory row whose `exporter = get_screenshot` (untagged nodes, FLATTEN regions, MCPFigma failures from B3a):

```
get_screenshot(fileKey=<fileKey>, nodeId=<nodeId>)  →  save to .figma-cache/<nodeId>/assets/<friendlyName>.png
```

**No FIGMA_TOKEN needed.** Run in parallel batches.

Optional faster paths (only if available):
- Figma REST API (when `FIGMA_TOKEN` is set): `GET /v1/images/:fileKey?ids=A,B,C&format=png&scale=3` — batches multiple nodes in one call.
- `download_figma_images` MCP tool — only if your MCP server exposes it; only useful for `imageRef` raster fills.

**Never** convert SVG→PNG locally. Validate every downloaded file: `file X.png` must say `PNG image data`. Files reporting `SVG` or `ASCII text` are failures — re-fetch via `get_screenshot`.

**Shared asset store (dedup):** before fetching, check `.figma-cache/_shared/assets/<nodeId>.png` (`:`→`_`). Exists → skip. Save new fetches to `_shared/assets/`, reference from per-screen manifest. See `references/fetch-strategy.md` §Asset Dedup.

Full flow + edge cases: `references/asset-handling.md`.

### Step B4 — Manifest

Write `.figma-cache/<nodeId>/manifest.json`:

```json
{
  "fileKey": "abc",
  "nodeId":  "3166:70147",
  "fetchedAt": "...",
  "phaseA": "done",
  "phaseB": "done",
  "mcpfigma": {
    "available":        true,
    "listResponsePath": ".figma-cache/3166:70147/mcpfigma-list.json",
    "warningsPath":     ".figma-cache/3166:70147/mcpfigma-warnings.log",
    "assetCatalogPath": "/Users/me/Project/App/Assets.xcassets",
    "exportRunAt":      "2026-04-26T10:11:12Z"
  },
  "assetList": [
    {
      "sourceNodeId":     "3166:70211",
      "figmaName":        "eICClose",
      "tagged":           true,
      "exporter":         "mcpfigma",
      "exportName":       "icAIClose",
      "outputPath":       ".figma-cache/3166:70147/assets/_mcpfigma/icAIClose@3x.png",
      "xcassetsImported": true,
      "imagesetPath":     "/Users/me/Project/App/Assets.xcassets/icAIClose.imageset",
      "displaySize":      "24x24",
      "renderingMode":    "template",
      "status":           "done"
    },
    {
      "sourceNodeId":  "3166:70200",
      "figmaName":     "Hero / Onboarding",
      "tagged":        false,
      "exporter":      "get_screenshot",
      "friendlyName":  "heroArtwork",
      "sharedPath":    "_shared/assets/3166_70200.png",
      "strategy":      "flatten",
      "displaySize":   "fill x 240",
      "renderingMode": "original",
      "status":        "done"
    },
    {
      "sourceNodeId": "3166:71000",
      "figmaName":    "eAnimLoading",
      "tagged":       false,
      "exporter":     "none",
      "kind":         "lottie-placeholder",
      "strategy":     "lottie-placeholder",
      "lottieName":   "placeholder_animation",
      "loopMode":     "loop",
      "displaySize":  "120x120",
      "status":       "done"
    }
  ]
}
```

Key notes:
- `xcassetsImported: true` on a row → C4 must NOT re-run sips/imageset/Contents.json for that asset.
- The same `sourceNodeId` must never appear twice. If MCPFigma export fails and the row falls back to `get_screenshot`, REPLACE the row's `exporter` and `friendlyName`/`exportName` rather than adding a second row.

Failed downloads: mark `status: failed`, retry once, then tell user. Never silently drop a row.

### Gate B — Phase B Exit (BASH, mandatory and STRICT)

You MUST run this. If it does not print `GATE: PASS`, you may NOT write any `.swift` file. Improvising assets is a hard violation.

```bash
CACHE=".figma-cache/<nodeId>"
FAIL=0
[ -s "$CACHE/manifest.json" ] && echo "PASS: manifest" || { echo "FAIL: manifest"; FAIL=1; }

# Asset coverage: assetList must not be empty if the design has icon hints OR tagged matches
ASSET_COUNT=$(python3 -c "import json; print(len(json.load(open('$CACHE/manifest.json')).get('assetList',[])))" 2>/dev/null)
ICON_HINTS=$(grep -ciE 'icon|logo|illustration|<img|<svg|VECTOR|BOOLEAN_OPERATION' "$CACHE/design-context.md" "$CACHE/metadata.json" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
TAGGED_COUNT=$(python3 -c "
import json, os
p='$CACHE/mcpfigma-list.json'
print(len(json.load(open(p)).get('matches',[])) if os.path.exists(p) else 0)
" 2>/dev/null)
if [ "${ASSET_COUNT:-0}" -eq 0 ] && { [ "${ICON_HINTS:-0}" -gt 0 ] || [ "${TAGGED_COUNT:-0}" -gt 0 ]; }; then
  echo "FAIL: assetList empty but design has $ICON_HINTS hints / $TAGGED_COUNT tagged matches — re-run Step B1 inventory"; FAIL=1
else
  echo "PASS: assetList coverage ($ASSET_COUNT entries; $TAGGED_COUNT tagged matches)"
fi

# Every assetList row → file on disk (covers both exporters; skip lottie placeholders)
MISSING=$(python3 -c "
import json, os
m = json.load(open('$CACHE/manifest.json'))
for a in m.get('assetList', []):
    if a.get('kind') == 'lottie-placeholder':
        continue                                                # no file expected
    paths = [
        a.get('outputPath',''),                                 # mcpfigma raw
        a.get('sharedPath',''),                                 # get_screenshot dedup
        '$CACHE/assets/' + a.get('friendlyName','') + '.png',   # get_screenshot per-screen
    ]
    if not any(p and os.path.exists(p) for p in paths):
        print('MISSING:', a.get('exportName') or a.get('friendlyName') or '?')
")
[ -z "$MISSING" ] && echo "PASS: all assets on disk" || { echo "FAIL: $MISSING"; FAIL=1; }

# Lottie placeholders sanity (counts only)
LOTTIE_COUNT=$(python3 -c "
import json
m = json.load(open('$CACHE/manifest.json'))
print(sum(1 for a in m.get('assetList',[]) if a.get('kind') == 'lottie-placeholder'))
")
echo "INFO: $LOTTIE_COUNT lottie placeholder(s) detected (no PNG, codegen as LottieView in C2)"

# Imageset check for tagged rows that claim xcassetsImported
BAD_IMAGESET=$(python3 -c "
import json, os
m = json.load(open('$CACHE/manifest.json'))
for a in m.get('assetList', []):
    if a.get('xcassetsImported') and not os.path.isdir(a.get('imagesetPath','')):
        print('MISSING_IMAGESET:', a.get('exportName'))
")
[ -z "$BAD_IMAGESET" ] && echo "PASS: imagesets on disk" || { echo "FAIL: $BAD_IMAGESET"; FAIL=1; }

# All raw files are real PNG (covers both paths)
BAD=$(file "$CACHE/assets/"*.png \
           "$CACHE"/_shared/assets/*.png \
           "$CACHE"/assets/_mcpfigma/*.png \
           2>/dev/null | grep -v "PNG image data" | grep -v "cannot open")
[ -z "$BAD" ] && echo "PASS: assets are real PNG" || { echo "FAIL: non-PNG: $BAD"; FAIL=1; }

# Coverage: every B0 tagged match AND every Lottie placeholder must be in assetList
UNCOVERED=$(python3 -c "
import json, os
needed = set()
list_path = '$CACHE/mcpfigma-list.json'
if os.path.exists(list_path):
    needed |= {m['nodeId'] for m in json.load(open(list_path)).get('matches', [])}
lottie_path = '$CACHE/lottie-placeholders.json'
if os.path.exists(lottie_path):
    needed |= {p['sourceNodeId'] for p in json.load(open(lottie_path))}
present = {a.get('sourceNodeId') for a in json.load(open('$CACHE/manifest.json')).get('assetList', [])}
for nid in sorted(needed - present):
    print('UNCOVERED:', nid)
")
[ -z "$UNCOVERED" ] && echo "PASS: all tagged matches + lottie placeholders covered" || { echo "FAIL: $UNCOVERED"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase B)" || echo "GATE: FAIL (Phase B) — DO NOT WRITE SWIFT FILES"
```

If `GATE: FAIL`: fix the cause (most often: missed inventory rows or wrong nodeId). For tagged-but-uncovered failures, re-run B1 cross-reference and ensure every B0 match has an inventory row. Do NOT begin Phase C until this prints `GATE: PASS`.

---

# Phase C — Implement (offline from cache)

Goal: SwiftUI code that matches the screenshot pixel-for-pixel, using only assets from Phase B.

### Step C1 — Audit & Prepare

**Project pre-flight** (see `references/visual-fidelity.md` §6 + `references/swiftui-pro-bridge.md` §3):
1. iOS deployment target → which SwiftUI APIs available. Read `IPHONEOS_DEPLOYMENT_TARGET` from `pbxproj`. Project baseline is **iOS 16+** — see `references/swiftui-pro-bridge.md` §6 for the iOS 16 fallback table that gates many swiftui-pro rules.
2. `Color(hex:)` extension — grep; if absent, use Asset Catalog / `Color(red:green:blue:)`
3. Localization — check `.strings`/`.xcstrings`. Project baseline is **`Localizable.xcstrings`**. If `STRING_CATALOG_GENERATE_SYMBOLS = YES`, set flag `useStringCatalogSymbols = true` → C2 emits `Text(.symbolKey)` and offers to translate new keys. Else use `LocalizedStringKey` literal form.
4. Dark mode scope — if Figma light-only, ask user
5. **Generated symbol assets** (swiftui-pro/api.md L14) — grep `pbxproj` for `GENERATE_ASSET_SYMBOLS = YES` (default-on for Xcode 15+ projects). If on → flag `useGeneratedSymbols = true` → C2 emits `Image(.icAIClose)` / `Color(.brandRed)`. Else `Image("icAIClose")` / `Color("brandRed")`.
6. **Design constants enums** (`Spacing`, `IKFont`, `IKCoreApp` — locked baseline). Grep:
   ```bash
   grep -rln "enum Spacing\b" --include="*.swift" .
   grep -rln "enum IKFont\b\|extension IKFont\b" --include="*.swift" .
   grep -rln "enum IKCoreApp\b\|struct IKCoreApp\b\|extension IKCoreApp\b" --include="*.swift" .
   ```
   List each enum's available cases (greps `case <token>` lines). Stash in run flags `hasSpacingEnum`, `hasIKFont`, `hasIKCoreApp` plus the case lists. C2 routes Figma values through these per `references/swiftui-pro-bridge.md` §7.
7. **Lottie SDK** — grep `import Lottie` or `Package.resolved` for `lottie-ios`. If present → flag `hasLottieSDK = true`; eAnim* placeholders codegen `LottieView`. Else warn user before C2 starts (see `references/lottie-placeholders.md` §9).
8. **swiftui-pro snapshot present** — confirm `references/swiftui-pro/SOURCE.md` exists. Skill MUST read at minimum `references/swiftui-pro/api.md`, `views.md`, `data.md`, `accessibility.md` before C2; full set on demand. Bridge: `references/swiftui-pro-bridge.md`.

**Print resolved flags at end of C1** so the user can verify routing decisions before any code is written:

```
useGeneratedSymbols      = <bool>
useStringCatalogSymbols  = <bool>
hasSpacingEnum           = <bool>  (cases: ...)
hasIKFont                = <bool>  (cases: ...)
hasIKCoreApp             = <bool>  (cases: ...)
hasColorHexExtension     = <bool>
hasLottieSDK             = <bool>
deploymentTarget         = iOS <N>
localizationStyle        = xcstrings | strings
darkModeScope            = enabled | disabled | unspecified
```

**Visual Inventory (mandatory).** Follow `references/visual-fidelity.md` §1–3. Every visible element → row with source tag `[tokens|inline|class|screenshot]`. Never skip `lineHeight`, `letterSpacing`, `shadow`, `border`, `renderingMode`.

### Step C1b — Adaptation Audit (if modifying existing screen)
Element-by-element ADD/UPDATE/REMOVE diff, user review before coding. See `references/adaptation-workflow.md`.

### Step C2 — Implement

**Reuse order:**
1. Code Connect mapped component → 2. Shared design-system component → 3. Nearby feature component → 4. Existing modifier/style/token → 5. New (only if nothing fits)

**Build order (outside-in):**
1. Outermost container, safe-area, background
2. Primary stack (VStack/HStack/ZStack/ScrollView) — explicit `spacing:` and alignment
3. Sections top-to-bottom, following inventory order
4. Text & icons per section — font, lineSpacing, tracking, color, renderingMode, tint
5. Backgrounds, borders, shadows, corner radius — watch `.background` vs `.padding` order (see `references/layout-translation.md`)
6. Effects (blur, mask, blend) — last
7. Interactions — `.buttonStyle(.plain)` for custom, navigation

**Critical rules:**
- MCP output = spec, not code. Parse values (see `references/visual-fidelity.md` §1), build native SwiftUI.
- `Text` → `LocalizedStringKey`; `Text(verbatim:)` for dynamic data.
- `Color(hex:)` only if project has the extension; else Asset Catalog or `Color(red:green:blue:)`.
- Respect iOS deployment target — don't use iOS 17+ APIs if target lower.
- Don't draw iOS system chrome (status bar, Dynamic Island, home indicator, system keyboard, system nav back, system `TabView` bar, pull-to-refresh). See the **ABSOLUTE RULE — Do NOT draw iOS system chrome** section near the top.
- **Use Figma assets only.** Every `Image(...)` must reference an asset downloaded in Phase B. `Image(systemName:)` is BANNED for Figma-designed icons. Drawing logos from `Text("G")` or colored `Rectangle()` is BANNED. If an asset is missing, STOP and re-run Phase B, never improvise.
- **Lottie placeholders.** For every manifest row with `kind: "lottie-placeholder"`, emit a `LottieView` stub in place of an asset, using the `lottie-ios` (Airbnb) SwiftUI API. Do NOT substitute with `Image(systemName:)`, do NOT draw a static frame from the children of the `eAnim*` node. See `references/lottie-placeholders.md` §6 for the exact code template. Add `import Lottie` once per file. The placeholder name is always the literal `"placeholder_animation"` — do not derive from the Figma name. Append a `// TODO:` comment instructing the developer to replace the name.
- **swiftui-pro standards (write-time, MANDATORY).** All emitted SwiftUI must comply with the snapshot in `references/swiftui-pro/`. The 23-row always-on transform table in `references/swiftui-pro-bridge.md` §2 is non-negotiable on every project, every emit:
  - `.bold()` not `.fontWeight(.bold)`; `.foregroundStyle()` not `.foregroundColor()`.
  - `Image(decorative:)` for decorative Figma images; `.accessibilityLabel("…")` on every meaningful icon (derive label from semantic Figma name: `eICClose` → `"Close"`).
  - Icon-only `Button` → `Button("Label", systemImage: …, action: …)` form OR custom label + `.accessibilityLabel`. Never bare image-only without a label.
  - Tap targets < 44pt → wrap with `.contentShape(.rect).frame(minWidth: 44, minHeight: 44)`.
  - `#Preview` macro, never `PreviewProvider`.
  - Conditional modifier toggle by ternary, never `if/else` view branching.
  - Animations always carry a `value:` parameter.
  - `NavigationStack` + `.navigationDestination(for:)`; never `NavigationView` or `NavigationLink(destination:)`.
  - No `Text` concatenation with `+`; use interpolation.
  - `.onTapGesture` only when you need tap location/count; otherwise `Button`.
- **iOS 16 baseline fallbacks (MANDATORY).** Project baseline is iOS 16+. Several swiftui-pro rules target iOS 17/18/26 and MUST be conditionally rewritten on iOS 16. Full table: `references/swiftui-pro-bridge.md` §6. Examples: `.clipShape(RoundedRectangle(cornerRadius: 12))` (not `.rect(cornerRadius:)`), `.navigationBarLeading` (not `.topBarLeading`), `tabItem { Label(…) }` (not `Tab(…)`), `ObservableObject` + `@StateObject` (not `@Observable` + `@Bindable`). Always emit comment marker `// iOS 16 fallback — switch to <modern API> at iOS <N>+` so future bumps are search-replaceable.
- **Project token routing (MANDATORY when audit flags set).** `Spacing`, `IKFont`, `IKCoreApp` are locked baseline enums. C1 audit confirms presence + lists cases. Route Figma values through them per `references/swiftui-pro-bridge.md` §7:
  - Spacing/padding/gap → `Spacing.<token>` first; fall back inline only when no token matches.
  - Typography → `IKFont.<token>` first; else `@ScaledMetric` + `.font(.system(size:weight:))`.
  - Top-level app values → `IKCoreApp.colors.*`, `IKCoreApp.spacing.*`.
  - Never invent new enum cases; surface mismatches in the run summary instead.

**Translation references:**
- `references/visual-fidelity.md` — **read first, always**
- `references/swiftui-pro-bridge.md` — **read second, always** (transform tables + iOS 16 fallbacks + token routing)
- `references/swiftui-pro/api.md`, `views.md`, `data.md`, `accessibility.md` — load on demand for specific rules
- `references/layout-translation.md` — Auto Layout, stacks, sizing, effects, animations
- `references/design-token-mapping.md` — typography, colors, gradients, opacity
- `references/component-variants.md` — state/size/style
- `references/responsive-layout.md` — size classes, iPhone+iPad

### Step C3 — Self-Check (mandatory, four passes + structural gates)

**Pass 1 — Code vs Inventory.** For each inventory row, verify code matches exactly. Fix every ✗.

**Pass 2 — Code vs Screenshot (mandatory, structured diff report).**

Mental walk-throughs are too easy to fake. Pass 2 produces a verifiable artifact: `.figma-cache/<nodeId>/c3-pass2-diff.md`, written using the template in `references/verification-loop.md` §1.

Procedure:
1. Open `screenshot.png` and `design-context.md` side by side.
2. For every check code (LH, LS, SH, BD, OP, RM, IS, DV, BG, TR, GR, SA, CH, PD, BS — defined in `references/visual-fidelity.md` §5) walk every section of the screen.
3. Write one Findings row per check with: `Source quote` (verbatim from design-context.md or inventory — no paraphrasing), `Code value` (verbatim SwiftUI modifier), `File:Line` (real line in a generated swift file), `Match` (PASS/FAIL/N/A), `Severity` (high/medium/low for FAIL).
4. Every check letter must appear ≥1 time. No instance on screen → one N/A row with reason. Minimum 12 rows total.

Then run **Gate C3-Pass2** (BASH, mandatory). Full block + 6 anti-hallucination checks: `references/verification-loop.md` §4.1.

Two failure modes:
- **Gate FAIL** (report invalid) → regen report; no code edits; no counter bump. After 2 consecutive regen failures, ASK user.
- **Gate PASS, `HIGH_FAILS > 0`** → trigger self-fix loop. Default `MAX_RETRIES=2` (override at task start with `max 3 retries`). Snapshot report to `c3-pass2-diff.attempt-<N>.md`, increment counter, edit ONLY the file:line cited in each FAIL row (no refactoring), re-run Pass 2 from scratch. Asymptote check: if `highFailsHistory` not decreasing → exit as exhausted. Full pseudocode + state layout: `references/verification-loop.md` §4.3.

User abort phrases (`stop fixing`, `ship as-is`) → mark `manifest.verification.c3Pass2.lastResult = "user_override"`, continue.

**Pass 3 — Asset substitution scan (BASH, mandatory):**

```bash
HITS=$(grep -rnE 'Image\(systemName:' <generated-swift-files>)
[ -z "$HITS" ] && echo "PASS: no SF Symbol substitution" || { echo "FAIL: SF Symbol used where Figma asset expected:"; echo "$HITS"; }
```

Every hit must be justified against the allow-list (system chrome only) or replaced with the Figma asset. Same applies to `Text("G")` / `Rectangle().fill(...)` standing in for logos — visually scan and fix.

**Pass 3b — System chrome scan (BASH, mandatory):**

```bash
CHROME=$(grep -rnE '"9:41"|Image\(systemName: "(wifi|battery|cellularbars|antenna|dot\.radiowaves)"\)|StatusBar|HomeIndicator|DynamicIsland' <generated-swift-files>)
[ -z "$CHROME" ] && echo "PASS: no system-chrome drawing" || { echo "FAIL: system chrome drawn in view (delete — iOS renders it):"; echo "$CHROME"; }
```

Also visually scan for a `Capsule()` / `RoundedRectangle()` at the bottom with width≈134 and height≈5 — that's the home indicator. Delete it. iOS draws it.

**Pass 4 — swiftui-pro Review (BASH + structural checklist, mandatory).**

Catches violations that slipped past C2's preventive rules. Two parts: bash sweep (deterministic) + structural review (manual walk).

**Part A: Bash sweep.**

```bash
SWIFT_FILES="<your-generated-swift-files>"
DEPTARGET="<from C1 audit, e.g. 16>"
FAIL=0

# (1) Modern API hits — always-on (regardless of deployment target)
HITS_API1=$(grep -nE 'foregroundColor\(|fontWeight\(\.bold\)|showsIndicators:|UIScreen\.main\.bounds|onChange\(of:.*\) \{ [^_]' $SWIFT_FILES)
[ -z "$HITS_API1" ] && echo "PASS: api.md (always)" || { echo "FAIL: api.md violations:"; echo "$HITS_API1"; FAIL=1; }

# (2) Deprecated API — `cornerRadius()` is always wrong; `.rect(cornerRadius:)` is iOS 17+ so iOS 16 must use RoundedRectangle().
HITS_CR=$(grep -nE '\.cornerRadius\(' $SWIFT_FILES)
[ -z "$HITS_CR" ] && echo "PASS: no .cornerRadius()" || { echo "FAIL: replace .cornerRadius() with .clipShape(RoundedRectangle(cornerRadius:)) on iOS 16:"; echo "$HITS_CR"; FAIL=1; }

# (3) iOS 16 forbids: .topBarLeading, .topBarTrailing, .clipShape(.rect(cornerRadius:)), Tab(...) ctor, @Observable, @Bindable
if [ "$DEPTARGET" -lt 17 ]; then
  HITS_iOS17=$(grep -nE '\.topBarLeading|\.topBarTrailing|\.rect\(cornerRadius:|@Observable\b|@Bindable\b' $SWIFT_FILES)
  [ -z "$HITS_iOS17" ] && echo "PASS: no iOS 17+ APIs on iOS $DEPTARGET" || { echo "FAIL: iOS 17+ API used but target is $DEPTARGET (use fallbacks per swiftui-pro-bridge.md §6):"; echo "$HITS_iOS17"; FAIL=1; }
fi
if [ "$DEPTARGET" -lt 18 ]; then
  HITS_iOS18=$(grep -nE 'Tab\("|@Entry\b' $SWIFT_FILES)
  [ -z "$HITS_iOS18" ] && echo "PASS: no iOS 18+ APIs on iOS $DEPTARGET" || { echo "FAIL: iOS 18+ API used but target is $DEPTARGET:"; echo "$HITS_iOS18"; FAIL=1; }
fi

# (4) Views & previews
HITS_VIEWS=$(grep -nE 'PreviewProvider|AnyView' $SWIFT_FILES)
[ -z "$HITS_VIEWS" ] && echo "PASS: views.md/performance.md" || { echo "FAIL: views/perf:"; echo "$HITS_VIEWS"; FAIL=1; }

# (5) Concurrency
HITS_CON=$(grep -nE 'DispatchQueue\.|Task\.sleep\(nanoseconds:|Task\.detached' $SWIFT_FILES)
[ -z "$HITS_CON" ] && echo "PASS: swift.md concurrency" || { echo "FAIL: concurrency:"; echo "$HITS_CON"; FAIL=1; }

# (6) Bindings
HITS_BIND=$(grep -nE 'Binding\(get:.*set:' $SWIFT_FILES)
[ -z "$HITS_BIND" ] && echo "PASS: data.md bindings" || { echo "FAIL: manual Binding(get:set:):"; echo "$HITS_BIND"; FAIL=1; }

# (7) Navigation
HITS_NAV=$(grep -nE 'NavigationView\b|NavigationLink\(destination:' $SWIFT_FILES)
[ -z "$HITS_NAV" ] && echo "PASS: navigation.md" || { echo "FAIL: deprecated navigation:"; echo "$HITS_NAV"; FAIL=1; }

# (8) Accessibility — Image without label or decorative marker (within 5-line window)
ORPHAN_IMAGE=$(python3 -c "
import re, pathlib
files = '''$SWIFT_FILES'''.split()
for f in files:
    text = pathlib.Path(f).read_text()
    lines = text.splitlines()
    for i, line in enumerate(lines, 1):
        if re.search(r'Image\([\"\.]', line) and 'decorative' not in line and 'systemName:' not in line:
            window = '\n'.join(lines[i-1:i+5])
            if 'accessibilityLabel' not in window and 'accessibilityHidden' not in window:
                print(f'{f}:{i}: {line.strip()}')
")
[ -z "$ORPHAN_IMAGE" ] && echo "PASS: image accessibility" || { echo "REVIEW: images missing label/decorative:"; echo "$ORPHAN_IMAGE"; }

# (9) Force unwrap (informational — verify each manually)
HITS_BANG=$(grep -nE '![\.[]' $SWIFT_FILES | grep -v '!=' | grep -v '//' || true)
[ -z "$HITS_BANG" ] && echo "PASS: no force unwraps" || echo "REVIEW: force unwraps (verify each is unrecoverable):"

# (10) Text concatenation with +
HITS_TEXT_PLUS=$(grep -nE 'Text\([^)]+\)\s*\+\s*Text\(' $SWIFT_FILES)
[ -z "$HITS_TEXT_PLUS" ] && echo "PASS: no Text +" || { echo "FAIL: Text concatenation with +:"; echo "$HITS_TEXT_PLUS"; FAIL=1; }

# (11) onTapGesture for actions (should be Button)
HITS_TAP=$(grep -nE '\.onTapGesture\s*\{' $SWIFT_FILES)
[ -z "$HITS_TAP" ] && echo "PASS: no onTapGesture for actions" || echo "REVIEW: onTapGesture — convert to Button unless tap location/count needed:"

# (12) iOS 16 fallback marker presence (when target < 17)
if [ "$DEPTARGET" -lt 17 ]; then
  CHROME_NAV=$(grep -nE 'navigationBarLeading|navigationBarTrailing|RoundedRectangle\(cornerRadius:' $SWIFT_FILES)
  if [ -n "$CHROME_NAV" ]; then
    MISSING_MARK=$(echo "$CHROME_NAV" | while read line; do
      f=$(echo "$line" | cut -d: -f1)
      n=$(echo "$line" | cut -d: -f2)
      ctx=$(sed -n "$((n-2)),$((n+2))p" "$f" 2>/dev/null)
      echo "$ctx" | grep -q "iOS 16 fallback" || echo "$line"
    done)
    [ -z "$MISSING_MARK" ] && echo "PASS: iOS 16 fallback markers present" || echo "REVIEW: iOS 16 fallback used but missing comment marker:"; echo "$MISSING_MARK"
  fi
fi

[ $FAIL -eq 0 ] && echo "GATE: PASS (Pass 4 — swiftui-pro Review bash)" || echo "GATE: FAIL (Pass 4 bash) — DO NOT proceed to C4"
```

**Part B: Structural review (manual walk per file).**

For each generated `.swift` file, walk the structural rules table in `references/swiftui-pro-bridge.md` §4. Specifically:
1. View body length — any `body` > ~40 lines? Extract sub-sections into separate `View` structs in their own files. **Computed properties returning `some View` are not acceptable** even with `@ViewBuilder`.
2. Multiple types per file? Each struct/class/enum into its own file.
3. Inline business logic in `body`/`task`/`onAppear`? Extract to method or `@Observable`/`ObservableObject` view model.
4. `@Observable` (iOS 17+) class missing `@MainActor`? Add `@MainActor`.
5. (iOS 17+ projects only) `ObservableObject` + `@Published` + `@StateObject` instead of modern `@Observable`? Recommend migration unless legacy reasons.

Output format mirrors swiftui-pro SKILL.md "Output Format" — group findings by file, name rule violated, before/after fix. Add a prioritized summary at the end.

**If Part A or Part B FAIL: fix every violation before proceeding to C4.** Re-run Part A bash to confirm clean exit.

Anything in code not traceable to inventory → guess → fix. Never "tweak until it looks right".

### Step C4 — Copy Assets to Project

For each row in `manifest.assetList`, branch on `exporter`:

**`exporter == "mcpfigma"`:**
- The `.imageset` is already inside `Assets.xcassets` (MCPFigma did this in B3a). Verify `imagesetPath` exists and contains at least one `*@2x.png` and one `*@3x.png`. **No sips, no Contents.json work.**
- If `xcassetsImported = false` (B3a wrote raw PNGs to `outputDir` but the catalog write failed), fall back to the get_screenshot path: take the existing `outputPath` PNGs, run sips for `@1x`, build the imageset by hand, copy. Treat as a get_screenshot row going forward.
- Rendering mode is decided at the SwiftUI **call site** — MCPFigma does not write `template-rendering-intent`.

**`exporter == "get_screenshot"`:**
1. Rendering mode: single-color icon → template; else original (see `references/asset-handling.md` §4)
2. `sips` → @1x/@2x/@3x from 3× source
3. `.imageset` + Contents.json: universal idiom; `template-rendering-intent` for tinted; `appearances` for dark variants
4. Copy to `Assets.xcassets` (use the catalog pinned in B0)

**SwiftUI call-site rules (both paths):**
- `Image("<exportName>")` for mcpfigma rows; `Image("<friendlyName>")` for get_screenshot rows. The manifest is the single source of truth.
- Always `.resizable()` + explicit `.frame(width:height:)`.
- Single-color icon (`renderingMode == "template"` in manifest):
  - mcpfigma rows → `.renderingMode(.template)` + `.foregroundStyle(...)` at the call site.
  - get_screenshot rows → may rely on `template-rendering-intent` in Contents.json, OR explicit `.renderingMode(.template)` — both work.
- Multi-color / illustration / brand: no `.renderingMode` modifier. Patterns in `references/asset-handling.md` §7.

**Verification (BASH, mandatory):**

```bash
SWIFT_FILES="<your-generated-swift-files>"

# (a) Every Image("...") in generated views must appear in manifest as exportName or friendlyName.
NAMES=$(python3 -c "
import json
m = json.load(open('.figma-cache/<nodeId>/manifest.json'))
for a in m['assetList']:
    if a.get('kind') == 'lottie-placeholder':
        continue
    print(a.get('exportName') or a.get('friendlyName'))
")
USED=$(grep -hoE 'Image\("[^"]+"\)' $SWIFT_FILES | sed -E 's/Image\("([^"]+)"\)/\1/')
for h in $USED; do
  echo "$NAMES" | grep -qx "$h" || echo "ORPHAN: Image(\"$h\") not in manifest"
done

# (b) Every lottie-placeholder row must have a matching LottieView call in the generated views.
PLACEHOLDER_COUNT=$(python3 -c "
import json
m = json.load(open('.figma-cache/<nodeId>/manifest.json'))
print(sum(1 for a in m['assetList'] if a.get('kind') == 'lottie-placeholder'))
")
LOTTIE_USES=$(grep -cE 'LottieView\(animation: \.named\("placeholder_animation"\)\)' $SWIFT_FILES \
              | awk -F: '{s+=$2} END{print s+0}')
if [ "$PLACEHOLDER_COUNT" -gt 0 ] && [ "$LOTTIE_USES" -lt "$PLACEHOLDER_COUNT" ]; then
  echo "FAIL: $PLACEHOLDER_COUNT lottie placeholders in manifest but only $LOTTIE_USES LottieView call(s) in code"
fi

# (c) `import Lottie` must appear in every file that uses LottieView.
for f in $SWIFT_FILES; do
  if grep -q 'LottieView(' "$f" && ! grep -q '^import Lottie' "$f"; then
    echo "FAIL: $f uses LottieView but is missing 'import Lottie'"
  fi
done

# (d) Imagesets exist for every row that should be in xcassets.
find <project>/Assets.xcassets -name "*.imageset" -type d
```

Build in Xcode — no "image not found" warnings, no missing-import errors. After the run, surface the placeholder list to the user (see `references/lottie-placeholders.md` §8 for the end-of-run summary template).

### Step C5 — Visual Validate (default ON, user can opt out)

After C3 finishes (Pass 2 clean report, Pass 3/3b grep clean, C4 assets copied), propose runtime validation. This catches what Pass 2 cannot see: real font rendering, shadow at simulator DPI, safe-area on chosen device, keyboard avoidance, animation start state.

Default: **PROMPT** with wording like *"C3 passed. Run C5 (build + screenshot simulator + side-by-side compare with Figma)? ~30s–2min. Reply 'yes' or 'skip C5'."*

Opt-out phrases: `skip C5`, `skip validate`, `no build`, `bỏ qua C5`, `không cần build`. Persist in `manifest.verification.c5.userChoice` so re-runs don't re-prompt.

If accepted, run the 6 sub-steps (commands + edge cases in `references/verification-loop.md` §5):

1. **C5.1 Detect target** — `xcodebuild -list`. 1 scheme → use it; >1 → ask user, stash; 0 → skip with `manifest.verification.c5.skipped = "no_project"`.
2. **C5.2 Pick simulator** — prefer Booted iPhone, else highest-iOS iPhone 15/16. Stash UDID.
3. **C5.3 Build** — `xcodebuild -scheme ... -destination ... build`, log to `c5-build.log`. Build fail → surface compile errors as FAIL high rows, self-fix loop, do NOT install.
4. **C5.4 Boot/install/launch** — `simctl boot/install/launch`. Wrong default screen → ask user once for `previewEntry`, stash.
5. **C5.5 Capture** — `sleep 2 && xcrun simctl io <udid> screenshot c5-simulator.png`.
6. **C5.6 Compare** — model reads both PNGs, writes `c5-visual-diff.md` using same table format as C3 Pass 2 (Source quote → Note column). Compare composition and values, not absolute pixel positions.

Then run **Gate C5** (BASH, mandatory). Full block: `references/verification-loop.md` §5.7. High-severity diffs feed the same self-fix loop as C3 Pass 2 (shared counter, `MAX_RETRIES=2`, scoped edits only). Build failures count as FAIL high.

### Step C6 — Register Code Connect (optional)
If (and only if) your Figma MCP exposes a register/add Code Connect tool, call it for new reusable components.

---

## Resume & Retry

Check manifest. `phaseA` and `phaseB` both `done` → skip to Phase C. Some `failed` → retry those only. Cache > 24h → suggest re-fetch. User phrases: "tiếp tục fetch" (resume from last incomplete phase), "implement from cache" (skip to Phase C, but Gate B must still pass).

## MCPFigma edge cases (reference)

- **MCPFigma not configured.** B0 probe sets `mcpfigmaAvailable = false`, prints one warning. Phase B falls through entirely to `get_screenshot`. No further prompt — silent fallback after the warning is enough. See `references/mcpfigma-setup.md`.
- **`FIGMA_ACCESS_TOKEN` missing or invalid.** `figma_list_assets` returns an auth error → same as "not configured", but with token-specific warning so the user knows the fix.
- **Designer tagged a node but the name is invalid** (warning row from B0). Logged in `mcpfigma-warnings.log`. The node is NOT exported by MCPFigma; it falls back to `get_screenshot`. Either re-tag in Figma (`eIC<UpperCamel>`) or accept the fallback.
- **Designer tags `eImageHero` containing nested interactive UI.** Trust the prefix by default — export the tagged node via MCPFigma even though the visual region looks like a FLATTEN candidate. Result is a flat raster of the whole region, fine for a hero. Override only when user explicitly says "treat eImageHero as decompose" — strip its `tagged` flag, set `exporter = get_screenshot`, mark FLATTEN.
- **Project has multiple `.xcassets`.** B0 prompts for `assetCatalogPath` and stashes it in the manifest. `xcodeProjectPath` is never used by the skill — it can't disambiguate.
- **`figma_export_assets` returns non-PNG.** Per Figma `/v1/images` contract, this should not happen. If `file <path>` ever shows non-PNG, treat as a server bug: mark the row `failed`, fall back to `get_screenshot`, file an issue.
- **Light/dark variants.** MCPFigma exports each tagged node as one imageset. To support light/dark, designer ships two nodes (`eICLogo` + `eICLogoDark`). The app picks at `colorScheme`. Merging both into one imageset (with `appearances`) is supported only by the `get_screenshot` path; if needed, take the manual path described in `references/asset-handling.md` §5 "light + dark variants".
- **Same `exportName` from two different source nodeIds.** MCPFigma adds `_2` suffix and emits a warning. Surface to user — the SwiftUI call site needs to know which is which.
- **Phase B re-run after partial success.** MCPFigma is idempotent (`overwrite=true` default). On re-run, only still-failing nodes are re-attempted; successful rows are no-op overwrites. Inspect manifest's `status` field before re-running — `done` rows can be skipped entirely if `outputPath` and (when applicable) `imagesetPath` still exist.
- **Lottie placeholder (`eAnim*`) — Lottie SDK missing.** C1 project pre-flight should detect whether `lottie-ios` is in dependencies. If not, surface to the user before C2 starts: *"Lottie SDK not detected — add `lottie-ios` (Airbnb) via SPM or CocoaPods, or convert these placeholders to static images."* Do NOT auto-install; do NOT silently swap in `Image(systemName:)`. See `references/lottie-placeholders.md` §9.
- **Lottie placeholder inside a flatten region.** The flattened parent exports as a static raster (animation is frozen in one frame). The placeholder `LottieView` overlays on top in `ZStack`. Tell the user the artwork would be cleaner if the designer pulled the `eAnim*` node out of the flatten region.
- **Custom Lottie wrapper in project.** If C1 audit finds `IKLottieView`/`AnimatedView`/etc., prefer the wrapper at C2 codegen. The placeholder name string `"placeholder_animation"` stays unchanged.

## Recommended hooks (hard enforcement)

To make Phase B genuinely un-skippable, add a `PreToolUse` hook in `.claude/settings.json` that blocks `Write`/`Edit` on `*.swift` files when `.figma-cache/<nodeId>/manifest.json` is missing or has empty `assetList`. Without the hook, gates rely on the agent honoring them; with the hook, the OS-level tool call is denied.

To make C3 Pass 2 self-checking automatic, add a `PostToolUse` hook on `Write` matching `c3-pass2-diff.md` that auto-runs the Gate C3-Pass2 BASH block and prints PASS/FAIL. Saves one round-trip per attempt and surfaces structural bugs immediately.

Both are optional. Ask the assistant to set them up via the `update-config` skill if you want them.

## Key Principles

1. **Three phases, three gates, no skipping.** Phase A → Gate A. Phase B → Gate B. Phase C self-check. Each gate prints `GATE: PASS` or you do not proceed.
2. **All assets from Figma — no exceptions.** SF Symbols, colored shapes, `Text("G")` logos, "simplified" illustrations are BANNED. Missing asset → stop and re-fetch, never improvise.
3. **Fidelity is the goal.** Pixel-for-pixel — spacing, color, font, lineHeight, tracking, shadow, border, opacity, gradient. Approximation is a bug.
4. **MCP output is a spec.** Parse values per `references/visual-fidelity.md` §1. Never port React/Tailwind to SwiftUI.
5. **Every value must be traceable.** Trace to tokens, inline style, class, or design-context comment. Untraceable = guessed.
6. **Visual Inventory first, every Phase C.** Never skip lineHeight/tracking/shadow/border/renderingMode.
7. **Self-check four passes + structural gates.** Pass 1 code-vs-inventory, Pass 2 code-vs-screenshot (writes `c3-pass2-diff.md`, Gate C3-Pass2 verifies structure + anti-hallucination), Pass 3/3b bash grep for `Image(systemName:` and system chrome, Pass 4 swiftui-pro Review (deprecated API + iOS 16 fallbacks + structural).
8. **Beware SwiftUI defaults.** Always specify `.font(.system(size:))`, `VStack(spacing:)`, `.padding(X)`, `.buttonStyle(.plain)` for custom buttons.
9. **Flatten composed artwork.** Don't reassemble atoms via `.offset()`. When in doubt → flatten.
10. **`get_screenshot(nodeId)` is the default asset downloader.** No token, no excuse to skip.
11. **Verification produces artifacts.** Pass 2 writes a structured diff report; C5 captures a simulator screenshot and writes a visual diff report. Both are gated and feed a self-fix loop. Mental walk-throughs are not enough — the agent can lie, but `file <path>` cannot.
