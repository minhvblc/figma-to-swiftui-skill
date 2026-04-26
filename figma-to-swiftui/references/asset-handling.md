# Asset Handling for iOS/SwiftUI

End-to-end workflow for turning Figma assets into Asset Catalog entries and using them correctly in SwiftUI. Optimized for pixel-match fidelity with the Figma design.

---

## 1a. Decide: flatten, decompose, or code?

**This is the most important decision in asset handling.** Get it wrong and the UI drifts pixel-by-pixel from Figma even when every atomic piece is correct.

For each major visual region of a screen, pick one of three strategies:

### Flatten — export the whole region as ONE PNG

Use `get_screenshot(fileKey, regionNodeId)` to render the entire region as a flattened PNG. Use this when the region:

- Is **non-interactive** (no buttons, inputs, tappable sub-elements inside)
- Has **composed artwork** — 3+ overlapping visual layers (background + illustration + decorative shapes + effects)
- Uses effects SwiftUI can't cleanly reproduce (complex masks, blend modes, inner shadows stacked on gradients, patterned fills, noise, grain)
- Is **designer-authored as a unit** (a hero banner, onboarding illustration, promo card artwork, empty-state scene)
- Has **static content** — no text that changes at runtime, no localized strings, no data-driven visuals

**Examples:** onboarding hero illustration, empty-state scene, splash artwork, promo card background with decorations, branded section header, full-width banner with illustration + gradient + overlay shapes.

### Decompose — download atomic pieces, build layout in SwiftUI

Download individual icons/images and compose them with SwiftUI stacks. Use when the region:

- Has **interactive children** (buttons, toggles, inputs, navigation)
- Contains **dynamic text** (titles that change, localized labels, user-entered content)
- Has elements that need **independent animation or state** (selected cell, pressed button, loading spinner)
- Is a **reusable component pattern** used across the app (list row, form field, card template)

**Examples:** list rows, form sections, tab bars, navigation headers, button groups, card grids with tappable cards.

### Code — no download, pure SwiftUI

Draw with SwiftUI shapes and modifiers. Use when the region is:

- A **trivial geometric shape** — rounded rect, circle, divider line, dot indicator
- A **solid or gradient background** with no artwork layered on top
- A **blur/material background** — use `.background(.ultraThinMaterial)` etc.
- A **shape used as UI affordance** — button background, badge circle, card container

### Mixed regions — flatten the artwork, overlay the UI

When a region has both composed artwork AND interactive/dynamic elements, split the layers:

- **Flatten the decorative layers** (bg, illustration, decorations) into ONE PNG — export via `get_screenshot` on a sub-frame that contains only artwork layers, OR ask the designer to provide a dedicated "artwork only" frame
- **Overlay the interactive/dynamic UI in SwiftUI** — buttons, text, inputs on top with `ZStack` + alignment

Example — onboarding screen with hero illustration + title + CTA:

```swift
ZStack(alignment: .bottom) {
    Image("onboardingHeroArtwork")           // flattened illustration + bg
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)

    VStack(alignment: .leading, spacing: 12) {
        Text("Welcome to the app")           // dynamic, localizable
            .font(.headingLarge)
        Text("Start in less than a minute")
            .font(.bodyRegular)
            .foregroundStyle(Color.textSecondary)
        Button("Get started") { ... }        // interactive
            .buttonStyle(PrimaryButtonStyle())
    }
    .padding(24)
    .background(.ultraThinMaterial)          // if Figma shows blur behind text
}
```

### Visual inspection rule (primary signal — use the screenshot)

**Open `screenshot.png` and actually look at the region before deciding.** The model has vision — use it. Trust the screenshot over JSX heuristics.

For each candidate region, ask:

