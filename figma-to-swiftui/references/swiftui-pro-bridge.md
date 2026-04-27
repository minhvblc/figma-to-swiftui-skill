# swiftui-pro Bridge for Figma → SwiftUI

This doc bridges what Figma's spec gives you with what `swiftui-pro` requires. The 9 reference files in `swiftui-pro/` are canonical — do not duplicate rule text here. This bridge only adds:

1. Tension resolutions when Figma intent appears to conflict with swiftui-pro
2. Transform tables that convert naive Figma→SwiftUI output into compliant code
3. iOS 16 baseline fallbacks for rules that target iOS 17/18/26
4. Project-context branches that depend on Phase C1 audit flags

Project baseline (locked): **iOS 16+**, **Localizable.xcstrings**, design constants enums **`Spacing`**, **`IKFont`**, **`IKCoreApp`**.

---

## §1. Tension resolutions (read first)

### 1a. Pixel fidelity vs "no hard-coded values"

`design.md`: *"Avoid hard-coded values for padding and stack spacing unless specifically requested"*. Figma values ARE specifically requested — they're the spec. So:

- **If `Spacing` enum exists in project (it does) → route Figma values through it.** `Spacing.l24` if `24` is defined; if no token matches, fall back inline.
- **If no enum / no matching token → inline literal is compliant.** `.padding(24)` is fine because the value is specifically requested by the design.
- **Never invent token names.** If Figma says 23pt and `Spacing.l24` is the closest, you have two choices: (a) use `Spacing.l24` with a comment if the user accepts the 1pt drift, or (b) use literal `23`. Do NOT add `Spacing.l23` to the enum without explicit user approval.

### 1b. Custom font sizes vs Dynamic Type

`accessibility.md`: *"Do not force specific font sizes. Prefer Dynamic Type. If you need a custom font size, use @ScaledMetric"*. Figma typography is custom by definition.

Decision tree per text style in inventory:
1. Does the Figma size match a Dynamic Type role? (Body=17, Headline=17 semibold, Title2=22, Title3=20, Subheadline=15, Footnote=13, Caption=12, Caption2=11.) → use the role: `.font(.body)`, `.font(.headline)`, etc.
2. Does the project's `IKFont` enum already define this typography? → use `IKFont.bodyMedium16` (or whatever the project's case names are; C1 audit lists them).
3. Else → `@ScaledMetric var fontSize: CGFloat = <figma>` declared at the top of the View struct, then `.font(.system(size: fontSize, weight: <weight>))`. Never inline `.font(.system(size: 16))` without `@ScaledMetric` — it breaks Dynamic Type.

### 1c. Figma colors vs Asset Catalog

- If `useGeneratedSymbols = true` (C1 audit) AND project has a color asset matching the Figma value → `Color(.brandRed)`.
- If project has `IKCoreApp.colors.*` or similar token enum → use that.
- Else if `Color(hex:)` extension exists in project → `Color(hex: "#FF6600")`.
- Else `Color(red: 1.0, green: 0.4, blue: 0.0)` with a `// TODO: extract to asset catalog` comment.

### 1d. Hard-coded strings vs xcstrings symbol API

Localization is **xcstrings (locked)**. Default codegen uses symbol-key API:

```swift
Text(.welcomeMessage)               // ✓ symbol from String Catalog Symbols
Text("Welcome", bundle: .main)      // ✗ string literal — only when localization isn't desired
```

Procedure: when emitting `Text(...)` for any user-facing string, add the key to the project's `Localizable.xcstrings` with `extractionState: "manual"`, then reference via the generated symbol. Offer to translate the new key into every language already in the catalog.

If the project's xcstrings symbols haven't been generated yet, fall back to `Text("Welcome")` (which `LocalizedStringKey` picks up) and note it in the run summary so the user can enable `String Catalog Symbols` build setting.

### 1e. Re-using project tokens — search order

For every Figma value (color, font, spacing, radius, animation), search project in this order:
1. `IKCoreApp.colors.*`, `IKCoreApp.spacing.*`, etc. — top-level app tokens
2. `Spacing.*`, `IKFont.*` — domain-specific enums
3. Asset catalog symbol (`Color(.x)` if `useGeneratedSymbols`)
4. Local computed constant in the same module
5. Inline literal (last resort)

C1 audit lists what's available; C2 picks the highest-priority match per value.

