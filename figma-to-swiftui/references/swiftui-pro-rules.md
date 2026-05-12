# swiftui-pro Rules (consolidated)

**Source:** Paul Hudson `swiftui-pro` skill (MIT v1.0), snapshot 2026-04-27. Consolidated from 9 source files.

This defines the team's SwiftUI coding standard. `figma-to-swiftui` applies these at Phase C2 (write-time) + C3 Pass 4 (review). For Figma-specific transforms + iOS 16 fallbacks, see [`swiftui-pro-bridge.md`](swiftui-pro-bridge.md).

**Do NOT modify rules here.** Figma-specific guidance + iOS 16 overrides go in `swiftui-pro-bridge.md`.

---

## API (Modern SwiftUI)

- Always `foregroundStyle()` not `foregroundColor()`.
- Always `clipShape(.rect(cornerRadius:))` not `cornerRadius()`. (iOS 17+ — see iOS 16 fallback in bridge §6.)
- Always `Tab` API not `tabItem()`. (iOS 18+ — iOS 16 fallback in bridge.)
- Never use `onChange()` 1-parameter variant; use 2-parameter or 0-parameter.
- Avoid `GeometryReader` if `containerRelativeFrame()` / `visualEffect()` / `Layout` works. (iOS 16 exception: GeometryReader allowed.)
- Prefer `sensoryFeedback()` over `UIImpactFeedbackGenerator`. (iOS 17+.)
- Use `@Entry` macro for custom `EnvironmentValues`/`FocusValues`/`Transaction`/`ContainerValues` keys (iOS 18+). Replaces manual `EnvironmentKey` + `EnvironmentValues` extension.
- `overlay(alignment:content:)` over deprecated `overlay(_:alignment:)`. `.overlay { Text("Hello") }` not `.overlay(Text("Hello"))`.
- Never `.navigationBarLeading`/`.navigationBarTrailing` for toolbar (deprecated iOS 17+). Use `.topBarLeading`/`.topBarTrailing`. (iOS 16: use deprecated form.)
- Grammar agreement: `Text("^[\(people) person](inflect: true)")` for EN/FR/DE/PT/ES/IT.
- Fill + stroke a shape with chained modifiers (iOS 17+); no overlay needed. (iOS 16: keep overlay form.)
- Asset catalog: `Image(.avatar)` over `Image("avatar")` (generated symbol API).
- iOS 26+: native `WebView` over `UIViewRepresentable` wrap of `WKWebView`. `import WebKit`.
- `ForEach(items.enumerated(), id: \.element.id)` directly — don't convert to array first.
- `.scrollIndicators(.hidden)` not `showsIndicators: false` in initializer.
- Never `Text` concatenation with `+`. Use interpolation:
  ```swift
  let red = Text("Hello").foregroundStyle(.red)
  let blue = Text("World").foregroundStyle(.blue)
  Text("\(red)\(blue)")
  ```
- `ObservableObject` requires `import Combine` (no longer transitively from SwiftUI).

---

## Views

- **Strongly prefer to avoid breaking view bodies using computed properties / methods returning `some View`**, even with `@ViewBuilder`. Extract into separate `View` structs in their own files.
- Flag `body` properties that are excessively long → break into extracted subviews.
- Button actions extracted from view bodies into separate methods (separate layout + logic).
- Business logic should not live inline in `task()`, `onAppear()`, or `body`. Place into view models or similar (testable).
- Each type (struct/class/enum) in its own Swift file. Flag multi-type files.
- Unless full-screen editing required, prefer `TextField(axis: .vertical)` over `TextEditor` (placeholder support). `lineLimit(5...)` for minimum height.
- Button action as `action` param: `Button("Label", systemImage: "plus", action: myAction)` over `Button("Label", systemImage: "plus") { action() }`.
- Render SwiftUI views to images via `ImageRenderer`, not `UIGraphicsImageRenderer`.
- `#Preview` for previews, not legacy `PreviewProvider`.
- `TabView(selection:)` bind to enum-stored property, not Int/String. `Tab("Home", systemImage: "house", value: .home)`.

### Animating views

- `@Animatable` macro over manual `animatableData`. Mark non-animatable props (Bool, Int) with `@AnimatableIgnored`.
- Never `animation(_ animation: Animation?)`; always provide value: `.animation(.bouncy, value: score)`.
- Chain animations via `completion` closure of `withAnimation()`, not multiple `withAnimation()` with delays:
  ```swift
  withAnimation {
      scale = 2
  } completion: {
      withAnimation { scale = 1 }
  }
  ```

---

## Data flow

### Shared state

