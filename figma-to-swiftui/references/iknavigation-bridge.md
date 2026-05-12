# IKNavigation Bridge

**Canonical source: [`ikame-ios-coding/references/iknavigation.md`](../../ikame-ios-coding/references/iknavigation.md)** — base ViewModel + View wiring (`enum Route` + `@Published var route: Route?` + `.navigationDestination(item:)`). This file holds only the figma-specific delta.

Applies only when `c1-conventions.json.usesIKNavigation == true`.

## §1. Detection (C1 audit)

`usesIKNavigation = true` when any signal: `import IKNavigation` in any `.swift`; `IKNavigation.makeView(router:` in app entry; `IKRouter` conformance; `@Environment(\.ikNavigationable)` access; `IKNavigation` in `Package.swift`/`*.xcodeproj`.

C1 captures `routers[]` (per-feature router list) by reading every `IKRouter` impl, plus `routerLayout`: `"per-feature"` canonical or `"single"` (brownfield — older projects like authenv2 keep all routes in one `MainRouter`/`AppRouter`).

If absent → use vanilla `NavigationStack`. **Do NOT add IKNavigation to a project that doesn't have it.**

## §2. Adding routes to existing feature router

The skill MUST extend the matching `<Feature>Route` enum + `<Feature>Router.makeView(from:)` switch — never invent a parallel router.

1. Read `c1-conventions.json.routers[]`
2. Identify feature from Figma frame name + folder context
3. Add case to `Core/Router/<Feature>/<Feature>Route.swift`
4. Add matching case to `Core/Router/<Feature>/<Feature>Router.swift` `makeView(from:)`

```swift
// OnboardingRoute.swift
enum OnboardingRoute: Hashable {
    case welcome
    case stepList
+   case stepDetail(id: StepID)       // ← skill adds

}

// OnboardingRouter.swift
struct OnboardingRouter: IKRouter {
    @ViewBuilder
    func makeView(from route: IKRouteID) -> some View {
        if let r = route.route(as: OnboardingRoute.self) {
            switch r {
            case .welcome:                WelcomeScreen()
            case .stepList:               OnboardingStepListScreen()
+           case .stepDetail(let id):     OnboardingStepDetailScreen(stepId: id)   // ← skill adds
            }
        } else {
            EmptyView()      // required for router composition
        }
    }
}
```

**New feature with no existing router** → create per-feature folder `Core/Router/<NewFeature>/` with both files; compose at app start with `+`. Always include `else { EmptyView() }`.

## §3. Sheet with internal navigation (`IKNavigationIdentifier`)

For sheets that need internal push/pop (auth flow, onboarding wizard) where the same stack is presented from multiple places:

```swift
// Define identifier (once per project)
extension IKNavigationIdentifier {
    static let authFlow = IKNavigationIdentifier()
}

// Implement on the relevant router
struct MainRouter: IKRouter {
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
Button("Sign in") { navigation.sheet(navigation: .authFlow) }
```

Simpler one-off form (no identifier needed):
```swift
navigation.sheet(navigation: IKNavigation.makeView(
    router: AuthRouter(),
    root: .authRoute(.login)
))
```

## §4. Push + sheet on same screen

Split into separate `@Published` properties — one route enum cannot represent both:

```swift
@Published var route: HomeViewModel.Route?           // push destinations
@Published var sheetRoute: HomeViewModel.SheetRoute?  // sheet destinations
```

View binds each:
```swift
.navigationDestination(item: $viewModel.route)  { route in destinationView(for: route) }
.sheet(item: $viewModel.sheetRoute) { sheet in sheetView(for: sheet) }
.fullScreenCover(item: $viewModel.modalRoute) { modal in modalView(for: modal) }
```

## §5. App entry point

The skill **does not** modify `AppDelegate` / `SceneDelegate` when IKNavigation is already wired. Existing `IKNavigation.makeView(router: AppRouter(), root: ...)` stays as-is. Only add new cases inside existing routers.

## §6. Banned in IKNavigation projects

| Pattern | Why |
|---|---|
| `NavigationStack(path:)` at screen root | App-level `IKNavigationView` owns the stack |
| `NavigationLink(destination:)` | Bypasses IKNavigation router |
| `.navigationDestination(for: <Type>.self)` | Type-keyed bypasses route identity; use `.navigationDestination(item:)` instead |
| `@State path = NavigationPath()` | Path is owned by IKNavigationView |
| `navigation.push(...)` inside ViewModel | VM has no `navigation` reference — set `route` on state instead |

**Note:** `.navigationDestination(item: $viewModel.route)` is the **canonical Style A binding and NOT banned**.

## §7. C8-iknavigation enforcement

For figma-to-swiftui, the banned-pattern hook catches root-level `NavigationStack(path:)`, `NavigationLink(destination:)`, and `.navigationDestination(for: <Type>.self)` at write-time. Stop-gate verifies ViewModel purity (no `navigation.push(...)` in `*ViewModel.swift`).

For deeper conventions check, see `ikame-ios-coding`.
