---
name: figma-to-swiftui
description: "Build pixel-perfect SwiftUI views from Figma via Figma MCP. Triggers on figma.com URLs, Figma node IDs, a current Figma selection in figma-desktop MCP, and phrases like 'implement/translate/convert Figma to SwiftUI', 'iOS UI from Figma', 'làm UI SwiftUI từ Figma', 'code màn iOS theo Figma', 'làm màn này', 'adapt SwiftUI view to Figma', or a .txt/.md brief paired with Figma work for iOS. Requires BOTH the figma-desktop MCP (get_metadata / get_design_context / get_screenshot) AND the MCPFigma server (figma_build_registry / figma_extract_tokens / figma_export_assets_unified) — STOP if either is missing, never improvise. Do NOT trigger for React, web, or Android."
---

# Figma to SwiftUI

Turn Figma nodes into production SwiftUI with pixel-matching fidelity. **Three phases, executed in strict order. Each phase has a mandatory exit gate. You may not start the next phase until the previous gate prints `GATE: PASS`.**

- **Phase A — Discover & Spec.** Fetch the design specification (context, screenshot, tokens, metadata). Cache only.
- **Phase B — Asset Pipeline.** Inventory every visible asset, classify, download as PNG, validate. Cache only.
- **Phase C — Implement.** Write SwiftUI offline from the cache, self-check, copy assets to the project.

**Fidelity playbook (read first, every Phase C):** `references/visual-fidelity.md`.

---

## Quick Reference (read this first)

The full SKILL.md below is comprehensive but long. For a fast pass before starting a task, use this index. Hooks enforce most rules automatically — you generally do not need to memorize them, just understand when each fires.

> **Script path resolution.** Every `scripts/X.sh` shown below is `~/.claude/scripts/X.sh` when running from an iOS project (the cwd you actually work in). The repo-relative path is what the skill source uses; `scripts/install.sh` copies them to `~/.claude/scripts/` so they are reachable wherever you invoke the skill. `~/.claude/skills/figma-to-swiftui/references/` similarly holds the installed reference docs. When in doubt: `ls ~/.claude/scripts/`, or run `bash ~/.claude/scripts/doctor.sh`.

**Decision flow at task start:**

```
1. Mode detect → scripts/mode-detect.sh <project>
     greenfield-vanilla       → scripts/vanilla-scaffold.sh
     greenfield-ikame         → scripts/ikxcodegen-scaffold.sh (ASK USER first)
     brownfield-ikame         → load Ikame conventions, no scaffold
     brownfield-vanilla       → load vanilla conventions, no scaffold
     ambiguous                → STOP, ask user
2. Pin Figma file → figma_build_registry
     screens populated        → iterate per screen
     candidateScreens populated → references/registry-empty-fallback.md case 1
     both empty               → references/registry-empty-fallback.md case 2 (re-root)
3. For each screen → Phase A → Phase B → Phase C → C5 (tier 1–3 per c5-tiered-verification.md)
```

**References, by trigger:**

| When you... | Read |
|---|---|
| Start a greenfield project | `references/greenfield-vanilla.md` + `references/ikxcodegen-bridge.md` |
| `figma_build_registry` returns 0 screens | `references/registry-empty-fallback.md` |
| Have ≥ 10 screens / ≥ 3 feature areas | `references/parallel-subagent-pattern.md` |
| Need to enter "rough scaffold" mode | `references/scaffold-mode.md` |
| Reach Phase B for a feature | `references/anti-patterns.md` (especially §1 + §13) |
| Reach C5 verification | `references/c5-tiered-verification.md` + `references/verification-loop.md` |
| Find a phrase you're tempted to write in summary | `references/anti-patterns.md` §"Failure-mode self-check" |
| Hook blocked your Write/Edit | The 1-line stderr; expand with `HOOK_VERBOSE=1` env var |

**P0 STOP gates (these are hard, even in scaffold mode):**

- Empty registry (no screens, no candidateScreens) → STOP, re-root before any Swift Write.
- `figma_extract_tokens` returned `forbidden` → use fallback per `mcpfigma-setup.md`, do NOT proceed without color/typography tokens.
- ikxcodegen / vanilla-scaffold output already exists → refuse to overwrite, ask user.

**The two most common failure modes:**

1. **Anti-pattern §1: SwiftUI shapes for icons.** Sneaks in when "the icon is simple". Hook `figma-to-swiftui-banned-pattern-gate.sh` blocks `Image(systemName:)` outside the allow-list. Bypass with `// allow-systemName: <reason>` ONLY for genuine iOS HIG glyphs.
2. **Anti-pattern §13: Template-from-doc.** Sneaks in on multi-screen flows when "they all look the same". Each screen needs its own Phase A artifact. The flow skill must reject templates built from doc wording instead of per-screen `get_design_context`.

If you're not sure which mode/tier/escape applies, read the reference. The reference docs are short and focused; SKILL.md below is exhaustive.

---

## Convention source of truth — Ikame projects

When `c1-conventions.json.usesIKCoreApp == true`, **`ikame-ios-coding` skill is the canonical source for every base Swift/SwiftUI convention.** This skill (`figma-to-swiftui`) only adds Figma-specific patterns and code-generation flow on top.

| Topic | Canonical reference | What this skill adds |
|---|---|---|
| Folder layout, file naming, promotion rule | `ikame-ios-coding/references/project-structure.md` | mode detection (greenfield-ikame/brownfield-ikame), per-screen folder pinning from Figma frame name |
| ViewModel pattern: `@MainActor` + `ObservableObject` + flat `@Published` + `enum Action` + `func send(_:)` + `enum Route` + `@Published var route: Route?` | `ikame-ios-coding/references/viewmodel.md` | C8-vm-pattern enforcement, Action-naming derived from Figma interactive node names |
| SwiftUI view: body ≤ 50 lines, modifier order, `@ViewBuilder` vs nested struct | `ikame-ios-coding/references/swiftui-view.md` | function-length gate, body-section splitting per Figma layout regions |
| IKNavigation: `<Feature>Route.swift` + `<Feature>Router.swift`, `IKRouteID` extension, `EmptyView()` else, compose with `+` | `ikame-ios-coding/references/iknavigation.md` | extending existing router with new cases derived from Figma flow, `IKNavigationIdentifier` for sheet-with-internal-nav |
| `@APIProtocol` + `enum API` registry + `=>` operator + `@JsonSerializable` | `ikame-ios-coding/references/api-ikmacros.md` | DTO ↔ Entity mapping for Figma-driven data shapes |
| IKToast / IKLoading / IKPopup | `ikame-ios-coding/references/ui-popup-toast-loading.md` | app-level `IKPopupConfiguration` extension cases observed per project, popup view body emission |
| ikFont presets / `ikFont(size:weight:)` escape hatch / 4-layer additional-font helper / `Color(hex:)` | `ikame-ios-coding/references/fonts-and-styling.md` | Figma typography token → preset or escape hatch decision; codegen for Asset Catalog colorsets |

**Conflicts always resolve in favor of `ikame-ios-coding`.** If a bridge file under `references/ikame-*-bridge.md` says one thing and `ikame-ios-coding` says another, follow `ikame-ios-coding` and treat the bridge as out-of-date. The bridges below are pruned to the **delta** — patterns / config cases / app-level extensions that `ikame-ios-coding` does not yet cover.

For convention areas `ikame-ios-coding` does NOT cover (IKTracking, IKLocalized, IKOnboardingFlow, IKHaptics, per-project `IKPopupConfiguration` extensions, `AppUtils.shared.showAppBottomToast` app-level wrapper), the matching bridges in `references/` remain authoritative.

For non-Ikame projects (`usesIKCoreApp == false`), `ikame-ios-coding` does not apply — use the vanilla conventions in `references/swiftui-pro-bridge.md`, `references/viewmodel-pattern.md` §1, etc.

---

## Mandatory Output Checklist

Every run MUST satisfy these five items. Cite each item by number in the verification report.

