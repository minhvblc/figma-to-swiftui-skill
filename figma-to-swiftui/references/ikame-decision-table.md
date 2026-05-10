# Ikame Decision Table — locked conventions for Ikame projects

The single source of truth for every code-shape decision the skill makes when emitting into an Ikame iOS project (detected via `usesIKCoreApp == true` in `c1-conventions.json`). Every row has an ID. Subagents and per-screen runs reference rows by ID; they **may not invent** alternatives.

This file locks **patterns**, not **values**. Values (specific colors, spacings, copy) always come from Figma per the *Figma là chân lý duy nhất* principle. Patterns (folder layout, ViewModel shape, navigation API, popup invocation) are locked here so 50 screens generated in parallel by 50 subagents emit the same shape.

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

## §3. Path and file naming (cross-ref `references/project-structure.md`)

| ID | Decision | Locked value |
|---|---|---|
| **D-201** | Feature folder | `Screens/<Feature>/` — flat, multiple screens per feature folder (NOT one folder per screen) |
| **D-202** | Main screen file | `Screens/<Feature>/<Feature>HomeScreen.swift` (entry screen) or `<Feature><Action>Screen.swift` (additional screens in same feature) |
| **D-203** | Screen extensions when file > 250 lines | `<Feature>HomeScreen+<Topic>.swift` (e.g. `+BodyView`, `+Action`, `+Navigation`) |
| **D-204** | Per-feature subview folder | `Screens/<Feature>/Subviews/` |
| **D-205** | Per-feature subview file naming | `<Feature>Home<Role>View.swift` (prefix = parent screen base name; suffix `View` always) |
| **D-206** | Per-feature subview as folder (multi-file) | `Screens/<Feature>/Subviews/<Feature>Home<Role>View/` (sub-folder when subview itself splits) |
| **D-207** | Per-feature ViewModel folder | `Screens/<Feature>/ViewModel/` |
| **D-208** | ViewModel file | `Screens/<Feature>/ViewModel/<Feature>HomeViewModel.swift` |
| **D-209** | Repository file (per-feature data layer) | `Screens/<Feature>/ViewModel/<Feature>HomeRepository.swift` — only when feature owns data orchestration |
| **D-210** | Per-feature Service (consumed by 1 feature only) | `Screens/<Feature>/ViewModel/<Feature><Topic>Service.swift` |
| **D-210b** | Shared Service (consumed by ≥2 features) | `Core/Services/<Name>Service.swift`. **MUST promote** the moment a 2nd feature needs the same service — subagent escalates via delta-request (§16 `service` with `promoteFrom`) rather than duplicating into its own feature folder. |
| **D-211** | Per-feature flow-only model | `Screens/<Feature>/Models/<Name>.swift` — only when used in 1 feature; promote to Entities when shared |
| **D-212** | Reusable component (≥2 features) | `Components/<Name>View.swift` (generic name, **prefix `App`** for cross-cutting reusable like `AppPopupView`, `AppToastCenterView`) |
| **D-213** | Reusable component as folder | `Components/<Name>View/` (multi-file like `MenuPopupView/`, `OTPRow/`) |
| **D-214** | App-wide model | `Entities/<Source>/<Prefix><Domain>Model.swift`. Prefix is **project-specific**, detected by C1 as `entitiesPrefix` and **may be empty**. Skill emits matching prefix for new entities. Examples: authenv2 uses `G` for GRDB models (`GROTPModel`, `GFolderModel`); other Ikame projects may have no prefix or a different one. **Never default to `G`** — that is authenv2-specific, not Ikame-standard. When `entitiesPrefix == ""`, emit unprefixed (`OTPModel`). |
| **D-215** | API service (app-level) | `Core/Services/<Name>Service.swift` |
| **D-216** | Database service / DB setup | `Core/Database/<Name>.swift` |
| **D-217** | Sync logic | `Core/Sync/<Name>.swift` |
| **D-218** | Router definition | `Core/Router/Main/MainRoute.swift` (route enum) + `Core/Router/Main/MainRouter.swift` (router conform) — extend, never create parallel |