---

## §2. Always-on transforms (apply at C2, regardless of project context)

These rules apply on every emit, every project. The deployment target is **iOS 16+** so rules that need iOS 17+ have explicit fallbacks in §6.

| # | Figma input | Naive output | swiftui-pro-compliant | Source rule |
|---|---|---|---|---|
| 1 | Bold weight on text | `.fontWeight(.bold)` | `.bold()` | design.md L27 |
| 2 | Color modifier | `.foregroundColor(.red)` | `.foregroundStyle(.red)` | api.md L3 |
| 3 | Top toolbar leading slot | `.toolbar { ToolbarItem(placement: .navigationBarLeading)` | iOS 17+ → `.topBarLeading`. **iOS 16 → keep `.navigationBarLeading` (mandatory fallback)**. Always emit comment marker. See §6. | api.md L11 |
| 4 | Top toolbar trailing | as above | Same fallback. See §6. | api.md L11 |
| 5 | Decorative Figma image | `Image("decorativeBlob")` (no a11y) | `Image(decorative: "decorativeBlob")` | accessibility.md L6 |
| 6 | Meaningful icon image | `Image("icAIClose")` (no a11y) | `Image("icAIClose").accessibilityLabel("Close")` (label derived from semantic Figma name) | accessibility.md L6 |
| 7 | Icon-only `Button` | `Button { } label: { Image(...) }` | `Button("Close", systemImage: "xmark", action: close)` form OR keep custom label and add `.accessibilityLabel("Close")`. Never icon-only without a label. | accessibility.md L9 |
| 8 | Tap action via gesture | `.onTapGesture { ... }` | `Button { ... } label: { ... }` | accessibility.md L12 |
| 9 | Hide scroll indicators | `ScrollView(showsIndicators: false)` | `ScrollView { ... }.scrollIndicators(.hidden)` | api.md L17 |
| 10 | Overlay with content | `.overlay(Text("..."), alignment: .top)` | `.overlay(alignment: .top) { Text("...") }` | api.md L10 |
| 11 | Stroke + fill on shape | `Shape().fill(c).overlay(Shape().stroke(...))` | iOS 17+ → chained `.fill().stroke()`. **iOS 16 → keep overlay form**. See §6. | api.md L13 |
| 12 | SwiftUI Preview | `struct V_Previews: PreviewProvider { static var previews: some View { ... } }` | `#Preview { V() }` | views.md L12 |
| 13 | Conditional modifier | `if cond { v.opacity(0.5) } else { v }` | `v.opacity(cond ? 0.5 : 1)` | performance.md L3 |
| 14 | Animation modifier | `.animation(.easeIn)` | `.animation(.easeIn, value: stateVar)` | views.md L20 |
| 15 | Tap target < 44pt | raw `.frame(width: 24, height: 24)` on `Button` | `.contentShape(.rect).frame(minWidth: 44, minHeight: 44)` (or wrap content in 44+ frame) | design.md L12 |
| 16 | View body length > ~40 lines | computed property `private var header: some View { ... }` | Extract to a separate `View` struct in its own file (vd. `LoginHeaderView.swift`) | views.md L3 |
| 17 | Inline business logic in `body`/`task`/`onAppear` | `.task { try? await api.fetch() }` | Extract to method (`loadData()`) called from `.task`, or move to `@Observable` view model | views.md L4–7 |
| 18 | Avoid `Image(systemName:)` for designed icons | `Image(systemName: "xmark")` | `Image("icAIClose")` (downloaded in Phase B). Allowed exceptions: native `NavigationStack` back chevron, share-sheet icons. See ABSOLUTE RULE in SKILL.md. | (figma-to-swiftui rule, harmonizes with accessibility.md) |
| 19 | `Text` concatenation with `+` | `Text("Hello") + Text("World")` | Interpolate: `let h = Text("Hello"); let w = Text("World"); Text("\(h)\(w)")` | api.md L18 |
| 20 | `Group` wrapping single child | redundant `Group { ChildView() }` | Just `ChildView()` | (general SwiftUI hygiene) |
| 21 | Nav title style | `.navigationTitle(...)` only | Confirm `.navigationBarTitleDisplayMode(.inline/.large)` matches Figma; use `Text(.titleKey)` symbol | navigation.md (general) |
| 22 | Navigation route | `NavigationLink("Next", destination: NextView())` | `NavigationLink("Next", value: Route.next)` + `.navigationDestination(for: Route.self)` registered once on the stack root | navigation.md L4 |
| 23 | Navigation root | `NavigationView` | `NavigationStack` (or `NavigationSplitView`) | navigation.md L3 |

