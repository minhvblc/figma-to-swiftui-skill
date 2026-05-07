# Swift Style — formatting, golden path, size limits, memory

Style rules the skill applies to every generated Swift file. Hard rules — enforced by `scripts/c8-func-length.sh`, `scripts/c8-weak-self.sh`, and inline grep gates in C3.

---

## §1. Formatting

| Rule | Value | Hard? |
|---|---|---|
| Indentation | 4 spaces (no tabs) | hard |
| Line length | 120 chars | warn at 120 |
| Trailing whitespace | none | hard |
| Final newline | exactly one | hard |
| Opening brace | same line as declaration | hard |
| Import order | alphabetical | hard |

```swift
// ✓
if user.isLoggedIn {
    showMainInterface()
} else {
    showLoginScreen()
}

import Combine
import Foundation
import SwiftUI

// ✗
if user.isLoggedIn
{
    showMainInterface()
}
```

---

## §2. Function size — HARD limit at 50 lines

| Range | Status | Action |
|---|---|---|
| ≤ 20 lines | ideal | keep |
| 21–30 lines | acceptable | consider extracting |
| 31–50 lines | warn | C3 emits a warning row |
| **51+ lines** | **HARD FAIL** | gate stops the run |

Counted: from opening `{` to closing `}` of the function body, blank lines and comments included. `var body: some View` is exempt from the limit (SwiftUI requires it can be long), but its **children** must obey size limits — see §3.

`scripts/c8-func-length.sh` runs at end of C3. Failure prints which file/function exceeded.

---

## §3. View size — HARD limit at 50 lines per subview

A SwiftUI `View` struct's body — when it represents a subview (in `Subviews/`) — must be ≤ 50 lines. The Screen's body is exempt because it composes header/content/footer (each of which is ≤ 50).

```swift
// ✓ Subview ≤ 50 lines
struct OnboardingProgressView: View {
    let progress: Double
    var body: some View {
        ZStack {
            background
            indicator
        }
        .frame(height: 64)
    }
    private var background: some View { ... }
    private var indicator: some View { ... }
}

// ✗ Subview that grew past 50 lines — must split
struct OnboardingHeaderView: View {
    var body: some View {
        VStack {
            // 80 lines of content
        }
    }
}
```

When a subview grows past 50 lines, extract a child subview — typically named `<Parent>Detail<Role>View` or `<Parent><Role>SectionView`. See `references/project-structure.md` §2.

A computed property returning `some View` (e.g. `private var headerSection: some View`) counts toward the **parent's** body length only when inlined; if the parent has > 5 such computed properties OR the parent body exceeds 50 lines (excluding child computed properties), extract them into separate `View` structs in `Subviews/`.

---

## §4. Golden path — guard early, happy path on the left margin

Pull error / pre-condition handling out via `guard` so the happy path is never indented past one level. This is the single most important readability rule.

```swift
// ✓ Golden path — main logic at left margin
func processData(_ data: Data?) throws -> Result {
    guard let data = data else { throw Error.invalidInput }
    guard data.isValid else { throw Error.invalidData }
    guard data.hasPermission else { throw Error.noPermission }

    let processed = transform(data)
    return processed
}

// ✗ Pyramid of doom — main logic buried
func processData(_ data: Data?) throws -> Result {
    if let data = data {
        if data.isValid {
            if data.hasPermission {
                let processed = transform(data)
                return processed
            } else { throw Error.noPermission }
        } else { throw Error.invalidData }
    } else { throw Error.invalidInput }
}
```

**Rule of thumb:** a function body should rarely contain `if-else` deeper than 1 level of nesting. Nested `if-else` of depth ≥ 3 fails the gate; depth 2 emits a warning.

---

## §5. Optional handling

```swift
// ✓ guard for early return
guard let user = currentUser else { return }

// ✓ if let for short-lived optional
if let email = user.email {
    sendEmail(to: email)
}

// ✗ Force unwrap — banned except in clear invariants
let email = user.email!

// ✓ Force unwrap explained — only when 100% guaranteed by surrounding code
// safe: regex literal — pattern is a compile-time constant
let regex = try! Regex("^[a-z]+$")
```

Force unwrap (`!`) without an explanatory comment fails C3's banned-pattern grep. The exceptions are: `try!` on compile-time constants, and force-unwrap immediately after `guard` proved non-nil within ≤ 5 lines.

---

## §6. Memory — `[weak self]` in escaping closures

Every escaping closure that captures `self` must use `[weak self]`. Failure to do so leaks the ViewModel until the closure releases.

```swift
// ✓
viewModel.onDataUpdated = { [weak self] in
    self?.updateUI()
}

Task { [weak self] in
    guard let self else { return }
    await self.load()
}

// ✗ Retain cycle
viewModel.onDataUpdated = {
    self.updateUI()
}
```

**Exceptions** (no `[weak self]` required):
- `Task { ... }` launched from inside a `@MainActor` ViewModel reducer — the ViewModel owns the task; when VM dies, task is implicitly cancelled. Capture is fine.
- `withAnimation { ... }` — synchronous, returns before closure can outlive `self`.
- `body: some View` lazy evaluations — same.
- `.onAppear { ... }` and other one-shot UIKit-style hooks — captured during view lifetime only.

`scripts/c8-weak-self.sh` checks closures passed to `assign(to:on:)`, `.sink`, `Combine` operators, `URLSession`, custom callback APIs (any closure stored as a property). It does NOT flag the exception list above.

The gate is **soft (warn)** because false positives are common — but every warning must be acknowledged by the agent in the verification summary, not silently ignored.

