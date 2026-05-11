# Fonts & Styling Bridge

How `figma-to-swiftui` maps Figma typography tokens + colors into the project's `ikFont` / `Color(hex:)` system. Conditional — applies fully when `c1-conventions.json.usesIKFont == true` (Ikame projects); partial rules apply elsewhere (color section is universal).

**Canonical source: `ikame-ios-coding/references/fonts-and-styling.md` and `references/ikame-decision-table.md` §12 (D-1101..D-1108).** This file holds only the figma-specific delta — mapping `tokens.json.typography[]` entries to `ikFont` presets vs escape hatch, B0b codegen behavior, and Color(hex:) vs Asset Catalog decision.

---

## §1. Detection (C1 audit)

C1 sets `usesIKFont = true` when ANY of these signals are present:

| Signal | Where |
|---|---|
| `pod 'IKCoreApp'` in Podfile (umbrella) | grep |
| `import IKCoreApp` AND any call site uses `.ikBody()` / `.ikLargeTitle()` / `.ikFont(` / `Font.ikBody` / `UIFont.ikBody` | grep |
| `IKFontSystem.shared.configure(` call in AppDelegate / app boot | grep |

If any signal present → `usesIKFont = true`. Skill emits `ikFont` preset / escape-hatch calls per `ikame-ios-coding/references/fonts-and-styling.md`.

C1 also captures:
- `fontModifier` — `"ikFont"` (canonical) or `"appFont"` (brownfield wrapper, see §6).
- `fontFamily` — the project's main family configured via `IKFontSystem.shared.configure(familyName:)` (e.g. `"Inter"`, `"SFProRounded"`). When the Figma typography token uses a different family, the skill needs a per-family helper (§5).
- `additionalFontFamilies[]` — per-family helpers already in `Utilities/Extensions/<Family>+Ext.swift` (e.g. `firaCode`, `jetBrainsMono`). When Figma uses one of these, emit the matching call site directly. When Figma uses a family not yet in the list, STOP and ask the user to add the 4-layer helper (or emit a delta-request).

If `usesIKFont == false` → the project is not Ikame; use `Font.custom(...)` directly with the Figma family name, OR the project's own equivalent abstraction (per `c1-conventions.json.fontConvention`).

---

## §2. The decision flow (B0b codegen)