---

## §3. Project-context-dependent transforms (C1 audit gates)

Phase C1 sets these flags by inspecting the project. C2 branches on them.

| Flag | C1 detection | If TRUE | If FALSE |
|---|---|---|---|
| `useGeneratedSymbols` | grep `pbxproj` for `GENERATE_ASSET_SYMBOLS = YES`; or check Xcode 15+ default behavior | `Image(.icAIClose)`, `Color(.brandRed)` | `Image("icAIClose")`, `Color("brandRed")` |
| `useStringCatalogSymbols` | xcstrings present + `STRING_CATALOG_GENERATE_SYMBOLS = YES` | `Text(.welcomeMessage)` + add key to .xcstrings (extractionState: manual) + offer translate | `Text("Welcome")` (LocalizedStringKey infers) |
| `hasSpacingEnum` | grep `enum Spacing` (locked: project uses this) | Route Figma spacing values through `Spacing.<token>` | Inline literal `.padding(24)` |
| `hasIKFont` | grep `IKFont` enum (locked: project uses this) | Use `IKFont.<token>` for typography | `@ScaledMetric` + `.font(.system(size:weight:))` |
| `hasIKCoreApp` | grep `IKCoreApp` (locked: project uses this) | Use `IKCoreApp.colors.<token>`, `IKCoreApp.spacing.<token>`, etc. | Fallback by category (color asset / Spacing / IKFont) |
| `deploymentTarget` | read `IPHONEOS_DEPLOYMENT_TARGET` from pbxproj | gates §6 fallbacks | as decided by §6 |
| `hasColorHexExtension` | grep `Color\(hex:` extension/init | use `Color(hex: "#FF6600")` for un-tokenized colors | `Color(red:green:blue:)` |
| `hasLottieSDK` | grep `import Lottie` or `Package.resolved` for `lottie-ios` | eAnim* placeholders codegen `LottieView` | warn user, defer or skip |

The skill always prints the resolved flags at end of C1 so the user can verify routing decisions before any code is written.

---

## §4. Structural rules (apply at C3 Pass 4 review)

These can drift even with careful C2 emission. Pass 4 review catches them.

| # | Anti-pattern | Required fix | Source rule |
|---|---|---|---|
| 1 | View body > ~40 lines with computed properties returning `some View` | Extract each into separate `View` struct in its own file | views.md L3, L14 |
| 2 | Multiple types in one file | Each struct/class/enum in its own file | views.md L8 |
| 3 | Inline business logic in `body`/`task`/`onAppear` | Method extraction or `@Observable` view model | views.md L4–7 |
| 4 | `@Observable` class missing `@MainActor` | Add `@MainActor` (unless project default) | data.md L10 |
| 5 | `Binding(get:set:)` in body | `@State` + `onChange()` | data.md L23 |
| 6 | `NavigationView` | `NavigationStack` | navigation.md L3 |
| 7 | `NavigationLink(destination:)` | `navigationDestination(for:)` | navigation.md L4 |
| 8 | Navigation hierarchy mixes `navigationDestination(for:)` and `NavigationLink(destination:)` | Pick one; never mix | navigation.md L5 |
| 9 | Force unwrap (`!`) on user-driven path | `if let` / `guard let` / `??` | swift.md L7 |
| 10 | `DispatchQueue.main.async` | `Task { @MainActor in ... }` | swift.md L49 |
| 11 | `Task.sleep(nanoseconds:)` | `Task.sleep(for: .seconds(...))` | swift.md L50 |
| 12 | `GeometryReader` for layout | iOS 17+ → `containerRelativeFrame()` / `visualEffect()` / `Layout`. **iOS 16 → `GeometryReader` is allowed (no native alternative).** | api.md L7 |
| 13 | `AnyView` | `@ViewBuilder` / `Group` / generics | performance.md L4 |
| 14 | `UIScreen.main.bounds` | `containerRelativeFrame` / `GeometryReader` (iOS 16) | design.md L10 |
| 15 | Manual date format `"yyyy-MM-dd"` for display | `Text(date, format: .dateTime.day().month().year())` | swift.md L15 |
| 16 | `.frame(width: 100, height: 100)` on text-bearing view | Allow flex; use `minWidth`/`minHeight` if a minimum is needed | design.md L11 |
| 17 | `ObservableObject` + `@Published` + `@StateObject` | iOS 17+ → `@Observable` + `@State` + `@Bindable`. **iOS 16 → keep ObservableObject form (no choice).** Add comment marker. | data.md L11 |
| 18 | `fontWeight(.medium)`, `.semibold`, etc. scattered | Reserve `fontWeight()` for non-bold weights with reason; prefer Dynamic Type roles or `IKFont` | design.md L28 |
| 19 | `caption2` font | Avoid; `caption` only when justified | design.md L31 |
| 20 | `UIColor` in SwiftUI | `Color` or asset catalog | design.md L30 |

