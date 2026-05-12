# Asset Handling for iOS/SwiftUI

End-to-end workflow for turning Figma assets into Asset Catalog entries and using them correctly in SwiftUI.

---

## 1a. Decide: flatten, decompose, or code?

**Most important decision in asset handling.** For each major visual region, pick one strategy:

| Strategy | When | Examples |
|---|---|---|
| **FLATTEN** — export region as 1 PNG via `get_screenshot(regionNodeId)` | Non-interactive, composed artwork (3+ overlapping layers), effects SwiftUI can't reproduce (complex masks, blend modes, layered shadows on gradients, patterned fills), designer-authored as a unit, static content (no localization) | Onboarding hero, empty-state scene, splash artwork, promo card background, branded section header, full-width banner |
| **DECOMPOSE** — atomic pieces + SwiftUI stacks | Interactive children, dynamic/localized text, independent animation/state, reusable component pattern | List rows, form sections, tab bars, navigation headers, button groups, card grids |
| **CODE** — pure SwiftUI shapes | Trivial geometric shape, solid/gradient backgrounds (no artwork on top), blur/material backgrounds, UI affordances | Rounded rect, circle, divider, dot indicator, badge circle |

### Mixed regions — flatten artwork, overlay UI

```swift
ZStack(alignment: .bottom) {
    Image(.onboardingHeroArtwork)            // flattened illustration + bg
        .resizable()
        .scaledToFill()
        .frame(maxWidth: .infinity)
        .ignoresSafeArea(edges: .top)

    VStack(alignment: .leading, spacing: 12) {
        Text(Strings.Onboarding.title)        // dynamic, localizable
        Text(Strings.Onboarding.subtitle)
        Button(Strings.Onboarding.cta) { }    // interactive
            .buttonStyle(PrimaryButtonStyle())
    }
    .padding(24)
}
```

### Visual inspection rule (primary signal)

**Open `screenshot.png` and look at the region before deciding.** Trust the screenshot over JSX heuristics.

| Question | If yes → |
|---|---|
| Looks like a painting/illustration/composed scene? | FLATTEN |
| Unique visual identity not repeated elsewhere? | FLATTEN |
| Overlapping decorative elements form a single visual unit? | FLATTEN |
| Artistic effects (hand-drawn shading, layered transparency)? | FLATTEN |
| Functional row of similar icons (tab bar, icon menu, social strip)? | DECOMPOSE |
| Elements uniform in size/style, arranged in grid or list with labels? | DECOMPOSE |
| Distinct UI affordances (each tappable, different purpose)? | DECOMPOSE |
| Trivial geometric shape? | CODE |

**Heuristic:** would a designer describe this as "the hero illustration" (1 thing) or "a row of action icons" (N things)? First → flatten. Second → decompose.

**Visual answer wins over JSX.** JSX can be structured as many sub-layers for designer convenience even when output is a single unit.

### When FLATTEN is wrong — image + code-able gradient

Common false-positive: photo background + gradient overlay (hero banner, onboarding header). Before flattening, check `.figma-cache/<nodeId>/fills.json`. If region has `fills[] = [IMAGE, GRADIENT_*]`, use [`fills-handling.md` Recipe 3](fills-handling.md): export image atomically, emit gradient as inline `LinearGradient(stops:...)`. FLATTEN remains correct when region has hand-drawn illustration baked in.

### Anti-pattern

Downloading 5 small icons from a composed illustration and stacking with `.offset(x:, y:)` in ZStack. Drifts on different screen sizes, misses shadow/blur/blend layers, breaks when tokens change. **When in doubt: flatten.**

---

## 1b. Decide: download or code? (for atomic pieces)

Once flattening is decided, for every remaining atomic element:

| Element | Handling |
|---|---|
| Real icon (UI controls, navigation, indicators) | Download via Phase B |
| Brand logo (Facebook, Google, app logo) | Download via Phase B |
| Illustration / decorative graphic | Download via Phase B |
| Rounded rect / circle as button background | CODE (SwiftUI shape) |
| Divider line | CODE |
| Solid color background | CODE |
| Linear/radial gradient (no image fill underneath) | CODE (`LinearGradient(...)`) |
| Material blur background | CODE (`.background(.ultraThinMaterial)`) |

---

## 2. Determine sizing from Figma

