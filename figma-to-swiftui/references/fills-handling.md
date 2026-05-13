# Fills Handling — Background Image + Gradient Overlay

How to translate Figma `fills[]` (paint stack) into SwiftUI when a node has an IMAGE fill, a GRADIENT fill, or both stacked. **`fills.json` from `figma_extract_fills` is the canonical source — read it before composing the view.** This doc replaces the old "agent guesses from screenshot" path captured in [`anti-patterns.md`](anti-patterns.md).

## Source of truth — `fills.json`

Cached at `.figma-cache/<nodeId>/fills.json` after Phase A Step 5. Shape:

```json
{
  "fileKey": "abc123",
  "rootNodeId": "3:24644",
  "nodes": [
    {
      "nodeId": "4:1",
      "nodeName": "HeroBanner",
      "nodeType": "FRAME",
      "width": 375,
      "height": 422,
      "fills": [
        { "type": "image",
          "imageRef": "5f8e...",
          "scaleMode": "FILL",
          "opacity": 1.0,
          "visible": true,
          "imageUrl": "https://s3-alpha-sig.figma.com/img/..." },
        { "type": "gradient",
          "kind": "linear",
          "stops": [
            { "position": 0.0, "hex": "#00000000" },
            { "position": 1.0, "hex": "#000000" }
          ],
          "startPoint": { "x": 0.5, "y": 0.0 },
          "endPoint":   { "x": 0.5, "y": 1.0 },
          "opacity": 0.65,
          "visible": true }
      ]
    }
  ],
  "warnings": []
}
```

**Order matters.** `fills[]` is the Figma paint stack bottom-to-top: index 0 paints first, subsequent fills layer on top. The SwiftUI `ZStack` you emit MUST preserve this order — image at the bottom, gradient on top.

**Filter rule.** Single SOLID 100%-opacity fills do NOT appear in `nodes[]` — those are already covered by `tokens.json` / `design-context.md`. If a node you expected isn't in `fills.json`, it had no interesting fill. Use the screenshot + design-context to confirm and emit the plain solid background.

## Recipe 1 — Background image only

`fills[]` has a single IMAGE fill. The image is already exported to `Assets.xcassets` by Phase B (matched by `nodeId` in `manifest.rows[]` → tagged as `imageAI<Name>` or fallback dedupe).

```swift
ZStack {
    Image(.imageAIHeroBg)              // iOS 17+ ImageResource symbol (Xcode 15+ baseline)
        .resizable()
        .scaledToFill()                // scaleMode=FILL → .scaledToFill
        .clipped()                      // crop overflow so corners stay tidy
    
    contentLayer                       // text + buttons
}
.frame(width: 375, height: 422)
.clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
```

**`scaleMode` → SwiftUI contentMode** (from `references/visual-fidelity.md` §1 "Image fill mode"):

| Figma `scaleMode` | SwiftUI |
|---|---|
| `FILL` (default) | `.resizable().scaledToFill()` + `.clipped()` |
| `FIT` | `.resizable().scaledToFit()` |
| `CROP` | `.resizable().scaledToFill()` + `.clipped()` |
| `TILE` | `.resizable(resizingMode: .tile)` |
| `STRETCH` | `.resizable()` (no aspect-ratio preservation) |

**Hard rules:**
- Image MUST come from `Assets.xcassets`. If `manifest.rows[]` has no entry for this `nodeId`, STOP and add the row to Phase B before continuing — never `Image(uiImage: UIImage(contentsOfFile: ...))` from `fills.json.imageUrl` at runtime, never `AsyncImage(url:)` for a static design asset.
- Use the iOS 17+ generated `ImageResource` symbol (`Image(.imageAIHeroBg)`), NOT the string form `Image("imageAIHeroBg")`.
- If the IMAGE fill has paint `opacity < 1.0`, add `.opacity(0.X)` on the Image — distinct from layer opacity.

## Recipe 2 — Gradient only

`fills[]` has a single GRADIENT fill, no image. Emit a SwiftUI `LinearGradient` / `RadialGradient` directly.

### Linear

```swift
LinearGradient(
    stops: [
        .init(color: Color(hex: "FF6B6B"), location: 0.0),
        .init(color: Color(hex: "FFD93D"), location: 1.0)
    ],
    startPoint: UnitPoint(x: 0.5, y: 0.0),     // from fills.json.startPoint
    endPoint:   UnitPoint(x: 0.5, y: 1.0)      // from fills.json.endPoint
)
.opacity(1.0)                                    // from fills.json.opacity
```

**Map Figma start/end → SwiftUI UnitPoint directly.** Figma's `gradientHandlePositions` are already in 0..1 unit space — pass through unchanged. Do NOT translate to the named UnitPoint constants (`.top`, `.topLeading`, etc.) — the raw numbers are more accurate when the designer uses non-cardinal angles (e.g. 30°).

