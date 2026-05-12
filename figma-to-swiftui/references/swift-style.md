# Swift Style — formatting, golden path, size limits, memory

**For Ikame projects, also see:** [`ikame-ios-coding/references/swiftui-view.md`](../../ikame-ios-coding/references/swiftui-view.md) (modifier order, function size from canonical) — this file covers the figma-to-swiftui-specific rules + iOS general style.

## §1. Function & view body size

| Limit | Hard cap | Soft target |
|---|---|---|
| Function body | 50 lines | 30 lines |
| SwiftUI view `body` | 50 lines | 40 lines |
| Sub-section `@ViewBuilder` computed prop | banned — extract to separate `View` struct |
| Nested types in one file | 1 root type + nested types it owns; otherwise split |

Stop-gate enforces 50-line cap. Past 30, extract methods/subviews.

## §2. Golden path (guard + early return)

```swift
// ✓ Golden path — happy case at nesting depth 0
func fetchProfile() async {
    guard !userId.isEmpty else { return }
    guard isAuthenticated else { route = .login; return }

    do {
        profile = try await profileRepository.getProfile(id: userId)
    } catch {
        errorMessage = error.localizedDescription
    }
}

// ✗ Pyramid — happy case buried in nesting
func fetchProfile() async {
    if !userId.isEmpty {
        if isAuthenticated {
            do {
                profile = try await profileRepository.getProfile(id: userId)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            route = .login
        }
    }
}
```

Nesting depth ≤ 1 for happy-path body. Multiple `guard`s OK; multiple `if let`s nested is not.

## §3. Modifier order (SwiftUI)

Apply in this order on each view:

1. **Typography** — `.font()`, `.foregroundStyle()`, `.bold()`, `.italic()`, `.tracking()`, `.lineSpacing()`
2. **Layout** — `.frame()`, `.padding()`, `.fixedSize()`, alignment, `.layoutPriority()`
3. **Decoration** — `.background()`, `.foregroundStyle()` (for shapes), `.overlay()`, `.border()`, `.clipShape()`, `.cornerRadius()`
4. **Effect** — `.shadow()`, `.blur()`, `.opacity()`, `.rotationEffect()`, `.scaleEffect()`, `.mask()`, `.blendMode()`
5. **Interaction** — `.onTapGesture()`, `.gesture()`, `.contentShape()`, `.allowsHitTesting()`, `.disabled()`
6. **State/lifecycle** — `.onAppear()`, `.onDisappear()`, `.task()`, `.onChange()`, `.onReceive()`
7. **Presentation** — `.sheet()`, `.fullScreenCover()`, `.alert()`, `.navigationDestination()`, `.toolbar()`
8. **Environment** — `.environment()`, `.environmentObject()`, `.preferredColorScheme()`

**Why it matters:** `.padding` after `.background` changes hit-testing (padding extends outside the visible background, but tap area shrinks). `.frame` after `.background` clips the background. Order matters silently — wrong order = real bugs.

## §4. Memory — `[weak self]`

Use `[weak self]` in escaping closures that may outlive `self`:

```swift
// ✓ Combine sink
publisher
    .sink { [weak self] value in
        self?.handle(value)
    }
    .store(in: &cancellables)

// ✓ Custom callback API
networkClient.subscribe { [weak self] event in
    guard let self else { return }
    self.process(event)
}

// ✓ URLSession callback
URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
    self?.handle(data)
}.resume()
```

**Exempt:** `Task { ... }` inside a `@MainActor` reducer where self is owned by the View — Task captures self strongly only for the body's duration, and `@MainActor` keeps lifecycle predictable. Most ViewModel reducer Tasks are exempt.

**Banned:** strong-self capture in long-lived publishers (`@Published` chains, `NotificationCenter` observers).

## §5. Error handling

Per-domain `Error` enum, catch case-by-case when user-facing message differs:

```swift
enum ProfileError: Error {
    case notFound
    case forbidden
    case network(URLError)
}

func loadProfile() async {
    do {
        profile = try await profileRepository.getProfile(id: userId)
    } catch ProfileError.notFound {
        errorMessage = "Profile not found"
        route = .signup
    } catch ProfileError.forbidden {
        errorMessage = "Access denied"
    } catch let ProfileError.network(urlError) {
        errorMessage = urlError.localizedDescription
    } catch {
        errorMessage = "Unexpected error"
    }
}
```

**Banned:** `catch { errorMessage = error.localizedDescription }` as the only handler when the screen needs different responses (route on auth fail, retry on network fail, etc.). The catch-all is fine as a FALLBACK after specific cases.

## §6. Naming conventions (figma-specific)

| Kind | Pattern | Source |
|---|---|---|
| Action case | Verb-prefixed: `didTap…`, `didReceive…`, `willDismiss…` | Derive from Figma interactive node name: `Button "Continue"` → `case didTapContinue` |
| Route case | Noun (destination): `.detail(article)`, `.login`, `.finish` | Derive from Figma flow / doc step |
| State property | Noun: `articles`, `isLoading`, `errorMessage`, `route` | Domain term, plural for collections |

## §7. Concurrency

- `async/await` over completion handlers (always).
- `Task { ... }` inside `@MainActor` reducer for async work.
- `Task.detached` only when explicit — almost never in this skill.
- `await MainActor.run { ... }` only when entering main actor from outside; inside `@MainActor` class it's redundant.

## §8. Constants & magic numbers

- Layout values from Figma → token enum case OR `// Figma: <node-id>` justification (banned-pattern hook enforces).
- Repeated literals > 3× → extract to `private static let <name>: CGFloat = ...` at top of file.
- App-wide constants → `AppConstants.swift` enum, not scattered.

## §9. Imports

```swift
import Foundation     // first
import SwiftUI
import Combine        // if used
import IKCoreApp      // for Ikame projects
import iKameSDKCore   // when calling SDK directly (Ikame)
// project-specific imports last
```

Banned: importing `IKNavigation`/`IKFont`/`IKMacros`/`IKPopup` as **separate** statements — they're re-exported by `IKCoreApp`.

## §10. Comments

Default: write no comments. Only add when the WHY is non-obvious:
- A hidden constraint (e.g. `// API contract: id must be lowercase`)
- A workaround for a specific bug (e.g. `// SwiftUI 16.4 bug — .padding above .background reorders hit-testing`)
- A `// safe-area-adjusted: raw=..., inset=..., adjusted=...` justification for screen-root `.padding(.top, 44|47|...)` (banned-pattern gate requires)
- A `// Figma: <node-id>` comment for one-off literal not backed by a token

Banned:
- Restating what the code does (`// loop over articles`)
- Section banners (`// MARK: - Helpers` is fine; `// =================` is noise)
- Trailing-comment paragraphs explaining the obvious

## §11. Generics & types

- `any <Protocol>` for protocol-typed properties (`private let repository: any ArticleRepository`) — never `var repository: ArticleRepository` (existential is required by Swift 5.7+).
- `some View` for `body`; `some View` for `@ViewBuilder` returns; `AnyView` BANNED unless absolutely necessary (each `AnyView` erases type info and bloats diff updates).
- `Result<Success, Error>` for synchronous returns that may fail; `throws` for async.
