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

### Step A2 — Screen Discovery (registry-first)

Call `figma_build_registry(fileKey, nodeId, depth=10)` once. The response gives you `screens[]` (FRAME-like children with iOS-canvas dimensions) directly — no manual `get_metadata` walk needed. Persist to `.figma-cache/<nodeId>/registry.json`.

- 0 screens **and** root is not itself a FRAME → ask user to point at a frame, not a page.
- 1 screen → continue with this skill.
- N > 1 screens → hand off to `figma-flow-to-swiftui-feature` (which reuses the same registry).

The registry response also includes `taggedAssets[]` and `lottiePlaceholders[]` — Step B0 reuses these instead of re-fetching. See `references/screen-discovery.md`.

### Step A3 — Batch Fetch Spec

Run in parallel where possible; save to `.figma-cache/<nodeId>/`:

1. `get_design_context(fileKey, nodeId, prompt="generate for iOS using SwiftUI")` → `design-context.md`
2. `get_screenshot(fileKey, nodeId)` at **scale 3** (fine details visible) → `screenshot.png` (this is the FRAME screenshot, not asset)
3. `figma_extract_tokens(fileKey)` → `tokens.json` (once per `fileKey` — dedup by copying/symlinking). This replaces `get_variable_defs` + manual SwiftUI naming. Output already has `swiftName`, `lightHex`/`darkHex`, `isCapsule` for radius. Empty `colors`+`spacing`+… with non-empty `warnings` = file has no Variables API access; fall back to reading `design-context.md` inline tokens at C2.
4. `get_metadata(fileKey, nodeId)` → `metadata.json` (kept for design-context cross-ref in Phase C; A2's registry handles asset discovery)
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
[ -s "$CACHE/registry.json" ] && grep -q '"rootNode"' "$CACHE/registry.json" && echo "PASS: registry" || { echo "FAIL: registry"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase A)" || echo "GATE: FAIL (Phase A)"
```

---

# Phase B — Asset Pipeline

**This is the phase agents skip. Don't.** Goal: every visible icon/logo/illustration/image from the screenshot exists as a validated PNG on disk (and, for tagged assets, also as an `.imageset` inside `Assets.xcassets`).

The whole pipeline runs through **`figma_export_assets_unified`** — one call that handles tagged + fallback paths internally:

- **Tagged path** (rows with `exporter: "tagged"`) — for `eIC*` / `eImage*` nodes registered by the designer. Renders @2x/@3x, renames to `icAI<Name>` / `imageAI<Name>`, writes `.imageset` directly into `Assets.xcassets`.
- **Fallback path** (rows with `exporter: "fallback"`) — for FLATTEN regions, untagged atomic nodes, and tagged rows that the server failed to render. Renders at scale 3 via `/v1/images`, validates PNG signature, dedupes into `_shared/assets/`.
- **Lottie path** (rows with `strategy: "lottiePlaceholder"`) — pass-through; manifest row only, no PNG.

Skill picks the right `exporter`/`strategy` per row in B1/B2 (visual judgment); the tool nukes all the orchestration. See `references/mcpfigma-setup.md`.

### Step B0 — Read registry, pin asset catalog

The `registry.json` written in A2 already contains everything the old Step B0 probed for: `taggedAssets[]`, `lottiePlaceholders[]`, naming `warnings[]`. No second probe.

1. **Surface designer warnings** from `registry.warnings` to the user once at the end of Phase B (e.g. `eIChome` lowercase → falls back to fallback path; user fixes name in Figma to use the MCPFigma fast path).

2. **Pin `assetCatalogPath`** for this run (project-specific judgment, not in the tool):
   - 0 `.xcassets` in project → ask user to create one before continuing.
   - 1 `.xcassets` → silent default, tell user which one.
   - N > 1 → interactive prompt; stash answer in `manifest.assetCatalogPath`.

   On Phase B re-run, prefer the previously stashed value.

### Step B1 — Inventory (visual-first)

Open `screenshot.png` and **list every visible non-text element**. Cross-reference three sources:
1. Visual scan of `screenshot.png` (ground truth — start here)
2. `design-context.md`: `<img>` URLs, inline `<svg>`, `imageRef`, `background-image`
3. `metadata.json`: nodes of type `VECTOR`, `BOOLEAN_OPERATION`, `INSTANCE`; names with `icon`, `ic_`, `logo`, `illustration`

Build the inventory table (with `registry.taggedAssets[]` and `registry.lottiePlaceholders[]` in mind):

| # | Purpose | NodeId | Exporter | Strategy | exportName / friendlyName / lottieName |
|---|---|---|---|---|---|
| 1 | Close icon | 3166:70211 | tagged | atomic | icAIClose |
| 2 | Hero illustration | 3166:70200 | fallback | flatten | heroArtwork |
| 3 | Facebook logo | 3166:70250 | tagged | atomic | icAIFacebook |
| 4 | Decorative blob | 3166:70260 | fallback | atomic | logoBlob |
| 5 | Loading animation | 3166:71000 | fallback | lottiePlaceholder | placeholder_animation |

**Cross-reference rule (run after building the visual rows):**
- For every visual row whose `nodeId` matches a `registry.taggedAssets[]` entry → set `exporter = "tagged"`, `exportName = entry.exportName`.
- For every visual row whose `nodeId` matches a `registry.lottiePlaceholders[]` entry → set `strategy = "lottiePlaceholder"`, `lottieName = "placeholder_animation"`. **No PNG, no xcassets entry.** See `references/lottie-placeholders.md`.
- Else → `exporter = "fallback"`, set `friendlyName` per the §6 naming rules in `references/asset-handling.md`.
- Then walk both lists the other direction: for every tagged asset OR Lottie placeholder in registry whose nodeId is **not** in the visual inventory → **STOP, ask the user**. Either the designer tagged a node the screenshot doesn't visibly contain (designer/inventory drift), or your visual scan missed it. Both are bugs.

**Hard rules:**
- Every visible non-text element → one row.
- A visible icon you cannot find a nodeId for → **STOP, ask the user**, do not skip.
- Empty inventory on a screen that visibly has icons/logos → bug, re-scan.
- A tagged node sitting inside a flattened parent region → keep the tagged row (will export through tagged path). The flattened parent still exports as a fallback row. The result is a duplicated visual atom (once inside the flatten PNG, once as a standalone tagged asset), which is fine — only one is referenced from SwiftUI. To override, the user explicitly says "skip tagged path for this node" — set `exporter = "fallback"` on that row.

### Step B2 — Classify (flatten / decompose / code)

Per region:
- **FLATTEN** (one fallback row whose nodeId is the region root): composed artwork, layered scene, artistic effects, static content. If a tagged node sits inside the flattened parent, keep its own tagged row — see B1 cross-reference rule.
- **DECOMPOSE** (atomic rows, one per icon): icon rows, grids, interactive/dynamic content.
- **CODE** (SwiftUI shapes, no row at all): only for trivial primitives — rect, circle, gradient, blur material. **Not for icons.**
- **MIXED**: flatten artwork sub-frame as a fallback row, overlay interactive UI in ZStack at code time.
- **LOTTIE-PLACEHOLDER**: registry already pre-classified these. Inventory row uses `strategy: "lottiePlaceholder"`. See `references/lottie-placeholders.md`.

Heuristic: "the hero illustration" (1 thing) → flatten; "a row of action icons" (N things) → decompose. **Doubt → flatten.** Never reassemble composed artwork with `.offset()`. Rules: `references/asset-handling.md` §1a.

### Step B3 — Unified export (one call)

Send the inventory to `figma_export_assets_unified`:

```
figma_export_assets_unified(
  fileKey          = <fileKey>,
  nodeId           = <root nodeId>,
  outputDir        = ".figma-cache/<nodeId>/assets",
  sharedAssetsDir  = ".figma-cache/_shared/assets",
  assetCatalogPath = <pinned in B0>,
  rows = [
    { nodeId: "3166:70211", exporter: "tagged",   exportName: "icAIClose" },
    { nodeId: "3166:70200", exporter: "fallback", friendlyName: "heroArtwork", strategy: "flatten" },
    { nodeId: "3166:71000", exporter: "fallback", friendlyName: "placeholder_animation", strategy: "lottiePlaceholder" }
  ]
)
```

The tool absorbs everything that used to be skill prose:
- Tagged batch render (@2x, @3x), naming, xcassets imageset write, screen-folder grouping.
- Fallback batch render (scale 3 by default) → PNG-signature validation → dedup into `sharedAssetsDir`.
- Tagged row that errors → automatically promoted to fallback path; final row reports `exporter: "fallback"` with both reasons.
- Lottie rows pass through with `status: "done"` and no PNG.
- `skipIfExistsInCatalog` defaults to true, so re-runs are cheap.

**Persist the response** as the manifest. Write the response (plus any extra metadata you carry — display size, rendering mode, etc.) to `.figma-cache/<nodeId>/manifest.json`. Do NOT add a second source of truth for asset state.

Example manifest after merge with display info:

```json
{
  "fileKey": "abc",
  "nodeId":  "3166:70147",
  "phaseA": "done",
  "phaseB": "done",
  "assetCatalogPath": "/Users/me/Project/App/Assets.xcassets",
  "rows": [
    {
      "nodeId": "3166:70211",
      "exporter": "tagged",
      "strategy": "atomic",
      "status": "done",
      "exportName": "icAIClose",
      "outputPath": ".figma-cache/3166:70147/assets/_mcpfigma/icAIClose@3x.png",
      "imagesetPath": "/Users/me/Project/App/Assets.xcassets/Welcome/icAIClose.imageset",
      "xcassetsImported": true,
      "displaySize": "24x24",
      "renderingMode": "template"
    },
    {
      "nodeId": "3166:70200",
      "exporter": "fallback",
      "strategy": "flatten",
      "status": "done",
      "friendlyName": "heroArtwork",
      "sharedPath": ".figma-cache/_shared/assets/3166_70200.png",
      "displaySize": "fill x 240",
      "renderingMode": "original"
    },
    {
      "nodeId": "3166:71000",
      "exporter": "fallback",
      "strategy": "lottiePlaceholder",
      "status": "done",
      "friendlyName": "placeholder_animation",
      "displaySize": "120x120"
    }
  ],
  "warnings": []
}
```

Key notes:
- `xcassetsImported: true` on a row → C4 must NOT re-run sips/imageset/Contents.json for that asset.
- Each `nodeId` appears exactly once — auto-promotion happens inside the tool, the row just reports its final `exporter` value.
- A row with `status: "failed"` → tell the user the `reason`, do not silently drop. Re-run after fixing the cause.

### Gate B — Phase B Exit (BASH, mandatory and STRICT)

You MUST run this. If it does not print `GATE: PASS`, you may NOT write any `.swift` file. Improvising assets is a hard violation.

```bash
CACHE=".figma-cache/<nodeId>"
FAIL=0
[ -s "$CACHE/manifest.json" ] && echo "PASS: manifest" || { echo "FAIL: manifest"; FAIL=1; }

# No row may be in failed status
FAILED=$(python3 -c "
import json
m = json.load(open('$CACHE/manifest.json'))
for r in m.get('rows', []):
    if r.get('status') == 'failed':
        print(r.get('nodeId'), '-', r.get('reason') or '?')
")
[ -z "$FAILED" ] && echo "PASS: no failed rows" || { echo "FAIL: failed rows:"; echo \"$FAILED\"; FAIL=1; }

# Coverage: registry tagged + lottie must all appear in manifest rows
UNCOVERED=$(python3 -c "
import json
reg = json.load(open('$CACHE/registry.json'))
needed = {a['nodeId'] for a in reg.get('taggedAssets', [])}
needed |= {p['nodeId'] for p in reg.get('lottiePlaceholders', [])}
present = {r.get('nodeId') for r in json.load(open('$CACHE/manifest.json')).get('rows', [])}
for nid in sorted(needed - present):
    print('UNCOVERED:', nid)
")
[ -z "$UNCOVERED" ] && echo "PASS: registry coverage" || { echo "FAIL: $UNCOVERED"; FAIL=1; }

# Coverage: visual hints in design-context demand at least 1 row when present
ROW_COUNT=$(python3 -c "import json; print(len(json.load(open('$CACHE/manifest.json')).get('rows',[])))")
ICON_HINTS=$(grep -ciE 'icon|logo|illustration|<img|<svg|VECTOR|BOOLEAN_OPERATION' "$CACHE/design-context.md" "$CACHE/metadata.json" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
if [ "${ROW_COUNT:-0}" -eq 0 ] && [ "${ICON_HINTS:-0}" -gt 0 ]; then
  echo "FAIL: rows empty but design has $ICON_HINTS hints — re-run Step B1 inventory"; FAIL=1
else
  echo "PASS: rows ($ROW_COUNT entries)"
fi

# Files on disk for every non-Lottie row
MISSING=$(python3 -c "
import json, os
m = json.load(open('$CACHE/manifest.json'))
for r in m.get('rows', []):
    if r.get('strategy') == 'lottiePlaceholder': continue
    paths = [r.get('outputPath',''), r.get('sharedPath','')]
    if not any(p and os.path.exists(p) for p in paths):
        print('MISSING:', r.get('exportName') or r.get('friendlyName') or r.get('nodeId'))
")
[ -z "$MISSING" ] && echo "PASS: all assets on disk" || { echo "FAIL: $MISSING"; FAIL=1; }

# Imageset check for tagged rows
BAD_IMAGESET=$(python3 -c "
import json, os
m = json.load(open('$CACHE/manifest.json'))
for r in m.get('rows', []):
    if r.get('xcassetsImported') and not os.path.isdir(r.get('imagesetPath','')):
        print('MISSING_IMAGESET:', r.get('exportName'))
")
[ -z "$BAD_IMAGESET" ] && echo "PASS: imagesets on disk" || { echo "FAIL: $BAD_IMAGESET"; FAIL=1; }

# All cached files have real PNG signatures
BAD=$(file "$CACHE/assets/"*.png \
           "$CACHE"/_shared/assets/*.png \
           "$CACHE"/assets/_mcpfigma/*.png \
           2>/dev/null | grep -v "PNG image data" | grep -v "cannot open")
[ -z "$BAD" ] && echo "PASS: assets are real PNG" || { echo "FAIL: non-PNG: $BAD"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase B)" || echo "GATE: FAIL (Phase B) — DO NOT WRITE SWIFT FILES"
```

If `GATE: FAIL`: fix the cause (most often: missed inventory rows or a row whose `status: failed` reason explains the failure). Do NOT begin Phase C until this prints `GATE: PASS`.

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
- **Token usage.** `tokens.json` (from `figma_extract_tokens` in A3) already has `swiftName`, `lightHex`, `darkHex`, `isCapsule`. Use those directly — do NOT re-derive names from Figma slash strings. Then merge with project enums (`Spacing`, `IKFont`, `IKCoreApp`) per the routing rules below: prefer existing enum case → fallback to extracted token → inline literal as last resort.
- `Text` → `LocalizedStringKey`; `Text(verbatim:)` for dynamic data.
- `Color(hex:)` only if project has the extension; else Asset Catalog or `Color(red:green:blue:)`.
- Respect iOS deployment target — don't use iOS 17+ APIs if target lower.
- Don't draw iOS system chrome (status bar, Dynamic Island, home indicator, system keyboard, system nav back, system `TabView` bar, pull-to-refresh). See the **ABSOLUTE RULE — Do NOT draw iOS system chrome** section near the top.
- **Use Figma assets only.** Every `Image(...)` must reference an asset downloaded in Phase B. `Image(systemName:)` is BANNED for Figma-designed icons. Drawing logos from `Text("G")` or colored `Rectangle()` is BANNED. If an asset is missing, STOP and re-run Phase B, never improvise.
- **Lottie placeholders.** For every manifest row with `strategy: "lottiePlaceholder"`, emit a `LottieView` stub in place of an asset, using the `lottie-ios` (Airbnb) SwiftUI API. Do NOT substitute with `Image(systemName:)`, do NOT draw a static frame from the children of the `eAnim*` node. See `references/lottie-placeholders.md` §6 for the exact code template. Add `import Lottie` once per file. The placeholder name is always the literal `"placeholder_animation"` — do not derive from the Figma name. Append a `// TODO:` comment instructing the developer to replace the name.
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

For each row in `manifest.rows`, branch on `exporter`:

**`exporter == "tagged"`:**
- The `.imageset` is already inside `Assets.xcassets` (tool did this in B3). Verify `imagesetPath` exists and contains at least one `*@2x.png` and one `*@3x.png`. **No sips, no Contents.json work.**
- Rendering mode is decided at the SwiftUI **call site** — the tool does not write `template-rendering-intent`.

**`exporter == "fallback"`** (and `strategy != "lottiePlaceholder"`):
1. Rendering mode: single-color icon → template; else original (see `references/asset-handling.md` §4)
2. `sips` → @1x/@2x/@3x from 3× source (`sharedPath`)
3. `.imageset` + Contents.json: universal idiom; `template-rendering-intent` for tinted; `appearances` for dark variants
4. Copy to `Assets.xcassets` (use the catalog pinned in B0)

**Lottie placeholder rows** are skipped here — codegen lives in C2.

**SwiftUI call-site rules (both paths):**
- `Image("<exportName>")` for tagged rows; `Image("<friendlyName>")` for fallback rows. The manifest is the single source of truth.
- Always `.resizable()` + explicit `.frame(width:height:)`.
- Single-color icon (`renderingMode == "template"` in manifest):
  - tagged rows → `.renderingMode(.template)` + `.foregroundStyle(...)` at the call site.
  - fallback rows → may rely on `template-rendering-intent` in Contents.json, OR explicit `.renderingMode(.template)` — both work.
- Multi-color / illustration / brand: no `.renderingMode` modifier. Patterns in `references/asset-handling.md` §7.

**Verification (BASH, mandatory):**

```bash
SWIFT_FILES="<your-generated-swift-files>"

# (a) Every Image("...") in generated views must appear in manifest as exportName or friendlyName.
NAMES=$(python3 -c "
import json
m = json.load(open('.figma-cache/<nodeId>/manifest.json'))
for r in m.get('rows', []):
    if r.get('strategy') == 'lottiePlaceholder':
        continue
    print(r.get('exportName') or r.get('friendlyName'))
")
USED=$(grep -hoE 'Image\("[^"]+"\)' $SWIFT_FILES | sed -E 's/Image\("([^"]+)"\)/\1/')
for h in $USED; do
  echo "$NAMES" | grep -qx "$h" || echo "ORPHAN: Image(\"$h\") not in manifest"
done

# (b) Every lottie-placeholder row must have a matching LottieView call.
PLACEHOLDER_COUNT=$(python3 -c "
import json
m = json.load(open('.figma-cache/<nodeId>/manifest.json'))
print(sum(1 for r in m.get('rows', []) if r.get('strategy') == 'lottiePlaceholder'))
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

### Step C5 — Visual Validate (mandatory)

After C3 finishes (Pass 2 clean report, Pass 3/3b grep clean, C4 assets copied), **RUN C5. Do not prompt.** This catches what Pass 2 cannot see: real font rendering, shadow at simulator DPI, safe-area on chosen device, keyboard avoidance, animation start state.

**Skip only when one of these system reasons applies** (auto-detected, persisted in `manifest.verification.c5.skipped`; user phrases cannot override):
- `no_project` — no `.xcodeproj` / `.xcworkspace` after walking up 3 levels.
- `simctl_error` — `xcrun simctl` errors (no simulator runtime, Xcode CLT missing, etc.).
- `ci_environment` — `CI=true` or `GITHUB_ACTIONS=true` env var present (no GUI simulator in CI).

User phrases like `skip C5`, `bỏ qua C5`, `no build`, `không cần build` are NOT honored — the agent must explain the Done-Gate (Key Principle #12) and proceed with C5 anyway. The only legitimate way to bypass is one of the three system reasons above.

Run the 6 sub-steps (commands + edge cases in `references/verification-loop.md` §5):

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

- **MCPFigma not configured.** A2's `figma_build_registry` call returns an error; surface to user, ask them to install/configure per `references/mcpfigma-setup.md`. No silent fallback — the registry is mandatory.
- **`FIGMA_ACCESS_TOKEN` missing or invalid.** Same — both `figma_build_registry` and the unified export need it. Token error message is server-side; relay it verbatim to the user.
- **Designer tagged a node but the name is invalid** (warning row in `registry.warnings`). The node is NOT in `taggedAssets[]` — it lands in B1 inventory as a fallback row. Either re-tag in Figma (`eIC<UpperCamel>`) or accept the fallback.
- **Designer tags `eImageHero` containing nested interactive UI.** Trust the prefix by default — keep the tagged row even though the visual region looks like FLATTEN. Result is a flat raster of the whole region, fine for a hero. Override only when user explicitly says "treat eImageHero as decompose" — set `exporter = "fallback"` on that row, mark FLATTEN.
- **Project has multiple `.xcassets`.** B0 prompts for `assetCatalogPath` and stashes it in the manifest. The unified tool requires the explicit path — it does not auto-resolve from a project root.
- **Tool returns non-PNG for a fallback row.** Tool already validates PNG signature and marks the row `failed` with reason `"Output không phải PNG..."`. Surface to user — typically means designer used SVG-only for that node; ask them to flatten in Figma.
- **Light/dark variants.** Tagged path exports each node as one imageset (no `appearances`). To support light/dark, designer ships two nodes (`eICLogo` + `eICLogoDark`); app picks at `colorScheme`. Merging both into one imageset (with `appearances`) is only available on the fallback path's manual import — see `references/asset-handling.md` §5 "light + dark variants".
- **Same `exportName` from two different source nodeIds.** Tool adds `_2` suffix and emits a warning in `summary.warnings`. Surface to user — SwiftUI call site needs to know which is which.
- **Phase B re-run after partial success.** Tool is idempotent (`overwrite=true`, `skipIfExistsInCatalog=true` defaults). On re-run, only still-failing nodes are re-attempted; successful rows are no-op overwrites. Inspect manifest `rows[].status` before re-running — `done` rows can be skipped entirely if their files still exist on disk.
- **Lottie placeholder (`eAnim*`) — Lottie SDK missing.** C1 project pre-flight should detect whether `lottie-ios` is in dependencies. If not, surface before C2: *"Lottie SDK not detected — add `lottie-ios` (Airbnb) via SPM or CocoaPods, or convert these placeholders to static images."* Do NOT auto-install; do NOT silently swap in `Image(systemName:)`. See `references/lottie-placeholders.md` §9.
- **Lottie placeholder inside a flatten region.** The flattened parent exports as a static raster (animation is frozen in one frame). The placeholder `LottieView` overlays on top in `ZStack`. Tell the user the artwork would be cleaner if the designer pulled the `eAnim*` node out of the flatten region.
- **Custom Lottie wrapper in project.** If C1 audit finds `IKLottieView`/`AnimatedView`/etc., prefer the wrapper at C2 codegen. The placeholder name string `"placeholder_animation"` stays unchanged.
- **Variables API not available** (Figma file is not on a plan that exposes Variables, or token has no scope). `figma_extract_tokens` returns empty arrays + a `warnings[]` entry. Skill falls back to reading inline tokens from `design-context.md` per `references/design-token-mapping.md` General Rules.

## Strongly recommended hooks (hard enforcement)

These hooks turn the in-skill gates into OS-level enforcement. Without them, gates rely on the agent honoring them; with them, the tool call is denied at the harness layer.

1. **PreToolUse hook — block `Write`/`Edit` on `*.swift` when assets missing.** Triggers when `.figma-cache/<nodeId>/manifest.json` is missing or has empty `rows`. Forces Phase B to complete before any SwiftUI is written.

2. **PostToolUse hook — auto-run Gate C3-Pass2 on `c3-pass2-diff.md` write.** Saves one round-trip per attempt and surfaces structural bugs immediately.

3. **Stop hook — block session termination when C5 not satisfied.** Reads `manifest.verification.c5`. Allows stop only when `gate == "PASS"` OR `skipped` is set to one of `no_project`, `simctl_error`, `ci_environment`. Otherwise prints to the agent: *"Done-Gate violated (Key Principle #12). Run C5 or set a system skip reason before declaring done."* This is the OS-level twin of Principle #12 and the strongest fix for "agent says done but C5 was never run".

Ask the assistant to set them up via the `update-config` skill.

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
12. **Done-Gate.** A task is NOT complete until either `manifest.verification.c5.gate == "PASS"` OR `manifest.verification.c5.skipped` is set to one of `no_project`, `simctl_error`, `ci_environment`. Stating "done" / "implemented" / "xong" / "ship it" without one of these is a protocol violation. The agent MUST surface the C5 status (PASS, FAIL, or SKIPPED with reason) in its final user-facing message — see the **Verification summary** template below.

## Verification summary (mandatory final block)

At the end of every run — success or failure — print this block to the user verbatim, filling in values from the artifacts on disk. The user uses this to verify the agent without re-reading the entire transcript.

```
Verification summary
- C3 Pass 2 (offline diff):    PASS / FAIL (high: N, medium: N)
- C3 Pass 3 (asset grep):      PASS / FAIL
- C3 Pass 3b (chrome grep):    PASS / FAIL
- C3 Pass 4 (swiftui-pro):     PASS / FAIL
- C5 (build + simulator):      PASS / FAIL / SKIPPED (<reason>)
- C5.6 (15-check visual diff): PASS / FAIL (high: N, medium: N)
Artifacts:
  .figma-cache/<nodeId>/c3-pass2-diff.md
  .figma-cache/<nodeId>/c5-build.log
  .figma-cache/<nodeId>/c5-simulator.png
  .figma-cache/<nodeId>/c5-visual-diff.md
```

Omit any row that genuinely does not apply (e.g. C5.6 if C5 was skipped). Never fabricate a PASS — open the file with `cat` if uncertain.