Promotion rule: subview originally in `Screens/<F>/Subviews/` that is referenced by a 2nd feature → MOVE to `Components/`, drop feature prefix, rename with `App` prefix if cross-cutting.

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

| ID | Decision | Locked value |
|---|---|---|
| **D-401** | Navigation API | `navigation.push(to: NavigationItem.<case>)`, `navigation.finish()`, `navigation.sheet(route:)`, `navigation.fullScreenCover(route:)` |
| **D-402** | Route enum source | `Core/Router/Main/MainRoute.swift` — extend the `NavigationItem` enum already defined; do **NOT** invent per-feature route enums unless user explicitly asks |
| **D-403** | Router source | `Core/Router/Main/MainRouter.swift` — extend the `makeView(from:)` switch with a new `case` for the new screen |
| **D-404** | View → Navigation wiring | **`routePublisher` Combine pattern**: ViewModel exposes `let routePublisher = PassthroughSubject<Route, Never>()`; View `.onReceive(viewModel.routePublisher) { route in onNavigation(to: route) }`; handler is a `func onNavigation(to: VM.Route)` in extension |
| **D-405** | When to use `routePublisher` vs `@Published var route` | **Always `routePublisher`** in Ikame. The `@Published var route` form from `references/viewmodel-pattern.md` §1 is for non-Ikame projects only. |
| **D-406** | Banned navigation APIs | `NavigationStack`, `NavigationLink`, `.navigationDestination(for:)`, `.navigationDestination(item:)`, `NavigationPath`, `@State path = NavigationPath()` |
| **D-407** | Sheet with internal stack | `IKNavigationIdentifier` extension + `makeNavigationView(navigationIdentifier:)` impl on `MainRouter`; trigger via `navigation.sheet(navigation: .<id>)` |

```swift
// ✓ Canonical (matches CodesHomeScreen)
@MainActor
final class CodesHomeViewModel: ObservableObject {
    enum Route {
        case scanQRCode
        case editOTP(GROTPModel)
        case goToFolder(GFolderModel)
        // ...
    }
    enum Action { case changeHeaderState; case addFolder; /* ... */ }

    @Published var codesHomeState: CodesHomeState = .normal
    let routePublisher = PassthroughSubject<Route, Never>()

    func send(_ action: Action) {
        switch action {
        case .changeHeaderState: codesHomeState = (codesHomeState == .edit) ? .normal : .edit
        case .addFolder: routePublisher.send(.addFolder([]))
        // ...
        }
    }
}

struct CodesHomeScreen: View {
    @Environment(\.ikNavigationable) private var navigation
    @StateObject var codesHomeViewModel: CodesHomeViewModel = .init()

    var body: some View {
        VStack { /* ... */ }
            .onReceive(codesHomeViewModel.routePublisher) { route in
                onNavigation(to: route)
            }
    }
}

extension CodesHomeScreen {
    func onNavigation(to route: CodesHomeViewModel.Route) {
        switch route {
        case .scanQRCode: actionShowCameraView()
        case .editOTP(let otp): showEdit2FACode(otpSelected: otp)
        case .goToFolder(let folder): navigation.push(to: NavigationItem.folderDetail(folder: folder))
        // ...
        }
    }
}
```

Do not reset `route = nil` — `PassthroughSubject` does not retain. Re-tap re-publishes naturally.

---

## §6. Popup / Sheet / Alert

IKPopup is the **strong default** for Ikame projects, not an absolute requirement. Vanilla SwiftUI native APIs (`.sheet`, `.alert`) remain acceptable in specific cases (D-507) but should be a deliberate, justified choice — not the default.

