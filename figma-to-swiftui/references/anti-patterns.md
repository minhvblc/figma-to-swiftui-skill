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

These are the exact phrases the skill exists to make impossible. If your summary contains any, STOP. Re-do the bypassed step. Then write the real summary.
