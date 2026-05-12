# swiftui-pro Bridge for Figma → SwiftUI

Bridges Figma spec with swiftui-pro requirements. The consolidated [`swiftui-pro-rules.md`](swiftui-pro-rules.md) is canonical — this bridge adds tension resolutions, transform tables, iOS 16 fallbacks, and project-context branches.

Baseline: **iOS 16+**, **Localizable.xcstrings**, optional design enums `Spacing` / `IKFont` / `IKCoreApp`.

---

## §1. Tension resolutions

### 1a. Pixel fidelity vs "no hard-coded values"

Figma values ARE the spec — they're specifically requested. Resolution:

- `Spacing` enum exists + token matches → route through it (`Spacing.l24`)
- No enum / no matching token → inline literal compliant (`.padding(24)`)
- **Never invent token names.** If Figma says 23pt and `Spacing.l24` is closest: use `Spacing.l24` with comment if user accepts 1pt drift, or use literal `23`. Do NOT add `Spacing.l23` without explicit user approval.

### 1b. Custom font sizes vs Dynamic Type

For each text style:
1. Matches Dynamic Type role? (Body=17, Headline=17 semibold, Title2=22, Title3=20, Subheadline=15, Footnote=13, Caption=12) → use role: `.font(.body)`
2. `IKFont` enum already defines? → use `IKFont.bodyMedium16`
3. Else → `@ScaledMetric var fontSize: CGFloat = <figma>` + `.font(.system(size: fontSize, weight:))`. **Never inline `.font(.system(size: 16))` without `@ScaledMetric`** — breaks Dynamic Type.

### 1c. Figma colors vs Asset Catalog

Resolution order:
1. `IKCoreApp.colors.*` token match → use
2. Asset catalog color asset → `Color(.brandRed)` (auto-generated `ColorResource`). String form `Color("brandRed")` BANNED.
3. Light-only `Color+Tokens.swift` extension → `Color.brandRed`
4. `Color(hex:)` extension exists → `Color(hex: "#FF6600")`
5. `Color(red: 1.0, green: 0.4, blue: 0.0)` + `// TODO: extract to asset catalog`

### 1d. Hard-coded strings vs xcstrings symbols

xcstrings is canonical (locked baseline). Default emission:
```swift
Text(.welcomeMessage)               // ✓ symbol from String Catalog Symbols
Text("Welcome", bundle: .main)      // ✗ only when localization not desired
```

Add key to `Localizable.xcstrings` with `extractionState: "manual"`, then reference via symbol. Offer to translate into existing catalog languages.

If catalog symbols not generated yet → `Text("Welcome")` (LocalizedStringKey picks up) + note in run summary.

### 1e. Re-using project tokens — search order

For every Figma value:
1. Project color audit map (`.figma-cache/_shared/project-colors.json`) — for colors only; `swiftPath` from entry
2. `IKCoreApp.colors.*`, `IKCoreApp.spacing.*` — top-level app tokens
3. `Spacing.*`, `IKFont.*` — domain-specific enums
4. Asset catalog symbol — `Color(.x)` (auto-generated `ColorResource`)
5. Local computed constant in module
6. Inline literal (last resort)

---

## §2. Always-on transforms (apply at C2, every project)

