# ViewModel Pattern — State + Action + `send(_:)`

The **only** ViewModel shape this skill emits. Hard rule — enforced by `scripts/c8-vm-pattern.sh`.

**For Ikame projects (`usesIKCoreApp == true`), the canonical source for this pattern is `ikame-ios-coding/references/viewmodel.md`.** This file mirrors the same shape (§1) for vanilla iOS 16+ projects, adds the iOS 17+ `@Observable` form for non-Ikame projects on a newer deployment target (§2), and documents the gate enforcement (§7). If anything here conflicts with `ikame-ios-coding`, the Ikame skill wins for Ikame projects.

This pattern applies regardless of whether the project uses `ObservableObject` (iOS 16) or `@Observable` (iOS 17+). The shape is the same; the storage differs. (Ikame projects are locked to `ObservableObject` per `ikame-decision-table.md` D-301; the `@Observable` variant below is for non-Ikame projects only.)

---

## §1. The shape (canonical iOS 16+ form)

```swift
import Foundation

@MainActor
final class OnboardingViewModel: ObservableObject {

    // MARK: - Route — every navigation target reachable from this screen
    enum Route: Equatable, Hashable {
        case detail(StepID)
        case finish
    }

    // MARK: - Action — every event the View can dispatch
    enum Action {
        case viewDidLoad
        case stepTapped(StepID)
        case primaryButtonTapped
        case dismissRoute
    }

    // MARK: - State (flat — one @Published per cell)
    @Published var steps: [Step] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var route: Route?

    // MARK: - Dependencies
    private let onboardingService: OnboardingServiceProtocol

    init(service: OnboardingServiceProtocol = OnboardingService()) {
        self.onboardingService = service
    }

    // MARK: - Reducer — the ONLY entry point from View
    func send(_ action: Action) {
        switch action {
        case .viewDidLoad:
            Task { await loadSteps() }

        case .stepTapped(let id):
            route = .detail(id)

        case .primaryButtonTapped:
            route = .finish

        case .dismissRoute:
            route = nil
        }
    }

    // MARK: - Private logic
    private func loadSteps() async {
        isLoading = true
        errorMessage = nil
        do {
            steps = try await onboardingService.fetchSteps()
        } catch OnboardingError.network {
            errorMessage = "Đã xảy ra lỗi mạng!"
        } catch {
            errorMessage = "Lỗi không xác định"
        }
        isLoading = false
    }
}
```

The View only ever calls `viewModel.send(.something)`. Never `viewModel.fetchSteps()`, never `viewModel.steps = ...` directly.

---

## §1b. Brownfield exception — legacy `routePublisher`

Some older Ikame projects (notably authenv2) deliver routes through a Combine `PassthroughSubject<Route, Never>` named `routePublisher` instead of `@Published var route: Route?`, with the View consuming via `.onReceive(viewModel.routePublisher) { route in onNavigation(to: route) }`. C1 captures this as `viewToRouteWiring: "routePublisher"`.

**This form is brownfield-only.** When detected in an existing project, match the legacy form in additions to that project. **Do NOT introduce `routePublisher` into a project that doesn't already have it.** Canonical Ikame code (per `ikame-ios-coding/references/viewmodel.md` and `references/ikame-decision-table.md` D-404, D-1206) uses the state-driven `@Published var route: Route?` form from §1 above — same as non-Ikame projects.

Shape of the legacy form (for reference when editing a brownfield project):

```swift
@MainActor
final class CodesHomeViewModel: ObservableObject {
    enum Route { case scanQRCode, editOTP(GROTPModel) /* ... */ }
    enum Action { case changeHeaderState, addFolder /* ... */ }

    @Published var codesHomeState: CodesHomeState = .normal
    let routePublisher = PassthroughSubject<Route, Never>()      // ← Combine subject, not @Published

    func send(_ action: Action) {
        switch action {
        case .addFolder:
            routePublisher.send(.addFolder(...))                  // ← send through subject
        // ...
        }
    }
}

// View
.onReceive(codesHomeViewModel.routePublisher) { route in
    onNavigation(to: route)                                       // ← extension func, not navigationDestination
}
```

