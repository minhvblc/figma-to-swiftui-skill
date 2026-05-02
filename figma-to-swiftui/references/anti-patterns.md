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

These are the exact phrases the skill exists to make impossible. If your summary contains any of them, STOP. Re-do the bypassed step. Then write the real summary.