- `@Observable` classes MUST be `@MainActor` unless project has Main Actor default isolation.
- Shared data uses `@Observable` + `@State` (ownership) + `@Bindable`/`@Environment` (passing).
- Avoid `ObservableObject`/`@Published`/`@StateObject`/`@ObservedObject`/`@EnvironmentObject` unless legacy/integration. (iOS 16: use these — see bridge §6.)

### Local state

- `@State` private + only owned by the view that created it.
- Class with expensive-to-recompute data (`CIContext`): `@State` is OK as a cache.

### Bindings

- Avoid `Binding(get:set:)` in view body. Use `@State`/`@Binding` + `onChange()`.
- `TextField` for numeric input: bind to numeric value + `format` init: `TextField("Score", value: $score, format: .number)` + `.keyboardType(.numberPad)`/`.decimalPad`.

### Working with data

- Conform structs to `Identifiable` rather than `id: \.someProperty` in SwiftUI.
- Never `@AppStorage` inside `@Observable` class (even `@ObservationIgnored`) — won't trigger view updates.

### SwiftData with CloudKit

- Never `@Attribute(.unique)`.
- Model properties: default values OR optional.
- All relationships: optional.

---

## Accessibility

- Respect user accessibility settings (fonts, colors, animations).
- Do NOT force specific font sizes. Prefer Dynamic Type (`.font(.body)`, `.font(.headline)`, etc.).
- Custom font size: `@ScaledMetric` (iOS 18 and earlier). iOS 26+: `.font(.body.scaled(by:))`.
- Flag images with unclear VoiceOver readings (e.g. `Image(.newBanner2026)`). Decorative → `Image(decorative:)` or `accessibilityHidden()`. Otherwise `accessibilityLabel()`.
- Reduce Motion → replace large motion animations with opacity.
- Complex/changing button labels → `accessibilityInputLabels()` for better Voice Control. (E.g. live AAPL price button: add input label "Apple".)
- Image-label buttons MUST include text, even invisible: `Button("Label", systemImage: "plus", action: myAction)`. Flag icon-only without text.
- Color as differentiator → respect `.accessibilityDifferentiateWithoutColor` — also use icons, patterns, strokes.
- Same for `Menu`: `Menu("Options", systemImage: "ellipsis.circle") { }` over just an image.
- Never `onTapGesture()` unless need tap location/count. Use `Button`.
- If `onTapGesture()` MUST be used: `.accessibilityAddTraits(.isButton)`.

---

## Navigation and presentation

- `NavigationStack` or `NavigationSplitView`. Flag deprecated `NavigationView`.
- `navigationDestination(for:)` over old `NavigationLink(destination:)`.
- Never mix `navigationDestination(for:)` + `NavigationLink(destination:)` in same hierarchy.
- `navigationDestination(for:)` registered ONCE per data type. Flag duplicates.

### Alerts, dialogs, sheets

- Attach `confirmationDialog()` to the UI that triggers it (Liquid Glass anchor).
- Alert with single "OK" doing nothing → omit buttons: `.alert("Dismiss Me", isPresented: $isShowingAlert) { }`.
- Sheet presenting optional → `sheet(item:)` over `sheet(isPresented:)`.
- `sheet(item:)` with view taking item as only init param: `sheet(item: $someItem, content: SomeView.init)` over `sheet(item: $someItem) { someItem in SomeView(item: someItem) }`.

---

## Swift idioms

- Swift-native over Foundation: `replacing("a", with: "b")` not `replacingOccurrences(of:with:)`.
- Modern Foundation: `URL.documentsDirectory`, `appending(path:)`.
- Never C-style `String(format: "%.2f", value)`. Use `Text(value, format: .number.precision(.fractionLength(2)))`.
- Static member lookup: `.circle` over `Circle()`, `.borderedProminent` over `BorderedProminentButtonStyle()`.
- Avoid force unwraps (`!`) and force `try` unless truly unrecoverable. Use `if let`/`guard let`/`??`/`try?`/`do-catch`. `fatalError("...")` with description when unavoidable.
- User-input text filter: `localizedStandardContains()` over `contains()`/`localizedCaseInsensitiveContains()`.
- Prefer `Double` over `CGFloat` (Swift bridges automatically) — exception: optionals or `inout`.
- Count matching predicates: `count(where:)` not `filter().count`.
- `Date.now` over `Date()`.
- `import SwiftUI` already provides UIKit/AppKit types (`UIImage`, `NSImage`). No need to add.
- People names: `PersonNameComponents` over `Text("\(firstName) \(lastName)")`.
- Repeated sort with identical closure → conform type to `Comparable`.
- Avoid manual date formatting if possible. If needed for display: `"y"` not `"yyyy"` (year correct in all locales). Data exchange exception: doesn't apply.
- String → Date: modern `Date(myString, strategy: .iso8601)`.
- Flag swallowed errors (`print(error.localizedDescription)`) — show alert.
- `if let value {` shorthand over `if let value = value {`.
- Omit `return` for single-expression functions. Use `if`/`switch` as expressions:
  ```swift
  var tileColor: Color {
      if isCorrect { .green } else { .red }   // not "return .green / return .red"
  }
  ```

