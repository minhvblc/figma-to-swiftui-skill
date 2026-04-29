---
name: figma-flow-to-swiftui-feature
description: "Orchestrate one or more Figma nodes plus a user-provided feature flow brief into a production-ready SwiftUI feature. Trigger when the user wants a full user journey, end-to-end flow, or multi-screen feature in an iOS project, including navigation, state handling, validation, loading/error/success states, and project-aware integration. Requires BOTH the figma-desktop MCP (get_metadata / get_design_context / get_screenshot) AND the MCPFigma server (figma_build_registry / figma_extract_tokens / figma_export_assets_unified) — STOP if either is missing, never improvise. Use together with figma-to-swiftui when pixel-accurate screen generation is also required."
---

# Figma Flow to SwiftUI Feature Skill

Turn one or more Figma nodes plus a feature-flow brief into a complete SwiftUI feature. This skill owns orchestration, completeness, and integration. It does not replace `figma-to-swiftui`; it coordinates feature-level work around it.

## Use This Skill When

- The user provides multiple Figma nodes for a single journey
- The user asks for a full feature, end-to-end flow, or screen sequence
- The request requires navigation, async actions, validation, or feature states
- The user wants more than a static screen translation

If the request is only one screen or one reusable component, use `figma-to-swiftui` instead.

## Scope

This skill is responsible for:
- Normalizing the request into a feature contract
- Auditing the project's architecture, dependencies, routing, and reusable UI building blocks
- Building a screen graph and integration plan before editing code
- Reusing existing components, modifiers, styles, assets, colors, `IKFont`, `IKCoreApp`, and adjacent feature patterns
- Ensuring the feature includes required states and transitions, not just happy-path UI

This skill is not responsible for pixel-level Figma-to-view translation. If `figma-to-swiftui` is available in the session, use it for each screen. If it is not available, follow the same principles locally and still treat Figma output as design specification, not code to port.

## Inputs

Look for these inputs first:
- **Source document** — `.txt`, `.md`, PM brief, spec, ticket. Read first, before any Figma call.
- Feature goal
- One or more Figma nodes or URLs
- Intended transitions between screens
- Actions and behaviors: submit, retry, back, cancel, confirm, selection, validation
- Data dependencies: API, store, cache, auth, persistence, environment, feature flags
- Architecture constraints already present in the project

When a source document is present, read [../figma-to-swiftui/references/source-document.md](../figma-to-swiftui/references/source-document.md) for the extraction template and conflict rules.
When details are incomplete, read [references/flow-input-contract.md](references/flow-input-contract.md).
When the doc is behavior-oriented but vague about exact element mapping, read [references/ambiguous-mapping.md](references/ambiguous-mapping.md) before coding.

## Fetch Discipline

All Figma MCP calls in this workflow follow [../figma-to-swiftui/references/fetch-strategy.md](../figma-to-swiftui/references/fetch-strategy.md). Key rules for flows specifically:

- `figma_build_registry(fileKey, rootNodeId, depth=10)` **once on the root flow node**. The response gives `screens[]` (drives the screen graph), `taggedAssets[]`, and `lottiePlaceholders[]` for the whole flow. Cache as `.figma-cache/_shared/registry.json`. Single-screen skill's B0 reads this and filters per screen by sub-tree containment.
- `figma_extract_tokens(fileKey)` **once per fileKey**; copy/symlink the resulting `tokens.json` into each screen's cache folder.
- `get_metadata` per screen as needed (kept for design-context cross-ref in C3); the registry already covers screen detection.
- If `figma_build_registry` errors (server not configured, token bad), surface to user — do not silently proceed; the registry is mandatory for the unified pipeline.
- **Lottie placeholders (`eAnim*`)** are already in `registry.lottiePlaceholders[]` — no separate walk per screen. Each screen's Phase B inventory ends up with `strategy: "lottiePlaceholder"` rows; Phase C2 codegens `LottieView` stubs using the literal name `"placeholder_animation"`. See `../figma-to-swiftui/references/lottie-placeholders.md`. The flow skill surfaces a combined end-of-run summary across all screens listing every placeholder the developer needs to replace.
- Run `figma-to-swiftui`'s **Phase A for ALL screens** in one batch — clustered in parallel, default 3 screens per cluster — then run Phase B for each screen in graph order. Do not interleave A and B across screens. Cluster mechanics: see Step 5 below + [`../figma-to-swiftui/references/fetch-strategy.md`](../figma-to-swiftui/references/fetch-strategy.md) §"Parallelism Inside Phase A".
- If any call times out, apply the circuit breaker in fetch-strategy.md. Do not retry the same node — split into sections instead. A single timeout removes that screen from the parallel path; remaining screens continue clustering normally.
- Manifests make Phase A resumable — re-fetch only the entries marked `failed`.

