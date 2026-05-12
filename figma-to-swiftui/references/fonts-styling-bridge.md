# Fonts & Styling Bridge

**Canonical source: [`ikame-ios-coding/references/fonts-and-styling.md`](../../ikame-ios-coding/references/fonts-and-styling.md)** — full `ikFont` preset table, `Color(hex:)` extension, dark mode adaptation. This file holds only the figma-specific delta: mapping `tokens.json.typography[]` to `ikFont` presets/escape hatch, B0b codegen behavior, and font-registration warnings.

Applies fully when `c1-conventions.json.usesIKFont == true` (Ikame); color section is universal.

## §1. Detection (C1 audit)

`usesIKFont = true` when any signal: `pod 'IKCoreApp'`; `import IKCoreApp` + call sites use `.ikBody()`/`.ikLargeTitle()`/`.ikFont(`/`Font.ikBody`; `IKFontSystem.shared.configure(` in app boot.

C1 captures:
- `fontModifier` — `"ikFont"` canonical / `"appFont"` brownfield wrapper
- `fontFamily` — main family from `IKFontSystem.shared.configure(familyName:)` (e.g. `"Inter"`)
- `additionalFontFamilies[]` — per-family helpers in `Utilities/Extensions/<Family>+Ext.swift`

If `usesIKFont == false` → use `Font.custom(...)` directly OR project's own abstraction.

## §2. Decision flow — typography token → SwiftUI

For each entry in `tokens.json.typography[]`:

```
typography entry → { fontFamily, fontPostScriptName, fontWeight, fontSize, lineHeightPx, letterSpacing, ... }
        │
        ▼
1. fontFamily == c1.fontFamily AND (fontSize, lineHeightPx) matches an ikFont preset?
        ├─ YES  →  Text(...).ik<Preset>(weight: .<weight>)
        │
2. fontFamily == c1.fontFamily AND (fontSize, lineHeightPx) is off-token?
        ├─ YES  →  Text(...).ikFont(<size>, weight: .<weight>)
        │          + .lineSpacing(<lineHeightPx - fontSize>) + .tracking(<letterSpacing>) if non-zero
        │          Extract `private static let <name>FontSize: CGFloat = <size>` when repeated > 3×
        │
3. fontFamily != c1.fontFamily (Figma uses different family)?
        └─ Check c1.additionalFontFamilies[]:
              ├─ Helper exists  →  Text(...).<family>(<size>, weight: .<weight>)
              └─ Helper missing →  STOP, ask user to add 4-layer helper
```

### ikFont preset table

Match `(fontSize, lineHeightPx)` **exactly** — do NOT round; off-token sizes use escape hatch.

| Preset | Size / Line-height |
|---|---|
| `ikHeading1` | 56 / 70 |
| `ikHeading2` | 48 / 60 |
| `ikHeading3` | 40 / 50 |
| `ikLargeTitle` | 32 / 40 |
| `ikTitle` | 24 / 30 |
| `ikSmallTitle` | 20 / 24 |
| `ikSubtitle18` | 18 / 26 |
| `ikSubtitle16` | 16 / 24 |
| `ikBody` | 14 / 20 |
| `ikCaption12` | 12 / 16 |
| `ikLabel11` | 11 / 14 |

Weight maps directly: `.regular`, `.medium`, `.semibold`, `.bold`. Italic → `.ikItalicFont(size:weight:)`.

### Figma style name → preset name aliasing

| Figma style name | ikFont preset (when size also matches) |
|---|---|
| `Heading 1`, `H1`, `Display 1` | `ikHeading1` |
| `Heading 3`, `H3` | `ikHeading3` |
| `Large Title`, `Title XL` | `ikLargeTitle` |
| `Title`, `H4` | `ikTitle` |
| `Subtitle 18`, `Subhead L` | `ikSubtitle18` |
| `Body`, `Body 14` | `ikBody` |
| `Caption`, `Caption 12` | `ikCaption12` |
| `Label`, `Footnote` | `ikLabel11` |

When name matches but size doesn't, **size wins** — emit escape hatch with `// Figma: <styleName>` comment.

## §3. B0b codegen — what NOT to emit for Ikame