| Figma metric | SwiftUI |
|---|---|
| Frame size (W×H) | `.frame(width: W, height: H)` |
| `width: hug`, `height: hug` | No explicit frame — let intrinsic size apply |
| `width: fill` | `.frame(maxWidth: .infinity)` |
| `width: fixed X` | `.frame(width: X)` |
| Constraint `aspect ratio` | `.aspectRatio(W/H, contentMode: .fit/.fill)` |

For icons: Figma sizes are typically in 8pt grid (16, 24, 32, 40, 48). For images: download at 3× the display size (e.g. 72×72 PNG for 24pt display).

---

## 3. Download the asset

**Tagged path** (`exporter: "tagged"`): the tool downloads `@2x`/`@3x`, names per Figma node (`eICHome` → `icAIHome`), writes `.imageset` directly to `Assets.xcassets`.

**Fallback path** (`exporter: "fallback"`): the tool downloads at scale 3 to `_shared/assets/<nodeId>.png`. Then run §5 to build the `.imageset` from the 3× source via `sips`.

**Lottie path** (`strategy: "lottiePlaceholder"`): no PNG download. See [`lottie-placeholders.md`](lottie-placeholders.md).

---

## 4. Decide the rendering mode

| Asset type | `renderingMode` | Reason |
|---|---|---|
| Single-color icon (UI controls, navigation, system glyphs) | `.template` | Tinted at call site via `.foregroundStyle(...)` |
| Multi-color logo (brand mark with specific colors) | `.original` | Never tint a brand logo |
| Illustration (composed scene, hero artwork) | `.original` | Preserves the artist's color palette |
| Hand-drawn artistic icon | `.original` |
| Photo / image content | `.original` |

For tagged-path assets: rendering mode decided at SwiftUI call site (`.renderingMode(.template)` modifier). For fallback-path: set `"template-rendering-intent": "template"` in `Contents.json`.

---

## 5. Build the Asset Catalog entry

**Skip §5 for tagged-path assets** — `xcassetsImported: true` means the tool already wrote the imageset. Resume §5 only when adding light/dark variants manually.

§5 applies to fallback-path assets + tagged rows auto-promoted to fallback.

### Generate @1x, @2x, @3x with sips

```bash
cd .figma-cache/<nodeId>/assets
SOURCE="icon-close.png"          # 72×72 for 24pt icon
BASE="icon-close"
cp "$SOURCE" "${BASE}@3x.png"
sips -Z 48 "$SOURCE" --out "${BASE}@2x.png" >/dev/null
sips -Z 24 "$SOURCE" --out "${BASE}@1x.png" >/dev/null
```

### Contents.json — standard imageset

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

Add `"properties": { "template-rendering-intent": "template" }` to the JSON above.

### Contents.json — light + dark variants

```json
{
  "images": [
    { "filename": "brand@2x.png",      "idiom": "universal", "scale": "2x" },
    { "filename": "brand@3x.png",      "idiom": "universal", "scale": "3x" },
    { "filename": "brand-dark@2x.png", "idiom": "universal", "scale": "2x",
      "appearances": [{ "appearance": "luminosity", "value": "dark" }] },
    { "filename": "brand-dark@3x.png", "idiom": "universal", "scale": "3x",
      "appearances": [{ "appearance": "luminosity", "value": "dark" }] }
  ],
  "info": { "author": "xcode", "version": 1 }
}
```

For single-color icons, rarely need dark variants — use template mode + semantic color.

---

## 6. Naming & deduplication

### Search for existing before creating

1. Grep project's Asset Catalog for matching names
2. Check nearby features for similar icons
3. Visually compare — pixel-match = reuse
4. Only create new when nothing matches

### Naming

- **Tagged-path**: `icAI<Name>` for icons, `imageAI<Name>` for images. Fixed convention — tool owns. `<Name>` from Figma node name (`eICHome` → `icAIHome`).
- **Fallback-path**:
  - Match project's existing case style (camelCase or kebab-case — don't mix)
  - Global icons (shared across screens): no prefix. `close`, `chevronRight`, `search`
  - Screen-specific visuals: prefix with screen/feature name. `onboardingHero`, `profileHeaderPlaceholder`
  - Variants: `heart`, `heartFilled`, `heartOutline`
- No spaces, no special chars, no extensions in catalog entry name.

### Color asset naming — Ikame projects

