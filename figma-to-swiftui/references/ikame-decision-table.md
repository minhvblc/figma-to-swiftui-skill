# Ikame Decision Table — locked conventions for Ikame projects

The single source of truth for every code-shape decision the skill makes when emitting into an Ikame iOS project (detected via `usesIKCoreApp == true` in `c1-conventions.json`). Every row has an ID. Subagents and per-screen runs reference rows by ID; they **may not invent** alternatives.

This file locks **patterns**, not **values**. Values (specific colors, spacings, copy) always come from Figma per the *Figma là chân lý duy nhất* principle. Patterns (folder layout, ViewModel shape, navigation API, popup invocation) are locked here so 50 screens generated in parallel by 50 subagents emit the same shape.

**Source of truth.** The base Ikame conventions (folder layout, ViewModel shape, SwiftUI view shape, IKNavigation, @APIProtocol, IKPopup / IKToast / IKLoading, ikFont, Color(hex:)) live in the `ikame-ios-coding` skill (`ikame-ios-coding/references/<topic>.md`). This decision table **mirrors** those for code-generation use and adds the figma-specific delta plus the advanced features (IKTracking, IKLocalized, IKOnboardingFlow, IKHaptics, app-level popup config cases) that `ikame-ios-coding` does not cover. **If this table conflicts with `ikame-ios-coding`, follow `ikame-ios-coding` and treat this table row as out of date.**

When the skill is generating into a non-Ikame project (`usesIKCoreApp == false`), this file does not apply — fall back to `references/swiftui-pro-bridge.md` and `references/viewmodel-pattern.md` defaults.

---

## §0. How decisions are sourced

| Type | Source | Examples |
|---|---|---|
| **Pattern** | This file (locked) | `D-301` IKNavigation push pattern, `D-501` IKPopup invocation |
| **Value** | Figma (`get_design_context` + `figma_extract_tokens`) | exact color hex, spacing, font size, copy string |
| **Discovery** | C1 probe (`c1-conventions.json`) | `ikFontEnum` name, `routerName`, `xcstringsPath`, asset catalog path |

When a subagent hits ambiguity that is **not** covered by a row below → STOP and escalate to leader. **Do NOT invent a 4th source.**

---

## §1. Detection — when this table applies

C1 probe sets `usesIKCoreApp` based on **EITHER** signal:

| Signal | Where |
|---|---|
| `pod 'IKCoreApp'` in `Podfile` | `grep -E "^\\s*pod\\s+'IKCoreApp'" Podfile` |
| `import IKCoreApp` in any `.swift` file under target | `grep -r "import IKCoreApp" --include='*.swift'` |

If either present → `usesIKCoreApp = true` and skill auto-enables every dependent flag below (the Ikame umbrella pod re-exports IKNavigation, IKFont, IKMacros, IKPopup, IKFeedback, IKTracking, IKLocalized — they do **not** appear as separate `pod` lines).

When `usesIKCoreApp == true`, C1 ALSO sets:

```json
{
  "usesIKCoreApp": true,
  "usesIKNavigation": true,
  "usesIKMacros": true,
  "usesIKFont": true,
  "usesIKPopup": true,
  "usesIKFeedback": true,
  "usesIKTracking": true,
  "usesIKLocalized": true,
  "usesIKAssetSymbol": true
}
```

Each individual flag still has its own per-bridge detection rule in case a non-Ikame project has only some of them. But the umbrella sets all when present.

---

## §2. Imports and file header

| ID | Decision | Locked value |
|---|---|---|
| **D-101** | Required imports for any Screen file | `import Foundation`, `import SwiftUI`, `import IKCoreApp` (always); `import iKameSDKCore` (when calling SDK directly); other stdlib imports as needed |
| **D-102** | Internal-import for third-party libs | `internal import Then` form (Swift 6) — when project already uses it; do NOT add new `internal import` for libs not already in project |
| **D-103** | File header comment | Block comment: file name / project name / `Created by iKame on <date>` — Xcode's auto-generated form. Do not strip on edit. |
| **D-104** | Section markers | `// MARK: - <Section>` mandatory; `// MARK: - Body View`, `// MARK: - Section Header View`, `// MARK: - Action`, `// MARK: - Navigation`, etc. |

```swift
// ✓ Canonical opening (matches authenv2/Authenticator/Screens/Codes/CodesHomeScreen.swift)
//
//  CodesHomeScreen.swift
//  Authenticator
//
//  Created by iKame on 11/5/25.
//

import Foundation
import SwiftUI
import IKCoreApp
import Combine
import iKameSDKCore
```

Banned: `import IKNavigation`, `import IKFont`, `import IKMacros`, `import IKPopup`, etc. as **separate** statements. They are already exported by `IKCoreApp`.

---

## §3. Path and file naming

**Canonical source: `ikame-ios-coding/references/project-structure.md`.** This section mirrors the locked values for code-generation use; if it conflicts with the source, follow the source.

