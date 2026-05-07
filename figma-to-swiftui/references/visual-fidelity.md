# Visual Fidelity Playbook

The process and checklist that makes SwiftUI output match the Figma design. This is the authoritative reference for "make it look like Figma".

This file covers:
1. How to parse `design-context.md` (the MCP response) into exact values
2. Source-of-truth rules when multiple caches disagree
3. The Visual Inventory template (rigorous)
4. SwiftUI defaults that silently break fidelity
5. The screenshot cross-check process

---

## 1. Parsing `design-context.md`

`get_design_context` returns React + Tailwind-ish code plus inline `style` objects. It is a **specification carrier**, not code to port. Extract exact values from it.

### Tailwind class → exact value

Default Tailwind scale (Figma MCP uses this unless the value doesn't match, in which case it uses `[arbitrary]` syntax):

| Class | Value |
|---|---|
| `p-1`, `p-2`, `p-3`, `p-4`, `p-6`, `p-8` | 4, 8, 12, 16, 24, 32pt |
| `gap-1`, `gap-2`, `gap-3`, `gap-4`, `gap-6` | 4, 8, 12, 16, 24pt |
| `text-xs` / `text-sm` / `text-base` / `text-lg` / `text-xl` / `text-2xl` / `text-3xl` | 12 / 14 / 16 / 18 / 20 / 24 / 30pt |
| `font-normal` / `medium` / `semibold` / `bold` | .regular / .medium / .semibold / .bold |
| `rounded` / `-md` / `-lg` / `-xl` / `-2xl` / `-3xl` / `-full` | 4 / 6 / 8 / 12 / 16 / 24 / Capsule |
| `leading-none` / `-tight` / `-snug` / `-normal` / `-relaxed` / `-loose` | 1.0 / 1.25 / 1.375 / 1.5 / 1.625 / 2.0 × fontSize |
| `tracking-tight` / `-normal` / `-wide` | -0.025em / 0 / 0.025em |

### Arbitrary values — take them literally

When Figma values don't match the default scale, MCP emits `[arbitrary]`:
- `p-[17px]` → 17pt padding (not 16)
- `text-[15px]` → 15pt font (not 14 or 16)
- `rounded-[10px]` → 10pt corner radius
- `leading-[22px]` → 22pt line height (absolute, not multiplier)
- `tracking-[-0.32px]` → -0.32pt letter spacing

**Rule: arbitrary values are authoritative. Never round them to the nearest Tailwind default.**

### Color classes

- `bg-white`, `bg-black` → `Color.white`, `Color.black`
- `bg-[#F5F5F5]` → `Color(hex: "F5F5F5")` or matching project color
- `bg-white/50` → `.white.opacity(0.5)`
- `bg-[#000000]/80` → `Color(hex: "000000").opacity(0.8)`
- Tailwind palette (`bg-gray-500`, etc.) → convert via tokens.json if project maps them; otherwise take the hex from the inline style that MCP usually emits alongside.

### Inline style blocks

MCP often emits explicit style objects that override Tailwind. Trust these over class names:

```jsx
style={{
  fontFamily: 'SF Pro Display',
  fontWeight: '600',
  fontSize: '17px',
  lineHeight: '22px',
  letterSpacing: '-0.32px',
  color: '#1C1C1E'
}}
```

Every field here is a value to carry into SwiftUI. **Do not drop fields** because "Font.system handles it by default" — it doesn't.

### Image fill mode (`objectFit` → SwiftUI content mode)

When Figma image fills a container (header banner, card thumbnail, hero), MCP emits the fill mode as inline `objectFit` (mirror of Figma's `imageScaleMode`). Mapping is non-negotiable:

| Figma scaleMode | CSS `objectFit` | SwiftUI |
|---|---|---|
| `FILL` (Figma default for image fills) | `cover` | `.resizable().scaledToFill()` + `.clipped()` |
| `FIT` | `contain` | `.resizable().scaledToFit()` |
| `CROP` (with crop transform) | n/a — pre-cropped | `.resizable().scaledToFill()` + `.clipped()` |
| `TILE` | `repeat` (background-repeat) | `.resizable(resizingMode: .tile)` |
| absent / image is intrinsic-sized | `none` | `Image(...)` no resizable; rely on intrinsic |

**Hard rule:** every fill-width / fill-height image MUST emit `.resizable() + (.scaledToFill()|.scaledToFit()) + .frame(...)` together. Missing any of the three = image renders at intrinsic size and leaves blank space inside the container — the exact bug captured in [`anti-patterns.md` §"Image fill-width missing scaledToFill"](anti-patterns.md). Default when MCP doesn't surface `objectFit`: assume `FILL` (`.scaledToFill()`) — Figma's image-fill default.

### Figma-specific comments

MCP sometimes injects comments like `// Auto layout: vertical, gap 12, padding 16` or `// Fill: linear gradient from #FF0080 to #7928CA`. These are authoritative when present.

---

## 2. Source-of-Truth Priority

When multiple caches disagree on a value:

```
tokens.json  >  inline style in design-context.md  >  Tailwind class in design-context.md  >  screenshot.png (estimate)
```

Rules:
- **tokens.json** wins for anything that has a design token (colors, spacing tokens, typography). If a variable is defined, use it — not the literal hex that happens to be on this frame.
- **Inline style** wins over Tailwind class when both are present (because inline is literal, class may be rounded).
- **Screenshot** is the tiebreaker when context is ambiguous or truncated, AND the final verification surface. Never pull an exact value from the screenshot (reading pixels from a PNG is unreliable) — use it to confirm, not to measure.
- **Code Connect map** (`code-connect.json`) overrides everything for components that have an existing mapping — use the mapped component and let it handle internal values.

---

## 3. Visual Inventory Template (required before Step 6)

For every screen or component, produce this before writing SwiftUI. Keep it in scratch context; do not write it to a file.

```
─────────── CONTAINER ───────────
size:           W x H  (fixed / fill-width / fill-height / hug)
frameSize:      Wf x Hf   [the Figma frame's own W×H — needed to detect mockup chrome]
deviceClass:    iPhone X/11 Pro/12 mini/13 mini (812) | 12/13/14 (844) | 14 Pro/15 Pro (852) | 14 Pro Max/15 Pro Max/16 Pro Max (932) | older (568/667/736) | n/a
safeAreaInsets: top=N, bottom=M     [iOS-rendered chrome; subtract from raw Figma Y before mapping to SwiftUI padding]
mockupChrome:   true | false        [true if frame H matches deviceClass list AND screenshot top region shows status-bar mockup (time "9:41", wifi/battery icons)]
deviceBezel:    true | false        [true if mockupChrome=true AND the frame outline shows ~47–55pt rounded corners on all 4 corners. That curve is the iPhone hardware bezel — NOT a UI corner radius. When true, screen-root MUST set cornerRadius=0 and emit NO `.cornerRadius`/`.clipShape(.rect(cornerRadius:))` on the root view.]
background:     <hex or token>   [source: tokens | inline | class]
cornerRadius:   Xpt              [source — but if `deviceBezel=true` and the value comes from the FRAME outline (not an inner card/sheet), set `0` and add note "device bezel, not UI"]
border:         Xpt, <hex>       [source]
shadow:         color=<rgba>, radius=X, offsetX=X, offsetY=X   [source]
padding:        top=X, leading=X, bottom=X, trailing=X    [if mockupChrome=true, X here is POST-SUBTRACT — raw Figma y minus safeAreaInsets.top; raw value goes in a parenthetical]

─────────── LAYOUT ───────────
type:                       VStack | HStack | ZStack | ScrollView + stack | LazyVGrid | GeometryReader
spacing:                    Xpt
counterAxisAlignItems:      MIN | CENTER | MAX | BASELINE      [Figma metadata; Tailwind "items-*"]
                            → SwiftUI: VStack(alignment: .leading|.center|.trailing) / HStack(alignment: .top|.center|.bottom|.firstTextBaseline)
                              VStack/HStack default IS .center — must override if Figma says MIN/MAX
primaryAxisAlignItems:      MIN | CENTER | MAX | SPACE_BETWEEN  [Figma metadata; Tailwind "justify-*"]
                            → SwiftUI: Spacer() pattern, NOT a stack init param
                              MIN = no Spacer; CENTER = Spacer above + below; MAX = Spacer above; SPACE_BETWEEN = Spacer between every pair
                              For VStack inside fixed-height frame, also need .frame(maxHeight: .infinity)
                              For HStack inside fill-width frame, also need .frame(maxWidth: .infinity)

─────────── ELEMENTS ─────────── (one row per visible element)
[n] <kind> "<label or asset name>"
    position:    index in stack | offset (x,y) for ZStack
    size:        WxH (fixed / hug / fill)
    — if Text:
    font:           family=<name>, size=X, weight=<w>, width=<std|expanded>
    lineHeight:     Xpt absolute  OR  Xx multiplier     [critical — never skip]
    letterSpacing:  X pt
    color:          <hex or token>
    textAlign:      LEFT | CENTER | RIGHT | JUSTIFIED   [Figma textAlignHorizontal — never skip]
                    → SwiftUI: .multilineTextAlignment(.leading|.center|.trailing|.justified)
    frame:          hug | fill-width | fixed-width(W)   [from Figma `primaryAxisSizingMode`: FIXED→fixed-width, AUTO→hug, fill→fill-width. NEVER emit `.frame(width: N)` on Text from a hug-mode node — measured visual width is not a constraint, see §4 Text + §7 rule #9]
    lineCount:      Figma render shows N lines           [used to decide single-line treatment vs wrap]
    lineLimit:      N | none                             [if fill-width single-line OR fixed-width single-line, MUST also emit .minimumScaleFactor(0.6) — see §4 Text + §7 rule #10]
    — if Image/Icon:
    asset:        <name>
    size:         WxH
    frame:        hug | fill-width | fill-height | fill-both | fixed(WxH)
    contentMode:  fill | fit | crop | tile | none       [from Figma imageScaleMode / inline `objectFit`. Default when absent on a fill-* image: FILL — see §1 "Image fill mode"]
    renderingMode: original | template (+ tint color)
    — if Button/Control:
    style:       <variant>
    sizeVariant: small|medium|large
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
- Every visible element from the screenshot must have an entry.
- Every value must have a source tag `[tokens | inline | class | screenshot]`.
- If a field is genuinely unknown, write `[estimate]` — never silently omit.
- `lineHeight`, `letterSpacing`, `shadow`, `border`, **`textAlign`**, **stack alignment (cross + main axis)**, **image `contentMode`**, **container `safeAreaInsets` + `mockupChrome` + `deviceBezel`** are skipped most often. Never skip them if design-context or metadata mentions them. Specifically:
  - Text rows: `textAlign` is LEFT by default in SwiftUI's `.multilineTextAlignment`; if Figma `textAlignHorizontal=CENTER` and you only write `.multilineTextAlignment(.center)`, the text will look **left-aligned** in the simulator because Text shrinks to its intrinsic width. Fix by giving the Text a wider drawing rect — but **place the fill-width frame on the right layer**: on the Text directly when the parent is a non-Button stack; on the Button's OUTER frame when the parent is `Button { ... }`. Putting `.frame(maxWidth: .infinity)` on inner Text inside a Button cascades the fill request up and overrides caller `.padding(.horizontal, N)`. See §4 "`.frame(maxWidth: .infinity)` cascade trap" + §7 Hard Rule #14.
  - Text rows: `frame` MUST come from Figma `primaryAxisSizingMode` (FIXED→fixed-width, AUTO→hug, fill→fill-width). Never invent a `fixed-width` from the rendered visual width — that ships truncation as soon as content grows.
  - Image rows: `contentMode` MUST be present for any non-hug image. Default to `fill` when MCP doesn't surface `objectFit`.
  - Stack rows: VStack/HStack default cross-axis alignment is `.center`. If Figma `counterAxisAlignItems=MIN`, you MUST write `VStack(alignment: .leading)` — the default does NOT match Figma's design.
  - Stack main-axis distribution (`primaryAxisAlignItems` = `CENTER` / `SPACE_BETWEEN` / `MAX`) does NOT map to a stack init param — use Spacer() patterns. Forgetting this stacks children at the top instead of distributing.
  - Container row: `safeAreaInsets` + `mockupChrome` MUST be set BEFORE any Y-coordinate makes it into the inventory. If `mockupChrome=true`, every Y/padding/spacing value in the inventory is the post-subtract value (raw Figma y minus `safeAreaInsets.top`). Skipping this normalization is the exact bug captured in [`anti-patterns.md` §"Y from frame origin double-counts safe area"](anti-patterns.md).
  - Container row: `deviceBezel` MUST be set whenever `mockupChrome=true`. When `deviceBezel=true`, the rounded outline of the entire frame is the iPhone hardware bezel — NOT app UI. The container's `cornerRadius` row MUST be `0` (with a note `// device bezel, not UI`) and the screen-root SwiftUI view MUST NOT carry `.cornerRadius(R)` / `.clipShape(.rect(cornerRadius: R))` / `.clipShape(RoundedRectangle(cornerRadius: R))`. Forgetting this is the exact bug captured in [`anti-patterns.md` §"Phone bezel mistaken for view corner radius"](anti-patterns.md).
- If Figma uses `Expanded` or `Condensed` width, record it — SwiftUI needs `.fontWidth(.expanded)`, not just weight.

### Source-tag → swiftui-pro routing

Each source tag implies a different routing decision in C2 codegen. Refer to `swiftui-pro-bridge.md` §3 for the full project-context decision tree.

| Tag | Source | Example value | swiftui-pro route (project baseline: `Spacing` / `IKFont` / `IKCoreApp` enums + iOS 16) |
|---|---|---|---|
| `tokens` | Figma variable in `tokens.json` | `--text-primary` | `IKCoreApp.colors.textPrimary` (preferred); else `Color(.textPrimary)` if `useGeneratedSymbols`; else `Color("textPrimary")` |
| `inline` | Figma node style in design-context | `font-weight: 700` | swiftui-pro transform — `.bold()` (api.md L3, design.md L27). Never `.fontWeight(.bold)`. |
| `inline` | spacing literal `padding: 24` | `24pt` | `Spacing.l24` if a matching token exists; else inline `.padding(24)` (compliant — value is specifically requested). |
| `inline` | typography literal `font-size: 16` | `16pt body` | If matches Dynamic Type role → `.font(.body)`. Else if `IKFont.<token>` matches → use it. Else `@ScaledMetric var fontSize: CGFloat = 16` + `.font(.system(size: fontSize, weight: .regular))`. Never inline `.font(.system(size: 16))` without `@ScaledMetric`. |
| `inline` | color literal `#FF6600` | hex | `IKCoreApp.colors.<token>` if matches; else `Color(.brandOrange)` if `useGeneratedSymbols` and asset exists; else `Color(hex: "#FF6600")` if `Color(hex:)` extension; else `Color(red:green:blue:)` with `// TODO` comment. |
| `class` | Tailwind class on Figma component | shared button class | Reuse via project's existing `ButtonStyle` (audit C1). Never re-implement. |
| `screenshot` | Visual measurement (estimate) | spacing ~24pt | Same routing as `inline` literal (token first, then inline). Mark `[estimate]` in inventory; ask user to verify if the design-system enum value differs by > 4pt. |

When the chosen route is "inline literal" (no token match), record a one-line note in the run summary so the user knows where the design system might want a new token added (no auto-edit of `Spacing`/`IKFont`/`IKCoreApp` — surface, don't mutate).

---

## 4. SwiftUI Defaults That Break Fidelity

These are the silent killers. Watch for each:

### Text
- `.font(.system(size: X))` has its own default line height (~1.17×). Figma `line-height: Xpx` rarely matches. Use `.lineSpacing(Y)` where `Y = lineHeight - fontSize`, then cancel SwiftUI's default with `.padding(.vertical, -((Y)/2))` if it over-pads. Alternative: wrap in a `Text` with explicit frame + `.lineSpacing`.
- Default letter spacing ≠ 0. Figma `letter-spacing: -0.32px` must be applied via `.tracking(-0.32)` or `.kerning(-0.32)`. They differ — `.kerning` applies between all chars, `.tracking` respects font ligatures. Prefer `.tracking`.
- `Text` ignores leading whitespace / truncates differently than Figma at narrow widths — test with real content length.
- **Alignment requires width — but maxWidth lives on the OUTERMOST container, not inner Text.** `.multilineTextAlignment(.center)` only affects how lines align *within* the Text's drawing rect. A single-line Text inside an HStack/VStack hugs its intrinsic width by default — so centered text appears left-aligned because the rect IS the text's width. To visually center inside a wider container, the Text needs a wider drawing rect. Two cases:
  - **Parent is a non-Button stack (VStack/HStack/ZStack/screen-root):** emit `.frame(maxWidth: .infinity, alignment: .center)` ON THE TEXT. The maxWidth pushes the Text to fill the parent stack's available width; the parent already fills its own slot.
  - **Parent is a `Button { ... }`:** emit `.frame(maxWidth: .infinity)` ON THE BUTTON's OUTER frame, NOT on inner Text or inner HStack. Text stays at intrinsic (no maxWidth modifier). See §"`.frame(maxWidth: .infinity)` cascade trap" below for why — and see Figma `primaryAxisSizingMode` mapping for buttons in [`layout-translation.md` §"Button sizing-mode → SwiftUI"](layout-translation.md).

  Figma's `textAlignHorizontal: CENTER` on a fill-width text node implies BOTH `.multilineTextAlignment(.center)` AND a fill-width drawing rect. The fill-width drawing rect comes from the Text's `.frame(maxWidth: .infinity)` (case 1) OR from the Button's outer frame propagating down (case 2). Pick the right layer; do not stack both.
- **`.frame(width: N)` on Text is BANNED by default.** Reading the rendered visual width from Figma metadata and emitting `.frame(width: 200)` on a `Text(...)` ships truncation the moment content grows — localized strings, longer dynamic data, large Dynamic Type. Mapping by Figma sizing mode (mirror in §3 inventory `frame:` row):

  | Figma `primaryAxisSizingMode` | Figma render lines | SwiftUI |
  |---|---|---|
  | AUTO (hug), 1 line | 1 | no `.frame` width modifier |
  | AUTO (hug), ≥2 lines | ≥2 | no `.frame` width modifier |
  | fill (parent constrains width), 1 line | 1 | `.frame(maxWidth: .infinity, alignment:)` + `.lineLimit(1)` + `.minimumScaleFactor(0.6)` |
  | fill, ≥2 lines | ≥2 | `.frame(maxWidth: .infinity, alignment:)` (let wrap; no `.lineLimit` cap, no `.minimumScaleFactor`) |
  | FIXED (justified by designer, e.g. badge cell) | any | `.frame(width: X).fixedSize(horizontal: false, vertical: true)` + comment `// Figma fixed-width: <reason>`; if 1-line, also `.minimumScaleFactor(0.6)` |

  `.fixedSize(horizontal: false, vertical: true)` lets the Text wrap to multiple lines when content overflows instead of truncating into ellipsis. **Default for Text is hug (no frame) or fill (`maxWidth: .infinity`) — never numeric `width`.**

  **Parent-aware exception for the `fill` rows.** When the Text's parent in the SwiftUI tree is a `Button { ... }`, the maxWidth must NOT go on the Text — it cascades up through the Button and overrides caller padding. Move the `.frame(maxWidth: .infinity)` to the Button's outer frame instead, and emit the Text without any width modifier (intrinsic / hug). The Button's outer frame propagates the fill-width drawing rect down to the Text for free, so `.multilineTextAlignment(.center)` still works as expected. See §"`.frame(maxWidth: .infinity)` cascade trap" + Hard Rule #14.
- **`.minimumScaleFactor(0.6)` on single-line Text in constrained widths.** Any Text with `.lineLimit(1)` (or visually single-line in Figma but inside a fill-width / fixed-width container) MUST carry `.minimumScaleFactor(0.6)`. Otherwise localized strings (German, Russian) and long dynamic data truncate to ellipsis — visually worse than a slightly-shrunk readable line. The 0.6 floor is a fidelity-vs-robustness trade: shrink up to 40% before truncating. Multi-line Text wraps naturally and does NOT take `.minimumScaleFactor` (wrapping is the right escape valve for multi-line copy).

### `.frame(maxWidth: .infinity)` cascade trap

`.frame(maxWidth: .infinity)` requests "fill all available width from my parent". SwiftUI propagates that request **outward**: the Text asks for fill, the HStack containing it must offer fill, the Button containing the HStack must offer fill, the screen-root must offer fill. A `maxWidth: .infinity` placed on a leaf view stretches every ancestor that doesn't impose its own width.

**The bug.** Skill output frequently emits `Text(...).frame(maxWidth: .infinity)` inside a Button to fix the "centered text reads as left-aligned" problem (see §Text "Alignment requires width"). When the Button is supposed to be ~343pt wide on a 393pt iPhone (caller wraps in `.padding(.horizontal, 16)`), the inner Text's maxWidth propagates up through the Button, the Button asks for the full screen width, and SwiftUI gives it to it — the caller's horizontal padding lands on a fill-width child, leaving zero margin. Visual result: button extends edge-to-edge, ignoring the designer's 16pt side margins. Figma showed a 343pt button; simulator shows a 393pt button.

**The rule — `.frame(maxWidth: .infinity)` belongs on the OUTERMOST view of the bounded container, never on inner descendants of a Button.**

| Where the maxWidth lives | Effect | Use when |
|---|---|---|
| On the Button's OUTER frame: `Button { Text("...") }.frame(maxWidth: .infinity)` | Button fills its parent's slot; Text centers inside the Button's drawing rect via SwiftUI's default centering. Caller's `.padding(.horizontal)` works correctly because the Button (not its child) is the fill-width view. | Figma button `primaryAxisSizingMode: FILL` (button fills its row container). |
| On a screen-root VStack / fill-width Card: `VStack { ... }.frame(maxWidth: .infinity)` | The container fills its slot; children inside hug or fill as their own modifiers say. | Screen-root content area, fill-width cards. |
| On inner Text or inner HStack INSIDE a Button | **CASCADES UP through Button.** Button itself fills width even if you intended Button to hug or be fixed-width. Caller padding is overridden. **BANNED.** | Never — except with `// allow-text-fill: <reason>` (rare; usually HStack+Spacer is cleaner). |
| Stacking BOTH (Button outer maxWidth AND inner Text maxWidth) | Same visual as Button-only (already fills); the inner modifier is dead weight. | Never — pick one layer. |

**By Figma `primaryAxisSizingMode` on the Button node:**

| Figma button sizing | SwiftUI |
|---|---|
| `FILL` (button fills its row container — most common for primary CTAs) | `Button { Text("...") }.frame(maxWidth: .infinity)` on Button outer; **no** maxWidth on inner Text |
| `FIXED` (designer set explicit width N) | `Button { Text("...") }.frame(width: N)` on Button outer; no width modifier on inner Text |
| `AUTO/HUG` (button hugs its label — chip / tag / pill) | `Button { Text("...") }` — no width modifier; let Button intrinsic-size to label |

**Patterns for asymmetric button content** (icon + label that need to push to opposite edges):

```swift
// CORRECT — Button fills, HStack inside uses Spacer to push apart
Button(action: tapped) {
  HStack(spacing: 0) {
    Text("Continue")
    Spacer()                  // pushes Image to trailing edge
    Image("icAIArrowRight")
  }
}
.frame(maxWidth: .infinity)   // Button outer fills caller slot
.padding(.vertical, 12)
.background(Color.accent, in: .rect(cornerRadius: 8))
.padding(.horizontal, 16)     // caller margin — works because Button is the fill-width view
```

```swift
// WRONG — Text maxWidth cascades up, .padding(.horizontal, 16) is bypassed
Button(action: tapped) {
  HStack(spacing: 0) {
    Text("Continue").frame(maxWidth: .infinity)  // BANNED: cascades to Button
    Image("icAIArrowRight")
  }
}
.padding(.horizontal, 16)     // bypassed — Button already filled the screen
```

**Allow-list.** A `Text(...).frame(maxWidth: .infinity)` inside `Button { ... }` requires a justifying comment `// allow-text-fill: <reason>` on the same line OR the line above. Legitimate cases are rare; before adding the comment, check whether `HStack { Spacer(); ...; Spacer() }` accomplishes the same intent without the cascade. Enforced by `figma-to-swiftui-banned-pattern-gate.sh` Check 8.

**Symmetric trap on the height axis.** `.frame(maxHeight: .infinity)` cascades the same way through vertical containers. Less common in Figma-to-SwiftUI runs (most screens are bounded vertically by ScrollView), but the rule is identical: maxHeight goes on the outermost bounded container, not on inner Text inside a Card or inner Card inside a Button-styled tappable row.

### Stack alignment
- **Cross-axis (`alignment:` init param) defaults to `.center`**, NOT `.leading`. Figma `counterAxisAlignItems = MIN` ⇒ explicitly write `VStack(alignment: .leading)` / `HStack(alignment: .top)`. Skipping the param silently centers — looks "wrong" only at the simulator stage.
- **Main-axis distribution has NO init param.** Figma `primaryAxisAlignItems = CENTER | MAX | SPACE_BETWEEN` does NOT translate to `VStack(...)` arguments. You build it with Spacers:
  - `MIN` (start) → no Spacer (default — children pack at top/leading)
  - `CENTER` → `Spacer()` above and below the children block
  - `MAX` (end) → `Spacer()` above the children block
  - `SPACE_BETWEEN` → `Spacer()` between every adjacent pair
- **Distribution requires the parent to fill its axis.** A `VStack { Spacer(); Text(); Spacer() }` inside a hugging container does nothing — the Spacers collapse to zero. Centering / SPACE_BETWEEN only works when the stack itself fills the axis: pair with `.frame(maxHeight: .infinity)` (VStack) or `.frame(maxWidth: .infinity)` (HStack), or place inside a parent that already forces fill (GeometryReader, screen-root VStack with `.frame(maxHeight: .infinity)`, etc.).
- **HStack with one Text child** that should be center-aligned in the row: use `HStack { Spacer(); Text("..."); Spacer() }` OR `Text("...").frame(maxWidth: .infinity, alignment: .center)`. Both work; pick one and stay consistent within a screen.

### Button
- A plain `Button("Label") { }` applies system button styling (blue foreground, press animation, implicit padding in some contexts). Wrap in `.buttonStyle(.plain)` when Figma button is custom-styled.
- `.plain` removes ALL styling — you must re-add background, padding, foreground manually.

### Image
- Assets default to `.renderingMode(.original)` unless the asset catalog is set to template. When the icon should tint with foreground color, set `.renderingMode(.template)` + `.foregroundStyle(...)`.
- `.resizable()` is required for any non-SF-Symbol image you want to size. Without it, size is intrinsic.
- **Fill-width / fill-height image MUST emit all three modifiers together** — `.resizable() + (.scaledToFill()|.scaledToFit()) + .frame(...)`. Missing any of the three:
  - no `.resizable()` → image stays at intrinsic pt size; `.frame(maxWidth: .infinity)` reserves space the image refuses to fill → blank gap.
  - no content mode → resized image stretches anisotropically (squashed / elongated).
  - no `.frame(...)` → resizable image shrinks to its intrinsic minimum.
  Mapping (mirror in §3 inventory `contentMode:` row, derived from Figma `imageScaleMode` / inline `objectFit`):

  | Figma scaleMode | Inline `objectFit` | SwiftUI |
  |---|---|---|
  | `FILL` (Figma image-fill default) | `cover` | `.resizable().scaledToFill().frame(maxWidth: .infinity, ...).clipped()` |
  | `FIT` | `contain` | `.resizable().scaledToFit().frame(maxWidth: .infinity, ...)` |
  | `CROP` (with crop transform) | n/a | same as FILL — pre-cropped raster, `.scaledToFill().clipped()` |
  | `TILE` | `repeat` | `.resizable(resizingMode: .tile).frame(...)` |
  | absent / hug image | `none` | `Image(...)` no `.resizable`, no `.frame` — intrinsic |

  Default when MCP doesn't expose `objectFit`/scaleMode AND the image fills its parent: assume `FILL`. Figma's image-fill default is FILL; the agent's instinct to skip `.scaledToFill()` ("the frame is enough") is the bug.

### Safe area & spacing normalization

Figma frames for iPhone screens almost always include the **mockup chrome** drawn over the canvas: a status bar (~44–59pt at top, time "9:41" + signal/wifi/battery icons or Dynamic Island) and a home indicator (~34pt at bottom, ~134×5pt capsule). These pixels are NOT content — iOS renders them. The `Visual Inventory CONTAINER` section captures them via `safeAreaInsets` + `mockupChrome`; SwiftUI views also live INSIDE the safe area by default.

**The double-count bug:** agent reads a view's Y from Figma metadata as `y=64` (`44 chrome + 20 actual gap`), emits `.padding(.top, 64)`. SwiftUI's default safe-area inset adds another 44pt on top. Visual gap on device = 44 + 64 = 108pt. The view sits 64pt too low.

**The fix — normalize before mapping:**
1. Detect mockup chrome. Frame H ∈ {568, 667, 736, 812, 844, 852, 896, 926, 932} → iPhone full-device height → `mockupChrome=true`. See [`layout-translation.md` §"Safe Area Normalization for Mockup Frames"](layout-translation.md) for the full device→inset table.
2. Subtract `safeAreaInsets.top` from every raw Figma Y before recording it in inventory. Same for bottom: subtract `safeAreaInsets.bottom` from values measured from frame bottom.
3. SwiftUI `.padding(.top, X)` is RELATIVE to the safe-area-top inset, not the frame origin. `Spacer().frame(height: X)` between the screen-root and the first content child is the same.
4. For content that genuinely extends behind the status bar (hero gradient banner, full-bleed image): apply `.ignoresSafeArea(edges: .top)` to the **background layer only** — never to the content layer (text/buttons would be hidden under the status bar).

**Suspicious values that almost always indicate the bug:** `.padding(.top, 44)`, `.padding(.top, 47)`, `.padding(.top, 59)`, `.padding(.top, 64)`, `.padding(.top, 67)`, `.padding(.top, 79)`, `.padding(.top, 88)` at screen-root level. Each MUST carry a comment `// safe-area-adjusted: raw figma y=<N+inset>, inset=<inset>, adjusted=<N>` if the value is intentional. Otherwise it's the double-count.

### Device bezel ≠ view corner radius

The same Figma frames also draw the **iPhone bezel** — the rounded outline of the physical phone body, ~47–55pt radius on all 4 corners. This is hardware, not UI:

| iPhone class | Approximate bezel radius |
|---|---|
| iPhone X / 11 / 12 / 13 / 14 / 15 | ~47pt |
| iPhone 14 Pro / 15 Pro / 16 Pro / Pro Max | ~55pt |
| Older (SE, 8, etc.) | 0 (square corners) |

**The bug:** agent reads the rounded outline of the whole frame in the screenshot, decides "the screen has rounded corners", emits `.cornerRadius(47)` / `.clipShape(.rect(cornerRadius: 47))` / `.clipShape(RoundedRectangle(cornerRadius: 47))` on the screen-root view. In the simulator (and on device) this clips the app view to a smaller rounded rect *inside* an already-rounded device, producing a visible "double bezel" — a black/transparent gutter all four edges, content cut off near the corners. Exactly the failure mode in the user's screenshot.

**The fix — never apply corner radius to the screen-root.** A SwiftUI screen view runs edge-to-edge on every iPhone; the hardware/system rounds the outer corners for free. Only inner cards, sheets, buttons, and badges take a corner radius — and those values come from the design tokens or inline styles of *those specific nodes*, not from the frame outline.

**Suspicious values that almost always indicate the bug:** any `.cornerRadius(N)`, `.clipShape(.rect(cornerRadius: N))`, `.clipShape(RoundedRectangle(cornerRadius: N))` with `N ≥ 30` applied at the **outermost** view of a `*Screen.swift` file. UI cards rarely exceed 24pt; bezel-class radii (30+) at screen-root almost always trace back to "I copied the frame outline".

**Allowed exceptions** (each must carry `// allow-screen-corner-radius: <reason>`):
- A modal sheet or presented half-screen card whose Figma node IS a rounded container (not the device frame).
- A custom in-app "card-style" route presentation where the design genuinely shows rounded corners *inside* the safe area (rare — usually achieved with `.presentationDetents` / `.sheet` modifiers, not by clipping the root).

### Padding & Spacing
- `.padding()` with no argument uses system default (~16pt). Always specify: `.padding(16)`.
- SwiftUI `VStack` spacing default is ~8pt. Always specify: `VStack(spacing: 0)` if no gap.
- Applying `.padding` AFTER `.background` vs BEFORE changes result. Figma inner padding = `.padding` first, then `.background`.

### Shape / Background
- `.background(Color.X)` extends behind the full frame. To clip with radius: `.background(Color.X, in: RoundedRectangle(cornerRadius: R))` or `.background(Color.X).clipShape(.rect(cornerRadius: R))`.
- `.cornerRadius(R)` is deprecated — use `.clipShape(.rect(cornerRadius: R))`.
- A `Rectangle().fill(...)` does NOT include a stroke — add `.overlay { RoundedRectangle(...).stroke(...) }` for borders.

### Shadow
- `.shadow(radius: R)` defaults to black at 33% opacity. Figma shadows are rarely this. Use full form: `.shadow(color: .black.opacity(0.1), radius: R, x: X, y: Y)`.
- Shadow blur radius in Figma ≠ SwiftUI radius 1:1 — Figma blur is Gaussian σ, SwiftUI `radius` is similar but tuning may be needed. Start with exact match; adjust if shadow is too hard/soft.

### Lists & Forms
- `List` adds section insets, row separators, and a form-like background. For a plain stack-of-rows that matches Figma, use `ScrollView { LazyVStack { ... } }` instead of `List`.
- `.listStyle(.plain)` removes some styling but not all. When Figma shows a flat list, prefer `LazyVStack`.

### NavigationStack
- Adds large title padding by default. Use `.navigationBarTitleDisplayMode(.inline)` when Figma header is compact, or `.toolbar(.hidden, for: .navigationBar)` for fully custom headers.
- Adds a back button and safe-area insets automatically. Factor these into layout.

### Font width / tracking (iOS 16+)
- Figma "Expanded Semibold" = `.fontWeight(.semibold).fontWidth(.expanded)`. Using only `.semibold` loses the expanded width.
- Figma "Condensed" = `.fontWidth(.condensed)`.

### Dynamic Type
- `.font(.body)` scales with user settings. For Figma's exact pt size, use `.font(.system(size: X))` — but this loses Dynamic Type. For pixel-match + DT, use `@ScaledMetric`.
- If the user's goal is strict fidelity, prefer fixed sizes. Document the tradeoff.

---

## 5. Screenshot Cross-Check

The screenshot is the final arbiter. Use it actively.

This section provides the underlying checklist; the executable procedure that produces a verifiable diff report (and the gates that catch report bugs) lives in `references/verification-loop.md`. The bullet codes below (LH, LS, ...) are the canonical names used by that report.

> **Confirmation bias is the #1 reason visual diffs get missed.** Always run the free-form "what's wrong" pass FIRST — before any structured analysis. Once a row reads PASS, every subsequent row biases toward PASS. The 6-step procedure in [`verification-loop.md` §C5.6](verification-loop.md#c56--side-by-side-compare-6-step-procedure-mandatory) is built around this — section inventory, element census, per-section crop pairs, free-form pass, 3-axis diff table, negative spot-check, 4-anchor proportional check, attestation. Do not duplicate that procedure here; defer to it.

### Before implementing a section
1. Look at `screenshot.png`.
2. **Identify & strip iOS system chrome first.** The frame often includes a mockup of status bar (time "9:41", Dynamic Island, signal/wifi/battery), home indicator (~134×5pt bar at bottom), **and the rounded outline of the iPhone body itself (~47–55pt corner radius on all 4 corners — that's the physical bezel, not a UI radius)**. None of these are content — iOS / hardware renders them. Do not inventory them, do not code them, **do not apply `.cornerRadius` / `.clipShape(.rect(cornerRadius:))` to the screen-root view to mimic the bezel**. See SKILL.md **ABSOLUTE RULE — Do NOT draw iOS system chrome**.
3. Mentally zoom to the section you're about to implement.
4. Note anything the design-context didn't mention (subtle gradients, blur, inner shadows, overlapping elements, opacity layers).
5. Add missing items to the Visual Inventory.

### After implementing (Step 6b)
1. Re-open `screenshot.png` in your mind.
2. Go through the implemented code top-down.
3. For each `.padding`, `.spacing`, `.font`, `.foregroundStyle`, `.background`, `.frame`, `.shadow` — ask: "does this match what I see?"
4. Special scan for commonly-missed items (the canonical 18 checks — every C3 Pass 2 report row cites one of these codes):
   - [ ] **LH** Line height (if Text has multi-line content)
   - [ ] **LS** Letter spacing / tracking
   - [ ] **SH** Inner shadow / outer shadow
   - [ ] **BD** Border + radius combined
   - [ ] **OP** Opacity on sub-elements
   - [ ] **RM** Icon rendering mode (tint vs original)
   - [ ] **IS** Icon exact pixel size (not just "small")
   - [ ] **AL** Text alignment + fill-width frame pairing (Figma `textAlignHorizontal=CENTER|RIGHT|JUSTIFIED` on a fill-width text node ⇒ code MUST emit BOTH `.multilineTextAlignment(...)` AND a fill-width drawing rect. The fill-width drawing rect comes from `.frame(maxWidth: .infinity, alignment: ...)` on the Text **when the parent is a non-Button stack**, OR from `.frame(maxWidth: .infinity)` on the Button's OUTER frame **when the parent is `Button { ... }`**. Inner-Text maxWidth inside a Button cascades up and overrides caller padding — banned without `// allow-text-fill: <reason>`. `.multilineTextAlignment` alone hugs the Text to intrinsic width — visually reads as left-aligned. Container stack alignment also lives here: Figma `counterAxisAlignItems=MIN` ⇒ explicit `VStack(alignment: .leading)` because SwiftUI's default cross-axis is `.center`.)
   - [ ] **BW** Button-width source-of-truth (every Button's WIDTH MUST come from the Button's OWN Figma `primaryAxisSizingMode`: `FILL` ⇒ `.frame(maxWidth: .infinity)` on Button outer; `FIXED` ⇒ `.frame(width: N)` on Button outer; `AUTO/HUG` ⇒ no width modifier. Inner Text/HStack inside the Button must NOT carry `.frame(maxWidth: .infinity)` — that cascades and bloats the button. See §"`.frame(maxWidth: .infinity)` cascade trap" + §7 Hard Rule #14.)
   - [ ] **DV** Divider color / opacity / height
   - [ ] **BG** Background material (blur) behind text
   - [ ] **TR** Text truncation / line limit
   - [ ] **GR** Gradient direction (top→bottom vs diagonal)
   - [ ] **SA** Safe area behavior (does bg extend under status bar?)
   - [ ] **CH** No system chrome drawn — no "9:41", no wifi/battery SF Symbols, no `Capsule`/`RoundedRectangle` at (~134×5) pretending to be the home indicator, **and no `.cornerRadius(R)` / `.clipShape(.rect(cornerRadius: R))` / `.clipShape(RoundedRectangle(cornerRadius: R))` with `R ≥ 30` on the screen-root view (that's the iPhone bezel mockup, not a UI radius — see §4 "Device bezel ≠ view corner radius")**. iOS / hardware renders all of these.
   - [ ] **PD** Explicit padding / spacing (no SwiftUI defaults — see Hard Rules §7 #7)
   - [ ] **BS** `.buttonStyle(.plain)` on custom-styled buttons (Hard Rules §7 #5)
   - [ ] **IF** Image fill mode (Figma `imageScaleMode` → `.resizable() + .scaledToFill()/.scaledToFit() + .frame(...)` — all three together. Missing any → blank gap or distortion. See §1 "Image fill mode" + §4 Image.)
   - [ ] **SS** Spacing-Safe-area normalization (`mockupChrome=true` frames: every screen-root `.padding(.top, N)` / `Spacer().frame(height: N)` must use `N = raw_figma_y - safeAreaInsets.top`, not raw `y`. Common bug: `.padding(.top, 44|47|59|64|67|79|88)` without `// safe-area-adjusted` comment = double-count. See §4 "Safe area & spacing normalization".)

### Disagreement handling
When code reflects inventory correctly but doesn't look right against the screenshot:
- The inventory is wrong. Re-parse design-context.
- Or the screenshot shows something design-context didn't specify. Add it.
- Never "tweak until it looks right" without tracing the source.

---

## 6. Common pre-flight checks

Before writing SwiftUI that references tokens/APIs, confirm the project supports them.

### `Color(hex:)` is not built-in

SwiftUI has no `Color(hex: "FF0080")` initializer. Every project that uses one has defined an extension. Before generating code:

1. Grep the project for `extension Color` or `Color(hex:` — confirm an extension exists.
2. If it exists, use it verbatim (match the signature — some take `String`, some take `UInt`, some support alpha as a separate param).
3. If it doesn't exist, use one of:
   - Asset Catalog named color: `Color("accentPrimary")` — preferred, supports dark mode
   - RGB initializer: `Color(red: 1.0, green: 0.0, blue: 0.5)` — decimal 0-1 values
   - System color: `.accentColor`, `.primary`, `.secondary` when semantic

Never leave `Color(hex:)` in code if the extension isn't defined — it won't compile.

### iOS deployment target

Before using any of these modifiers, check the project's deployment target (`IPHONEOS_DEPLOYMENT_TARGET` in `.xcodeproj`, or `platforms:` in `Package.swift`):

| API | Minimum iOS |
|---|---|
| `.scrollTargetBehavior`, `.scrollTransition`, `containerRelativeFrame`, `@Observable`, `Grid` | iOS 17 |
| `.onScrollGeometryChange`, `.scrollPosition`, `@Entry` | iOS 18 |
| `.glassEffect`, Liquid Glass | iOS 26 |
| `NavigationStack`, `NavigationPath` | iOS 16 |
| `ViewThatFits`, `AnyLayout`, `Grid` | iOS 16 |
| `.fontWidth(.expanded/.condensed)`, `.tracking` | iOS 16 |

If project target is lower, use the older equivalent (e.g. iOS 16 use `LazyVGrid` instead of `Grid`, `NavigationView` only when target <16).

### Localization

Figma strings → `Text("localizable_key")` using `LocalizedStringKey`, not hardcoded strings, unless the project is explicitly single-locale.

- Default `Text("...")` parameter is `LocalizedStringKey` — string literals are auto-localized through `Localizable.strings` / `.xcstrings`.
- When the string is dynamic data (user content, API response), use `Text(verbatim:)` to skip localization lookup.
- Check the project for existing `.strings` / `.xcstrings` files. If present, add new keys there. If absent and the project has multiple feature folders, ask the user about localization strategy.

### Dark mode

- **If Figma provides both light + dark variants** for a frame: fetch both (call `get_screenshot` on each variant node), add both to the cache, and use Asset Catalog "Any / Dark" appearances for colors and images.
- **If Figma provides light only:** ask the user whether dark mode is in scope. If yes, use Asset Catalog semantic colors that auto-adapt (iOS system grays, or named colors with both appearances) — don't hardcode hex that looks wrong in dark. If dark is out of scope, still use Asset Catalog colors so dark mode doesn't render completely broken.
- For images with a dark variant: Contents.json `appearances` entry (see references/asset-handling.md §5).
- For template icons: tint with a semantic color (`.foregroundStyle(Color.textPrimary)`) — it adapts for free.

### Placeholder / mockup text

Figma frequently contains placeholder copy: `Lorem ipsum...`, `Body text`, `Title`, `Placeholder`, `Sample text`, `Username`, `example@email.com`, `$0.00`. If you copy this into SwiftUI as `Text("Lorem ipsum")`, placeholder content ships.

Rule:
- Detect these patterns in the Visual Inventory. Flag each with `[PLACEHOLDER]`.
- In code, either: (a) ask the user for real copy, (b) bind to a model property (`Text(viewModel.title)`) with a TODO, (c) use a short semantic localizable key (`Text("profile.title")`).
- Never ship `Text("Lorem ipsum dolor sit amet")` literal.

---

## 7. Hard Rules

1. Every magic number in SwiftUI code must be traceable to a source (tokens, inline style, class, or design-context comment). If you can't trace it, you guessed.
2. Never use `.font(.body)` / `.title` / etc. unless the design-context explicitly maps to iOS text styles. Figma sizes are absolute.
3. Never approximate. 17pt is not 16pt. #F5F5F7 is not #F5F5F5.
4. Never skip `lineHeight`, `letterSpacing`, `shadow`, `border`, **`textAlign`**, **stack alignment** (`primaryAxisAlignItems` + `counterAxisAlignItems` from Figma metadata) when design-context or metadata specifies them. For centered text inside fill-width rows, `.multilineTextAlignment(.center)` alone is not enough — the Text needs a fill-width drawing rect. Place the `.frame(maxWidth: .infinity, alignment: .center)` on the Text **only if the parent is a non-Button stack**. If the parent is a `Button { ... }`, place `.frame(maxWidth: .infinity)` on the Button's outer frame instead — see Hard Rule #14 + §"`.frame(maxWidth: .infinity)` cascade trap".
5. Always set `.buttonStyle(.plain)` on custom-styled buttons to disable system styling.
6. Always set `.renderingMode` explicitly on `Image` — don't rely on the asset catalog default.
7. Always specify `VStack(spacing:)` and `.padding(X)` with explicit values — never rely on SwiftUI defaults.
8. Before saying "done", do the screenshot cross-check in Section 5.
9. **`.frame(width: N)` on Text is BANNED** unless Figma `primaryAxisSizingMode === FIXED` AND a justifying `// Figma fixed-width: <reason>` comment is on the line above OR the same line. Default for Text is hug (no frame) or fill-width (`maxWidth: .infinity`). Reading Figma's measured visual width on a hug-mode node and emitting `.frame(width: 200)` ships truncation as soon as content grows. See §4 Text + the sizing-mode → modifier table.
10. **Single-line Text in a constrained-width container MUST emit `.minimumScaleFactor(0.6)`** alongside `.lineLimit(1)`. Constrained = fill-width frame, fixed-width frame, button label, badge cell, header title — anywhere wrapping isn't the desired escape valve. The 0.6 floor lets localized strings (German, Russian, Vietnamese diacritics) and longer dynamic data shrink to fit instead of truncating to ellipsis. Multi-line Text wraps naturally and does NOT take `.minimumScaleFactor`.
11. **Fill-width / fill-height Image MUST emit `.resizable() + .scaledToFill()/.scaledToFit() + .frame(...)` together.** Missing `.resizable()` = blank gap. Missing content mode = anisotropic stretch. Missing `.frame(...)` = intrinsic shrink. Default content mode when `objectFit` is absent: `.scaledToFill()` (Figma's image-fill default). See §4 Image + the Figma scaleMode → SwiftUI table.
12. **Safe-area normalization for mockup frames.** When `mockupChrome=true` in inventory CONTAINER: every Y position recorded in inventory + every screen-root `.padding(.top, N)` / `Spacer().frame(height: N)` MUST be `N = raw_figma_y - safeAreaInsets.top`. Suspicious values (44/47/59/64/67/79/88) at screen-root require `// safe-area-adjusted: raw=<N+inset>, inset=<inset>, adjusted=<N>` comment. Same on bottom for home indicator. See §4 "Safe area & spacing normalization" + [`layout-translation.md` §"Safe Area Normalization"](layout-translation.md).
13. **Device bezel is NOT a UI corner radius.** When `deviceBezel=true` in inventory CONTAINER (frame H matches an iPhone full-device class AND outline shows ~47–55pt rounded corners): the screen-root view MUST NOT carry `.cornerRadius(R)` / `.clipShape(.rect(cornerRadius: R))` / `.clipShape(RoundedRectangle(cornerRadius: R))`. The hardware/system clips the outer corners for free; clipping again produces a visible "double bezel" gutter on device. `R ≥ 30` at screen-root level is BANNED unless a `// allow-screen-corner-radius: <reason>` comment justifies it (rare — modal sheets / presented half-screens with a Figma-specified inner-card radius). See §4 "Device bezel ≠ view corner radius" + [`anti-patterns.md` §"Phone bezel mistaken for view corner radius"](anti-patterns.md).
14. **`.frame(maxWidth: .infinity)` belongs on the OUTERMOST view of the bounded container — NOT on inner Text inside a Button.** SwiftUI propagates fill-width requests outward; a Text asking for fill makes the surrounding Button fill, overriding the caller's `.padding(.horizontal, N)`. Mapping by Figma `primaryAxisSizingMode` of the Button node: `FILL` → `.frame(maxWidth: .infinity)` on Button outer; `FIXED` → `.frame(width: N)` on Button outer; `AUTO/HUG` → no width modifier (let Button intrinsic-size). Inner Text NEVER takes `maxWidth: .infinity` inside a Button without `// allow-text-fill: <reason>`. Same rule applies symmetrically to `.frame(maxHeight: .infinity)` cascading through vertical bounded containers. See §4 "`.frame(maxWidth: .infinity)` cascade trap" + [`anti-patterns.md` §"Button bloated by inner Text maxWidth"](anti-patterns.md).