When `c1-conventions.json.usesIKCoreApp == true`:
- **New tokens from Figma → `color<HEX>`** (e.g. `#0F0F0F` → `color0F0F0F`). Hex uppercase, no `#`. Reference as `Color(.color0F0F0F)`.
- **Semantic alias allowed when project already uses one** (`bg`, `accentRed`, `colorDelete`). Reuse — don't duplicate.
- **Dedup before adding:** look up hex in `xcassets/Colors/` first.
- In code: `Color(.color0F0F0F)` (iOS 17+ auto-generated `ColorResource`). NEVER `Color(red:green:blue:)`, NEVER `Color(hex:)` if asset exists, NEVER string form `Color("color0F0F0F")`.

For non-Ikame: fall back to `swiftui-pro-bridge.md` §1c. See [AP-14](anti-patterns.md) for SwiftUI built-in shadowing trap (banned names: `primary`, `secondary`, `accent`, etc).

Materialization: `colorset-codegen.sh` reads `tokens.json` + emits colorsets to xcassets. Ikame branch names new colorsets `color<HEX>`; generic branch uses semantic name.

---

## 7. Use the asset in SwiftUI

### Tagged icon (template at call site)

```swift
Image(.icAIClose)
    .resizable()
    .renderingMode(.template)
    .frame(width: 24, height: 24)
    .foregroundStyle(Color(.textPrimary))
```

### Fallback icon (template intent in Contents.json)

```swift
Image(.iconClose)
    .resizable()
    .frame(width: 24, height: 24)
    .foregroundStyle(Color(.textPrimary))
```

(`.renderingMode(.template)` redundant when Contents.json already declares template intent — but harmless.)

### Multi-color icon / illustration (original)

```swift
Image(.facebookLogo)
    .resizable()
    .frame(width: 24, height: 24)
```

### Fill-* image (mandatory triple)

```swift
Image(.heroArtwork)
    .resizable()
    .scaledToFill()                          // or .scaledToFit() per Figma objectFit
    .frame(maxWidth: .infinity, height: 240) // explicit frame
```

All three required. Missing `.resizable()` = blank gap. Missing content mode = anisotropic stretch. Missing `.frame(...)` = intrinsic shrink. See [AP-10](anti-patterns.md).

### Lottie placeholder

```swift
import Lottie

LottieView(animation: .named("placeholder_animation"))
    .playing()
    .frame(width: 120, height: 120)
// TODO: replace placeholder_animation.json with real Lottie file
```

See [`lottie-placeholders.md`](lottie-placeholders.md).

---

## 8. Remote images

For images loaded from URL (user avatars, dynamic content):

```swift
AsyncImage(url: URL(string: avatarURL)) { phase in
    switch phase {
    case .empty:   ProgressView()
    case .success(let image): image.resizable().scaledToFill()
    case .failure: Image(.avatarPlaceholder).resizable()
    @unknown default: EmptyView()
    }
}
.frame(width: 48, height: 48)
.clipShape(Circle())
```

For more robust loading (caching, retry), use a library like [Nuke](https://github.com/kean/Nuke) or [SDWebImageSwiftUI](https://github.com/SDWebImage/SDWebImageSwiftUI) when the project already has it.

---

## 9. Copy from cache to project

After C4 verifies imagesets, optionally clean cache:

```bash
# Delete cache assets after Phase C is verified
rm -rf .figma-cache/<nodeId>/assets/
# _shared/ stays — other screens may reference its dedup'd PNGs
```

The `.imageset/` directories under `Assets.xcassets` are the source of truth post-C4.

---

## Asset Rules Summary

1. **Tagged path is canonical** — `eIC*`/`eImage*` Figma nodes export directly to `Assets.xcassets` via `figma_export_assets_unified`. Don't second-guess the tool.
2. **Fallback path requires §5 build** — sips 3× source to @1x/@2x/@3x, write Contents.json, copy to xcassets.
3. **Template mode for single-color UI icons** — set in Contents.json or at call site.
4. **Original mode for brand logos + illustrations** — never tint a brand.
5. **Search for existing before creating new** — dedup is cheaper than maintaining parallel assets.
6. **Naming: tagged path is fixed (`icAI*`/`imageAI*`); fallback follows project convention.**
7. **Banned colorset names** (Ikame + non-Ikame): `primary`, `secondary`, `accent`, etc — shadow SwiftUI built-ins. See [AP-14](anti-patterns.md).
8. **Fill-* Image MUST emit `.resizable() + content-mode + .frame()`** — all three.
