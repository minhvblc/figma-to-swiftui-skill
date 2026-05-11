# IKPopup Bridge

How `figma-to-swiftui` emits popup / sheet / alert code when the target project uses **IKPopup** (re-exported by `IKCoreApp`). Conditional — applies only when `c1-conventions.json.usesIKPopup == true`.

**Canonical source: `ikame-ios-coding/references/ui-popup-toast-loading.md` and `references/ikame-decision-table.md` §6 (D-501..D-507).** This file holds only the figma-specific delta — anchored menu-popup positioning, popup view code generation patterns, project-level `IKPopupConfiguration` extension catalog.

IKPopup replaces SwiftUI's native `.sheet(isPresented:)`, `.alert(isPresented:)`, `.fullScreenCover(isPresented:)`, and `.confirmationDialog` for Ikame projects. It is the **strong default**, not an absolute requirement — see §6 for justified deviations.

---

## §1. Detection (C1 audit)

C1 sets `usesIKPopup = true` when ANY of these signals are present:

| Signal | Where to look |
|---|---|
| `pod 'IKCoreApp'` in Podfile (umbrella) | `grep -E "^\s*pod\s+'IKCoreApp'" Podfile` |
| `import IKCoreApp` in any Swift file | `grep -l 'import IKCoreApp' --include='*.swift' -r` |
| `IKPopup.shared.showPopup(` call in any Swift file | `grep -r 'IKPopup\.shared\.showPopup'` |
| `@Environment(\.ikPopupDismiss)` access | `grep -r 'ikPopupDismiss'` |

If any signal present → `usesIKPopup = true`. Skill emits IKPopup-flavored popups by default.

If absent → skill uses vanilla SwiftUI native popup APIs per `references/swiftui-pro/views.md`. Do not introduce IKPopup into a project that doesn't already have it.

C1 also captures `popupConfigurations` — the list of `.popup<Name>` cases the project defines, so the skill picks an existing case rather than inventing.

---

## §2. Default invocation — async/await (closure form)

Every popup is invoked via the trailing-closure form. The variant depends on positioning / dismissal needs:

| Variant | Call | Use |
|---|---|---|
| Preset center popup | `await IKPopup.shared.popup { <View> }` | Confirms, alerts, custom dialogs |
| Preset bottom sheet | `await IKPopup.shared.sheet { <View> }` | Pickers, action lists |
| Preset full-screen | `await IKPopup.shared.fullScreen { <View> }` | Multi-step modal, onboarding flow |
| Preset top toast | `await IKPopup.shared.toast { <View> }` | Custom toast — prefer `IKToast.show(.<id>, message:)` for standard cases |
| Custom configuration | `await IKPopup.shared.show(configuration: .<case>) { <View> }` | Anchored menus, project-specific layouts (see §3) |

All variants return `any Sendable?` asynchronously — cast to the popup view's nested `ReturnAction` / `Action` enum at the call site:

```swift
let result = await IKPopup.shared.popup {
    ConfirmDeleteView(itemName: name)
}
if let action = result as? ConfirmDeleteView.ReturnAction, action == .confirm {
    viewModel.send(.confirmedDelete)
}
```

**Rules:**
- Always `await` — never call without await; the popup `Task` is dropped and never presents.
- `IKPopup.shared.popup { ... }` is MainActor-safe and async. Plain `await ...` from any MainActor context works; you don't need to wrap in `Task { @MainActor in ... }` unless the caller is non-MainActor (e.g. a UIKit completion handler).
- Always handle `nil` explicitly — `nil` = user dismissed (tapped outside or `dismiss()` with no value). Don't silently swallow.

**Brownfield (`IKPopup.shared.showPopup(swiftUIView:configuration:)` legacy).** Some older Ikame projects use the named-argument form `IKPopup.shared.showPopup(swiftUIView: view, configuration: cfg)` from inside `Task { @MainActor in ... }`. C1 captures the prevailing form as `popupInvocationStyle: "closure"` (default) or `"namedArgs"`. When `namedArgs` is detected, match the legacy form in additions to that project — canonical new code uses the closure form above.

---

## §3. Project-level configuration cases

When using `IKPopup.shared.show(configuration:) { ... }`, the `configuration:` parameter takes a value from `IKPopupConfiguration`. Built-in defaults (provided by IKCoreApp): `.defaultPopup`, `.defaultSheet`, `.defaultFullScreen`, `.defaultToast`, `.defaultLoading`.

