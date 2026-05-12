# Visual Fidelity Playbook

Read this **first, every Phase C.** It defines: how to parse `design-context.md`, the Visual Inventory required before any code, SwiftUI defaults that silently break fidelity, the screenshot cross-check, and the 14 hard rules.

---

## 1. Parsing `design-context.md`

### Tailwind class → exact value

| Class | Value |
|---|---|
| `p-4`, `px-4`, `py-4`, `pt-4`, etc | 16pt (`4 × 4`) |
| `m-4`, `mx-4`, etc | 16pt |
| `gap-3`, `space-x-3` | 12pt |
| `w-full`, `h-full` | `.frame(maxWidth: .infinity)` / `.frame(maxHeight: .infinity)` |
| `w-screen`, `h-screen` | `GeometryReader { proxy in ... proxy.size.width/height }` |
| `text-sm`, `text-base`, `text-lg`, `text-xl` | 14 / 16 / 18 / 20pt (NOT iOS text styles) |
| `font-medium`, `font-semibold`, `font-bold` | `.medium`, `.semibold`, `.bold` |
| `rounded-lg`, `rounded-xl`, `rounded-2xl` | 8 / 12 / 16pt |

### Arbitrary values — take them literally

`p-[16px]` → 16pt, `text-[#FF6600]` → `Color(hex: "#FF6600")`, `font-[Inter]` → `Font.custom("Inter", size: ...)`, `leading-[150%]` → multiply by font size for `.lineSpacing`.

### Color classes

`text-gray-900` → check inline color block first; map to project token. Never assume Tailwind's default — Figma uses custom palettes.

### Inline style blocks

`design-context.md`'s `## These styles are contained in the design` block has the canonical values. Prefer this over Tailwind class names when they differ.

### Image fill mode (`objectFit` → SwiftUI content mode)

| Figma `imageScaleMode` / CSS `objectFit` | SwiftUI |
|---|---|
| FILL / `cover` | `.scaledToFill()` (default when scaleMode absent on fill-* image) |
| FIT / `contain` | `.scaledToFit()` |
| CROP | `.scaledToFill()` + `.clipped()` |
| TILE | `.background { Image(...).resizable() }` — manual tile |

### Figma-specific comments

`// Figma: <node-id>` (inline literal justification), `// safe-area-adjusted: raw=N, inset=I, adjusted=N-I` (screen-root padding justification), `// allow-systemName: <reason>`, `// allow-text-fill: <reason>`, `// allow-screen-corner-radius: <reason>` — see banned-pattern hook.

---

## 2. Source-of-Truth Priority

When sources conflict:

1. **Code Connect map** (`code-connect.json`) overrides everything for mapped components.
2. **Project tokens** (`c1-conventions.json` enum cases) > **Figma tokens** (`tokens.json` swiftName/lightHex).
3. **`tokens.json`** > **inline style block** > **Tailwind class**.
4. **`fills.json`** > **`design-context.md` background classes** when container has non-trivial fills.
5. **Visual inspection of `screenshot.png`** is the tiebreaker when metadata disagrees.

---

## 3. Visual Inventory Template (required before Step 6)

For every screen, produce this in scratch context before writing SwiftUI:

