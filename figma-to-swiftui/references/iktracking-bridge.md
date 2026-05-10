# IKTracking Bridge

How `figma-to-swiftui` emits analytics tracking code when the target project uses Ikame's tracking infrastructure (`AppTracking` enum + `AppTrackingFeature.shared` + `.ikLogScreenActive` / `.ikDialogScreenActive` view modifiers). Conditional — applies only when `c1-conventions.json.usesIKTracking == true`.

The full set of tracking decisions is locked in `references/ikame-decision-table.md` §8 (D-701..D-705). This file expands on the patterns with full code examples.

---

## §1. Detection (C1 audit)

C1 sets `usesIKTracking = true` when ANY of these signals are present:

| Signal | Where to look |
|---|---|
| `pod 'IKCoreApp'` in Podfile | grep |
| `import IKCoreApp` in any Swift file | grep |
| `enum AppTracking` declaration in any Swift file | `grep -r 'enum AppTracking'` |
| `.ikLogScreenActive(` modifier usage | `grep -r 'ikLogScreenActive'` |
| `AppTrackingFeature.shared.addTrackingFeature(` call | `grep -r 'AppTrackingFeature\.shared'` |

If any signal present → `usesIKTracking = true`. Skill emits Ikame tracking calls.

C1 also captures:
- `trackingEnumName` — e.g. `AppTracking`
- `trackingEnumPath` — e.g. `Utilities/Tracking/AppTracking.swift`

---

## §2. Screen-active tracking — `.ikLogScreenActive`

**Mandatory on every full-screen View** — applied to the body's outermost modifier chain, exactly once per screen. The skill emits this by default for any new `*Screen.swift`:

```swift
struct CodesHomeScreen: View {
    var body: some View {
        VStack(spacing: .zero) {
            headerView
            bodyWithFooterView
        }
        .background(Color.bg)
        .ikLogScreenActive(AppTracking.codesHome)        // ← MANDATORY
    }
}
```

