# Figma Layout to SwiftUI Translation

Complete reference for translating Figma layout concepts into SwiftUI code.

## Auto Layout to Stacks

Figma Auto Layout is the closest analog to SwiftUI stacks. The translation is mostly 1:1, but edge cases exist.

### Direction

- Vertical auto layout -> VStack(alignment:, spacing:)
- Horizontal auto layout -> HStack(alignment:, spacing:)
- Wrap (horizontal with line break) -> No native SwiftUI equivalent. Use LazyVGrid with adaptive columns, or a custom FlowLayout.

### Alignment

Figma auto layout alignment maps to SwiftUI alignment:

Primary axis alignment (justify):
- Packed (start) -> Default stack behavior (no spacer)
- Packed (center) -> Wrap content in stack with Spacer() on both sides, or use .frame(maxWidth/Height: .infinity) with centered alignment
- Packed (end) -> Spacer() before content
- Space between -> Spacer() between each child element
- Space around / space evenly -> Not native; distribute with custom spacing or GeometryReader

Cross axis alignment:
- VStack: .leading, .center, .trailing
- HStack: .top, .center, .bottom, .firstTextBaseline, .lastTextBaseline

### Spacing (Gap)

Figma gap value maps directly to spacing parameter:
- gap: 12 -> VStack(spacing: 12) or HStack(spacing: 12)
- Mixed gaps between children -> Cannot use single spacing value. Use explicit Spacer().frame(height/width:) or padding between children.

### Padding

Figma padding maps to SwiftUI .padding():
- Uniform padding: 16 -> .padding(16)
- Horizontal 16, Vertical 12 -> .padding(.horizontal, 16).padding(.vertical, 12)
- Individual edges -> .padding(EdgeInsets(top:, leading:, bottom:, trailing:))
- Note: Figma uses left/right, SwiftUI uses leading/trailing for RTL support

**Padding vs background order matters:**
```swift
// Figma: card with 16pt inner padding, white bg, 12pt radius
content
    .padding(16)                                         // inner padding
    .background(Color.white, in: .rect(cornerRadius: 12)) // bg clipped to rounded shape
// NOT:
content
    .background(Color.white)  // bg first — takes intrinsic size, no padding
    .padding(16)              // padding OUTSIDE bg — visible gap
```

**Figma "padding" on a text layer is not always padding:** Figma sometimes encodes vertical centering as top/bottom padding. When a Text in Figma has padding top=4, bottom=4 and line-height ≠ font-size, this is usually the text's line-box, not real padding. Don't double-apply — see references/visual-fidelity.md for line-height handling.

### Sizing

Figma sizing modes:
- Fixed (width: 200) -> .frame(width: 200)
- Hug contents -> No modifier needed. SwiftUI views hug by default.
- Fill container -> .frame(maxWidth: .infinity) or .frame(maxHeight: .infinity)
- Fill with min/max -> .frame(minWidth:, maxWidth:, minHeight:, maxHeight:)

#### Text sizing-mode → SwiftUI (HARD RULE)

`.frame(width:)` on a Text view is BANNED unless Figma `primaryAxisSizingMode === FIXED` AND a justifying comment is present (`// Figma fixed-width: <reason>`). Reading Figma's measured visual width on a hug-mode Text and emitting `.frame(width: 200)` ships truncation the moment content grows (longer localized strings, dynamic data, larger Dynamic Type sizes).

Mapping:

| Figma `primaryAxisSizingMode` | Lines (Figma render) | SwiftUI |
|---|---|---|
| AUTO (hug), 1 line | 1 | no `.frame` width modifier |
| AUTO (hug), ≥2 lines | ≥2 | no `.frame` width modifier |
| fill (parent constrains width), 1 line | 1 | `.frame(maxWidth: .infinity, alignment:)` + `.lineLimit(1)` + **`.minimumScaleFactor(0.6)`** |
| fill, ≥2 lines | ≥2 | `.frame(maxWidth: .infinity, alignment:)` (let wrap; no `.lineLimit` cap, no `.minimumScaleFactor`) |
| FIXED (justified by designer, e.g. badge cell) | any | `.frame(width: X).fixedSize(horizontal: false, vertical: true)` + `// Figma fixed-width: <reason>` comment; if 1-line, also `.minimumScaleFactor(0.6)` |

`.fixedSize(horizontal: false, vertical: true)` on a fixed-width Text lets it wrap to multiple lines when content overflows instead of clipping into ellipsis. Single-line Text in any constrained container (`.lineLimit(1)`) takes `.minimumScaleFactor(0.6)` so localized copy shrinks rather than truncates. Multi-line Text wraps naturally — does NOT take `.minimumScaleFactor` (wrapping is the right escape valve for multi-line copy).