## Workflow

### 0. Read the Source Document (if provided)

If the user attached or pasted a `.txt` / `.md` / spec document, read it **before** any Figma MCP call. Extract: feature goal, expected screens, entry point, per-screen actions, async work, required states, constraints, out-of-scope items.

The extract is the primary driver for Step 1 and Step 2. It decides which Figma nodes are in scope, which actions to wire, and which non-happy-path states must be implemented even when Figma does not show them.

See [../figma-to-swiftui/references/source-document.md](../figma-to-swiftui/references/source-document.md) for the template and conflict-resolution rules.

### 1. Normalize the Request

Convert the user's prompt into a feature contract before coding:
- Screens and their node IDs
- Entry points
- Navigation transitions
- Per-screen actions
- Async operations and result states
- Open assumptions

Do not infer business logic from visuals alone. Make low-risk assumptions explicit. If a missing detail would materially change architecture or data flow, stop and ask.
Do not code immediately after this step. First produce the output schema described in [references/output-schema.md](references/output-schema.md).

### 1b. Resolve Ambiguous Mapping

If the PM or product document describes behavior only in broad terms, or if one screen has multiple plausible nodes or actions:
- Build a `screen -> candidate node` table
- Build an `action -> candidate element` table
- Assign confidence for each mapping
- Stop before code when a low-confidence mapping would change implementation

See [references/ambiguous-mapping.md](references/ambiguous-mapping.md).

### 2. Audit the Codebase

Before generating any SwiftUI:
- Find the current routing pattern: `NavigationStack`, router, coordinator, custom navigator
- Find feature state ownership: `@State`, `@Observable`, view model, reducer, store
- Find existing service clients, repositories, or `IKCoreApp` helpers
- Find reusable components, modifiers, button styles, typography helpers, asset and color tokens
- Check nearby features for the same flow shape before creating new abstractions
- **swiftui-pro audit (mandatory):** confirm the routing uses `NavigationStack` / `NavigationSplitView` (not deprecated `NavigationView`) and that destinations register via `.navigationDestination(for:)` not `NavigationLink(destination:)`. If the existing codebase **mixes** the two, **STOP** — flag to the user before writing new screens; mixing breaks navigation. See `../figma-to-swiftui/references/swiftui-pro/navigation.md`.
- **swiftui-pro audit (mandatory):** confirm shared state uses `@Observable` + `@MainActor` (iOS 17+) or `ObservableObject` + `@Published` + `@StateObject` (iOS 16 fallback) consistently — not mixed. See `../figma-to-swiftui/references/swiftui-pro/data.md`. If project baseline is iOS 16+, the legacy form is mandatory; document that decision in the screen graph output.
- **swiftui-pro audit (mandatory):** locate `Spacing`, `IKFont`, `IKCoreApp` enums and list their cases. C2 routes Figma values through them per `../figma-to-swiftui/references/swiftui-pro-bridge.md` §7. If any enum is missing, surface to the user before generating views.

Read [references/navigation-state-integration.md](references/navigation-state-integration.md) when wiring architecture.

### 3. Build a Screen Graph

Write down the feature structure before implementation:
- Screen list
- Transition edges
- Action -> side effect -> result -> next state mapping
- Shared components across screens
- Files likely to change

Read [references/feature-flow-workflow.md](references/feature-flow-workflow.md) for the recommended sequence.
The screen graph is not complete until it is expressed in the output schema from [references/output-schema.md](references/output-schema.md).

### 4. Implement Shared Feature Scaffolding First

