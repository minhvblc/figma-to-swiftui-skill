# IKNavigation Bridge

How `figma-to-swiftui` adapts navigation output when the target project uses **IKNavigation** instead of vanilla `NavigationStack`. Conditional — applies only when `c1-conventions.json.usesIKNavigation == true`.

**Canonical source: `ikame-ios-coding/references/iknavigation.md` and `references/ikame-decision-table.md` §5.** This file holds only the figma-specific delta (router extension on adding new routes, sheet-with-internal-nav-stack via `IKNavigationIdentifier`, banned-patterns gate). For the base ViewModel + View wiring (`enum Route` + `@Published var route: Route?` + `.navigationDestination(item:)`), follow the canonical source.

---

## §1. Detection (C1 audit)

C1 sets `usesIKNavigation = true` when ANY of these signals are present:

| Signal | Where to look |
|---|---|
| `import IKNavigation` in any existing Swift file | `find . -name '*.swift' -exec grep -l 'import IKNavigation' {} \;` |
| `IKNavigation.makeView(router:` call in App entry / SceneDelegate | `App/*.swift` |
| `IKRouter` protocol conformance in any file | `grep -r ': IKRouter\b'` |
| `@Environment(\.ikNavigationable)` access | `grep -r 'ikNavigationable'` |
| `Package.swift` / `*.xcodeproj` references `ikmacros` or `IKNavigation` package | manually inspected |

If any signal is present → `usesIKNavigation = true`. Skill emits IKNavigation-flavored code.

If absent → the skill uses vanilla `NavigationStack` per `references/swiftui-pro/navigation.md`. **Do not import IKNavigation into a project that doesn't already have it** — that's pulling in a dependency the user didn't request.

C1 also captures `routers[]` (a list of `{ name, featureSubfolder, routeEnumName }` triples — e.g. `{ name: "MainRouter", featureSubfolder: "Main", routeEnumName: "MainRoute" }`, plus one entry per `Core/Router/<Feature>/`) by reading every `IKRouter` impl, so the skill knows which existing feature router to extend instead of inventing a parallel one.

**Brownfield single-router exception.** Some older Ikame projects (notably authenv2) keep all routes in a single `MainRouter` / `AppRouter` with a flat `NavigationItem` enum, instead of per-feature routers. C1 captures this as `routerLayout: "single"` (vs canonical `"per-feature"`). When detected, extend the single existing router; do NOT split it into per-feature routers in the same PR.

---

## §2. ViewModel Route shape

Canonical Ikame VM-driven route follows `ikame-ios-coding/references/viewmodel.md` and `references/ikame-decision-table.md` D-404, D-1206 — `enum Route: Equatable, Hashable` nested + `@Published var route: Route?` + `case dismissRoute`.

```swift
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Route: Equatable, Hashable {
        case stepDetail(StepID)
        case finish
    }
    enum Action {
        case viewDidLoad
        case stepTapped(StepID)
        case primaryButtonTapped
        case dismissRoute
    }

    @Published var route: Route?

    func send(_ action: Action) {
        switch action {
        case .viewDidLoad:           Task { await loadSteps() }
        case .stepTapped(let id):    route = .stepDetail(id)
        case .primaryButtonTapped:   route = .finish
        case .dismissRoute:          route = nil
        }
    }
}
```

ViewModel does **not** import IKNavigation. ViewModel does **not** call `navigation.push(to:)`. Routes are pure state.

**Brownfield `routePublisher`.** When C1 captures `viewToRouteWiring: "routePublisher"` (legacy form, see `references/viewmodel-pattern.md` §1b), match the legacy form — do NOT mix the two in one project.

---

## §3. View — IKNavigation flavor

Per `ikame-ios-coding/references/iknavigation.md`, there are two valid styles depending on whether the navigation has business meaning:

### Style A (canonical for VM-driven flows) — `.navigationDestination(item:)`

When the route was set by the ViewModel after some business logic (login result, list item tap, etc.), the View binds `$viewModel.route` to `.navigationDestination(item:)` and renders the destination directly:

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
            destinationView(for: route)
        }
    }
}