**Do NOT** emit a separate `AppFont.swift` with `AppFont.heading3() -> Font` wrappers around `Font.custom(...)`. The `ikFont` preset family is part of IKCoreApp — emit call sites directly:

```swift
// ✓ Canonical
Text(Strings.Home.title).ikLargeTitle(weight: .bold)

// ✗ Banned for Ikame
enum AppFont {
    static func largeTitle() -> Font { Font.custom("Inter-Bold", size: 32) }
}
```

B0b emits `AppFont.swift` only when `usesIKFont == false`. For Ikame, B0b emits only colorsets + `Spacing.swift` + (when off-token sizes repeat > 3×) per-screen `private static let <name>FontSize` constants.

## §4. Colors — Asset Catalog vs `Color(hex:)`

| Use case | API |
|---|---|
| Named, reused ≥ 2×, OR light/dark adaptive | Asset Catalog colorset → `Color(.<swiftName>)` (auto-generated `ColorResource`) |
| One-off literal in a single screen | `Color(hex: "#3B7BFD")` if project has the extension; else `Color(red: ..., green: ..., blue: ...)` |
| Multi-color gradient | `LinearGradient(colors: [.appPrimary, .appAccent], ...)` — all stops from named colors when possible |

The B0b `colorset-codegen.sh` script emits universal (light) + dark appearances. The `Colors/` group is written with `provides-namespace: false` so the symbol resolves flat (`Color(.brandPrimary)` not `Color(.Colors.brandPrimary)`).

## §5. Brownfield `appFont` wrapper

Some older projects wrap `ikFont` with `appFont`:

```swift
// Project-defined wrapper
extension View {
    func appFontHeading3() -> some View { ikHeading3(weight: .bold) }
}

// Call site
Text("Title").appFontHeading3()
```

When `fontModifier == "appFont"`, the skill emits the wrapper form. Don't mix `ikFont` + `appFont` in one project.

## §6. Additional font families (4-layer helper pattern)

When Figma uses a font family different from the project's main family (e.g. main is `Inter`, Figma uses `FiraCode` for code snippets), Ikame projects use a 4-layer helper that delegates to `ikCustomFont`:

```swift
// Utilities/Extensions/FiraCode+Ext.swift
extension View {
    func firaCode(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        ikCustomFont(familyName: "FiraCode", size: size, weight: weight)
    }
}
```

Call site: `Text(snippet).firaCode(13)`.

If a helper doesn't exist yet for a needed family → STOP, ask user to add the 4-layer helper. Don't emit `Font.custom(...)` directly in views.

## §7. Font file registration — silent fallback warning

**Critical gotcha:** when emitting `Font.custom("X-Y", size:)` (in non-Ikame projects) or when adding a new additional font family to an Ikame project, the matching `.otf`/`.ttf` MUST be:

1. **Bundled in the project** (typically `Resources/Fonts/<X-Y>.otf`)
2. **Listed in `Info.plist`'s `UIAppFonts` array**

If either is missing, iOS **silently** falls back to system fonts. No build error. No runtime crash. The screenshot shows the wrong typography while the code looks correct.

```swift
// ✗ Anti-pattern if font file not bundled:
.font(.custom("Inter-Medium", size: 17))
// Renders system font silently. Pass 2 visual diff catches the typography drift,
// but only if you actually run C5 + compare carefully.
```

Manual check before C5:
```bash
# 1. Find every Font.custom("X", ...) call site
grep -rE 'Font\.custom\("[^"]+"' --include="*.swift" .

# 2. Verify each name appears in Info.plist UIAppFonts
plutil -p <project>/Info.plist | grep -A 100 UIAppFonts
```

For Ikame projects, `IKFontSystem.shared.configure(familyName: "...")` at app boot registers the project's main family. Additional families need their `.otf`/`.ttf` in `UIAppFonts` separately.

If the Figma typography token's family isn't registered → STOP, tell the user: *"Font `<Family>` is in Figma but not in `UIAppFonts`. Add the .otf to `Resources/Fonts/` and `<filename>.otf` to `Info.plist` UIAppFonts, OR change the Figma token to the project's main family."*
