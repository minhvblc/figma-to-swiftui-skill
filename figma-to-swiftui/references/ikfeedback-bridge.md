# IKFeedback Bridge

**Canonical source: [`ikame-ios-coding/references/ui-popup-toast-loading.md`](../../ikame-ios-coding/references/ui-popup-toast-loading.md)** — `IKToast.show(...)`, `IKToast.showExclusive(...)`, `IKLoading.showLoading()`/`dismissLoading()`. This file holds only the figma-specific delta.

Applies only when `c1-conventions.json.usesIKFeedback == true`.

## §1. Detection (C1 audit)

`usesIKFeedback = true` when any signal: `IKToast.show` / `IKLoading.showLoading` in any file; `import IKCoreApp` + the project has feedback handling; brownfield `AppUtils.shared.showAppBottomToast` wrapper detected.

C1 captures:
- `toastApi`: `"ikToast"` (canonical) or `"appToastWrapper"` (brownfield)
- `appToastWrapper.typeName` + `funcSig` — when brownfield wraps `IKToast` (e.g. `AppUtils.shared.showAppBottomToast(_:duration:)`)

## §2. Toast — canonical IKToast vs brownfield wrapper

**Canonical (`toastApi == "ikToast"`):**
```swift
IKToast.show(.success, message: "Saved!")
IKToast.show(.error,   message: "Network failed")
IKToast.show(.warning, message: "Battery low")
IKToast.show(.info,    message: "Check your inbox")
IKToast.show(.network, message: "Offline mode")
IKToast.showExclusive(.error, message: "...")  // dismisses other toasts
IKToast.dismissAll()
```

Built-in identifiers: `.success`, `.error`, `.warning`, `.info`, `.network`. Don't invent new ones — for project-specific styles, define a new `IKToastIdentifier` extension at app level (per `ikame-ios-coding`).

**Brownfield wrapper (`toastApi == "appToastWrapper"`):**
```swift
AppUtils.shared.showAppBottomToast("Saved!", duration: .short)
```

When C1 detects an `AppUtils`-style wrapper, the skill uses the wrapper at every call site instead of `IKToast.show` directly. Mixing the two in one PR is banned.

## §3. Figma feedback pattern → invocation map

| Figma pattern | Use |
|---|---|
| Top banner toast with check icon | `IKToast.show(.success, ...)` |
| Top banner toast with X icon (red) | `IKToast.show(.error, ...)` |
| Centered "Loading..." spinner overlay | `IKLoading.showLoading()` / `dismissLoading()` |
| Bottom toast (Material-style) | `AppUtils.shared.showAppBottomToast(...)` when `toastApi == "appToastWrapper"` — else canonical `.appBottomSheet` popup |
| Persistent banner (offline indicator) | Out of scope for IKToast — implement as inline view |

## §4. IKHaptics

Not covered by `ikame-ios-coding` canonical. When project uses haptics on user actions:

```swift
import IKCoreApp

IKHaptics.success()    // light success thump
IKHaptics.warning()    // double tap
IKHaptics.error()      // strong error
IKHaptics.selection()  // picker / segmented control change
IKHaptics.impact(.light)  // .medium, .heavy
```

Skill emits these alongside the navigation/state change they accompany (e.g. successful save → `IKHaptics.success()` then `IKToast.show(.success, ...)`).

## §5. Banned

- `Haptics.notificationOccurred(.success)` via `UIImpactFeedbackGenerator` directly — use `IKHaptics`
- Plain `Text("Saved")` overlay as a toast — use `IKToast`
- `ProgressView()` overlay as a loading screen — use `IKLoading`