#### Image content-mode → SwiftUI (HARD RULE)

A fill-width / fill-height image MUST emit all three modifiers together: `.resizable() + (.scaledToFill()|.scaledToFit()) + .frame(...)`. Missing any of the three is a bug:

| Missing | Visual outcome |
|---|---|
| no `.resizable()` | image stays at intrinsic pt size; `.frame(maxWidth: .infinity)` reserves space the image refuses to fill → blank gap |
| no content mode | resized image stretches anisotropically (squashed / elongated) |
| no `.frame(...)` | resizable image shrinks to its intrinsic minimum |

Mapping (Figma `imageScaleMode` / inline `objectFit` → SwiftUI):

| Figma scaleMode | Inline `objectFit` | SwiftUI |
|---|---|---|
| `FILL` (Figma image-fill default) | `cover` | `.resizable().scaledToFill().frame(maxWidth: .infinity, ...).clipped()` |
| `FIT` | `contain` | `.resizable().scaledToFit().frame(maxWidth: .infinity, ...)` |
| `CROP` (with crop transform) | n/a — pre-cropped | same as FILL — `.resizable().scaledToFill().clipped()` |
| `TILE` | `repeat` | `.resizable(resizingMode: .tile).frame(...)` |
| absent / hug image | `none` | `Image(...)` no `.resizable`, no `.frame` — intrinsic pt size |