```
─────────── CONTAINER ───────────
size:           W x H  (fixed / fill-width / fill-height / hug)
frameSize:      Wf x Hf
deviceClass:    iPhone X/11 Pro/12 mini/13 mini (812) | 12/13/14 (844) | 14 Pro/15 Pro (852)
                | 14 Pro Max/15 Pro Max/16 Pro Max (932) | older (568/667/736) | n/a
safeAreaInsets: top=N, bottom=M
mockupChrome:   true | false       [true if frame H matches deviceClass list AND screenshot shows status-bar mockup]
deviceBezel:    true | false       [true if mockupChrome=true AND frame outline shows ~47-55pt rounded corners.
                                    HARDWARE bezel — NOT a UI corner radius. When true, screen-root cornerRadius=0]
background:     <hex or token>   [source: tokens | inline | class | fills.json]
layeredFills:   <none> | <bottom-to-top list>   [source: fills.json — emit ZStack per fills-handling.md Recipe 3]
cornerRadius:   Xpt              [if deviceBezel=true and from FRAME outline, set 0 + note "device bezel, not UI"]
border:         Xpt, <hex>
shadow:         color=<rgba>, radius=X, offsetX=X, offsetY=X
padding:        top=X, leading=X, bottom=X, trailing=X    [if mockupChrome=true, POST-SUBTRACT — raw minus inset]

─────────── LAYOUT ───────────
type:                       VStack | HStack | ZStack | ScrollView + stack | LazyVGrid | GeometryReader
spacing:                    Xpt
counterAxisAlignItems:      MIN | CENTER | MAX | BASELINE   → VStack(alignment:) / HStack(alignment:)
                                                              DEFAULT IS .center — override if Figma says MIN/MAX
primaryAxisAlignItems:      MIN | CENTER | MAX | SPACE_BETWEEN   → Spacer() pattern, NOT a stack init param

─────────── ELEMENTS ─────────── (one row per visible element)
[n] <kind> "<label or asset name>"
    position:    index in stack | offset (x,y) for ZStack
    size:        WxH (fixed / hug / fill)
    — if Text:
    font:           family=<name>, size=X, weight=<w>, width=<std|expanded>
    lineHeight:     Xpt absolute  OR  Xx multiplier         [never skip]
    letterSpacing:  X pt
    color:          <hex or token>
    textAlign:      LEFT | CENTER | RIGHT | JUSTIFIED        [never skip; from Figma textAlignHorizontal]
    frame:          hug | fill-width | fixed-width(W)        [from Figma primaryAxisSizingMode — NEVER from rendered visual width]
    lineCount:      Figma render shows N lines
    lineLimit:      N | none                                  [if single-line in constrained width, MUST also emit .minimumScaleFactor(0.6)]
    — if Image/Icon:
    asset:        <name>
    size:         WxH
    frame:        hug | fill-width | fill-height | fill-both | fixed(WxH)
    contentMode:  fill | fit | crop | tile | none           [Default when fill-* + objectFit absent: FILL]
    renderingMode: original | template (+ tint color)
    — if Button:
    style:       <variant>
    sizingMode:  FILL | FIXED(W) | AUTO/HUG                  [Figma primaryAxisSizingMode — applied on Button OUTER frame]
    background:  <hex>
    foreground:  <hex>
    cornerRadius: Xpt
    padding:     X x X
    — if Shape:
    shape:       RoundedRectangle | Capsule | Circle | Custom
    fill:        <hex or gradient spec>
    stroke:      Xpt <hex>
```

**Rules:**
- Every visible element → an entry with source tag `[tokens | inline | class | screenshot]`.
- Unknown field → `[estimate]`, never omit.
- Never skip: `lineHeight`, `letterSpacing`, `shadow`, `border`, `textAlign`, stack alignment (both axes), image `contentMode`, container `safeAreaInsets`/`mockupChrome`/`deviceBezel`.
- VStack/HStack default cross-axis is `.center` — must override if Figma says MIN/MAX.
- `primaryAxisAlignItems` (CENTER/SPACE_BETWEEN/MAX) does NOT map to a stack init param — use `Spacer()` patterns.

### Source-tag → swiftui-pro routing

| Tag | Example | Route |
|---|---|---|
| `tokens` | `--text-primary` | `IKCoreApp.colors.textPrimary` (preferred) OR `Color(.textPrimary)` |
| `inline` | `font-weight: 700` | `.bold()` (swiftui-pro transform — never `.fontWeight(.bold)`) |
| `inline` | `padding: 24` | `Spacing.l24` if token matches; else `.padding(24)` |
| `inline` | `font-size: 16` | Dynamic Type role → `.font(.body)`; IKFont match → preset; else `@ScaledMetric var fontSize: CGFloat = 16` |
| `inline` | `#FF6600` | Token match → enum; else `Color(.brandOrange)` (asset symbol); else `Color(hex: "#FF6600")` |
| `class` | shared button class | Reuse project's existing `ButtonStyle` (C1 audit) |
| `screenshot` | `~24pt` | Token first, then inline. Mark `[estimate]`; ask if differs > 4pt |

---

## 4. SwiftUI Defaults That Break Fidelity

### Text

- `.font(.system(size: X))` has its own line height (~1.17×) — rarely matches Figma. Use `.lineSpacing(Y)` where `Y = lineHeight - fontSize`.
- Default letter spacing ≠ 0. Use `.tracking(-0.32)` (preserves ligatures) over `.kerning(-0.32)`.
- **Alignment requires width — maxWidth lives on OUTERMOST container, not inner Text.** Single-line Text inside HStack/VStack hugs its intrinsic width by default → centered text appears left-aligned. Two cases:
  - **Parent is non-Button stack:** `.frame(maxWidth: .infinity, alignment: .center)` ON THE TEXT.
  - **Parent is `Button { ... }`:** `.frame(maxWidth: .infinity)` ON BUTTON's OUTER frame. Text stays intrinsic.