Notable differences from §1: `let routePublisher = PassthroughSubject<Route, Never>()` (let, not @Published), no `case dismissRoute` (PassthroughSubject doesn't retain), View `.onReceive(...)` not `.navigationDestination(item:)`, requires `import Combine`.

---

## §2. iOS 17+ variant (non-Ikame projects only)

When `c1-conventions.json.minDeploymentTarget >= 17` AND project uses `@Observable`. **Banned for Ikame projects** (`usesIKCoreApp == true` is locked to `ObservableObject` per `ikame-decision-table.md` D-301 for cross-project consistency, regardless of `minDeploymentTarget`).

```swift
import Observation

@Observable @MainActor
final class OnboardingViewModel {

    enum Route: Equatable, Hashable { /* ... */ }
    enum Action { /* ... */ }

    // Plain stored vars — @Observable handles the publishing
    var steps: [Step] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var route: Route?

    @ObservationIgnored private let onboardingService: OnboardingServiceProtocol

    init(service: OnboardingServiceProtocol = OnboardingService()) {
        self.onboardingService = service
    }

    func send(_ action: Action) { /* same as §1 */ }

    private func loadSteps() async { /* same as §1 */ }
}
```

**Differences from iOS 16+ form:**
- `@Observable` macro instead of `ObservableObject`
- Plain `var` instead of `@Published var`
- `@ObservationIgnored` on dependencies (so they don't trigger view updates)
- View uses `@State` + `@Bindable` instead of `@StateObject`

The reducer shape is **identical**. C8-vm-pattern.sh accepts both.

---

## §3. Hard rules

### 3a. Flat state (one `@Published` per cell)

```swift
// ✓ Each cell publishes independently — only the consuming subview re-renders
@Published var articles: [Article] = []
@Published var isLoading: Bool = false
@Published var errorMessage: String?

// ✗ Banned default — any cell change re-renders every observer
@Published var state = ViewState()
struct ViewState {
    var articles: [Article] = []
    var isLoading: Bool = false
    var errorMessage: String?
}
```

**Only exception**: a struct of fields that always change together AND are observed by a single subview. Form input is the canonical case:

```swift
// ✓ Allowed — form fields change together, one subview owns them
@Published var formInput = FormInput()
struct FormInput {
    var email: String = ""
    var password: String = ""
    var confirmPassword: String = ""
}
// Other VM state stays flat
@Published var isSubmitting: Bool = false
@Published var errorMessage: String?
```

The skill defaults to flat. It only emits a struct when the input from C1 / Figma indicates "this is a form" or the user explicitly asks.

### 3b. `enum Action` is mandatory

Every ViewModel that exists has `enum Action` and `func send(_ action: Action)`. The grep gate fails the run if either is missing.

If a ViewModel has truly no actions (rare — usually a passive read-only model), declare:

```swift
enum Action { /* none */ }
func send(_ action: Action) { }
```

…and add a comment why. The gate accepts an empty enum with explicit empty `send`.

### 3c. `enum Route` is mandatory **only if the screen navigates anywhere**

If the screen pushes / sheets / dismisses to anything, declare `enum Route` nested + `@Published var route: Route?` + a `case dismissRoute` action. View binds `$viewModel.route`:

```swift
.navigationDestination(item: $viewModel.route) { route in
    switch route {
    case .detail(let id): DetailScreen(id: id)
    case .finish: EmptyView()
    }
}
```

If the screen has zero outgoing navigation, omit `Route` entirely. The gate does not require it.

**`navigation` flavor (IKNavigation projects)** — when `c1-conventions.json.usesIKNavigation == true`, the canonical state-driven form from §1 still applies; the View just binds `.navigationDestination(item: $viewModel.route)` (or `.sheet(item:)` / `.fullScreenCover(item:)`) per route. Purely-UI navigation (static buttons, app-level pop-to-root) may use imperative `navigation.push(to: .<feature>Route(...))` directly from the View — see `references/iknavigation-bridge.md` §3 and `ikame-ios-coding/references/iknavigation.md`. **Do NOT call `navigation.push` from inside a ViewModel.**

**Brownfield `routePublisher` (legacy Ikame only)** — when C1 captures `viewToRouteWiring: "routePublisher"`, route is delivered via `let routePublisher = PassthroughSubject<Route, Never>()` instead of `@Published var route: Route?`. **`case dismissRoute` is omitted** because `PassthroughSubject` does not retain — re-tapping re-publishes naturally. See §1b above and `references/ikame-decision-table.md` D-404 brownfield note.

### 3d. `@MainActor` at the class level

Every ViewModel class is `@MainActor`. Per-method `@MainActor` is banned (defeats the purpose). The reducer can launch detached `Task { ... }` for background work; the result is awaited and assigned on the main actor automatically.

```swift
// ✓
@MainActor
final class OnboardingViewModel: ObservableObject {
    func send(_ action: Action) {
        case .viewDidLoad:
            Task { await loadSteps() }   // hops back to main on assignment
    }
}

// ✗ Banned — partial isolation is a footgun
final class OnboardingViewModel: ObservableObject {
    @MainActor func loadSteps() async { ... }
}
```

### 3e. `final` is recommended

ViewModels are leaf types — never subclass them. `final` lets the compiler devirtualize. Not strictly enforced (warning only), but emitted by the skill by default.

### 3f. Dependencies via init

ViewModels accept their dependencies via `init` with default values that production code can use directly:

```swift
init(service: OnboardingServiceProtocol = OnboardingService()) {
    self.onboardingService = service
}
```

Why: tests inject a mock; production callers don't have to pass anything. Default-value pattern is preferred over `@Injected` property wrappers because it makes the dependency surface visible at the call site.

---

## §4. View ↔ ViewModel ownership

### iOS 16+ (ObservableObject)

```swift
struct OnboardingScreen: View {
    @StateObject private var viewModel = OnboardingViewModel()

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            contentSection
        }
        .onAppear { viewModel.send(.viewDidLoad) }
        .navigationDestination(item: $viewModel.route) { route in
            switch route {
            case .detail(let id): DetailScreen(id: id)
            case .finish: EmptyView()
            }
        }
    }
}
```

### iOS 17+ (@Observable)

```swift
struct OnboardingScreen: View {
    @State private var viewModel = OnboardingViewModel()

    var body: some View {
        @Bindable var vm = viewModel
        VStack(spacing: 0) {
            headerSection
            contentSection
        }
        .onAppear { viewModel.send(.viewDidLoad) }
        .navigationDestination(item: $vm.route) { route in
            switch route {
            case .detail(let id): DetailScreen(id: id)
            case .finish: EmptyView()
            }
        }
    }
}
```

The reducer-call sites (`viewModel.send(.viewDidLoad)`) are identical between the two forms.

---

## §5. What goes in View vs ViewModel

| Concern | View | ViewModel |
|---|---|---|
| Loading spinner display | ✓ binds `viewModel.isLoading` | sets `isLoading` |
| Toast message display | ✓ binds `viewModel.toastMessage` | sets `toastMessage` |
| Popup / alert (pure show) | ✓ entirely in View | nothing |
| Popup with await (e.g. confirmation) | shows the popup | `await` happens here, sets state |
| Navigation execution (push / sheet) | ✓ binds `$viewModel.route` (or calls `navigation.push(to:)` for IKNavigation) | sets `route` |
| Animation timing | ✓ `withAnimation` block in View | nothing |
| Async data fetch | nothing | ✓ `Task { await fetch() }` |
| Validation rules | nothing | ✓ pure functions, called from reducer |
| Form binding | binds `$viewModel.formInput.email` etc. | declares `@Published var formInput` |

If a behavior is only "show this view with this data" → View. If it has an `await` or a side effect → ViewModel.

---

## §6. Error handling inside the reducer

Per-domain `Error` enum, caught case-by-case. Generic `catch` only as a fallback that maps to a generic message:

```swift
enum OnboardingError: Error {
    case network
    case invalidStep(StepID)
    case quotaExceeded
}

private func loadSteps() async {
    isLoading = true
    errorMessage = nil
    do {
        steps = try await onboardingService.fetchSteps()
    } catch OnboardingError.network {
        errorMessage = "Đã xảy ra lỗi mạng!"
    } catch OnboardingError.quotaExceeded {
        errorMessage = "Bạn đã hết lượt thử."
    } catch {
        errorMessage = "Lỗi không xác định"
    }
    isLoading = false
}
```

Banned: a single `catch { errorMessage = error.localizedDescription }` that surfaces system messages to the user. They are unlocalized and frequently meaningless ("The operation couldn't be completed.").

---

## §7. C8-vm-pattern.sh enforcement

The gate runs at end of Step C3 and inspects every `*ViewModel.swift` generated by this run:

1. **Class header.** Class is `final` (warn if missing) AND has `@MainActor` annotation (hard).
2. **`enum Action`.** Top-level nested `enum Action { ... }` exists.
3. **`func send(_ action: Action)`.** Method exists with that exact signature, with a single `switch action` body.
4. **`enum Route`.** If the file references `route` (any `var route` / `case route` / `dismissRoute` / `routePublisher`), `enum Route` exists. Canonical form: `@Published var route: Route?` (§1) requires `enum Route: Equatable, Hashable` so `.navigationDestination(item: $route)` binding works. Brownfield form: `let routePublisher = PassthroughSubject<Route, Never>()` (§1b) — only accepted when C1 captures `viewToRouteWiring: "routePublisher"`; `Route` only needs the cases the View pattern-matches in that case.
5. **Flat state heuristic.** If the file has ≥ 2 `@Published` declarations AND a top-level `struct ViewState` (or similar) wrapping all of them, fail. The single-struct exception (form input + flat state coexisting) is OK because flat state still exists.
6. **No direct mutation from View.** Greps for `viewModel.<property>=` outside `viewModel.send(...)` and outside `$viewModel.` (binding) — fails when found in the corresponding `*Screen.swift` / `*View.swift`.

Output: `GATE: PASS` or `GATE: FAIL: <reason>` — exit code matches.