| Question | If yes → |
|---|---|
| Does it look like a **painting, illustration, or composed scene** (characters, decorative backgrounds, artistic framing)? | FLATTEN |
| Does it have a **unique visual identity** that isn't repeated elsewhere in the app (hero artwork, onboarding illustration, empty-state scene)? | FLATTEN |
| Are there **overlapping decorative elements** (gradient blobs, floating particles, confetti, glows, highlights) that together form a single visual unit? | FLATTEN |
| Does it have **artistic effects** visible in the image (hand-drawn shading, soft blurs, grain, layered transparency)? | FLATTEN |
| Does it look like a **functional row of similar icons** (tab bar, icon menu, social icon strip)? | DECOMPOSE |
| Are elements **uniform in size and style**, arranged in a grid or list, with labels? | DECOMPOSE |
| Do the elements look like **distinct UI affordances** (each tappable, each with a different purpose)? | DECOMPOSE |
| Is it a **trivial geometric shape** (divider line, circle indicator, rounded card background with nothing inside)? | CODE |

**Quick heuristic:** would a designer describe this as "the hero illustration" (1 thing) or "a row of action icons" (N things)? The first → flatten. The second → decompose.

**If the visual answer conflicts with the JSX signals, the visual answer wins.** JSX can be structured as many sub-layers for designer convenience even when the output is a single visual unit.

### Supporting signals in design-context.md

