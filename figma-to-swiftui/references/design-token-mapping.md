# Figma Design Tokens to SwiftUI Mapping

How to translate Figma variables into a SwiftUI design system. **Phase A3 calls `figma_extract_tokens` once per `fileKey`** and writes the structured JSON to `tokens.json` — this file already has the SwiftUI naming applied (`primary500`, `textPrimary`, `headingLarge`, …) plus `lightHex`/`darkHex` for color modes and `isCapsule` for radius. The rules below describe the mapping the tool already performs and the project-specific judgment the skill still does at C2.

## What `tokens.json` already contains

```json
{
  "colors":  [{ "figmaName": "primary/500", "swiftName": "primary500",
                "lightHex": "#FF0080", "darkHex": "#E60074" }],
  "spacing": [{ "figmaName": "spacing/md", "swiftName": "md", "value": 12, "isCapsule": false }],
  "radius":  [{ "figmaName": "radius/full", "swiftName": "full", "value": 9999, "isCapsule": true }],
  "opacity": [],
  "other":   [],
  "typography": [{
    "figmaName": "Heading 3", "swiftName": "heading3",
    "fontFamily": "SF Pro Rounded", "fontPostScriptName": "SFProRounded-Bold",
    "fontWeight": 700, "fontSize": 28,
    "lineHeightPx": 34, "letterSpacing": -0.56,
    "textCase": "ORIGINAL", "textAlignHorizontal": "LEFT", "italic": false
  }],
  "warnings": []
}
```

Each section (colors / numeric / typography) fails independently. `warnings` non-empty + a specific section empty = that endpoint failed; fall back to reading inline tokens from `design-context.md` for that section only. Typography requires MCPFigma ≥ 0.3.0; older binaries omit the field entirely.

## Skill's job at C2: merge with project enums

The tool doesn't know the project. At C2 the skill chooses, per token:
1. Use existing project enum case if name matches (`Spacing.md`, `IKFont.headingLarge`, `IKCoreApp.colors.primary500`).
2. Else fall back to the extracted token (`Color.primary500` from a generated extension).
3. Else inline literal as last resort.

Never invent new project enum cases — surface mismatches in the run summary.

## Color Tokens

Figma color variables map to SwiftUI Color extensions or Asset Catalog named colors.

### Strategy

1. Check if project already has a color system (Color+Extensions.swift, Theme.swift, or Asset Catalog named colors)
2. If yes: map Figma variable names to existing project colors by matching values
3. If no: create Color extensions or Asset Catalog entries from Figma variables
4. Prefer semantic colors and named assets already used by adjacent screens before introducing a new token

### Mapping Rules

Figma variable "primary/500" -> Color.primary500 or Color("primary500")
Figma variable "text/primary" -> Color.textPrimary
Figma variable "surface/default" -> Color.surfaceDefault
Figma variable "border/subtle" -> Color.borderSubtle

### Adaptive Colors (Light/Dark) — automated path

For every entry in `tokens.json.colors[]` where **both** `lightHex` and `darkHex` are non-null, use `scripts/colorset-codegen.sh` to emit Asset Catalog colorsets — **never hand-write the JSON**. The script writes `<Assets.xcassets>/Colors/<swiftName>.colorset/Contents.json` with the universal (light) + dark appearances and the correct alpha extracted from the hex (`#RRGGBBAA` is honored).

```bash
scripts/colorset-codegen.sh .figma-cache/_shared/tokens.json <Assets.xcassets> Colors
```

Use `Color("Colors/<swiftName>")` in views; Xcode handles the appearance switch. The colorset path is preferred over `@Environment(\.colorScheme)` branching because:
1. iOS sets the appearance per-window (Liquid Glass, popovers, etc.) — environment branching can desync.
2. Snapshot tests can override `.preferredColorScheme(.dark)` and the colorset still resolves.
3. Designer dark-mode hex is preserved 1:1 from `tokens.json`; no agent typing.

Light-only tokens (`darkHex == null`) stay as Color extensions in `DesignSystem/Color+Tokens.swift` (the script skips them). Mixing both is fine — the namespaced `Colors/` group keeps the asset-catalog references distinct from extension references.

## Spacing Tokens

Figma spacing variables map to CGFloat constants.

```swift
enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}
```

Use project's existing spacing system if one exists. Do not create a parallel system.

## Typography Tokens

Figma typography variables map to Font definitions. **Typography is the #1 source of "it doesn't look right" in SwiftUI** — carry every field, not just size + weight.

### Required fields for every text style

| Figma | SwiftUI |
|---|---|
| font-family | `Font.custom("Family", size:)` or `.system(size:)` |
| font-size | `size:` param |
| font-weight | `weight:` param |
| font-width (Expanded/Condensed) | `.fontWidth(.expanded)` / `.condensed` (iOS 16+) |
| line-height | `.lineSpacing(lineHeight - fontSize)` — **see pitfall below** |
| letter-spacing | `.tracking(X)` (preferred) or `.kerning(X)` |
| text-align | `.multilineTextAlignment(.leading / .center / .trailing)` |
| text-transform: uppercase | `.textCase(.uppercase)` |

### Line height pitfall

Figma `line-height: 22px` on a `16px` font = 22pt total line box. SwiftUI `Text` has its own default line height (~1.17× font size ≈ 18.72pt for size 16). To force Figma's value:

```swift
Text("...")
    .font(.system(size: 16, weight: .semibold))
    .lineSpacing(22 - 16)  // extra space between lines = lineHeight - fontSize
    // If the resulting block over-pads, compensate:
    .padding(.vertical, -((22 - 16) / 2))
```

**Never skip line-height when Figma specifies it.** Multi-line text will look loose or tight otherwise.

### Letter spacing pitfall

Figma `letter-spacing: -0.32px` → `.tracking(-0.32)`. Do not use `.kerning()` for font-aware tracking — `.tracking()` respects font ligatures. `.kerning()` applies raw between all chars.

### Example — full style carry-over

```swift
extension Font {
    static let headingLarge = Font.system(size: 28, weight: .bold)
}

Text("Title")
    .font(.headingLarge)
    .fontWidth(.expanded)           // if Figma style is "Expanded"
    .tracking(-0.56)                 // Figma letter-spacing
    .lineSpacing(34 - 28)            // Figma line-height 34
    .foregroundStyle(Color.textPrimary)
    .multilineTextAlignment(.leading)
```

### Custom Fonts

If Figma uses a custom font (e.g., Inter, SF Pro Rounded):
1. Check if font is already added to the Xcode project (Info.plist UIAppFonts)
2. If not, download and add the font files
3. Use Font.custom("FontName", size:) instead of .system()

If the project already provides typography helpers or wrappers such as `IKFont`, use those first instead of introducing raw font declarations or a parallel typography layer.

### Dynamic Type Support

Always consider Dynamic Type. Prefer .font(.headline) or .font(.body) when Figma typography maps closely to iOS text styles. For custom sizes, use @ScaledMetric:

```swift
@ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 16
```

## Border Radius Tokens

Figma corner radius variables map to CGFloat constants used with RoundedRectangle. The MCPFigma `figma_extract_tokens` tool flags pill-shaped radii via `isCapsule: true` (true when value ≥ 999, designer's "full" intent). **This flag is authoritative — trust it instead of comparing the numeric value yourself.**

```swift
enum CornerRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    // Note: do NOT add a `full` case. Pill tokens go through Capsule(), not a 9999 constant.
}
```

### Hard rule: `isCapsule` → `Capsule()`

For every `tokens.json.radius[i]` (and `tokens.json.spacing[i]` / `opacity[i]`, where the same flag may appear) with `isCapsule: true`, codegen the SwiftUI `Capsule()` shape — never `.cornerRadius(9999)` or `RoundedRectangle(cornerRadius: 9999)`.

```swift
// ✓ correct — pill button
Button { ... } label: { Text(Strings.cta) }
    .frame(maxWidth: .infinity, minHeight: 48)
    .background(Color("Colors/primary500"))
    .clipShape(Capsule())

// ✗ wrong — 9999 magic number renders identically on iPhone but breaks
//   on shapes wider than they are tall (the rounded ends become flat).
.cornerRadius(9999)
```

Apply the same rule to **fills, backgrounds, borders, and overlays** that use the pill token — `Capsule()` everywhere, no `RoundedRectangle`. Mixing the two on the same pill element causes 1px seams under hairline strokes.

### Numeric radii (`isCapsule: false`)

Use `RoundedRectangle(cornerRadius: <value>, style: .continuous)`. The `.continuous` style matches Apple's default squircle shape used in Figma's iOS template — `.circular` (the default) renders slightly different curvature.

## Shadow Tokens

Figma shadow variables (elevation levels):

```swift
extension View {
    func shadowSm() -> some View {
        shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }
    func shadowMd() -> some View {
        shadow(color: .black.opacity(0.1), radius: 8, x: 0, y: 4)
    }
    func shadowLg() -> some View {
        shadow(color: .black.opacity(0.15), radius: 16, x: 0, y: 8)
    }
}
```

## Gradients

Figma linear gradient → SwiftUI `LinearGradient`. Match stops and direction exactly.

```swift
// Figma: top-to-bottom gradient, #FF0080 0% → #7928CA 100%
LinearGradient(
    colors: [Color(hex: "FF0080"), Color(hex: "7928CA")],
    startPoint: .top,
    endPoint: .bottom
)

// Figma: diagonal (45° / topLeading → bottomTrailing)
LinearGradient(
    colors: [...],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

// Figma: stops at specific positions
LinearGradient(
    stops: [
        .init(color: Color(hex: "FF0080"), location: 0.0),
        .init(color: Color(hex: "7928CA"), location: 0.6),
        .init(color: Color(hex: "0070F3"), location: 1.0)
    ],
    startPoint: .leading,
    endPoint: .trailing
)
```

Radial gradient → `RadialGradient`. Angular (conic) → `AngularGradient`. Match Figma's center, radius, and angle exactly.

## Opacity

- Figma fill opacity 50% → `Color(...).opacity(0.5)` on the background.
- Figma layer opacity (applied to the whole layer + children) → `.opacity(0.5)` on the view.
- These differ: fill-opacity only affects the fill color; layer opacity affects everything inside. Read the Figma inspector carefully.
- Tailwind `bg-black/50` = fill opacity. `opacity-50` = layer opacity.

## General Rules

1. Always check project for existing design system before creating new tokens
2. Match by value first (hex color, px value), then by semantic name
3. If project tokens exist but names differ from Figma, use project names
4. Do not duplicate: one source of truth for each token
5. Prefer existing shared modules and helpers such as `IKFont`, `IKCoreApp`, theme wrappers, and Asset Catalog colors when they already express the same intent
6. Group tokens logically (Color, Spacing, Typography, Radius, Shadow)
