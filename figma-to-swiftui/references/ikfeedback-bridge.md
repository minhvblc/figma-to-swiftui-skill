# IKFeedback Bridge

How `figma-to-swiftui` emits user-feedback code (loading indicator, haptics, toast) when the target project uses Ikame's feedback APIs (re-exported by `IKCoreApp`). Conditional — applies only when `c1-conventions.json.usesIKFeedback == true`.

**Canonical sources:**
- `ikame-ios-coding/references/ui-popup-toast-loading.md` — IKLoading and IKToast.
- `references/ikame-decision-table.md` §7 (D-601..D-607) — locked decisions including the brownfield wrapper pattern.

This file documents only the figma-specific delta and the APIs `ikame-ios-coding` does NOT yet cover (IKHaptics, project-level toast wrappers like `AppUtils.shared.showAppBottomToast`).

Three feedback families:
- **IKLoading** — global modal loading spinner (canonical, in ios-coding-skill)
- **IKToast** — top-of-screen banner with built-in identifiers (canonical, in ios-coding-skill)
- **IKHaptics** — haptic feedback wrapper (this bridge only)
- **AppUtils.shared.showAppBottomToast** — project-level bottom-toast wrapper observed in authenv2 (brownfield only — this bridge only)

---

## §1. Detection (C1 audit)

C1 sets `usesIKFeedback = true` when ANY of these signals are present:

| Signal | Where to look |
|---|---|
| `pod 'IKCoreApp'` in Podfile | grep |
| `import IKCoreApp` in any Swift file | grep |
| `IKLoading.showLoading(` call | `grep -r 'IKLoading\.\(show\|dismiss\)Loading'` |
| `IKToast.show(` call | `grep -r 'IKToast\.\(show\|showExclusive\|dismissAll\)'` |
| `IKHaptics.<member>` call | `grep -r 'IKHaptics\.'` |
| `AppUtils.shared.showAppBottomToast(` call (or other project-level toast wrapper) | `grep -r 'showAppBottomToast\|<projectWrapper>'` |

If any signal present → `usesIKFeedback = true`. Skill emits Ikame-flavored feedback by default.

If absent → skill uses native iOS APIs (`UIImpactFeedbackGenerator`, `ProgressView` overlay, custom toast). Do not introduce Ikame feedback into a project that doesn't have it.

C1 also captures:
- `toastApi` — `"ikToast"` (canonical, IKCoreApp's `IKToast.show(.<id>, message:)`) or `"appToastWrapper"` (project-level wrapper like authenv2's `AppUtils.shared.showAppBottomToast(for: .<case>)`).
- `appToastWrapper.typeName` (e.g. `ToastSceenType` in authenv2) — when `toastApi == "appToastWrapper"`, the existing enum's case list the skill must pick from.
- `appToastWrapper.funcSig` (e.g. `AppUtils.shared.showAppBottomToast(for:)`) — the exact call form to emit at call sites.

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

## §4. Toast — canonical `IKToast` (with brownfield wrapper option)

**Canonical invocation** — `IKToast.show(.<identifier>, message:)` with built-in identifiers from IKCoreApp:

```swift
IKToast.show(.success, message: "Saved!")
IKToast.show(.error,   message: "Network failed")
IKToast.show(.warning, message: "Storage almost full")
IKToast.show(.info,    message: "Update available")
IKToast.show(.network, message: "No internet connection")

// Dismiss other toasts first, then show this
IKToast.showExclusive(.error, message: "Save failed")

// Clear every toast
IKToast.dismissAll()
```

| Identifier | Use |
|---|---|
| `.success` | Operation succeeded, item saved/deleted, action confirmed |
| `.error` | Failed save, validation error, generic error |
| `.warning` | Approaching a limit, deprecation, "are you sure" hint |
| `.info` | Neutral info, tip, status update |
| `.network` | Connectivity issues specifically |

Custom visual styles registered once at app start: `IKToast.register(for: .customId) { msg in MyToastView(msg: msg) }`. See `ikame-ios-coding/references/ui-popup-toast-loading.md` for full API.