Prefer integration-first changes:
- Route definitions
- Feature models and request/response types
- Shared state objects or view models
- Reusable subcomponents used across multiple screens

Do not create a parallel navigation or state system if the project already has one.
If the request is still ambiguous after the schema pass, stop here and ask instead of continuing into code generation.

### 5. Implement Each Screen (Phase A for all, then Phase B per screen)

Use `figma-to-swiftui`'s two-phase workflow across the whole flow.

**STOP — read this before doing anything.** The single most common failure mode in this skill is: "agent runs `figma_list_assets` + `figma_export_assets` only, writes a minimal `manifest.json` with `assetList`, satisfies the legacy hook, then proceeds to write Swift view files based on doc behavior + invented copy + invented tokens." That outcome compiles. **It does not match Figma.** If you find yourself reaching for the older split tools below, you are about to fail this skill:

- ❌ `figma_list_assets` — superseded by `figma_build_registry` (returns screens + tagged + lottie + warnings in one call)
- ❌ `figma_export_assets` — superseded by `figma_export_assets_unified` (handles tagged + fallback + lottie in one call)
- ❌ Using `get_variable_defs` raw + manually deriving `swiftName` — superseded by `figma_extract_tokens` (returns tokens with `swiftName`, `lightHex`/`darkHex`, `isCapsule` ready)

If `figma_extract_tokens` / `figma_build_registry` / `figma_export_assets_unified` are unavailable in the session, surface this to the user and stop — do not silently fall back to the older tools. The strict-fidelity rules in `figma-to-swiftui` Step C2 (no inline strings / no inline hex / no inline font sizes / no made-up token names) and the C3 Pass 1 banned-phrase grep depend on the artifacts the unified tools produce.

**Equally banned: substitute third-party Figma MCP servers.** When the required MCPs (`figma-desktop` + `figma-assets`/MCPFigma) are missing, do NOT swap in a different Figma MCP "for this run only". The Framelink / `figma-developer-mcp` server in particular advertises `mcp__figma__get_figma_data` and `mcp__figma__download_figma_images` — these tools return data in the wrong shape for this skill's gates and will produce a run that **looks** complete but fails every grounding check (registry coverage, token provenance, asset naming convention, banned-phrase grep). See `figma-to-swiftui/SKILL.md` §"Prerequisites — BANNED substitute MCPs" for the full ban list. STOP-and-tell-the-user is the only correct action; calling the substitute even once to "see what's there" is a violation. A run summary that ends *"figma-desktop MCP not present — used `mcp__figma__get_figma_data` as a functional equivalent"* is a failed run, not a successful one with a footnote.

**Self-attestation block (mandatory before writing any Swift view file).** When you reach Phase B, emit this table to the user. Every screen must show all four artifacts present. If even one row has `missing`, you are not allowed to proceed:

```
Phase A artifacts per screen
| Screen | design-context.md | screenshot.png | tokens.json | manifest.phaseA |
|---|---|---|---|---|
| <Name 1> (nodeId X)  | ✓ <bytes> | ✓ valid | ✓ <symlink to _shared> | ✓ "done" |
| <Name 2> (nodeId Y)  | ✓ <bytes> | ✓ valid | ✓ <symlink to _shared> | ✓ "done" |
...
```

The hook `figma-to-swiftui-gate.sh` enforces this at write-time — it will reject Swift writes when any of the four artifacts is missing for any screen-cache directory. Do not try to bypass the hook by writing a fake `manifest.json` with a stub `assetList`; the hook reads `phaseA: "done"` AND verifies `design-context.md` non-empty AND `tokens.json` present AND `screenshot.png` valid PNG. Fake one, the next is missing.

**Phase A sub-step A0 (flow-global): registry.** Once per flow, before fetching any screen:
1. Call `figma_build_registry(fileKey, rootNodeId, depth=10)`.
2. Save to `.figma-cache/_shared/registry.json`.
3. Pin a single `assetCatalogPath` for the whole flow (interactive prompt if the project has multiple `.xcassets`). Stash in the shared cache folder so every screen's Phase B reads the same value.
4. When delegating Phase B to `figma-to-swiftui` for each screen, pass `registryPath = .figma-cache/_shared/registry.json`. The single-screen skill's B0 reads from this file.
5. Per-screen filtering: a screen's tagged + lottie subset is the entries whose `nodeId` is (or is a descendant of) the screen's nodeId.

