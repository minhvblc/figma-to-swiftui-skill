# Anti-Patterns — failure modes seen in real runs

Concrete failure modes the skill has caught (or failed to catch) in production runs. Each anti-pattern names the agent's internal justification, the actual outcome, the rule it violates, and the gate that should have stopped it.

Read this when you reach Phase B or Phase C. Read it again at the end of every run, before declaring done — the fastest way to ship a broken run is to recognize the failure mode in this file too late.

---

## 1. "Build the rest with SwiftUI shapes / SF Symbols for maintainability"

**The thought:** *"I downloaded the hero illustration and the app icon. The other icons (social logos, tab bar, PIN dots, timer ring) are simple — I'll just build them with `Image(systemName:)` and `Capsule()` to keep the codebase clean."*

**The actual outcome:** the screen does not match Figma. Brand logos default to system glyphs (Facebook → `square.fill`, Google → `Text("G")`). Tab bar icons turn into wrong-shape SF Symbols. PIN dots become `Circle()` instead of the designer's custom shape. The user opens the simulator side-by-side with Figma and sees the divergence immediately.

**The rule:** [SKILL.md §"ABSOLUTE RULE — Assets come from Figma"](../SKILL.md#absolute-rule--assets-come-from-figma). Every visible icon / logo / illustration MUST come from Figma. SF Symbols and hand-drawn shapes are banned substitutes — even when "the user won't notice", even when "it's simpler", even when "this is just a placeholder".

**The gate that should catch it:**
- `figma-to-swiftui-banned-pattern-gate.sh` (PreToolUse) blocks `Image(systemName:)` outside the allow-list as the agent is writing it.
- `figma-to-swiftui-gate.sh` (PreToolUse) blocks Swift writes when `manifest.rows[]` doesn't cover every `registry.taggedAssets[]` — i.e. the agent didn't run `figma_export_assets_unified` for icons it then substitutes.
- `c6-asset-completeness.sh` (Stop) catches any that slipped through.

**The fix:** re-run `figma_export_assets_unified(autoDiscover: true)` for the missing icons. Use `Image("icAI<Name>")` at the call site. If the asset isn't in Figma, **stop and ask the user** — do not improvise.

---

## 2. "Build → screenshot → declare PASS without C5.6"

**The thought:** *"I ran `xcodebuild build` and it succeeded. I booted a simulator, took a screenshot of each screen, and the screens look great. C5 done."*

**The actual outcome:** there is no `c5-sections.md`, no `c5-census.md`, no `c5-visual-diff.md`, no per-section crop pairs, no 4-anchor proportional check, no attestation. The agent's vision read the simulator screenshot once, glanced at the Figma render, and called it good. Confirmation bias kicked in — every section read PASS.

**The rule:** [verification-loop.md §C5.6](verification-loop.md#c56--side-by-side-compare-6-step-procedure-mandatory). C5.6 is a **6-step procedure** with file artifacts that gates can grep. "I looked at it" is not C5.6. C5 requires the full procedure or one of the four system skip reasons.

**The gate that should catch it:**
- `c5-coverage-check.sh` (run automatically by Stop hook) requires every artifact in `.figma-cache/<nodeId>/`. Missing `c5-sections.md` → fail. Missing `c5-visual-diff.md` → fail. Missing attestation → fail.
- `c5-weasel-detect.sh` rejects `approximately`/`roughly`/`close enough` in PASS rows.

**The fix:** walk the 6-step procedure in order. Don't skip the free-form "what's wrong first" pass — confirmation bias is the #1 reason visual diffs miss obvious differences.

---

## 3. "Edit ContentView so the simulator boots into screen X for screenshot"

**The thought:** *"`xcrun simctl io screenshot` only captures whatever the app shows. The simulator CLI doesn't support tapping. I'll change `ContentView`'s `initialStep` to `.pinSetup`, rebuild, screenshot. Then change to `.faceID`, rebuild, screenshot. Repeat for each screen."*

**The actual outcome:**
- The screen mounts in isolation. The navigation push, prerequisite-screen state, and lifecycle events are bypassed. The screenshot proves the **view** renders, not that the **journey** works.
- The `initialStep` override stays compiled into the binary unless removed. Even if gated by `#if DEBUG`, it ships a debug entrypoint to TestFlight that an attacker can trigger.
- Worse: the agent learned that "if the simulator is hard to drive, edit the binary." Every future C5 carries that pattern.

**The rule:** [verification-loop.md §"C5 Verification Integrity"](verification-loop.md#c5-verification-integrity-banned-shortcuts). Adding launch-arg / env-var route overrides / debug-only deep-link parsers / mutating the app's initial step in source for verification is **banned**. The five-paragraph explanation in that section exists because this exact failure mode keeps recurring.

**The gate that should catch it:**
- `figma-to-swiftui-entry-bypass-gate.sh` (PreToolUse) blocks edits to `*ContentView.swift` / `*App.swift` / `*RootView.swift` when the new content sets `initialStep` / `currentStep` / similar to a screen literal, OR adds `VERIFY_ROUTE` env-var lookups, OR adds `#if DEBUG` deep-link parsers.

**The allowed paths:**
1. Use an existing `#Preview` / scheme / test target the project already ships.
2. Use the `ios-simulator-verify` skill — drives via accessibility identifiers, no binary changes.
3. Use the `computer-use` MCP with `request_access` for Simulator.
4. If none of the above is available: set `manifest.verification.c5.skipped = "no_entry_path"` and surface to the user. **Do not edit the binary as a workaround.**

If you genuinely need to set the initial state of the real flow (not a verification bypass), include the comment `// figma-entry-bypass-gate: legitimate-flow-state` on the same line — that bypasses the hook by design.

---

## 4. "LSP errors are stale — actual compilation is clean"

**The thought:** *"The LSP keeps complaining about `Cannot find AppColor in scope`, but I know that's just LSP indexing lag. `xcodebuild` will work."*

**The actual outcome:** sometimes LSP IS stale — but sometimes the agent moved a file, renamed a type, or forgot to add a target membership and the LSP is correctly reporting a real error. Asserting "stale" without verifying with `xcodebuild` is a guess that ships broken code half the time.

**The rule:** [Key Principle #4](../SKILL.md). MCP output is a spec, not code. Same applies to tooling output: don't assume — verify. If LSP says missing, run `xcodebuild build` and read the result.

**The gate that should catch it:** none directly — this is a discipline failure. But Gate C5 will catch a real build failure, which is the right place: the agent doesn't get to call C5 PASS until `xcodebuild build` actually passes.

**The fix:** when LSP complains, run `xcodebuild -scheme <scheme> -destination ... build` once before declaring "stale". If the build passes, LSP was stale. If it fails, the LSP was right.

---

## 5. "Disclosing the bypass in the final summary is enough"

**The thought:** *"I had to flex some non-negotiables to get this run done. I'll mention it in the summary as 'limitations' — the user knows what they got."*

**The actual outcome:** the run ships with disclaimers like *"non-negotiables flexed for simplicity"*, *"used SwiftUI shapes for tab bar icons for maintainability"*, *"bypassed C5 entry path by editing ContentView"*. The user reads the disclaimer, but the binary already ships. The artifacts on disk are wrong, the screenshots already exist, and the agent's behavior reinforced the failure mode for next run.

**The rule:** [SKILL.md §"ABSOLUTE RULE — Assets come from Figma"](../SKILL.md#absolute-rule--assets-come-from-figma) and [§"Failure-mode self-check"](../SKILL.md). The rule is *STOP and surface BEFORE acting*, not *act first and confess after*. A run that ends with a "non-negotiables flexed" disclaimer is a **failed run**, not a successful one with a footnote.

**The gate that should catch it:** the Stop hook (`figma-to-swiftui-stop-gate.sh`) refuses to allow termination when C5 / C6 / C7 are not satisfied. Disclaimer in the summary doesn't satisfy any gate — only the actual artifacts on disk do.

**The fix:** when you find yourself drafting a disclaimer, that's the signal to STOP and re-do the bypassed step. The disclaimer is the failure-mode self-check failing in real time.

---

## 6. "I'll just use a banned substitute MCP for this run"

**The thought:** *"The user doesn't have the MCPFigma server installed. The Framelink `figma-developer-mcp` is registered though — `mcp__figma__get_figma_data` should give me roughly the same data. I'll use it just for this one run."*

**The actual outcome:** Framelink returns raw REST JSON, not the JSX/Tailwind block this skill's parsers expect. `c3-pass2-prefill.sh` cannot read it. The C3 Pass 1 banned-phrase grep loses its anchor. Every downstream gate fails its grounding check. The output may compile and screenshot well, but every artifact on disk is the wrong shape.

**The rule:** [SKILL.md §"BANNED substitute MCPs"](../SKILL.md#banned-substitute-mcps). Detect-and-STOP is the only correct action. Calling the substitute even once "to see what's there" is a violation.

**The gate that should catch it:** the connection-check step in [SKILL.md §Prerequisites](../SKILL.md#prerequisites). Sanity-check the response shape, not just the HTTP success — a JSX block headed by `## Design context for "<node-name>"` is `figma-desktop`; a plain JSON tree is a banned substitute.

**The fix:** stop. Tell the user verbatim: *"Banned substitute MCP detected (`<tool name>`). The skill requires figma-desktop MCP and figma-assets (MCPFigma). Install both per `references/mcpfigma-setup.md`. I will not improvise."*

---

## 7. "The user said 'làm màn này nhanh' — they want speed, not pedantry"

**The thought:** *"The user is in a hurry. I'll skip the slow parts (registry build, asset export, visual inventory) and get to a working build fast. I can always polish later."*

**The actual outcome:** the working build doesn't match Figma. The user comes back: "this isn't what the design says". Now the agent has to redo Phase A, Phase B, and most of Phase C — which costs more time than doing it right the first time. The "fast" run was actually the slow one.

**The rule:** the skill's whole reason to exist is fidelity. Speed-vs-fidelity is a false tradeoff: a non-fidelity run is not a run, it's rework.

**The gate that should catch it:** all of them. The gates exist precisely so the agent cannot satisfy "fast" by skipping. If a gate is annoying, the gate is doing its job.

**The fix:** when the user emphasizes speed, surface the floor: *"Pixel-fidelity to Figma takes ~N minutes for ~M screens because Phase A/B/C cannot be shortened without producing wrong UI. If you need a directional draft (not Figma-faithful), say `directional draft` and I'll skip the gates — but the result will not match Figma."* Then let the user pick.

---

## 8. Text fixed-width truncates localized copy

**The thought:** *"Figma metadata says this Text is 200pt wide. I'll emit `.frame(width: 200)` so the layout matches Figma exactly."*

**The actual outcome:** the Text fits the English copy ("Continue") fine. As soon as the app ships and someone localizes ("Tiếp tục" / "Weiter" / "продолжить") OR the screen renders user-supplied dynamic data, the text overruns 200pt and SwiftUI truncates it to ellipsis. The "exact match to Figma" was actually a measurement of the rendered string at design time, not a structural constraint — Figma node was `primaryAxisSizingMode: AUTO` (hug). The agent confused *measured visual width* with *requested fixed width*.

**The rule:** [visual-fidelity.md §Text](visual-fidelity.md) + [§7 Hard Rule #9](visual-fidelity.md). `.frame(width: N)` on a Text view is BANNED unless Figma node is `primaryAxisSizingMode === FIXED` AND a `// Figma fixed-width: <reason>` comment justifies it. Default for Text is hug (no frame) or fill (`maxWidth: .infinity`). Single-line Text in any constrained container also takes `.minimumScaleFactor(0.6)` so localized copy shrinks rather than truncates ([§7 Hard Rule #10](visual-fidelity.md)).

**The gate that should catch it:**
- `figma-to-swiftui-banned-pattern-gate.sh` (PreToolUse) blocks `Text(...).frame(width: <number>)` writes that don't carry `// Figma fixed-width:` on the same line or the line above.
- C3 Pass 2 check letter `TR` (text truncation / line limit) flags any `.lineLimit(1)` on Text without a paired `.minimumScaleFactor(...)`.

**The fix:** delete the `.frame(width: ...)` modifier on the Text. Let it hug. If the parent is fill-width and the Text needs to span the row, replace with `.frame(maxWidth: .infinity, alignment: .leading|.center|.trailing)`. If single-line is required (button label, badge), add `.lineLimit(1).minimumScaleFactor(0.6)`.

---

## 9. Y from frame origin double-counts safe area

**The thought:** *"Figma metadata says the headline is at y=64 in the frame. I'll emit `.padding(.top, 64)` to match."*

**The actual outcome:** the Figma frame is 812pt tall (iPhone X) and includes a status bar mockup at the top — 44pt of chrome that iOS itself renders, not part of the SwiftUI view. The 64pt is `44pt chrome + 20pt actual gap`. SwiftUI views also live INSIDE the safe area by default, so the renderer adds another 44pt of inset. Visual gap on the device = `44 + 64 = 108pt`. The headline is 64pt too low — exactly the height of the status bar that was double-counted.

**The rule:** [layout-translation.md §"Safe Area Normalization for Mockup Frames"](layout-translation.md) + [visual-fidelity.md §4 "Safe area & spacing normalization"](visual-fidelity.md) + [§7 Hard Rule #12](visual-fidelity.md). When `mockupChrome=true` (frame H matches an iPhone full-device height like 812 / 844 / 852 / 932), every Y measured from the frame origin must subtract `safeAreaInsets.top` before mapping into SwiftUI `.padding(.top, ...)` or `Spacer().frame(height: ...)`. Same on the bottom for the home indicator.

**The gate that should catch it:**
- `figma-to-swiftui-banned-pattern-gate.sh` (PreToolUse) blocks screen-root `.padding(.top, 44|47|59|64|67|79|88)` writes that don't carry `// safe-area-adjusted: raw=..., inset=..., adjusted=...` on the same line or the line above.
- C3 Pass 2 check letter `SS` (Spacing-Safe-area) verifies that any screen-root padding-top / Spacer.height equal to a suspicious value either has the justifying comment OR a Source quote that traces to a Figma raw Y minus inset.

**The fix:** classify the frame from H. Subtract the inset from every Y in the inventory. Re-emit `.padding(.top, raw_y - inset)` with the comment. If content genuinely needs to ride behind the status bar (full-bleed hero gradient), apply `.ignoresSafeArea(edges: .top)` to the **background layer only** — never to the content layer.

---

## 10. Image fill-width missing `.scaledToFill`

**The thought:** *"The Figma image fills the screen width — I'll add `.frame(maxWidth: .infinity, height: 240)` and call it done."*

**The actual outcome:** the image stays at its intrinsic point size (e.g. 343×200) and SwiftUI honours `.frame(maxWidth: .infinity, height: 240)` by reserving the *frame area*, leaving blank bars on either side of the image and an empty 40pt strip below. The user opens the simulator and sees a banner that's 343pt wide on a 393pt-wide iPhone — looks intentional only to the agent, broken to the user. Or worse: agent adds `.resizable()` but no content mode, and the image distorts anisotropically (squashed when frame H < intrinsic H, stretched the other way).

**The rule:** [visual-fidelity.md §1 "Image fill mode"](visual-fidelity.md) + [§4 Image](visual-fidelity.md) + [§7 Hard Rule #11](visual-fidelity.md) + [layout-translation.md §"Image content-mode → SwiftUI"](layout-translation.md). A fill-width / fill-height Image MUST emit all three modifiers together — `.resizable() + (.scaledToFill()|.scaledToFit()) + .frame(...)`. Default content mode when MCP doesn't surface `objectFit` and the image fills its parent: `.scaledToFill()` (Figma's image-fill default).

**The gate that should catch it:**
- `figma-to-swiftui-banned-pattern-gate.sh` (PreToolUse) blocks `Image(...).frame(maxWidth: .infinity, ...)` writes that don't have `.resizable()` AND a content-mode modifier (`.scaledToFill()` / `.scaledToFit()` / `.aspectRatio(contentMode:)`) within the same modifier chain.
- C3 Pass 2 check letter `IF` (Image Fill mode) verifies for every fill-* Image: `.resizable()` present, content mode present, frame present.

**The fix:** chain all three. `Image("hero").resizable().scaledToFill().frame(maxWidth: .infinity, maxHeight: 240).clipped()`. The `.clipped()` matters with `.scaledToFill()` — without it the over-flowing pixels render outside the frame and overlap neighbours.

---

## 11. Phone bezel mistaken for view corner radius

**The thought:** *"The Figma frame clearly shows the screen has rounded corners — about 47pt. I'll add `.cornerRadius(47)` (or `.clipShape(.rect(cornerRadius: 47))`) to the screen-root view to match."*

**The actual outcome:** the rounded outline the agent saw in Figma is NOT a UI corner radius — it's the **iPhone bezel mockup** drawn around the canvas, depicting the physical phone body. iPhone X/11/12/13/14/15 ≈ 47pt; 14 Pro / 15 Pro / 16 Pro / Pro Max ≈ 55pt. The hardware (and the iOS compositor on the simulator) already clips the outer corners for free. By adding `.cornerRadius(47)` on top of that, the agent clips the SwiftUI view to a *smaller* rounded rect inside an already-rounded device — the screen's content shrinks toward the centre and a black/empty gutter appears around all four edges. Exactly the bug in the user-supplied screenshot pair: design has corners (the bezel), code copies them onto the root view, and the simulator screenshot shows the result clipped a second time.

**The rule:** [SKILL.md §"ABSOLUTE RULE — Do NOT draw iOS system chrome"](../SKILL.md) + [visual-fidelity.md §4 "Device bezel ≠ view corner radius"](visual-fidelity.md) + [§7 Hard Rule #13](visual-fidelity.md). When `deviceBezel=true` in the inventory CONTAINER (frame H matches iPhone full-device class AND the outline shows ~47–55pt rounded corners): the screen-root view MUST NOT carry `.cornerRadius(R)`, `.clipShape(.rect(cornerRadius: R))`, or `.clipShape(RoundedRectangle(cornerRadius: R))`. The bezel is hardware/system chrome — never UI.

**The gate that should catch it:**
- `figma-to-swiftui-banned-pattern-gate.sh` (PreToolUse) blocks `*Screen.swift` writes that emit screen-root `.cornerRadius(N)` / `.clipShape(.rect(cornerRadius: N))` / `.clipShape(RoundedRectangle(cornerRadius: N))` with `N ≥ 30` and no `// allow-screen-corner-radius: <reason>` justification on the same/previous line.
- `c7-no-system-chrome.sh` (Stop) catches any that slipped through the PreToolUse hook — same heuristic, same threshold.
- C3 Pass 2 check letter `CH` (no system chrome) covers it explicitly: `R ≥ 30` at screen-root reads as a chrome redraw.

**The fix:** delete the modifier from the screen-root. Inner cards / sheets / buttons / badges keep their own (smaller, design-system-sourced) radii — those are real UI. If a modal sheet or presented half-screen genuinely needs an inner-card radius that happens to be ≥ 30pt, mark it with `// allow-screen-corner-radius: presented sheet, Figma node <X> radius` so the gate can validate intent.

---

## 12. Button bloated by inner Text maxWidth

**The thought:** *"Figma `textAlignHorizontal=CENTER` on this button label means the centered text needs `.frame(maxWidth: .infinity, alignment: .center)`. I'll add it on the Text. The skill's AL check letter says to pair `.multilineTextAlignment(.center)` with a fill-width frame — done."*

**The actual outcome:** the Button extends edge-to-edge on the simulator, ignoring the caller's `.padding(.horizontal, 16)`. The Figma design shows a button sitting inside a 16pt side margin (343pt wide on a 393pt iPhone); the simulator shows a button that fills the full 393pt screen width. The caller's padding lands on a child that is already requesting fill, so it has nothing to push against — the Button asked for the full available width and got it.

The mechanism: `.frame(maxWidth: .infinity)` is a "fill request" that propagates outward through the SwiftUI tree until something imposes a finite width. Inner Text → outer HStack → Button → caller. The Button has no width modifier of its own, so the request cascades through it to the caller, which (intending margin) gives the Button the full screen width minus padding, and then the Button's *content* uses that full-width-minus-padding as its drawing rect.

The right rule, from the Button's own Figma `primaryAxisSizingMode`:
- `FILL` (button fills its container) ⇒ `.frame(maxWidth: .infinity)` on the **Button outer**, no maxWidth on inner Text
- `FIXED` (designer set width N) ⇒ `.frame(width: N)` on the **Button outer**, no width on inner Text
- `AUTO/HUG` (button hugs its label) ⇒ no width modifier; let Button intrinsic-size

When the Button outer carries `.frame(maxWidth: .infinity)`, it propagates the fill-width drawing rect *down* to its content. The inner Text with `.multilineTextAlignment(.center)` then visually centers in the wider rect, **without** needing its own maxWidth. The C3 Pass 2 `AL` check is satisfied: the alignment modifier is present AND the drawing rect is fill-width — it just lives on the Button outer instead of the Text.

**The rule:** [visual-fidelity.md §"`.frame(maxWidth: .infinity)` cascade trap"](visual-fidelity.md) + [§7 Hard Rule #14](visual-fidelity.md). `.frame(maxWidth: .infinity)` belongs on the OUTERMOST view of the bounded container (Button outer / Card outer / screen-root) — never on inner Text or inner HStack inside a Button. Same cascade trap applies symmetrically to `.frame(maxHeight: .infinity)` through vertical containers.

**The gate that should catch it:**
- `figma-to-swiftui-banned-pattern-gate.sh` (PreToolUse) Check 8 blocks `Text(...).frame(maxWidth: .infinity)` writes whose enclosing scope is a `Button { ... }` body, unless `// allow-text-fill: <reason>` on the same line or the line above justifies it. The awk tracks brace depth from `Button {` to detect when we're inside the button scope; multi-line modifier chains (Text on one line, `.frame` chained on a later line) are caught within a 10-line window.
- C3 Pass 2 check letter `BW` (button-width) verifies for every Button in the Visual Inventory: width modifier (if any) is on the Button outer, sourced from the Button node's `primaryAxisSizingMode`; inner Text/HStack does not carry a maxWidth modifier.
- C5.6.6 4-anchor proportional check has a "primary CTA width" row whose Figma vs simulator width-percentage delta must be ≤ 3pp — catches the simulator-vs-Figma width mismatch even if the agent's vision missed it on the qualitative side-by-side.

**The fix:** move the `.frame(maxWidth: .infinity)` from the inner Text to the Button's outer modifier chain. Remove any maxWidth on inner Text or inner HStack. If the button content is asymmetric (icon + label that should push to opposite edges), use `HStack { Spacer(); ... }` or `HStack { Text(...); Spacer(); Image(...) }` — Spacer pushes elements apart without cascading a fill request.

```swift
// CORRECT
Button(action: tapped) { Text("Continue") }
  .frame(maxWidth: .infinity)
  .padding(.vertical, 12)
  .background(Color.accent, in: .rect(cornerRadius: 8))
  .padding(.horizontal, 16)
```

```swift
// WRONG — banned by Check 8
Button(action: tapped) {
  HStack {
    Text("Continue").frame(maxWidth: .infinity)
  }
}
.padding(.horizontal, 16)  // overridden — Button already fills the screen
```

---

## Escape hatches (when an enforcement hook is wrong for your case)

Every hook ships with one or two opt-out paths so legitimate edge cases don't get hard-blocked. Use them sparingly — each one defeats a rule that exists for a reason — and always include the explanation comment on the same line OR the line immediately above so a code reviewer can see WHY.

| Hook | Trigger | Escape | When to use |
|---|---|---|---|
| `figma-to-swiftui-gate.sh` (PreToolUse, Phase A/B coverage) | Block `.swift` Write when manifest / design-context / screenshot / tokens / registry incomplete for any cached screen | Path segment `_NoFigma_` (e.g. `App/_NoFigma_/NetworkClient.swift`) | The file is non-UI scaffolding unrelated to Figma — networking, persistence, AppDelegate hooks. Not for view code. |
| `figma-to-swiftui-banned-pattern-gate.sh` (PreToolUse, content) | `Image(systemName:)` outside chevron / share / xmark / keyboard allow-list | `// allow-systemName: <reason>` on same line or line above | Legitimate iOS-system glyph (ShareLink button, search-field clear icon). Never for a Figma-designed icon. |
| same hook | Text in fill-width container needs `.frame(maxWidth: .infinity)` AT THE TEXT | `// allow-text-fill: <reason>` | Rare — when parent stack is non-Button AND a sibling forces the row to width: .infinity. Better: move maxWidth to the outer container. Never to defeat a Button bloat. |
| same hook | `.frame(width: <num>)` on Text | `// Figma fixed-width: <reason>` | Figma's `primaryAxisSizingMode === FIXED` on the Text node. Note the exact Figma size in the reason. |
| same hook | Screen-root `.padding(.top, 44\|47\|59\|64\|67\|79\|88)` | `// safe-area-adjusted: raw=<y>, inset=<n>, adjusted=<y-n>` | Math IS correct (not a double-count). Comment shows the calculation. |
| same hook | `.cornerRadius` / `clipShape(.rect(cornerRadius:))` ≥ 30pt | `// allow-screen-corner-radius: <reason>` | Presented sheet card / inner hero card whose Figma node legitimately specifies radius ≥ 30pt. NEVER on the screen root (that's the bezel). |
| `figma-to-swiftui-entry-bypass-gate.sh` (PreToolUse, App/Root/ContentView entry surface) | `initialStep` / `currentStep` / `VERIFY_ROUTE` / `#if DEBUG` deep-link parser | `// figma-entry-bypass-gate: legitimate-flow-state` on the assignment line, OR `_NoFigma_` segment | Real onboarding state init that just happens to look like a verification jump. Never to make C5 reachable for screenshot purposes. |
| `figma-to-swiftui-c8-gate.sh` (PostToolUse) | Path / naming / ViewModel pattern / function length / IK* violations | None — fix the file | C8 gates have no escape by design. If the project genuinely doesn't follow C1's detected convention, fix `c1-conventions.json` (re-run `c1-probe.sh`), don't try to dodge per-file. |
| `figma-to-swiftui-pass2-gate.sh` (PostToolUse on `c3-pass2-diff.md`) | Pass 2 report structure / weasel words / counter | None — fix the report | Same — diff-report quality has no shortcut. |
| `figma-to-swiftui-stop-gate.sh` (Stop) | Phase B not done / C5 not satisfied / C6/C7/C8 fail | `manifest.verification.c5.skipped` set to one of `no_project`, `simctl_error`, `ci_environment`, `no_entry_path` (auto-detected — user phrases like "skip C5" do NOT bypass) | One of four genuine system reasons. Never set manually to dodge — the gate re-verifies the underlying condition (e.g. `no_project` requires no `.xcodeproj` walking up 3 levels). |

**Comment-form rules.** Every comment-style escape (`// allow-…`, `// Figma fixed-width:`, `// safe-area-adjusted:`, `// figma-entry-bypass-gate:`) must:
- Live on the SAME line as the modifier OR the line directly above it (no further). The hook's grep window is `lineno` and `lineno - 1`.
- Carry a real reason in the freeform tail. `// allow-systemName: needed` is not enough — write `// allow-systemName: ShareLink default icon` so review sees the WHY.

**Path-form rule.** The `_NoFigma_` token requires the surrounding underscores literally (the shell match is `case "$FILE_PATH" in *_NoFigma_*`). `MyNoFigmaView.swift` does NOT match. Preferred form is a path component: `<Target>/_NoFigma_/Network/Client.swift`. A basename also matches if you write the underscores explicitly (e.g. `_NoFigma_NetworkClient.swift`), but the folder form is clearer to readers.

**STOP-line:** the moment an escape hatch becomes your default tool, you've drifted into the failure mode the hook exists to prevent. Re-read the corresponding §1–§12 entry and fix the real cause instead.

---

## Failure-mode self-check (read at the end of every run)

Before you write the Verification summary, scan your draft for these phrases. If you find any, you have NOT finished the run — you have a failed run with a footnote:

- "for maintainability" / "to keep it simple" / "để dễ maintain"
- "the user won't notice" / "close enough" / "good enough for now"
- "approximately" / "roughly" / "near match" / "minor difference"
- "non-negotiables flexed" / "had to compromise"
- "LSP is stale, actual compile is fine" — without running `xcodebuild build`
- "bypassed C5 entry path by editing X" / "added an init override for verification"
- "used SwiftUI shapes for ... " — for icons / logos / illustrations
- "skipped Phase B for these icons because they're simple"
- "downloaded the major assets, built minor ones in code"
- "the Text is 200pt wide in Figma so I added `.frame(width: 200)`" — see §8
- "y=64 in the frame so `.padding(.top, 64)`" — see §9 (subtract safe-area inset)
- "frame is enough, no need for `.scaledToFill`" — see §10
- "the screen has rounded corners in Figma so I added `.cornerRadius(47)` to the root" — see §11 (that's the bezel)
- "centered text needs `.frame(maxWidth: .infinity)` so I added it on the Text inside the button" — see §12 (cascades up; goes on Button outer)

These are the exact phrases the skill exists to make impossible. If your summary contains any of them, STOP. Re-do the bypassed step. Then write the real summary.