| # | Figma input | Naive | swiftui-pro-compliant |
|---|---|---|---|
| 1 | Bold text | `.fontWeight(.bold)` | `.bold()` |
| 2 | Color modifier | `.foregroundColor(.red)` | `.foregroundStyle(.red)` |
| 3 | Top toolbar leading | `.navigationBarLeading` | iOS 17+ → `.topBarLeading`. **iOS 16 → keep `.navigationBarLeading`** + comment marker |
| 4 | Top toolbar trailing | same | Same fallback |
| 5 | Decorative image | `Image(.decorativeBlob)` | `Image(decorative: .decorativeBlob)` |
| 6 | Meaningful icon | `Image(.icAIClose)` | `Image(.icAIClose).accessibilityLabel("Close")` (label from semantic Figma name) |
| 7 | Icon-only button | `Button { } label: { Image(...) }` | `Button("Close", systemImage: "xmark", action: close)` OR custom label + `.accessibilityLabel("Close")` |
| 8 | Tap action via gesture | `.onTapGesture { ... }` | `Button { ... } label: { ... }` |
| 9 | Hide scroll indicators | `ScrollView(showsIndicators: false)` | `ScrollView { ... }.scrollIndicators(.hidden)` |
| 10 | Overlay with content | `.overlay(Text("..."), alignment: .top)` | `.overlay(alignment: .top) { Text("...") }` |
| 11 | Stroke + fill on shape | overlay form | iOS 17+ → chained `.fill().stroke()`. **iOS 16 → keep overlay form** |
| 12 | SwiftUI Preview | `struct V_Previews: PreviewProvider` | `#Preview { V() }` |
| 13 | Conditional modifier | `if cond { v.opacity(0.5) } else { v }` | `v.opacity(cond ? 0.5 : 1)` |
| 14 | Animation | `.animation(.easeIn)` | `.animation(.easeIn, value: stateVar)` |
| 15 | Tap target < 44pt | raw `.frame(width: 24, height: 24)` on Button | `.contentShape(.rect).frame(minWidth: 44, minHeight: 44)` |
| 16 | View body > ~40 lines with `@ViewBuilder` computed prop | extract to separate `View` struct in own file |
| 17 | Inline business logic in `body`/`task`/`onAppear` | Extract to method or `@Observable` view model |
| 18 | `Image(systemName:)` for designed icons | `Image(.icAIClose)` (Phase B downloaded). Allowed: native back chevron, share-sheet icons |
| 19 | `Text + Text` concat | Interpolate: `Text("\(h)\(w)")` |
| 20 | `Group` wrapping single child | Just `ChildView()` |
| 21 | Nav title | `.navigationTitle(...)` + `.navigationBarTitleDisplayMode(.inline/.large)` + `Text(.titleKey)` symbol |
| 22 | Navigation route | `NavigationLink("Next", value: Route.next)` + `.navigationDestination(for: Route.self)` |
| 23 | Navigation root | `NavigationView` → `NavigationStack` |

---

## §3. Project-context-dependent transforms (C1 audit gates)

C1 sets these flags in `c1-conventions.json`. C2 reads and branches.

| Flag | C1 detection | If TRUE | If FALSE |
|---|---|---|---|
| `useGeneratedSymbols` | `GENERATE_ASSET_SYMBOLS = YES` (default-on Xcode 15+) | `Image(.icAIClose)`, `Color(.brandRed)` | Legacy `Image("icAIClose")` (flagged as non-modern) |
| `useStringCatalogSymbols` | xcstrings + `STRING_CATALOG_GENERATE_SYMBOLS = YES` | `Text(.welcomeMessage)` + add key | `Text("Welcome")` (LocalizedStringKey infers) |
| `spacingEnum` | grep `enum Spacing\|AppSpacing\|Padding` | Route via `<enum>.<token>` | Inline literal `.padding(24)` |
| `ikFontEnum` | grep `enum IKFont\|AppFont\|Typography` | Use `<enum>.<token>` | `@ScaledMetric` + `.font(.system(size:weight:))` |
| `colorEnum` | grep `enum IKCoreApp\|AppColors\|ColorPalette` | Use `<enum>.colors.<token>` | Fallback by category |
| `minDeploymentTarget` | `IPHONEOS_DEPLOYMENT_TARGET` from pbxproj | Gates §6 fallbacks | As decided by §6 |
| `hasColorHexExtension` | grep `Color\(hex:` extension | Use `Color(hex: "#FF6600")` | `Color(red:green:blue:)` |
| `hasLottieSDK` | grep `import Lottie`/`Package.resolved`/`lottie-ios` | eAnim* → `LottieView` | Warn user, defer or skip |
| `screenFolderConvention` | `Screens/<X>/<X>Screen.swift` count ≥ 2 | New screen at `Screens/<Name>/...` per [`project-structure.md`](project-structure.md) | Single-file output at user-requested path |
| `viewModelPattern` | `enum Action` + `func send(_ action: Action)` in latest VM | Match existing reducer shape | Canonical reducer per [`viewmodel-pattern.md`](viewmodel-pattern.md) |
| `observationFlavor` | iOS 17+ AND project uses `@Observable` | `@Observable @MainActor` | `ObservableObject` + `@Published` |
| `usesIKNavigation` | `import IKNavigation`/`IKRouter`/`@Environment(\.ikNavigationable)` | Emit per [`iknavigation-bridge.md`](iknavigation-bridge.md) | Vanilla `NavigationStack` |
| `usesIKMacros` | `import IKMacros`/`@APIProtocol`/`@JsonSerializable` | Per [`ikmacro-bridge.md`](ikmacro-bridge.md) | Plain `Codable` + `URLSession` |
| `usesIKCoreApp` | `pod 'IKCoreApp'` OR `import IKCoreApp` (umbrella) | Cascade all dependent flags TRUE | Per-flag detection still applies |
| `usesIKPopup` | `usesIKCoreApp` OR `IKPopup.shared.popup(` | Per [`ikpopup-bridge.md`](ikpopup-bridge.md) | Vanilla `.sheet` / `.alert` |
| `usesIKFeedback` | `usesIKCoreApp` OR `IKLoading.show*` OR `IKHaptics.` | Per [`ikfeedback-bridge.md`](ikfeedback-bridge.md) | `UIImpactFeedbackGenerator` / iOS 17 `.sensoryFeedback` |
| `usesIKFont` | `usesIKCoreApp` OR `.ikFont(`/`.ikBody()`/etc. | Per [`fonts-styling-bridge.md`](fonts-styling-bridge.md) | `AppFont.swift` from B0b |