private extension OnboardingScreen {
    @ViewBuilder
    func destinationView(for route: OnboardingViewModel.Route) -> some View {
        switch route {
        case .stepDetail(let id): OnboardingStepDetailScreen(stepId: id)
        case .finish:             EmptyView()      // VM dismisses via `case .finish` → router pop / parent reaction
        }
    }
}
```

This is what `ikame-ios-coding` shows as canonical. **No `onChange` + `navigation.push` dance is needed.** When the route is set, SwiftUI navigates; when the user pops, SwiftUI clears the binding and you can observe in `.onChange(of: viewModel.route)` if you need to fire a follow-up action — but most flows don't.

### Style B (canonical for purely-UI navigation) — imperative `navigation.push`

When the navigation is a static menu button or app-level action that the VM does NOT need to know about, dispatch directly from the View:

```swift
struct SettingsScreen: View {
    @Environment(\.ikNavigationable) private var navigation

    var body: some View {
        VStack {
            Button("Profile") {
                navigation.push(to: .mainRoute(.profile))
            }
            Button("About") {
                navigation.push(to: .mainRoute(.about))
            }
            Button("Log out") {
                Task { @MainActor in
                    await AuthService.shared.logout()
                    navigation.popToRoot()
                }
            }
        }
    }
}
```

This goes through the IKNavigation router (i.e. `MainRouter.makeView(from:)` resolves `.mainRoute(.profile)` → `ProfileScreen()`), unlike Style A which renders the destination inline. Both are valid; pick based on whether the VM cares about the navigation.

**Never call `navigation.push(...)` from inside a ViewModel.** That's a hard rule (`scripts/c8-iknavigation.sh` flags it).

---

## §4. Sheet / fullScreenCover

### Single-route sheet (Style A — VM-driven, separate `@Published` for sheet)

When a screen needs both push AND sheet destinations, split into separate `@Published` properties — one `route` enum cannot represent both presentation modes simultaneously:

```swift
@Published var route: HomeViewModel.Route?           // push destinations
@Published var sheetRoute: HomeViewModel.SheetRoute?  // sheet destinations
```

View binds each:

```swift
.navigationDestination(item: $viewModel.route)  { route in destinationView(for: route) }
.sheet(item: $viewModel.sheetRoute, onDismiss: { viewModel.send(.dismissSheet) }) { sheet in
    sheetView(for: sheet)
}
.fullScreenCover(item: $viewModel.modalRoute) { modal in modalView(for: modal) }
```

### Sheet with its own navigation stack (`IKNavigationIdentifier`)

Used when the sheet needs internal push/pop (auth flow, onboarding wizard). Two ways:

**Inline form** (one-off use):
```swift
navigation.sheet(navigation: IKNavigation.makeView(
    router: AuthRouter(),
    root: .authRoute(.login)
))
```

**Indirection via `IKNavigationIdentifier`** (when the same stack is presented from multiple places):
```swift
// Define identifier (once per project, in a routes file)
extension IKNavigationIdentifier {
    static let authFlow = IKNavigationIdentifier()
}

// Implement makeNavigationView on the relevant router
struct MainRouter: IKRouter {
    @ViewBuilder
    func makeView(from route: IKRouteID) -> some View { /* ... */ }

    @ViewBuilder
    func makeNavigationView(navigationIdentifier: IKNavigationIdentifier) -> some View {
        switch navigationIdentifier {
        case .authFlow:
            IKNavigation.makeView(router: AuthRouter(), root: .authRoute(.login))
        default:
            EmptyView()
        }
    }
}

// View triggers
Button("Sign in") {
    navigation.sheet(navigation: .authFlow)
}
```

---

## §5. Adding routes to an existing feature router

When the skill generates a new screen that navigates to a new destination within the same feature, it MUST extend the matching `<Feature>Route` enum and `<Feature>Router.makeView(from:)` switch — never create a parallel router unless the user explicitly authorizes a new module.

Skill action:

1. Read `c1-conventions.json.routers[]` — the list of feature routers detected in `Core/Router/<Feature>/`.
2. Identify which feature the new screen belongs to (from Figma frame name + folder context).
3. Open the matching `Core/Router/<Feature>/<Feature>Route.swift` and add the case.
4. Open the matching `Core/Router/<Feature>/<Feature>Router.swift` and add the matching case in `makeView(from:)`.

```swift
// Core/Router/Onboarding/OnboardingRoute.swift
extension IKRouteID {
    static func onboardingRoute(_ route: OnboardingRoute) -> Self { .init(route) }
}
enum OnboardingRoute: Hashable {
    case welcome
    case stepList
+   case stepDetail(id: StepID)        // ← skill adds this
}