- **`.frame(width: N)` on Text BANNED by default** — measured visual width is not a constraint:

  | Figma `primaryAxisSizingMode` | Lines | SwiftUI |
  |---|---|---|
  | AUTO (hug), 1 line | 1 | no width modifier |
  | AUTO (hug), ≥2 lines | ≥2 | no width modifier |
  | fill, 1 line | 1 | `.frame(maxWidth: .infinity, alignment:)` + `.lineLimit(1)` + `.minimumScaleFactor(0.6)` |
  | fill, ≥2 lines | ≥2 | `.frame(maxWidth: .infinity, alignment:)` (let wrap) |
  | FIXED | any | `.frame(width: X).fixedSize(horizontal: false, vertical: true)` + `// Figma fixed-width: <reason>` |

  Parent-aware for `fill` rows: when parent is a `Button { ... }`, move maxWidth to Button's outer frame, not Text.

- **`.minimumScaleFactor(0.6)` required on single-line Text in constrained widths** (`.lineLimit(1)` OR visually single-line inside fill-width/fixed-width). Otherwise localized strings (German, Russian) and longer dynamic data truncate. Multi-line Text does NOT take `.minimumScaleFactor`.

### `.frame(maxWidth: .infinity)` cascade trap

SwiftUI propagates fill-width requests **outward**. A Text asking for fill cascades up through Button → screen-root.

**The bug:** `Text(...).frame(maxWidth: .infinity)` inside a Button to fix "centered text reads left-aligned". Caller wrapping in `.padding(.horizontal, 16)`, but inner Text's maxWidth propagates → Button asks for full width → caller's padding bypassed. Figma showed 343pt button; sim shows 393pt.

**Rule — `.frame(maxWidth: .infinity)` belongs on the OUTERMOST view of bounded container, never on inner descendants of a Button.**

By Figma `primaryAxisSizingMode` on Button:

| Figma sizing | SwiftUI |
|---|---|
| FILL (most primary CTAs) | `Button { ... }.frame(maxWidth: .infinity)` on outer; no maxWidth inner |
| FIXED | `Button { ... }.frame(width: N)` on outer; no width inner |
| AUTO/HUG | `Button { ... }` — no width modifier |

### Patterns for asymmetric button content (icon + label)

Pick based on Figma signal — wrong pattern is what C5.6.6 "Button internal layout check" catches.

| Figma signal | Pattern |
|---|---|
| Auto-layout HORIZONTAL + `primaryAxisAlignItems: SPACE_BETWEEN` (text + icon at opposite edges) | **Case A — HStack + Spacer** |
| Icon `layoutPositioning: ABSOLUTE` OR Tailwind `absolute right-6` on icon inside `relative` button. Text `textAlignHorizontal: CENTER` sits at horizontal center | **Case B — ZStack overlay** |
| Text-only button | `Button { Text("...") }.frame(maxWidth: .infinity)` — Text auto-centers |

**Eye-test tiebreaker on Figma screenshot.** Text at leading edge = Case A. Text at horizontal center with icon as trailing accent = Case B.

**Case A** (push to opposite edges):
```swift
Button(action: tapped) {
    HStack(spacing: 0) {
        Text("Continue")
        Spacer()
        Image(.icAIArrowRight)
    }
}
.frame(maxWidth: .infinity)   // Button outer fills caller slot
.padding(.vertical, 12)
.background(Color(.accent), in: .rect(cornerRadius: 8))
.padding(.horizontal, 16)     // caller margin works
```

**Case B** (centered text, icon overlay):
```swift
Button(action: tapped) {
    ZStack {
        Text("Continue")                              // centers in ZStack
        HStack {
            Spacer()
            Image(.icAIArrowRight).padding(.trailing, 16)
        }
    }
}
.frame(maxWidth: .infinity, minHeight: 56)
.background(Color(.accent), in: .rect(cornerRadius: 8))
```

### Stack alignment

VStack/HStack `.center` cross-axis default rarely matches Figma. If Figma `counterAxisAlignItems = MIN`, write `VStack(alignment: .leading)`. Main-axis (`primaryAxisAlignItems`) needs `Spacer()` patterns:

| Figma | SwiftUI pattern |
|---|---|
| MIN | (no Spacer) |
| CENTER | `Spacer(); ...; Spacer()` |
| MAX | `Spacer(); ...` |
| SPACE_BETWEEN | `...; Spacer(); ...; Spacer(); ...` |

For VStack inside fixed-height frame, also `.frame(maxHeight: .infinity)`. For HStack inside fill-width frame, also `.frame(maxWidth: .infinity)`.

### Button

Always set `.buttonStyle(.plain)` on custom-styled buttons to disable system styling.

### Image

- Default `.resizable()` is OFF — must add explicitly.
- Default content mode without `.scaledToFill()`/`.scaledToFit()` = intrinsic shrink to image's native size.
- Default `renderingMode` reads from asset catalog — explicit `.renderingMode(.template)` for tinted single-color icons.

**Fill-width / fill-height Image MUST emit all three:** `.resizable() + .scaledToFill()|.scaledToFit() + .frame(...)`. Missing any one is a bug (blank gap / anisotropic stretch / intrinsic shrink). Default content mode when `objectFit` absent on fill-* image: `.scaledToFill()`.

### Safe area & spacing normalization

When `mockupChrome=true` (Figma frame includes status-bar mockup): every Y position in inventory + every screen-root `.padding(.top, N)` MUST be `N = raw_figma_y - safeAreaInsets.top`. Suspicious values (44/47/59/64/67/79/88) at screen-root require `// safe-area-adjusted: raw=<N+inset>, inset=<inset>, adjusted=<N>` comment.

Same for bottom + home indicator.

### Device bezel ≠ view corner radius

When `deviceBezel=true` (frame outline shows ~47-55pt rounded corners): screen-root view MUST NOT carry `.cornerRadius(R)` / `.clipShape(.rect(cornerRadius: R))`. Hardware clips outer corners for free. `R ≥ 30` at screen-root is BANNED without `// allow-screen-corner-radius: <reason>` comment (rare — modal sheets / half-screens with Figma-specified inner-card radius).

### Padding & Spacing

- Edge insets: use `.padding(.top, X).padding(.leading, X)...` not `.padding(EdgeInsets(...))` (clearer).
- Never rely on default `.padding()` (16pt) — always specify.
- `VStack(spacing:)` must be explicit; defaults to 8pt.

### Shape / Background

- `.cornerRadius(X)` is deprecated — use `.clipShape(.rect(cornerRadius: X))` (iOS 17+) or `.clipShape(RoundedRectangle(cornerRadius: X))` (iOS 16).
- `.background(Color, in: .rect(cornerRadius: X))` clips + colors in one step.
- Individual corners: `UnevenRoundedRectangle(topLeadingRadius:, topTrailingRadius:, bottomLeadingRadius:, bottomTrailingRadius:)`.

### Shadow

Always full form: `.shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)`. SwiftUI defaults (black, 5pt radius, 0/0 offset) rarely match Figma.

### Lists & Forms

- `List` defaults: separators, inset, default row height. Customize with `.listRowSeparator(.hidden)`, `.listRowInsets(...)`, `.listRowBackground(...)`.
- `LazyVStack`/`LazyVGrid` no default separators (use them for custom-styled lists from Figma).

### NavigationStack

- `.navigationTitle(title)` + `.navigationBarTitleDisplayMode(.inline | .large)`.
- Hide nav bar: `.toolbar(.hidden, for: .navigationBar)`.
- Hide tab bar: `.toolbar(.hidden, for: .tabBar)`.
- Inline back: no Back button label by default → fine. Custom back: `.navigationBarBackButtonHidden(true)` + custom `ToolbarItem`.

### Font width / tracking (iOS 16+)

If Figma uses `Expanded`/`Condensed` width: `.fontWidth(.expanded)` (not just weight).

### Dynamic Type

`@ScaledMetric var fontSize: CGFloat = 16` scales with user's font preference. Use when Figma value matches Dynamic Type role; emit raw `.font(.system(size: 16))` only inside `@ScaledMetric` wrapper.

---

## 5. Screenshot Cross-Check

### Before implementing a section

1. Open `screenshot.png` at scale 3.
2. Identify the section by visual inspection (header, body, CTA, footer).
3. Cross-reference inventory rows — match each row to a visible element.
4. If an element has no inventory row → return to Step 3 (Visual Inventory) and add it.

### After implementing (Step 6b)

