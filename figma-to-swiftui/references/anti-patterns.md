# Anti-Patterns — failure modes seen in real runs

Concrete failure modes the skill has caught (or failed to catch) in production. Each AP names the agent's internal justification, the rule it violates, and the fix.

Read this when you reach Phase B or Phase C. Read again at end of every run, before declaring done.

---

## AP-1. "Build the rest with SwiftUI shapes / SF Symbols for maintainability"

**Thought:** *"Downloaded the hero illustration and app icon. Other icons (social logos, tab bar, PIN dots, timer ring) are simple — I'll build with `Image(systemName:)` and `Capsule()` to keep the codebase clean."*

**Rule:** [SKILL.md §"ABSOLUTE RULE — Assets come from Figma"](../SKILL.md). Every visible icon/logo/illustration MUST come from Figma. SF Symbols and hand-drawn shapes are banned substitutes.

**Caught by:** `figma-to-swiftui-banned-pattern-gate.sh` (PreToolUse), `figma-to-swiftui-gate.sh` (Phase A/B coverage), `c6-asset-completeness.sh` (Stop).

**Fix:** re-run `figma_export_assets_unified(autoDiscover: true)` for missing icons. Use `Image(.icAI<Name>)` at call site. Missing in Figma → STOP and ask.

---

## AP-2. "Build → screenshot → declare PASS without C5.6"

**Thought:** *"Build succeeded, captured screenshot, screens look great. C5 done."*

**Rule:** [verification-loop.md §C5.6](verification-loop.md). C5.6 is a 6-step procedure with file artifacts: `c5-sections.md`, `c5-visual-diff.md`, per-section crops, free-form pass, 3-axis diff, negative spot-check, 4-anchor proportional, attestation.

**Caught by:** Stop hook verifies `c5-visual-diff.md` structure (6 sections required).

**Fix:** walk the 6-step procedure in order. Don't skip the free-form "what's wrong first" pass — confirmation bias is the #1 reason visual diffs miss obvious differences.

---

## AP-3. "Edit ContentView so the simulator boots into screen X for screenshot"

**Thought:** *"`xcrun simctl io screenshot` only captures what the app shows. I'll change `initialStep` to `.pinSetup`, rebuild, screenshot. Repeat for each screen."*

**Rule:** [verification-loop.md §"C5 Verification Integrity"](verification-loop.md). Launch-arg / env-var route overrides / debug-only deep-link parsers / mutating initial step for verification = **BANNED**. Even gated by `#if DEBUG`, ships a debug entrypoint to TestFlight.

**Caught by:** `figma-to-swiftui-entry-bypass-gate.sh` (PreToolUse) blocks edits to `*ContentView.swift` / `*App.swift` / `*RootView.swift` setting `initialStep`/`currentStep`/`VERIFY_ROUTE` or adding `#if DEBUG` deep-link parsers.

**Allowed paths:** existing `#Preview` / scheme / test target; `ios-simulator-verify` skill; `computer-use` MCP with `request_access`; or set `verification.c5.skipped = "no_entry_path"` and surface to user.

Legitimate flow-state init (not verification bypass) carries `// figma-entry-bypass-gate: legitimate-flow-state` on assignment line.

---

## AP-4. "LSP errors are stale — actual compilation is clean"

**Thought:** *"LSP complains about `Cannot find AppColor in scope` but that's just indexing lag."*

