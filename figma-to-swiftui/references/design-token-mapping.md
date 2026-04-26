# Figma Design Tokens to SwiftUI Mapping

How to translate Figma variables (from get_variable_defs) into a SwiftUI design system.

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

### Adaptive Colors (Light/Dark)

Figma variables with mode variants (light/dark):
- Asset Catalog: Create color set with Any Appearance + Dark Appearance
- Code: Use @Environment(\.colorScheme) only if Asset Catalog is not an option

```swift
// Asset Catalog approach (preferred)
Color("textPrimary") // automatically adapts

// Code approach (when needed)
extension Color {
    static var textPrimary: Color {
        Color("textPrimary")
    }
}
```

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

Figma corner radius variables map to CGFloat constants used with RoundedRectangle:

```swift
enum CornerRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16
    static let full: CGFloat = 9999 // pill shape -> Capsule()
}
```

When radius equals 9999 or "full", use Capsule() instead of RoundedRectangle.

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
