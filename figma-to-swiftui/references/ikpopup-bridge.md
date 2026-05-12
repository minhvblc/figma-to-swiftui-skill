# IKPopup Bridge

**Canonical source: [`ikame-ios-coding/references/ui-popup-toast-loading.md`](../../ikame-ios-coding/references/ui-popup-toast-loading.md)** — `IKPopup.shared.popup`, variants (`.toast`, `.popup`, `.sheet`, `.fullScreen`), `@Environment(\.ikPopupDismiss)`, async return values. This file holds only the figma-specific delta.

Applies only when `c1-conventions.json.usesIKPopup == true`.

## §1. Detection (C1 audit)

`usesIKPopup = true` when any signal: `import IKCoreApp` + `IKPopup.shared` usage; `IKPopupConfiguration` enum extension in any file; `Podfile` has `pod 'IKCoreApp'`.

C1 also captures:
- `popupConfigurations[]` — list of existing app-level `IKPopupConfiguration` extension cases (project-defined popup presets)
- `popupInvocationStyle` — `"closure"` (canonical) vs `"namedArgs"` (brownfield)

## §2. App-level `IKPopupConfiguration` extension

Many projects extend `IKPopupConfiguration` to define reusable popup styles (background dim, animation, dismissOnTap). The skill MUST use existing cases when the Figma popup matches one — never invent a new case unless authorized.

Example existing project file (`Core/Popup/PopupConfiguration+App.swift`):

```swift
extension IKPopupConfiguration {
    static let appBottomSheet = IKPopupConfiguration(
        variant: .sheet,
        backgroundColor: .black.opacity(0.4),
        dismissOnTap: true,
        animation: .spring(response: 0.4, dampingFraction: 0.85)
    )

    static let appCenterDialog = IKPopupConfiguration(
        variant: .popup,
        backgroundColor: .black.opacity(0.5),
        dismissOnTap: false
    )

    static let appFullScreen = IKPopupConfiguration(
        variant: .fullScreen,
        backgroundColor: .white
    )
}
```

C1 captures these cases. When Figma shows a bottom sheet → use `.appBottomSheet`. Center dialog → `.appCenterDialog`. Etc.

If the Figma popup pattern doesn't match any existing case → **STOP, ask the user**:
> *"Figma shows a [bottom sheet with custom blur background] but project has no matching `IKPopupConfiguration` case. Add new case `.appBlurredBottomSheet`?"*

## §3. Invocation styles

**Canonical (closure form):**
```swift
let result = await IKPopup.shared.popup(configuration: .appBottomSheet) {
    ConfirmDeleteView(itemName: article.title)
}
```

**Brownfield (named-args form)** — some older projects:
```swift
let result = await IKPopup.shared.show(
    variant: .sheet,
    backgroundColor: .black.opacity(0.4),
    content: { ConfirmDeleteView(itemName: article.title) }
)
```

C1's `popupInvocationStyle` determines which the skill emits. Don't mix the two in one project.

## §4. Figma popup pattern → invocation map

| Figma pattern | Use |
|---|---|
| Bottom sheet (slides from bottom, 40-80% height) | `.appBottomSheet` |
| Center dialog / alert with title + buttons | `.appCenterDialog` |
| Full-screen modal | `.appFullScreen` |
| Inline toast (auto-dismiss banner) | `IKToast.show(...)` — see [ikfeedback-bridge.md](ikfeedback-bridge.md) |

## §5. Banned

- `.sheet(item:)` / `.popover` at view root for non-trivial modals — use IKPopup
- Inline `IKPopupConfiguration(variant: ..., ...)` at call site — use the project-level `.appXxx` case
- Inventing a new `.appXxx` case without asking (per §2)