**Rules:**
- The argument is an `AppTracking` enum case representing the screen identity.
- The case must already exist in the enum — if not, **STOP and emit a delta-request** `{ "type": "tracking", "case": "<name>", "rationale": "<screen purpose>" }`. Subagents do NOT modify `AppTracking.swift` directly (it's app-wide shared state).
- Only one `.ikLogScreenActive` per screen — applied to the body root, not to subviews.

When the screen has multiple "states" (vd `.normal`, `.edit`, `.empty`) but it's still ONE logical screen, use ONE case (e.g. `AppTracking.codesHome`). Use distinct cases only when the user-perceived screens are different (e.g. `AppTracking.codesHome` vs `AppTracking.codesEdit`).

---

## §3. Dialog-active tracking — `.ikDialogScreenActive`

When a popup is itself a tracked surface (analytics treats it as a "screen"), apply `.ikDialogScreenActive` on the popup's body view inside `IKPopup.shared.showPopup(...)`:

```swift
let result: InputDialogView.ReturnAction? = await IKPopup.shared.showPopup(
    swiftUIView: InputDialogView(
        title: "Rename".ikLocalized(),
        // ...
    )
    .ikDialogScreenActive(AppTracking.dialogRenameFolder),     // ← on the dialog view
    configuration: .defaultPopup
)
```

**Rules:**
- One `.ikDialogScreenActive` per popup invocation.
- Case follows naming convention `AppTracking.dialog<Name>` (or whatever pattern the project uses — C1 captures the enum cases for reference).
- Apply at the call site of `showPopup` (chained on the `swiftUIView:` argument), not inside the popup's struct body.

If the popup is purely informational (e.g. a transient toast — though those use `AppUtils.showAppBottomToast` not IKPopup), do NOT add dialog-active tracking. It's only for popups that count as "user landed on this screen" in analytics terms.

---

## §4. Programmatic tracking — `AppTrackingFeature.shared.addTrackingFeature`

For **action events** (button taps, status changes, errors), call programmatically inside the action handler:

```swift
func showCopiedToast() {
    AppUtils.shared.showAppBottomToast(for: .copiedToast)

    AppTrackingFeature.shared.addTrackingFeature(for: .ft_authenticator, params: [
        .action_type: AppTracking.action.rawValue,
        .action_name: AppTracking.copy_code.rawValue,
        .feature_target: AppTracking.yes.rawValue,
        .status: AppTracking.success.rawValue
    ])
}
```

**Rules:**
- The first argument (`for:`) is the **feature** the action belongs to (e.g. `.ft_authenticator`, `.ft_password`, `.ft_settings`). Cases come from `AppTracking` (or a sibling enum like `FeatureName`) — C1 captures the available cases.
- The `params:` dictionary uses `AppTracking` enum keys. Common keys observed in authenv2: `.action_type`, `.action_name`, `.feature_target`, `.status`. Other projects may have additional / different keys.
- All param values are `.rawValue` of `AppTracking` cases — string values directly are banned (use enum case → `.rawValue` for type safety).

When a needed param key or value case is missing from the `AppTracking` enum → STOP and emit a delta-request. Do NOT inline a string literal as a workaround.

---

## §5. AppTracking enum extension protocol

Subagents NEVER modify `AppTracking.swift` directly during a per-feature run. The leader's merge phase resolves delta-requests by adding cases.

When a subagent generating screen `Foo` needs:
- A new screen-active case `AppTracking.fooHome` → delta-request `{ "type": "tracking", "scope": "screen", "case": "fooHome" }`.
- A new dialog-active case `AppTracking.dialogFooConfirm` → delta-request `{ "type": "tracking", "scope": "dialog", "case": "dialogFooConfirm" }`.
- A new action name `AppTracking.foo_save` → delta-request `{ "type": "tracking", "scope": "action", "case": "foo_save" }`.
- A new feature `AppTracking.ft_foo` → delta-request `{ "type": "tracking", "scope": "feature", "case": "ft_foo" }`.

The subagent's file references the case **as if it exists** (the file won't compile until leader merges, but the leader's delta resolution happens before the integration build phase).

---

## §6. Banned alternatives

| Pattern | Why banned |
|---|---|
| Inline `Analytics.track("event_name", params: [...])` style call (Firebase Analytics direct) | Ikame uses AppTrackingFeature wrapper; direct Firebase calls bypass the project's tracking rules |
| String-literal param values (`["action": "tap_save"]`) | Type-unsafe; cases must be enum-rooted |
| `.onAppear { tracker.track(...) }` for screen-active | Use `.ikLogScreenActive(...)` modifier — handles lifecycle correctly |
| Per-subview `.ikLogScreenActive(...)` | One per full-screen view only |
| Multiple `.ikLogScreenActive(...)` chained on the same view | One per screen |

---

## §7. C8-iktracking.sh enforcement

When `c1-conventions.json.usesIKTracking == true`:

1. **Every new `*Screen.swift`** generated this run has a `.ikLogScreenActive(AppTracking.<case>)` modifier in `var body`.
2. **No string-literal tracking events** — `Analytics.track("...")`, `Firebase.Analytics.logEvent("...", parameters:...)`, `Mixpanel.track(...)` etc. are flagged.
3. **All `AppTrackingFeature.shared.addTrackingFeature(...)` param values** use `AppTracking.<case>.rawValue` — no inline string literals as values.
4. **Param keys** are `AppTracking.<case>` (or other project tracking enum) — not string literals.

When `usesIKTracking == false`, the gate prints `GATE: SKIP (project does not use IKTracking)` and exits 0.

---

## §8. Failure-mode self-check

Before emitting tracking code:

1. **Screen-active.** Did I add exactly one `.ikLogScreenActive(AppTracking.<case>)` to the screen's body root?
2. **Case existence.** Does `AppTracking.<case>` already exist? If not, did I emit a delta-request instead of inventing or hardcoding a string?
3. **Dialog-active.** For popups that count as analytics surfaces, did I add `.ikDialogScreenActive(...)` on the `swiftUIView:` argument of `showPopup`?
4. **Programmatic events.** Did I use `AppTrackingFeature.shared.addTrackingFeature(for:, params:)` with `.rawValue`'d enum cases — not Firebase or string-literal direct calls?
5. **Param values.** Every value is `<EnumCase>.rawValue` — no inline strings?

If any answer is "no" / "unsure", STOP and consult `references/ikame-decision-table.md` §8 OR escalate via delta-request §16.
