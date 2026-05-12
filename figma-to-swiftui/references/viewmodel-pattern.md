# ViewModel Pattern — State + Action + `send(_:)`

The **only** ViewModel shape this skill emits.

**Canonical for Ikame projects: [`ikame-ios-coding/references/viewmodel.md`](../../ikame-ios-coding/references/viewmodel.md)** — full pattern (iOS 16+ `ObservableObject` form). This file holds:
- Non-Ikame iOS 17+ `@Observable` variant
- Brownfield `routePublisher` form
- Banned patterns
- Gate enforcement

## §1. Canonical shape (iOS 16+ `ObservableObject`)

See canonical source. Summary:

```swift
@MainActor
final class HomeViewModel: ObservableObject {
    enum Route: Equatable, Hashable {
        case detail(Article)
    }
    enum Action {
        case viewDidLoad
        case didTapArticle(Article)
        case dismissRoute
    }

    @Published var articles: [Article] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var route: Route?

    private let articleRepository: any ArticleRepository

    init(articleRepository: any ArticleRepository = API.articleRepository) {
        self.articleRepository = articleRepository
    }

    func send(_ action: Action) {
        switch action {
        case .viewDidLoad:           Task { await loadArticles() }
        case .didTapArticle(let a):  route = .detail(a)
        case .dismissRoute:          route = nil
        }
    }

    private func loadArticles() async {
        isLoading = true
        defer { isLoading = false }
        do {
            articles = try await articleRepository.getArticles(page: 1)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
```

**Rules:**
- Flat `@Published`, never nested in a `State` struct (whole-view invalidation otherwise)
- `@MainActor` on the class
- `send(_:)` is the ONLY entry point from View
- `enum Route` + `@Published var route: Route?` when the screen navigates
- Default init params for testability (`= API.<repo>`)
- Importing UIKit/SwiftUI is allowed when pragmatic

## §2. iOS 17+ `@Observable` variant (non-Ikame only)

For non-Ikame with `iOS 17+` deployment target AND `c1-conventions.json.observationFlavor == "observable"`:

```swift
import Observation

@MainActor
@Observable
final class HomeViewModel {
    enum Route: Equatable, Hashable { case detail(Article) }
    enum Action { case viewDidLoad, didTapArticle(Article), dismissRoute }

    var articles: [Article] = []
    var isLoading: Bool = false
    var errorMessage: String?
    var route: Route?

    private let articleRepository: any ArticleRepository
    init(articleRepository: any ArticleRepository) { self.articleRepository = articleRepository }

    func send(_ action: Action) {
        switch action {
        case .viewDidLoad:          Task { await loadArticles() }
        case .didTapArticle(let a): route = .detail(a)
        case .dismissRoute:         route = nil
        }
    }
}
```

View uses `@State private var viewModel = HomeViewModel(...)` + `@Bindable var viewModel` in child views needing two-way binding. No `@Published`; properties are bare `var`.

**Ikame projects are LOCKED to `ObservableObject`** regardless of deployment target — IKCoreApp's environment values + IKNavigation expect the protocol form.

## §3. Brownfield `routePublisher` variant

Some legacy Ikame projects use a Combine `PassthroughSubject<Route, Never>` instead of `@Published var route: Route?`. C1 captures this as `viewToRouteWiring: "routePublisher"`:

```swift
@MainActor
final class LegacyViewModel: ObservableObject {
    enum Route: Equatable, Hashable { case detail(Article) }
    enum Action { case didTapArticle(Article) }

    @Published var articles: [Article] = []
    let routePublisher = PassthroughSubject<Route, Never>()

    func send(_ action: Action) {
        switch action {
        case .didTapArticle(let a): routePublisher.send(.detail(a))
        }
    }
}
```

View subscribes:
```swift
.onReceive(viewModel.routePublisher) { route in
    // handle push or sheet
}
```

When C1 reports `viewToRouteWiring == "routePublisher"`, match the legacy form. **Do NOT mix the two in one project.**

## §4. Banned patterns

- View directly mutating `viewModel.articles = …` (use `send(.action)`)
- `State` struct with all fields, bound to a single `@Published` (whole-view re-render)
- Calling navigator/router from ViewModel (set `route` state instead — view dispatches)
- Instantiating `XxxRepositoryImpl(...)` outside `enum API`
- `try!` / force unwrap on outside-the-file values (network responses, JSON, user input)
- Function body > 50 lines (hard cap)

## §5. Gate enforcement

Stop-gate hook + `c1-probe.sh` verify:
- `@MainActor` on the class
- `enum Action` present (or `routePublisher` for brownfield)
- `func send(_ action: Action)` reducer present
- `enum Route` present if `route = .x` referenced
- Function bodies ≤ 50 lines