---

## §7. `lazy` for expensive setup

Use `lazy var` for one-time-computed properties that aren't always needed:

```swift
// ✓
lazy var dateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    return formatter
}()
```

Don't `lazy var` cheap things — it adds overhead without benefit.

---

## §8. MARK comments

Every file uses `// MARK: - <Section>` to organize sections in this order (when present):

```swift
// MARK: - Route
// MARK: - Action
// MARK: - State / Properties
// MARK: - Dependencies
// MARK: - Lifecycle / Init
// MARK: - Reducer            (ViewModel)
// MARK: - Subviews            (View — when extracted as @ViewBuilder)
// MARK: - Private Methods
// MARK: - Actions             (deprecated for ViewModels — replaced by Action enum + reducer)
```

The skill emits MARK comments by default. Don't over-section: if a file has 1 method, it doesn't need MARK headers.

---

## §9. Error handling — domain-specific enums

```swift
enum NetworkError: Error {
    case noInternetConnection
    case serverError(statusCode: Int)
    case invalidResponse
    case timeout
}

enum ValidationError: Error {
    case emptyEmail
    case invalidEmailFormat
    case passwordTooShort
}
```

**Catch by case**, never a single generic `catch` that maps any error to a user message:

```swift
// ✓
do {
    let user = try await fetchUserProfile(for: id)
    state.user = user
} catch NetworkError.noInternetConnection {
    state.errorMessage = "Không có kết nối mạng"
} catch NetworkError.serverError(let code) {
    state.errorMessage = "Lỗi server (\(code))"
} catch {
    state.errorMessage = "Lỗi không xác định"
}

// ✗
do {
    let user = try await fetchUserProfile(for: id)
} catch {
    state.errorMessage = error.localizedDescription   // ← unlocalized system text leaks to user
}
```

The skill generates a per-domain error enum when an async path returns >1 error class. For a single-error path, generic `catch` + a specific message is acceptable.

---

## §10. Documentation

- Public APIs (anything outside the screen folder, marked `public`) get `///` doc comments.
- Internal logic gets a comment **only when the WHY is non-obvious** — a hidden constraint, an invariant, a workaround for a specific bug. Never explain WHAT (well-named identifiers do that).

```swift
// ✓ — explains a non-obvious invariant
// `route = nil` first so the `.navigationDestination` binding releases the previous
// destination's view before we present the next one — prevents a state-bleed bug
// where the new screen briefly inherits the old screen's @StateObject.
route = nil
route = .next

// ✗ — explains WHAT
// Set the route to detail
route = .detail(id)
```

---

## §11. Modifier order

Modifiers on a SwiftUI view follow this order (top to bottom):

```
1. Text / Typography      .font, .lineLimit, .multilineTextAlignment, .truncationMode, .foregroundStyle
2. Layout / Sizing        .padding, .frame, .fixedSize, .layoutPriority
3. Decoration             .background, .overlay, .border, .clipShape, .mask, .shadow
4. Effect                 .opacity, .blur, .saturation, .animation
5. Interaction            .onTapGesture, .gesture, .contextMenu, .swipeActions
6. State / Lifecycle      .onChange, .onReceive, .onAppear, .task
7. Presentation           .sheet, .fullScreenCover, .alert, .confirmationDialog, .navigationDestination
8. Environment            .environmentObject, .environment, .preferredColorScheme
```

Within each group, smaller-scope modifiers come first.

```swift
// ✓
Text("Hello")
    .font(IKFont.bodyMedium16)
    .foregroundStyle(Color.primaryText)
    .padding(.horizontal, Spacing.l16)
    .frame(maxWidth: .infinity)
    .background(Color.surfaceCard)
    .clipShape(RoundedRectangle(cornerRadius: 12))
    .onTapGesture { viewModel.send(.tapped) }
```

**Why the order matters.** SwiftUI applies modifiers in declaration order. `.padding().background()` ≠ `.background().padding()` — first creates padding with the background filling it, second draws background flush to the view with padding outside. A consistent order makes review tractable.

---

## §12. Banned constructs

Already enforced elsewhere; listed here for reference:

| Pattern | Why banned | Gate |
|---|---|---|
| `Image(systemName: ...)` for non-allow-listed icons | Figma is the source of truth | C6 |
| `cornerRadius()` (deprecated) | Use `RoundedRectangle(...)` or `.clipShape(.rect(cornerRadius:))` (iOS 17+) | C3 Pass 1 |
| `NavigationView` (deprecated) | Use `NavigationStack` (or `IKNavigation` if project uses it) | C3 swiftui-pro |
| Inline hex `Color(red: 0.2, green: 0.5, ...)` when `_shared/tokens.json` has the token | tokens.json is the source | C3 Pass 1 |
| Inline string literals in `Text("...")` when localization is set up | xcstrings symbol API | C3 Pass 1 |
| `.font(.system(size: N))` without `@ScaledMetric` AND when `IKFont` enum exists | Dynamic Type + project tokens | C3 swiftui-pro |
| `onTapGesture` on a tappable area that should be a `Button` | a11y / interaction semantics | C3 Pass 1 |
| Force unwrap (`!`) without explanatory comment | safety | C3 |
| Generic `catch { errorMessage = error.localizedDescription }` | leaks system text | C3 |
| `@MainActor` on individual methods (not the class) | partial isolation footgun | C8-vm-pattern |
| `func send` accessor not on a ViewModel — i.e. ViewModel without an Action enum | architecture | C8-vm-pattern |