If `figma_build_registry` returns auth error or is not registered, surface and stop — the registry is mandatory.

**Phase A — batch-fetch ALL screens first.** For every screen in the graph, run Phase A (Step 1–4 of `figma-to-swiftui`), populating `.figma-cache/<nodeId>/` with design-context, screenshot, tokens, code-connect, assets, and a manifest. Do this for all screens in one burst, not interleaved with Phase B. Reasons:
- Minimizes total MCP exposure time (ephemeral asset URLs, session windows).
- Lets the manifest checkpoint partial progress — if a fetch fails, retry only the failed node instead of losing work.
- Keeps Phase B free of MCP calls, so it is unaffected by timeouts.

**Cluster the fetches in parallel** (mandatory for flows ≥ 3 screens). Issue one message with `parallelBudget × 2` tool calls (`get_design_context` + `get_screenshot` for each screen in the cluster), wait for all to land, then start the next cluster. Default `parallelBudget = 3` (6 tool calls in flight). Failure of one screen does NOT abort the cluster — that screen is recorded `status: "failed"` and retried serially with the circuit-breaker section-split at the end. See [`../figma-to-swiftui/references/fetch-strategy.md`](../figma-to-swiftui/references/fetch-strategy.md) §"Parallelism Inside Phase A" for the full rules (auto-degrade on repeated timeouts, wall-time accounting, override). On flows ≥ 3 screens this typically cuts Phase A wall-time by 30–50% vs. sequential per-screen fetching.

**Dedup the file-scoped data.** `figma_extract_tokens` is per `fileKey`, not per node. If all screens come from the same Figma file, fetch tokens once and copy/symlink the same `tokens.json` into each screen's cache folder.

**If a Phase A fetch fails** on a screen: the manifest records it as `failed`; continue with the next screen, then retry failed ones at the end. Do NOT retry the same node on timeout — apply the circuit breaker from fetch-strategy.md and split the screen into sections.

**No Phase A shortcut — design-context.md and screenshot.png are mandatory per screen.** Common failure modes that this rule exists to prevent:

- *"I have depth=2 metadata + the doc, I'll skip per-screen design-context fetches."* — **STOP.** Metadata has node IDs and bounds; it does NOT have styling, fonts, colors, gradients, shadows, or layout. The doc describes BEHAVIOR; the screenshot captures RENDERED VISUAL TRUTH. They are not interchangeable.
- *"Pragmatic adjustment: I'll generate SwiftUI directly from doc + judgment."* — that is hallucinated UI. C3 Pass 2 cannot run without `screenshot.png` (it diffs code against the screenshot). C5 visual diff cannot run without `screenshot.png`. Skipping the fetch silently disables both gates.
- *"To save tokens."* — fetching design-context for N screens costs orders of magnitude less than shipping divergent UI and re-doing the work.

**Per-screen Gate A enforcement.** After the Phase A batch-fetch, run **Gate A** from `figma-to-swiftui/SKILL.md` (the BASH block under "Gate A — Phase A Exit") for every screen individually. The flow does not advance to Phase B for ANY screen until that screen's Gate A prints `GATE: PASS`. Surface a per-screen Gate A status table to the user before proceeding.

**Phase B — implement offline from cache.** Once Phase A is complete (or complete-with-known-gaps that the user has accepted), implement screens one at a time in graph order. No further MCP calls in Phase B.

**Phase B order, flow-level (mandatory):**

1. **B0a — Copy extraction** (flow-level once). Walk every screen's `design-context.md`, extract every visible string with its `data-node-id`, write a single `Strings.swift` (or String Catalog) keyed by node ID. See `figma-to-swiftui/SKILL.md` Step B0a. Every `Text(...)` in subsequent view files must reference this — inline English literals are banned by C3 Pass 1.

2. **B0b — Token codegen** (flow-level once). Read `_shared/tokens.json`, generate `DesignSystem/Color+Tokens.swift`, `AppFont.swift`, `Spacing.swift` with one entry per Figma token, each carrying a `// Figma: <token-name>` comment. See Step B0b. Every Color / font / spacing in subsequent view files must come from these enums — inline hex / font sizes are banned by C3 Pass 1.