---

## §5. Output format for Pass 4 review

Mirror swiftui-pro SKILL.md "Output Format". Group findings by file:

```
### LoginView.swift

**Line 12: Use `foregroundStyle()` instead of `foregroundColor()`.**

```swift
// Before
Text("Hello").foregroundColor(.red)

// After
Text("Hello").foregroundStyle(.red)
```

**Line 24: Icon-only button is bad for VoiceOver — add a text label.**

```swift
// Before
Button(action: close) { Image("icAIClose") }

// After
Button("Close", action: close) {
    Image("icAIClose")
        .accessibilityHidden(true)   // image is decorative; the Button label provides accessibility
}
```

### Summary

1. **Accessibility (high):** the close button on line 24 is invisible to VoiceOver.
2. **Deprecated API (medium):** `foregroundColor()` on line 12.
```

End each Pass 4 with this prioritized summary so user knows what to address first.

---

## §6. iOS 16 fallback table

The project baseline is iOS 16+. swiftui-pro is written assuming iOS 18+/26 in places. When emitting for iOS 16, branch as follows. **Always include the fallback comment marker** so future iOS bumps can search-replace.

Comment marker format:
```swift
// iOS 16 fallback — switch to <modern API> at iOS <N>+
```

| swiftui-pro rule | API min | iOS 16 emission |
|---|---|---|
| `Tab("...", systemImage:..., value:..)` (api.md L5) | iOS 18 | `tabItem { Label("Home", systemImage: "house") }` + `.tag(.home)` |
| `.topBarLeading` / `.topBarTrailing` (api.md L11) | iOS 17 | `.navigationBarLeading` / `.navigationBarTrailing` |
| `.clipShape(.rect(cornerRadius:))` (api.md L4) | iOS 17 | `.clipShape(RoundedRectangle(cornerRadius: 12))` |
| `@Entry` macro (api.md L9) | iOS 18 / Xcode 16 | Manual `EnvironmentKey` + `EnvironmentValues` extension |
| `@Observable` (data.md L11) | iOS 17 | `ObservableObject` + `@Published` + `@StateObject`/`@ObservedObject` |
| `@Bindable` (data.md L11) | iOS 17 | `@ObservedObject` + `$model.field` direct |
| `WebView` native (api.md L15) | iOS 26 | `UIViewRepresentable` wrap of `WKWebView` |
| `Image(.assetName)` symbol (api.md L14) | build-time only | ✓ Use directly when `useGeneratedSymbols` |
| `Text(.symbolKey)` xcstrings (hygiene.md L8) | build-time only | ✓ Use directly when `useStringCatalogSymbols` |
| `#Preview` macro (views.md L12) | Xcode 15+ runtime any | ✓ Use directly |
| `containerRelativeFrame()` (api.md L7) | iOS 17 | Use `GeometryReader` (allowed exception on iOS 16) |
| `.scrollIndicators(.hidden)` (api.md L17) | iOS 16 | ✓ Use directly |
| `.bold()` modifier on view (design.md L27) | iOS 16 | ✓ Use directly |
| `.foregroundStyle()` (api.md L3) | iOS 15 | ✓ Always |
| `overlay(alignment:content:)` (api.md L10) | iOS 15 | ✓ Always |
| `.fill().stroke()` chained (api.md L13) | iOS 17 | Keep `.overlay { Shape().stroke(...) }` form |
| `sensoryFeedback()` (api.md L8) | iOS 17 | `UIImpactFeedbackGenerator` |
| `NavigationStack` (navigation.md L3) | iOS 16 | ✓ Use directly |
| `navigationDestination(for:)` (navigation.md L4) | iOS 16 | ✓ Use directly |
| `task()` modifier (performance.md L13) | iOS 15 | ✓ Always |
| `LazyVStack`/`LazyHStack` | iOS 14 | ✓ Always |
| `.font(.body.scaled(by:))` (accessibility.md L5) | iOS 26 | `@ScaledMetric var fontSize: CGFloat = 16` + `.font(.system(size: fontSize, weight: ...))` |
| `String Catalog Symbols` (hygiene.md L8) | Xcode 15+ build setting | ✓ Use directly when build setting on |
| `scrollContentBackground` (performance.md L5) | iOS 16 | ✓ Use directly |
| `scrollTargetBehavior` | iOS 17 | Skip — use `.scrollTargetLayout` only when target ≥17 |
| `Symbol effects` (`.symbolEffect`) | iOS 17 | Skip on iOS 16 — leave SF Symbols static |
| `sensoryFeedback` (haptics) | iOS 17 | `UIImpactFeedbackGenerator` |
| `fontDesign(.rounded)` | iOS 16.1+ | OK on most iOS 16 patches; verify if exact 16.0 minimum required |