**Brownfield wrapper — `AppUtils.shared.showAppBottomToast`.** Some older Ikame projects (notably authenv2) defined an app-level toast wrapper that takes a project-specific enum case instead of a free-text message:

```swift
// authenv2 brownfield form — only when C1 captures toastApi: "appToastWrapper"
AppUtils.shared.showAppBottomToast(for: .copiedToast)
AppUtils.shared.showAppBottomToast(for: .saveFailed)
AppUtils.shared.showAppBottomToast(for: .syncCompleted)
```

The argument is a case from the project's `ToastSceenType` (or whatever name C1 captures as `appToastWrapper.typeName`). The wrapper routes to `IKToast` or `IKPopup.shared.toast` internally; the skill uses the wrapper when the project has one.

**When detected, follow the brownfield form:**
- If `toastApi == "appToastWrapper"` → emit `<funcSig>(for: .<case>)` using existing enum cases.
- If `toastApi == "ikToast"` (canonical, fresh ikxcodegen scaffold) → emit `IKToast.show(.<id>, message: "<text>")` directly.

**Rules (both forms):**
- Toast is **global** — appears in a fixed position, dismisses automatically. Do NOT manage its lifetime from view code.
- Toast is fire-and-forget — no result, no `await`. If you need confirmation, use `IKPopup.shared.popup { ... }` instead.
- For multiple events in quick succession (e.g. "saved 3 items"), aggregate into a single toast describing the batch — do NOT fire multiple toasts in a row.

When the project uses a wrapper enum AND Figma specifies a toast for an event that doesn't have an existing case → STOP and emit a delta-request `{ "type": "toastType", "case": "<name>", "rationale": "..." }`. Do NOT add the case from a feature subagent — toast types are app-wide.

**Banned alternatives:**

| Pattern | Replacement |
|---|---|
| Custom `.overlay { ToastView(...) }` with manual timer dismissal | `IKToast.show(.<id>, message:)` or wrapper |
| Third-party toast libraries (SwiftMessages, ToastSwiftUI) | `IKToast` |
| In-content banner styling that mimics a toast | If Figma shows a banner (not a toast), it's a banner — render inline, don't try to use IKToast |

---

## §5. Combining all three

A typical "save and confirm" flow uses all three feedback APIs:

```swift
// ✓ Canonical — IKToast directly
private func saveArticle(_ article: Article) async {
    IKLoading.showLoading()
    defer { IKLoading.dismissLoading() }

    do {
        try await API.articleRepository.save(article)
        IKHaptics.impactOccurred(.medium)             // tactile confirmation
        IKToast.show(.success, message: "Saved")      // visual confirmation
    } catch {
        IKHaptics.impactOccurred(.heavy)              // tactile error
        IKToast.show(.error, message: error.localizedDescription)
    }
}

// ✓ Brownfield form — when project has an app-level wrapper
private func saveOTPs(_ otps: [GROTPModel]) async {
    IKLoading.showLoading()
    defer { IKLoading.dismissLoading() }

    do {
        try await DatabaseManager.saveOtps(otps: otps)
        IKHaptics.impactOccurred(.medium)
        AppUtils.shared.showAppBottomToast(for: .savedToast)
    } catch {
        IKHaptics.impactOccurred(.heavy)
        AppUtils.shared.showAppBottomToast(for: .saveFailed)
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
4. **Toast API.** Did I check C1's `toastApi`? If `"ikToast"` (canonical), emit `IKToast.show(.<id>, message:)`. If `"appToastWrapper"` (brownfield), emit `<funcSig>(for: .<case>)`.
5. **Toast case.** When using a wrapper enum, is `.<case>` from the existing enum (C1 captured `appToastWrapper.typeName`)? If new case needed, did I emit a delta-request instead of inventing?
6. **Inline vs global.** Did I correctly identify whether the Figma design wants global modal loading (use `IKLoading`) vs inline component loading (use local `ProgressView` / spinner)?

If any answer is "no" / "unsure", STOP and consult `references/ikame-decision-table.md` §7 + `ikame-ios-coding/references/ui-popup-toast-loading.md`.
