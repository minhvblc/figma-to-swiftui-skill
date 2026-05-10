# IKFeedback Bridge

How `figma-to-swiftui` emits user-feedback code (loading indicator, haptics, toast) when the target project uses Ikame's feedback APIs (re-exported by `IKCoreApp`). Conditional — applies only when `c1-conventions.json.usesIKFeedback == true`.

This bridge covers three Ikame APIs:
- **IKLoading** — global modal loading spinner
- **IKHaptics** — haptic feedback wrapper (selection / impact)
- **AppUtils.shared.showAppBottomToast** — global bottom toast

The full set of feedback decisions is locked in `references/ikame-decision-table.md` §7 (D-601..D-607). This file expands on the patterns with full code examples.

---

## §1. Detection (C1 audit)

C1 sets `usesIKFeedback = true` when ANY of these signals are present:

| Signal | Where to look |
|---|---|
| `pod 'IKCoreApp'` in Podfile | grep |
| `import IKCoreApp` in any Swift file | grep |
| `IKLoading.showLoading(` call | `grep -r 'IKLoading\.\(show\|dismiss\)Loading'` |
| `IKHaptics.<member>` call | `grep -r 'IKHaptics\.'` |
| `AppUtils.shared.showAppBottomToast(` call | `grep -r 'showAppBottomToast'` |

If any signal present → `usesIKFeedback = true`. Skill emits Ikame-flavored feedback by default.

If absent → skill uses native iOS APIs (`UIImpactFeedbackGenerator`, `ProgressView` overlay, custom toast). Do not introduce Ikame feedback into a project that doesn't have it.

C1 also captures `toastTypeEnumName` (e.g. `ToastSceenType` in authenv2) so the skill picks an existing case rather than inventing.

---

## §2. Loading — IKLoading

**Default invocation** — show / defer-dismiss inside a `Task`:

```swift
Task {
    IKLoading.showLoading()
    defer { IKLoading.dismissLoading() }

    do {
        try await someLongOperation()
        // ...
    } catch {
        // dismiss is automatic via defer
        showErrorToast()
    }
}
```

**Rules:**
- Always pair `IKLoading.showLoading()` with `IKLoading.dismissLoading()`.
- Use `defer { IKLoading.dismissLoading() }` immediately after `showLoading()` so any early return / throw still dismisses.
- IKLoading is **global** — never call from a view's `.task { }` modifier directly; always wrap in a `Task` triggered by a user action.
- Do NOT use `ProgressView` or custom spinner overlays for app-wide loading. Per-component inline progress (e.g. small spinner inside a list row) is OK and orthogonal to IKLoading.

**Banned alternatives** (without justification):

| Pattern | Replacement |
|---|---|
| Custom `.overlay { ProgressView() }` for global loading | `IKLoading.showLoading()` / `dismissLoading()` |
| `@State var isLoading = true` + `if isLoading { ProgressView() }` for global state | `IKLoading` |
| Third-party HUD libraries (SVProgressHUD, MBProgressHUD) | `IKLoading` (ikxcodegen-scaffolded projects do not include these) |

Inline component loading (a small spinner inside a button while a network call resolves, a list row showing a placeholder) is fine — that's a different use case from global modal loading.

---

## §3. Haptics — IKHaptics

**Default invocation** — single line at the moment the user-visible state changes:

```swift
Button(action: {
    IKHaptics.selectionChanged()         // ← when toggling state
    viewModel.send(.toggleSelection)
}) { Image(.icCheck38) }

// On confirmation
viewModel.send(.confirmedDelete)
IKHaptics.impactOccurred(.medium)        // ← after action commits

// On error
IKHaptics.impactOccurred(.heavy)
```

| API | Use for |
|---|---|
| `IKHaptics.selectionChanged()` | UI selection toggle (checkbox, picker, segment) |
| `IKHaptics.impactOccurred(.light)` | minor feedback (item appeared, gesture detected) |
| `IKHaptics.impactOccurred(.medium)` | confirm action committed (saved, deleted, completed) |
| `IKHaptics.impactOccurred(.heavy)` | major event (error, important alert) |
| `IKHaptics.impactOccurred(.rigid)` | tactile click for system-like buttons |
| `IKHaptics.impactOccurred(.soft)` | gentle feedback (subtle state change) |

**Rules:**
- One haptic per user-perceived event. Don't chain multiple `IKHaptics.<x>()` calls in the same handler.
- Trigger haptics on the View side (immediate user feedback), not inside the ViewModel reducer (which may run on a non-main task).
- For long-running actions: trigger on **start** with `.selectionChanged()` and on **completion** with `.impactOccurred(.medium)` — not at every interim step.

**Banned alternatives:**