1. Build the screen in Xcode.
2. Run in simulator at the matching device class.
3. Side-by-side compare with `screenshot.png` at 1:1 scale.
4. For every mismatch: identify which inventory row was wrong, fix the inventory row first, then update the code.

### Disagreement handling

| Source disagreement | Resolution |
|---|---|
| `tokens.json` vs inline style | tokens.json wins (it IS the design system) |
| inline style vs Tailwind class | inline wins |
| screenshot vs metadata | screenshot wins (it's the rendered truth) |
| Figma vs production constraint (deployment target, missing font file) | STOP, ask user |

---

## 6. Pre-flight checks

### `Color(hex:)` is not built-in

```swift
extension Color {
    init(hex: String) {
        let scanner = Scanner(string: hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")))
        var hex64: UInt64 = 0
        scanner.scanHexInt64(&hex64)
        let r = Double((hex64 & 0xFF0000) >> 16) / 255
        let g = Double((hex64 & 0x00FF00) >> 8) / 255
        let b = Double(hex64 & 0x0000FF) / 255
        self = Color(red: r, green: g, blue: b)
    }
}
```

Check if project has it; if not, use Asset Catalog or `Color(red: ..., green: ..., blue: ...)` directly.

### iOS deployment target

`IPHONEOS_DEPLOYMENT_TARGET` from `.pbxproj`. Baseline iOS 16+. iOS 17+ APIs (`@Observable`, `.rect(cornerRadius:)`, `.topBarLeading`, `Tab(...)`, `Color(.named)`) require gating or fallback. See [`swiftui-pro-bridge.md`](swiftui-pro-bridge.md) §6 for full table.

### Localization

`.strings` (legacy) or `.xcstrings` (canonical, iOS 16+). If `STRING_CATALOG_GENERATE_SYMBOLS = YES`, emit `Text(.symbolKey)`; else use `LocalizedStringKey` literal form.

### Dark mode

If Figma is light-only → ASK user before C2 starts whether dark variants are needed. Don't assume.

### Placeholder / mockup text

`Lorem ipsum`, `Coming soon`, `[Your text here]`, `Section X` in Figma usually means real copy is missing. ASK user for real copy before C2 starts. Don't ship placeholders.

---

## 7. Hard Rules

1. Every magic number in SwiftUI must trace to a source (tokens, inline style, class, or design-context comment). If you can't trace it, you guessed.
2. Never `.font(.body)` / `.title` / etc. unless design-context maps to iOS text styles. Figma sizes are absolute.
3. Never approximate. 17pt ≠ 16pt. #F5F5F7 ≠ #F5F5F5.
4. Never skip `lineHeight`, `letterSpacing`, `shadow`, `border`, **`textAlign`**, **stack alignment** (both axes). For centered text in fill-width rows: `.multilineTextAlignment(.center)` alone is not enough — the Text needs a fill-width drawing rect. Place `.frame(maxWidth: .infinity)` on the Text if parent is non-Button stack; on Button's OUTER frame if parent is Button — see Rule #14.
5. Always `.buttonStyle(.plain)` on custom-styled buttons.
6. Always set `.renderingMode` explicitly on `Image`.
7. Always specify `VStack(spacing:)` and `.padding(X)` with explicit values.
8. Before saying "done", do screenshot cross-check (§5).
9. **`.frame(width: N)` on Text BANNED** unless Figma `primaryAxisSizingMode === FIXED` AND `// Figma fixed-width: <reason>` comment.
10. **Single-line Text in constrained widths MUST emit `.minimumScaleFactor(0.6)`** alongside `.lineLimit(1)`.
11. **Fill-width/height Image MUST emit `.resizable() + .scaledToFill()/.scaledToFit() + .frame(...)`** together.
12. **Safe-area normalization for mockup frames.** Screen-root `.padding(.top, N)` where N ∈ {44, 47, 59, 64, 67, 79, 88} requires `// safe-area-adjusted: raw=<N+inset>, inset=<inset>, adjusted=<N>` comment.
13. **Device bezel ≠ view corner radius.** Screen-root cornerRadius ≥ 30pt BANNED without `// allow-screen-corner-radius: <reason>` comment.
14. **`.frame(maxWidth: .infinity)` belongs on OUTERMOST view of bounded container — NEVER on inner Text inside Button** without `// allow-text-fill: <reason>`. Maps by Figma button `primaryAxisSizingMode`: FILL → Button outer; FIXED → `.frame(width: N)` on Button outer; AUTO/HUG → no width modifier.