| ID | Decision | Locked value |
|---|---|---|
| **D-501** | Default popup invocation | `IKPopup.shared.showPopup(swiftUIView:, configuration:, useHostingController:?, presentInsideKeyWindow:?)` — first choice unless D-507 applies |
| **D-502** | Invocation pattern | Async/await — `Task { @MainActor in let result: <T>? = await IKPopup.shared.showPopup(...) }` |
| **D-503** | Configuration enum cases | `.menuPopup(<anchorPoint>)`, `.defaultPopup`, `.passwordPopup`, `.authenUndoPopup`, `.defaultNavigationPresentFullScreen`, `.customAppSheetFixedHeight(height:)`, `<projectName>Popup` per project — C1 captures `popupConfigurations` from existing usages |
| **D-504** | Result shape | Generic `T?` — `nil` = dismissed, `.some(value)` = user chose. `T` is typically the popup view's nested `enum Action` or `enum ReturnAction` (e.g. `AppPopupView.ReturnAction`, `UndoPopupView.Action`, `InputDialogView.ReturnAction`) |
| **D-505** | Default-banned popup APIs | `.sheet(isPresented:)`, `.fullScreenCover(isPresented:)`, `.alert(isPresented:)`, `.confirmationDialog`, `UIAlertController` — should be replaced by IKPopup unless D-507 exception applies. Inline comment `// allow-vanilla-popup: <reason>` required to bypass the gate. |
| **D-506** | Body of popup view | A regular `struct <Name>View: View` placed in `Components/` — declares its own `enum ReturnAction`, dismisses via `@Environment(\.ikPopupDismiss)` |
| **D-507** | When vanilla SwiftUI popup is acceptable | (a) Figma explicitly mocks a system-style alert / share-sheet matching iOS native chrome; (b) user explicitly requests a non-IKPopup variant; (c) interop with UIKit-only SDKs (e.g. `UIActivityViewController` system share); (d) toolbar's native back-chevron handled by IKNavigation. When exception applies, add `// allow-vanilla-popup: <reason>` so the gate doesn't false-positive. |

Default: route through IKPopup. Deviations per D-507 must be justified inline; otherwise gate flags as drift.

```swift
// ✓ Canonical
Task { @MainActor in
    let result: AppPopupView.ReturnAction? = await AppUtils.shared.showAnyPopup(
        with: .deleteOTP(objectIds: objectIds)
    )
    switch result {
    case .rightButtonAction:
        codesHomeViewModel.send(.confirmedDeleteOTP(objectIds: objectIds))
    default: break
    }
}

// ✓ Direct IKPopup with custom view
let menuType: MenuPopupType? = await IKPopup.shared.showPopup(
    swiftUIView: MenuPopupView(configuration: .init(popupTypes: [.selectMode, .createFolder])),
    configuration: .menuPopup(anchorPoint)
)
```

---

## §7. Loading / Haptics / Toast

| ID | Decision | Locked value |
|---|---|---|
| **D-601** | Loading indicator (global) | `IKLoading.showLoading()` / `IKLoading.dismissLoading()` — paired with `defer { IKLoading.dismissLoading() }` after `showLoading` |
| **D-602** | Loading indicator (view-scoped) | None — Ikame uses global. Do NOT introduce per-view `ProgressView` overlays unless Figma shows a specific in-content spinner pattern |
| **D-603** | Haptic feedback | `IKHaptics.selectionChanged()`, `IKHaptics.impactOccurred(.medium)`, `.impactOccurred(.light)`, `.impactOccurred(.heavy)`, `.impactOccurred(.rigid)`, `.impactOccurred(.soft)` |
| **D-604** | Banned haptic APIs | `UIImpactFeedbackGenerator`, `UISelectionFeedbackGenerator`, `UINotificationFeedbackGenerator`, iOS 17 `.sensoryFeedback(.success, trigger:)` |
| **D-605** | Toast (global, bottom) | `AppUtils.shared.showAppBottomToast(for: .<ToastType>)` — `ToastType` is a project enum; C1 captures cases |
| **D-606** | Toast (in-content) | None — Ikame uses global. Do not introduce custom toast overlays |
| **D-607** | Banned toast APIs | Custom `.overlay { ToastView }`, third-party Toast libraries |

```swift
// ✓ Canonical
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
    .foregroundStyle(Color.text900)
```