For each entry in `tokens.json.typography[]` (emitted by MCPFigma's `figma_extract_tokens`), pick one of three outputs:

```
typography entry → { fontFamily, fontPostScriptName, fontWeight, fontSize, lineHeightPx, letterSpacing, textCase, textAlignHorizontal, italic }
        │
        ▼
1. fontFamily == c1.fontFamily AND (fontSize, lineHeightPx) match an ikFont preset?
        ├─ YES  →  emit call sites as `Text(...).ik<Preset>(weight: .<weight>)`
        │
2. fontFamily == c1.fontFamily AND (fontSize, lineHeightPx) is off-token?
        ├─ YES  →  emit call sites as `Text(...).ikFont(<size>, weight: .<weight>)`
        │          + `.lineSpacing(<lineHeightPx - fontSize>)` + `.tracking(<letterSpacing>)` if non-zero
        │          extract `private static let <name>FontSize: CGFloat = <size>` at top of screen file when repeated > 3 times
        │
3. fontFamily != c1.fontFamily (Figma used a different family)
        └─ Check c1.additionalFontFamilies[]:
              ├─ Helper exists  →  emit `Text(...).<family>(<size>, weight: .<weight>)`
              └─ Helper missing →  STOP, ask user OR emit delta-request {type: "additionalFontFamily", family: "<Name>", postScriptName: "..."}
```

### The ikFont preset table

From `ikame-ios-coding/references/fonts-and-styling.md` — match `(fontSize, lineHeightPx)` exactly. **Do NOT round; off-token sizes use the escape hatch (case 2).**

| Preset method | Size / Line-height |
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

Weight maps directly from `fontWeight` (Figma) → `weight:` argument: `.regular`, `.medium`, `.semibold`, `.bold`. For italic, use `.ikItalicFont(size:weight:)` (SwiftUI) — see ios-coding-skill §"Italic variants".

### Token-name → preset-name aliasing

When `tokens.json.typography[]` entry names (the design-system names from Figma styles) match canonical ikFont preset names, prefer the preset. Common mappings:

| Figma style name | ikFont preset |
|---|---|
| `Heading 1`, `H1`, `Display 1` | `ikHeading1` (if size matches) |
| `Heading 3`, `H3` | `ikHeading3` |
| `Large Title`, `Title XL` | `ikLargeTitle` |
| `Title`, `H4` | `ikTitle` |
| `Subtitle 18`, `Subhead L` | `ikSubtitle18` |
| `Body`, `Body 14` | `ikBody` |
| `Caption`, `Caption 12` | `ikCaption12` |
| `Label`, `Footnote` | `ikLabel11` |

When the name matches but the size doesn't, **size wins** — emit the escape hatch with a `// Figma: <styleName>` comment for traceability.

---

## §3. B0b token codegen — what NOT to emit

Per ios-coding-skill canonical convention, **do NOT** emit a separate `AppFont.swift` file with `AppFont.heading3() -> Font` wrappers around `Font.custom(...)`. The `ikFont` preset family is already part of IKCoreApp — emit call sites that use it directly:

```swift
// ✓ Canonical
Text(Strings.Home.title).ikLargeTitle(weight: .bold)

// ✗ Banned in Ikame projects — duplicates ikFont with a project-local wrapper
enum AppFont {
    static func largeTitle() -> Font { Font.custom("Inter-Bold", size: 32) }
}
Text(Strings.Home.title).font(AppFont.largeTitle())
```

The B0b script `scripts/b0b-tokens-codegen.sh` emits `AppFont.swift` only when:
- The project is NOT Ikame (`usesIKFont == false`), AND
- No equivalent abstraction is detected (`fontConvention == "vanilla"`).

For Ikame projects, B0b emits only colorsets + `Spacing.swift` + (when there are off-token sizes used > 3 times) per-screen `private static let <name>FontSize` constants. No `AppFont.swift` generated.

---

## §4. Color — `Color(.<name>)` from Asset Catalog vs `Color(hex:)` one-off

Per `ikame-ios-coding/references/fonts-and-styling.md`:

| Use case | API |
|---|---|
| Color with a name in the design system, OR reused in ≥ 2 places, OR adapts to light/dark | Asset Catalog colorset → `Color(.<swiftName>)` |
| One-off color genuinely without a semantic name (single use, no theme adaptation) | `Color(hex: "#<RRGGBB>")` (or `Color(hex: "<RRGGBBAA>")` with alpha) |

**B0b codegen behavior:**

For each entry in `tokens.json.colors[]`:
- **Dual-mode** (`lightHex` AND `darkHex` present) → emit `<Assets.xcassets>/Colors/<swiftName>.colorset` with universal + dark appearances. Call site uses `Color(.<swiftName>)` (iOS 17+ auto-generated `ColorResource` symbol — project must have `GENERATE_ASSET_SYMBOLS = YES`).
- **Light-only** (`darkHex` null) → emit colorset with universal appearance only (still `Color(.<swiftName>)` at call sites) OR a light-only static-let in `DesignSystem/Color+Tokens.swift` per project convention.

Format support for `Color(hex:)`:

| Length | Format | Example |
|---|---|---|
| 6 or 7 chars | `RRGGBB` (no alpha) | `Color(hex: "#FF0000")` |
| 8 chars | `RRGGBBAA` | `Color(hex: "00FF0080")` (green at 50% alpha) |
| Anything else | Falls back to white silently | `Color(hex: "abc")` → white |

**The skill never emits invalid hex.** When Figma fills are `imageRef` / gradient / blend (not solid hex), use `fills.json` (per `references/fills-handling.md`) — do NOT try to stringify into a hex.

---

## §5. Additional font family — when Figma uses a non-project font

When `tokens.json.typography[].fontFamily` does not equal the project's main family (captured by C1 as `fontFamily`), the skill needs a per-family helper. Per `ikame-ios-coding/references/fonts-and-styling.md` §"Importing an additional font family":

1. **Check `Resources/Fonts/`** — does the project already ship the `.ttf`/`.otf`? If not, STOP and ask the user to add the font files + register them in Info.plist `UIAppFonts`.
2. **Check `Utilities/Extensions/<Family>+Ext.swift`** — does the 4-layer helper file exist?

If the helper exists → emit call sites that use it:

```swift
Text(logLine).firaCode(13)
Text(versionLabel).firaCode(14, weight: .semibold)
Text(emphasized).firaCode(13, italic: true)
```

If the helper does NOT exist → STOP and ask the user, OR emit a delta-request:

```
{ "type": "additionalFontFamily",
  "family": "FiraCode",
  "postScriptName": "FiraCode-Regular",
  "weights": ["Regular", "Medium", "Bold"],
  "rationale": "Figma node 3:24644 uses FiraCode for code snippets" }
```

The leader resolves by adding the 4-layer file (`UIFont` + `Font` + `View` + `Text` extensions) delegating to `ikCustomFont(familyName:size:weight:italic:)` per ios-coding-skill template. **Do NOT** define a one-off `Font.custom("FiraCode-Regular", size: 13)` at the call site — that bypasses descriptor handling and the 4-layer consistency.

---

## §6. Brownfield `appFont` wrapper (legacy)

Some older Ikame projects ship a project-local `.appFont(<size>, weight:)` modifier wrapping `Font.custom(...)` in `Utilities/Fonts/`. C1 captures this as `fontModifier: "appFont"` (vs canonical `"ikFont"`).

When `appFont` is detected, match the legacy form in additions to that project:

```swift
// Brownfield form — only when C1 captures fontModifier: "appFont"
Text(Strings.Home.title).appFontHeading3()
Text("Selected: \(count)").appFont(20, weight: .semibold)
```

**Do NOT introduce a new `appFont` wrapper into a project that doesn't have one** — canonical new code uses `ikFont` from IKCoreApp.

Mapping `appFont` → `ikFont` cases (for reference when migrating):

| Legacy `appFont` call | Canonical `ikFont` equivalent |
|---|---|
| `.appFontHeading1()` | `.ikHeading1()` |
| `.appFontHeading2()` | `.ikHeading2()` |
| `.appFontHeading3()` | `.ikHeading3()` |
| `.appFontBody()` | `.ikBody()` |
| `.appFont(20, weight: .semibold)` | `.ikSmallTitle(weight: .semibold)` (if size matches) or `.ikFont(20, weight: .semibold)` (escape hatch) |

The skill does NOT migrate existing call sites — only emits the matching form for new code in the same project.

---

## §7. Banned font / styling patterns

| Pattern | Replacement | Notes |
|---|---|---|
| `.font(.system(size: N))` | `Text(...).ikFont(N, weight: .<w>)` (off-token) or `.ik<Preset>(weight: .<w>)` (preset match) | iOS system font bypasses the project family. |
| `.font(.body)` / `.font(.title)` / `.font(.headline)` SwiftUI semantic roles | `.ikBody()` / `.ikTitle()` / etc. | SwiftUI roles use SF; project family is configured via `IKFontSystem`. |
| `Font.custom("FiraCode-Regular", size: 13)` raw at call site | `Text(...).firaCode(13)` via 4-layer helper | Helper delegates to `ikCustomFont(familyName:size:weight:italic:)`. |
| `UIFont(name: "FiraCode-Bold", size: 14)` raw at call site | `UIFont.firaCode(14, weight: .bold)` via 4-layer helper | Same — helper delegates to `UIFont.ikCustomFont(...)`. |
| `Text("...").font(.ikBody())` | `Text("...").ikBody()` | Text overload is canonical; signals intent. |
| `.fontWeight(.bold)` after `.ikBody()` (separate modifier) | `.ikBody(weight: .bold)` (single call) | Weight is an argument on the preset, not a separate modifier. |
| Inline `Color(red: 0.2, green: 0.5, blue: 1, opacity: 1)` when an asset matches | `Color(.<swiftName>)` from Asset Catalog | Search `xcassets/Colors/` before inlining. |
| `Color(hex: "")` / `Color(hex: "abc")` | Pass a valid 6/7/8-char hex | Invalid hex silently becomes white. |
| Inline custom hex used in 3+ places | Asset Catalog colorset or `Color` extension | Dedup before sprinkling. |

---

## §8. Failure-mode self-check

Before emitting any view that touches typography or color:

1. **Font modifier API.** Did I use `Text(...).ik<Preset>(weight:)` (preset match) or `.ikFont(<size>, weight:)` (off-token escape hatch)? Not `.font(.system(...))`, not `.font(.<role>)`, not raw `Font.custom(...)`?
2. **Preset choice.** When `(fontSize, lineHeightPx)` matches a preset row exactly, did I use the preset (not the escape hatch)?
3. **Off-token escape.** When size is off-token, did I include `.lineSpacing` and `.tracking` if non-zero?
4. **Per-screen specials.** When the same off-token size appears > 3 times, did I extract `private static let <name>FontSize: CGFloat = <size>`?
5. **Additional family.** When `tokens.json.typography[].fontFamily != c1.fontFamily`, did I check `c1.additionalFontFamilies[]` first? Did I emit the per-family call site if the helper exists, or STOP/delta-request if not?
6. **Color reference.** Every color is `Color(.<name>)` (Asset Catalog generated symbol) for named/reused/themed colors, OR `Color(hex: "#<RRGGBB>"))` for one-off Figma pixels?
7. **No raw Font.custom / UIFont(name:) at call site.** Even for additional fonts, always via the 4-layer helper.
8. **Brownfield `appFont`.** When C1 captured `fontModifier: "appFont"`, did I match the legacy form instead of emitting `ikFont`?

If any answer is "no" / "unsure", STOP and consult `ikame-ios-coding/references/fonts-and-styling.md` + `references/ikame-decision-table.md` §12.
