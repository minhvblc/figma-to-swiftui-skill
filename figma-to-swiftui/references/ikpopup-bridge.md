# IKPopup Bridge

How `figma-to-swiftui` emits popup / sheet / alert code when the target project uses **IKPopup** (re-exported by `IKCoreApp`). Conditional — applies only when `c1-conventions.json.usesIKPopup == true`.

IKPopup replaces SwiftUI's native `.sheet(isPresented:)`, `.alert(isPresented:)`, `.fullScreenCover(isPresented:)`, and `.confirmationDialog` for Ikame projects. It is the **strong default**, not an absolute requirement — see §6 for justified deviations.

The full set of popup decisions is locked in `references/ikame-decision-table.md` §6 (D-501..D-507). This file expands on the patterns with full code examples.

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

## §2. Default invocation — async/await

Every popup is invoked via `await IKPopup.shared.showPopup(...)` from inside a `Task { @MainActor in ... }`:

```swift
Task { @MainActor in
    let result: <ReturnType>? = await IKPopup.shared.showPopup(
        swiftUIView: <SomeView>(...),
        configuration: .<configCase>
    )
    switch result {
    case .someAction:
        viewModel.send(.handleSomeAction)
    case nil:
        // dismissed
        break
    default:
        break
    }
}
```

The result is generic `T?` — `nil` means the user dismissed without choosing, `.some(value)` means the user picked an option. `T` is typically the popup view's nested `enum ReturnAction` (when the popup has multiple buttons) or `enum Action` (when the popup is for selection).

**Rules:**
- Always `Task { @MainActor in ... }` — popups need MainActor.
- Always `await` — never call without await; IKPopup returns immediately on the wrong path.
- Always handle `nil` (dismissed) explicitly — even if the action is "do nothing", document why with a `default: break` or `case nil: break`.

---

## §3. Common configuration cases

The `configuration:` parameter takes a static-let enum case from the project's IKPopup config extension. Common cases observed in authenv2:

| Case | Use for |
|---|---|
| `.menuPopup(<anchorPoint: CGPoint>)` | menu / dropdown anchored to a button frame |
| `.defaultPopup` | center modal — confirm dialogs, info boxes |
| `.passwordPopup` | password / PIN entry overlay |
| `.authenUndoPopup` | "deleted X — undo" snack-bar style at bottom |
| `.defaultNavigationPresentFullScreen` | full-screen sheet with internal nav (camera, scanner) |
| `.customAppSheetFixedHeight(height: <CGFloat>)` | bottom sheet with fixed height |

The skill must pick from cases the project already exposes (C1 captures `popupConfigurations`). When the Figma design implies a popup style not represented by any existing case → STOP and emit a delta-request `{ "type": "popupConfig", "case": "...", "rationale": "..." }` rather than inventing.

### Anchored menu popup pattern

When the popup anchors to a button (e.g. trailing menu icon), capture the button's frame first and feed the anchor point:

```swift
@State var moreButtonRect: CGRect = .zero

HoverButton {
    showMorePopupView()
} label: {
    Image(.icTrailingMenu)
        .onGlobalFrameChange { rect in
            moreButtonRect = rect
        }
}

func showMorePopupView() {
    Task { @MainActor in
        let popupSize: CGSize = getSizeOfView(view: MenuPopupView(configuration: .someConfig))
        let yPosition: CGFloat = computeAnchorY(buttonRect: moreButtonRect, popupSize: popupSize)
        let anchorPoint: CGPoint = .init(
            x: moreButtonRect.origin.x - popupSize.width + 32,
            y: yPosition
        )

        let type: MenuPopupType? = await IKPopup.shared.showPopup(
            swiftUIView: MenuPopupView(configuration: .someConfig),
            configuration: .menuPopup(anchorPoint)
        )

        IKHaptics.selectionChanged()

        switch type {
        case .selectMode:  viewModel.send(.changeHeaderState)
        case .createFolder: viewModel.send(.addFolder)
        default: break
        }
    }
}
```

---

