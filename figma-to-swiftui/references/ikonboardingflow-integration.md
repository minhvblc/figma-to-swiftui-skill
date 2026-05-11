# IKOnboardingFlow Integration — Registration Patterns

**Why this exists:** the Bible Widgets session registered `.intro` with `IKDI.onboardingFlow.register(forScreen: .intro) { IKNavigation.makeView(router: IntroRouter(), root: .source) }` — a pattern that **looks** right but breaks the framework's flow handoff. The framework rendered nothing for that slot until we switched to a single root View orchestrator (authenv2 pattern).

## §1. The four slots IKOnboardingFlow understands

```swift
public enum IKOFScreen: Sendable, Equatable, Hashable {
    case splash         // app launch logo
    case intro          // onboarding questions / steps
    case introIap       // paywall after intro
    case main           // post-onboarding app entry
    case custom(UUID)
}
```

The framework cycles in order: `.splash → .intro (first launch only) → .introIap (free users only) → .main`.

Default registrations exist for all four (yellow placeholders for splash/intro/introIap, EmptyView for main). Real apps register their views with `IKDI.onboardingFlow.register(forScreen:, registration:)`.

## §2. The shape difference that bit Bible Widgets

Each slot expects a SwiftUI View, but the SHAPE of the view differs by slot.

### For `.main`

`IKNavigation.makeView(router:, root:)` is the canonical Ikame entry point. The view is wrapped in IKNavigation's `UINavigationController` analogue and handles deep navigation correctly.

```swift
IKDI.onboardingFlow.register(forScreen: .main) {
    IKNavigation.makeView(router: MainRouter(), root: .mainRoute(.main))
}
```

### For `.intro` / `.splash` / `.introIap`

These slots use IKOnboardingFlow's own transition + finish-promise mechanism. The registered view is wrapped in `IKOFHostingController` (NOT `IKNavigation`). The wrapper provides:

- `\.ikOFDismiss` environment value — the view calls this when finishing to hand off to the next slot
- `finishPromise` mechanism — observes when the view's lifecycle ends to advance the flow

If you wrap with `IKNavigation.makeView(router:, root:)`, you get TWO nested navigation/lifecycle hosts, and the inner one's pushes don't propagate `\.ikOFDismiss` correctly. The framework can't tell when your flow finishes, so the chain breaks.

**Correct shape for `.intro`:**

```swift
IKDI.onboardingFlow.register(forScreen: .intro) {
    MyOnboardingFlow()    // single SwiftUI View
}
```

`MyOnboardingFlow` is a struct conforming to `View` with:
- Internal state machine over sub-screens (an enum + `@State currentStep`)
- `@Environment(\.ikOFDismiss)` to call when at the end
- Provides `\.onboardingNextStep` env to children so they can ask to advance

## §3. Canonical orchestrator pattern (from authenv2)

```swift
struct MyOnboardingFlow: View {
    @State private var currentStepIndex: Int = 0
    @State private var currentType: MyStepType = .first
    @State private var steps: [MyStepType] = []
    @Environment(\.ikOFDismiss) private var dismissOnboardingFlow

    var body: some View {
        ZStack {
            screenView(for: currentType)
                .transition(.asymmetric(insertion: .move(edge: .trailing),
                                        removal: .move(edge: .leading)))
        }
        .animation(.easeInOut(duration: 0.25), value: currentType)
        .environment(\.onboardingNextStep) { advance() }
        .onAppear {
            if steps.isEmpty { steps = MyStepType.allCases }
            currentStepIndex = 0
            currentType = steps.first ?? .first
        }
    }

    private func advance() {
        if currentStepIndex + 1 > steps.count - 1 {
            dismissOnboardingFlow(IKOFNavigationBehavior.crossDissolveAnimation)
            return
        }
        currentStepIndex += 1
        currentType = steps[currentStepIndex]
    }

    @ViewBuilder
    private func screenView(for type: MyStepType) -> some View {
        switch type {
        case .first:  FirstScreen()
        case .second: SecondScreen()
        // ... one case per step
        }
    }
}
```

Companion env-key file (one-time-per-app):

```swift
struct OnboardingNextStepKey: EnvironmentKey {
    static let defaultValue: (@MainActor @Sendable () -> Void) = { }
}

extension EnvironmentValues {
    public var onboardingNextStep: (@MainActor @Sendable () -> Void) {
        get { self[OnboardingNextStepKey.self] }
        set { self[OnboardingNextStepKey.self] = newValue }
    }
}
```

Children advance by:

```swift
struct FirstScreen: View {
    @Environment(\.onboardingNextStep) private var onboardingNextStep
    var body: some View {
        Button("Continue") { onboardingNextStep() }
    }
}
```

## §4. `didShowIntro` UserDefaults — automatic

After the framework completes a successful `.intro` slot run, `UserDefaults.standard.didShowIntro` is set to `true` automatically (by IKOnboardingFlow internals — see `Pods/IKOnboardingFlow/IKOnboardingFlow/Sources/IKOnboardingFlow.swift` line 56-58). On next launch, the `.intro` slot is skipped and the flow goes `.splash → .introIap → .main`. No manual UserDefaults manipulation needed.

## §5. Banned patterns

- `IKDI.onboardingFlow.register(forScreen: .intro) { IKNavigation.makeView(router:, root:) }` — wrong wrapper, breaks ikOFDismiss
- `IKDI.onboardingFlow.register(forScreen: .splash) { IKNavigation.makeView(...) }` — same issue
- Setting `UserDefaults.standard.didShowIntro = true` manually to skip onboarding for dev — use `IKDI.onboardingFlow.configure(steps: [.main])` instead, which is the framework-sanctioned bypass
- Bypassing `IKDI.onboardingFlow.start(with: window)` in SceneDelegate to set your own `window.rootViewController` — fights the framework's lifecycle. Use `configure(steps:)` to control which slots run

## §6. Write-time enforcement

`scripts/hooks/figma-to-swiftui-ikonboarding-pattern-gate.sh` is a PostToolUse hook on `Edit`/`Write`/`MultiEdit` of `AppDelegate.swift` and `*OnboardingFlow*.swift` files. It regex-matches the banned pattern and blocks the write with a link back to this doc.

## §7. Related

- `figma-to-swiftui/references/ikonboardingflow-bridge.md` — older / generic IKOnboardingFlow bridge doc
- `scripts/hooks/figma-to-swiftui-ikonboarding-pattern-gate.sh`
- `figma-to-swiftui/references/anti-patterns.md` AP-16
- authenv2 reference: `Authenticator/Screens/Onboarding/OnboardingFlow.swift`
- Bible Widgets fix: `BibleWidgets/BibleWidgets/Screens/Onboarding/BibleOnboardingFlow.swift`