1. **Every visible icon, logo, illustration, and image is sourced from Figma.** No `Image(systemName:)` or hand-drawn `Path` / `Shape` substituting for a Figma node. Allow-list exceptions are documented in `references/verification-loop.md#6` and require an explicit `// allow-systemName:` opt-in for anything outside the canonical list. Enforced by `scripts/c6-asset-completeness.sh` (see [verification-loop.md §6](references/verification-loop.md#6-c6--asset-completeness-mandatory)).
2. **No iOS system chrome is redrawn in SwiftUI.** Status bar (time, signal/wifi/battery), home indicator, Dynamic Island, and notch are rendered by iOS. Enforced by `scripts/c7-no-system-chrome.sh` (see [verification-loop.md §7](references/verification-loop.md#7-c7--no-system-chrome-mandatory)).
3. **Asset export is exhaustive.** When calling `figma_export_assets_unified`, pass `autoDiscover: true` so the server scans the subtree under `nodeId` and auto-builds rows for every `eIC*` / `eImage*` it finds — caller-supplied rows still win on duplicates. The response's `coverage` block (`discoveredCount`, `exportedCount`, `autoAddedRows`, `skippedNodeIds`) is the proof. See `references/mcpfigma-setup.md` §"figma_export_assets_unified" for the flag.
4. **Visual diff is decisive, not weasel-worded.** C5.6 must produce `c5-sections.md`, `c5-census.md`, per-section crop pairs, free-form "what's wrong" paragraph, 3-axis diff table, negative spot-check, 4-anchor proportional check, and attestation. No "approximately", "roughly", "close enough" in PASS rows. See [verification-loop.md §C5.6](references/verification-loop.md#c56--side-by-side-compare-6-step-procedure-mandatory). Enforced by `scripts/c5-coverage-check.sh` and `scripts/c5-weasel-detect.sh`.
5. **Generated code follows project conventions detected at C1.** Folder layout, file naming, ViewModel pattern (`State + Action + send(_:)` reducer), function size, and (when the project uses them) IKNavigation / IKMacros / IKFont / IKPopup / IKFeedback / IKTracking / IKLocalized routing. The C1 convention probe writes `c1-conventions.json` (see [`references/adaptation-workflow.md` §0](references/adaptation-workflow.md#0-convention-probe-mandatory-run-before-the-audit)) which gates the c8-* scripts: `c8-conventions-gate.sh`, `c8-vm-pattern.sh`, `c8-func-length.sh`, `c8-iknavigation.sh`, `c8-ikfont.sh`, `c8-ikpopup.sh`, `c8-ikfeedback.sh`, `c8-iktracking.sh`, `c8-iklocalized.sh`, `c8-weak-self.sh`. **For Ikame projects (`usesIKCoreApp == true`), `ikame-ios-coding` skill is the canonical source for every base convention** — see the "Convention source of truth" section above. Bridge files under `references/ikame-*-bridge.md` hold only the Figma-specific delta + advanced features `ikame-ios-coding` does not yet cover (IKTracking, IKLocalized, IKOnboardingFlow, IKHaptics, app-level popup config cases). Phase 0 mode detection: `scripts/mode-detect.sh`.

---

## ABSOLUTE RULE — Assets come from Figma

Every visible icon, logo, illustration, image, and decorative graphic in the screenshot **MUST** be downloaded from Figma in Phase B. No exceptions, no shortcuts.

**Banned substitutions** (treat as bugs, not "approximations"):
- `Image(systemName: ...)` (SF Symbols) for any element that exists as a Figma node
- Colored rectangles / circles / `Text("G")` standing in for real logos
- `Shape` primitives drawn to mimic an icon ("a circle with a checkmark")
- "Simplified" versions of Figma illustrations
- Any phrase like "no Figma PNG/SVG pipeline was set up" — Phase B is mandatory, not optional

**Only allow-listed exceptions** for `Image(systemName:)`:
- iOS system chrome the user explicitly said to keep system-default (back chevron in NavigationStack toolbar, share sheet icons)
- The user explicitly tells you to substitute for a missing asset

**Failure-mode self-check.** If you catch yourself thinking *"SF Symbol is close enough"*, *"the user won't notice"*, *"I'll skip the pipeline this time"*, *"there's no FIGMA_TOKEN so I can't download"*, *"the third-party Figma MCP gives me roughly the same data, I'll use it just for this run"*, *"I'll mark this as approximation in the summary"*, *"I had to flex the non-negotiables"*, *"the major assets are downloaded, I'll build the minor ones (tab bar / PIN dots / timer ring / social logos) with SwiftUI shapes for maintainability"*, *"these icons are simple — `Image(systemName:)` is fine"*, or *"build → screenshot → it looks great" without the C5.6 procedure* — **STOP**. That is the exact failure mode this skill exists to prevent. Go run Phase B via `figma_export_assets_unified(autoDiscover: true)` (MCPFigma) for every visible icon, then run the full C5.6 procedure. If MCPFigma is not connected, STOP and ask the user to install it — do not silently downgrade to substitutions. **Disclosing the bypass in the final summary does not redeem it** — the rule is "STOP and surface BEFORE acting", not "act first and confess after". A run that ships with the "non-negotiables flexed" disclaimer is a failed run, not a successful one with a footnote.

**Concrete failure modes seen in real runs** are catalogued in [`references/anti-patterns.md`](references/anti-patterns.md). Read it once before Phase B and once again before writing the Verification summary — it lists the exact agent justifications that produced broken runs ("build the rest with SwiftUI shapes", "edit ContentView to jump screens for screenshot", "LSP is stale", "disclose in summary"), the rule each violates, and the gate that should have caught it.

If an asset truly cannot be fetched (node missing from Figma, MCP returns error after retry), **STOP and tell the user** — do not improvise. Improvisation = task failure.

---

## ABSOLUTE RULE — Do NOT draw iOS system chrome

Figma frames often include a mockup of iOS system chrome (status bar, Dynamic Island, home indicator) **and the rounded outline of the iPhone body itself** (the bezel). **All of these are rendered by iOS or by the physical hardware.** Drawing them in SwiftUI is always a bug — it duplicates what iOS already shows and breaks on real devices.

**Never draw these, even if they appear in the Figma screenshot:**
- Status bar (time "9:41", Dynamic Island, signal/wifi/battery icons)
- Home indicator (the ~134×5pt horizontal bar at the bottom)
- System keyboard, pull-to-refresh spinner, system nav back chevron
- Native tab bar (`TabView` provides its own), system alerts, page dots
- **iPhone bezel / device frame** — the rounded outline of the entire frame, ~47–55pt radius, depicting the physical phone corners. The hardware's own corners produce this curve on a real device; SwiftUI's screen-root view never needs `.cornerRadius` / `.clipShape(RoundedRectangle)` for it.

**Recognize them in the screenshot before inventorying.** Strip them out of the Visual Inventory — they are mockup decoration, not content. The SwiftUI view starts below the status bar, ends above the home indicator, and runs edge-to-edge on the X axis with no rounded outer corners; iOS / hardware handles the rest.

**What to do instead:**
- Status bar area → `.ignoresSafeArea(edges: .top)` on the background only if the design shows content extending behind it; otherwise let the safe area work normally.
- Bottom of screen → leave the home indicator area to iOS. Use `.safeAreaInset(edge: .bottom)` / `.safeAreaPadding` if your content needs padding above it. Do NOT draw a `Capsule()` or `RoundedRectangle()` at (width≈134, height≈5) to mimic it.
- Custom tab bar that IS part of the app (not iOS `TabView`) → fine to implement, but place it with `.safeAreaInset(edge: .bottom)` so iOS keeps the home indicator below it.
- **Outer rounded corners of the entire frame → ignore them entirely.** Do NOT add `.cornerRadius(R)` / `.clipShape(.rect(cornerRadius: R))` / `.clipShape(RoundedRectangle(cornerRadius: R))` to the screen-root view to mimic the bezel. The physical device clips them automatically; in the simulator your view legitimately reaches all 4 corners of the canvas. If a Figma frame *appears* to have rounded outer corners, those are the device-mockup bezel — not a UI radius.

**Failure-mode self-check.** If the Visual Inventory has a row like "home indicator bar", "status bar with time 9:41", "Dynamic Island pill", **or "screen container has corner radius ~47pt / ~55pt"** — **delete it** before coding. If you find yourself thinking *"the screen has rounded corners in Figma so I'll add `.cornerRadius(47)` to the root"*, that is the bug — STOP and re-read this section.

## Prerequisites

**Two Figma MCP servers are required — both, not one.** They cover disjoint responsibilities and the skill assumes both:

| MCP server | Tools used by this skill | Purpose |
|---|---|---|
| `figma-desktop` (official) | `get_metadata`, `get_design_context`, `get_screenshot`, `get_variable_defs` | Reads design spec, FRAME screenshot, design context, raw variable defs from the open Figma file. |
| `figma-assets` (MCPFigma) | `figma_build_registry`, `figma_extract_tokens`, `figma_export_assets_unified` (and legacy `figma_list_assets` / `figma_export_assets` — **do not use, see Step 5 of flow skill**) | Discovers screen graph, extracts SwiftUI-ready tokens, exports per-node PNG assets into `Assets.xcassets`. |

### BANNED substitute MCPs (do NOT use as a fallback)

These third-party Figma MCP servers expose superficially-similar tools but produce **incompatible artifacts**. They MUST NOT be used as a substitute for the two required servers above, even when the required ones are missing. Detect-and-STOP, do not silently degrade:

| Tool name (substring match) | Origin | Why banned |
|---|---|---|
| `mcp__figma__get_figma_data` | `figma-developer-mcp` (Framelink) | Returns raw REST JSON; not the JSX/Tailwind output that `design-context.md` requires; downstream prefill scripts (`c3-pass2-prefill.sh`) and the C3 Pass 1 banned-phrase grep cannot read it. |
| `mcp__figma__download_figma_images` | `figma-developer-mcp` (Framelink) | Renders raw PNGs but skips the tagged-asset naming convention (`icAI*` / `imageAI*`), the `_shared/assets/` dedup, the imageset emission, and the lottie-placeholder routing that `figma_export_assets_unified` performs. Result: the agent then hand-builds imagesets, which violates Phase B's "single source of truth" rule. |
| Any tool named `mcp__figma_*__*` whose server is not `figma-desktop` or `figma-assets` | various | Same blast radius — the gates and Pass 2/C3/C5 reports assume artifacts produced by the required servers. |

If any of these tools appear in the available tool list AND `get_design_context` / `figma_build_registry` are missing → **STOP**. Tell the user verbatim: *"Banned substitute MCP detected (`<tool name>`). The skill requires `figma-desktop` MCP and `figma-assets` (MCPFigma). Install both per `references/mcpfigma-setup.md` and `references/figma-mcp-setup.md`. I will not improvise."* Do not call the banned tool, even once, to "see what's there".

The agent's own thought *"the third-party MCP gives me roughly the same data, I'll use it just for this run"* is the exact failure mode this rule exists to prevent. Output may compile and screenshot well, but the artifacts on disk are wrong shape and every subsequent gate (C3 Pass 1, Pass 2, Pass 4) loses its grounding.

### Connection check (mandatory, probe first — do not ask upfront)

1. Call `get_metadata` on the target node (or current selection) **using the figma-desktop MCP namespace explicitly** (e.g. `mcp__figma-desktop__get_metadata`, not the bare `get_metadata` from a third-party server). Failure → figma-desktop MCP missing → STOP, ask user to install/connect.
2. Call `figma_build_registry(fileKey, nodeId, depth=10)` (Step A2). Failure with "tool not registered" → MCPFigma missing → STOP, ask user to install per `references/mcpfigma-setup.md`.
3. **Sanity-check the response shape**, not just the HTTP/JSON-RPC success. `get_design_context` MUST return the JSX/Tailwind block headed by `## Design context for "<node-name>"` — if the response is a plain JSON tree, you are talking to a banned substitute MCP, not figma-desktop. STOP per the rule above. Same for `figma_build_registry`: response MUST contain `rootNode`, `screens`, `taggedAssets`, `lottiePlaceholders`, `warnings` keys (see `references/mcpfigma-setup.md` §"figma_build_registry").

**If only one of the two is connected → STOP. Do not improvise a fallback.** Specifically:
- Missing `get_screenshot` / `get_design_context` → no Pass 2 / C5 visual diff is possible; agent MUST NOT proceed by "reading metadata + guessing styles" or by swapping in a banned substitute MCP. That is exactly the failure mode banned above.
- Missing `figma_build_registry` / `figma_export_assets_unified` → Phase B asset pipeline cannot run; agent MUST NOT fall back to `Image(systemName:)`, to hand-drawn shapes, or to `mcp__figma__download_figma_images` for "just downloading the PNGs and writing imagesets manually".

Other inputs:
- Figma URL `figma.com/design/:fileKey/:fileName?node-id=...`, or current selection in figma-desktop MCP (no URL needed)
- SwiftUI Xcode project (preferred)
- Optional: `.txt`/`.md` brief — read **before** any Figma call

## Route

| Input | Use |
|---|---|
| 1 node, no doc (or doc = 1 screen) | this skill |
| Multiple nodes / root page / journey | `figma-flow-to-swiftui-feature` (delegates back per screen) |
| Ambiguous | Step 0 + 1b first, then decide |

See `references/source-document.md`.

---

# Phase 0 — Pre-flight (MANDATORY before any Phase A work)

Run-once-per-project. **If you skip Phase 0, you will write Swift into a folder that has no scaffolded project, the `figma-to-swiftui-mode-gate.sh` hook will block your first Write, and you will have to come back to Phase 0 anyway. Do it first.**

### Step 0.1 — Mode detection (always runs)

```bash
bash ~/.claude/scripts/mode-detect.sh <projectFolder> --write-cache
```

Writes `<projectFolder>/.figma-cache/_shared/mode.json`. The mode-gate hook checks for this file's presence before allowing any `*.swift` Write/Edit. Four possible outcomes:

| mode | What it means | Required follow-up |
|---|---|---|
| `greenfield-ikame` | Empty folder + `ikxcodegen` on PATH (Ikame fleet detected) | **ASK USER** (one-line Y/n): *"Detected Ikame fleet (ikxcodegen on PATH). Scaffold via ikxcodegen? [Y/n]"*. On Y/default → `bash ~/.claude/scripts/ikxcodegen-scaffold.sh <ProjectName>`. On n → fall through to vanilla. |
| `greenfield-vanilla` | Empty folder, no `ikxcodegen` (or user opted out) | `bash ~/.claude/scripts/vanilla-scaffold.sh <ProjectName>` |
| `brownfield-ikame` | Existing project with `pod 'IKCoreApp'` (or any `import IKCoreApp`) | No scaffold needed. Load Ikame conventions per `~/.claude/skills/figma-to-swiftui/references/ikame-decision-table.md`. |
| `brownfield-vanilla` | Existing project, no Ikame umbrella | No scaffold needed. Load vanilla conventions. |
| `ambiguous` | Mixed signals / partial scaffold | **STOP.** Ask user before scaffolding over existing files. When OK'd, persist `userConfirmed: true` into `mode.json` (`jq '. + {userConfirmed: true}' mode.json > tmp && mv tmp mode.json`). |

**Banned at this step:** generating raw `.xcodeproj` / `Project.yml` for a greenfield Ikame run (the `mode-gate` hook also enforces this — if mode is `greenfield-ikame` and no `.xcodeproj` exists when Phase A is already done, Swift writes are blocked until scaffold runs).

### Step 0.2 — C5 Engine probe (deferred to C5 start, but check Xcode is running NOW so you don't get blocked later)

The deterministic Engine A vs Engine B selection happens at C5 start via `scripts/c5-engine-select.sh`. On the Xcode 26+ baseline (the fleet default), Engine A (`mcp__xcode__BuildProject` + `RenderPreview`) requires **Xcode app to be running with the target project open**. If Xcode is not running by the time Phase C reaches C5, the selector falls back to Engine B and the `engine-gate` hook flags it. Open Xcode now:

```bash
open -a Xcode <projectFolder>/<ProjectName>.xcworkspace  # or .xcodeproj if no workspace
```

This is a soft hint — the hook only blocks raw `xcodebuild`/`simctl` at C5 time, not in Phase 0.

### Step 0.3 — Verify the figma-to-swiftui MCP stack is connected

Per the [Prerequisites](#prerequisites) section above, run the connection check on `figma-desktop` AND `figma-assets` (MCPFigma). If either is missing, STOP — do not improvise with a substitute MCP. The skill *cannot* run with one MCP.

### Phase 0 exit gate

When all three steps complete, you have:
- `.figma-cache/_shared/mode.json` with mode + optional `userChose` / `userConfirmed`
- A scaffolded project (greenfield) OR an existing project (brownfield) — both confirmed by the presence of `*.xcodeproj`
- Both Figma MCPs verified responding

Only then proceed to Phase A.

---

# Phase A — Discover & Spec

Goal: a complete design specification in the cache. **No asset downloads in this phase.**

### Step A0 — Source Document
If a doc is attached, read it first. Extract: goal, screens, actions, states, constraints, out-of-scope. See `references/source-document.md`.

### Step A1 — Parse URL
- `fileKey`: first path segment after `/design/` or `/file/`
- `nodeId`: `node-id` query param; replace `-` with `:` (URLs use `3166-70147`, MCP expects `3166:70147`)
- Reject `/proto/` and `/board/` — ask for a `/design/` link
- figma-desktop: uses selected node automatically

### Step A2 — Screen Discovery (registry-first)

Call `figma_build_registry(fileKey, nodeId, depth=10)` once. The response gives you `screens[]` (FRAME-like children with iOS-canvas dimensions) directly — no manual `get_metadata` walk needed. Persist to `.figma-cache/<nodeId>/registry.json`.

- 0 screens **and** root is not itself a FRAME → ask user to point at a frame, not a page.
- 1 screen → continue with this skill.
- N > 1 screens → hand off to `figma-flow-to-swiftui-feature` (which reuses the same registry).

The registry response also includes `taggedAssets[]` and `lottiePlaceholders[]` — Step B0 reuses these instead of re-fetching. See `references/screen-discovery.md`.

### Step A2b — Screen-vs-State Disambiguation (mandatory before A3)

Two screens with **the same UI structure** in Figma are almost always two **states of one screen**, not two separate screens — even if the doc describes them as separate steps in a flow. Common pairs that mislead agents into building twice as many screens as needed:

- "Enter PIN" + "Confirm PIN" frames with identical 3×4 number pad → ONE screen, two states (`first-entry`, `re-entry-for-confirm`)
- "Enable Face ID" + "Scan Face ID" frames sharing the same illustration → ONE screen with an overlay/modal state
- Step-1, Step-2, Step-3 onboarding cards with identical layout → ONE screen with `currentStep` state, three copy variants

**Detection rule** — for every pair `(A, B)` in `registry.screens[]`, flag a similarity hit when **all** of:
- Same frame size (`width × height` match)
- ≥ 80% of node-tree shape matches (same component types in same positions; cheap proxy: walk `metadata.json` paths and Jaccard on the path set)
- Body copy nearly identical (Levenshtein-ratio > 0.8 between extracted text content)

For each hit:

> Stop. Show the two screens to the user with both screenshots side by side. Ask: **"Đây là 2 state của cùng một màn (X) hay 2 màn riêng?"** Wait for the answer. If "state" → produce ONE screen with state-driven view + state enum case for each Figma node; record the mapping in `registry.json` under `stateGroups[]`. If "two screens" → continue with both. Do NOT decide on your own.

This check is mandatory before Step A3 batch fetch — if you don't run it, you waste tokens fetching design-context for what becomes one screen, and you build duplicate screens later. The doc behavior describing the user flow does NOT justify treating identical Figma frames as separate screens; doc describes user-facing steps, Figma describes view structure, and one view can host many steps.

### Step A3 — Batch Fetch Spec

For a single screen, issue calls 1+2+4+5 in **one parallel message** (`get_design_context` + `get_screenshot` + `get_metadata` + `figma_extract_fills` on the same node land independently). Call 3 (`figma_extract_tokens`) is per-`fileKey` — issue it once and reuse via symlink. For multi-screen flows, the flow skill clusters across screens (default 3 screens × 2 calls per cluster); see [references/fetch-strategy.md](references/fetch-strategy.md) §"Parallelism Inside Phase A". Save to `.figma-cache/<nodeId>/`:

1. `get_design_context(fileKey, nodeId, prompt="generate for iOS using SwiftUI")` → `design-context.md` *(figma-desktop MCP)*
2. `get_screenshot(fileKey, nodeId)` at **scale 3** (fine details visible) → `screenshot.png` *(figma-desktop MCP — this is the FRAME screenshot used for visual diff in C3 Pass 2 and C5; it is NOT an asset. Per-asset PNG export happens in Phase B via `figma_export_assets_unified`.)* Then immediately produce a comparison-safe sibling: `sips -Z 2000 .figma-cache/<nodeId>/screenshot.png --out .figma-cache/<nodeId>/screenshot-cmp.png`. Bản gốc (`screenshot.png`) giữ cho crop chất lượng cao (C5.6.3) và single-image read (C3 Pass 2). Bản `-cmp.png` (≤2000px long-side) dùng cho mọi many-image read (C5.6.1/.2/.4/.5). Lý do split: Claude many-image API reject ảnh >2000px khi request có ≥2 ảnh — frame iPhone scale-3 luôn vượt.
3. `figma_extract_tokens(fileKey)` → `tokens.json` *(MCPFigma 0.3.0+ — once per `fileKey`, dedup by copying/symlinking)*. This replaces `get_variable_defs` + manual SwiftUI naming. Output has `swiftName`, `lightHex`/`darkHex`, `isCapsule` for radius, plus a `typography[]` array (sourced from `/v1/files/<key>/styles` + `/v1/files/<key>/nodes`) carrying `fontFamily`, `fontPostScriptName`, `fontWeight`, `fontSize`, `lineHeightPx`, `letterSpacing`, `textCase`, `textAlignHorizontal`, `italic`. Each pass (variables, typography) fails independently — empty + non-empty `warnings` for one section means fall back to `design-context.md` inline tokens for that section only.
4. `get_metadata(fileKey, nodeId)` → `metadata.json` *(figma-desktop MCP — kept for design-context cross-ref in Phase C; A2's registry handles asset discovery)*
5. `figma_extract_fills(fileKey, nodeId, depth: 10, resolveImageUrls: true)` → `fills.json` *(MCPFigma — per-screen, NOT per-fileKey)*. Output: per-node fill stack for any descendant whose fills are non-trivial (gradient, image, stacked, translucent, blended). Single 100%-opacity SOLID fills are filtered out (already covered by `tokens.json` + `design-context.md`). Each gradient has normalized `stops[].position/hex`, `startPoint`/`endPoint` in 0..1 unit space (SwiftUI `UnitPoint`), and paint-level `opacity`. Each IMAGE fill carries `imageRef`, `scaleMode`, and (when `resolveImageUrls: true`) a CDN `imageUrl` resolved via `/v1/files/<key>/images`. **This is the canonical source for background-image + gradient-overlay composition in C2** — see [references/fills-handling.md](references/fills-handling.md). When fills.json is missing or empty, fall back to parsing `design-context.md` gradient classes/comments, but flag in summary so user knows fidelity is approximated.
6. Optional: Code Connect mapping — only if your Figma MCP exposes such a tool. Skip silently if unavailable.

**Hard rule on missing tools.** If steps 1, 2, or 4 error because figma-desktop MCP is not connected → STOP and ask the user to install it. **Do NOT** proceed with metadata-only + guessing styles — Pass 2 / C5 visual diff cannot run without `screenshot.png`, and Phase C cannot ground colors/typography without `design-context.md`. Same rule for steps 3 + 5: if MCPFigma is missing, STOP and ask — do not invent token enums and do not improvise background-image/gradient stacks from screenshot pixels.

On truncation: don't retry — fall back to metadata + per-section fetch. See `references/fetch-strategy.md`.

### Step A3+ — Phase B early-start pipeline (RECOMMENDED on first run)

`figma_export_assets_unified(autoDiscover: true)` only needs `nodeId` + `assetCatalogPath` — the server walks the subtree itself. It does NOT need `design-context.md`, `screenshot.png`, or `tokens.json`. This means Phase B's biggest network call (typically 30-90s for a screen with many assets) can ride along in the SAME parallel batch as A3 calls 1+2+3+4 instead of waiting for A3 to finish.

Wall-time saving on first run: **~10-15s on single-screen, 30-60s on a 4-screen flow** (B3 of multiple screens overlap with each other and with A3 fetches).

**Pre-pipeline checklist** (all must hold before issuing B3 in the A3 batch):
- A2 registry returned exactly one screen (or root is a confirmed single FRAME) — multi-screen flows go through `figma-flow-to-swiftui-feature` instead
- `assetCatalogPath` is resolvable WITHOUT user prompt (project has 0 → ask user to create one then stop, or 1 → silent default; **N>1** → prompt user first, no pipeline this run)
- A2 registry returned no `warnings[]` that change the asset plan (designer naming issues, etc. — surface and let user decide)
- User did not say "fetch sequentially"

**The parallel batch when pipelining:**
```
parallel batch = [
  get_design_context(fileKey, nodeId),              # A3 step 1
  get_screenshot(fileKey, nodeId, scale=3),         # A3 step 2
  figma_extract_tokens(fileKey),                    # A3 step 3 (skip if shared cache hit)
  get_metadata(fileKey, nodeId),                    # A3 step 4
  figma_extract_fills(fileKey, nodeId),             # A3 step 5 (per-screen)
  figma_export_assets_unified(                      # B3 — early-start
    fileKey, nodeId, outputDir, sharedAssetsDir,
    assetCatalogPath, rows: [], autoDiscover: true
  ),
]
```

**Cross-validation after the batch lands** (MANDATORY):
After A3 screenshot is in cache, walk Step B1 (Inventory) as usual. For every visual row, check whether its `nodeId` appears in `manifest.rows[]` from the early-started B3:

| Outcome | Action |
|---|---|
| Visual nodeId ∈ manifest, status: done | ✓ covered, no extra work |
| Visual nodeId NOT in manifest | Bump B3 with a supplementary single-row call for that node (~1-2s); merge result into manifest |
| Manifest row NOT in visual inventory (autoDiscover false-positive on a hidden/decorative node) | Keep in manifest — harmless; C4 inverse check surfaces it as `UNUSED` warning, user decides whether to clean |

The cross-validation step replaces nothing — B1 inventory + B2 classify + Gate B all still run unchanged. Pipelining only changes WHEN B3 issues, not whether the gates verify it.

**When the pipeline can't run** (any condition above false): fall back to the sequential default — A3 first, then B0 → B1 → B2 → B3 → Gate B as written below. The sequential path is still correct, just slower by 10-15s.

### Gate A — Phase A Exit (BASH, mandatory)

You MUST run this. If it does not print `GATE: PASS`, do NOT start Phase B.

```bash
CACHE=".figma-cache/<nodeId>"
FAIL=0
[ -s "$CACHE/design-context.md" ] && ! grep -q "truncated\|TRUNCATED" "$CACHE/design-context.md" && echo "PASS: design-context" || { echo "FAIL: design-context"; FAIL=1; }
file "$CACHE/screenshot.png" 2>/dev/null | grep -q "PNG image data" && echo "PASS: screenshot" || { echo "FAIL: screenshot"; FAIL=1; }
file "$CACHE/screenshot-cmp.png" 2>/dev/null | grep -q "PNG image data" && {
  LONG=$(sips -g pixelWidth -g pixelHeight "$CACHE/screenshot-cmp.png" | awk '/pixel(Width|Height)/ {print $2}' | sort -n | tail -1)
  [ "${LONG:-9999}" -le 2000 ] && echo "PASS: screenshot-cmp ($LONG px)" || { echo "FAIL: screenshot-cmp long-side=$LONG"; FAIL=1; }
} || { echo "FAIL: screenshot-cmp (run 'sips -Z 2000' on screenshot.png)"; FAIL=1; }
[ -s "$CACHE/metadata.json" ] && grep -q '"id"' "$CACHE/metadata.json" && echo "PASS: metadata" || { echo "FAIL: metadata"; FAIL=1; }
[ -f "$CACHE/tokens.json" ] && echo "PASS: tokens" || { echo "FAIL: tokens"; FAIL=1; }
[ -f "$CACHE/fills.json" ] && grep -q '"nodes"' "$CACHE/fills.json" && echo "PASS: fills" || { echo "FAIL: fills (run figma_extract_fills — needed for background image + gradient overlay fidelity)"; FAIL=1; }
[ -s "$CACHE/registry.json" ] && grep -q '"rootNode"' "$CACHE/registry.json" && echo "PASS: registry" || { echo "FAIL: registry"; FAIL=1; }
[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase A)" || echo "GATE: FAIL (Phase A)"
```

---

# Phase B — Asset Pipeline

**This is the phase agents skip. Don't.** Goal: every visible icon/logo/illustration/image from the screenshot exists as a validated PNG on disk (and, for tagged assets, also as an `.imageset` inside `Assets.xcassets`).

The whole pipeline runs through **`figma_export_assets_unified`** — one call that handles tagged + fallback paths internally:

- **Tagged path** (rows with `exporter: "tagged"`) — for `eIC*` / `eImage*` nodes registered by the designer. Renders @2x/@3x, renames to `icAI<Name>` / `imageAI<Name>`, writes `.imageset` directly into `Assets.xcassets`.
- **Fallback path** (rows with `exporter: "fallback"`) — for FLATTEN regions, untagged atomic nodes, and tagged rows that the server failed to render. Renders at scale 3 via `/v1/images`, validates PNG signature, dedupes into `_shared/assets/`.
- **Lottie path** (rows with `strategy: "lottiePlaceholder"`) — pass-through; manifest row only, no PNG.

Skill picks the right `exporter`/`strategy` per row in B1/B2 (visual judgment); the tool nukes all the orchestration. See `references/mcpfigma-setup.md`.

### Step B0a — Copy extraction (mandatory before any view code)

**Fast path (recommended):** run `scripts/b0a-extract-copy.sh --design-context .figma-cache/<nodeId>/design-context.md --output <project>/DesignSystem/Strings.swift --screen-name <Welcome>`. The script does the parsing + key-generation step described below in one call. It only emits Strings.swift (Option 2); when the project uses xcstrings (`c1-conventions.json.xcstringsPath != null`), edit the catalog directly per Option 1 — the script intentionally does not touch xcstrings. Resulting file is `parse`-clean (Swift reserved keywords like `continue` get backtick-quoted automatically).

Parse `design-context.md` and extract **every visible string** the user will read on this screen — title, subtitle, body, button labels, helper text, error text, status badges, footer links. For each: note the `data-node-id` from the React/Tailwind output; note the Figma typography style if present in the inline tokens block.

Write the extracts to a single source of truth for the project — choose ONE of:

**Option 1 (preferred for iOS 16+)**: a Swift String Catalog (`Localizable.xcstrings`). Each entry uses the `data-node-id` as the key (e.g. `welcome.title.3:24644`) and the Figma copy verbatim as the default value. SwiftUI views reference via `Text("welcome.title.3:24644")`. Auto-localizable later.

**Option 2 (when no String Catalog)**: a single `Strings.swift` enum:

```swift
enum Strings {
    enum Welcome {
        static let title = "Secure All Accounts"               // Figma node 3:24644
        static let body = "Add an extra layer of security..."  // Figma node 3:24645
        static let cta  = "Continue"                           // Figma node I3:24648;109:3976
    }
    // ...
}
```

**Hard rule from this point onward**: every `Text(...)` literal in a generated view file MUST be either:
- a String Catalog key, OR
- a `Strings.<Screen>.<key>` reference, OR
- dynamic data from a model (`token.serviceName`, etc.)

Inline English literals (`Text("Continue")`, `Text("Welcome")`) in view files are **banned** by C3 Pass 1 review. They indicate the agent invented copy or duplicated it from memory instead of from Figma.

### Step B0b — Token codegen (mandatory before any view code)

**Fast path (recommended):** run `scripts/b0b-tokens-codegen.sh --tokens .figma-cache/_shared/tokens.json --xcassets <Assets.xcassets> --out <project>/DesignSystem/`. One call emits all four artifacts: dual-mode colorsets (delegating to `colorset-codegen.sh`), `Color+Tokens.swift` (light-only), `AppFont.swift` (typography with separate `*LineSpacing` / `*Tracking` constants), and `Spacing.swift` (only emits cases that exist in tokens.json — no synthetic 8pt grid). All generated files are `parse`-clean. The hand-rolled steps below are kept as the explicit form when the script can't run (e.g. agent in a sandbox without bash).

Read `tokens.json` (from A3 `figma_extract_tokens`). Generate **read-only** Swift token files in the project's `DesignSystem/` directory. Files are auto-generated; never edit by hand:

1. **Color tokens** — split by mode coverage:

   **1a. Dual-mode tokens (`lightHex` AND `darkHex` both present in `tokens.json`)** — emit Asset Catalog colorsets via:
   ```bash
   scripts/colorset-codegen.sh .figma-cache/_shared/tokens.json <Assets.xcassets> Colors
   ```
   Each token becomes `<Assets.xcassets>/Colors/<swiftName>.colorset/Contents.json` with universal (light) + dark appearances. The `Colors/` group is written with `provides-namespace: false` so Xcode auto-generates a flat `ColorResource` symbol — use `Color(.<swiftName>)` in views (iOS 17+ type-safe symbol, always available on the Xcode 15+ baseline). Xcode auto-adapts to the user's appearance setting. This avoids manual `@Environment(\.colorScheme)` branching and prevents the common "dark mode lệch" failure. The legacy string form `Color("<swiftName>")` is BANNED.

   **1b. Light-only tokens (`darkHex` is null)** — emit `DesignSystem/Color+Tokens.swift` with one Color extension per token:

   ```swift
   extension Color {
       static let lightText900 = Color(red: 0x1A/255, green: 0x1A/255, blue: 0x1A/255)  // Figma: Light/Text/900
       // ...
   }
   ```

   The colorset script skips light-only tokens (it only emits dual-mode entries), so the two outputs never collide. Use `Color.lightText900` for these.

2. **`DesignSystem/AppFont.swift`** — one static method per Figma typography token. Source: `tokens.json.typography[]` (MCPFigma 0.3.0+ — emitted by `figma_extract_tokens` from Figma's `/styles` + `/nodes` text styles). Each entry carries `fontFamily / fontPostScriptName / fontWeight / fontSize / lineHeightPx / letterSpacing / textCase / textAlignHorizontal / italic` (verified against `Sources/MCPFigmaCore/Domain/TextStyleExtractor.swift`). Do NOT consolidate fonts ("close enough"); preserve every distinct token.

   **Skip this step for Ikame projects** (`c1-conventions.json.usesIKFont == true`). Per `references/fonts-styling-bridge.md` §3, B0b does NOT emit `AppFont.swift` for Ikame — the `ikFont` preset family (`.ikLargeTitle()`, `.ikBody()`, etc.) is already part of IKCoreApp. Call sites use the preset directly when `(fontSize, lineHeightPx)` matches a preset row, or `ikFont(<size>, weight:)` escape hatch when off-token. The block below describes the non-Ikame codegen path.

   **Note on `textAlignHorizontal`.** It IS in `tokens.json` per typography style, but it is the *shared-style default* (pulled from `/v1/files/<key>/styles` — the typography style's own definition), NOT a property of the font itself. A Text node in a specific screen can override alignment locally without re-defining the style. So **do NOT bake `.multilineTextAlignment(...)` into `AppFont.<token>()`** — alignment lives at the call site. When emitting a `Text(...)`, read the **node's own** `textAlignHorizontal` from `design-context.md` JSX classes (`text-left|center|right|justify`) first; fall back to `tokens.json.typography[<token>].textAlignHorizontal` only if the node has no explicit override. (`textAlignVertical` is NOT extracted by MCPFigma 0.3.0 — if needed, parse from `design-context.md` or treat as TOP default.)

   ```swift
   enum AppFont {
       /// Figma: Heading 3 — SFProRounded-Bold 28 / lh 34 / tracking -0.56
       static func heading3() -> Font {
           Font.custom("SFProRounded-Bold", size: 28)
       }
       static let heading3LineSpacing: CGFloat = 34 - 28      // lineHeightPx − fontSize
       static let heading3Tracking:    CGFloat = -0.56

       /// Figma: Body 18 — SFProRounded-Regular 18 / lh 30
       static func body18() -> Font {
           Font.custom("SFProRounded-Regular", size: 18)
       }
       static let body18LineSpacing: CGFloat = 30 - 18
       // ...
   }
   ```

   Apply to text views:
   ```swift
   Text(Strings.Welcome.title)
       .font(AppFont.heading3())
       .lineSpacing(AppFont.heading3LineSpacing)
       .tracking(AppFont.heading3Tracking)
   ```

   If `tokens.json.typography[]` is empty **AND** `tokens.json.warnings[]` shows the section ran cleanly (HTTP 200, just no shared styles), fall back to the inline `## These styles are contained in the design` block of `design-context.md`. Empty + non-empty `warnings` from the typography pass = degrade gracefully and surface to the user. **403 / 401 from the typography pass is NOT a fallback case** — STOP, ask the user to fix token scope. Typography reads `/v1/files/<key>/styles` which has no plan-gated scope (unlike Variables), so the plan-limit-fallback exception in §"MCPFigma edge cases" does NOT apply to typography 403s.

3. **`DesignSystem/Spacing.swift`** — only emit cases that actually appear in tokens. Do NOT add a generic 8pt grid (`xxs/xs/s/m/l/xl…`) unless those literal values exist in `tokens.json`.

**Hard rule from this point onward**: every `Color(...)`, `.font(...)`, padding/spacing literal in a generated view file MUST come from these enums OR carry an explicit `// Figma: <node-id>` comment justifying the inline value (rare — typically one-off layout positions). Made-up tokens (`surfaceCard`, `textTertiary`, `cardGap` without a Figma source) are **banned** by C3 Pass 1 review.

If `tokens.json` has empty `colors[]` **and** the run reported HTTP 200 (warnings non-empty, errors empty) → fall back to inline tokens parsed from `design-context.md`'s "These styles are contained in the design: …" block. Never invent. **Plan-limit 403 sub-case** — if the run reported HTTP 403 with Figma's message containing the exact substring `"requires the file_variables:read scope"`, the plan-limit fallback applies (see §"MCPFigma edge cases" — disclosure protocol mandatory). If `tokens.json` is **missing entirely** OR the run reported `forbidden` / `unauthorized` for any other reason (different 403 message, or 401) → **STOP**, do NOT invent and do NOT fall back; this is a token-scope or file-access issue per `references/mcpfigma-setup.md` §Troubleshooting.

### Step B0 — Read registry, pin asset catalog

The `registry.json` written in A2 already contains everything the old Step B0 probed for: `taggedAssets[]`, `lottiePlaceholders[]`, naming `warnings[]`. No second probe.

1. **Surface designer warnings** from `registry.warnings` to the user once at the end of Phase B (e.g. `eIChome` lowercase → falls back to fallback path; user fixes name in Figma to use the MCPFigma fast path).

2. **Pin `assetCatalogPath`** for this run (project-specific judgment, not in the tool):
   - 0 `.xcassets` in project → ask user to create one before continuing.
   - 1 `.xcassets` → silent default, tell user which one.
   - N > 1 → interactive prompt; stash answer in `manifest.assetCatalogPath`.

   On Phase B re-run, prefer the previously stashed value.

### Step B1 — Inventory (visual-first)

Open `screenshot.png` and **list every visible non-text element**. Cross-reference three sources:
1. Visual scan of `screenshot.png` (ground truth — start here)
2. `design-context.md`: `<img>` URLs, inline `<svg>`, `imageRef`, `background-image`
3. `metadata.json`: nodes of type `VECTOR`, `BOOLEAN_OPERATION`, `INSTANCE`; names with `icon`, `ic_`, `logo`, `illustration`

Build the inventory table (with `registry.taggedAssets[]` and `registry.lottiePlaceholders[]` in mind):

| # | Purpose | NodeId | Exporter | Strategy | exportName / friendlyName / lottieName |
|---|---|---|---|---|---|
| 1 | Close icon | 3166:70211 | tagged | atomic | icAIClose |
| 2 | Hero illustration | 3166:70200 | fallback | flatten | heroArtwork |
| 3 | Facebook logo | 3166:70250 | tagged | atomic | icAIFacebook |
| 4 | Decorative blob | 3166:70260 | fallback | atomic | logoBlob |
| 5 | Loading animation | 3166:71000 | fallback | lottiePlaceholder | placeholder_animation |

**Cross-reference rule (run after building the visual rows):**
- For every visual row whose `nodeId` matches a `registry.taggedAssets[]` entry → set `exporter = "tagged"`, `exportName = entry.exportName`.
- For every visual row whose `nodeId` matches a `registry.lottiePlaceholders[]` entry → set `strategy = "lottiePlaceholder"`, `lottieName = "placeholder_animation"`. **No PNG, no xcassets entry.** See `references/lottie-placeholders.md`.
- Else → `exporter = "fallback"`, set `friendlyName` per the §6 naming rules in `references/asset-handling.md`.
- Then walk both lists the other direction: for every tagged asset OR Lottie placeholder in registry whose nodeId is **not** in the visual inventory → **STOP, ask the user**. Either the designer tagged a node the screenshot doesn't visibly contain (designer/inventory drift), or your visual scan missed it. Both are bugs.

**Hard rules:**
- Every visible non-text element → one row.
- A visible icon you cannot find a nodeId for → **STOP, ask the user**, do not skip.
- Empty inventory on a screen that visibly has icons/logos → bug, re-scan.
- A tagged node sitting inside a flattened parent region → keep the tagged row (will export through tagged path). The flattened parent still exports as a fallback row. The result is a duplicated visual atom (once inside the flatten PNG, once as a standalone tagged asset), which is fine — only one is referenced from SwiftUI. To override, the user explicitly says "skip tagged path for this node" — set `exporter = "fallback"` on that row.

### Step B2 — Classify (flatten / decompose / code)

Per region:
- **FLATTEN** (one fallback row whose nodeId is the region root): composed artwork, layered scene, artistic effects, static content. If a tagged node sits inside the flattened parent, keep its own tagged row — see B1 cross-reference rule.
- **DECOMPOSE** (atomic rows, one per icon): icon rows, grids, interactive/dynamic content.
- **CODE** (SwiftUI shapes, no row at all): only for trivial primitives — rect, circle, gradient, blur material. **Not for icons.**
- **MIXED**: flatten artwork sub-frame as a fallback row, overlay interactive UI in ZStack at code time.
- **LOTTIE-PLACEHOLDER**: registry already pre-classified these. Inventory row uses `strategy: "lottiePlaceholder"`. See `references/lottie-placeholders.md`.

Heuristic: "the hero illustration" (1 thing) → flatten; "a row of action icons" (N things) → decompose. **Doubt → flatten.** Never reassemble composed artwork with `.offset()`. Rules: `references/asset-handling.md` §1a.

### Step B3 — Unified export (one call)

**If you used the A3+ pipeline above:** B3 already ran in the A3 parallel batch and `manifest.json` is on disk. Skip the call here and jump directly to the cross-validation step at the end of this section. The cross-validation supplementary call (when needed) uses the row schema below — same shape, just one row at a time.

**Otherwise** (sequential path), send the inventory to `figma_export_assets_unified`:

```
figma_export_assets_unified(
  fileKey          = <fileKey>,
  nodeId           = <root nodeId>,
  outputDir        = ".figma-cache/<nodeId>/assets",
  sharedAssetsDir  = ".figma-cache/_shared/assets",
  assetCatalogPath = <pinned in B0>,
  rows = [
    { nodeId: "3166:70211", exporter: "tagged",   exportName: "icAIClose" },
    { nodeId: "3166:70200", exporter: "fallback", friendlyName: "heroArtwork", strategy: "flatten" },
    { nodeId: "3166:71000", exporter: "fallback", friendlyName: "placeholder_animation", strategy: "lottiePlaceholder" }
  ]
)
```

The tool absorbs everything that used to be skill prose:
- Tagged batch render (@2x, @3x), naming, xcassets imageset write, screen-folder grouping.
- Fallback batch render (scale 3 by default) → PNG-signature validation → dedup into `sharedAssetsDir`.
- Tagged row that errors → automatically promoted to fallback path; final row reports `exporter: "fallback"` with both reasons.
- Lottie rows pass through with `status: "done"` and no PNG.
- `skipIfExistsInCatalog` defaults to true, so re-runs are cheap.

**Persist the response** as the manifest. Write the response (plus any extra metadata you carry — display size, rendering mode, etc.) to `.figma-cache/<nodeId>/manifest.json`. Do NOT add a second source of truth for asset state.

Example manifest after merge with display info:

```json
{
  "fileKey": "abc",
  "nodeId":  "3166:70147",
  "phaseA": "done",
  "phaseB": "done",
  "assetCatalogPath": "/Users/me/Project/App/Assets.xcassets",
  "rows": [
    {
      "nodeId": "3166:70211",
      "exporter": "tagged",
      "strategy": "atomic",
      "status": "done",
      "exportName": "icAIClose",
      "outputPath": ".figma-cache/3166:70147/assets/_mcpfigma/icAIClose@3x.png",
      "imagesetPath": "/Users/me/Project/App/Assets.xcassets/Welcome/icAIClose.imageset",
      "xcassetsImported": true,
      "displaySize": "24x24",
      "renderingMode": "template"
    },
    {
      "nodeId": "3166:70200",
      "exporter": "fallback",
      "strategy": "flatten",
      "status": "done",
      "friendlyName": "heroArtwork",
      "sharedPath": ".figma-cache/_shared/assets/3166_70200.png",
      "displaySize": "fill x 240",
      "renderingMode": "original"
    },
    {
      "nodeId": "3166:71000",
      "exporter": "fallback",
      "strategy": "lottiePlaceholder",
      "status": "done",
      "friendlyName": "placeholder_animation",
      "displaySize": "120x120"
    }
  ],
  "warnings": []
}
```

Key notes:
- `xcassetsImported: true` on a row → C4 must NOT re-run sips/imageset/Contents.json for that asset.
- Each `nodeId` appears exactly once — auto-promotion happens inside the tool, the row just reports its final `exporter` value.
- A row with `status: "failed"` → tell the user the `reason`, do not silently drop. Re-run after fixing the cause.

**Resume on partial failure (mandatory).** If a previous `figma_export_assets_unified` call left some rows `failed` (network blip, transient 5xx), do **NOT** resubmit the full row list. Read `manifest.rows[].status` and rebuild the `rows` argument from only `status != "done"` entries (`failed`, plus any not yet attempted). The tool's per-row dedup + `skipIfExistsInCatalog: true` would silently skip already-imported imagesets, but resubmitting wastes round trips and blows the call budget on flows of 30+ assets. Pseudocode:

```python
m = json.load(open(".figma-cache/<nodeId>/manifest.json"))
done    = {r["nodeId"] for r in m.get("rows", []) if r.get("status") == "done"}
pending = [orig_row for orig_row in original_rows if orig_row["nodeId"] not in done]
# resubmit only `pending`; merge new results back into manifest.rows by nodeId
```

Idempotency contract: every row must keep its original `exporter` / `strategy` / `exportName` on resubmit so the merged manifest stays consistent. If you change those fields between attempts, treat it as a fresh row (full resubmit) and clear the old entry.

### Gate B — Phase B Exit (BASH, mandatory and STRICT)

You MUST run this. If it does not print `GATE: PASS`, you may NOT write any `.swift` file. Improvising assets is a hard violation.

```bash
CACHE=".figma-cache/<nodeId>"
FAIL=0
[ -s "$CACHE/manifest.json" ] && echo "PASS: manifest" || { echo "FAIL: manifest"; FAIL=1; }

# No row may be in failed status
FAILED=$(python3 -c "
import json
m = json.load(open('$CACHE/manifest.json'))
for r in m.get('rows', []):
    if r.get('status') == 'failed':
        print(r.get('nodeId'), '-', r.get('reason') or '?')
")
[ -z "$FAILED" ] && echo "PASS: no failed rows" || { echo "FAIL: failed rows:"; echo \"$FAILED\"; FAIL=1; }

# Coverage: registry tagged + lottie must all appear in manifest rows
UNCOVERED=$(python3 -c "
import json
reg = json.load(open('$CACHE/registry.json'))
needed = {a['nodeId'] for a in reg.get('taggedAssets', [])}
needed |= {p['nodeId'] for p in reg.get('lottiePlaceholders', [])}
present = {r.get('nodeId') for r in json.load(open('$CACHE/manifest.json')).get('rows', [])}
for nid in sorted(needed - present):
    print('UNCOVERED:', nid)
")
[ -z "$UNCOVERED" ] && echo "PASS: registry coverage" || { echo "FAIL: $UNCOVERED"; FAIL=1; }

# Coverage: visual hints in design-context demand at least 1 row when present
ROW_COUNT=$(python3 -c "import json; print(len(json.load(open('$CACHE/manifest.json')).get('rows',[])))")
ICON_HINTS=$(grep -ciE 'icon|logo|illustration|<img|<svg|VECTOR|BOOLEAN_OPERATION' "$CACHE/design-context.md" "$CACHE/metadata.json" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')
if [ "${ROW_COUNT:-0}" -eq 0 ] && [ "${ICON_HINTS:-0}" -gt 0 ]; then
  echo "FAIL: rows empty but design has $ICON_HINTS hints — re-run Step B1 inventory"; FAIL=1
else
  echo "PASS: rows ($ROW_COUNT entries)"
fi

# Files on disk for every non-Lottie row
MISSING=$(python3 -c "
import json, os
m = json.load(open('$CACHE/manifest.json'))
for r in m.get('rows', []):
    if r.get('strategy') == 'lottiePlaceholder': continue
    paths = [r.get('outputPath',''), r.get('sharedPath','')]
    if not any(p and os.path.exists(p) for p in paths):
        print('MISSING:', r.get('exportName') or r.get('friendlyName') or r.get('nodeId'))
")
[ -z "$MISSING" ] && echo "PASS: all assets on disk" || { echo "FAIL: $MISSING"; FAIL=1; }

# Imageset check for tagged rows
BAD_IMAGESET=$(python3 -c "
import json, os
m = json.load(open('$CACHE/manifest.json'))
for r in m.get('rows', []):
    if r.get('xcassetsImported') and not os.path.isdir(r.get('imagesetPath','')):
        print('MISSING_IMAGESET:', r.get('exportName'))
")
[ -z "$BAD_IMAGESET" ] && echo "PASS: imagesets on disk" || { echo "FAIL: $BAD_IMAGESET"; FAIL=1; }

# All cached files have real PNG signatures
BAD=$(file "$CACHE/assets/"*.png \
           "$CACHE"/_shared/assets/*.png \
           "$CACHE"/assets/_mcpfigma/*.png \
           2>/dev/null | grep -v "PNG image data" | grep -v "cannot open")
[ -z "$BAD" ] && echo "PASS: assets are real PNG" || { echo "FAIL: non-PNG: $BAD"; FAIL=1; }

[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase B)" || echo "GATE: FAIL (Phase B) — DO NOT WRITE SWIFT FILES"
```

If `GATE: FAIL`: fix the cause (most often: missed inventory rows or a row whose `status: failed` reason explains the failure). Do NOT begin Phase C until this prints `GATE: PASS`.

---

# Phase C — Implement (offline from cache)

Goal: SwiftUI code that matches the screenshot pixel-for-pixel, using only assets from Phase B.

### Step C1 — Audit & Prepare

**Project pre-flight** (see `references/visual-fidelity.md` §6 + `references/swiftui-pro-bridge.md` §3):
1. iOS deployment target → which SwiftUI APIs available. Read `IPHONEOS_DEPLOYMENT_TARGET` from `pbxproj`. Project baseline is **iOS 16+** — see `references/swiftui-pro-bridge.md` §6 for the iOS 16 fallback table that gates many swiftui-pro rules.
2. `Color(hex:)` extension — grep; if absent, use Asset Catalog / `Color(red:green:blue:)`
3. Localization — check `.strings`/`.xcstrings`. Project baseline is **`Localizable.xcstrings`**. If `STRING_CATALOG_GENERATE_SYMBOLS = YES`, set flag `useStringCatalogSymbols = true` → C2 emits `Text(.symbolKey)` and offers to translate new keys. Else use `LocalizedStringKey` literal form.
4. Dark mode scope — if Figma light-only, ask user
5. **Generated symbol assets** (swiftui-pro/api.md L14) — grep `pbxproj` for `GENERATE_ASSET_SYMBOLS = YES` (default-on for Xcode 15+; the skill's Xcode 26+ baseline is always-on, so `useGeneratedSymbols = true` is the canonical case). C2 ALWAYS emits `Image(.icAIClose)` / `Color(.brandRed)` (iOS 17+ auto-generated `ImageResource` / `ColorResource`). The legacy string form `Image("icAIClose")` / `Color("brandRed")` is BANNED — only ever surfaced when the project explicitly sets `GENERATE_ASSET_SYMBOLS = NO`, which the skill flags on the run summary as a non-modern project.
6. **Design constants — fonts, spacing, colors.**
   - **Fonts**: for Ikame projects, fonts use the `ikFont` family directly from IKCoreApp (no project-level font enum). Grep for usage form: `grep -rln "\.ikFont\|\.ikBody\|\.ikLargeTitle\|\.appFont\|\.appFontHeading" --include="*.swift" .` → set `fontModifier = "ikFont"` (canonical) or `"appFont"` (brownfield wrapper). Also capture `fontFamily` from `IKFontSystem.shared.configure(familyName:)` call. Additional families: list any `<Family>+Ext.swift` files under `Utilities/Extensions/`. See `references/fonts-styling-bridge.md` §1.
   - **Spacing**: grep for `enum \(Spacing\|AppSpacing\|Padding\)\b` — set `spacingEnum`. List cases.
   - **Colors**: Asset Catalog colorset symbols are the canonical reference (`Color(.<name>)`). Also detect any `Color.<name>` static-var extensions in `DesignSystem/Color+Tokens.swift` or similar. Grep: `grep -rln "extension Color\b" --include="*.swift" .` and inspect for `static let <name>: Color`.
   C2 routes Figma values through `ikFont` preset family (Ikame) or `<spacingEnum>.<token>` (when set) per `references/swiftui-pro-bridge.md` §3 and `references/fonts-styling-bridge.md` §2.
7. **Lottie SDK** — grep `import Lottie` or `Package.resolved` for `lottie-ios`. If present → flag `hasLottieSDK = true`; eAnim* placeholders codegen `LottieView`. Else warn user before C2 starts (see `references/lottie-placeholders.md` §9).
8. **swiftui-pro snapshot present** — confirm `references/swiftui-pro/SOURCE.md` exists. Skill MUST read at minimum `references/swiftui-pro/api.md`, `views.md`, `data.md`, `accessibility.md` before C2; full set on demand. Bridge: `references/swiftui-pro-bridge.md`.
9. **Project color audit (mandatory).** Run:
   ```bash
   scripts/c1-project-color-audit.sh <project-root> .figma-cache/_shared/project-colors.json
   ```
   Emits a `{hex, swiftPath, source, lightHex, darkHex}` map of every color already in the project (Asset Catalog colorsets + `Color.<name>` extensions + `Color(hex:)` literals). C2 routing prefers this map over inventing new tokens: when a Figma hex matches a project entry, codegen `<swiftPath>` directly. Without the audit the agent eyeballs the project, misses matches, and emits parallel tokens that drift over time.
10. **Coding-conventions probe (mandatory).** **Fast path:** run `scripts/c1-probe.sh --project <project-root> --output .figma-cache/<nodeId>/c1-conventions.json` — one call emits the full JSON described below (folder layout, ViewModel pattern, deployment target, IKNavigation/IKMacros detection, token enums, xcstrings/xcassets paths, generated-symbols flags). Re-invoke with `--asset-catalog <path>` when the project has multiple `.xcassets`. The hand-rolled detector list below is the explicit form. See [`references/adaptation-workflow.md` §0](references/adaptation-workflow.md#0-convention-probe-mandatory-run-before-the-audit) for the full procedure. Detect:
    - **Folder layout** — `one-screen-per-folder` (canonical Ikame and non-Ikame; `Screens/<X>/<X>Screen.swift` co-located with `<X>ViewModel.swift`) vs `ikame-feature-flat` (brownfield: `Screens/<Feature>/<Feature>HomeScreen.swift` + `Screens/<Feature>/ViewModel/`) vs `flat`. See [`references/project-structure.md` §1](references/project-structure.md#1-detection-c1-audit) for detection rules.
    - **ViewModel pattern** — `state-action-reducer` vs `ad-hoc` vs `none` (grep latest `*ViewModel.swift` for `enum Action` + `func send(_:)`); for Ikame projects also capture `viewToRouteWiring`: `"publishedRoute"` (canonical `@Published var route`) vs `"routePublisher"` (brownfield Combine subject).
    - **Observation flavor** — `observable` (iOS 17+ + `@Observable`) vs `observable-object` (iOS 16+ default). Ikame projects are locked to `observable-object` regardless of deployment target (`ikame-decision-table.md` D-301).
    - **IKNavigation** — see [`references/iknavigation-bridge.md` §1](references/iknavigation-bridge.md#1-detection-c1-audit). Cache `usesIKNavigation`, `routers[]` (per-feature router list), `routerLayout` (`"per-feature"` canonical / `"single"` brownfield).
    - **IKMacros** — see [`references/ikmacro-bridge.md` §1](references/ikmacro-bridge.md#1-detection-c1-audit). Cache `usesIKMacros`, `apiRegistry` (`registryEnumName`, `registryFilePath`, `sharedRepoExpr`).
    - **IKPopup** — see [`references/ikpopup-bridge.md` §1](references/ikpopup-bridge.md#1-detection-c1-audit). Cache `usesIKPopup`, `popupConfigurations[]`, `popupInvocationStyle` (`"closure"` canonical / `"namedArgs"` brownfield).
    - **IKFeedback** — see [`references/ikfeedback-bridge.md` §1](references/ikfeedback-bridge.md#1-detection-c1-audit). Cache `usesIKFeedback`, `toastApi` (`"ikToast"` canonical / `"appToastWrapper"` brownfield), `appToastWrapper.typeName` + `funcSig` when applicable.
    - **IKFont** — see [`references/fonts-styling-bridge.md` §1](references/fonts-styling-bridge.md#1-detection-c1-audit). Cache `usesIKFont`, `fontModifier` (`"ikFont"` canonical / `"appFont"` brownfield), `fontFamily`, `additionalFontFamilies[]`.
    - **xcstrings catalog path** — `find . -name '*.xcstrings'`
    - **Asset catalog path** — `find . -name '*.xcassets' -type d` (interactive prompt when multiple).

    Write everything to `.figma-cache/<nodeId>/c1-conventions.json` (single-screen) or `.figma-cache/_shared/c1-conventions.json` (flow). C2 reads this file. The c8-* gates also read it to know whether to enforce or skip.

**Print resolved flags at end of C1** so the user can verify routing decisions before any code is written:

```
useGeneratedSymbols       = <bool>
useStringCatalogSymbols   = <bool>
spacingEnum               = "Spacing" | "AppSpacing" | null  (cases: ...)
fontModifier              = "ikFont" (canonical) | "appFont" (brownfield) | null
fontFamily                = "Inter" | "SFProRounded" | <other> | null
additionalFontFamilies    = ["FiraCode", ...] | []
colorEnum                 = "IKCoreApp" | null              (cases: ...)
hasColorHexExtension      = <bool>
hasLottieSDK              = <bool>
minDeploymentTarget       = iOS <N>
observationFlavor         = observable | observable-object       (Ikame locked to observable-object)
localizationStyle         = xcstrings | strings
darkModeScope             = enabled | disabled | unspecified
projectColorMap           = .figma-cache/_shared/project-colors.json (<N> entries)
screenFolderConvention    = one-screen-per-folder (canonical) | ikame-feature-flat (brownfield) | flat
viewModelPattern          = state-action-reducer | ad-hoc | none
viewToRouteWiring         = publishedRoute (canonical) | routePublisher (brownfield Ikame)
usesIKNavigation          = <bool>     routers[] = [{name, featureSubfolder, routeEnumName}]    routerLayout = per-feature | single
usesIKMacros              = <bool>     apiRegistry = {registryEnumName, registryFilePath, sharedRepoExpr}
usesIKPopup               = <bool>     popupConfigurations = [...]    popupInvocationStyle = closure | namedArgs
usesIKFeedback            = <bool>     toastApi = ikToast | appToastWrapper    appToastWrapper = {typeName, funcSig} | null
usesIKFont                = <bool>     (see fontModifier / fontFamily / additionalFontFamilies above)
```

The full JSON is at `.figma-cache/<nodeId>/c1-conventions.json`. Both this skill and `figma-flow-to-swiftui-feature` read from this single source of truth.

**Visual Inventory (mandatory).** Follow `references/visual-fidelity.md` §1–3. Every visible element → row with source tag `[tokens|inline|class|screenshot]`. Never skip `lineHeight`, `letterSpacing`, `shadow`, `border`, `renderingMode`, **`textAlign`** (Figma `textAlignHorizontal`), **stack alignment** (Figma `counterAxisAlignItems` + `primaryAxisAlignItems` — both axes, both must be sourced from metadata, neither defaults are safe). Centered text in a fill-width row needs `.multilineTextAlignment(.center)` **AND** a fill-width drawing rect — but **place the `.frame(maxWidth: .infinity)` on the right layer**: on the Text itself when the parent is a non-Button stack; on the Button's OUTER frame when the parent is `Button { ... }`. Inner-Text maxWidth inside a Button cascades up and bloats the button — banned without `// allow-text-fill: <reason>`. See `references/visual-fidelity.md` §"Stack alignment" + §"Text" + §"`.frame(maxWidth: .infinity)` cascade trap".

### Step C1b — Adaptation Audit (if modifying existing screen)
Element-by-element ADD/UPDATE/REMOVE diff, user review before coding. See `references/adaptation-workflow.md`.

### Step C2 — Implement

**Reuse order:**
1. Code Connect mapped component → 2. Shared design-system component → 3. Nearby feature component → 4. Existing modifier/style/token → 5. New (only if nothing fits)

**Build order (outside-in):**
1. Outermost container, safe-area, background
2. Primary stack (VStack/HStack/ZStack/ScrollView) — explicit `spacing:` and alignment
3. Sections top-to-bottom, following inventory order
4. Text & icons per section — font, lineSpacing, tracking, color, renderingMode, tint
5. Backgrounds, borders, shadows, corner radius — watch `.background` vs `.padding` order (see `references/layout-translation.md`)
6. Effects (blur, mask, blend) — last
7. Interactions — `.buttonStyle(.plain)` for custom, navigation

**Critical rules:**
- MCP output = spec, not code. Parse values (see `references/visual-fidelity.md` §1), build native SwiftUI.
- **Xcode-MCP-first file writes (when xcode MCP available, STRONGLY PREFERRED — default path on Xcode 26+).** Use the xcode MCP file family for creating, editing, moving, and reading Swift files in the target project — it auto-adds new files to the `.xcodeproj` target membership, eliminating the manual `xcodeproj-add-files.sh` Ruby-gem post-step. Probe with `bash scripts/c5-engine-select.sh` (Engine A = xcode MCP path). Tool mapping:
  - **New file** → `mcp__xcode__XcodeWrite` (creates file + adds to project + sets `<group>` source tree) instead of vanilla `Write`. Pass the project-relative path (e.g. `MyApp/Screens/Splash/SplashScreen.swift`), not absolute filesystem path.
  - **Edit existing file** → `mcp__xcode__XcodeUpdate` (uses literal string match, similar contract to vanilla `Edit`) instead of `Edit`.
  - **Read existing file in target** → `mcp__xcode__XcodeRead` (returns content in `cat -n` form) instead of vanilla `Read` — beware double escaping (`\\d` shown as `\\\\d` in JSON; use literal `\d` when writing).
  - **Move / rename / delete** → `mcp__xcode__XcodeMV` / `mcp__xcode__XcodeRM` (updates project navigator + file system in one call).
  - **Make a folder/group** → `mcp__xcode__XcodeMakeDir` (creates filesystem dir + adds as PBXGroup in the project navigator).
  - **List project files** → `mcp__xcode__XcodeGlob` / `mcp__xcode__XcodeLS` (respects project organization rather than raw filesystem).
  - **Tab identifier** — `mcp__xcode__XcodeListWindows` first to discover the workspace tab id; reuse for every subsequent file call.

  **Fallback to vanilla `Write/Edit`** ONLY when:
  - `c5-engine-select.sh` reports `engine: "xcodebuild"` (mcpbridge missing or Xcode not running), OR
  - The project uses Xcode 16+ synchronized folders (`PBXFileSystemSynchronizedRootGroup`) — files dropped on disk under the synchronized folder are auto-included by Xcode itself, so vanilla `Write` already does the right thing. `scripts/xcodeproj-add-files.sh` detects this and exits as a no-op; the same applies when you skip the Ruby step entirely. Modern `ikxcodegen` scaffolds fall into this category.

  **Banned:** writing a Swift file with vanilla `Write` then forgetting to update the `.xcodeproj` and relying on the user to "Add Files to..." in Xcode. The file compiles in the Xcode index but disappears at archive time. The xcode MCP path makes this impossible by construction.
- **Write-time compile-error catch (when xcode MCP available, RECOMMENDED).** After every `Write/Edit` of a `.swift` file (whether via `XcodeWrite` or vanilla `Write`), immediately call `mcp__xcode__XcodeRefreshCodeIssuesInFile` on the file path. The MCP returns structured Swift compiler diagnostics (errors + warnings + notes) for that file using the live Xcode index — orders of magnitude faster than waiting for `xcodebuild build` in C5. Fix every error before writing the next file. Workflow shifts compile-error discovery from **C5.3 build (~60-180s wait)** to **post-Write (sub-second)**, eliminating one or more full self-fix-loop attempts on average. When the xcode MCP is not available, this step is silently skipped — C5.3 still catches everything, just later. Do NOT batch this — the cost of one extra MCP call per file is negligible compared to one extra xcodebuild round.
- **Token usage.** `tokens.json` (from `figma_extract_tokens` in A3) already has `swiftName`, `lightHex`, `darkHex`, `isCapsule`. Use those directly — do NOT re-derive names from Figma slash strings. Then merge with project enums (`Spacing`, `IKFont`, `IKCoreApp`) per the routing rules below: prefer existing enum case → fallback to extracted token → inline literal as last resort.
- **`isCapsule` → `Capsule()` (hard rule).** For any radius/spacing token with `isCapsule: true` in `tokens.json`, codegen `.clipShape(Capsule())` (and `Capsule()` for fills/backgrounds/overlays) — never `.cornerRadius(9999)` or `RoundedRectangle(cornerRadius: 9999)`. Magic-number 9999 renders correctly only when width ≈ height; pills wider than tall flatten the ends. See `references/design-token-mapping.md` §"Border Radius Tokens".
- **Dual-mode colors → Asset Catalog.** Run `scripts/colorset-codegen.sh .figma-cache/_shared/tokens.json <Assets.xcassets> Colors` to emit colorsets for every token with both `lightHex` and `darkHex`; reference them via `Color(.<swiftName>)` (iOS 17+ auto-generated `ColorResource` — the `Colors/` group is written with `provides-namespace: false` so the symbol resolves flat). Light-only tokens stay as `Color.<swiftName>` static-var extensions in `DesignSystem/Color+Tokens.swift` (callable Apple-style without parentheses). Never hand-write the colorset JSON. Never the legacy string form `Color("<swiftName>")`.
- `Text` → `LocalizedStringKey`; `Text(verbatim:)` for dynamic data.
- `Color(hex:)` only if project has the extension; else Asset Catalog or `Color(red:green:blue:)`.
- Respect iOS deployment target — don't use iOS 17+ APIs if target lower.
- Don't draw iOS system chrome (status bar, Dynamic Island, home indicator, system keyboard, system nav back, system `TabView` bar, pull-to-refresh). See the **ABSOLUTE RULE — Do NOT draw iOS system chrome** section near the top.
- **Use Figma assets only.** Every `Image(...)` must reference an asset downloaded in Phase B. `Image(systemName:)` is BANNED for Figma-designed icons. Drawing logos from `Text("G")` or colored `Rectangle()` is BANNED. If an asset is missing, STOP and re-run Phase B, never improvise.
- **Lottie placeholders.** For every manifest row with `strategy: "lottiePlaceholder"`, emit a `LottieView` stub in place of an asset, using the `lottie-ios` (Airbnb) SwiftUI API. Do NOT substitute with `Image(systemName:)`, do NOT draw a static frame from the children of the `eAnim*` node. See `references/lottie-placeholders.md` §6 for the exact code template. Add `import Lottie` once per file. The placeholder name is always the literal `"placeholder_animation"` — do not derive from the Figma name. Append a `// TODO:` comment instructing the developer to replace the name.
- **swiftui-pro standards (write-time, MANDATORY).** All emitted SwiftUI must comply with the snapshot in `references/swiftui-pro/`. The 23-row always-on transform table in `references/swiftui-pro-bridge.md` §2 is non-negotiable on every project, every emit:
  - `.bold()` not `.fontWeight(.bold)`; `.foregroundStyle()` not `.foregroundColor()`.
  - `Image(decorative:)` for decorative Figma images; `.accessibilityLabel("…")` on every meaningful icon (derive label from semantic Figma name: `eICClose` → `"Close"`).
  - Icon-only `Button` → `Button("Label", systemImage: …, action: …)` form OR custom label + `.accessibilityLabel`. Never bare image-only without a label.
  - Tap targets < 44pt → wrap with `.contentShape(.rect).frame(minWidth: 44, minHeight: 44)`.
  - `#Preview` macro, never `PreviewProvider`. **Mandatory** — every emitted `<Name>Screen.swift` MUST end with a `#Preview { … }` block that builds the screen with mock state (e.g. `<Name>Screen(viewModel: <Name>ViewModel())` plus any required dependency stubs). C5 Engine A (xcode MCP RenderPreview) targets this `#Preview` directly — without it, the agent falls back to the slower xcodebuild/simctl path and the user pays the SPM-resolve hang penalty. If the screen has external dependencies (network, persistence) that can't be mocked inline, build a `#Preview { … }` with placeholder data + a `// preview: <reason>` comment.
  - Conditional modifier toggle by ternary, never `if/else` view branching.
  - Animations always carry a `value:` parameter.
  - `NavigationStack` + `.navigationDestination(for:)`; never `NavigationView` or `NavigationLink(destination:)`. **For Ikame projects** (`usesIKNavigation == true`), see `references/iknavigation-bridge.md` §3 — root-level `NavigationStack` is owned by IKNavigation; use state-driven `.navigationDestination(item: $viewModel.route)` Style A or imperative `navigation.push(to:)` Style B; `.navigationDestination(for: <Type>.self)` is banned.
  - No `Text` concatenation with `+`; use interpolation.
  - `.onTapGesture` only when you need tap location/count; otherwise `Button`.
- **iOS 16 baseline fallbacks (MANDATORY).** Project baseline is iOS 16+. Several swiftui-pro rules target iOS 17/18/26 and MUST be conditionally rewritten on iOS 16. Full table: `references/swiftui-pro-bridge.md` §6. Examples: `.clipShape(RoundedRectangle(cornerRadius: 12))` (not `.rect(cornerRadius:)`), `.navigationBarLeading` (not `.topBarLeading`), `tabItem { Label(…) }` (not `Tab(…)`), `ObservableObject` + `@StateObject` (not `@Observable` + `@Bindable`). Always emit comment marker `// iOS 16 fallback — switch to <modern API> at iOS <N>+` so future bumps are search-replaceable.
- **Project token routing (MANDATORY when audit flags set).** Read `c1-conventions.json` for the actual enum names (`spacingEnum`, `colorEnum` — may be `null` when absent) and font modifier (`fontModifier` — `"ikFont"` canonical for Ikame, `"appFont"` brownfield wrapper, or null for non-Ikame projects with `AppFont.swift` generated by B0b). Route Figma values per `references/swiftui-pro-bridge.md` §3 + `references/fonts-styling-bridge.md` §2:
  - Spacing/padding/gap → `<spacingEnum>.<token>` first; fall back inline literal when no token matches OR when `spacingEnum == null`.
  - Typography (Ikame, `fontModifier == "ikFont"`) → `.ik<Preset>(weight:)` when `(fontSize, lineHeightPx)` matches a preset row; `.ikFont(<size>, weight:)` escape hatch when off-token; `.<family>(<size>, weight:)` per-family helper when Figma uses a non-project family. Typography (brownfield, `fontModifier == "appFont"`) → `.appFont<Preset>()` / `.appFont(<size>, weight:)`. Typography (non-Ikame) → `AppFont.<token>()` from B0b-generated wrapper.
  - Top-level app values → `<colorEnum>.colors.*`, `<colorEnum>.spacing.*` when present.
  - Never invent new enum cases; surface mismatches in the run summary instead.
- **Coding conventions (MANDATORY, governed by `c1-conventions.json`).** All emitted Swift files conform to the project's detected conventions. Read each reference once before C2 starts:
  - **Folder layout & file naming** — [`references/project-structure.md`](references/project-structure.md). Canonical Ikame and non-Ikame layout: `screenFolderConvention = "one-screen-per-folder"` — new screen at `Screens/<Name>/<Name>Screen.swift` + `Screens/<Name>/<Name>ViewModel.swift`; subviews/models/enums prefixed with screen name under per-screen folder. Brownfield Ikame projects with feature-flat layout (`screenFolderConvention = "ikame-feature-flat"`) follow legacy `Screens/<Feature>/<Feature>HomeScreen.swift` pattern — see project-structure.md §3. Enforced by `scripts/c8-conventions-gate.sh`.
  - **ViewModel shape** — [`references/viewmodel-pattern.md`](references/viewmodel-pattern.md). Every ViewModel: `@MainActor` + `final class` + nested `enum Action` + `func send(_ action: Action)` reducer + flat `@Published` state + nested `enum Route` if the screen navigates. iOS 17+ projects with `observationFlavor = "observable"` get the `@Observable` variant. Enforced by `scripts/c8-vm-pattern.sh`.
  - **Function & view size** — [`references/swift-style.md`](references/swift-style.md) §2-3. Functions ≤ 50 lines (hard); subview structs ≤ 50 lines. Enforced by `scripts/c8-func-length.sh`.
  - **Golden path** — [`references/swift-style.md`](references/swift-style.md) §4. `guard` + early return; nesting depth ≤ 1 level for happy-path body.
  - **Modifier order** — [`references/swift-style.md`](references/swift-style.md) §11. Typography → Layout → Decoration → Effect → Interaction → State/Lifecycle → Presentation → Environment.
  - **Memory** — [`references/swift-style.md`](references/swift-style.md) §6. `[weak self]` in escaping closures (Combine sinks, URLSession callbacks, custom-callback APIs). `Task` inside `@MainActor` reducer is exempt.
  - **Error handling** — [`references/swift-style.md`](references/swift-style.md) §9. Per-domain `Error` enum, catch case-by-case; never `catch { errorMessage = error.localizedDescription }`.
  - **IKNavigation** — when `usesIKNavigation = true`, follow [`references/iknavigation-bridge.md`](references/iknavigation-bridge.md) and `ikame-ios-coding/references/iknavigation.md`. Canonical wiring: ViewModel exposes `enum Route: Equatable, Hashable` + `@Published var route: Route?`; View binds `.navigationDestination(item: $viewModel.route)` (Style A) or, for purely-UI navigation, calls `@Environment(\.ikNavigationable)` + `navigation.push(to: .<feature>Route(.<case>))` (Style B). Banned at root: screen-level `NavigationStack(path:)`, `NavigationLink(destination:)`, `.navigationDestination(for: <Type>.self)`, `NavigationPath`. **`.navigationDestination(item:)` is NOT banned — it's the canonical Style A binding.** Extend the matching per-feature router under `Core/Router/<Feature>/`; do NOT invent a new feature router unless authorized. Enforced by `scripts/c8-iknavigation.sh`.
  - **IKMacros** — when `usesIKMacros = true` AND the run generates DTO/service code, follow [`references/ikmacro-bridge.md`](references/ikmacro-bridge.md). DTOs use `@JsonSerializable` + `@JsonKey`; services use `@APIProtocol` + `@GET`/`@POST`/etc. Inject `IKAPIRepository` via init.
- **Strict-fidelity rules (MANDATORY, banned patterns enforced by C3 Pass 1).** Every generated view file is reviewed against these:
  - **No inline string literals.** `Text("Continue")` is banned in view files. Use String Catalog keys or `Strings.<Screen>.<key>` from the B0a manifest. Exception: developer-debug screens explicitly opted out.
  - **No inline hex / RGB color literals.** `Color(red: 0x3B/255, …)` and `Color(hex: "#3B7BFD")` in views are banned. Use `Color.<token>` from the B0b-generated `Color+Tokens.swift`.
  - **No inline font sizes.** `.font(.system(size: 28, weight: .bold))` in views is banned. **For Ikame projects** (`usesIKFont == true`): use the matching `ikFont` preset (`.ikLargeTitle(weight: .bold)`) when `(fontSize, lineHeightPx)` exactly matches a preset row; use `ikFont(<size>, weight: .<weight>)` escape hatch when off-token. For additional families (Figma uses a font different from the project family), use the per-family 4-layer helper (`Text(...).firaCode(13)`). See `references/fonts-styling-bridge.md` + `ikame-ios-coding/references/fonts-and-styling.md`. **Non-Ikame projects**: use `AppFont.<token>()` from the B0b-generated `AppFont.swift`. If the screen needs a value not in tokens, STOP and ask the user — typography drift is a bug.
  - **No made-up token names.** Adding `surfaceCard`, `textTertiary`, `cardGap` (or any case) to `Color+Tokens.swift` / `Spacing.swift` without a backing entry in `tokens.json` is banned. Pass 1 review greps new enum cases against `tokens.json` and rejects mismatches.
  - **Layout values trace to Figma.** Every `padding(.<edge>, <number>)`, `frame(width: <number>)`, `.cornerRadius(<number>)` must (a) trace to a literal in `design-context.md` (Tailwind class such as `p-[16px]`, `rounded-[16px]`, `w-[343px]`) or (b) come from a `Spacing` / `CornerRadius` enum case backed by `tokens.json`. One-off absolute-layout positions require `// Figma: y=192, w=375` comment to pass review.
  - **`.frame(width:)` on Text BANNED.** Reading Figma's measured visual width on a hug-mode Text and emitting `.frame(width: 200)` ships truncation as soon as content grows. Default for Text is hug (no frame) or fill (`maxWidth: .infinity`). Allow-list: Figma `primaryAxisSizingMode === FIXED` AND `// Figma fixed-width: <reason>` comment present. See `references/visual-fidelity.md` §7 #9 + `references/layout-translation.md` §"Text sizing-mode → SwiftUI".
  - **`.minimumScaleFactor(0.6)` required on single-line Text in constrained widths.** Any Text with `.lineLimit(1)` (or visually single-line in Figma but inside a fill-width / fixed-width container) MUST carry `.minimumScaleFactor(0.6)`. Localized strings and longer dynamic data shrink to fit instead of truncating to ellipsis. Multi-line Text wraps naturally and does NOT take it. See `references/visual-fidelity.md` §7 #10.
  - **Fill-* Image must emit all three modifiers.** `.resizable() + (.scaledToFill()|.scaledToFit()) + .frame(...)` together — missing any one is a bug (blank gap / anisotropic stretch / intrinsic shrink). Default content mode: `.scaledToFill()` (Figma image-fill default). See `references/visual-fidelity.md` §7 #11 + `references/layout-translation.md` §"Image content-mode → SwiftUI".
  - **Safe-area normalization for mockup frames.** When the Figma frame matches an iPhone full-device height (812/844/852/932/...), every Y measurement is `raw_figma_y - safeAreaInsets.top`. Suspicious values at screen-root (`.padding(.top, 44|47|59|64|67|79|88)`) require a `// safe-area-adjusted: raw=..., inset=..., adjusted=...` comment or they are double-counts. Same on bottom for home indicator. See `references/visual-fidelity.md` §7 #12 + `references/layout-translation.md` §"Safe Area Normalization for Mockup Frames".
  - **Banned invention phrases.** Pass 1 greps the diff for known agent-invented English copy and red-flags. Current banned list (extended as new failures appear):
    - "Secure your accounts" → Figma says "Secure All Accounts"
    - "Use Face ID" → Figma says "Quick Setup: Face ID Protection"
    - "Create your PIN" → Figma says "Let's make your account safer"
    - "Get Started" when the actual Figma button reads "Continue"
    - benefit-checklist text that does not appear in `design-context.md`
    - any title/subtitle pair where the title length differs from Figma by > 30%

**Translation references:**
- `references/visual-fidelity.md` — **read first, always**
- `references/swiftui-pro-bridge.md` — **read second, always** (transform tables + iOS 16 fallbacks + token routing)
- `references/swiftui-pro/api.md`, `views.md`, `data.md`, `accessibility.md` — load on demand for specific rules
- `references/layout-translation.md` — Auto Layout, stacks, sizing, effects, animations
- `references/design-token-mapping.md` — typography, colors, gradients, opacity
- `references/fills-handling.md` — background image / gradient overlay / image+gradient stack (read when a container has non-trivial fills in `fills.json`)
- `references/component-variants.md` — state/size/style
- `references/responsive-layout.md` — size classes, iPhone+iPad

**Coding-convention references (read once before C2):**
- `references/project-structure.md` — folder layout + file naming (canonical `Screens/<Name>/<Name>Screen.swift`, brownfield ikame-feature-flat)
- `references/viewmodel-pattern.md` — State + Action + `send(_:)` reducer (canonical ViewModel shape)
- `references/swift-style.md` — function/view size, golden path, modifier order, memory, error handling
- `references/iknavigation-bridge.md` — IKNavigation usage when `usesIKNavigation = true` (Style A `.navigationDestination(item:)` vs Style B `navigation.push`)
- `references/ikmacro-bridge.md` — `@APIProtocol` / `@JsonSerializable` / `enum API` registry when `usesIKMacros = true` AND generating repository/DTO code
- `references/ikpopup-bridge.md` — IKPopup closure-form invocation + per-project config cases when `usesIKPopup = true`
- `references/ikfeedback-bridge.md` — IKLoading + IKToast (canonical) + IKHaptics + brownfield `AppUtils.shared.showAppBottomToast` wrapper when `usesIKFeedback = true`
- `references/fonts-styling-bridge.md` — Figma typography token → `ikFont` preset / escape hatch / additional family helper when `usesIKFont = true`
- For Ikame canonical conventions: `ikame-ios-coding/references/<topic>.md` is the source of truth — bridges above only document the figma-specific delta.

### Step C3 — Self-Check (mandatory, five passes + structural gates)

**Pass 1 — Code vs Inventory.** For each inventory row, verify code matches exactly. Fix every ✗.

**Pass 2 — Code vs Screenshot (mandatory, structured diff report).**

Mental walk-throughs are too easy to fake. Pass 2 produces a verifiable artifact: `.figma-cache/<nodeId>/c3-pass2-diff.md`, written using the template in `references/verification-loop.md` §1.

Procedure:
1. **Prefill mechanical rows first** (recommended): run `scripts/c3-pass2-prefill.sh <nodeId>`. This writes 9 rows decided by grep (CH, PD, GR, DV, BG, TR, SA, BS, **SS**) and 9 TODO rows for the Figma-grounded checks (LH, LS, SH, BD, OP, RM, IS, **AL**, **IF**) — see `references/verification-loop.md` §4.0.
2. Open `screenshot.png` and `design-context.md` side by side.
3. Walk every section of the screen. Replace each TODO row with `Source quote` (verbatim from design-context.md or inventory — no paraphrasing), `Code value` (verbatim SwiftUI modifier), `File:Line` (real line in a generated swift file), `Match` (PASS/FAIL/N/A), `Severity` (high/medium/low for FAIL). Flip any prefilled PASS/NA to FAIL if the script's mechanical decision was wrong for this screen.
4. Every check letter must appear ≥1 time. No instance on screen → one N/A row with reason. Minimum 14 rows total. Coverage = 18 letters: LH/LS/SH/BD/OP/RM/IS/**AL**/DV/BG/TR/GR/SA/CH/PD/BS/**IF**/**SS**.

Then run **Gate C3-Pass2** (BASH, mandatory). Full block + 6 anti-hallucination checks: `references/verification-loop.md` §4.1.

Two failure modes:
- **Gate FAIL** (report invalid) → regen report; no code edits; no counter bump. After 2 consecutive regen failures, ASK user.
- **Gate PASS, `HIGH_FAILS > 0`** → trigger self-fix loop. Default `MAX_RETRIES=2` (override at task start with `max 3 retries`). Snapshot report to `c3-pass2-diff.attempt-<N>.md`, increment counter, edit ONLY the file:line cited in each FAIL row (no refactoring), re-run Pass 2 from scratch. Asymptote check: if `highFailsHistory` not decreasing → exit as exhausted. Full pseudocode + state layout: `references/verification-loop.md` §4.3.

User abort phrases (`stop fixing`, `ship as-is`) → mark `manifest.verification.c3Pass2.lastResult = "user_override"`, continue.

**Pass 3 + 3b + 4 Part A — fast path (mandatory):** run `scripts/c3-static-checks.sh --files "<space-separated swift paths>" --target <iOS-major>`. One call covers all three sweeps:
- **Pass 3** (asset substitution): grep for `Image(systemName:)` outside the system-chrome allow-list. Hits → re-fetch the asset from Figma; never improvise.
- **Pass 3b** (system chrome): grep for `"9:41"` / wifi / battery / `StatusBar` / `HomeIndicator` / `DynamicIsland` redraws + visually scan for ~134×5pt `Capsule`/`RoundedRectangle` at the bottom (home indicator clone). Hits → delete; iOS renders these.
- **Pass 4 Part A** (swiftui-pro Review, 12 checks): banned modern API hits, deprecated `cornerRadius()`, iOS-version-gated APIs, `PreviewProvider`/`AnyView`, `DispatchQueue`/`Task.detached`, manual `Binding(get:set:)`, deprecated navigation, image accessibility, force unwraps (informational), `Text + Text`, `.onTapGesture` for actions (informational), iOS 16 fallback markers.

The driver writes `GATE: PASS` / `GATE: FAIL` to stdout — same exit semantics, one bash startup. **Explicit form (verbatim greps + python image-accessibility scan) lives in [`references/verification-loop.md`](references/verification-loop.md) §4.4** as fallback when the driver script is unavailable. SKILL.md no longer inlines the bash to keep this step compact; the reference has the full source.

**Pass 4 Part B: Structural review (manual walk per file).**

For each generated `.swift` file, walk the structural rules table in `references/swiftui-pro-bridge.md` §4. Specifically:
1. View body length — any `body` > ~40 lines? Extract sub-sections into separate `View` structs in their own files. **Computed properties returning `some View` are not acceptable** even with `@ViewBuilder`.
2. Multiple types per file? Each struct/class/enum into its own file.
3. Inline business logic in `body`/`task`/`onAppear`? Extract to method or `@Observable`/`ObservableObject` view model.
4. `@Observable` (iOS 17+) class missing `@MainActor`? Add `@MainActor`.
5. (iOS 17+ projects only) `ObservableObject` + `@Published` + `@StateObject` instead of modern `@Observable`? Recommend migration unless legacy reasons.

Output format mirrors swiftui-pro SKILL.md "Output Format" — group findings by file, name rule violated, before/after fix. Add a prioritized summary at the end.

**If Part A or Part B FAIL: fix every violation before proceeding to C4.** Re-run Part A bash to confirm clean exit.

**Pass 5 — Coding-conventions gates (BASH, mandatory).**

Catches violations of project-structure, ViewModel pattern, function size, and (when the project uses them) IKNavigation / IKFont. Reads `c1-conventions.json` from C1 — gates auto-skip when the corresponding flag is off.

**Fast path (recommended):** run `scripts/c8-all.sh --src "$SWIFT_SRC" --conventions "$CONV"` — runs all six c8-* sub-gates in parallel and aggregates the result with deterministic output ordering. Same enforcement semantics; `c8-weak-self` stays informational. Use this in place of the six sequential calls below.

```bash
SWIFT_SRC="<dir-containing-generated-swift-files>"
CONV=".figma-cache/<nodeId>/c1-conventions.json"
FAIL=0

# (1) Folder layout + file naming
scripts/c8-conventions-gate.sh --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1

# (2) ViewModel pattern (State + Action + send + @MainActor + Route)
scripts/c8-vm-pattern.sh --src "$SWIFT_SRC" || FAIL=1

# (3) Function-length limits (warn @ 30 / hard fail @ 50)
scripts/c8-func-length.sh --src "$SWIFT_SRC" || FAIL=1

# (4) IKNavigation gate (skipped when usesIKNavigation = false)
scripts/c8-iknavigation.sh --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1

# (5) IKFont gate (skipped when usesIKFont = false)
scripts/c8-ikfont.sh --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1

# (6) Weak-self closure scan (informational; agent acknowledges in summary)
scripts/c8-weak-self.sh --src "$SWIFT_SRC"

[ $FAIL -eq 0 ] && echo "GATE: PASS (Pass 5 — coding conventions)" || { echo "GATE: FAIL (Pass 5 — coding conventions) — DO NOT proceed to C4"; exit 1; }
```

Each gate prints `GATE: PASS`, `GATE: FAIL: <reason>`, or `GATE: SKIP (...)` with exit code matching. Reference docs:
- [`references/project-structure.md`](references/project-structure.md) — folder layout + file naming (canonical `one-screen-per-folder`, brownfield `ikame-feature-flat`)
- [`references/viewmodel-pattern.md`](references/viewmodel-pattern.md) — State/Action/reducer with canonical `@Published var route` (brownfield `routePublisher`)
- [`references/swift-style.md`](references/swift-style.md) — function size, golden path, modifier order, weak self
- [`references/iknavigation-bridge.md`](references/iknavigation-bridge.md) — IKNavigation Style A (`.navigationDestination(item:)`) vs Style B (imperative push), per-feature router (conditional)
- [`references/ikmacro-bridge.md`](references/ikmacro-bridge.md) — IKMacros DTO/repository + `enum API` registry (conditional)
- [`references/ikpopup-bridge.md`](references/ikpopup-bridge.md) — IKPopup closure form + project-level config cases (conditional)
- [`references/ikfeedback-bridge.md`](references/ikfeedback-bridge.md) — IKLoading + IKToast + IKHaptics + brownfield AppUtils.bottomToast (conditional)
- [`references/fonts-styling-bridge.md`](references/fonts-styling-bridge.md) — Figma typography token → `ikFont` preset / escape hatch / per-family helper; Color(hex:) vs Asset Catalog (conditional)
- `ikame-ios-coding/references/<topic>.md` — canonical source of truth for Ikame conventions; bridges above are figma-specific delta.

Anything in code not traceable to inventory → guess → fix. Never "tweak until it looks right".

### Step C4 — Copy Assets to Project

For each row in `manifest.rows`, branch on `exporter`:

**`exporter == "tagged"`:**
- The `.imageset` is already inside `Assets.xcassets` (tool did this in B3). Verify `imagesetPath` exists and contains at least one `*@2x.png` and one `*@3x.png`. **No sips, no Contents.json work.**
- Rendering mode is decided at the SwiftUI **call site** — the tool does not write `template-rendering-intent`.

**`exporter == "fallback"`** (and `strategy != "lottiePlaceholder"`):
1. Rendering mode: single-color icon → template; else original (see `references/asset-handling.md` §4)
2. `sips` → @1x/@2x/@3x from 3× source (`sharedPath`)
3. `.imageset` + Contents.json: universal idiom; `template-rendering-intent` for tinted; `appearances` for dark variants
4. Copy to `Assets.xcassets` (use the catalog pinned in B0)

**Lottie placeholder rows** are skipped here — codegen lives in C2.

**SwiftUI call-site rules (both paths):**
- `Image(.<exportName>)` for tagged rows; `Image(.<friendlyName>)` for fallback rows (iOS 17+ auto-generated `ImageResource` — never the string form `Image("<name>")`). The manifest is the single source of truth.
- Always `.resizable()` + explicit `.frame(width:height:)`.
- Single-color icon (`renderingMode == "template"` in manifest):
  - tagged rows → `.renderingMode(.template)` + `.foregroundStyle(...)` at the call site.
  - fallback rows → may rely on `template-rendering-intent` in Contents.json, OR explicit `.renderingMode(.template)` — both work.
- Multi-color / illustration / brand: no `.renderingMode` modifier. Patterns in `references/asset-handling.md` §7.

**Verification (BASH, mandatory):**

```bash
SWIFT_FILES="<your-generated-swift-files>"

# (a) Every Image(.<name>) in generated views must appear in manifest as exportName or friendlyName.
NAMES=$(python3 -c "
import json
m = json.load(open('.figma-cache/<nodeId>/manifest.json'))
for r in m.get('rows', []):
    if r.get('strategy') == 'lottiePlaceholder':
        continue
    print(r.get('exportName') or r.get('friendlyName'))
")
# Catch both the canonical ImageResource form (Image(.name)) and the legacy string form (Image("name")).
# Legacy form should not exist on the Xcode 15+ baseline; if it does, surface as ORPHAN candidates anyway.
USED=$( { grep -hoE 'Image\(\s*\.[A-Za-z_][A-Za-z0-9_]*' $SWIFT_FILES | sed -E 's/Image\(\s*\.([A-Za-z_][A-Za-z0-9_]*).*/\1/';
          grep -hoE 'Image\("[^"]+"\)' $SWIFT_FILES | sed -E 's/Image\("([^"]+)"\)/\1/'; } | sort -u )
for h in $USED; do
  echo "$NAMES" | grep -qx "$h" || echo "ORPHAN: Image reference \"$h\" not in manifest"
done

# (a2) Inverse — every manifest asset must be referenced by at least one Image(.X) in code.
# Orphan assets bloat the catalog and usually mean the agent extracted a node it later flattened away.
# This is a WARNING, not a FAIL: the user decides whether to remove or keep the unused entry.
for n in $NAMES; do
  [ -z "$n" ] && continue
  echo "$USED" | grep -qx "$n" || echo "UNUSED: manifest entry $n not referenced by any Image(.X) call"
done

# (b) Every lottie-placeholder row must have a matching LottieView call.
PLACEHOLDER_COUNT=$(python3 -c "
import json
m = json.load(open('.figma-cache/<nodeId>/manifest.json'))
print(sum(1 for r in m.get('rows', []) if r.get('strategy') == 'lottiePlaceholder'))
")
LOTTIE_USES=$(grep -cE 'LottieView\(animation: \.named\("placeholder_animation"\)\)' $SWIFT_FILES \
              | awk -F: '{s+=$2} END{print s+0}')
if [ "$PLACEHOLDER_COUNT" -gt 0 ] && [ "$LOTTIE_USES" -lt "$PLACEHOLDER_COUNT" ]; then
  echo "FAIL: $PLACEHOLDER_COUNT lottie placeholders in manifest but only $LOTTIE_USES LottieView call(s) in code"
fi

# (c) `import Lottie` must appear in every file that uses LottieView.
for f in $SWIFT_FILES; do
  if grep -q 'LottieView(' "$f" && ! grep -q '^import Lottie' "$f"; then
    echo "FAIL: $f uses LottieView but is missing 'import Lottie'"
  fi
done

# (d) Imagesets exist for every row that should be in xcassets.
find <project>/Assets.xcassets -name "*.imageset" -type d
```

Build in Xcode — no "image not found" warnings, no missing-import errors. After the run, surface the placeholder list to the user (see `references/lottie-placeholders.md` §8 for the end-of-run summary template).

### Step C5 — Visual Validate (mandatory)

After C3 finishes (Pass 2 clean report, Pass 3/3b grep clean, C4 assets copied), **RUN C5. Do not prompt.** This catches what Pass 2 cannot see: real font rendering, shadow at simulator DPI, safe-area on chosen device, keyboard avoidance, animation start state.

**Skip only when one of these system reasons applies** (auto-detected, persisted in `manifest.verification.c5.skipped`; user phrases cannot override):
- `no_project` — no `.xcodeproj` / `.xcworkspace` after walking up 3 levels.
- `simctl_error` — `xcrun simctl` errors (no simulator runtime, Xcode CLT missing, etc.).
- `ci_environment` — `CI=true` or `GITHUB_ACTIONS=true` env var present (no GUI simulator in CI).
- `no_entry_path` — screen is not the launch screen, no existing `#Preview` / scheme / test target reaches it, and no driver (`ios-simulator-verify` skill or `computer-use` MCP) is available. Adding a launch-arg / env-var route override to the binary is **banned** — see `references/verification-loop.md` §"C5 Verification Integrity".

User phrases like `skip C5`, `bỏ qua C5`, `no build`, `không cần build` are NOT honored — the agent must explain the Done-Gate (Key Principle #12) and proceed with C5 anyway. The only legitimate way to bypass is one of the three system reasons above.

#### C5.0 — Engine selection (deterministic via `scripts/c5-engine-select.sh`)

Two engines:

- **Engine A — xcode MCP (default on Xcode 26+).** The `xcode` MCP server (`xcrun mcpbridge`, ships with Xcode 26+; tools surfaced as `mcp__xcode__BuildProject`, `mcp__xcode__RenderPreview`, `mcp__xcode__XcodeListNavigatorIssues`, `mcp__xcode__GetBuildLog`, `mcp__xcode__XcodeListWindows`, `mcp__xcode__XcodeRefreshCodeIssuesInFile`, plus the `XcodeWrite/XcodeUpdate/XcodeRead/XcodeMV/XcodeRM/XcodeMakeDir/XcodeGlob/XcodeLS` file-family for project-aware writes — see Step C2 above). Wins: bypasses `xcodebuild -list` SPM "Creating working copy" hang (the live Xcode session has already resolved packages), bypasses `simctl boot/install/launch` (RenderPreview snapshots a `#Preview` directly — no app entry path needed).
- **Engine B — xcodebuild + simctl (universal fallback).** Used when Engine A prerequisites fail.

**Procedure** — run `bash scripts/c5-engine-select.sh --screen-file <path-to-*Screen.swift>` once at C5 start. The script probes three prerequisites:

1. `xcrun mcpbridge --help` exits 0 (Xcode 26+ ships it).
2. `pgrep -x Xcode` succeeds (mcpbridge needs a live session).
3. The screen file contains a top-level `#Preview { ... }` block (C2 emit requirement).

It writes single-line JSON to stdout:

```json
{"engine":"xcode-mcp"|"xcodebuild","reason":"…","preReqs":{"mcpbridge":bool,"xcodeRunning":bool,"previewBlock":bool|null}}
```

The agent:
1. Parses the JSON. Stash `engine` into `manifest.verification.c5.engine` (`"xcode-mcp"` | `"xcodebuild"`).
2. If `engine == "xcode-mcp"` AND `mcp__xcode__BuildProject` is not yet visible in the available tools (deferred-tool case), call `ToolSearch` once with query `xcode` (keyword search loads the whole xcode toolkit in one round-trip per the MCP server instructions).
3. Branch to the matching path below (Engine A or Engine B).

Pass `--explain` to the script when troubleshooting — it prints a human-readable report with the exact fix for each failed prereq (e.g. "open Xcode with the target project, then re-run").

**Banned:**
- Copy-pasting `xcodebuild build` from `references/verification-loop.md` §5 without running `scripts/c5-engine-select.sh` first. The reference holds the Engine B procedure — engine *choice* is owned by the script.
- Selecting Engine B by feel ("xcodebuild is the path I know"). When the doctor script reports xcrun mcpbridge available AND Xcode is running, Engine B is a regression — the Stop hook flags this in the Done-Gate report.

Doctor script (`scripts/doctor.sh`) reports xcode-mcp availability at install time.

#### Engine A path — xcode MCP (preferred)

1. **A.1 Workspace probe.** Call `mcp__xcode__XcodeListWindows`. Pick the window matching the target project. Stash workspace info to `manifest.verification.c5.xcodeWindow`.
2. **A.2 Build.** Call `mcp__xcode__BuildProject` with the resolved scheme. On failure: call `mcp__xcode__XcodeListNavigatorIssues` (and `mcp__xcode__GetBuildLog` if needed) to get structured compile errors. Treat each error as a `FAIL high` row in the self-fix loop — same scope rule as Pass 2 (only edit the cited file:line).
3. **A.3 Render.** Call `mcp__xcode__RenderPreview` targeting the screen's `*.swift` file (the one containing `#Preview { ... }`). The MCP returns the snapshot PNG. Save to `.figma-cache/<nodeId>/c5-render.png`.
4. **A.4 Compare.** Skip the `sips -Z 2000` shrink — RenderPreview already returns canvas-sized PNG (well under the 2000px many-image API cap). The agent reads `c5-render.png` + `screenshot.png` (or `screenshot-cmp.png` if the Figma frame is large) directly into the C5.6 procedure.
5. **A.5 Diff.** C5.6 procedure runs unchanged — same `c5-visual-diff.md` template as Engine B. Same 6-step compare in `references/verification-loop.md` §C5.6.

The Engine A path eliminates: `previewEntry` user prompt (RenderPreview targets `#Preview` directly, no app launch / nav stack), `simctl boot` cold start (~30-90s), `xcodebuild -list` SPM resolve hang (Xcode keeps state), and the `sips -Z 2000` shrink step (preview canvas is small).

**Banned:** Engine A is NOT a "route override" bypass. RenderPreview renders pure SwiftUI `#Preview` content, no `#if DEBUG` deep-link, no launch-arg env-var overrides — the C5 verification-integrity rule (`references/verification-loop.md` §"C5 Verification Integrity") still applies. If a screen has no `#Preview`, fall back to Engine B (legitimate skip path) — do NOT add a binary route override to make Engine A happy.

#### Engine B path — xcodebuild + simctl (fallback)

Run the 6 sub-steps (commands + edge cases in `references/verification-loop.md` §5):

1. **C5.1 Detect target** — `xcodebuild -list`. 1 scheme → use it; >1 → ask user, stash; 0 → skip with `manifest.verification.c5.skipped = "no_project"`.
2. **C5.2 Pick simulator** — prefer Booted iPhone, else highest-iOS iPhone 15/16. Stash UDID.
3. **C5.3 Build** — `xcodebuild -scheme ... -destination ... build`, log to `c5-build.log`. Build fail → surface compile errors as FAIL high rows, self-fix loop, do NOT install.
4. **C5.4 Boot/install/launch** — `simctl boot/install/launch`. Wrong default screen → ask user once for `previewEntry`, stash.
5. **C5.5 Capture + C5.5b Comparison-safe pair** — **Fast path (recommended):** `scripts/c5-capture.sh --cache .figma-cache/<nodeId> --udid <udid>` — one call does the 2s settle, simctl screenshot, PNG validation, and the long-side ≤2000px shrink for both `c5-simulator-cmp.png` and `screenshot-cmp.png`. Pass `--no-figma-cmp` only when the Figma screenshot was already shrunk by a prior run / by `figma_export_assets_unified(fallbackScale=2)`. The explicit form is `sleep 2 && xcrun simctl io <udid> screenshot c5-simulator.png` followed by two `sips -Z 2000` calls. Claude's many-image requests reject any image with long-side >2000px (iPhone-native captures ~1170×2532 blow this), so the cmp pair is mandatory. Full procedure in `references/verification-loop.md` §C5.5b.
6. **C5.6 Compare** — model reads the C5.5b pair (`*-cmp.png`), writes `c5-visual-diff.md` using same table format as C3 Pass 2 (Source quote → Note column). Compare composition and values, not absolute pixel positions.

Then run **Gate C5** (BASH, mandatory). Full block: `references/verification-loop.md` §5.7. High-severity diffs feed the same self-fix loop as C3 Pass 2 (shared counter, `MAX_RETRIES=2`, scoped edits only). Build failures count as FAIL high.

### Step C6 — Register Code Connect (optional)
If (and only if) your Figma MCP exposes a register/add Code Connect tool, call it for new reusable components.

---

## Resume & Retry

Check manifest. `phaseA` and `phaseB` both `done` → skip to Phase C. Some `failed` → retry those only. Cache > 24h → suggest re-fetch. User phrases: "tiếp tục fetch" (resume from last incomplete phase), "implement from cache" (skip to Phase C, but Gate B must still pass).

## MCPFigma edge cases (reference)

- **MCPFigma not configured.** A2's `figma_build_registry` call returns an error; surface to user, ask them to install/configure per `references/mcpfigma-setup.md`. No silent fallback — the registry is mandatory.
- **`FIGMA_ACCESS_TOKEN` missing or invalid.** Same — both `figma_build_registry` and the unified export need it. Token error message is server-side; relay it verbatim to the user.
- **Designer tagged a node but the name is invalid** (warning row in `registry.warnings`). The node is NOT in `taggedAssets[]` — it lands in B1 inventory as a fallback row. Either re-tag in Figma (`eIC<UpperCamel>`) or accept the fallback.
- **Designer tags `eImageHero` containing nested interactive UI.** Trust the prefix by default — keep the tagged row even though the visual region looks like FLATTEN. Result is a flat raster of the whole region, fine for a hero. Override only when user explicitly says "treat eImageHero as decompose" — set `exporter = "fallback"` on that row, mark FLATTEN.
- **Project has multiple `.xcassets`.** B0 prompts for `assetCatalogPath` and stashes it in the manifest. The unified tool requires the explicit path — it does not auto-resolve from a project root.
- **Tool returns non-PNG for a fallback row.** Tool already validates PNG signature and marks the row `failed` with reason `"Output không phải PNG..."`. Surface to user — typically means designer used SVG-only for that node; ask them to flatten in Figma.
- **Light/dark variants.** Tagged path exports each node as one imageset (no `appearances`). To support light/dark, designer ships two nodes (`eICLogo` + `eICLogoDark`); app picks at `colorScheme`. Merging both into one imageset (with `appearances`) is only available on the fallback path's manual import — see `references/asset-handling.md` §5 "light + dark variants".
- **Same `exportName` from two different source nodeIds.** Tool adds `_2` suffix and emits a warning in `summary.warnings`. Surface to user — SwiftUI call site needs to know which is which.
- **Phase B re-run after partial success.** Tool is idempotent (`overwrite=true`, `skipIfExistsInCatalog=true` defaults). On re-run, only still-failing nodes are re-attempted; successful rows are no-op overwrites. Inspect manifest `rows[].status` before re-running — `done` rows can be skipped entirely if their files still exist on disk.
- **Lottie placeholder (`eAnim*`) — Lottie SDK missing.** C1 project pre-flight should detect whether `lottie-ios` is in dependencies. If not, surface before C2: *"Lottie SDK not detected — add `lottie-ios` (Airbnb) via SPM or CocoaPods, or convert these placeholders to static images."* Do NOT auto-install; do NOT silently swap in `Image(systemName:)`. See `references/lottie-placeholders.md` §9.
- **Lottie placeholder inside a flatten region.** The flattened parent exports as a static raster (animation is frozen in one frame). The placeholder `LottieView` overlays on top in `ZStack`. Tell the user the artwork would be cleaner if the designer pulled the `eAnim*` node out of the flatten region.
- **Custom Lottie wrapper in project.** If C1 audit finds `IKLottieView`/`AnimatedView`/etc., prefer the wrapper at C2 codegen. The placeholder name string `"placeholder_animation"` stays unchanged.
- **Variables API empty + warnings (HTTP 200).** `figma_extract_tokens` returns empty arrays + a `warnings[]` entry **with HTTP 200**. Cause: file plan exposes Variables but the file has none defined, OR shared styles absent. Fallback allowed: read inline tokens from `design-context.md` per `references/design-token-mapping.md` General Rules. Write `tokens.json` with `_note: "reconstructed from inline styles — Variables API empty + warnings"` so downstream gates can see it was a fallback.

- **Variables scope not on PAT — HTTP 403 + `requires the file_variables:read scope` message.** `figma_extract_tokens` returns HTTP 403 with Figma's `message` field containing the exact substring `"requires the file_variables:read scope"`. Two operational sub-cases the agent CANNOT programmatically distinguish: (a) **plan-gated** — the user's Figma plan does not expose `file_variables:read` in the PAT settings UI (Free / Professional / Organization without Enterprise add-on); unfixable without a plan upgrade. (b) **scope omitted** — the plan exposes the scope but the PAT was generated without ticking `Variables → Read` (off by default); fixable by re-issuing PAT. Fallback allowed under this combined case **only when the disclosure protocol below is met in full** — partial disclosure is treated as a silent degrade and is a protocol violation:
  1. Write `tokens.json` with `_note: "reconstructed from inline styles — file_variables:read scope missing on PAT (Figma 403). Plan-gated for non-Enterprise; user-fixable if scope option is visible at https://figma.com/settings → Personal access tokens."`
  2. The Verification summary MUST include a verbatim copy of the Figma 403 `message` field AND the line `Variables source: inline-fallback (file_variables:read scope unavailable on PAT — verify if scope option exists in Figma settings; if yes, regenerate PAT with the scope and re-run for full Variables grounding).`
  3. The agent's final user-facing message MUST list this fallback alongside C5 status. If you find yourself writing `"reconstructed from inline styles"` to disk WITHOUT also adding the `Variables source:` line and the verbatim 403 message to the Verification summary — **STOP**: that is exactly the silent-degrade failure mode this rule blocks. Re-emit the summary with both items before declaring done.

- **Other 401 / 403 — STOP.** Any other auth failure: HTTP 401 (`unauthorized`), or HTTP 403 with a `message` that does NOT contain the substring `"requires the file_variables:read scope"` (e.g. file access denied, workspace permission, missing `file_content:read`, generic forbidden). **STOP**. Do NOT fall back. Surface verbatim. Tell the user to re-issue their PAT at https://figma.com/settings with all scopes their plan exposes (especially `File content: Read` and `Variables: Read` if visible), and verify the file is in the token-owner's workspace per `references/mcpfigma-setup.md` §Troubleshooting.
- **`figma_build_registry` returns empty `screens[]`** — root may be a leaf (icon / text node) **or** a `SECTION` container holding the actual frames. Inspect `rootNode.type`. If `SECTION`, the registry tool has not recursed into its children: surface to the user with the section's child FRAME list and ask which one to point the skill at, or pass the parent CANVAS / PAGE node ID. Do NOT silently substitute by enumerating the section's siblings yourself — that bypasses A2's screen-detection rules (320-1024pt width range) and lands you with stray non-screen frames.

## Strongly recommended hooks (hard enforcement)

These hooks turn the in-skill gates into OS-level enforcement. Without them, gates rely on the agent honoring them; with them, the tool call is denied at the harness layer.

1. **PreToolUse hook — Phase A+B coverage gate.** `figma-to-swiftui-gate.sh`: blocks `Write`/`Edit` on `*.swift` when any screen-cache lacks Phase A artifacts (manifest, design-context, screenshot, tokens, registry) OR Phase B is incomplete (`phaseB != "done"`, empty `rows[]`, failed rows, OR `registry.taggedAssets[].nodeId` not all present in `manifest.rows[]` with `status: "done"`). Closes the "downloaded the hero, built the rest with SwiftUI shapes" failure mode.

2. **PreToolUse hook — banned-pattern detector.** `figma-to-swiftui-banned-pattern-gate.sh`: scans the Swift content the agent is about to write. Blocks `Image(systemName:)` outside the four-name allow-list (no `// allow-systemName:` comment), `Text("9:41")` and other status-bar redraws, `Capsule()` with height ≤ 6pt (home-indicator lookalike), `FakeStatusBar` / `HomeIndicator` / `NotchView` / `DynamicIslandView` struct names, letter-as-logo (`Text("G")` near a small frame), `Text(...).frame(width: <num>)` without `// Figma fixed-width:` justification, screen-root `.padding(.top, 44|47|59|64|67|79|88)` without `// safe-area-adjusted` comment (double-counts the iOS safe-area inset), `Image(...).frame(maxWidth: .infinity)` chains (both legacy `Image("X")` and modern `Image(.X)` form) missing `.resizable()` + content mode (blank-gap bug), `cornerRadius`/`clipShape(.rect(cornerRadius:))`/`clipShape(RoundedRectangle(cornerRadius:))` ≥ 30pt without `// allow-screen-corner-radius:` justification (mimics the iPhone bezel — hardware already curves it), and `Text(...).frame(maxWidth: .infinity)` whose enclosing scope is a `Button { ... }` body, without `// allow-text-fill:` justification (cascades up through Button — overrides caller `.padding(.horizontal, N)` and bloats the button to screen width). Prevents the absolute-rule violations from landing on disk in the first place.

3. **PreToolUse hook — entry-path bypass detector.** `figma-to-swiftui-entry-bypass-gate.sh`: blocks edits to `*App.swift` / `*ContentView.swift` / `*RootView.swift` / `*MainView.swift` / `*AppRouter.swift` / `*AppCoordinator.swift` when the new content sets `initialStep`/`currentStep`/`verifyStep` to a screen literal, looks up `VERIFY_ROUTE` env vars, or adds `#if DEBUG` deep-link parsers. Closes the C5 verification-integrity bypass per `references/verification-loop.md` §"C5 Verification Integrity". Legitimate flow-state initialization carries `// figma-entry-bypass-gate: legitimate-flow-state` to bypass.

4. **PostToolUse hook — auto-run Gate C3-Pass2 on `c3-pass2-diff.md` write.** `figma-to-swiftui-pass2-gate.sh`: saves one round-trip per attempt and surfaces structural bugs immediately.

5. **PostToolUse hook — C8 coding-conventions write-time gate.** `figma-to-swiftui-c8-gate.sh`: runs after every `Write/Edit *.swift` inside a figma task. Reads `c1-conventions.json` from the cache and per-file checks: (a) path correctness — when `screenFolderConvention == "one-screen-per-folder"`: parent-`-Screen` files must live at `Screens/<X>/<X>Screen.swift` (folder name `<X>`, NOT `<X>Screen`), `<X>ViewModel.swift` is co-located in the same folder, `-Screen` suffix banned in `Subviews/Models/Enums/SubViewModels/`; when `screenFolderConvention == "ikame-feature-flat"`: parent-`-Screen` files must live at `Screens/<Feature>/<Feature>HomeScreen.swift` or `Screens/<Feature>/<Feature><Action>Screen.swift`, ViewModel under `Screens/<Feature>/ViewModel/`; (b) subview prefix — files in `Subviews/` start with the parent screen's base name; (c) ViewModel content — `*ViewModel.swift` must have `@MainActor` + `enum Action` + `func send(_ action: Action)`, plus `enum Route: Equatable, Hashable` if `route` is referenced (or `let routePublisher = PassthroughSubject<Route, Never>()` only when C1 captures `viewToRouteWiring: "routePublisher"`); (d) IKNavigation banned root APIs (screen-level `NavigationStack(path:)` / `NavigationLink` / `.navigationDestination(for: <Type>.self)` / `NavigationPath`) when `usesIKNavigation = true`; `.navigationDestination(item:)` is NOT banned (canonical Style A binding); (e) Ikame font violations when `usesIKFont = true`: raw `.font(.system(size:))`, `.font(.body)` / `.font(.title)` etc., `Font.custom("…", size:)` at view call sites (only allowed inside the 4-layer additional-font helper that delegates to `ikCustomFont`); (f) function bodies > 50 lines (hard fail). Catches violations IMMEDIATELY at write-time so the agent fixes the file before building on top of it. Pairs with the session-end Stop hook (item 6) for tree-wide checks (parent-view existence, weak-self warnings).

6. **Stop hook — block session termination when Done-Gate unsatisfied.** `figma-to-swiftui-stop-gate.sh`: for every screen-cache with `phaseA == "done"`, requires `phaseB == "done"` + `rows[]` non-empty + `verification.c5.gate == "PASS"` (or one of four system skip reasons) + C5.6 coverage script passing + project-wide C6 (asset completeness) + C7 (no system chrome) + C8 (coding conventions — folder layout, ViewModel pattern, function length, conditional IKNavigation/IKFont) passing. The previous "only enforce when phaseB done" gate left a hole — agents skipped Phase B entirely and stopped freely. This version closes it.

`scripts/install.sh` registers all six hooks idempotently into `~/.claude/settings.json`. Re-running it after pulling new hook scripts is safe.

## Key Principles

1. **Three phases, three gates, no skipping.** Phase A → Gate A. Phase B → Gate B. Phase C self-check. Each gate prints `GATE: PASS` or you do not proceed.
2. **All assets from Figma — no exceptions.** SF Symbols, colored shapes, `Text("G")` logos, "simplified" illustrations are BANNED. Missing asset → stop and re-fetch, never improvise.
3. **Fidelity is the goal.** Pixel-for-pixel — spacing, color, font, lineHeight, tracking, shadow, border, opacity, gradient. Approximation is a bug.
4. **MCP output is a spec.** Parse values per `references/visual-fidelity.md` §1. Never port React/Tailwind to SwiftUI.
5. **Every value must be traceable.** Trace to tokens, inline style, class, or design-context comment. Untraceable = guessed.
6. **Visual Inventory first, every Phase C.** Never skip lineHeight/tracking/shadow/border/renderingMode/**textAlign**/**stack alignment** (`primaryAxisAlignItems` + `counterAxisAlignItems` both axes). Centered text in a fill-width container needs `.multilineTextAlignment(.center)` AND a fill-width drawing rect — place `.frame(maxWidth: .infinity, alignment: .center)` on the Text when the parent is a non-Button stack, or on the Button's OUTER frame when the parent is `Button { ... }` (inner-Text maxWidth cascades up — banned by Check 8 without `// allow-text-fill:`).
7. **Self-check four passes + structural gates.** Pass 1 code-vs-inventory, Pass 2 code-vs-screenshot (writes `c3-pass2-diff.md`, Gate C3-Pass2 verifies structure + anti-hallucination), Pass 3/3b bash grep for `Image(systemName:` and system chrome, Pass 4 swiftui-pro Review (deprecated API + iOS 16 fallbacks + structural).
8. **Beware SwiftUI defaults.** Always specify `.font(.system(size:))`, `VStack(spacing:)`, `.padding(X)`, `.buttonStyle(.plain)` for custom buttons.
9. **Flatten composed artwork.** Don't reassemble atoms via `.offset()`. When in doubt → flatten.
10. **Two-MCP split is mandatory.** `get_screenshot(nodeId)` (figma-desktop MCP) gives the FRAME screenshot used by Pass 2 / C5 visual diff — never use it as an asset exporter. Per-asset PNG export goes through `figma_export_assets_unified` (MCPFigma). If either MCP is missing → STOP and ask the user; never improvise a substitute.
11. **Verification produces artifacts.** Pass 2 writes a structured diff report; C5 captures a simulator screenshot and writes a visual diff report. Both are gated and feed a self-fix loop. Mental walk-throughs are not enough — the agent can lie, but `file <path>` cannot.
12. **Done-Gate.** A task is NOT complete until either `manifest.verification.c5.gate == "PASS"` OR `manifest.verification.c5.skipped` is set to one of `no_project`, `simctl_error`, `ci_environment`, `no_entry_path`. Stating "done" / "implemented" / "xong" / "ship it" without one of these is a protocol violation. The agent MUST surface the C5 status (PASS, FAIL, or SKIPPED with reason) in its final user-facing message — see the **Verification summary** template below.

## Verification summary (mandatory final block)

At the end of every run — success or failure — print this block to the user verbatim, filling in values from the artifacts on disk. The user uses this to verify the agent without re-reading the entire transcript.

```
Verification summary
- C3 Pass 2 (offline diff):    PASS / FAIL (high: N, medium: N)
- C3 Pass 3 (asset grep):      PASS / FAIL
- C3 Pass 3b (chrome grep):    PASS / FAIL
- C3 Pass 4 (swiftui-pro):     PASS / FAIL
- C5 (build + simulator):      PASS / FAIL / SKIPPED (<reason>)
- C5.6 (6-step compare):       PASS / FAIL (high: N, medium: N)
- Variables source:            tokens.json (full) | inline-fallback (Variables API empty + warnings) | inline-fallback (file_variables:read scope unavailable on PAT — verify if scope option exists in Figma settings; if yes, regenerate PAT with the scope and re-run for full Variables grounding)
                               <if inline-fallback (scope unavailable): also paste the verbatim Figma 403 message field here>
Artifacts:
  .figma-cache/<nodeId>/c3-pass2-diff.md
  .figma-cache/<nodeId>/c5-build.log
  .figma-cache/<nodeId>/c5-simulator.png
  .figma-cache/<nodeId>/c5-visual-diff.md
```

Omit any row that genuinely does not apply (e.g. C5.6 if C5 was skipped). Never fabricate a PASS — open the file with `cat` if uncertain.

## Timing measurement (optional, regression-detection only)

Manifests carry an optional `timing` block so wall-time changes between runs are measurable. None of the gates read this — it exists purely so the user can verify that workflow refactors (faster scripts, parallel hooks, etc.) didn't slow things down or, worse, silently skip steps. Schema:

```json
{
  "timing": {
    "phaseA":  { "startedAt": "<ISO-8601>", "endedAt": "<ISO-8601>", "ms": <int> },
    "phaseB":  { ... },
    "c1":      { ... },
    "c2":      { ... },
    "c3Pass2": { ... },
    "c3Pass3": { ... },
    "c3Pass4": { ... },
    "c3Pass5": { ... },
    "c5":      { ... },
    "c5_6":    { ... },
    "gates": [
      { "name": "Gate A",         "ms": <int> },
      { "name": "Gate B",         "ms": <int> },
      { "name": "Gate C3-Pass2",  "ms": <int>, "attempt": <1..N> },
      { "name": "Gate C5",        "ms": <int> }
    ]
  }
}
```

Rules:
- `phaseX.ms` is wall-time from the FIRST tool call of that phase to the LAST artifact write — NOT the sum of individual tool-call latencies.
- `gates[].ms` is wall-time of the bash gate itself.
- Self-fix loop attempts: record the LAST attempt's `ms` in `c3Pass2`, push earlier attempts into `gates[].attempt`.
- Fields are additive — older manifests without `timing` are still valid; the report just shows fewer rows.

Run `scripts/timing-report.sh --cache .figma-cache/<nodeId>` for a single screen, or `scripts/timing-report.sh --flow .figma-cache` for a flow-level breakdown across screens. Older manifests without the `timing` block produce a "no timing data yet" note rather than failing.