C1 prints resolved flags at end so user can verify routing.

---

## §4. Structural rules (apply at C3 Pass 4 review)

| # | Anti-pattern | Required fix |
|---|---|---|
| 1 | View body > ~40 lines with computed `@ViewBuilder` props | Extract to separate `View` struct in own file |
| 2 | Multiple types in one file | Each struct/class/enum in own file |
| 3 | Inline business logic in `body`/`task`/`onAppear` | Method or `@Observable` view model |
| 4 | `@Observable` class missing `@MainActor` | Add `@MainActor` |
| 5 | `Binding(get:set:)` in body | `@State` + `onChange()` |
| 6 | `NavigationView` | `NavigationStack` |
| 7 | `NavigationLink(destination:)` | `navigationDestination(for:)` |
| 8 | Mixing `navigationDestination(for:)` + `NavigationLink(destination:)` | Pick one; never mix |
| 9 | Force unwrap on user-driven path | `if let`/`guard let`/`??` |
| 10 | `DispatchQueue.main.async` | `Task { @MainActor in ... }` |
| 11 | `Task.sleep(nanoseconds:)` | `Task.sleep(for: .seconds(...))` |
| 12 | `GeometryReader` for layout | iOS 17+ → `containerRelativeFrame()`. **iOS 16 → GeometryReader allowed** |
| 13 | `AnyView` | `@ViewBuilder`/`Group`/generics |
| 14 | `UIScreen.main.bounds` | `containerRelativeFrame`/`GeometryReader` |
| 15 | Manual `"yyyy-MM-dd"` for display | `Text(date, format: .dateTime.day().month().year())` |
| 16 | `.frame(width:height:)` on text-bearing view | Allow flex; `minWidth`/`minHeight` if needed |
| 17 | `ObservableObject` + `@Published` + `@StateObject` | iOS 17+ → `@Observable` + `@State` + `@Bindable`. **iOS 16 → keep ObservableObject** + comment marker |
| 18 | `.fontWeight(.medium/.semibold)` scattered | Reserve for non-bold weights with reason; prefer Dynamic Type roles |
| 19 | `caption2` font | Avoid; `caption` only when justified |
| 20 | `UIColor` in SwiftUI | `Color` or asset catalog |

---

## §5. Output format for Pass 4 review

Group findings by file:

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

### Summary

1. **Accessibility (high):** close button on line 24 invisible to VoiceOver.
2. **Deprecated API (medium):** `foregroundColor()` on line 12.
```

---

## §6. iOS 16 fallback table

Baseline iOS 16+. Comment marker format: `// iOS 16 fallback — switch to <modern API> at iOS <N>+`.