### Swift Concurrency

- Modern `async/await` over closure-based variants.
- Never GCD (`DispatchQueue.main.async()`, `.global()`). Always `async/await`, actors, `Task`.
- Never `Task.sleep(nanoseconds:)`. Use `Task.sleep(for:)`.
- Flag mutable shared state not protected by actor / `@MainActor` (assuming strict concurrency).
- Assume strict concurrency: flag `@Sendable` violations, data races.
- `MainActor.run()` — check project default actor isolation first.
- `Task.detached()` is often bad. Review carefully.

---

## Design

### Uniform design

Place fonts, sizes, colors, spacing, padding, rounding, animation timings into shared enum of constants → uniform + adjustable.

### Flexible accessible design

- Never `UIScreen.main.bounds`. Use `containerRelativeFrame()` / `visualEffect()` / (last resort) `GeometryReader`.
- Avoid fixed frames unless content fits neatly. Flexibility preferred (different device sizes, Dynamic Type).
- iOS minimum tap area: 44×44pt. Enforce strictly.

### Standard system styling

- `ContentUnavailableView` for empty/missing data, not custom designs.
- `searchable()`: `ContentUnavailableView.search` auto-includes the search term.
- Icon + text side-by-side: `Label` over `HStack`.
- Hierarchical styles (secondary/tertiary) over manual opacity.
- `Form`: wrap controls (`Slider`) in `LabeledContent` for title + control layout.
- `RoundedRectangle`: default `.continuous` rounding — no need to specify explicitly.

### Designs for everyone

- `bold()` over `fontWeight(.bold)` (system chooses correct weight for context).
- `fontWeight()` only for non-bold weights with reason. Avoid scattering `.medium`/`.semibold`.
- Avoid hard-coded padding/spacing unless specifically requested.
- Avoid `UIColor` in SwiftUI. Use `Color` / asset catalog.
- `.caption2` extremely small — avoid. `.caption` careful use.

---

## Performance

- Toggle modifier values via ternary, never `if/else` view branching (avoid `_ConditionalContent`, preserve identity).
- Avoid `AnyView` unless absolutely required. `@ViewBuilder` / `Group` / generics.
- `ScrollView` with opaque static solid background → `scrollContentBackground(.visible)` (better scroll-edge rendering).
- Break views into dedicated SwiftUI views, NOT computed properties/methods. `@ViewBuilder` doesn't solve this.
- Keep view initializers small. Move non-trivial work into `task()` modifier.
- Assume each view's `body` is called frequently. Move sorting/filtering out.
- Avoid storing `DateFormatter` properties unless required. Use `Text(Date.now, format: .dateTime.day().month().year())`.
- Avoid expensive inline transforms in `List`/`ForEach` initializers (e.g. repeated `items.filter { ... }`).
- Derive transformed data via `let` or cache in `@State` with explicit invalidation logic (avoid stale UI).
- Large datasets in `ScrollView`: `LazyVStack`/`LazyHStack`. Flag eager stacks with many children.
- `task()` over `onAppear()` for async work (auto-cancelled on disappear).
- Avoid storing escaping `@ViewBuilder` closures on views. Store built view results:
  ```swift
  // Anti-pattern
  struct CardView<Content: View>: View {
      let content: () -> Content
      var body: some View { VStack { content() }.padding() }
  }
  // Preferred
  struct CardView<Content: View>: View {
      @ViewBuilder let content: Content
      var body: some View { VStack { content }.padding() }
  }
  ```

---

## Hygiene

- API keys / secrets: never in repository.
- Comments where logic isn't self-evident.
- Unit tests for core logic. UI tests where unit tests not possible.
- `@AppStorage` never for usernames, passwords, sensitive data. Use Keychain.
- SwiftLint configured → zero warnings/errors.
- Localizable.xcstrings: symbol keys (e.g. "helloWorld") with `extractionState: "manual"` → access via `Text(.helloWorld)`. Offer translation into all supported languages.
- Xcode MCP configured → prefer its tools (`RenderPreview` for SwiftUI preview captures, `DocumentationSearch` for Apple docs).