// Core/Router/Onboarding/OnboardingRouter.swift
struct OnboardingRouter: IKRouter {
    @ViewBuilder
    func makeView(from route: IKRouteID) -> some View {
        if let r = route.route(as: OnboardingRoute.self) {
            switch r {
            case .welcome:                WelcomeScreen()
            case .stepList:               OnboardingStepListScreen()
+           case .stepDetail(let id):     OnboardingStepDetailScreen(stepId: id)   // ← skill adds this
            }
        } else {
            EmptyView()        // required for router composition
        }
    }
}
```

**New feature with no existing router** → create the per-feature folder `Core/Router/<NewFeature>/` with both files (`<NewFeature>Route.swift` + `<NewFeature>Router.swift`). Compose at app start with `+`: `IKNavigation.makeView(router: MainRouter() + AuthRouter() + OnboardingRouter(), root: .mainRoute(.main))`. Always include `else { EmptyView() }` in `makeView(from:)` — otherwise router composition silently breaks for routes from other features.

---

## §6. App entry point

The skill **does not** modify the App entry point or SceneDelegate when IKNavigation is already wired. The existing `IKNavigation.makeView(router: AppRouter(), root: AppRoute.home)` stays as-is. The skill only adds new cases inside the existing router, plus the new screen files.

Modifying the entry point is reserved for two cases:
- The user explicitly says "add this as a new tab" or "make this the new launch screen".
- The skill is generating a new feature flow (`figma-flow-to-swiftui-feature`) that introduces a new auth-flow style sheet — then the skill extends `IKNavigationIdentifier` and adds a `makeNavigationView` case, but still does NOT touch the App entry.

---

## §7. Banned in IKNavigation projects

| Pattern | Why banned |
|---|---|
| `NavigationStack(path: $path)` at screen root | The project's `IKNavigationView` (created via `IKNavigation.makeView(...)` at app start) already owns the stack; introducing a screen-level `NavigationStack` creates a parallel system. |
| `NavigationLink(destination: ...)` | Use state-driven `.navigationDestination(item:)` binding (Style A) or imperative `navigation.push(to:)` (Style B). `NavigationLink` doesn't go through IKNavigation's router. |
| `.navigationDestination(for: <Type>.self)` | Type-keyed destinations bypass IKNavigation's route identity. Use `.navigationDestination(item: $viewModel.route)` (item-keyed) instead — that IS the canonical Style A binding. |
| `@State private var path = NavigationPath()` | Path is owned by `IKNavigationView`; views read `route` from ViewModel and dispatch to `$viewModel.route` (Style A) or `@Environment(\.ikNavigationable)` (Style B). |
| `viewModel.someMethod()` directly calling `navigation.push(...)` inside a ViewModel | ViewModel has no `navigation` reference. Routes are pure state; pushing happens in the View. |

**Note**: `.navigationDestination(item: $viewModel.route)` is the canonical Style A binding **and not banned**. It works inside `IKNavigationView` because IKNavigation wraps a `NavigationStack` internally — SwiftUI's `.navigationDestination(item:)` modifier composes with it correctly.

`scripts/c8-iknavigation.sh` runs at end of C3 only when `usesIKNavigation == true` and fails the run on any of the above except `.navigationDestination(item:)`.

---

## §8. C8-iknavigation.sh enforcement

When `c1-conventions.json.usesIKNavigation == true`:

1. **Imports.** Every `*Screen.swift` and `*View.swift` that invokes navigation imports `IKCoreApp` (the umbrella re-exports IKNavigation; do not import `IKNavigation` as a separate statement).
2. **Banned root-level APIs.** No screen-level `NavigationStack(path:)`, no `NavigationLink(destination:)`, no `.navigationDestination(for: <Type>.self)`, no `@State path = NavigationPath()` in generated files. Note: `.navigationDestination(item: $viewModel.route)` is NOT banned — it is the canonical Style A binding.
3. **Environment access.** Files that dispatch imperative navigation (Style B) declare `@Environment(\.ikNavigationable) private var navigation`.
4. **VM purity.** No `import IKNavigation` (or `import IKCoreApp` solely for `IKNavigationable`) and no `navigation.push(...)` call inside any `*ViewModel.swift`. ViewModels mutate `route` state; Views dispatch.
5. **Router extension.** If the run added a new route case to an existing feature, the matching `Core/Router/<Feature>/<Feature>Route.swift` gained the case AND the matching `Core/Router/<Feature>/<Feature>Router.swift` `makeView(from:)` gained the new switch case. Else branch `EmptyView()` is preserved.
6. **No parallel router invention.** No new file matching `Core/Router/<NewFeature>/<NewFeature>Router.swift` was created unless the user explicitly authorized a new feature module.

When `usesIKNavigation == false`, the gate prints `GATE: SKIP (project uses NavigationStack)` and exits 0.