These reinforce the visual decision (but don't override it):

- Region's JSX has 3+ nested divs with `position: absolute` or `transform`
- Multiple stacked `background-image` or `background` layers
- CSS `mask`, `mix-blend-mode`, `filter`, `backdrop-filter`
- Many SVG `<path>` elements with complex fills or gradients
- Design-context for the region is >150 lines of JSX (too complex to reproduce)
- Inline comment like `// Illustration`, `// Artwork`, `// Background`
- Node name in Figma contains "Illustration", "Artwork", "Hero", "Banner", "Background", "Decoration"

### Anti-pattern to avoid

Downloading 5 small icons from a composed illustration and stacking them with `.offset(x:, y:)` in a ZStack. This:
- Drifts on different screen sizes
- Misses shadow/blur/blend layers the designer applied
- Breaks when tokens change
- Produces a flat, incorrect version of a rich design

**When in doubt: flatten.** It's easier to flatten first and decompose later if a reusable piece emerges, than to rebuild a composition pixel-by-pixel.

---

## 1b. Decide: download or code? (for atomic pieces)

Once you've decided what to flatten, for every remaining atomic element decide: download or code?

| Element | Handling |
|---|---|
| Icon (any — chevron, close, menu, custom) | **Download as PNG** |
| Logo, brand mark | **Download as PNG** |
| Illustration, onboarding graphic | **Download as PNG** |
| Photograph (static) | **Download as PNG or JPG** |
| User-generated image (feeds, avatars) | **Remote load** — do not bundle |
| Pure geometric shape used as UI (rounded card, divider line, circle placeholder, gradient bg) | **Code** — SwiftUI `RoundedRectangle`, `Circle`, `LinearGradient`, etc. |
| Background gradient, blur material | **Code** — `LinearGradient`, `.background(.ultraThinMaterial)` |
| A shape that happens to be simple (e.g. a red circle badge) but is drawn in Figma | **Code** — no asset needed |

**Rule of thumb:** if it's vector/geometric and trivial to reproduce in SwiftUI (1-2 shapes), code it. If it's raster, has multiple paths, uses effects Figma can't trivially describe, or is a brand asset — download.

**Never substitute with SF Symbols.** If Figma has a chevron icon, download that chevron — don't swap in `Image(systemName: "chevron.right")` unless the user explicitly asks.

---

## 2. Determine sizing from Figma

Before downloading, know two sizes for each asset:
- **Export size** (pixel dimensions of the PNG file): always 3× the display size
- **Display size** (point size used in SwiftUI frame): read from the Figma frame containing the icon/image

Example:
- Figma icon sits in a 24×24pt frame → export at 72×72px (3×) → SwiftUI `.frame(width: 24, height: 24)`
- Figma hero illustration is 343×200pt → export at 1029×600px → SwiftUI `.frame(maxWidth: .infinity, maxHeight: 200)` with `.aspectRatio(contentMode: .fill)`

If the asset appears at multiple sizes in the design (e.g. 16pt in a list, 24pt in a header), it's the same asset — one Asset Catalog entry, different `.frame` sizes at call sites. The asset catalog handles `@1x/@2x/@3x` automatically.

---

## 3. Download the asset

**Priority order:**

1. **Figma REST API** (preferred when `FIGMA_TOKEN` is available) — batch download, fastest, uses Figma's server-side renderer
2. **MCP `get_screenshot`** — per-node fallback, same renderer as REST, works without token
3. **MCP `download_figma_images`** — only for raster image fills with `imageRef` (photos, uploaded assets) — returns SVG for vector icons even with `.png` extension, not a format converter

Never try to convert SVG → PNG locally (rsvg-convert, inkscape, ImageMagick) — rendering drifts from Figma. Always use one of the 3 methods above.

### Primary: Figma REST API (batch, fast)

When `FIGMA_TOKEN` is available (env var, 1Password, user-provided), use the REST API as the default. It batches many node IDs into one call and returns PNG URLs rendered by Figma's own server.

**Check token first:**
```bash
if [ -n "$FIGMA_TOKEN" ]; then echo "token available"; else echo "fallback to MCP"; fi
```

**Batch call:**
```bash
# Collect all icon/image nodeIds from the Inventory (Step 3.0) — comma-separated
IDS="3166:70200,3166:70211,3166:70215,3166:70222"

curl -s -H "X-Figma-Token: $FIGMA_TOKEN" \
  "https://api.figma.com/v1/images/$FILE_KEY?ids=$IDS&format=png&scale=3" \
  > .figma-cache/<nodeId>/rest-images.json
```

**Response format:**
```json
{
  "err": null,
  "images": {
    "3166:70200": "https://s3-alpha-sig.figma.com/img/.../hero.png",
    "3166:70211": "https://s3-alpha-sig.figma.com/img/.../close.png",
    "3166:70215": null
  }
}
```

**Download each URL immediately** (S3 URLs are signed and expire):
```bash
# For each nodeId → url pair, map to the filename in the Inventory table
curl -s -o .figma-cache/<nodeId>/assets/heroArtwork.png \
  "https://s3-alpha-sig.figma.com/img/.../hero.png"

# Validate
file .figma-cache/<nodeId>/assets/heroArtwork.png
# Must output: "PNG image data"
```

**Error handling (fall through to MCP for any failure):**
- `err` field non-null in response → full call failed → fallback to MCP for all nodes
- `images[nodeId]` is `null` → Figma couldn't render that specific node → fallback to MCP `get_screenshot(fileKey, nodeId)` for that one
- HTTP 403 / "Invalid token" → token is bad → notify user, fallback to MCP
- HTTP 429 (rate limit) → wait 30s, retry once; if still fails, fallback to MCP

**Rate limit:** Figma allows ~300 req/min per IP. One batch call covers many icons, so this rarely trips.

**Scale parameter:** `scale=3` gives you the @3x asset. Generate @2x/@1x with `sips` afterwards. Supported: 1, 2, 3, 4.

### Fallback 1: MCP `get_screenshot` (per-node)

When `FIGMA_TOKEN` is missing, or REST API returned a null URL for a specific node, or REST failed with a rate limit:

```
get_screenshot(fileKey, nodeId)
→ saves PNG to the localPath you specify
```

- Works for any node type
- Always returns PNG (Figma's renderer — same output as REST API for the same node)
- One call per node — slower than REST batch, but no token needed

### Fallback 2: MCP `download_figma_images` (raster fills only)

Only useful for nodes with `imageRef` (uploaded photos, raster brand assets):

```json
{
  "fileKey": "abc123",
  "localPath": ".figma-cache/<nodeId>/assets",
  "pngScale": 3,
  "nodes": [
    { "nodeId": "123:456", "fileName": "userAvatar.png", "imageRef": "abc..." }
  ]
}
```

Always validate after: `file assets/*.png` must output "PNG image data". If SVG/XML → discard, use `get_screenshot`.

### When `download_figma_images` is actually useful

For nodes with an `imageRef` fill (uploaded photos, raster brand assets) — Figma stores these as raster already, and `download_figma_images` returns the original PNG/JPG bytes at the requested scale:

```json
{
  "fileKey": "abc123",
  "localPath": ".figma-cache/3166:70147/assets",
  "pngScale": 3,
  "nodes": [
    { "nodeId": "123:456", "fileName": "user-avatar.png", "imageRef": "abc..." }
  ]
}
```

You can identify these in `design-context.md` by `imageRef` attributes in the JSX, or by inline CSS like `background-image: url(...)` pointing to a Figma asset ID.

**Always validate afterward:**

```bash
file .figma-cache/<nodeId>/assets/user-avatar.png
# Must output "PNG image data". If "SVG" or "XML" → discard, use get_screenshot instead.
```

### Curl from localhost URL (also prone to format drift)

`get_design_context` embeds localhost URLs for assets. These URLs also don't guarantee PNG content — validate the same way:

```bash
curl -o ".figma-cache/<nodeId>/assets/<name>_raw" "<localhost-url>"
ACTUAL=$(file -b ".figma-cache/<nodeId>/assets/<name>_raw")

if echo "$ACTUAL" | grep -qi "png"; then
  mv ".figma-cache/<nodeId>/assets/<name>_raw" ".figma-cache/<nodeId>/assets/<name>.png"
elif echo "$ACTUAL" | grep -qi "jpeg"; then
  sips -s format png ".figma-cache/<nodeId>/assets/<name>_raw" --out ".figma-cache/<nodeId>/assets/<name>.png" && rm ".figma-cache/<nodeId>/assets/<name>_raw"
else
  # SVG, XML, or unknown — discard, use get_screenshot
  rm ".figma-cache/<nodeId>/assets/<name>_raw"
fi
```

### Never try to convert SVG → PNG locally

If you do end up with an SVG file (from download_figma_images or curl), **discard it and call `get_screenshot`** on the same node. Do NOT:
- Use CLI tools like `rsvg-convert`, `inkscape`, ImageMagick `convert` to rasterize locally — they produce different rendering than Figma (stroke widths, text, effects drift)
- Bundle the SVG as-is — Xcode's SVG support is limited (no filters, blurs, masks, some gradients)
- Use `WebView` to render SVG — overkill and fragile

`get_screenshot` uses Figma's own renderer → the resulting PNG is pixel-identical to the Figma canvas.

### Decision flow

```
Collect nodeIds from Inventory (Step 3.0)
│
├── FIGMA_TOKEN available?
│   ├── YES → REST API batch call (primary)
│   │         GET /v1/images/:fileKey?ids=A,B,C&format=png&scale=3
│   │         ├── Full success → download URLs, validate PNG, done
│   │         ├── Partial (some nodes null) → fallback MCP get_screenshot for null ones
│   │         └── Full failure (err, 403, 429 after retry) → fallback to MCP for all
│   │
│   └── NO / missing → skip to MCP fallback
│
├── MCP get_screenshot(fileKey, nodeId) — per node
│   └── Works for any node, always PNG
│
└── MCP download_figma_images — ONLY for imageRef raster fills
    └── Must validate with `file`. If SVG/XML → use get_screenshot
```

---

## 4. Decide the rendering mode

Before adding to the Asset Catalog, decide:

| Asset | Rendering mode | Why |
|---|---|---|
| Single-color icon (1 fill, any hue) | **Template** | Tint via `.foregroundStyle` — adapts to light/dark, reusable across contexts |
| Multi-color icon with 2+ distinct fills | **Original** | Preserve Figma colors |
| Brand logo | **Original** | Preserve brand colors |
| Illustration, photo | **Original** | Preserve artwork |
| Icon with gradient fill | **Original** | Templates drop gradients |

**Detect from Figma:**
- Check the icon node in `design-context.md` or the screenshot. Count distinct fill colors.
- If Figma assigns a *color variable* to the fill (e.g. `fill: var(--icon-primary)`), it's meant to be tintable → **template**.
- If the icon appears in multiple foreground colors across screens, it's template.

**Where to set the rendering mode:**
- Prefer **Contents.json** (`"template-rendering-intent": "template"`) for icons that are always template. This lets any call site use `Image("x")` without modifiers.
- Apply **in code** (`.renderingMode(.template)`) only when the same asset is used sometimes as template, sometimes original.

---

## 5. Build the Asset Catalog entry

### Generate @1x, @2x, @3x with sips

Source is the 3× download:

```bash
cd .figma-cache/<nodeId>/assets
SOURCE="icon-close.png"          # 72x72px for a 24pt icon
BASE="icon-close"
cp "$SOURCE" "${BASE}@3x.png"
sips -Z 48 "$SOURCE" --out "${BASE}@2x.png" > /dev/null
sips -Z 24 "$SOURCE" --out "${BASE}@1x.png" > /dev/null
```

`-Z N` scales to fit within N×N pixels while preserving aspect ratio.

### Contents.json — standard imageset (universal)

```json
{
  "images": [
    { "filename": "icon-close@1x.png", "idiom": "universal", "scale": "1x" },
    { "filename": "icon-close@2x.png", "idiom": "universal", "scale": "2x" },
    { "filename": "icon-close@3x.png", "idiom": "universal", "scale": "3x" }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

### Contents.json — template-rendered icon

```json
{
  "images": [
    { "filename": "icon-close@1x.png", "idiom": "universal", "scale": "1x" },
    { "filename": "icon-close@2x.png", "idiom": "universal", "scale": "2x" },
    { "filename": "icon-close@3x.png", "idiom": "universal", "scale": "3x" }
  ],
  "info": { "author": "xcode", "version": 1 },
  "properties": { "template-rendering-intent": "template" }
}
```

### Contents.json — light + dark variants

When Figma has separate light/dark versions (common for logos, brand art):

```json
{
  "images": [
    { "filename": "brand@1x.png",      "idiom": "universal", "scale": "1x" },
    { "filename": "brand@2x.png",      "idiom": "universal", "scale": "2x" },
    { "filename": "brand@3x.png",      "idiom": "universal", "scale": "3x" },
    { "filename": "brand-dark@1x.png", "idiom": "universal", "scale": "1x",
      "appearances": [{ "appearance": "luminosity", "value": "dark" }] },
    { "filename": "brand-dark@2x.png", "idiom": "universal", "scale": "2x",
      "appearances": [{ "appearance": "luminosity", "value": "dark" }] },
    { "filename": "brand-dark@3x.png", "idiom": "universal", "scale": "3x",
      "appearances": [{ "appearance": "luminosity", "value": "dark" }] }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

For single-color icons, you rarely need dark variants — use template rendering mode and tint with a semantic color that adapts automatically.

---

## 6. Naming & deduplication

### Before creating a new entry — search for existing

1. Grep the project's Asset Catalog for matching names (case-insensitive, partial match)
2. Check nearby features for similar icons (a "close" icon likely already exists)
3. Compare visually — if pixel-match with an existing asset, reuse it
4. Only create new when nothing matches

### Naming

- Match the project's existing case style (camelCase or kebab-case — don't mix).
- **Global icons** (shared across many screens): no prefix. `close`, `chevronRight`, `search`, `heart`.
- **Screen-specific visuals** (illustrations tied to one feature): prefix with screen/feature name. `onboardingHero`, `checkoutSummaryIllustration`, `profileHeaderPlaceholder`.
- Purpose-based suffix when multiple variants exist: `heart`, `heartFilled`, `heartOutline`.
- No spaces, no special characters, no extensions in the catalog entry name.

---

## 7. Use the asset in SwiftUI

### Template icon with tint

```swift
Image("close")
    .resizable()
    .renderingMode(.template)              // omit if set in Contents.json
    .aspectRatio(contentMode: .fit)
    .frame(width: 24, height: 24)
    .foregroundStyle(Color.textPrimary)
```

### Original icon or small logo

```swift
Image("brandMark")
    .resizable()
    .scaledToFit()
    .frame(width: 120, height: 32)
```

### Hero / illustration (full-width)

```swift
Image("onboardingHero")
    .resizable()
    .aspectRatio(contentMode: .fill)
    .frame(maxWidth: .infinity, maxHeight: 240)
    .clipped()
```

### Avatar (square, clipped to circle)

```swift
Image("userAvatar")
    .resizable()
    .scaledToFill()
    .frame(width: 48, height: 48)
    .clipShape(Circle())
```

### Rules

- **Always `.resizable()`** on any downloaded image you want to size. Without it, the image stays at intrinsic pixel size.
- **Always set an explicit `.frame(width:, height:)`** matching the Figma display size. Don't let intrinsic size decide.
- **Use `.aspectRatio(contentMode:)`** or `.scaledToFit() / .scaledToFill()` when the container aspect may differ from the image's.
- **`.scaledToFill()` + `.clipped()`** (or `.clipShape()`) when the image should fill and crop overflow.
- **Template icons:** pair `.renderingMode(.template)` with `.foregroundStyle(...)`. Without a foreground color, SwiftUI applies the default accent color.

---

## 8. Remote images

If the design references URL-loaded images (user avatars, feed content, dynamic content):

1. Check project dependencies (`Package.swift`, `Podfile`, `*.xcodeproj`) for an existing loader: Kingfisher, SDWebImage, Nuke.
2. If found → use it with the project's existing patterns (placeholder, error view, caching policy).
3. If nothing found → ask the user which approach. Do not default to `AsyncImage` silently — it has no caching and flickers.

Do not download remote images as local assets.

---

## 9. Copy from cache to project (Step 7 of the main flow)

After generating the `.imageset` folder structure in `.figma-cache/<nodeId>/assets/<name>.imageset/`, copy it into the project's `Assets.xcassets`:

```bash
cp -R .figma-cache/<nodeId>/assets/icon-close.imageset \
      path/to/Project/Assets.xcassets/
```

Confirm with the user if the project uses multiple Asset Catalogs (per-target, per-feature) — place in the right one.

After copy:
- Clean up the cache (optional) — assets in cache are no longer needed once catalog is updated
- Verify in Xcode: open Assets.xcassets, confirm imageset appears with all three scales
- Build and confirm no "image not found" warnings

---

## Asset Rules Summary

1. **Flatten first, decompose second, code last.** For non-interactive composed artwork, export the whole region via `get_screenshot`. Only break into atomic pieces when the region has interactive/dynamic children.
2. **Download, don't substitute.** Every icon/image from Figma. Never SF Symbols unless user asks.
3. **Download priority: REST API batch → MCP `get_screenshot` → MCP `download_figma_images` (imageRef only).** REST API is preferred when `FIGMA_TOKEN` is available — batches many icons in one call and uses Figma's renderer. Fall through to MCP on token miss, null URLs, or rate limits. `download_figma_images` is only for raster image fills — returns SVG for vector icons regardless of `.png` extension.
4. **Never convert SVG → PNG locally.** Local tools (rsvg-convert, inkscape, ImageMagick) drift from Figma rendering. Always re-export via `get_screenshot`.
5. **Validate with `file`.** Every downloaded asset must show "PNG image data". If SVG/XML → discard, re-export via `get_screenshot`.
6. **3 scale variants.** Generate @2x/@1x with `sips` from the source.
7. **Know the display size.** Read from the Figma frame; set `.frame(width:, height:)` accordingly.
8. **Decide rendering mode.** Single-color icon → template; multi-color/logo → original.
9. **Prefer Contents.json for rendering intent.** Set once in the catalog rather than at every call site.
10. **Search before adding.** Dedup against existing assets.
11. **Global icons: no prefix.** Screen-specific visuals: screen/feature prefix.
12. **Always `.resizable()` + explicit `.frame()`.** Never rely on intrinsic size.
13. **Light/dark variants via Contents.json `appearances`** when Figma provides both.
14. **Remote images via project's loader.** No `AsyncImage` without user confirmation.
15. **No new icon library dependencies.**