## §4. Popup view body

A popup is a regular `struct <Name>View: View` placed in `Components/`. It declares its own return type and dismisses via `@Environment(\.ikPopupDismiss)`:

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
            Text(title).appFontHeading3()
            Text(subtitle).appFont(14, weight: .regular)
            TextField(placeholder, text: $text)

            HStack(spacing: 12) {
                Button(cancelTitle) { dismiss(.cancel) }
                Button(confirmTitle) { dismiss(.confirm(text)) }
            }
        }
        .padding(20)
        .onAppear { text = inputText }
    }
}
```

The `dismiss(.<case>)` call returns the chosen `ReturnAction` to the caller's `await`. The popup view never touches the parent's ViewModel directly — it returns through the `await`.

When the popup's content is itself a tracked screen (counts as analytics surface), add `.ikDialogScreenActive(AppTracking.<dialogName>)` modifier. See `references/iktracking-bridge.md` §3.

---

## §5. Result-driven follow-ups

After `await` returns, the calling site dispatches to the ViewModel through `send(_:)`. Do NOT mutate ViewModel state directly:

```swift
// ✓ Canonical
let result: AppPopupView.ReturnAction? = await AppUtils.shared.showAnyPopup(
    isDelete: true,
    with: .deleteOTP(objectIds: objectIds)
)
switch result {
case .rightButtonAction:
    codesHomeViewModel.send(.confirmedDeleteOTP(objectIds: objectIds))
default:
    break
}

// ✗ Banned — bypasses reducer
codesHomeViewModel.otpIdSelecteds = []
```

When the popup leads to navigation, dispatch a route on the ViewModel which the View receives via `routePublisher`:

```swift
// ✓ ViewModel
case .confirmedExportCodes(let codes):
    routePublisher.send(.exportCodesToQR(codes: codes))
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
| `.sheet(isPresented:)` | Use `IKPopup.shared.showPopup` |
| `.fullScreenCover(isPresented:)` | Use `IKPopup.shared.showPopup` with `.defaultNavigationPresentFullScreen` |
| `.alert(isPresented:)` / `.alert(item:)` | Use `IKPopup.shared.showPopup` with `.defaultPopup` and a custom alert view |
| `.confirmationDialog(...)` | Use `IKPopup.shared.showPopup` |
| `UIAlertController(title:message:preferredStyle:)` | Use `IKPopup` |
| Custom `ZStack` overlay popups built by hand | Use `IKPopup` — it handles backdrop, dismissal, animation, accessibility |

---

## §8. C8-ikpopup.sh enforcement

When `c1-conventions.json.usesIKPopup == true`:

1. **No bare `.sheet(isPresented:`** without `// allow-vanilla-popup:` within 3 lines above.
2. **No bare `.fullScreenCover(isPresented:`** without justification.
3. **No bare `.alert(isPresented:`** / `.alert(item:`** without justification.
4. **No `.confirmationDialog(`** without justification.
5. **No `UIAlertController` instantiation** anywhere.
6. **Files in `Components/` that look like popup views** (declare a nested `enum ReturnAction`) MUST import IKCoreApp and reference `@Environment(\.ikPopupDismiss)` for dismissal.

When `usesIKPopup == false`, the gate prints `GATE: SKIP (project does not use IKPopup)` and exits 0.

---

## §9. Failure-mode self-check

Before emitting a popup invocation:

1. Did I use `IKPopup.shared.showPopup(...)` async/await — not `.sheet(isPresented:)`?
2. Is the configuration case from the existing `popupConfigurations` list (C1) — not invented?
3. Did I wrap in `Task { @MainActor in ... }` and `await` the call?
4. Did I handle `nil` (user dismissed) explicitly?
5. After `await`, do I dispatch via `viewModel.send(.<action>)` — not mutate state directly?
6. If using vanilla SwiftUI popup → did I add `// allow-vanilla-popup: <reason>` comment?

If any answer is "no", STOP and consult `references/ikame-decision-table.md` §6 OR escalate via delta-request §16.