**Rule:** [Key Principle #4](../SKILL.md). MCP output is a spec, not code — same for tooling output. Don't assume; verify against the compiler.

**Verification (Engine A, sub-second):** `mcp__xcode__XcodeRefreshCodeIssuesInFile` on the file. Engine B: `xcodebuild build`.

**Fix:** when LSP complains, verify against the compiler before declaring "stale". The cost is negligible.

---

## AP-5. "Disclosing the bypass in the final summary is enough"

**Thought:** *"Had to flex some non-negotiables. I'll mention it in the summary as 'limitations'."*

**Rule:** [SKILL.md §"Failure-mode self-check"](../SKILL.md). The rule is *STOP and surface BEFORE acting*, not *act first and confess after*. A run ending with "non-negotiables flexed" disclaimer is a **failed run**, not a footnoted success.

**Caught by:** Stop hook refuses termination when C5/C6/C7 unsatisfied. Disclaimer doesn't satisfy any gate — only artifacts on disk do.

**Fix:** when you find yourself drafting a disclaimer, STOP. That's the signal to redo the bypassed step.

---

## AP-6. "I'll just use a banned substitute MCP for this run"

**Thought:** *"User doesn't have MCPFigma. Framelink `figma-developer-mcp` is registered — `mcp__figma__get_figma_data` gives roughly the same data. Just for one run."*

**Rule:** [SKILL.md §"BANNED substitute MCPs"](../SKILL.md). Framelink returns raw REST JSON, not JSX/Tailwind the skill's parsers expect. Every downstream gate loses grounding.

**Fix:** STOP. Install MCPFigma per [`mcpfigma-setup.md`](mcpfigma-setup.md). Do not call the banned tool, not even "to see what's there".

---

## AP-7. "User said 'làm màn này nhanh' — they want speed, not pedantry"

**Thought:** *"User wants speed. I'll skip Phase B, use SF Symbols, skip C5."*

**Rule:** The fidelity-first contract is the value the skill provides. Speed without fidelity is a different product — and the user will catch the divergence on first side-by-side. "Speed" requests do NOT override the absolute rules.

**Fix:** acknowledge urgency, but stay on the rails. The 6-step procedure is fast when the cache is warm — the slowness is in `xcodebuild build` (Engine B) which Engine A bypasses. Use Engine A when available.

---

## AP-8. Text fixed-width truncates localized copy

**Thought:** *"Figma metadata says the text is 200pt wide. I'll add `.frame(width: 200)`."*

**Outcome:** Measured visual width on a hug-mode node. Ships truncation as soon as content grows — localized strings (German, Russian), longer dynamic data.

**Rule:** [visual-fidelity.md §7 Rule #9](visual-fidelity.md). `.frame(width: N)` on Text BANNED unless Figma `primaryAxisSizingMode === FIXED` AND `// Figma fixed-width: <reason>` comment.

**Fix:** read Figma `primaryAxisSizingMode`. AUTO/HUG → no width. FILL → `.frame(maxWidth: .infinity)` + `.lineLimit(1)` + `.minimumScaleFactor(0.6)` if single-line. FIXED → `.frame(width: X).fixedSize(horizontal: false, vertical: true)` with comment.

---

## AP-9. Y from frame origin double-counts safe area

**Thought:** *"Element at y=64 in Figma frame, so `.padding(.top, 64)`."*

**Outcome:** iOS already inserts `safeAreaInsets.top` (≈47-67pt depending on device). Padding 64pt on top of that = 111pt visual gap. Figma showed 17pt below status bar; sim shows 64pt below.

**Rule:** [visual-fidelity.md §7 Rule #12](visual-fidelity.md). When `mockupChrome=true`, screen-root padding requires `// safe-area-adjusted: raw=<N+inset>, inset=<inset>, adjusted=<N>` comment.

**Caught by:** banned-pattern hook flags `.padding(.top, 44|47|59|64|67|79|88)` at screen-root without the safe-area-adjusted comment.

**Fix:** subtract `safeAreaInsets.top` from raw Figma Y. `y=64 - 47 = 17` → `.padding(.top, 17) // safe-area-adjusted: raw=64, inset=47, adjusted=17`.

---

## AP-10. Image fill-width missing `.scaledToFill`

**Thought:** *"Image with `.frame(maxWidth: .infinity, height: 240)` should fill — no need for `.scaledToFill()`."*

**Outcome:** without `.resizable()`, the Image stays at intrinsic size. Without `.scaledToFill()`/`.scaledToFit()`, content mode is ambiguous. Frame reserves 240pt blank space with the image shrunk to its native size.

**Rule:** [visual-fidelity.md §7 Rule #11](visual-fidelity.md). Fill-* Image MUST emit `.resizable() + .scaledToFill()|.scaledToFit() + .frame(...)` — all three.

**Fix:** always emit all three. Default content mode when `objectFit` absent: `.scaledToFill()` (Figma's image-fill default).

---

## AP-11. Phone bezel mistaken for view corner radius

**Thought:** *"Figma frame outline shows ~47pt rounded corners. The screen container has corner radius 47pt."*

**Outcome:** the iPhone hardware clips outer corners for free. App-applied `.cornerRadius(47)` on screen-root produces a visible "double bezel" gutter on device.

**Rule:** [visual-fidelity.md §7 Rule #13](visual-fidelity.md). `.cornerRadius` / `.clipShape(.rect(cornerRadius:))` / `.clipShape(RoundedRectangle(cornerRadius:))` ≥ 30pt at screen-root BANNED without `// allow-screen-corner-radius: <reason>` comment.

**Caught by:** banned-pattern hook flags ≥30pt corner radius at screen-root.

**Fix:** delete the modifier. Hardware does the curve. `R ≥ 30` is only legitimate on presented sheets / inner cards with Figma-specified inner-card radius.

---

## AP-12. Button bloated by inner Text maxWidth

**Thought:** *"Text inside button reads left-aligned. Add `.frame(maxWidth: .infinity)` to the Text."*

**Outcome:** SwiftUI propagates fill-width requests outward. The Text's maxWidth cascades up through the Button. Caller's `.padding(.horizontal, 16)` is overridden. Figma showed 343pt button; sim shows 393pt edge-to-edge.

**Rule:** [visual-fidelity.md §7 Rule #14](visual-fidelity.md). `.frame(maxWidth: .infinity)` belongs on OUTERMOST view of bounded container — NEVER on inner Text inside Button without `// allow-text-fill: <reason>`.

**Caught by:** banned-pattern hook flags `Text(...).frame(maxWidth: .infinity)` inside `Button { ... }` body.

**Fix:** by Figma `primaryAxisSizingMode` on Button: FILL → `Button { ... }.frame(maxWidth: .infinity)` on outer; FIXED → `.frame(width: N)` on outer; AUTO/HUG → no width modifier. Inner Text stays intrinsic.

---

## AP-13. Template-from-doc (multi-screen flows)

**Thought:** *"Doc lists 30 screens with similar structure. I'll build a generic `OnboardingStepView`, feed strings from the doc, skip per-screen `get_design_context`."*

**Outcome:** generic template doesn't capture per-screen variations (different option counts, special states, copy nuances Figma defines). All 30 screens render but none matches Figma.

**Rule:** [mcpfigma-setup.md §"Registry-empty cases"](mcpfigma-setup.md). Each screen needs its own Phase A artifact (per-screen `get_design_context`). The flow skill must reject templates built from doc wording.

**Caught by:** `figma-to-swiftui-gate.sh` blocks Swift writes when `manifest.phaseA != "done"` for any cached screen.

**Fix:** iterate `figma_build_registry.screens[]` (or `candidateScreens[]` per fallback), fetch per-screen Phase A in parallel batches of 3 (per `fetch-strategy.md`).

---

## AP-14. SwiftUI Color built-in shadowing in colorsets

**Thought:** *"Style guide tokens are `primary`, `secondary`, `accent` — I'll emit colorsets with those names."*

**Outcome:** every build emits 2 warnings: *"The 'primary' color asset name resolves to a conflicting Color symbol. Try renaming."* Code using `Color("primary")` silently picks SwiftUI's `Color.primary` (system label color), NOT your colorset.

**Banned colorset names** (lowercase exact match): `primary`, `secondary`, `accent`, `red`, `green`, `blue`, `gray`, `orange`, `pink`, `purple`, `yellow`, `black`, `white`, `clear`, `indigo`, `mint`, `teal`, `cyan`, `brown`.

**Fix:** prefix with `app` (or project namespace): `Color(.appPrimary)` from `appPrimary.colorset`. `b0b-tokens-codegen.sh` auto-prefixes conflicting names.

---

## AP-15. Silent system-font fallback

**Thought:** *"`Font.custom("Inter-Medium", size: 17)` will work — the family is in tokens."*

**Outcome:** iOS silently falls back to system font. No build error, no runtime warning. Typography close but not exactly matching Figma. Easy to dismiss as "minor sub-pixel difference".

**Root cause:** `.otf`/`.ttf` not in `Resources/Fonts/` AND/OR not listed in Info.plist `UIAppFonts`.

**Rule:** [fonts-styling-bridge.md §7](fonts-styling-bridge.md). Every `Font.custom("X")` call needs matching file in bundle + entry in `UIAppFonts`.

**Manual check before C5:**
```bash
grep -rE 'Font\.custom\("[^"]+"' --include="*.swift" .
plutil -p <project>/Info.plist | grep -A 100 UIAppFonts
```

For Ikame: `IKFontSystem.shared.configure(familyName:)` at app boot registers the main family. Additional families need their files in `UIAppFonts` separately.

**Fix:** STOP, tell user: *"Font `<Family>` in Figma but not in `UIAppFonts`. Add the .otf to `Resources/Fonts/` and `<filename>.otf` to Info.plist UIAppFonts, OR change the Figma token to the project's main family."*

---

## AP-16. Content overflows safe area

**Thought:** *"Root view fills the screen. I'll add `.ignoresSafeArea()` to the ScrollView so the background goes edge-to-edge. Or `.frame(maxHeight: .infinity)` so the VStack stretches."*

**Outcome:** on a real device, the top portion of content (header text, first list row) sits **under** the status bar / Dynamic Island. Bottom CTAs sit under the home indicator. On simulator Pro / 16 Pro frame this is most obvious — the title overlaps the time pill, the button you tap-target gets clipped by the indicator bar. iOS render order is system chrome ON TOP of view; `.ignoresSafeArea` removes the inset, but iOS still draws chrome where it always does.

**Root cause:** the rule *"only background may extend under chrome — content respects safe area"* never made it from the figma-to-swiftui spec docs into a gate. Layout-translation.md and visual-fidelity.md both state it; nothing was checking compliance until c3-safearea-gate.sh.

**Rule:** [layout-translation.md §"Safe Area Normalization"](layout-translation.md) + [visual-fidelity.md §3](visual-fidelity.md) + SKILL.md C2.

- `.ignoresSafeArea(edges: ...)` ONLY on visual background primitives: `Color`, `Image`, `Rectangle`, `RoundedRectangle`, `Capsule`, `Ellipse`, `Circle`, `LinearGradient`, `RadialGradient`, `AngularGradient`, `EllipticalGradient`, `MeshGradient`.
- NEVER on a content container (`VStack`, `HStack`, `ZStack`, `ScrollView`, `List`, `Form`, `LazyVStack`, `NavigationStack`, `TabView`). If you need a full-bleed background, put the `Color/Image/Gradient` BEHIND the content (ZStack with background as first child) and apply `.ignoresSafeArea` to **that primitive only**.
- Sticky bottom CTA (button bar at `y >= frame.height - 120` in Figma) → wrap with `.safeAreaInset(edge: .bottom) { ... }` on the screen-root container. Don't pad-by-34pt to "make room for home indicator" — iOS already pushes content up.
- `.frame(maxHeight: .infinity)` at screen root WITHOUT a `.ignoresSafeArea` / `.safeAreaInset` companion → content will bleed. If genuinely intentional, comment `// allow-fullbleed-noinset: <reason>` on the `.frame` line.

**Caught by:** `c3-safearea-gate.sh` (run via `c3-driver.sh safearea` or `aggregate`) — emits `c3-safearea.json`. Codes:
- `SA-1` (FAIL): `.ignoresSafeArea` on content container or `safeAreaPadding` mis-targeted.
- `SA-1?` (FAIL — escalated, was WARN): `.ignoresSafeArea` whose target the audit could not trace from the chain, or whose target is an unrecognized custom view. Default FAIL because ambiguous targets are exactly the failure mode this rule guards against. **Bypass**: add `// safearea-target-confirmed: <Color|Image|Gradient|Rectangle|...>` on the SAME line when you have manually verified the target is a background primitive; the gate downgrades to WARN. Requires `--src-root` flag on the gate so it can read source lines (driver auto-passes when invoked correctly).
- `SA-2` (FAIL): root `.frame(maxHeight: .infinity)` with zero safearea rows in the file.
- `SA-3` (WARN): `.safeAreaInset` on a background primitive (likely belongs on container).

**Fix recipe (full-bleed hero):**
```swift
ZStack(alignment: .top) {
    Color(.appBackground)                       // ← background extends
        .ignoresSafeArea(edges: .top)           // ← only background ignores
    VStack(spacing: 24) {                       // ← content respects safe area
        Image(.imageAIHero32x32)
        Text("Welcome back")
            .ikFont(.title)
    }
    .padding(.top, 24)                          // measured from safeAreaTop, NOT frame top
}
.safeAreaInset(edge: .bottom) {                 // sticky CTA — attaches to root
    Button("Continue") { vm.send(.continueTap) }
        .ikFont(.bodySemi)
        .padding(.horizontal, 16)
}
```

**Fix recipe (full-bleed scroll with header):**
```swift
ScrollView {
    VStack(spacing: 0) {
        Image(.imageAIHero)                     // bleeds visually because it's the FIRST child
            .resizable()
            .scaledToFill()
            .frame(height: 280)
        contentBody
            .padding(.horizontal, 16)
    }
}
.background(
    Color(.appBackground)
        .ignoresSafeArea(edges: .top)           // ← background under the scroll, not the scroll itself
)
```

---

## AP-17. NavigationStack with no nav-bar visibility — system bar pushes content 44pt down

**Thought:** *"Every screen lives in a NavigationStack so push transitions work. Just `NavigationStack { ScreenContent() }` and let SwiftUI handle the rest."*

**Outcome:** when Figma shows a **custom top bar** (the common pattern — `X` close + title + settings icon, or a custom header row), the system nav bar **still renders 44pt of empty chrome above the content**. The user-visible result: the Figma custom header sits where the title-area should be on iOS — instead it's pushed down 44pt and the system nav bar zone is empty. From the user's perspective, "UI tràn ra ngoài safe area" — content overlap, screen visibly different from Figma.

**Why this happens:** SwiftUI's `NavigationStack` defaults to **visible** nav bar with auto title/back button. There is no "show nav bar only when needed" mode — it's on until you explicitly hide it.

**Root cause:** the rule *"if Figma top zone is a custom header, hide the system nav bar"* never made it from layout-translation.md into an executable gate. Most agents reach for `NavigationStack` by reflex (push navigation is real, navigation links exist) without checking the Figma top zone.

**Rule:** SKILL.md C2 + [layout-translation.md §"Safe Area Normalization"](layout-translation.md).

- Figma's top zone is **status bar mockup + custom header row** (X / title / icon) → MUST add `.toolbar(.hidden, for: .navigationBar)` to the root content inside `NavigationStack`. The status bar is system-rendered, but the system nav bar (chevron + title) is NOT in Figma — kill it.
- Figma's top zone is **status bar mockup + iOS-style nav bar with a centered title and back chevron** → keep the system nav bar; use `.navigationTitle("…")` + `.navigationBarTitleDisplayMode(.inline)`. This is the rarer case.
- Screen is part of a flow that uses `NavigationStack` at a parent level → **don't wrap THIS screen in NavigationStack at all**. Nested NavigationStacks confuse routing and add extra nav bars.
- Modal sheet / fullScreenCover content with its own NavigationStack → same rule. Add `.toolbar(.hidden, for: .navigationBar)` when Figma shows a custom dismiss/title row.

**Caught by:** `c3-safearea-gate.sh` NB-1 (in `c3-driver.sh safearea` / `aggregate`). **FAIL** for `*Screen.swift` files using `NavigationStack`/`NavigationView` without any `.toolbar(.hidden, ...)` / `.navigationTitle(...)` / `.toolbarVisibility(...)` / `.navigationBarHidden(...)`. **WARN** for non-Screen files (App.swift / RouterView.swift at the app root legitimately holds the NavigationStack with no toolbar — child views own that).

**Fix recipe (custom top bar, no system nav bar):**
```swift
struct ProfileScreen: View {
    var body: some View {
        NavigationStack {                            // routing capability preserved
            VStack(spacing: 0) {
                customTopBar                          // Figma's X / title / settings row
                Spacer(minLength: 16)
                ScrollView { profileBody }
            }
            .toolbar(.hidden, for: .navigationBar)   // ← kill the system 44pt bar
        }
    }
}
```

**Fix recipe (system nav bar with title — rarer):**
```swift
struct DetailScreen: View {
    var body: some View {
        NavigationStack {
            ScrollView { detailBody }
                .navigationTitle("Details")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
```

**Fix recipe (screen pushed by a parent's NavigationStack):**
```swift
// Parent (RouterView.swift) — holds the NavigationStack
struct RouterView: View {
    var body: some View {
        NavigationStack {
            HomeScreen()
                .navigationDestination(for: Route.self) { route in
                    switch route { ... }
                }
        }
    }
}

// Child — does NOT wrap in another NavigationStack
struct ProfileScreen: View {
    var body: some View {
        VStack(spacing: 0) { customTopBar; bodyContent }
            .toolbar(.hidden, for: .navigationBar)   // still hide, since parent's
                                                      // NavigationStack would show
                                                      // a default bar here too
    }
}
```

---

## Escape hatches (when an enforcement hook is wrong for your case)

Every hook ships with opt-out paths so legitimate edge cases don't get blocked. Use sparingly — each defeats a rule that exists for a reason. Always include the explanation comment.

| Hook | Trigger | Escape | When |
|---|---|---|---|
| `gate.sh` (Phase A/B coverage) | Block `.swift` Write when cache incomplete | Path contains `_NoFigma_` (`App/_NoFigma_/NetworkClient.swift`) | Non-UI scaffolding unrelated to Figma. Never for view code. |
| `banned-pattern-gate.sh` | `Image(systemName:)` outside allow-list | `// allow-systemName: <reason>` on same/prev line | iOS-system glyph (ShareLink, search clear). Never for Figma-designed icon. |
| same | Text fill-width inside Button | `// allow-text-fill: <reason>` | Rare. Better: move maxWidth to outer container. |
| same | `.frame(width:)` on Text | `// Figma fixed-width: <reason>` | Figma `primaryAxisSizingMode === FIXED`. |
| same | Screen-root `.padding(.top, 44/47/59/64/67/79/88)` | `// safe-area-adjusted: raw=<y>, inset=<n>, adjusted=<y-n>` | Math is correct (not double-count). |
| same | Screen-root cornerRadius ≥ 30pt | `// allow-screen-corner-radius: <reason>` | Presented sheet/inner card with Figma-specified radius. NEVER on screen root. |
| `entry-bypass-gate.sh` | `initialStep`/`VERIFY_ROUTE`/`#if DEBUG` deep-link in App/Root/ContentView | `// figma-entry-bypass-gate: legitimate-flow-state` on assignment line | Real flow state init, not verification jump. |
| `c3-safearea-gate.sh` | Root `.frame(maxHeight: .infinity)` w/o `.ignoresSafeArea`/`.safeAreaInset` | `// allow-fullbleed-noinset: <reason>` on `.frame` line | Genuine intentional full-bleed without safe-area handling. Almost never correct — re-read AP-16 first. |
| `c3-safearea-gate.sh` SA-1? | `.ignoresSafeArea` with target the audit couldn't trace from the chain | `// safearea-target-confirmed: <Color\|Image\|Gradient\|...>` on `.ignoresSafeArea` line | Target IS a background primitive but chain shape (wrapped in custom view, conditional, multi-line) hid that from the audit. Manually verify FIRST. |
| `c3-safearea-gate.sh` NB-1 | `*Screen.swift` wraps content in NavigationStack/View w/o `.toolbar(.hidden, ...)`/`.navigationTitle(...)`/`.toolbarVisibility(...)` | `// nav-bar-intentional: <reason>` on NavigationStack line | Screen genuinely uses the iOS system nav bar with title + back chevron. Re-read AP-17 first — when Figma shows a custom header, this is NEVER the right answer. |
| `c3-fills-coverage.sh` | `fills.json` has IMAGE / GRADIENT / stacked nodes but emitted source has no matching `Image()` / `LinearGradient(`/`RadialGradient(`/... | `// allow-no-bg-emit: <reason>` on `var body` line of the screen file | Design intentionally swapped Figma background for solid color AND `fills.json` is stale. Prefer re-running `figma_extract_fills` to regenerate `fills.json` over using this bypass. |
| `c3-fills-coverage.sh` FC-4 | `fills.json` IMAGE node has no `manifest.rows[]` entry (exporter pipeline missed it) | `// allow-no-bg-emit: <reason>` on `var body` (same marker as FC-1/2/3) | Same as above — design intentionally dropped the background. Prefer re-running `figma_export_assets_unified(autoDiscover: true)` or adding a fallback row to `manifest.rows[]` over using the bypass. |
| `stop-gate.sh` | C5/C6/C7 fail | `manifest.verification.c5.skipped` set to `no_project`/`simctl_error`/`ci_environment`/`no_entry_path` (auto-detected) | Genuine system reason. Never set manually. |

**Comment-form rules:**
- Same line as modifier OR line directly above (no further — hook grep window is `lineno` and `lineno - 1`).
- Real reason in tail. `// allow-systemName: needed` is not enough — write `// allow-systemName: ShareLink default icon`.

**Path-form rule:** `_NoFigma_` requires literal underscores. `MyNoFigmaView.swift` does NOT match. Preferred: path component `<Target>/_NoFigma_/Network/Client.swift`.

**STOP-line:** the moment an escape hatch becomes your default tool, you've drifted into the failure mode the hook exists to prevent. Re-read the corresponding AP and fix the real cause instead.

---

## Failure-mode self-check (read at end of every run)

Before writing Verification summary, scan your draft for these phrases. Any hit = you have NOT finished the run:

- "for maintainability" / "to keep it simple" / "để dễ maintain"
- "the user won't notice" / "close enough" / "good enough for now"
- "approximately" / "roughly" / "near match" / "minor difference"
- "non-negotiables flexed" / "had to compromise"
- "LSP is stale, actual compile is fine" — without running `mcp__xcode__XcodeRefreshCodeIssuesInFile` or `xcodebuild build`
- "bypassed C5 entry path by editing X" / "added an init override for verification"
- "used SwiftUI shapes for ..." — for icons / logos / illustrations
- "skipped Phase B for these icons because they're simple"
- "downloaded the major assets, built minor ones in code"
- "the Text is 200pt wide in Figma so I added `.frame(width: 200)`" — see AP-8
- "y=64 in the frame so `.padding(.top, 64)`" — see AP-9
- "frame is enough, no need for `.scaledToFill`" — see AP-10
- "the screen has rounded corners in Figma so I added `.cornerRadius(47)` to the root" — see AP-11
- "centered text needs `.frame(maxWidth: .infinity)` so I added it on the Text inside the button" — see AP-12
- "I put `.ignoresSafeArea()` on the ScrollView so the background extends edge-to-edge" — see AP-16
- "root VStack with `.frame(maxHeight: .infinity)`, no inset, should be fine" — see AP-16
- "wrapped every screen in NavigationStack so push transitions work" — see AP-17
- "the empty bar at the top is fine, user won't notice" — see AP-17 (it's 44pt of wrong)
- "skipped the Figma background image — design context didn't show it / screenshot was ambiguous" — see [fills-handling.md](fills-handling.md). `fills.json` is the canonical source; if the agent didn't read it, that's the bug. `c3-fills-coverage.sh` FC-1 catches this.
- "design used a solid color, so I ignored fills.json" — fills.json filters SOLID-100%; if the node IS in fills.json it has a NON-trivial paint. Re-read fills-handling.md Recipe 1/2/3.
- "applied `.ignoresSafeArea` on the whole ZStack, content is fine" — content is NOT fine. ZStack is a content container per SA-1. Move `.ignoresSafeArea` onto the background primitive child only.

These are the exact phrases the skill exists to make impossible. If your summary contains any, STOP. Re-do the bypassed step. Then write the real summary.
