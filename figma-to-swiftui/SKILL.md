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

**This is the phase agents skip. Don't.** Goal: every visible icon/logo/illustration/image from the screenshot exists as a validated PNG on disk.

The default asset downloader is `get_screenshot(fileKey, nodeId)`. **No token required.** It works per-node and returns PNG. Use it for every atomic icon and every flatten region. There is no excuse to skip this phase.

### Step B1 — Inventory (visual-first)

Open `screenshot.png` and **list every visible non-text element**. Cross-reference three sources:
1. Visual scan of `screenshot.png` (ground truth — start here)
2. `design-context.md`: `<img>` URLs, inline `<svg>`, `imageRef`, `background-image`
3. `metadata.json`: nodes of type `VECTOR`, `BOOLEAN_OPERATION`, `INSTANCE`; names with `icon`, `ic_`, `logo`, `illustration`

Build the inventory table:

| # | Purpose | NodeId | Strategy | Filename |
|---|---|---|---|---|
| 1 | Close icon | 3166:70211 | atomic | iconClose.png |
| 2 | Hero illustration | 3166:70200 | flatten | heroArtwork.png |
| 3 | Facebook logo | 3166:70250 | atomic | logoFacebook.png |

**Hard rules:**
- Every visible non-text element → one row.
- A visible icon you cannot find a nodeId for → **STOP, ask the user**, do not skip.
- Empty inventory on a screen that visibly has icons/logos → bug, re-scan.

### Step B2 — Classify (flatten / decompose / code)

Per region:
- **FLATTEN** (`get_screenshot` on the region → one PNG): composed artwork, layered scene, artistic effects, static content.
- **DECOMPOSE** (atomic icons + SwiftUI compose): icon rows, grids, interactive/dynamic content. Each atom → its own row.
- **CODE** (SwiftUI shapes): only for trivial primitives — rect, circle, gradient, blur material. **Not for icons.** "It looks like a circle with a line" is still an icon — download it.
- **MIXED**: flatten artwork sub-frame, overlay interactive UI in ZStack.

Heuristic: "the hero illustration" (1 thing) → flatten; "a row of action icons" (N things) → decompose. **Doubt → flatten.** Never reassemble composed artwork with `.offset()`. Rules: `references/asset-handling.md` §1a.

### Step B3 — Download (default path: MCP `get_screenshot`)

For every row in the inventory:

```
get_screenshot(fileKey=<fileKey>, nodeId=<nodeId>)  →  save to .figma-cache/<nodeId>/assets/<friendlyName>.png
```

This is the default. **No FIGMA_TOKEN needed.** Run in parallel batches.

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
  "fileKey": "abc", "nodeId": "3166:70147", "fetchedAt": "...",
  "phaseA": "done", "phaseB": "done",
  "assetList": [
    { "sourceNodeId": "3166:70200", "sharedPath": "_shared/assets/3166_70200.png", "friendlyName": "heroArtwork", "strategy": "flatten", "displaySize": "fill x 240", "renderingMode": "original", "status": "done" }
  ]
}
```

Failed downloads: mark `failed`, retry once, then tell user. Never silently drop a row.

### Gate B — Phase B Exit (BASH, mandatory and STRICT)

You MUST run this. If it does not print `GATE: PASS`, you may NOT write any `.swift` file. Improvising assets is a hard violation.

```bash
CACHE=".figma-cache/<nodeId>"
FAIL=0
[ -s "$CACHE/manifest.json" ] && echo "PASS: manifest" || { echo "FAIL: manifest"; FAIL=1; }