Most projects also define **per-project extension cases** on `IKPopupConfiguration` for app-specific layouts. Common cases observed in authenv2:

| Case | Use for |
|---|---|
| `.menuPopup(<anchorPoint: CGPoint>)` | menu / dropdown anchored to a button frame |
| `.passwordPopup` | password / PIN entry overlay |
| `.authenUndoPopup` | "deleted X — undo" snack-bar style at bottom |
| `.defaultNavigationPresentFullScreen` | full-screen sheet with internal nav (camera, scanner) |
| `.customAppSheetFixedHeight(height: <CGFloat>)` | bottom sheet with fixed height |

C1 captures `popupConfigurations` — the list of `.popup<Name>` cases the project defines, so the skill picks an existing case rather than inventing. **When the Figma design implies a popup style not represented by any existing case → STOP and emit a delta-request** `{ "type": "popupConfig", "case": "...", "rationale": "..." }` rather than inventing.

### Anchored menu popup pattern

When the popup anchors to a button (e.g. trailing menu icon), capture the button's frame first and feed the anchor point:

```swift
@State private var moreButtonRect: CGRect = .zero

HoverButton {
    showMorePopupView()
} label: {
    Image(.icTrailingMenu)
        .onGlobalFrameChange { rect in
            moreButtonRect = rect
        }
}

private func showMorePopupView() {
    Task { @MainActor in
        let popupSize = getSizeOfView(view: MenuPopupView(configuration: .someConfig))
        let yPosition = computeAnchorY(buttonRect: moreButtonRect, popupSize: popupSize)
        let anchorPoint = CGPoint(
            x: moreButtonRect.origin.x - popupSize.width + 32,
            y: yPosition
        )

        let result = await IKPopup.shared.show(configuration: .menuPopup(anchorPoint)) {
            MenuPopupView(configuration: .someConfig)
        }
        IKHaptics.selectionChanged()

        switch result as? MenuPopupType {
        case .selectMode:    viewModel.send(.changeHeaderState)
        case .createFolder:  viewModel.send(.addFolder)
        default:             break
        }
    }
}
```

---

## §4. Popup view body

A popup is a regular `struct <Name>View: View` placed in `Components/` (when reused across screens) or screen-prefixed under `Screens/<X>/Subviews/` (when used by only one screen). It declares its own return type and dismisses via `@Environment(\.ikPopupDismiss)`:

```swift
import SwiftUI
import IKCoreApp

struct InputDialogView: View {
    enum ReturnAction {
        case confirm(String)
        case cancel
    }

    let title: String
    let subtitle: String
    let placeholder: String
    let confirmTitle: String
    let cancelTitle: String
    let inputText: String

    @Environment(\.ikPopupDismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text(title).ikLargeTitle(weight: .bold)
            Text(subtitle).ikBody()
            TextField(placeholder, text: $text)

            HStack(spacing: 12) {
                Button(cancelTitle)  { dismiss(.cancel) }
                Button(confirmTitle) { dismiss(.confirm(text)) }
            }
        }
        .padding(20)
        .onAppear { text = inputText }
    }
}
```

The `dismiss(.<case>)` call returns the chosen `ReturnAction` to the caller's `await`. `dismiss()` with no argument returns `nil`. The popup view never touches the parent's ViewModel directly — it returns through the `await`.

When the popup's content is itself a tracked screen (counts as analytics surface), add `.ikDialogScreenActive(AppTracking.<dialogName>)` modifier. See `references/iktracking-bridge.md` §3.

---

## §5. Result-driven follow-ups

After `await` returns, the calling site dispatches to the ViewModel through `send(_:)`. Do NOT mutate ViewModel state directly:

```swift
// ✓ Canonical
let result = await IKPopup.shared.popup {
    ConfirmDeleteView(itemName: name)
}
if let action = result as? ConfirmDeleteView.ReturnAction, action == .confirm {
    viewModel.send(.confirmedDelete)
}

// ✓ Through an app-level wrapper (project-specific)
let result = await AppUtils.shared.showAnyPopup(
    isDelete: true,
    with: .deleteOTP(objectIds: objectIds)
)
if let action = result as? AppPopupView.ReturnAction, action == .rightButtonAction {
    codesHomeViewModel.send(.confirmedDeleteOTP(objectIds: objectIds))
}

// ✗ Banned — bypasses reducer
codesHomeViewModel.otpIdSelecteds = []
```

When the popup result needs to drive navigation, dispatch a route on the ViewModel — the View binds `$viewModel.route` to `.navigationDestination(item:)`:

