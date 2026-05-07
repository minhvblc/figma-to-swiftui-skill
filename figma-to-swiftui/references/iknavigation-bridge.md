# IKNavigation Bridge

How `figma-to-swiftui` adapts navigation output when the target project uses **IKNavigation** instead of vanilla `NavigationStack`. Conditional — applies only when `c1-conventions.json.usesIKNavigation == true`.

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

C1 also captures `routerName` (e.g. `AppRouter`, `OnboardingRouter`) by reading the most recent `IKRouter` impl, so the skill knows what to extend instead of inventing a new router.

---

## §2. ViewModel Route stays the same

The ViewModel pattern from `references/viewmodel-pattern.md` is unchanged — `enum Route` nested + `@Published var route: Route?` + `case dismissRoute`. The difference is **how the View executes** the navigation.

```swift
@MainActor
final class OnboardingViewModel: ObservableObject {
    enum Route: Hashable {
        case detail(StepID)
        case finish
    }
    enum Action {
        case stepTapped(StepID)
        case primaryButtonTapped
        case dismissRoute
    }

    @Published var route: Route?

    func send(_ action: Action) {
        switch action {
        case .stepTapped(let id): route = .detail(id)
        case .primaryButtonTapped: route = .finish
        case .dismissRoute: route = nil
        }
    }
}
```

ViewModel does not import IKNavigation. ViewModel does not call `navigation.push(to:)`. The View is the only layer that talks to IKNavigation.

---

## §3. View — IKNavigation flavor

Two equivalent shapes. The skill picks (A) when the project's existing screens use it, (B) when they use the second form. C1 records `viewToRouteWiring` as `"onChange"` or `"environmentRouter"` so the skill stays consistent.

### Shape A — `onChange(of: viewModel.route)` to dispatch

```swift
struct OnboardingScreen: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @Environment(\.ikNavigationable) private var navigation

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            contentSection
        }
        .onAppear { viewModel.send(.viewDidLoad) }
        .onChange(of: viewModel.route) { _, newRoute in
            guard let newRoute else { return }
            switch newRoute {
            case .detail(let id):
                navigation.push(to: AppRoute.stepDetail(id: id))
            case .finish:
                navigation.finish()
            }
            viewModel.send(.dismissRoute)
        }
    }
}
```