# Asset coverage: assetList must not be empty if the design has any icon hints
ASSET_COUNT=$(python3 -c "import json; print(len(json.load(open('$CACHE/manifest.json')).get('assetList',[])))" 2>/dev/null)
ICON_HINTS=$(grep -ciE 'icon|logo|illustration|<img|<svg|VECTOR|BOOLEAN_OPERATION' "$CACHE/design-context.md" "$CACHE/metadata.json" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
if [ "${ASSET_COUNT:-0}" -eq 0 ] && [ "${ICON_HINTS:-0}" -gt 0 ]; then
  echo "FAIL: assetList empty but design has $ICON_HINTS icon/image hints — re-run Step B1 inventory and B3 download"; FAIL=1
else
  echo "PASS: assetList coverage ($ASSET_COUNT entries)"
fi

# Every asset row → file on disk, every file → PNG
MISSING=$(python3 -c "
import json, os
m = json.load(open('$CACHE/manifest.json'))
for a in m.get('assetList', []):
    paths = [a.get('sharedPath',''), '$CACHE/assets/'+a.get('friendlyName','')+'.png']
    if not any(p and os.path.exists(p) for p in paths):
        print('MISSING:', a.get('friendlyName','?'))
")
[ -z "$MISSING" ] && echo "PASS: all assets on disk" || { echo "FAIL: $MISSING"; FAIL=1; }

BAD=$(file "$CACHE/assets/"*.png "$CACHE"/_shared/assets/*.png 2>/dev/null | grep -v "PNG image data" | grep -v "cannot open")
[ -z "$BAD" ] && echo "PASS: assets are real PNG" || { echo "FAIL: non-PNG: $BAD"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase B)" || echo "GATE: FAIL (Phase B) — DO NOT WRITE SWIFT FILES"
```

If `GATE: FAIL`: fix the cause (most often: missed inventory rows or wrong nodeId). Do NOT begin Phase C until this prints `GATE: PASS`.

---

# Phase C — Implement (offline from cache)

Goal: SwiftUI code that matches the screenshot pixel-for-pixel, using only assets from Phase B.

### Step C1 — Audit & Prepare

**Project pre-flight** (see `references/visual-fidelity.md` §6):
1. iOS deployment target → which SwiftUI APIs available
2. `Color(hex:)` extension — grep; if absent, use Asset Catalog / `Color(red:green:blue:)`
3. Localization — check `.strings`/`.xcstrings`; use `LocalizedStringKey`
4. Dark mode scope — if Figma light-only, ask user

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

**Translation references:**
- `references/visual-fidelity.md` — **read first, always**
- `references/layout-translation.md` — Auto Layout, stacks, sizing, effects, animations
- `references/design-token-mapping.md` — typography, colors, gradients, opacity
- `references/component-variants.md` — state/size/style
- `references/responsive-layout.md` — size classes, iPhone+iPad

### Step C3 — Self-Check (mandatory, three passes)

**Pass 1 — Code vs Inventory.** For each inventory row, verify code matches exactly. Fix every ✗.

**Pass 2 — Code vs Screenshot.** Open `screenshot.png`, walk code top-down. Verify: lineHeight, tracking, shadow (color+opacity+offset+radius), border, opacity layers, renderingMode, icon exact size, divider, background material, gradient direction/stops, safe-area, `buttonStyle(.plain)`, no default SwiftUI padding.

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

Anything in code not traceable to inventory → guess → fix. Never "tweak until it looks right".

### Step C4 — Copy Assets to Project

1. Rendering mode: single-color icon → template; else original (see `references/asset-handling.md` §4)
2. `sips` → @1x/@2x/@3x from 3× source
3. `.imageset` + Contents.json: universal idiom; `template-rendering-intent` for tinted; `appearances` for dark variants
4. Copy to `Assets.xcassets` (ask if multiple catalogs)
5. Use in SwiftUI: `.resizable()` + explicit `.frame` + `.renderingMode` + `.foregroundStyle` (templates). Patterns in `references/asset-handling.md` §7
6. Verify in Xcode — no "image not found"

### Step C5 — Validate (on user request only)
Ask how user wants to validate. If no preference, skip.

### Step C6 — Register Code Connect (optional)
If (and only if) your Figma MCP exposes a register/add Code Connect tool, call it for new reusable components.

---

## Resume & Retry

Check manifest. `phaseA` and `phaseB` both `done` → skip to Phase C. Some `failed` → retry those only. Cache > 24h → suggest re-fetch. User phrases: "tiếp tục fetch" (resume from last incomplete phase), "implement from cache" (skip to Phase C, but Gate B must still pass).

## Recommended hook (hard enforcement)

To make Phase B genuinely un-skippable, add a `PreToolUse` hook in `.claude/settings.json` that blocks `Write`/`Edit` on `*.swift` files when `.figma-cache/<nodeId>/manifest.json` is missing or has empty `assetList`. Without the hook, gates rely on the agent honoring them; with the hook, the OS-level tool call is denied. Ask the assistant to set this up via the `update-config` skill if you want it.

## Key Principles

1. **Three phases, three gates, no skipping.** Phase A → Gate A. Phase B → Gate B. Phase C self-check. Each gate prints `GATE: PASS` or you do not proceed.
2. **All assets from Figma — no exceptions.** SF Symbols, colored shapes, `Text("G")` logos, "simplified" illustrations are BANNED. Missing asset → stop and re-fetch, never improvise.
3. **Fidelity is the goal.** Pixel-for-pixel — spacing, color, font, lineHeight, tracking, shadow, border, opacity, gradient. Approximation is a bug.
4. **MCP output is a spec.** Parse values per `references/visual-fidelity.md` §1. Never port React/Tailwind to SwiftUI.
5. **Every value must be traceable.** Trace to tokens, inline style, class, or design-context comment. Untraceable = guessed.
6. **Visual Inventory first, every Phase C.** Never skip lineHeight/tracking/shadow/border/renderingMode.
7. **Self-check three passes.** Code vs inventory, code vs screenshot, bash grep for `Image(systemName:`.
8. **Beware SwiftUI defaults.** Always specify `.font(.system(size:))`, `VStack(spacing:)`, `.padding(X)`, `.buttonStyle(.plain)` for custom buttons.
9. **Flatten composed artwork.** Don't reassemble atoms via `.offset()`. When in doubt → flatten.
10. **`get_screenshot(nodeId)` is the default asset downloader.** No token, no excuse to skip.