3. **Per-screen B0 → B6** (figma-to-swiftui), in graph order. Shared components processed before consumers.

Per-screen implementation rules:
- Reuse existing project components, modifiers, styles, assets, and colors before creating new ones
- Prefer `IKFont`, `IKCoreApp`, and project-native helpers over raw implementations
- Name any new Figma-derived assets with a screen or source-node prefix
- Avoid placeholder UI or fake data if the real integration already exists in the project
- **swiftui-pro structural rules apply:** each screen view in its own file; sub-sections > ~40 lines extract into separate `View` structs (in their own files), not computed properties returning `some View`. See `../figma-to-swiftui/references/swiftui-pro/views.md` and `../figma-to-swiftui/references/swiftui-pro-bridge.md` §4.
- **All generated screen views run C3 Pass 4 (swiftui-pro Review)** before declaring done. Surface a flow-level summary listing every Pass 4 finding across screens, prioritized.
- **Doc-vs-Figma conflict resolution.** When the source document describes a flow that doesn't match the Figma frames (e.g. doc says "PIN Setup → PIN Confirm" as two steps but Figma has two visually-identical frames), defer to Figma for **structure** and to the doc for **behavior**. If two Figma frames have ≥80% identical structure → they are two states of one screen (per `figma-to-swiftui` Step A2b). Build ONE view with state, not two views. Never invent a separate view to match the doc's narration.

Prefer this reuse order:
1. Code Connect mapped component
2. Existing shared design-system component or internal UI wrapper
3. Nearby feature component with the same role
4. Existing modifier, style, token, or helper
5. New feature-specific implementation only when no suitable project-native option exists

### 5.5 xcassets import order (multi-screen flows)

For each screen's Phase B:
- Tagged assets write directly into `Assets.xcassets` during B3, **per screen, in the order screens are processed**.
- The tool groups imagesets into a folder named after the root node passed in the call (the screen). Two screens that both reference `eICHome` will land as `Assets.xcassets/Screen1/icAIHome.imageset` AND `Assets.xcassets/Screen2/icAIHome.imageset` — each under its screen folder. **Xcode resolves `Image("icAIHome")` by name across the whole catalog**, so this duplication on disk is harmless at the call site.
- `skipIfExistsInCatalog` (default `true`) means a re-run will not re-download/re-import an imageset whose name already exists anywhere in the catalog. Effective behavior: the FIRST screen that processes a shared icon "wins" the import; subsequent screens silently skip it. Re-runs become cheap.
- Different source nodeIds with the same Figma name (rare; two designers used `eICClose` on different nodes) → tool deduplicates with suffix (`icAIClose_2`) and emits a warning.
- Fallback assets (untagged + FLATTEN regions) are deduped at the flow level via `_shared/assets/`, then imageset-imported in C4 per screen.
- A single `assetCatalogPath` is pinned for the entire flow at A0 (interactive prompt if the project has multiple `.xcassets`). All screens share it — do not re-prompt per screen.

### 6. Wire the Full Behavior

Complete the non-visual behavior:
- Validation rules
- Disabled and in-flight button states
- Loading, empty, error, success, and retry states
- Back/cancel handling
- Conditional navigation and guards
- Async task lifecycle and error mapping

Read [references/feature-completeness.md](references/feature-completeness.md) to avoid stopping at the happy path.

### 7. Verify at Feature Level

**Step 7 has two halves: per-screen visual validation (7a) and feature-level wiring checks (7b). Both are mandatory; neither substitutes for the other. A clean compile is NOT proof the screens look right.**

#### 7a. Per-screen C5 (build + simulator screenshot, MANDATORY)

For every screen in the flow, run **Step C5** from the single-screen skill — see [`../figma-to-swiftui/SKILL.md`](../figma-to-swiftui/SKILL.md) Step C5 + [`../figma-to-swiftui/references/verification-loop.md`](../figma-to-swiftui/references/verification-loop.md) §5. C5 builds the project, boots a simulator, installs the app, screenshots each screen, and writes a visual diff vs the Figma render to `.figma-cache/<nodeId>/c5-visual-diff.md`. Persists `manifest.verification.c5.gate` per screen.