| Pattern | Replacement |
|---|---|
| `UIImpactFeedbackGenerator(style: .medium).impactOccurred()` | `IKHaptics.impactOccurred(.medium)` |
| `UISelectionFeedbackGenerator().selectionChanged()` | `IKHaptics.selectionChanged()` |
| `UINotificationFeedbackGenerator().notificationOccurred(.success)` | `IKHaptics.impactOccurred(.medium)` (Ikame doesn't expose notification haptics directly) |
| iOS 17+ `.sensoryFeedback(.success, trigger: <state>)` view modifier | `IKHaptics` — keep API uniform across Ikame projects |

---

## §4. Toast — AppUtils.shared.showAppBottomToast

**Default invocation** — fire-and-forget at the moment the event happens:

```swift
// On copy
AppUtils.shared.showAppBottomToast(for: .copiedToast)

// On error
AppUtils.shared.showAppBottomToast(for: .saveFailed)

// On success
AppUtils.shared.showAppBottomToast(for: .syncCompleted)
```

The argument is a case from the project's `ToastSceenType` (or whatever name C1 captures as `toastTypeEnumName`). The skill picks an existing case rather than inventing.

**Rules:**
- Toast is **global** — appears at the bottom of the window, dismisses automatically. Do NOT manage its lifetime from view code.
- Toast is fire-and-forget — no result, no `await`. If you need confirmation, use `IKPopup` instead.
- For multiple events in quick succession (e.g. "saved 3 items"), aggregate into a single toast describing the batch — do NOT fire multiple toasts in a row.

When the Figma design specifies a toast for an event that doesn't have an existing `ToastSceenType` case → STOP and emit a delta-request `{ "type": "toastType", "case": "<name>", "rationale": "..." }`. Do NOT add the case from a feature subagent — toast types are app-wide.

**Banned alternatives:**

| Pattern | Replacement |
|---|---|
| Custom `.overlay { ToastView(...) }` with manual timer dismissal | `AppUtils.shared.showAppBottomToast` |
| Third-party toast libraries (SwiftMessages, ToastSwiftUI) | `AppUtils.shared.showAppBottomToast` |
| In-content banner styling that mimics a toast | If Figma shows a banner (not a toast), it's a banner — render inline, don't try to use `AppBottomToast` |

---

## §5. Combining all three

A typical "save and confirm" flow uses all three feedback APIs:

```swift
func saveOTPs(_ otps: [GROTPModel]) {
    Task {
        IKLoading.showLoading()
        defer { IKLoading.dismissLoading() }

        do {
            try await DatabaseManager.saveOtps(otps: otps)

            IKHaptics.impactOccurred(.medium)               // tactile confirmation
            AppUtils.shared.showAppBottomToast(for: .savedToast)   // visual confirmation

        } catch {
            IKHaptics.impactOccurred(.heavy)                // tactile error
            AppUtils.shared.showAppBottomToast(for: .saveFailed)
        }
    }
}
```

---

## §6. C8-ikfeedback.sh enforcement

When `c1-conventions.json.usesIKFeedback == true`:

1. **No `UIImpactFeedbackGenerator` or `UISelectionFeedbackGenerator` or `UINotificationFeedbackGenerator`** instantiation.
2. **No `.sensoryFeedback(` view modifier** (iOS 17+ haptics — Ikame uses IKHaptics for cross-project consistency).
3. **No `IKLoading.showLoading()` without a paired `IKLoading.dismissLoading()`** within the same `Task` block (grep check — `defer { IKLoading.dismissLoading() }` counts).
4. **No third-party toast / HUD imports** (`SwiftMessages`, `SVProgressHUD`, `MBProgressHUD`) appearing in this run's generated files.

When `usesIKFeedback == false`, the gate prints `GATE: SKIP (project does not use IKFeedback)` and exits 0.

---

## §7. Failure-mode self-check

Before emitting feedback code:

1. **Loading.** Did I wrap in `Task` with `defer { IKLoading.dismissLoading() }`? Not raw `ProgressView` overlay?
2. **Haptics.** Did I use `IKHaptics.<api>` — not `UIImpactFeedbackGenerator` or `.sensoryFeedback(`?
3. **Haptics.** One haptic per event — not chained / spammed?
4. **Toast.** Did I use `AppUtils.shared.showAppBottomToast(for: .<case>)` — not custom overlay?
5. **Toast case.** Is `.<case>` from the existing `ToastSceenType` enum (C1 captured)? If new case needed, did I emit a delta-request instead of inventing?
6. **Inline vs global.** Did I correctly identify whether the Figma design wants global modal loading (use `IKLoading`) vs inline component loading (use local `ProgressView` / spinner)?

If any answer is "no" / "unsure", STOP and consult `references/ikame-decision-table.md` §7.