---

## §11. Color reference

| ID | Decision | Locked value |
|---|---|---|
| **D-1001** | Color reference in code | `Color.<name>` — generated symbol from xcassets colorset (project's existing extension, e.g. `Color.bg`, `Color.text900`, `Color.colorE6E6E6`) |
| **D-1002** | New color from Figma | Add a colorset to `Resources/Assets.xcassets/Colors/` named `color<HEX>` (e.g. Figma `#0F0F0F` → asset `color0F0F0F`). Reference as `Color.color0F0F0F`. |
| **D-1003** | Semantic color name (when Figma provides) | Allowed: `accentRed`, `colorDelete`, `colorSearchBar`, `colorSelected`, `bg`. Use the existing semantic name when the project already has it; only add hex-named when no semantic matches. |
| **D-1004** | Dedup before adding | Search `xcassets/Colors/` for the hex first. If `color0F0F0F` exists → reuse, do NOT create a duplicate semantic alias. |
| **D-1005** | Banned color patterns | Inline `Color(red:green:blue:)`, `Color(hex:"#...")` extension call when an asset exists, `Color(.sRGB, ...)` |
| **D-1006** | When to materialize a colorset | C1 step 7 emits `tokens.json` with light/dark hex pairs from Figma. `scripts/colorset-codegen.sh` runs at B0b to create colorsets in xcassets — Ikame variant emits `color<HEX>` names by default |

---

## §12. Font / typography

| ID | Decision | Locked value |
|---|---|---|
| **D-1101** | Font modifier (project-tokenized) | `.appFont(<size>, weight: .<weight>)` — Ikame's project-wide font modifier. Defined in `Utilities/Fonts/` |
| **D-1102** | Heading shortcuts | `.appFontHeading1()`, `.appFontHeading2()`, `.appFontHeading3()`, `.appFontBody()`, etc. — shortcuts when Figma matches a defined heading style |
| **D-1103** | Skill behavior when Figma size doesn't match heading shortcut | Use `.appFont(<exactSize>, weight: <exactWeight>)` form; do NOT round to nearest heading. Figma value wins. |
| **D-1104** | Banned font patterns | `.font(.system(size:weight:))` raw, `.font(.body)` / `.font(.headline)` Dynamic Type roles, `Font.custom(...)`, `.fontWeight(.bold)` separate from `.appFont(_,weight:)` |
| **D-1105** | Dynamic Type | `.appFont` wraps `@ScaledMetric` internally — skill does not need to add `@ScaledMetric` separately |

```swift
// ✓ Canonical
Text(CodesHomeScreenConstants.title)
    .appFontHeading3()
    .fontWeight(.semibold)         // weight after the heading shortcut is OK
    .foregroundStyle(Color.black)

Text("Selected: \(count)")
    .appFont(20, weight: .semibold)
    .foregroundStyle(Color.text900)
```

---

## §13. ViewModel internals (Ikame variant)

| ID | Decision | Locked value |
|---|---|---|
| **D-1201** | Class declaration | `@MainActor final class <Name>ViewModel: ObservableObject` |
| **D-1202** | Action enum | Nested `enum Action` with cases for every event the View dispatches |
| **D-1203** | Route enum | Nested `enum Route` with cases for every navigation destination — used with `routePublisher`, NOT `@Published var route` |
| **D-1204** | Reducer | `func send(_ action: Action) { switch action { ... } }` — single entry point from View |
| **D-1205** | State storage | Flat `@Published var <name>: <Type>` — one `@Published` per cell. Aggregated `struct ViewState` is banned (see `references/viewmodel-pattern.md` §3a) |
| **D-1206** | Route publisher | `let routePublisher = PassthroughSubject<Route, Never>()` — let, not @Published. Combine subject. |
| **D-1207** | Repository / Service injection | Init parameter with default value — `init(repository: <Name>Repository = <Name>Repository())`. Tests inject mock; production code defaults. |
| **D-1208** | Background work | `Task { @MainActor in ... }` from inside the reducer — VM's `@MainActor` isolation continues into the task; results assigned on main automatically |
| **D-1209** | Error handling | Domain-specific `enum <Name>Error: Error`, caught case-by-case. Generic `catch` only as fallback to a localized message (see `references/swift-style.md` §9) |

```swift
@MainActor
final class CodesHomeViewModel: ObservableObject {
    enum Action {
        case changeHeaderState
        case addFolder
        case confirmedDeleteOTP(objectIds: Set<String>)
        case startDeleteOTP
        // ...
    }
    enum Route {
        case scanQRCode
        case editOTP(GROTPModel)
        case copiedPopup
        case popupDeleteCodeConfirm(objectIds: Set<String>)
        // ...
    }

    @Published var codesHomeState: CodesHomeState = .normal
    @Published var otpIdSelecteds: Set<String> = []
    @Published var newAddedOTPIds: Set<String> = []
    let routePublisher = PassthroughSubject<Route, Never>()

    private let repository: CodesHomeRepository

    init(repository: CodesHomeRepository = CodesHomeRepository()) {
        self.repository = repository
    }

    func send(_ action: Action) {
        switch action {
        case .changeHeaderState:
            codesHomeState = (codesHomeState == .edit) ? .normal : .edit
        case .addFolder:
            routePublisher.send(.addFolder(otps: Array(otpIdSelecteds)))
        case .confirmedDeleteOTP(let ids):
            Task { await deleteOTP(ids: ids) }
        // ...
        }
    }

    private func deleteOTP(ids: Set<String>) async { /* ... */ }
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
| `c8-conventions-gate.sh` | D-201..D-218 (path / file naming) — extended to recognize `screenFolderConvention == "ikame-feature-flat"` |
| `c8-vm-pattern.sh` | D-1201..D-1209 (VM shape) — accepts `routePublisher` as Route delivery in addition to `@Published var route` |
| `c8-iknavigation.sh` | D-401..D-407 (navigation) — runs when `usesIKNavigation == true` |
| `c8-ikfont.sh` | D-1101..D-1104 (font tokens) — runs when `usesIKFont == true` |
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
2. **Path.** Does the file go to `Screens/<Feature>/...` or `Components/...` or `Entities/...` or `Core/...`? Did I check §3 table? — D-201..D-218
3. **State.** Did I use `@StateObject + ObservableObject + routePublisher`? Not `@Observable`? — D-301, D-405
4. **Navigation.** Did I use `navigation.push(to: NavigationItem.<case>)`? Not `NavigationStack`/`NavigationLink`? — D-401, D-406
5. **Popup.** Did I use `IKPopup.shared.showPopup(...)` async? Not `.sheet(isPresented:)`? — D-501, D-505
6. **Feedback.** Did I use `IKLoading` / `IKHaptics` / `AppUtils.shared.showAppBottomToast`? Not vanilla SwiftUI / UIKit equivalents? — D-601, D-603, D-605
7. **Tracking.** Did I add `.ikLogScreenActive(AppTracking.<case>)` to the body? Did the case exist in `AppTracking` enum? — D-701, D-705
8. **Localization.** `Text("...")` literals left alone (SwiftUI auto-localizes via LocalizedStringKey)? Every user-facing String stored as `String` (constants, popup args, format strings) has `.ikLocalized()`? Did I avoid `Text("...".ikLocalized())` (double-localize anti-pattern)? — D-801..D-805
9. **Asset.** Every image is `Image(.<symbol>)`? Every color is `Color.<symbol>`? — D-901, D-1001
10. **Font.** Every typography is `.appFont(...)` or `.appFontHeading<N>()`? — D-1101..D-1104
11. **Constants.** Static labels in nested `<Name>ScreenConstants` struct? — D-1301
12. **Verbs.** Action handlers prefixed `action`/`show`/`process`/...? — §15

If any answer is "no" or "unsure", STOP and consult this file, OR escalate to leader via delta-request (§16). **Do not "best-effort" — that is the failure mode this skill exists to prevent.**
