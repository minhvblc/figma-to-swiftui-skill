# IKOnboardingFlow Bridge

How `figma-to-swiftui` integrates with **IKOnboardingFlow** — Ikame's app-level flow orchestrator (re-exported by `IKCoreApp`). This framework owns the lifecycle between major app phases (splash → onboarding → main → IAP → deep-link routing) and is what `ikxcodegen` wires into the App entry point.

Conditional — applies when `c1-conventions.json.usesIKOnboardingFlow == true` (auto-set when `usesIKCoreApp == true` AND App entry imports `IKOnboardingFlow`).

The full set of related decisions is locked in `references/ikame-decision-table.md` §5 (D-401..D-407 navigation). This bridge documents the framework-level pattern that wraps individual screens.

---

## §1. Detection (C1 audit)

C1 sets `usesIKOnboardingFlow = true` when ANY of these signals are present:

| Signal | Where to look |
|---|---|
| `import IKOnboardingFlow` in App entry / SceneDelegate / AppDelegate | `grep -r 'import IKOnboardingFlow' --include='*.swift'` |
| `IKDI.onboardingFlow.register(forScreen: .` call anywhere | `grep -r 'onboardingFlow\.register'` |
| `IKDI.onboardingFlow.start(with:` call (typically in SceneDelegate) | `grep -r 'onboardingFlow\.start'` |
| `pod 'IKOnboardingFlow'` in Podfile | `grep -E "^\s*pod\s+'IKOnboardingFlow'" Podfile` |

If any signal present → skill respects the framework's screen-registration pattern. Otherwise the skill emits a vanilla App entry per `references/iknavigation-bridge.md` §6.

---

## §2. The framework's screen enum