The `viewModel.send(.dismissRoute)` after dispatch resets the route so a re-tap re-publishes the same value (otherwise `onChange` doesn't refire on a re-set to `.detail(sameId)`).

### Shape B — direct call from action handler

```swift
struct OnboardingScreen: View {
    @StateObject private var viewModel = OnboardingViewModel()
    @Environment(\.ikNavigationable) private var navigation

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            contentSection
        }
        .onAppear { viewModel.send(.viewDidLoad) }
    }

    private var contentSection: some View {
        ForEach(viewModel.steps) { step in
            OnboardingStepRow(step: step)
                .onTapGesture {
                    // Direct dispatch — view bypasses the route state for navigation
                    navigation.push(to: AppRoute.stepDetail(id: step.id))
                }
        }
    }
}
```

In Shape B, ViewModel still has `enum Route` for testability (you can assert `vm.route == .detail(id)` in a unit test), but production code dispatches directly. Choose this shape only when the project consistently uses it; otherwise default to Shape A.

---

## §4. Sheet / fullScreenCover

### Single-route sheet

```swift
// In ViewModel
enum Route: Hashable {
    case settingsSheet
    case productDetailFullscreen(id: String)
}

// In View — Shape A
.onChange(of: viewModel.route) { _, route in
    guard let route else { return }
    switch route {
    case .settingsSheet:
        navigation.sheet(route: AppRoute.settings)
    case .productDetailFullscreen(let id):
        navigation.fullScreenCover(route: ProductRoute.detail(id: id))
    }
    viewModel.send(.dismissRoute)
}
```

### Sheet with its own navigation stack (`IKNavigationIdentifier`)

Used when the sheet needs internal push/pop (auth flow, onboarding wizard). The skill detects this pattern via Figma — if the screen graph branches into a multi-screen flow that's modally presented, mark the sheet as needing its own stack.

```swift
// Define identifier (once per project, in routes file)
extension IKNavigationIdentifier {
    static let authFlow = IKNavigationIdentifier()
}

// Router implements makeNavigationView for that identifier
struct AppRouter: IKRouter {
    @ViewBuilder
    func makeNavigationView(navigationIdentifier: IKNavigationIdentifier) -> some View {
        switch navigationIdentifier {
        case .authFlow:
            IKNavigation.makeView(router: AuthRouter(), root: AuthRoute.login)
        default:
            EmptyView()
        }
    }
}

// View dispatches
.onChange(of: viewModel.route) { _, route in
    guard route == .openAuthFlow else { return }
    navigation.sheet(navigation: .authFlow)
    viewModel.send(.dismissRoute)
}
```

---

## §5. Adding routes to an existing router

When the skill generates a new screen that navigates to a new destination, it MUST extend the existing router rather than create a parallel one. Skill action:

1. Read `c1-conventions.json.routerName` (e.g. `AppRouter`).
2. Read the existing router file, locate the `makeView(from:)` switch.
3. Add the new case for the new route:

```swift
// Existing AppRouter.makeView(from:)
@ViewBuilder
func makeView(from route: IKRouteID) -> some View {
    if let r = route.route(as: AppRoute.self) {
        switch r {
        case .home:    HomeScreen()
        case .cart:    CartScreen()
        case .account: AccountScreen()
+       case .stepDetail(let id): OnboardingStepDetailScreen(stepId: id)   // ← skill adds this
        }
    }
}
```

…and add the corresponding case to `enum AppRoute`:

```swift
enum AppRoute: Hashable {
    case home
    case cart
    case account
+   case stepDetail(id: StepID)   // ← skill adds this
}
```

Never invent a new `enum NewFeatureRoute` and a new `NewFeatureRouter` unless the user explicitly asks for a separate module router. Default: extend.

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
| `NavigationStack(path: $path)` | The project uses IKNavigation; introducing a vanilla NavigationStack creates a parallel system. |
| `NavigationLink(destination: ...)` | Same reason. |
| `.navigationDestination(for:)` / `.navigationDestination(item:)` | Same reason — IKNavigation handles destination resolution via `Router.makeView(from:)`. |
| `@State private var path = NavigationPath()` | Path is owned by `IKNavigationView`; views read `route` from ViewModel and dispatch to `@Environment(\.ikNavigationable)`. |
| Importing `SwiftUI`'s navigation APIs without IKNavigation imports when other screens use IKNavigation | Mixed navigation systems. |

`scripts/c8-iknavigation.sh` runs at end of C3 only when `usesIKNavigation == true` and fails the run on any of the above.

---

## §8. C8-iknavigation.sh enforcement

When `c1-conventions.json.usesIKNavigation == true`:

1. **Imports.** Every `*Screen.swift` and `*View.swift` that invokes navigation imports IKNavigation (or has a parent that does).
2. **Banned APIs.** No `NavigationStack`, `NavigationLink`, `.navigationDestination`, `NavigationPath` in generated files. (Ones in legacy code — unchanged — are out of scope for this gate.)
3. **Environment access.** Files that dispatch navigation declare `@Environment(\.ikNavigationable) private var navigation`.
4. **Router extension.** If the run added new routes, the corresponding `enum AppRoute` (or whichever route enum) gained the case AND the router's `makeView(from:)` gained the matching case.
5. **No router invention.** No new file matching `*Router.swift` was created unless the user explicitly authorized a new module.

When `usesIKNavigation == false`, the gate prints `GATE: SKIP (project uses NavigationStack)` and exits 0.