| ID | Decision | Locked value |
|---|---|---|
| **D-201** | Screen folder | `Screens/<ScreenName>/` — **one folder per screen.** Screen file + its ViewModel + screen-only types live inside. |
| **D-202** | Screen file | `Screens/<ScreenName>/<ScreenName>Screen.swift` (type name: `<ScreenName>Screen`) |
| **D-203** | Screen extensions when file > ~250 lines | `Screens/<ScreenName>/<ScreenName>Screen+<Topic>.swift` (e.g. `+Subviews`, `+Action`, `+Navigation`). Prefer extracting SubViews into separate files under `Subviews/` first; only split the Screen file when subview extraction is exhausted. |
| **D-204** | Per-screen subview folder | `Screens/<ScreenName>/Subviews/` — present only when the screen has ≥1 extracted SubView with state |
| **D-205** | Per-screen subview file naming | `Screens/<ScreenName>/Subviews/<ScreenName><Role>View.swift` (prefix = screen name; suffix `View` always). Example: `HomeArticleRowView` under `Screens/Home/Subviews/`. |
| **D-206** | Per-screen subview as folder (multi-file) | `Screens/<ScreenName>/Subviews/<ScreenName><Role>View/` (sub-folder when the subview itself splits across multiple files) |
| **D-207** | Per-screen ViewModel | Co-located with the Screen — `Screens/<ScreenName>/<ScreenName>ViewModel.swift`. **Do not** create a `ViewModel/` subfolder. |
| **D-208** | Sub-ViewModel for a stateful SubView | `Screens/<ScreenName>/SubViewModels/<ScreenName><Role>ViewModel.swift` — present only when a SubView truly has its own VM (rare; prefer parent's `@Published` first) |
| **D-209** | Per-screen flow-only model | `Screens/<ScreenName>/Models/<ScreenName><Name>.swift` — only when used in 1 screen; promote to `Entities/` when shared |
| **D-210** | Per-screen enum | `Screens/<ScreenName>/Enums/<ScreenName><Name>.swift` — only when used in 1 screen |
| **D-211** | Reusable component (≥2 screens) | `Components/<Name>View.swift` — **prefix DROPPED on promotion** (`HomeArticleRowView` → `ArticleRowView`). The `App` prefix is reserved for project-wide infrastructural components (e.g. `AppPopupView`, `AppToastCenterView`); plain promoted components use a generic name. |
| **D-212** | Reusable component as folder | `Components/<Name>View/` (multi-file like `MenuPopupView/`, `OTPRow/`) |
| **D-213** | App-wide model | `Entities/<Prefix><Domain>Model.swift` (or `Entities/<Source>/<Prefix><Domain>Model.swift` if the project groups by data source). Prefix is **project-specific**, detected by C1 as `entitiesPrefix` and **may be empty**. Skill emits matching prefix for new entities. Examples: authenv2 uses `G` for GRDB models (`GROTPModel`, `GFolderModel`); a fresh ikxcodegen scaffold has no prefix. **Never default to `G`** — that is authenv2-specific, not Ikame-standard. When `entitiesPrefix == ""`, emit unprefixed (`OTPModel`). |
| **D-214** | API repository protocol | `Core/Network/Repositories/<Domain>Repository.swift` — `@APIProtocol`-annotated; macro generates `<Domain>RepositoryImpl`. Created on first repository. |
| **D-215** | API registry | `Core/Network/API.swift` — `enum API` exposing every repository as a static accessor. **All call sites use `API.<name>` and never instantiate `<Domain>RepositoryImpl` directly.** Created on first repository. |
| **D-216** | Database service / DB setup | `Core/Database/<Name>.swift` (created on first DB use) |
| **D-217** | Sync logic | `Core/Sync/<Name>.swift` (created on first sync feature) |
| **D-218** | Router definition | `Core/Router/<Feature>/<Feature>Route.swift` (enum + `IKRouteID` extension) + `Core/Router/<Feature>/<Feature>Router.swift` (`IKRouter` impl) — **one subfolder per feature router, not a flat `Core/Router/`**. Compose multiple feature routers with `+`. Extend the matching feature's `Route` enum + `Router.makeView(from:)` switch when adding new routes; never create a parallel feature router unless the user explicitly authorizes a new module. |
| **D-219** | Utilities | `Utilities/Constants.swift`, `Utilities/Extensions/<Type>+Ext.swift`, `Utilities/Helpers/<Name>.swift` — present in scaffold; skill appends to existing files |

**Notably absent from the initial ikxcodegen scaffold:** `Components/` and `Entities/`. Don't create them preemptively — they appear only when there's an actual shared component or domain model. New screens go straight under `Screens/<Name>/` with screen-prefixed children.

**Promotion rule:** when a screen-prefixed file becomes used by ≥2 screens → MOVE from `Screens/<X>/...` to `Components/` (UI) or `Entities/` (data) or `Utilities/` (helper), **drop the screen prefix**, update imports. Conversely, do not preemptively put things in `Components/`/`Entities/` "in case they get reused" — start screen-prefixed and promote when reuse actually happens.

**Brownfield exception — feature-flat layout.** Older Ikame projects (notably authenv2) ship with a legacy feature-flat layout (`Screens/<Feature>/<Feature>HomeScreen.swift` + `Screens/<Feature>/ViewModel/<Feature>HomeViewModel.swift`). C1 captures this as `screenFolderConvention: "ikame-feature-flat"`. When detected:
- For new screens added to an existing feature flow → match the existing flat layout (don't mix conventions in one project).
- For new isolated screens (not part of an existing feature flow) → emit the canonical one-folder-per-screen layout above.
- When in doubt → ask the user before scaffolding the folder.

---

## §4. State management

| ID | Decision | Locked value |
|---|---|---|
| **D-301** | ViewModel storage | `@StateObject var <name>ViewModel: <Name>ViewModel = .init()` — `ObservableObject` form. **Locked because all Ikame apps support iOS 16** (deployment target `'16.0'` set in ikxcodegen Podfile). `@Observable` is iOS 17+ and is **BANNED** for Ikame projects regardless of `minDeploymentTarget`. Do not migrate even when an individual project bumps deployment target — Ikame standardizes on ObservableObject for cross-project consistency. |
| **D-302** | View-local UI state | `@State` (photo picker bool, sheet bool, current selection rect, etc.) — short-lived, owned by view |
| **D-303** | Persistent flag | `@AppStorage(<KeyConstant>) var <name>: <Type> = <default>` — key is a `static let` in `AppConstants` |
| **D-304** | Navigation injection | `@Environment(\.ikNavigationable) private var navigation` |
| **D-305** | Popup dismiss injection | `@Environment(\.ikPopupDismiss) private var dismiss` |
| **D-306** | Tab bar opacity | `@Environment(\.setTabbarOpacity) var setTabbarOpacity` |
| **D-307** | Size class | `@Environment(\.horizontalSizeClass) var horizontalSizeClass` |

ViewModel internals: see §13.

---

## §5. Navigation

**Canonical source: `ikame-ios-coding/references/iknavigation.md`.** This section mirrors the locked values; if it conflicts with the source, follow the source.

| ID | Decision | Locked value |
|---|---|---|
| **D-401** | Navigation API (imperative) | `navigation.push(to: .<feature>Route(.<case>))`, `navigation.pop()`, `navigation.popToRoot()`, `navigation.replace(to:)`, `navigation.sheet(route:)`, `navigation.fullScreenCover(route:)`, `navigation.sheet(navigation:)`, `navigation.fullScreenCover(navigation:)`, `navigation.finish()` |
| **D-402** | Route enum source | `Core/Router/<Feature>/<Feature>Route.swift` — one route enum per feature. Each file also declares the `IKRouteID` extension helper: `extension IKRouteID { static func <feature>Route(_ route: <Feature>Route) -> Self { .init(route) } }`. Compose multiple feature routers with `+` at app start. |
| **D-403** | Router source | `Core/Router/<Feature>/<Feature>Router.swift` — `IKRouter` impl with mandatory `else { EmptyView() }` branch. Extend the existing feature router's `makeView(from:)` switch when adding new routes to the same feature; create a new feature router only when the user explicitly authorizes a new module. |
| **D-404** | VM → View navigation wiring | **State-driven via `@Published var route: Route?`.** ViewModel declares `enum Route: Equatable, Hashable` nested + `@Published var route: Route?`; View binds `.navigationDestination(item: $viewModel.route) { route in … }` (or `.sheet(item:)` / `.fullScreenCover(item:)` for modal presentations). ViewModel mutates state via `route = .<case>` from inside `send(_:)`; dismissal goes through a `case dismissRoute` action that sets `route = nil`. |
| **D-405** | Imperative `navigation.push` vs state-driven | **State-driven (`@Published var route`)** when the navigation has business meaning the VM should know about (after successful login, on tap of a list item with logic). **Imperative (`navigation.push(to: .<feature>Route(...))` from View)** when the navigation is purely UI (`Button("Settings") { navigation.push(to: .mainRoute(.settings)) }` in a static menu) or app-level (`popToRoot` after logout from any deep screen). Both are valid — pick based on whether the VM cares. Do NOT call `navigation.push` from inside a ViewModel — that breaks testability and the state→view contract. |
| **D-406** | Banned navigation APIs | `NavigationStack` / `NavigationLink` / `.navigationDestination(for:)` / `NavigationPath` / `@State path = NavigationPath()` — bypasses IKNavigation. `.navigationDestination(item:)` IS the binding helper used WITH IKNavigation when state-driven (D-404) — not banned. |
| **D-407** | Sheet with internal nav stack | Compose another nav stack: `navigation.sheet(navigation: IKNavigation.makeView(router: <FeatureRouter>(), root: .<feature>Route(.<initialCase>)))`. Or use the `IKNavigationIdentifier` indirection when the same sheet stack is presented from multiple places: declare `extension IKNavigationIdentifier { static let <name> = IKNavigationIdentifier() }`, implement `makeNavigationView(navigationIdentifier:)` on the relevant router, then trigger via `navigation.sheet(navigation: .<name>)`. |

```swift
// ✓ Canonical — state-driven, per-feature route
@MainActor
final class HomeViewModel: ObservableObject {
    enum Route: Equatable, Hashable {
        case detail(Article)
        case settings
    }
    enum Action {
        case viewDidLoad
        case didTapArticle(Article)
        case didTapSettings
        case dismissRoute
    }

    @Published var articles: [Article] = []
    @Published var route: Route?

    func send(_ action: Action) {
        switch action {
        case .viewDidLoad:           Task { await loadArticles() }
        case .didTapArticle(let a):  route = .detail(a)
        case .didTapSettings:        route = .settings
        case .dismissRoute:          route = nil
        }
    }
}

struct HomeScreen: View {
    @StateObject private var viewModel = HomeViewModel()

    var body: some View {
        content
            .onAppear { viewModel.send(.viewDidLoad) }
            .navigationDestination(item: $viewModel.route) { route in
                destinationView(for: route)
            }
    }
}

private extension HomeScreen {
    @ViewBuilder
    func destinationView(for route: HomeViewModel.Route) -> some View {
        switch route {
        case .detail(let article): ArticleDetailScreen(article: article)
        case .settings:            SettingsScreen()
        }
    }
}

// Core/Router/Home/HomeRoute.swift
extension IKRouteID {
    static func homeRoute(_ route: HomeRoute) -> Self { .init(route) }
}
enum HomeRoute: Hashable { case home, articleDetail(Article), settings }

// Core/Router/Home/HomeRouter.swift
struct HomeRouter: IKRouter {
    @ViewBuilder
    func makeView(from route: IKRouteID) -> some View {
        if let r = route.route(as: HomeRoute.self) {
            switch r {
            case .home:                       HomeScreen()
            case .articleDetail(let article): ArticleDetailScreen(article: article)
            case .settings:                   SettingsScreen()
            }
        } else {
            EmptyView()    // required for router composition
        }
    }
}
```

**Imperative form for purely-UI navigation:**

```swift
// In a View — no VM involvement needed
Button("Settings") {
    navigation.push(to: .homeRoute(.settings))
}
```

**Dismissal:** after the View handles a route push, dispatch `viewModel.send(.dismissRoute)` so that re-tapping the same target re-publishes the route change (otherwise `navigationDestination(item:)` won't refire on a re-set to the same value).

**Brownfield (`routePublisher` legacy).** Some older Ikame projects (notably authenv2) deliver routes through a Combine `PassthroughSubject<Route, Never>` named `routePublisher` instead of `@Published var route: Route?`, with the View consuming via `.onReceive(viewModel.routePublisher) { route in onNavigation(to: route) }`. C1 captures this as `viewToRouteWiring: "routePublisher"`. When detected, match the legacy form in additions to that project; **do NOT introduce `routePublisher` into a project that does not already have it.** Canonical new code uses the state-driven form above.

---

## §6. Popup / Sheet / Alert

**Canonical source: `ikame-ios-coding/references/ui-popup-toast-loading.md`.** This section mirrors the locked values; if it conflicts with the source, follow the source.

IKPopup is the **strong default** for Ikame projects, not an absolute requirement. Vanilla SwiftUI native APIs (`.sheet`, `.alert`) remain acceptable in specific cases (D-507) but should be a deliberate, justified choice — not the default.

| ID | Decision | Locked value |
|---|---|---|
| **D-501** | Default popup invocation (preset variants) | `IKPopup.shared.popup { <View> }` (center), `IKPopup.shared.sheet { <View> }` (bottom sheet), `IKPopup.shared.fullScreen { <View> }` (full-screen modal), `IKPopup.shared.toast { <View> }` (top transient — prefer `IKToast.show(.<id>, message:)` for standard cases). Trailing-closure form, returns `any Sendable?` asynchronously. |
| **D-502** | Custom-configuration invocation | `IKPopup.shared.show(configuration: <IKPopupConfiguration>) { <View> }` — when the visual / dismissal / animation behavior needs to deviate from the presets. The `configuration:` parameter accepts a value from `IKPopupConfiguration` (defaults: `.defaultPopup`, `.defaultSheet`, `.defaultFullScreen`, `.defaultToast`, `.defaultLoading`) or a project-level extension case (D-503). |
| **D-503** | Project-level configuration cases | Per-project extensions on `IKPopupConfiguration` add cases like `.menuPopup(<anchorPoint>)`, `.passwordPopup`, `.authenUndoPopup`, `.defaultNavigationPresentFullScreen`, `.customAppSheetFixedHeight(height:)`, etc. C1 captures `popupConfigurations` from existing usages. **Pick from existing cases; never invent new ones — escalate via delta-request (§16 `popupConfig`).** |
| **D-504** | Invocation pattern | Async/await — the call is `await`able and returns `any Sendable?`. Cast as needed: `let result = await IKPopup.shared.popup { ConfirmDeleteView() } as? ConfirmDeleteView.ReturnAction`. `nil` = dismissed (tapped outside / `dismiss()` with no value); `.some(value)` = user chose (`dismiss(value)`). |
| **D-505** | Default-banned popup APIs | `.sheet(isPresented:)`, `.fullScreenCover(isPresented:)`, `.alert(isPresented:)` / `.alert(item:)`, `.confirmationDialog`, `UIAlertController` — should be replaced by IKPopup unless D-507 exception applies. Inline comment `// allow-vanilla-popup: <reason>` required to bypass the gate. |
| **D-506** | Body of popup view | A regular `struct <Name>View: View` placed in `Components/` (or screen-prefixed under `Screens/<X>/Subviews/` when used by only one screen). Declares its own `enum ReturnAction` for typed results, dismisses via `@Environment(\.ikPopupDismiss) private var dismiss` calling `dismiss(.someAction)` to return a value or `dismiss()` to return nil. |
| **D-507** | When vanilla SwiftUI popup is acceptable | (a) Figma explicitly mocks a system-style alert / share-sheet matching iOS native chrome; (b) user explicitly requests a non-IKPopup variant; (c) interop with UIKit-only SDKs (e.g. `UIActivityViewController` system share); (d) toolbar's native back-chevron handled by IKNavigation. When exception applies, add `// allow-vanilla-popup: <reason>` so the gate doesn't false-positive. |

Default: route through IKPopup. Deviations per D-507 must be justified inline; otherwise gate flags as drift.

```swift
// ✓ Canonical — preset variant, typed return
let result = await IKPopup.shared.popup {
    ConfirmDeleteView()
}
if let action = result as? ConfirmDeleteView.ReturnAction, action == .confirm {
    viewModel.send(.confirmedDelete)
}

// ✓ Custom configuration — uses .show(configuration:) form
let anchor = CGPoint(x: buttonRect.minX, y: buttonRect.maxY + 8)
let menuType = await IKPopup.shared.show(configuration: .menuPopup(anchor)) {
    MenuPopupView(items: [.selectMode, .createFolder])
} as? MenuPopupType
switch menuType {
case .selectMode:    viewModel.send(.changeHeaderState)
case .createFolder:  viewModel.send(.addFolder)
default:             break
}

// ✓ App-level wrapper (project-specific) — still routes to IKPopup under the hood
Task { @MainActor in
    let result = await AppUtils.shared.showAnyPopup(with: .deleteOTP(objectIds: objectIds))
    if let action = result as? AppPopupView.ReturnAction, action == .rightButtonAction {
        codesHomeViewModel.send(.confirmedDeleteOTP(objectIds: objectIds))
    }
}
```

**Brownfield (`IKPopup.shared.showPopup(swiftUIView:configuration:)` legacy).** Some older Ikame projects (notably authenv2) use the named-argument form `IKPopup.shared.showPopup(swiftUIView: view, configuration: cfg)` instead of the closure form. C1 captures the prevailing form as `popupInvocationStyle: "closure"` (default) or `"namedArgs"`. When `namedArgs` is detected, match the legacy form in additions to that project; **canonical new code uses the closure form above.**

---

## §7. Loading / Haptics / Toast

**Canonical source for IKLoading / IKToast: `ikame-ios-coding/references/ui-popup-toast-loading.md`.** Haptics + app-level toast wrappers (e.g. `AppUtils.shared.showAppBottomToast`) live only here — `ikame-ios-coding` does not yet cover them.

| ID | Decision | Locked value |
|---|---|---|
| **D-601** | Loading indicator (global) | `IKLoading.showLoading()` / `IKLoading.dismissLoading()` — paired with `defer { IKLoading.dismissLoading() }` immediately after `showLoading()` so early returns / throws still dismiss |
| **D-602** | Loading indicator (view-scoped) | Inline `ProgressView` is OK for small in-content spinners (button-while-saving, list-row loading). Use `IKLoading` for app-wide blocking loading. Don't roll a custom global overlay. |
| **D-603** | Toast (canonical) | `IKToast.show(.<identifier>, message: "<text>")` — built-in identifiers `.success`, `.error`, `.warning`, `.info`, `.network`. Variants: `IKToast.showExclusive(.<id>, message:)` (dismisses other toasts first), `IKToast.dismissAll()`, `IKToast.show(.<id>, message:, configuration:)` (custom config). Custom visual styles registered once at app start with `IKToast.register(for: .<customId>) { msg in MyToastView(msg: msg) }`. |
| **D-604** | Toast (app-level wrapper, project-specific) | When the project defines an app-wide toast wrapper (`AppUtils.shared.showAppBottomToast(for: .<ToastSceenType>)` in authenv2; varies per project), C1 captures `appToastWrapper: { typeName: "...", funcSig: "..." }`. The wrapper routes to `IKPopup.shared.toast` or `IKToast` internally — skill uses the wrapper at call sites when the project has one. Without a wrapper detected, emit `IKToast.show(.<id>, message:)` directly. |
| **D-605** | Haptic feedback | `IKHaptics.selectionChanged()` (selection toggle), `IKHaptics.impactOccurred(.light)` (minor feedback), `.impactOccurred(.medium)` (action confirmed), `.impactOccurred(.heavy)` (error / major event), `.impactOccurred(.rigid)` (tactile click), `.impactOccurred(.soft)` (gentle). One haptic per user-perceived event; trigger on the View side at the moment of user-visible state change. |
| **D-606** | Banned haptic APIs | `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator`, `UINotificationFeedbackGenerator`, iOS 17 `.sensoryFeedback(.success, trigger:)` — use `IKHaptics.*` for cross-project consistency |
| **D-607** | Banned toast / loading APIs | Custom `.overlay { ToastView }` for global toasts, third-party HUD libs (SVProgressHUD, MBProgressHUD, SwiftMessages, ToastSwiftUI), `@State var isLoading` + manual `ProgressView` overlay for global loading |

```swift
// ✓ Canonical — IKToast directly
Task {
    IKLoading.showLoading()
    defer { IKLoading.dismissLoading() }
    do {
        try await API.itemRepository.save(item)
        IKHaptics.impactOccurred(.medium)
        IKToast.show(.success, message: "Saved")
    } catch {
        IKHaptics.impactOccurred(.heavy)
        IKToast.show(.error, message: error.localizedDescription)
    }
}

// ✓ App-level wrapper — used when project ships one
Task {
    IKLoading.showLoading()
    defer { IKLoading.dismissLoading() }
    do {
        try await DatabaseManager.saveOtps(otps: codes)
        AppUtils.shared.showAppBottomToast(for: .copiedToast)
        IKHaptics.impactOccurred(.medium)
    } catch {
        AppUtils.shared.showAppBottomToast(for: .saveFailed)
    }
}
```

When the Figma design specifies a toast for an event that doesn't have an existing `ToastSceenType` case (in projects that use a wrapper enum) → STOP and emit a delta-request `{ "type": "toastType", "case": "...", "rationale": "..." }`. Do NOT add the case from a feature subagent.

---

## §8. Tracking

| ID | Decision | Locked value |
|---|---|---|
| **D-701** | Screen-active tracking | `.ikLogScreenActive(AppTracking.<screenName>)` modifier — applied at the **top-level View `body`**, exactly once per screen |
| **D-702** | Dialog-active tracking | `.ikDialogScreenActive(AppTracking.<dialogName>)` — applied to the popup body view inside `IKPopup.shared.showPopup(...)` |
| **D-703** | Programmatic tracking | `AppTrackingFeature.shared.addTrackingFeature(for: <feature>, params: [.<key>: <value>.rawValue, ...])` |
| **D-704** | Tracking enum source | `Utilities/Tracking/AppTracking.swift` — extend the existing enum cases when adding a new screen; do NOT create parallel tracking enums |
| **D-705** | Skill behavior on missing tracking enum case | STOP — emit a warning and ask the user whether to add the case. Do NOT invent a string literal |

```swift
// ✓ Canonical
struct CodesHomeScreen: View {
    var body: some View {
        VStack { /* ... */ }
            .ikLogScreenActive(AppTracking.codesHome)   // ← screen-active
    }
}

// In an action:
AppTrackingFeature.shared.addTrackingFeature(for: .ft_authenticator, params: [
    .action_type: AppTracking.action.rawValue,
    .action_name: AppTracking.copy_code.rawValue,
    .feature_target: AppTracking.yes.rawValue,
    .status: AppTracking.success.rawValue
])
```

---

## §9. Localization

Two paths — `Text` literals use SwiftUI's automatic `LocalizedStringKey`; everywhere else uses `.ikLocalized()` extension on `String`.

| ID | Decision | Locked value |
|---|---|---|
| **D-801** | String literal passed directly to `Text(_:)` | `Text("Authenticator")`, `Text("Selected: \(count)")` — SwiftUI infers `LocalizedStringKey` and auto-localizes via the project's Localizable.xcstrings catalog. **Do NOT add `.ikLocalized()`** here — it would coerce to `String`, which calls a different `Text` overload that does NOT auto-localize. |
| **D-802** | String stored as `String` (constants, computed values, passed to non-Text APIs) | `"<English source>".ikLocalized()` — extension method on `String`. The English source IS the key. |
| **D-803** | When to use a per-screen `Constants` struct | Static labels reused in multiple places within the same screen → declare in `struct <Name>ScreenConstants { static let title = "Title".ikLocalized() }` nested inside the View struct. The `.ikLocalized()` is required because `static let title: String` infers `String`, not `LocalizedStringKey`. |
| **D-804** | xcstrings file | Both paths share the project's existing `.xcstrings` (path captured by C1 as `xcstringsPath`). Skill appends new keys; never creates a parallel `.xcstrings`. SwiftUI's automatic LocalizedStringKey resolution AND `.ikLocalized()` use the same catalog. |
| **D-805** | Strings passed to popup / alert / format functions | `.ikLocalized()` — these APIs accept `String`, not `LocalizedStringKey`. Examples: popup title, alert message, share text, `String(format: "Selected: %d".ikLocalized(), count)`. |
| **D-806** | Banned localization patterns | `Text(NSLocalizedString(...))`, `NSLocalizedString(...)` direct, `String(localized:)`, `Text(.symbolKey)` symbol-key API (Ikame does not use it). Manual `LocalizedStringKey("...")` constructor is also banned — let SwiftUI infer from the literal. |

```swift
// ✓ Direct Text literal — SwiftUI infers LocalizedStringKey, auto-localized
Text("Authenticator")
Text("Selected: \(codesHomeViewModel.otpIdSelecteds.count)")

// ✓ String constants — .ikLocalized() because static let infers String, not LocalizedStringKey
struct CodesHomeScreenConstants {
    static let title: String = "Authenticator".ikLocalized()
    static let renameTitle: String = "Rename".ikLocalized()
    static let renameDescription: String = "Please enter the folder name below".ikLocalized()
}

// ✓ Text consuming a String constant — pass-through; constant is already localized
Text(CodesHomeScreenConstants.title)
    .appFontHeading3()

// ✓ Format string for non-Text API
let formatted = String(format: "Selected: %d".ikLocalized(), count)

// ✓ Popup / alert title (the API accepts String)
let result = await AppUtils.shared.showAlertPopup(
    title: "Delete Folder?".ikLocalized(),
    message: "Choose how you want to delete this folder.".ikLocalized(),
    alertButtonTitle: "Delete Everything".ikLocalized(),
    cancelButtonTitle: "Cancel".ikLocalized()
)

// ✗ WRONG — .ikLocalized() in Text overrides LocalizedStringKey path
Text("Authenticator".ikLocalized())   // calls Text(_: String) — NOT auto-localized

// ✗ WRONG — manual LocalizedStringKey
Text(LocalizedStringKey("Authenticator"))
```

---

## §10. Asset reference

| ID | Decision | Locked value |
|---|---|---|
| **D-901** | Image reference | `Image(.<assetName>)` — Swift 5.9+ generated symbol from `Assets.xcassets`. Project must have `GENERATE_ASSET_SYMBOLS = YES` (C1 verifies) |
| **D-902** | Banned image patterns | `Image("<assetName>")` (string literal), `Image(systemName:)` for designed icons, hand-drawn `Path` / `Shape` / `Rectangle()` / `Text("G")` as logo placeholder |
| **D-903** | Allowed `Image(systemName:)` exceptions | iOS chrome the user explicitly wants to keep system-default (back chevron in IKNavigation toolbar, share-sheet icon) — must have inline comment `// allow-systemName: <reason>` |
| **D-904** | Asset folder | `Resources/Assets.xcassets` (the catalog created by ikxcodegen). Skill appends to it; does not create a new catalog |
| **D-905** | Image rendering mode | Per `references/asset-handling.md` §4. Tagged-path assets decide at the call site: `.renderingMode(.template) + .foregroundStyle(...)` for tintable single-color icons. |

```swift
// ✓ Canonical
Image(.icCancel)                                  // generated symbol
Image(.icCloudUploadEnable)
Image(.icTrailingMenu)
    .background(.text50)
    .clipShape(Circle())

Image(.icAIClose)                                 // tagged-path
    .resizable()
    .renderingMode(.template)
    .frame(width: 24, height: 24)
    .foregroundStyle(Color(.text900))
```

---

## §11. Color reference

| ID | Decision | Locked value |
|---|---|---|
| **D-1001** | Color reference in code | `Color(.<name>)` — iOS 17+ auto-generated `ColorResource` symbol from xcassets colorset (e.g. `Color(.bg)`, `Color(.text900)`, `Color(.colorE6E6E6)`). The legacy `Color.<name>` static-var extension form is also accepted when the project already ships such an extension, but new code MUST emit `Color(.<name>)`. |
| **D-1002** | New color from Figma | Add a colorset to `Resources/Assets.xcassets/Colors/` named `color<HEX>` (e.g. Figma `#0F0F0F` → asset `color0F0F0F`). Reference as `Color(.color0F0F0F)`. |
| **D-1003** | Semantic color name (when Figma provides) | Allowed: `accentRed`, `colorDelete`, `colorSearchBar`, `colorSelected`, `bg`. Use the existing semantic name when the project already has it; only add hex-named when no semantic matches. |
| **D-1004** | Dedup before adding | Search `xcassets/Colors/` for the hex first. If `color0F0F0F` exists → reuse, do NOT create a duplicate semantic alias. |
| **D-1005** | Banned color patterns | Inline `Color(red:green:blue:)`, `Color(hex:"#...")` extension call when an asset exists, `Color(.sRGB, ...)` |
| **D-1006** | When to materialize a colorset | C1 step 7 emits `tokens.json` with light/dark hex pairs from Figma. `scripts/colorset-codegen.sh` runs at B0b to create colorsets in xcassets — Ikame variant emits `color<HEX>` names by default |

---

## §12. Font / typography

**Canonical source: `ikame-ios-coding/references/fonts-and-styling.md` and `references/fonts-styling-bridge.md`.** This section mirrors the locked values; if it conflicts with the source, follow the source.

| ID | Decision | Locked value |
|---|---|---|
| **D-1101** | Preset typography (canonical) | `.ikHeading1()` (56/70), `.ikHeading2()` (48/60), `.ikHeading3()` (40/50), `.ikLargeTitle()` (32/40), `.ikTitle()` (24/30), `.ikSmallTitle()` (20/24), `.ikSubtitle18()` (18/26), `.ikSubtitle16()` (16/24), `.ikBody()` (14/20), `.ikCaption12()` (12/16), `.ikLabel11()` (11/14). Each takes an optional `weight:` (`.regular`, `.medium`, `.semibold`, `.bold`). |
| **D-1102** | Application form (canonical) | `Text("…").ikBody(weight: .medium)` (Text overload, preferred). Also valid on `View`: `SomeView().ikSubtitle16()`. For `Font` / `UIFont` values: `Font.ikTitle(weight: .bold)`, `UIFont.ikBody(weight: .medium)`. |
| **D-1103** | Off-token escape hatch | `Text("…").ikFont(<size>, weight: .<weight>)` (or `.ikFont(<size>, weight:)` on `View`). Use only when Figma size doesn't match any preset; **do NOT round to the nearest preset**. Extract repeated specials into a `private static let` constant at the top of the screen file. |
| **D-1104** | Style-based / Dynamic-Type form | `Text("…").ikFont(.body, weight: .medium)` / `Text("…").ikFont(.custom(size: 22), weight: .bold)` — uses `IKFontConfig.TextStyle` semantic sizes that scale with Dynamic Type or screen width when the project has `scaledSizeByWidth: true` in `IKFontSystem.shared.configure(...)`. Use when C1 detects width-scaling enabled or design has explicitly opted into responsive typography. |
| **D-1105** | Italic variants | `Text("…").ikItalicFont(size: <size>, weight:)` (SwiftUI), `UIFont.ikGetItalicFont(size: <size>)` (UIKit). |
| **D-1106** | Additional font families (per project) | For a font family different from the project's main `ikFont` family, add a 4-layer helper file `Utilities/Extensions/<Family>+Ext.swift` defining `UIFont.<family>(_:weight:italic:)` + `Font.<family>(_:weight:italic:)` + `View.<family>(_:weight:italic:)` + `Text.<family>(_:weight:italic:)` that **delegate to `ikCustomFont(familyName:size:weight:italic:)` from IKCoreApp**. Never call `Font.custom("Family-Weight", size:)` or `UIFont(name:size:)` at the call site. Register `.ttf`/`.otf` files in `Resources/Fonts/` + Copy Bundle Resources + `UIAppFonts` in Info.plist. |
| **D-1107** | Banned font patterns | `.font(.system(size:weight:))`, `.font(.body)` / `.font(.headline)` SwiftUI semantic roles, `Font.custom("…", size:)` at call site (use 4-layer helper instead), `.fontWeight(.bold)` separate from preset's `weight:` parameter, `Text("…").font(.ikBody())` instead of canonical `Text("…").ikBody()` (the Text overload is preferred), inline `ikFont(N, …)` repeated 5+ times in one file (extract a constant) |
| **D-1108** | App-level font setup | One-time `IKFontSystem.shared.configure(familyName: "<Family>", sizes: .default)` (or custom `Sizes(...)`) in `AppDelegate.application(_:didFinishLaunchingWithOptions:)`. Until configured, `ikFont` falls back to the iOS system font. Font files follow `<Family>-<Weight>.ttf` (e.g. `Inter-Regular.ttf`, `Inter-Bold.ttf`). |

**Token → preset decision flow (B0b codegen):** read `tokens.json.typography[]` and for each entry pick:

1. **Size + line-height match a preset exactly** (32/40 → `ikLargeTitle`, 14/20 → `ikBody`, etc.) → emit call sites as `Text("…").ik<Preset>(weight: .<weight>)`. The preset table is the canonical mapping; **do not** emit a `AppFont.<token>()` wrapper for these.
2. **Size off-token but family is the project family** → emit `Text("…").ikFont(<size>, weight: .<weight>)`. Per-screen specials only; extract a `private static let <name>FontSize: CGFloat = <size>` at the top of the screen file when used > 3 times.
3. **Family different from the project's main `ikFont` family** → emit per-family helper call (`Text("…").<family>(<size>, weight: .<weight>)`) and ensure the 4-layer helper file exists per D-1106. If missing, **STOP** and add the helper file.

```swift
// ✓ Canonical — preset on Text
Text(Strings.Home.title)
    .ikLargeTitle(weight: .bold)
    .foregroundStyle(Color(.text900))

// ✓ Off-token escape hatch — per-screen special
Text("\(score)")
    .ikFont(64, weight: .bold)

// ✓ Additional font family (e.g. FiraCode for code snippets)
Text(logLine)
    .firaCode(13)        // helper delegates to ikCustomFont(familyName: "FiraCode", …)

// ✗ Banned — system font / SwiftUI role / raw Font.custom at call site
Text("X").font(.system(size: 14))
Text("X").font(.body)
Text("X").font(.custom("FiraCode-Regular", size: 13))
```

**Brownfield (`.appFont` legacy).** Some older Ikame projects ship a project-local `.appFont(<size>, weight:)` modifier wrapping `Font.custom(...)` in `Utilities/Fonts/`. C1 captures this as `fontModifier: "appFont"` (vs canonical `"ikFont"`). When `appFont` is detected, match the legacy form in additions to that project; **canonical new code uses `ikFont` from IKCoreApp.** Do NOT introduce a new `appFont` wrapper into a project that doesn't have one.

---

## §13. ViewModel internals

**Canonical source: `ikame-ios-coding/references/viewmodel.md`.** This section mirrors the locked values; if it conflicts with the source, follow the source.

| ID | Decision | Locked value |
|---|---|---|
| **D-1201** | Class declaration | `@MainActor final class <Name>ViewModel: ObservableObject` — `final` recommended; `ObservableObject` (iOS 16+) NOT `@Observable` (deployment target locked to iOS 16) |
| **D-1202** | Action enum | Nested `enum Action` with cases for every user-driven / lifecycle event the View dispatches. Verb-prefixed cases (`viewDidLoad`, `didTap…`, `didChange…`, `didSubmit…`, `dismissRoute`). |
| **D-1203** | Route enum | Nested `enum Route: Equatable, Hashable` with cases for every navigation destination. **`Equatable + Hashable` required** so `.navigationDestination(item:)` binding works (D-404). Omit `Route` entirely if the screen has zero outgoing navigation. |
| **D-1204** | Reducer | `func send(_ action: Action) { switch action { ... } }` — single entry point from View. Every case handled explicitly. Long-running work goes into `private` async methods called from `send`. |
| **D-1205** | State storage | Flat `@Published var <name>: <Type>` — one `@Published` per cell. Aggregated `struct ViewState` is banned (only exception: a form input bag where fields always change together AND only one subview observes them). See `ikame-ios-coding/references/viewmodel.md` §3. |
| **D-1206** | Route delivery | **`@Published var route: Route?`** — state-driven. ViewModel sets `route = .<case>` inside `send`; View binds `.navigationDestination(item: $viewModel.route)` (or `.sheet(item:)` / `.fullScreenCover(item:)`). Dismissal: `case dismissRoute` action sets `route = nil`. **NOT** `let routePublisher = PassthroughSubject<Route, Never>()` — that legacy form is brownfield-only (see D-404 brownfield note). |
| **D-1207** | Repository / Service injection | Init parameter with **default value pointing at the registry** — `init(repository: any <Domain>Repository = API.<domain>Repository)`. Tests inject a mock conforming to the same protocol; production code uses the default. **Never** `<Domain>RepositoryImpl(...)` directly in the init default — always go through `API.<domain>Repository`. |
| **D-1208** | Background work | `Task { await loadX() }` from inside the reducer — VM's `@MainActor` isolation continues into the task; results assigned on main automatically. Explicit `Task { @MainActor in ... }` is needed only when the task is launched from a non-MainActor context. |
| **D-1209** | Error handling | Domain-specific `enum <Name>Error: Error`, caught case-by-case. Generic `catch` only as fallback to a localized message (see `references/swift-style.md` §9 and `ikame-ios-coding/references/viewmodel.md` §"Calling APIs from `send`"). |
| **D-1210** | UI feedback from VM | `IKToast.show(.<id>, message:)` / `IKLoading.showLoading()` / `IKPopup.shared.popup { ... }` are MainActor-safe and may be called directly from the VM. No need to bounce through View. |

```swift
// ✓ Canonical — state-driven route, registry-injected repository
@MainActor
final class HomeViewModel: ObservableObject {
    enum Route: Equatable, Hashable {
        case detail(Article)
        case settings
    }
    enum Action {
        case viewDidLoad
        case didTapArticle(Article)
        case didTapSettings
        case didPullToRefresh
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
        case .viewDidLoad:
            Task { await loadArticles() }
        case .didTapArticle(let article):
            route = .detail(article)
        case .didTapSettings:
            route = .settings
        case .didPullToRefresh:
            Task { await loadArticles() }
        case .dismissRoute:
            route = nil
        }
    }

    private func loadArticles() async {
        isLoading = true
        defer { isLoading = false }
        do {
            articles = try await articleRepository.getArticles(page: 1)
        } catch {
            errorMessage = error.localizedDescription
            IKToast.show(.error, message: errorMessage ?? "Unknown error")
        }
    }
}
```

---

## §14. Constants nested struct (Ikame convention)

| ID | Decision | Locked value |
|---|---|---|
| **D-1301** | Per-screen constants | Declare `struct <Name>ScreenConstants { static let <key>: <Type> = <value> }` nested **inside the View struct** for every static label / config used in the body |
| **D-1302** | Per-screen menu config | Declare `struct Constants { static let menuConfiguration: MenuPopupConfiguration = .init(...) }` nested in View struct when screen owns popup configs |
| **D-1303** | Global constants | `IKConstants.shared.<KEY>` (e.g. `IKConstants.shared.HEIGHT_SCREEN`) — provided by IKCoreApp |
| **D-1304** | App-level constants | `AppConstants.<KEY>` (e.g. `AppConstants.KeyICloudSyncEnabled`) — `Utilities/Helpers/Constants.swift` |
| **D-1305** | Banned constants patterns | Free-floating `let title = "..."` at file scope, magic numbers in body without comment |

```swift
// ✓ Canonical (matches CodesHomeScreen)
struct CodesHomeScreen: View {
    struct Constants {
        static let menuConfiguration: MenuPopupConfiguration = .init(
            popupTypes: [.selectMode, .createFolder]
        )
    }

    struct CodesHomeScreenConstants {
        static let title: String = "Authenticator".ikLocalized()
        static let renameTitle: String = "Rename".ikLocalized()
        // ...
    }

    @AppStorage(AppConstants.KeyICloudSyncEnabled) private var iCloudSyncEnabled: Bool = false
    // ...
}
```

---

## §15. Verb naming for action handlers

Cross-ref `references/project-structure.md` §5. In Ikame code, common verbs in the View extension are:

| Prefix | Use for | Ikame example |
|---|---|---|
| `action...` | top-level action handler triggered by a route | `actionShowCameraView()`, `actionUploadFromLibrary()` |
| `show...` | UI presentation (popup, sheet, modal) | `showPopupConfirmDeleteOTP(objectIds:)`, `showShareOTPScreen(otps:)`, `showRenameFolderPopup(folderId:currentName:)` |
| `process...` | data processing | `processCodeFromString(_:)`, `processCodeFromImage()` |
| `import...` | data import | `importFromFile()` |
| `add...` | append / save | `addScannedCodeToDB(codes:showToast:)` |
| `detect...` | analysis / extraction | `detectCodes(in:)` |
| `onNavigation(to:)` | route handler in extension | `func onNavigation(to route: VM.Route) { ... }` |

These are conventions, not hard-enforced. Skill emits matching verbs by default; deviation OK if Figma context strongly suggests a different verb.

---

## §16. STOP rules — when to escalate to leader (subagent contract)

A subagent generating screens **MUST STOP and emit a delta-request** instead of inventing in any of these cases:

| Trigger | What to put in the delta-request |
|---|---|
| Need a new component referenced by ≥2 features | `{ "type": "component", "name": "AppXxxView", "rationale": "...", "figmaNodeIds": [...] }` |
| Need a new entity model | `{ "type": "entity", "name": "GXxxModel", "source": "GRDB|Firebase", "fields": [...] }` |
| Need a new API service, OR discover an existing per-feature service is being consumed by a 2nd feature (must promote to `Core/Services/` per D-210b) | `{ "type": "service", "scope": "app\|feature", "rationale": "...", "endpoints": [...], "promoteFrom": "<old path or null>" }` |
| Need a new navigation destination | `{ "type": "route", "case": "case xxxScreen(...)", "destinationView": "..." }` |
| Need a new tracking enum case | `{ "type": "tracking", "case": "...", "rationale": "..." }` |
| Need a new popup configuration | `{ "type": "popupConfig", "case": ".xxxPopup", "rationale": "..." }` |
| Need a new ToastType case | `{ "type": "toastType", "case": "...", "rationale": "..." }` |
| Figma value (color, font, spacing) does NOT match any existing token AND adding a new token would touch shared files | `{ "type": "token", "category": "color|font|spacing", "figmaValue": "...", "proposedName": "..." }` |
| Ambiguity in Figma (loading state vs error state, screen vs popup, etc.) | `{ "type": "ambiguity", "question": "...", "evidence": [...] }` |

**Banned alternative behaviors:**
- Emit a parallel definition in feature folder.
- Inline-define a one-off enum / struct that conceptually belongs in shared.
- Pick the "closest" Figma token without flagging the drift.
- Skip the screen with a `// TODO`.
- Add the token to a shared file directly (subagent has READ-only access to `Sources/Shared/`, `Components/`, `Entities/`, `Core/`, `Utilities/`).

The leader's merge phase resolves delta-requests by editing shared files and re-running gates.

---

## §17. Gate enforcement summary

| Gate | What it checks (Ikame additions) |
|---|---|
| `c8-conventions-gate.sh` | D-201..D-219 (path / file naming) — recognizes `screenFolderConvention: "one-screen-per-folder"` (canonical) and `"ikame-feature-flat"` (brownfield) |
| `c8-vm-pattern.sh` | D-1201..D-1210 (VM shape) — canonical Route delivery is `@Published var route: Route?`; accepts `routePublisher` only when C1 captures `viewToRouteWiring: "routePublisher"` |
| `c8-iknavigation.sh` | D-401..D-407 (navigation) — runs when `usesIKNavigation == true` |
| `c8-ikfont.sh` | D-1101..D-1108 (font tokens) — canonical modifier is `ikFont` family; accepts `appFont` only when C1 captures `fontModifier: "appFont"` |
| (new) `c8-ikpopup.sh` | D-501..D-507 — flags vanilla popup APIs without `// allow-vanilla-popup` justification; runs when `usesIKPopup == true` |
| (new) `c8-ikfeedback.sh` | D-601..D-607 — runs when `usesIKFeedback == true` |
| (new) `c8-iktracking.sh` | D-701..D-705 — runs when `usesIKTracking == true` |
| (new) `c8-iklocalized.sh` | D-801..D-806 — flags `NSLocalizedString`, manual `LocalizedStringKey(...)`, `Text("...".ikLocalized())` (double-localize), missing `.ikLocalized()` on String constants; runs when `usesIKLocalized == true` |
| `c6-asset-completeness.sh` | D-901..D-905 — already enforces no `Image(systemName:)` for Figma nodes |
| (new in colorset-codegen) | D-1001..D-1006 — `color<HEX>` naming + dedup |

Gates marked `(new)` are pending implementation — see implementation roadmap in `docs/workflow.md` (TBD).

---

## §18. Failure-mode self-check (before emitting any Ikame-flavored code)

Before any subagent writes a `.swift` file, run this checklist mentally:

1. **Imports.** Did I write only `import IKCoreApp` (not the individual `import IKNavigation` / `IKFont` / etc.)? — D-101
2. **Path.** Does the file go to `Screens/<ScreenName>/...` (canonical one-folder-per-screen) — or `Screens/<Feature>/...` (brownfield feature-flat only, when C1 detected it)? Did I check §3 table? — D-201..D-219
3. **State.** Did I use `@MainActor final class … : ObservableObject` + `@StateObject` ownership + flat `@Published`? Not `@Observable`, not a nested `struct ViewState`? — D-301, D-1201, D-1205
4. **Navigation.** Did I use **state-driven** `@Published var route: Route?` (canonical) — or `routePublisher` (brownfield, only when C1 detected `viewToRouteWiring: "routePublisher"`)? Did I bind `.navigationDestination(item: $viewModel.route)` in the View? Did I avoid `NavigationStack` / `NavigationLink` / `NavigationPath`? — D-401, D-404, D-406, D-1206
5. **Popup.** Did I use `IKPopup.shared.popup { … }` / `.sheet { … }` / `.fullScreen { … }` / `.show(configuration:) { … }` (canonical closure form) — or `IKPopup.shared.showPopup(swiftUIView:configuration:)` (brownfield, only when C1 detected `popupInvocationStyle: "namedArgs"`)? Did I avoid `.sheet(isPresented:)` etc. without `// allow-vanilla-popup`? — D-501, D-502, D-505
6. **Toast.** Did I use `IKToast.show(.<id>, message:)` (canonical) — or `AppUtils.shared.showAppBottomToast(for: .<case>)` (only when C1 detected an app-level wrapper)? — D-603, D-604
7. **Loading.** Did I pair `IKLoading.showLoading()` with `defer { IKLoading.dismissLoading() }`? — D-601
8. **Haptics.** Did I use `IKHaptics.<api>` — not `UIImpactFeedbackGenerator` or `.sensoryFeedback`? — D-605, D-606
9. **Tracking.** Did I add `.ikLogScreenActive(AppTracking.<case>)` to the body? Did the case exist in `AppTracking` enum? — D-701, D-705
10. **Localization.** `Text("...")` literals left alone (SwiftUI auto-localizes via LocalizedStringKey)? Every user-facing String stored as `String` (constants, popup args, format strings) has `.ikLocalized()`? Did I avoid `Text("...".ikLocalized())` (double-localize anti-pattern)? — D-801..D-805
11. **Asset.** Every image is `Image(.<symbol>)`? Every color is `Color(.<name>)`? — D-901, D-1001
12. **Font.** Every typography uses an `ikFont` preset (`Text("…").ikBody(weight:)` / `.ikLargeTitle()` etc.) or `ikFont(size:weight:)` escape hatch? Brownfield projects with C1 `fontModifier: "appFont"` use `.appFont(...)` instead. — D-1101..D-1107
13. **Constants.** Static labels in nested `<Name>ScreenConstants` struct? — D-1301
14. **Verbs.** Action handlers prefixed `action`/`show`/`process`/...? — §15

If any answer is "no" or "unsure", STOP and consult this file (or `ikame-ios-coding/references/<topic>.md` for the canonical convention), OR escalate to leader via delta-request (§16). **Do not "best-effort" — that is the failure mode this skill exists to prevent.**