IKOnboardingFlow defines an enum of well-known app phases. Common cases (project-specific values may differ; subagent reads from the framework's installed module — do NOT invent):

- `.splash` — initial launch screen with logo + progress
- `.onboarding` — multi-screen onboarding flow
- `.iap` — paywall / subscription screen
- `.main` — post-onboarding entry, typically the home / tab bar
- (project-specific) `.appLock`, `.permission`, etc.

When `usesIKOnboardingFlow == true`, C1 also captures `onboardingFlowScreens` — the list of cases the framework exposes. Subagents reference these by case name.

---

## §3. App entry pattern (canonical, do not modify)

`ikxcodegen` produces this pattern in `App/AppDelegate.swift`:

```swift
import UIKit
import IKCoreApp
import IKOnboardingFlow

@main
class AppDelegate: UIResponder, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: ...) -> Bool {
        setupCoreApp()
        return true
    }
    // ... (UIScene boilerplate)
}

extension AppDelegate {
    func setupCoreApp() {
        IKDI.sdk.start()

        // Register each app-level phase with the framework. The framework
        // calls these closures when it transitions into that phase.
        IKDI.onboardingFlow.register(forScreen: .main) {
            IKNavigation.makeView(router: MainRouter(), root: .mainRoute(.main))
        }
    }
}
```

`SceneDelegate.swift` triggers the framework:

```swift
import IKCoreApp
import IKOnboardingFlow

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: ..., options: ...) {
        guard let windowScene = (scene as? UIWindowScene) else { return }
        let window = UIWindow(windowScene: windowScene)
        self.window = window
        IKDI.onboardingFlow.start(with: window)
    }
}
```

**Skill rules around this pattern:**

- DO NOT modify `setupCoreApp()` or `SceneDelegate.scene(_:willConnectTo:)` unless the user explicitly requests adding a new framework phase.
- DO add new `IKDI.onboardingFlow.register(forScreen: .<phase>) { ... }` blocks inside `setupCoreApp()` when the flow needs framework-level phase registration (e.g. adding a paywall phase).
- DO extend `MainRouter` + `MainRoute` for screen-level navigation INSIDE a registered phase — see `references/iknavigation-bridge.md` §5.

---

## §4. Mapping a Figma flow to framework phases

When the skill generates a multi-screen flow (e.g. Splash → Intro1 → Intro2 → Intro3 → Intro9 → IAP → Home), the agent must decide:

**Option A — Single phase, internal nav (preferred for mid-app flows):**
Register one phase (e.g. `.main`) and have all 7 screens reachable via `MainRoute` cases. Internal navigation goes through IKNavigation. Suitable when the flow is self-contained and the framework's other phases aren't involved.

**Option B — Multiple phases (when matches framework's existing semantics):**
Map screens to existing framework phases:
- Splash → `.splash` (framework-owned phase, framework auto-renders)
- Intro1, Intro2, Intro3, Intro9 → `.onboarding` (single phase, internal nav between intros)
- IAP → `.iap` (framework-owned, transitions to `.main` on success)
- Home → `.main`

Option B is the "correct" architectural fit for an onboarding+IAP+main flow because the framework already has lifecycle semantics for these phases (e.g. `.iap` is shown only on first launch / when subscription expires). But it requires the framework's phase enum to actually expose these cases.

**Decision rule:**

- C1 inspects `onboardingFlowScreens` capture. If `.splash`, `.onboarding`, `.iap`, `.main` ALL exist → use Option B.
- Otherwise → Option A. Register a single `.main` phase; all 7 screens behind one `MainRouter`.

When in doubt, default to Option A. Subagents do NOT add new cases to the framework's `OnboardingScreen` enum — that's a framework-owner decision.

---

## §5. Phase registration in the skill's flow workflow

When the flow skill (`figma-flow-to-swiftui-feature`) generates against an Ikame project with `usesIKOnboardingFlow == true`:

1. **Step 4 (Shared scaffolding):** decide Option A vs Option B per §4.
2. **Step 4 — append to `setupCoreApp()`:** for each framework phase the flow registers, add an `IKDI.onboardingFlow.register(forScreen: .<phase>) { ... }` block. Subagents emit DELTA-REQUEST when this requires touching `App/AppDelegate.swift` (which is normally don't-touch).
3. **Step 4 — extend MainRoute:** add new `MainRoute` cases for each screen reachable inside a phase. Each screen registered with `IKNavigation.makeView(router:root:)`.
4. **Step 5 (Per-screen impl):** screens that are framework-phase entries (e.g. SplashScreen) emit `routePublisher.send(.toIntro1)` when ready to advance. The View handles the dispatch to `navigation.push(to: .mainRoute(...))` per `references/iknavigation-bridge.md`.
5. **Step 5 — splash phase advance:** when Splash is the launch phase, advancing OUT of Splash typically goes through framework call (e.g. `IKDI.onboardingFlow.advanceFromSplash()` if the framework exposes such API), NOT a direct push. Subagent must check what the framework expects — the API name varies across IKOnboardingFlow versions.

---

## §6. Banned patterns

| Pattern | Why banned |
|---|---|
| `WindowGroup { ... }` SwiftUI App scene | Conflicts with framework's `IKDI.onboardingFlow.start(with: window)` UIKit-style entry. The framework owns window lifecycle. |
| `@main struct App: App { ... }` SwiftUI App protocol | Same — framework's `@main` AppDelegate is canonical. |
| Inventing a new framework phase by adding a case to `OnboardingScreen` enum | The enum is owned by the IKOnboardingFlow pod; modifying it requires a framework PR upstream. Subagent must NOT patch pod sources. |
| Calling `window.rootViewController = ...` directly | Bypasses the framework. Use `IKDI.onboardingFlow.start(with:)`. |
| Multiple `IKDI.onboardingFlow.start(...)` calls | Framework expects exactly one start call per app launch. |

---

## §7. C8 enforcement (deferred — no dedicated gate)

There is no `c8-ikonboardingflow.sh` gate yet — the patterns are subtle and the framework's API surface varies by version. Soft enforcement happens via:

- `c8-iknavigation.sh` — flags vanilla NavigationStack APIs (which would conflict with the framework's IKNavigation-via-MainRouter pattern).
- Build-time errors when the agent calls a non-existent framework method (e.g. `IKDI.onboardingFlow.unknownMethod()` won't compile).

When the agent emits Swift code touching `IKDI.onboardingFlow.register(forScreen:)`, manual review is recommended before merge.

---

## §8. Failure-mode self-check

Before emitting any code touching App entry / SceneDelegate / framework registration:

1. Did C1 confirm `usesIKOnboardingFlow == true`? If false → use vanilla SwiftUI App / SceneDelegate per swiftui-pro-bridge.
2. Did I check what `OnboardingScreen` enum cases the framework exposes (via C1 capture or grep on Pods/IKOnboardingFlow/)?
3. For each Figma screen in the flow, did I decide Option A (single phase) or Option B (phase-per-section) with explicit rationale?
4. If Option B requires a framework case that doesn't exist → STOP and ask user. Do NOT modify pod sources.
5. Did I emit a delta-request when adding `IKDI.onboardingFlow.register(...)` to `setupCoreApp()` (touching App/AppDelegate.swift, normally don't-touch)?

If any answer is "no" / "unsure", STOP and consult the user. The framework's exact API surface is project-version-specific; better to ask than to emit non-compiling code.