C5 is **mandatory**. The flow's **Done-Gate** (the feature-level analogue of `figma-to-swiftui` Key Principle #12) requires every screen to satisfy one of:
- `manifest.verification.c5.gate == "PASS"`, OR
- `manifest.verification.c5.skipped` set to one of `no_project`, `simctl_error`, `ci_environment`, `no_entry_path` (auto-detected, persisted; user phrases like `skip C5` / `bỏ qua C5` are NOT honored). See `../figma-to-swiftui/references/verification-loop.md` §"C5 Verification Integrity" — adding a debug route override to the binary to bypass `no_entry_path` is **banned**.

A flow is NOT done while any screen has neither. **A successful `xcodebuild build` is not C5** — C5 requires `simctl boot` + `simctl install` + `simctl launch` + `simctl io screenshot` + visual compare. If you only ran `xcodebuild build` and stopped, you have NOT run C5; the Done-Gate is violated and you must complete C5 before declaring done.

If you cannot run C5 for a real reason (e.g. missing StoreKit config blocks the paywall from rendering, missing Lottie SDK leaves placeholders), capture the screenshot anyway and note the degraded state in the diff row — do not skip the entire C5. Partial visual evidence is better than none, and the user can decide whether the gap is acceptable.

#### 7b. Feature-level walkthrough — delegate to `ios-simulator-verify`

7a (C5) proves each screen renders correctly in isolation. **It does not prove the journey works.** A user does not stop on Welcome and visually compare it to Figma — they tap Next, then enter a PIN, then mismatch it, then recover. That sequence is what 7b verifies, and it is a separate concern from per-screen visual fidelity.

After 7a passes (or is skipped for a system reason), invoke the **`ios-simulator-verify` skill** to drive the simulator through the planned walkthrough. The flow skill's job at this step is to hand the verify skill a concrete walkthrough plan — not to re-implement simulator orchestration here.

**BANNED verification shortcuts.** None of the following count as 7b. They produce screenshots without proving the journey works, and several change the binary in ways that ship debug surface to production:

1. **Adding a launch-arg / env-var route override** (e.g. `VERIFY_ROUTE=PINSetup`, `--initial-screen=Welcome`, a `#if DEBUG` deep-link parser) and rebuilding to "jump" to each screen, then screenshotting. Reasons banned:
   - Each screen is then mounted in isolation. Navigation push, state initialization, and prerequisite-screen side effects are bypassed → the journey is NOT verified, only the views.
   - The override stays compiled into the binary (every Swift `#if DEBUG` reaches the simulator unless build configuration is `Release`). User now ships a debug entrypoint to TestFlight.
   - It teaches the agent that "if `osascript` / `computer-use` is blocked, just edit the app to make verification easier." That is the exact failure mode the rule exists to prevent.
2. **Adding `#Preview` macros to drive each screen in Xcode previews and counting that as 7b.** Previews skip real navigation, real state, and real lifecycle events. Use them for design iteration, not for journey verification.
3. **Reading the code and asserting transitions "from logic"** (e.g. *"matching confirm pushes Face ID — verified by reading `OnboardingState.handlePINComplete`"*). Code reading is C3 Pass 1 / Pass 4, not 7b. 7b requires the simulator to actually transition.
4. **Stopping at `xcodebuild build` and treating BUILD SUCCEEDED as 7b.** A clean compile fails 7b by definition.

The only allowed paths for 7b are:
- `ios-simulator-verify` skill (preferred — drives via accessibility identifiers, no binary changes).
- `computer-use` MCP with `request_access` for the Simulator app (drives by pixel taps; requires explicit user approval).
- A pre-existing test target (XCUITest / Swift Testing UI tests) that the project already ships — invoking it is fine, adding new test code purely to satisfy 7b is not.

If none of the allowed paths is available, state explicitly which axes were not driven and why, and mark the affected coverage rows `not-checked` in the verify table. **Do not silently downgrade to a banned shortcut and call the result PASS.**

What you must hand to `ios-simulator-verify`:

1. The **screen graph** from Step 3, expressed as an ordered sequence of actions ("tap Next", "type 1234", "tap close").
2. **At minimum three coverage axes**: end-to-end happy path, one recovery path (mismatch / form error / retry), one conditional fork (first-launch vs returning, premium vs free, empty vs populated).
3. **Per-step assertions**: what should be visible, what side effect must be observable (UserDefaults flag, keychain entry, navigation depth).
4. **Known degradations** the verify skill should mark `degraded` rather than fail on (e.g. no `.storekit` config means the paywall plan list will be empty — that is expected, not a regression).

What `ios-simulator-verify` returns:
- A three-column **verified / degraded / not-checked** findings table
- A directory of state-named screenshots
- A "next actions" list for closing the gaps

Surface that table in your final response. Do not silently absorb the verify skill's findings — if a row is `⚠️ degraded` because StoreKit is unconfigured, the user must see that.

If `ios-simulator-verify` is unavailable (skill not installed, simulator unavailable, CI environment), state explicitly which axes were not checked and why. **Compile-passed alone is not 7b.** A clean compile fails 7b by definition because nothing was driven through the flow.

#### 7c. Flow-level Verification summary (mandatory final block)

At the end of every run — success or failure — print this block to the user verbatim, filling in values from each screen's manifest. This is the flow analogue of the single-screen Verification summary in [`../figma-to-swiftui/SKILL.md`](../figma-to-swiftui/SKILL.md). Never fabricate a PASS — open the file with `cat` if uncertain. If a screen was skipped at the system level (`no_project`, `simctl_error`, `ci_environment`), say so explicitly so the user knows local C5 still needs to run before merge.

```
Flow Verification summary
Screen <Name 1> (nodeId <…>)
  C5 (build + simulator):      PASS / FAIL / SKIPPED (<reason>)
  C5.6 (visual diff vs Figma): PASS / FAIL (high: N, medium: N)

Screen <Name 2> (nodeId <…>)
  ...

Feature-level wiring (7b):
  Routes reachable:            PASS / FAIL (<list>)
  State transitions:           PASS / FAIL (<list>)

Artifacts:
  .figma-cache/<nodeIdN>/c5-simulator.png
  .figma-cache/<nodeIdN>/c5-visual-diff.md
```

Stating "done" / "xong" / "BUILD SUCCEEDED, closing out" without this block — or with a fabricated PASS in it — is a Done-Gate violation. If you find yourself thinking *"a clean compile felt like enough proof"* or *"runtime behavior wasn't observed but the build links"*, **STOP**. That is the exact failure mode this gate exists to prevent. Run C5 now.

## Non-Negotiable Rules

- Do not port React/Tailwind MCP output into SwiftUI directly
- Do not introduce new dependencies unless the user asks
- Do not invent backend contracts or business rules from a mockup
- Do not create duplicate tokens, duplicate routers, or duplicate shared components
- Do not stop at static UI when the request is for a feature flow
- **Never fabricate manifest fields to make a gate pass.** `manifest.json` is a record of work actually done — `phaseA = "done"` means `design-context.md`, `screenshot.png`, `metadata.json`, `tokens.json`, `registry.json` all exist on disk per screen. `phaseB = "done"` means every `rows` entry has its PNG on disk (and, for tagged rows, its imageset in the catalog). `verification.c5.gate = "PASS"` means Gate C5 actually printed `GATE: PASS`. Writing these fields to satisfy a gate's bash check WITHOUT having executed the underlying step is gaming the gate and a protocol violation. If a gate would fail, do the work — do not edit the manifest. If you find yourself writing "manifests so the gate passes", **STOP** — that is the exact failure mode this rule exists to prevent.

## Output Expectations

Before code, always emit the schema from [references/output-schema.md](references/output-schema.md).

When this skill is used well, the result should include:
- A clear feature contract
- A screen-to-node mapping with confidence
- An action-to-element mapping when the document is not explicit
- A screen graph or equivalent route plan
- A reuse plan naming the project-native patterns that will be used
- SwiftUI views for each provided node
- Integrated navigation and state handling
- Complete user-visible states for the flow
- Reuse of project-native patterns instead of parallel abstractions