Default content mode when `objectFit` is absent and the image fills its parent: `.scaledToFill()` (Figma's image-fill default).

#### Button sizing-mode → SwiftUI (HARD RULE)

Where `.frame(maxWidth: .infinity)` lives matters as much as whether it's emitted at all. SwiftUI propagates "fill width" requests outward — a Text or HStack inside a Button asking for fill makes the Button itself fill, overriding the caller's `.padding(.horizontal, N)`. The width modifier MUST live on the Button's OUTER frame (or be absent), driven by the Button node's own Figma `primaryAxisSizingMode`:

| Figma button `primaryAxisSizingMode` | SwiftUI on Button outer | Inner Text / HStack |
|---|---|---|
| `FILL` (button fills its row container — common for primary CTAs) | `.frame(maxWidth: .infinity)` | NO width modifier on inner Text. Use `HStack { ...; Spacer(); ... }` for asymmetric content if needed. |
| `FIXED` (designer set explicit width N) | `.frame(width: N)` | NO width modifier on inner Text. |
| `AUTO/HUG` (button hugs its label — chip / tag / pill) | no width modifier (intrinsic) | NO width modifier on inner Text. |

**Pattern (correct):**
```swift
Button(action: tapped) { Text("Continue") }
  .frame(maxWidth: .infinity)         // Button outer fills caller's slot
  .padding(.vertical, 12)
  .background(Color(.accent), in: .rect(cornerRadius: 8))
  .padding(.horizontal, 16)           // caller margin — works because Button is the fill-width view
```

**Anti-pattern (cascades to bloat — BANNED):**
```swift
Button(action: tapped) {
  HStack {
    Text("Continue").frame(maxWidth: .infinity)  // ← cascades up through Button
  }
}
.padding(.horizontal, 16)              // ← bypassed, button extends edge-to-edge
```

The inner-Text maxWidth case is enforced by `figma-to-swiftui-banned-pattern-gate.sh` Check 8. Allow-list: `// allow-text-fill: <reason>` on the same line OR the line above. Same cascade trap exists symmetrically for `.frame(maxHeight: .infinity)` inside vertically-bounded containers (Cards, Tappable rows). See [`visual-fidelity.md` §"`.frame(maxWidth: .infinity)` cascade trap"](visual-fidelity.md) + §7 Hard Rule #14.

**Common sizing mistakes:**
- Applying `.frame(width: 375)` on a full-width element — use `.frame(maxWidth: .infinity)` so it adapts to device width
- Forgetting `.frame(maxWidth: .infinity, alignment: .leading | .center | .trailing)` when Figma fills width with a non-default alignment. The classic centering bug: a Text whose Figma `textAlignHorizontal=CENTER` inside a fill-width row gets `.multilineTextAlignment(.center)` only, the Text hugs its intrinsic width, and the visible result reads as left-aligned. Always pair `.multilineTextAlignment(.center)` with a fill-width drawing rect — but check the parent: if the parent is a non-Button stack, place `.frame(maxWidth: .infinity, alignment: .center)` on the Text; if the parent is `Button { ... }`, place `.frame(maxWidth: .infinity)` on the Button's OUTER frame and let the rect propagate down. See `visual-fidelity.md` §Text + §"`.frame(maxWidth: .infinity)` cascade trap" + Button sizing-mode table above.
- Putting `.frame(maxWidth: .infinity)` on inner Text or inner HStack inside a Button — cascades up, makes the Button fill the screen, overrides caller padding. See Button sizing-mode table above. **Inner Text inside Button: no maxWidth modifier; the Button outer is where width lives.**
- Reading the rendered visual width on a hug-mode Text from Figma metadata and emitting `.frame(width: 200)` — see Text sizing-mode table above. **Hug → no `.frame` width.**
- Using `.frame(height:)` on Text — Text height = font line-box; fixed height clips or leaves space. Prefer `.padding` on Text's container.
- Image with `.frame(maxWidth: .infinity)` but no `.resizable()` — image keeps intrinsic size, the frame reserves blank space. See Image content-mode table above. **Fill image needs all three modifiers.**

### Aspect Ratio

- Figma constraint "Preserve aspect ratio" -> .aspectRatio(width/height, contentMode: .fit) or .fill

## Absolute Positioning

Figma frames without auto layout use absolute (x, y) positioning.

- Prefer translating to stacks when the visual structure allows it
- When absolute positioning is necessary, use ZStack with .offset(x:, y:)
- For responsive absolute layouts, use GeometryReader (sparingly)
- Figma constraints (pin left, pin top, etc.) -> combine .frame() with alignment parameters in the parent

## Scroll

- Figma frame with "Clip content" + overflow -> ScrollView
- Vertical scroll -> ScrollView(.vertical) { VStack { ... } }
- Horizontal scroll -> ScrollView(.horizontal) { HStack { ... } }
- Both directions -> ScrollView([.vertical, .horizontal]) { ... }
- Paging -> ScrollView { LazyHStack { ... } }.scrollTargetBehavior(.paging)

## Common Patterns

### Card Layout
Figma: Frame (auto layout vertical, padding 16, corner radius 12, drop shadow, fill white)
SwiftUI:
```swift
VStack(alignment: .leading, spacing: 8) {
    // card content
}
.padding(16)
.background(Color.white)
.clipShape(RoundedRectangle(cornerRadius: 12))
.shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 2)
```

### List Item
Figma: Frame (auto layout horizontal, spacing 12, padding vertical 12 horizontal 16, fill container)
SwiftUI:
```swift
HStack(spacing: 12) {
    // list item content
}
.padding(.vertical, 12)
.padding(.horizontal, 16)
.frame(maxWidth: .infinity, alignment: .leading)
```

### Header with Back Button
Figma: Frame (auto layout horizontal, space between, padding 16)
SwiftUI: Prefer .navigationTitle() + .toolbar {} over custom header when possible. Custom header only if design is significantly non-standard.

### Bottom Safe Area Content
Figma: Frame pinned to bottom with padding
SwiftUI:
```swift
VStack {
    Spacer()
    content
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
}
.safeAreaInset(edge: .bottom) { ... }
// or use .toolbar(.bottomBar)
```

## Safe Area Normalization for Mockup Frames

Figma frames for iPhone screens almost always include the **mockup chrome** drawn over the canvas — status bar at the top (time "9:41" + signal/wifi/battery icons OR Dynamic Island pill) and home indicator at the bottom (~134×5pt capsule). These pixels are NOT content the SwiftUI view should reproduce — iOS renders them. SwiftUI views also live inside the safe area by default.

**The double-count bug.** Agent reads a view's Y from Figma metadata as `y=64` (raw `44pt status-bar chrome + 20pt actual gap`), emits `.padding(.top, 64)` directly. SwiftUI's default safe-area inset adds another 44pt on top. Visual gap on the device = `44 + 64 = 108pt` — view is 64pt too low. Same on the bottom edge with the home indicator (34pt).

The fix is two steps: (1) detect mockup chrome from frame size, (2) subtract the safe-area inset before mapping to SwiftUI.

### Detect mockup chrome

Frame H from `metadata.json` matches a known iPhone full-device height ⇒ mockup chrome is present. (Figma frames where designers EXCLUDE chrome typically use rounded heights like 768 / 780 / 800 — never the device-exact values below.)

| Frame H (pt) | Device | safeAreaInsets.top | safeAreaInsets.bottom |
|---|---|---|---|
| 568 | iPhone SE (1st gen / 5/5s) | 20 | 0 |
| 667 | iPhone 6/7/8/SE 2nd/3rd gen | 20 | 0 |
| 736 | iPhone 6/7/8 Plus | 20 | 0 |
| 812 | iPhone X / XS / 11 Pro / 12 mini / 13 mini | 44 | 34 |
| 844 | iPhone 12 / 12 Pro / 13 / 13 Pro / 14 | 47 | 34 |
| 852 | iPhone 14 Pro / 15 / 15 Pro / 16 | 59 (Dynamic Island) | 34 |
| 896 | iPhone XR / XS Max / 11 / 11 Pro Max | 44 | 34 |
| 926 | iPhone 12 Pro Max / 13 Pro Max / 14 Plus | 47 | 34 |
| 932 | iPhone 14 Pro Max / 15 Plus / 15 Pro Max / 16 Plus / 16 Pro Max | 59 (Dynamic Island) | 34 |

**Cross-check signal.** `screenshot.png` top region typically shows the status-bar mockup (time `9:41`, signal/wifi/battery icons) when `mockupChrome=true`. If frame H matches the table BUT the screenshot has no chrome at top → designer drew on a full-device canvas with the chrome layer hidden; still subtract insets per the table (the canvas height implies chrome is *reserved*, even if not visually drawn).

**Ambiguous case.** Frame H not in the table (e.g. 768, 800, 900) ⇒ designer cropped chrome themselves ⇒ `mockupChrome=false` ⇒ Y values are already content-relative ⇒ DO NOT subtract. If you cannot confidently classify (frame H = 800, screenshot has a status-bar mockup at top) → **STOP and ask the user**, do not guess.

### Apply normalization

Once `mockupChrome=true` and insets are known, every Y measurement on the way into the inventory and every Y-spacing modifier on the way out subtracts the inset:

```
adjusted_y      = raw_figma_y - safeAreaInsets.top
adjusted_bottom = raw_figma_distance_from_frame_bottom - safeAreaInsets.bottom
```

```swift
// Figma raw y = 64 (44 chrome + 20 gap); inset.top = 44 → adjusted = 20
VStack {
    content
}
.padding(.top, 20)   // safe-area-adjusted: raw figma y=64, inset=44, adjusted=20
```

**Rules:**
1. Raw Figma Y values from `metadata.json` / `design-context.md` are NEVER copied verbatim into `.padding(.top, ...)` / `Spacer().frame(height: ...)` at screen-root when `mockupChrome=true`. Subtract first.
2. Suspicious values at screen-root that almost always indicate the bug — if you find yourself emitting any of these without a justifying comment, stop and re-check the math: `.padding(.top, 44|47|59|64|67|79|88)`.
3. If a value at screen-root genuinely IS one of these (e.g. designer wanted a 64pt top inset above the safe area for a hero gradient), add the comment verbatim: `// safe-area-adjusted: raw figma y=<N+inset>, inset=<inset>, adjusted=<N>`.
4. Content that should extend BEHIND the status bar (full-bleed hero gradient, image banner): apply `.ignoresSafeArea(edges: .top)` to the **background layer only**. Content layer (text/buttons) stays inside the safe area. See `visual-fidelity.md` §"Safe area & spacing normalization".
5. Bottom: never add 34pt to bottom padding to "make room for the home indicator" — iOS already pushes content above it. Use `.safeAreaInset(edge: .bottom) { ... }` if you need a custom bottom bar to ride above the home indicator.

This is enforced by check letter `SS` (Spacing-Safe-area) in C3 Pass 2 — see `references/verification-loop.md`.

## Effects & Decorations

| Figma | SwiftUI |
|---|---|
| Drop shadow | `.shadow(color:, radius:, x:, y:)` — full form; defaults are wrong |
| Inner shadow | `.overlay { RoundedRectangle(...).stroke(...).blur(...) }` or custom |
| Layer blur | `.blur(radius:)` |
| Background blur | `.background(.ultraThinMaterial)` / `.regularMaterial` / `.thickMaterial` |
| Corner radius (all equal) | `.clipShape(.rect(cornerRadius:))` |
| Individual corners | `UnevenRoundedRectangle(topLeadingRadius:, topTrailingRadius:, bottomLeadingRadius:, bottomTrailingRadius:)` |
| Border / stroke | `.overlay(RoundedRectangle(...).stroke(color, lineWidth:))` |
| Clip content | `.clipped()` or `.clipShape(...)` |
| Mask | `.mask { ... }` |
| Blend mode | `.blendMode(.multiply)` etc |
| Liquid Glass (iOS 26+) | `.glassEffect()` with appropriate shape |

## Animations & Transitions

Figma prototype connections = design intent for transitions, not literal animation specs. Interpret as navigation or state-change animations.

| Figma | SwiftUI |
|---|---|
| Dissolve | `.opacity(...)` + `withAnimation(.easeInOut)` |
| Move in / slide in | `.transition(.move(edge:))` or `.offset(...)` |
| Push | `NavigationStack` push (system transition) |
| Smart animate | `withAnimation { }` on state change |
| Scroll animate | `ScrollView` + `.scrollTransition()` |

Rules:
- Check project deps for Lottie — use if present
- Don't over-animate. Prototype links = navigation, not custom animation.
- Complex choreographed animations → ask user whether to implement fully or simplify