| swiftui-pro rule | Min iOS | iOS 16 emission |
|---|---|---|
| `Tab("...", systemImage:, value:)` | 18 | `tabItem { Label("Home", systemImage: "house") }` + `.tag(.home)` |
| `.topBarLeading` / `.topBarTrailing` | 17 | `.navigationBarLeading` / `.navigationBarTrailing` |
| `.clipShape(.rect(cornerRadius:))` | 17 | `.clipShape(RoundedRectangle(cornerRadius: 12))` |
| `@Entry` macro | 18 / Xcode 16 | Manual `EnvironmentKey` + `EnvironmentValues` extension |
| `@Observable` + `@Bindable` | 17 | `ObservableObject` + `@Published` + `@StateObject`/`@ObservedObject` + `$model.field` |
| `WebView` native | 26 | `UIViewRepresentable` wrap `WKWebView` |
| `containerRelativeFrame()` | 17 | `GeometryReader` (allowed exception) |
| `.fill().stroke()` chained | 17 | `.overlay { Shape().stroke(...) }` |
| `sensoryFeedback()` | 17 | `UIImpactFeedbackGenerator` |
| `scrollTargetBehavior` | 17 | Skip — use `.scrollTargetLayout` only at ≥17 |
| `.symbolEffect` | 17 | Skip on iOS 16 — leave SF Symbols static |
| `.font(.body.scaled(by:))` | 26 | `@ScaledMetric var fontSize: CGFloat = 16` + `.font(.system(size: fontSize, ...))` |
| Always-available (✓ use directly) | — | `.foregroundStyle()`, `.bold()`, `overlay(alignment:content:)`, `NavigationStack`, `.navigationDestination(for:)`, `task()`, `.scrollIndicators(.hidden)`, `LazyVStack`/`LazyHStack`, `scrollContentBackground`, `Image(.assetName)`, `Text(.symbolKey)`, `#Preview` |

When project bumps to iOS 17+/18+: search `// iOS 16 fallback —` comment markers; each is an upgrade candidate.

---

## §7. Project tokens reference

C1 audit greps for enums + writes detected name to `c1-conventions.json` (or `null` when absent). **Detect-then-apply** — do NOT introduce a new `Spacing.swift` / `IKFont.swift` unless user asks.

**`spacingEnum`** (Common: `Spacing`, `AppSpacing`, `Padding`):
```swift
.padding(.horizontal, Spacing.l24)      // not .padding(.horizontal, 24)
VStack(spacing: Spacing.m16) { ... }
```
Cases: `Spacing.xs4`, `s8`, `m16`, `l24`, `xl32`, `xxl48`. C1 lists actual cases. `null` or no match → inline literal + `// Figma: 24` comment.

**`ikFontEnum`** (Common: `IKFont`, `AppFont`, `Typography`):
```swift
Text(.welcomeMessage).font(IKFont.headlineSemibold20)
```
For each Figma typography (size+weight+lineHeight+tracking), find closest case. None exists → `@ScaledMetric` + `.font(.system(size:weight:))`. Never invent new cases without approval.

**`colorEnum`** (Common: `IKCoreApp`, `AppColors`, `ColorPalette`):
```swift
.foregroundStyle(IKCoreApp.colors.textPrimary)
.padding(IKCoreApp.spacing.contentPadding)
```
Often namespaces others. `null` → prefer Asset Catalog → light-only extension → `Color(hex:)` → inline `Color(red:green:blue:)`. Never legacy string form.

Figma value doesn't fit any token → surface in run summary; skill never auto-edits enum files.

---

## §8. Quick reference — what NOT to do

```swift
// ✗ DON'T
.foregroundColor(.red)
.cornerRadius(12)
.fontWeight(.bold)
Text("Hello") + Text(" World")
struct V_Previews: PreviewProvider { ... }
Button(action: close) { Image(.icAIClose) }         // missing accessibility
.onTapGesture { closeAction() }                      // not a Button
if loading { v.opacity(0.5) } else { v }            // _ConditionalContent
.animation(.easeIn)                                   // no value
ScrollView(showsIndicators: false) { ... }
DispatchQueue.main.async { ... }
Task { try! await api.load() }

// ✓ DO
.foregroundStyle(.red)
.clipShape(RoundedRectangle(cornerRadius: 12))       // iOS 16 form
.bold()
let h = Text("Hello"); let w = Text(" World"); Text("\(h)\(w)")
#Preview { V() }
Button("Close", action: close) { Image(.icAIClose).accessibilityHidden(true) }
v.opacity(loading ? 0.5 : 1)
.animation(.easeIn, value: loading)
ScrollView { ... }.scrollIndicators(.hidden)
Task { @MainActor in await load() }
do { try await api.load() } catch { showError(error) }
```