```swift
// ✓ ViewModel
case .confirmedExportCodes(let codes):
    route = .exportCodesToQR(codes: codes)
```

---

## §6. When vanilla SwiftUI popup is acceptable (D-507)

Vanilla `.sheet`, `.alert`, `.confirmationDialog`, `.fullScreenCover` are NOT banned outright. They are acceptable in these cases:

| Case | Reason |
|---|---|
| Figma explicitly mocks system-style alert | iOS native chrome is the design intent |
| User explicitly requests non-IKPopup variant | user override wins |
| UIKit-only SDK interop | e.g. `UIActivityViewController` for system share sheet — wrapped via `UIViewControllerRepresentable` |
| Toolbar's native back-chevron | handled by IKNavigation (out of IKPopup scope) |

When using vanilla SwiftUI popup, **add an inline justification comment** so the gate doesn't false-positive:

```swift
// allow-vanilla-popup: system share sheet — UIActivityViewController is UIKit-only
.sheet(isPresented: $isShowingShareSheet) {
    ActivityViewControllerRepresentable(items: items)
}
```

The `c8-ikpopup.sh` gate scans for `.sheet(`, `.alert(`, `.confirmationDialog(`, `.fullScreenCover(`, `UIAlertController` and requires the comment marker `// allow-vanilla-popup:` within 3 lines above the call site. Otherwise it fails the gate.

---

## §7. Banned defaults

Without `// allow-vanilla-popup:` justification, the following are banned in Ikame projects:

| Pattern | Why banned |
|---|---|
| `.sheet(isPresented:)` / `.sheet(item:)` | Use `IKPopup.shared.popup { … }` or `IKPopup.shared.sheet { … }` |
| `.fullScreenCover(isPresented:)` / `.fullScreenCover(item:)` | Use `IKPopup.shared.fullScreen { … }` (or `.show(configuration: .defaultNavigationPresentFullScreen) { … }`) |
| `.alert(isPresented:)` / `.alert(item:)` | Use `IKPopup.shared.popup { … }` with a custom alert view |
| `.confirmationDialog(...)` | Use `IKPopup.shared.sheet { … }` with action list view |
| `UIAlertController(title:message:preferredStyle:)` | Use `IKPopup` |
| Custom `ZStack` overlay popups built by hand | Use `IKPopup` — it handles backdrop, dismissal, animation, accessibility |

Note: `.navigationDestination(item: $viewModel.route)` for push navigation is **NOT** banned — it's the canonical state-driven navigation binding (see `references/iknavigation-bridge.md` §3 Style A).

---

## §8. C8-ikpopup.sh enforcement

When `c1-conventions.json.usesIKPopup == true`:

1. **No bare `.sheet(isPresented:` / `.sheet(item:`** without `// allow-vanilla-popup:` within 3 lines above.
2. **No bare `.fullScreenCover(isPresented:` / `.fullScreenCover(item:`** without justification.
3. **No bare `.alert(isPresented:` / `.alert(item:`** without justification.
4. **No `.confirmationDialog(`** without justification.
5. **No `UIAlertController` instantiation** anywhere.
6. **Files that declare a nested `enum ReturnAction`** (popup views) MUST import `IKCoreApp` and reference `@Environment(\.ikPopupDismiss)` for dismissal.

When `usesIKPopup == false`, the gate prints `GATE: SKIP (project does not use IKPopup)` and exits 0.

---

## §9. Failure-mode self-check

Before emitting a popup invocation:

1. Did I use `IKPopup.shared.popup { ... }` / `.sheet { ... }` / `.fullScreen { ... }` / `.show(configuration:) { ... }` async — not `.sheet(isPresented:)` or `.alert(isPresented:)`?
2. If using `.show(configuration:)`, is the configuration case from the existing `popupConfigurations` list (C1) — not invented?
3. Did I `await` the call from a MainActor context (or wrap in `Task { @MainActor in ... }` if calling from non-MainActor)?
4. Did I handle `nil` (user dismissed) explicitly?
5. After `await`, do I dispatch via `viewModel.send(.<action>)` — not mutate state directly?
6. If using vanilla SwiftUI popup → did I add `// allow-vanilla-popup: <reason>` comment?
7. Is the popup view body using `ikFont` typography (not `.system(...)`) and `Color(.<name>)` from the asset catalog?

If any answer is "no", STOP and consult `references/ikame-decision-table.md` §6 + `ikame-ios-coding/references/ui-popup-toast-loading.md` OR escalate via delta-request §16.