**Stops with alpha.** When a stop's hex is 8 chars (`#RRGGBBAA`), the alpha is part of the color, NOT paint-level opacity. Emit:
```swift
.init(color: Color(red: 0xFF/255, green: 0x6B/255, blue: 0x6B/255, opacity: 0xCC/255), location: 0.0)
```
Or, if the color resolves to an Asset Catalog entry (`Color(.<name>)`) or a token extension (`Color.<name>`), use that and add a comment noting the alpha came from the gradient stop.

### Radial

```swift
RadialGradient(
    stops: [
        .init(color: Color.white, location: 0.0),
        .init(color: Color.black, location: 1.0)
    ],
    center: UnitPoint(x: 0.5, y: 0.5),               // fills.json.startPoint
    startRadius: 0,
    endRadius: max(width, height) *
        distance(startPoint, endPoint)               // approximate from end handle
)
```

Radial gradients are rare and Figma's three-handle model (center, edge, perpendicular) doesn't map cleanly to SwiftUI's `startRadius/endRadius` scalar pair. **When `fills.json.fills[i].kind == "radial"`, attempt the recipe above and flag in the run summary that radial fidelity is approximate; confirm against `screenshot.png` in C5 Pass 2.**

### Angular / Diamond

Marked `unsupported` in v1 — emit a comment marker, fall back to closest LinearGradient, surface in the run summary for user review.

## Recipe 3 — Image + Gradient stack (the common case)

`fills[]` has `[IMAGE, GRADIENT]` (or sometimes `[IMAGE, GRADIENT, SOLID-translucent]`). This is the recipe for hero cards / onboarding banners / promo headers.

```swift
ZStack(alignment: .bottom) {                 // alignment by content needs
    // Layer 1 (bottom): the image
    Image(.imageAIHeroBg)
        .resizable()
        .scaledToFill()
        .clipped()
    
    // Layer 2 (top): gradient overlay
    LinearGradient(
        stops: [
            .init(color: Color.black.opacity(0.0), location: 0.0),
            .init(color: Color.black,             location: 1.0)
        ],
        startPoint: UnitPoint(x: 0.5, y: 0.0),
        endPoint:   UnitPoint(x: 0.5, y: 1.0)
    )
    .opacity(0.65)                            // paint-level opacity from fills.json
    .allowsHitTesting(false)                  // don't steal taps from content above
    
    // Layer 3 (top): content
    VStack(alignment: .leading, spacing: Spacing.m12) {
        Text(Strings.Hero.title)
            .font(AppFont.heading3())
            .foregroundStyle(Color.white)
        Text(Strings.Hero.subtitle)
            .font(AppFont.body16())
            .foregroundStyle(Color.white.opacity(0.85))
    }
    .padding(Spacing.l24)
    .frame(maxWidth: .infinity, alignment: .leading)
}
.frame(width: 375, height: 422)
.clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
```

**Hard rules:**
1. **Order matches `fills[]` order.** Index 0 in `fills.json.fills[]` = lowest `ZStack` child = painted first. NEVER reverse.
2. **Gradient `.allowsHitTesting(false)`** when content (text/buttons) sits above — gradient is decorative, must not block taps.
3. **`scaledToFill()` + `.clipped()` together.** Missing `.clipped()` lets the image bleed outside the rounded corners — [`anti-patterns.md` §"Image fill-width missing scaledToFill"](anti-patterns.md).
4. **`.frame` + `.clipShape` on the OUTER container**, not on individual layers. This ensures image + gradient + content all clip to the same rounded rectangle.

## Recipe 4 — Translucent solid overlay (rare)

`fills[]` has `[IMAGE, SOLID-translucent]` instead of a gradient. Emit a `Color(...).opacity(X)` as the overlay layer:

```swift
ZStack {
    Image(.imageAIHeroBg).resizable().scaledToFill().clipped()
    Color.black.opacity(0.45)                 // SOLID #000000 with paint opacity 0.45
}
.frame(...)
.clipShape(...)
```

## Recipe 5 — Multiple gradients stacked

Rare but valid (two-tone overlay). Emit one `LinearGradient`/`RadialGradient` per fill entry, ordered bottom-to-top. Keep `.allowsHitTesting(false)` on each decorative layer.

## When `fills.json` is empty for a node you expect

If your B1 inventory has a container that visibly shows a background image or gradient in `screenshot.png` but `fills.json` does NOT include it:

1. **Check the node's fills are non-trivial.** Single 100%-opacity SOLID fills are filtered out by `figma_extract_fills` — the visible background is a plain color and design-context.md / tokens.json cover it. Emit `.background(Color(.surfaceX))` or `.background(Color.white)` per usual.
2. **Check the node's `nodeId` resolution.** `figma_extract_fills` walks the subtree from the screen-root nodeId you passed. If the visual node is OUTSIDE this subtree (e.g. it's a parent of the screen frame), the tool didn't see it. Re-run `figma_extract_fills` with the parent nodeId.
3. **MCP tool error.** Check `fills.json.warnings[]`. If `/v1/files/<key>/images` failed, `IMAGE.imageUrl` will be null but `imageRef` is still present — agent can still emit `Image(.imageAIHeroBg)` from the existing manifest entry.
4. **Last resort fallback.** If the node has interesting fills but `fills.json` doesn't capture them, parse `design-context.md` Tailwind classes (`bg-gradient-to-b`, `bg-[url(...)]`) and inline comments (`// Fill: linear gradient ...`). Note in run summary: "fills.json missed node X — used design-context fallback, fidelity may drift". This is the OLD path; surfacing it is a signal MCPFigma needs a bug fix.

## Banned patterns

- **`AsyncImage(url: URL(string: fills.json.imageUrl))`** — fills.json.imageUrl is a short-lived Figma CDN URL meant for tool-side resolution, NOT for runtime image loading. Production code always uses `Assets.xcassets`.
- **Hand-drawing the gradient with `Rectangle().fill(...)` + manual stops** — use `LinearGradient`/`RadialGradient` directly. They ARE the SwiftUI primitives.
- **`Color(red:green:blue:)` for gradient stops when the color exists in `tokens.json`** — route through Asset Catalog (`Color(.X)`) or token extension (`Color.X`). The gradient stop position is local; the color itself follows the same token-routing rules as everything else.
- **"Simplified" gradient — fewer stops than Figma defined** — every stop in `fills.json.fills[i].stops[]` is required. Skipping stops is the same anti-pattern as "approximated" colors.
- **Using `.background(LinearGradient(...))` when the design has `[IMAGE, GRADIENT]`** — `.background()` takes ONE shape; you need the explicit `ZStack` for layered fills.

## Inventory integration

When building B1 Visual Inventory (per [`visual-fidelity.md` §3](visual-fidelity.md)), for any container row whose node has fills.json coverage, add a sub-block:

```
─────────── CONTAINER ───────────
...
fills (from fills.json):
  [0] image     ref=5f8e..., scaleMode=FILL, opacity=1.0    asset=imageAIHeroBg (manifest.rows)
  [1] gradient  linear, stops=[#00000000@0, #000000@1], opacity=0.65, start=(0.5,0), end=(0.5,1)
```

This makes the layered-fill plan explicit before any Swift is written. C3 Pass 1 (banned-phrase grep) plus C5 visual diff catch drift after the fact, but the inventory entry is where the discipline starts.

## Coverage gate — `c3-fills-coverage.sh`

Enforces this entire doc at C3. Reads `fills.json.nodes[]` and source-greps the audit's `*Screen.swift` / `*View.swift` files for `Image(.X)` / `LinearGradient(` / `RadialGradient(` / `AngularGradient(` / `EllipticalGradient(` / `MeshGradient(` constructors. Catches the most common Bug-1 failure mode: Recipe 1 or Recipe 3 skipped entirely (`fills.json` has an IMAGE node but emitted code has zero `Image()` references).

| Code | Level | Triggers |
|---|---|---|
| **FC-1** | FAIL | ≥1 IMAGE-fill node in `fills.json` but 0 `Image(.X)` / `Image("X")` in source. Recipe 1/3 skipped. |
| **FC-2** | FAIL | ≥1 GRADIENT-only node in `fills.json` but 0 gradient constructors in source. Recipe 2 skipped. |
| **FC-3** | FAIL | ≥1 stacked `[IMAGE, GRADIENT_*]` node but emitted code has image only (gradient overlay dropped). Recipe 3 half-applied. |
| **FC-4** | FAIL | ≥1 IMAGE-carrying node in `fills.json` but `manifest.rows[]` has no `status=done` entry for that nodeId. The exporter pipeline missed it — `Image(.X)` will reference the wrong asset or none at all. Fix: re-run `figma_export_assets_unified(autoDiscover: true)` OR manually add a fallback row for the node. |
| **FC-4?** | WARN | `manifest.json` missing entirely — can't run FC-4. Run the exporter at Phase A first, then re-run this gate. |

Invoke via the C3 driver:

```bash
bash ~/.claude/scripts/c3-driver.sh fills-coverage --cache .figma-cache/<nodeId> --src-root "$PWD"
```

**Bypass.** When the design legitimately swapped the Figma background for a solid color and `fills.json` is stale, add `// allow-no-bg-emit: <reason>` on the `var body` line (or any line) of the generated screen file. The gate downgrades the affected finding to WARN. **Do not** use the bypass to ship the bug — regenerate `fills.json` instead by re-running `figma_extract_fills` against the current root nodeId.

Writes `.figma-cache/<nodeId>/c3-fills-coverage.json`. Aggregate gate surfaces it as `layers.l2_fills_coverage.gate` in `c3-gate.json`.