When the user later bumps the project to iOS 17+ or 18+, search for `// iOS 16 fallback —` comment markers — every occurrence is an upgrade candidate.

---

## §7. Project tokens reference (locked: `Spacing`, `IKFont`, `IKCoreApp`)

C1 audit grep confirms these enums exist; C2 routes Figma values through them.

**`Spacing` (spacing/padding/gap):**
```swift
.padding(.horizontal, Spacing.l24)         // not .padding(.horizontal, 24)
VStack(spacing: Spacing.m16) { ... }        // not VStack(spacing: 16)
```
Token mapping: ask the project's existing usage — common conventions `Spacing.xs4`, `s8`, `m16`, `l24`, `xl32`, `xxl48`. If Figma value doesn't match an existing token, fall back to inline literal with comment `// TODO: align with Spacing enum if appropriate`.

**`IKFont` (typography):**
```swift
Text(.welcomeMessage).font(IKFont.headlineSemibold20)
```
For each Figma typography style (size + weight + lineHeight + tracking), find the closest `IKFont` case. If none exists, use `@ScaledMetric` + `.font(.system(size:weight:))`. Never invent new `IKFont` cases without user approval.

**`IKCoreApp` (top-level app tokens):**
```swift
.foregroundStyle(IKCoreApp.colors.textPrimary)
.padding(IKCoreApp.spacing.contentPadding)
```
Often namespaces the others (`IKCoreApp.colors.*`, `IKCoreApp.spacing.*`). C1 audit lists what's exposed.

If a value doesn't fit any token, codegen surfaces it in the run summary so the user knows where the design system needs an addition (no auto-edit of these enums).

---

## §8. Quick reference — what NOT to do

These are the most common drifts when generating from Figma. Self-check Pass 4 catches them, but C2 should avoid them outright.

```swift
// ✗ DON'T
.foregroundColor(.red)
.cornerRadius(12)
.fontWeight(.bold)
Text("Hello") + Text(" World")
struct V_Previews: PreviewProvider { ... }
Button(action: close) { Image("icAIClose") }       // missing accessibility
.onTapGesture { closeAction() }                     // not a Button
if loading { v.opacity(0.5) } else { v }           // _ConditionalContent
.animation(.easeIn)                                  // no value
ScrollView(showsIndicators: false) { ... }
DispatchQueue.main.async { ... }
Task { try! await api.load() }                      // force try

// ✓ DO
.foregroundStyle(.red)
.clipShape(RoundedRectangle(cornerRadius: 12))      // iOS 16 form
.bold()
let h = Text("Hello"); let w = Text(" World"); Text("\(h)\(w)")
#Preview { V() }
Button("Close", action: close) { Image("icAIClose").accessibilityHidden(true) }
Button { closeAction() } label: { Image("icAIClose").accessibilityHidden(true) }.accessibilityLabel("Close")
v.opacity(loading ? 0.5 : 1)
.animation(.easeIn, value: loading)
ScrollView { ... }.scrollIndicators(.hidden)
Task { @MainActor in await load() }
do { try await api.load() } catch { showError(error) }
```
