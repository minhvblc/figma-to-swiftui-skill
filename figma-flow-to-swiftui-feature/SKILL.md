---
name: figma-flow-to-swiftui-feature
description: "Orchestrate one or more Figma nodes plus a user-provided feature flow brief into a production-ready SwiftUI feature. Trigger when the user wants a full user journey, end-to-end flow, or multi-screen feature in an iOS project, including navigation, state handling, validation, loading/error/success states, and project-aware integration. Requires BOTH the figma-desktop MCP (get_metadata / get_design_context / get_screenshot) AND the MCPFigma server (figma_build_registry / figma_extract_tokens / figma_export_assets_unified) — STOP if either is missing, never improvise. Use together with figma-to-swiftui when pixel-accurate screen generation is also required."
---

# Figma Flow to SwiftUI Feature Skill

Turn one or more Figma nodes plus a feature-flow brief into a complete SwiftUI feature. This skill owns orchestration, completeness, and integration. It does not replace `figma-to-swiftui`; it coordinates feature-level work around it.

## Mandatory Output Checklist

Every flow run MUST satisfy these five items. Cite each item by number in the verification report.

1. **Every visible icon, logo, illustration, and image is sourced from Figma.** No `Image(systemName:)` or hand-drawn `Path` / `Shape` substituting for a Figma node. Allow-list exceptions documented in [`../figma-to-swiftui/references/verification-loop.md` §6](../figma-to-swiftui/references/verification-loop.md#6-c6--asset-completeness-mandatory). Enforced per screen by `scripts/c6-asset-completeness.sh` AND at write-time by `scripts/hooks/figma-to-swiftui-banned-pattern-gate.sh`.
2. **No iOS system chrome is redrawn in SwiftUI.** Status bar, home indicator, Dynamic Island, notch are rendered by iOS — and the iPhone bezel (the rounded outline of the entire frame, ~47–55pt) is rendered by the hardware itself. Drawing any of them is a bug; on real devices the user gets duplicates or a "double bezel" gutter. Enforced by `scripts/c7-no-system-chrome.sh` over the entire feature src tree (status-bar / home-indicator / Dynamic Island redraws AND screen-root `.cornerRadius`/`.clipShape(.rect(cornerRadius:))` ≥ 30pt without `// allow-screen-corner-radius:` justification) — see [`../figma-to-swiftui/references/verification-loop.md` §7](../figma-to-swiftui/references/verification-loop.md#7-c7--no-system-chrome-mandatory) + [`../figma-to-swiftui/references/anti-patterns.md` §11](../figma-to-swiftui/references/anti-patterns.md).
3. **Asset export is exhaustive on every screen.** Each `figma_export_assets_unified` call passes `autoDiscover: true` so the server scans the subtree under that screen's `nodeId` and auto-builds rows for every `eIC*` / `eImage*` found. The response's `coverage` block is the proof. See [`../figma-to-swiftui/references/mcpfigma-setup.md` §"figma_export_assets_unified"](../figma-to-swiftui/references/mcpfigma-setup.md). Enforced at write-time by `scripts/hooks/figma-to-swiftui-gate.sh`: every `registry.taggedAssets[].nodeId` MUST appear in `manifest.rows[]` with `status: "done"` before any `*.swift` Write/Edit is allowed.
4. **Visual diff is decisive, not weasel-worded — per screen.** Every screen's C5.6 must produce `c5-sections.md`, `c5-census.md`, per-section crop pairs, free-form "what's wrong" paragraph, 3-axis diff table, negative spot-check, 4-anchor proportional check, and attestation. No "approximately", "roughly", "close enough" in PASS rows. See [`../figma-to-swiftui/references/verification-loop.md` §C5.6](../figma-to-swiftui/references/verification-loop.md#c56--side-by-side-compare-6-step-procedure-mandatory). Enforced per screen by `scripts/c5-coverage-check.sh` and `scripts/c5-weasel-detect.sh`.
5. **Every screen follows the project's coding conventions.** The flow-level convention probe at Step 2 writes `.figma-cache/_shared/c1-conventions.json` (see [`../figma-to-swiftui/references/adaptation-workflow.md` §0](../figma-to-swiftui/references/adaptation-workflow.md#0-convention-probe-mandatory-run-before-the-audit)) which gates all c8-* scripts: `c8-conventions-gate.sh`, `c8-vm-pattern.sh`, `c8-func-length.sh`, `c8-iknavigation.sh`, `c8-ikfont.sh`, `c8-ikpopup.sh`, `c8-ikfeedback.sh`, `c8-iktracking.sh`, `c8-iklocalized.sh`. Folder layout, ViewModel pattern (State + Action + `send(_:)` reducer), function size, and (when project uses them) IKNavigation / IKMacros / IKFont / IKPopup / IKFeedback / IKTracking / IKLocalized routing are all enforced PER SCREEN at the end of each Phase C run, plus once at flow level after Step 6 over the full feature tree. Reference files: [`../figma-to-swiftui/references/project-structure.md`](../figma-to-swiftui/references/project-structure.md), [`../figma-to-swiftui/references/viewmodel-pattern.md`](../figma-to-swiftui/references/viewmodel-pattern.md), [`../figma-to-swiftui/references/swift-style.md`](../figma-to-swiftui/references/swift-style.md), [`../figma-to-swiftui/references/iknavigation-bridge.md`](../figma-to-swiftui/references/iknavigation-bridge.md), [`../figma-to-swiftui/references/ikmacro-bridge.md`](../figma-to-swiftui/references/ikmacro-bridge.md). For Ikame projects (`usesIKCoreApp == true`): [`../figma-to-swiftui/references/ikame-decision-table.md`](../figma-to-swiftui/references/ikame-decision-table.md) (master locked conventions, D-IDs that subagents reference instead of inventing), [`../figma-to-swiftui/references/ikxcodegen-bridge.md`](../figma-to-swiftui/references/ikxcodegen-bridge.md), [`../figma-to-swiftui/references/ikpopup-bridge.md`](../figma-to-swiftui/references/ikpopup-bridge.md), [`../figma-to-swiftui/references/ikfeedback-bridge.md`](../figma-to-swiftui/references/ikfeedback-bridge.md), [`../figma-to-swiftui/references/iktracking-bridge.md`](../figma-to-swiftui/references/iktracking-bridge.md), [`../figma-to-swiftui/references/iklocalized-bridge.md`](../figma-to-swiftui/references/iklocalized-bridge.md). Phase 0 mode detection: `scripts/mode-detect.sh`.

**Concrete failure modes catalogued:** [`../figma-to-swiftui/references/anti-patterns.md`](../figma-to-swiftui/references/anti-patterns.md) lists the exact agent justifications that produced broken multi-screen runs ("downloaded major assets, built the rest with shapes", "build → screenshot → looks great without C5.6", "edit ContentView to jump between screens for verification"). Read once before Phase B and once before writing the Flow Verification summary.

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
- **swiftui-pro audit (mandatory):** confirm the routing uses `NavigationStack` / `NavigationSplitView` (not deprecated `NavigationView`) and that destinations register via `.navigationDestination(for:)` not `NavigationLink(destination:)`. If the existing codebase **mixes** the two, **STOP** — flag to the user before writing new screens; mixing breaks navigation. See `../figma-to-swiftui/references/swiftui-pro/navigation.md`. **NOTE:** when the convention probe (next bullet) sets `usesIKNavigation = true`, this swiftui-pro check inverts — the mandatory state is IKNavigation throughout, NOT vanilla NavigationStack; see `../figma-to-swiftui/references/iknavigation-bridge.md`.
- **swiftui-pro audit (mandatory):** confirm shared state uses `@Observable` + `@MainActor` (iOS 17+) or `ObservableObject` + `@Published` + `@StateObject` (iOS 16 fallback) consistently — not mixed. See `../figma-to-swiftui/references/swiftui-pro/data.md`. If project baseline is iOS 16+, the legacy form is mandatory; document that decision in the screen graph output.
- **swiftui-pro audit (mandatory):** locate token enums by canonical and alternative names — `Spacing` / `AppSpacing` / `Padding`, `IKFont` / `AppFont` / `Typography`, `IKCoreApp` / `AppColors` / `ColorPalette`. List their cases. C2 routes Figma values through whichever is detected per `../figma-to-swiftui/references/swiftui-pro-bridge.md` §3. When a project has none of these, the skill falls back to inline literals + `@ScaledMetric` (the bridge §7 fallbacks) — do NOT introduce a new enum file unless the user explicitly asks.
- **Coding-conventions probe (mandatory, flow-shared).** Run the convention probe ONCE for the entire flow per [`../figma-to-swiftui/references/adaptation-workflow.md` §0](../figma-to-swiftui/references/adaptation-workflow.md#0-convention-probe-mandatory-run-before-the-audit). Write the result to `.figma-cache/_shared/c1-conventions.json`. Every per-screen Phase C reads this same file — do not re-probe per screen. Resolved fields the screen graph (Step 3) must respect:
  - `screenFolderConvention` — drives where each new `*Screen.swift` / `*ViewModel.swift` lands. Three modes: **`one-screen-per-folder`** (canonical Ikame and non-Ikame; `Screens/<Name>/<Name>Screen.swift` co-located with `<Name>ViewModel.swift`), `flat`, `ikame-feature-flat` (brownfield Ikame; `Screens/<Feature>/<Feature>HomeScreen.swift` + `ViewModel/`, `Subviews/`, `Models/` subfolders). See [`../figma-to-swiftui/references/project-structure.md`](../figma-to-swiftui/references/project-structure.md).
  - `viewModelPattern` + `viewToRouteWiring` — every new ViewModel uses State + Action + `send(_:)` reducer. Route delivery: **`publishedRoute`** canonical (`@Published var route: Route?` bound to `.navigationDestination(item:)`) or `routePublisher` brownfield Ikame (`let routePublisher = PassthroughSubject<Route, Never>()`). See [`../figma-to-swiftui/references/viewmodel-pattern.md`](../figma-to-swiftui/references/viewmodel-pattern.md) §1 + §1b and [`ikame-ios-coding/references/viewmodel.md`](../../ikame-ios-coding/references/viewmodel.md).
  - `usesIKNavigation` (+ `routers[]` + `routerLayout`) — when true, the flow EXTENDS the matching feature's `<Feature>Route.swift` + `<Feature>Router.swift` pair under `Core/Router/<Feature>/`; compose routers with `+`. **Canonical layout `per-feature`**; brownfield single-`MainRouter` layout (`routerLayout: "single"`) extends only that single router. Do NOT introduce vanilla `NavigationStack(path:)` at screen root. See `../figma-to-swiftui/references/iknavigation-bridge.md` §5 and `ikame-ios-coding/references/iknavigation.md`.
  - `usesIKMacros` (+ `apiRegistry`) — when true AND the flow needs new networking, generate `@APIProtocol` repositories and expose them through the `enum API` registry (`apiRegistry.registryFilePath`, typically `Core/Network/API.swift`). Inject `<sharedRepoExpr>` (e.g. `sharedRepo` or `AppAPIRepository.shared`). Call sites use `API.<name>Repository`, never `<Name>RepositoryImpl(...)` directly. See `../figma-to-swiftui/references/ikmacro-bridge.md` and `ikame-ios-coding/references/api-ikmacros.md`.
  - `fontModifier` (+ `fontFamily` + `additionalFontFamilies[]`), `spacingEnum`, `colorEnum` — token routing. Canonical Ikame typography uses `ikFont` preset family (`.ikLargeTitle()` / `.ikBody()` / `.ikFont(size:weight:)` escape hatch); brownfield projects with `fontModifier: "appFont"` use `.appFont*` wrappers. See `../figma-to-swiftui/references/fonts-styling-bridge.md` and `ikame-ios-coding/references/fonts-and-styling.md`.
  - **Ikame cascade flags** (set when `usesIKCoreApp == true`, i.e. project's Podfile has `pod 'IKCoreApp'` OR any Swift file imports it):
    - `usesIKPopup` (+ `popupConfigurations[]` + `popupInvocationStyle`) — popups go through `await IKPopup.shared.popup { … }` / `.sheet { … }` / `.show(configuration:) { … }` (canonical closure form) or `IKPopup.shared.showPopup(swiftUIView:configuration:)` (brownfield named-args form). Vanilla `.sheet` / `.alert` require `// allow-vanilla-popup: <reason>` justification (D-507). See [`../figma-to-swiftui/references/ikpopup-bridge.md`](../figma-to-swiftui/references/ikpopup-bridge.md) and `ikame-ios-coding/references/ui-popup-toast-loading.md`.
    - `usesIKFeedback` (+ `toastApi` + `appToastWrapper`) — canonical toast `IKToast.show(.<id>, message:)`; brownfield wrapper `AppUtils.shared.showAppBottomToast(for: .<case>)` when C1 captures `toastApi: "appToastWrapper"`. Loading via `IKLoading.showLoading()` + `defer { dismissLoading() }`. Haptics via `IKHaptics.<api>`. See [`../figma-to-swiftui/references/ikfeedback-bridge.md`](../figma-to-swiftui/references/ikfeedback-bridge.md).
    - `usesIKTracking` (+ `trackingEnumName` + `trackingEnumPath`) — every new screen has `.ikLogScreenActive(<trackingEnumName>.<case>)` mandatory; programmatic tracking via `AppTrackingFeature.shared.addTrackingFeature(...)`. See [`../figma-to-swiftui/references/iktracking-bridge.md`](../figma-to-swiftui/references/iktracking-bridge.md). New cases require delta-request — subagents NEVER mutate the shared enum directly.
    - `usesIKLocalized` — two paths per [`../figma-to-swiftui/references/iklocalized-bridge.md`](../figma-to-swiftui/references/iklocalized-bridge.md): `Text("...")` literal (SwiftUI auto-localizes via LocalizedStringKey) vs `"...".ikLocalized()` (String constants and non-Text APIs). The double-localize pattern `Text("...".ikLocalized())` is BANNED (silently disables auto-localization).
    - `usesIKAssetSymbol` — `Image(.<assetName>)` (iOS 17+ auto-generated `ImageResource`, also produced by Ikame's IKAssetSymbol macro). The legacy string form `Image("<assetName>")` is BANNED on the Xcode 15+ baseline regardless of this flag — the flag now only distinguishes Ikame's macro path from Apple's auto-gen path.
    - `entitiesPath` (+ `entitiesPrefix` + `entitiesSources`) — when the flow introduces a new app-wide model, place it at `<entitiesPath>/<source>/<entitiesPrefix><Domain>Model.swift` (or `<entitiesPath>/<entitiesPrefix><Domain>Model.swift` when project groups flat). Prefix is project-specific (`G` in authenv2 for GRDB; may be empty in other projects). Subagents emit delta-requests rather than write to `Entities/` directly.
  - **Decision-table reference** — when `usesIKCoreApp == true`, every per-screen subagent reads [`../figma-to-swiftui/references/ikame-decision-table.md`](../figma-to-swiftui/references/ikame-decision-table.md) for the locked patterns (D-IDs). Subagents MAY NOT invent alternatives to D-101..D-1305 — they reference rows by ID and STOP-and-escalate via delta-request when an ambiguity falls outside the table (decision-table §16).
  - **Mode detection** — at flow start, run `scripts/mode-detect.sh <projectFolder>` to classify as `greenfield | brownfield-ikame | brownfield-vanilla | ambiguous`. Greenfield-Ikame requires `ikxcodegen` scaffold before Phase A — see [`../figma-to-swiftui/references/ikxcodegen-bridge.md`](../figma-to-swiftui/references/ikxcodegen-bridge.md) §1. The skill must NOT generate raw `.xcodeproj` for greenfield Ikame; always go through `ikxcodegen`. Ambiguous mode → STOP and ask the user before scaffolding over existing files.

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

**Ikame projects (`usesIKCoreApp == true`) — mandatory placement rules.** When Step 2 detected the Ikame umbrella, shared scaffolding goes to the Ikame topology per [`../figma-to-swiftui/references/ikame-decision-table.md`](../figma-to-swiftui/references/ikame-decision-table.md) D-201..D-218:

- **Routes** — when `routerLayout == "per-feature"` (canonical Ikame), extend the matching `Core/Router/<Feature>/<Feature>Route.swift` enum + `<Feature>Router.swift` `makeView(from:)` switch. When a new feature module is needed, create the per-feature folder `Core/Router/<NewFeature>/{<NewFeature>Route,<NewFeature>Router}.swift` and compose with `+` at app start. When `routerLayout == "single"` (brownfield, single `MainRouter`), extend that single router. Do NOT create a parallel route enum or feature router in the same layout the project already uses unless the user explicitly asks for a new module.
- **App-wide models** — `<entitiesPath>/<source>/<entitiesPrefix><Domain>Model.swift` (D-214). Prefix is project-specific. New models that the flow uniquely needs go here — flow-only models stay in `Screens/<Feature>/Models/`.
- **Shared services** — `Core/Services/<Name>Service.swift` (D-210b) when the service is consumed by ≥2 features. A service initially scoped to 1 feature lives in `Screens/<Feature>/ViewModel/`. **MUST promote** the moment a 2nd feature consumes it.
- **Shared subcomponents** — `Components/App<Name>View.swift` (cross-cutting reusable, App prefix) or `Components/<Name>View.swift` (domain-specific). Multi-file components use folder form `Components/<Name>View/`. (D-212, D-213)
- **Tracking enum extension** — when the flow introduces new tracked screens / dialogs / actions, **emit delta-requests** for new `<trackingEnumName>` cases. The Step-4 pass owns merging them into `<trackingEnumPath>`; subagents at Step 5 never modify that file directly.
- **Toast type extension** — same protocol. New `<toastTypeEnumName>` cases come from delta-requests resolved at Step 4.
- **App entry / Environments / Podfile** — DO NOT MODIFY. These are owned by `ikxcodegen` (greenfield) or by the existing project (brownfield). Wiring features into the app happens through `MainRouter` extension only.

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
| Screen | design-context.md | screenshot.png | tokens.json | fills.json | manifest.phaseA |
|---|---|---|---|---|---|
| <Name 1> (nodeId X)  | ✓ <bytes> | ✓ valid | ✓ <symlink to _shared> | ✓ <N interesting nodes> | ✓ "done" |
| <Name 2> (nodeId Y)  | ✓ <bytes> | ✓ valid | ✓ <symlink to _shared> | ✓ <N interesting nodes> | ✓ "done" |
...
```

The hook `figma-to-swiftui-gate.sh` enforces this at write-time — it will reject Swift writes when any of the five artifacts is missing for any screen-cache directory. Do not try to bypass the hook by writing a fake `manifest.json` with a stub `assetList`; the hook reads `phaseA: "done"` AND verifies `design-context.md` non-empty AND `tokens.json` present AND `screenshot.png` valid PNG AND `fills.json` parseable. Fake one, the next is missing.

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

**Phase B early-start pipeline (RECOMMENDED on first run).** Per `../figma-to-swiftui/SKILL.md` §"Step A3+ — Phase B early-start pipeline", `figma_export_assets_unified(autoDiscover: true)` per screen can ride along in the same cluster as A3 calls when (a) the flow's `assetCatalogPath` is already pinned at A0 and (b) registry warnings don't change the asset plan. Effective cluster shape becomes `parallelBudget × 3` tool calls (design-context + screenshot + B3 per screen, default 9 in flight at `parallelBudget=3`). Cross-validation per screen (B1 inventory vs `manifest.rows[]`) runs after the cluster lands — same rules as single-screen. On a 4-6 screen flow this typically saves an additional **30-60s** over sequential A3-then-B3-per-screen, by overlapping every B3 with adjacent A3 fetches AND with each other within the cluster. Auto-degrade still applies: if a cluster produces ≥1 timeout, halve `parallelBudget` for the rest of the run AND fall back to sequential B3 (run after Phase A done) for the remainder.

**Dedup the file-scoped data.** `figma_extract_tokens` is per `fileKey`, not per node. If all screens come from the same Figma file, fetch tokens once and copy/symlink the same `tokens.json` into each screen's cache folder.

**If a Phase A fetch fails** on a screen: the manifest records it as `failed`; continue with the next screen, then retry failed ones at the end. Do NOT retry the same node on timeout — apply the circuit breaker from fetch-strategy.md and split the screen into sections.

**No Phase A shortcut — design-context.md and screenshot.png are mandatory per screen.** Common failure modes that this rule exists to prevent:

- *"I have depth=2 metadata + the doc, I'll skip per-screen design-context fetches."* — **STOP.** Metadata has node IDs and bounds; it does NOT have styling, fonts, colors, gradients, shadows, or layout. The doc describes BEHAVIOR; the screenshot captures RENDERED VISUAL TRUTH. They are not interchangeable.
- *"Pragmatic adjustment: I'll generate SwiftUI directly from doc + judgment."* — that is hallucinated UI. C3 Pass 2 cannot run without `screenshot.png` (it diffs code against the screenshot). C5 visual diff cannot run without `screenshot.png`. Skipping the fetch silently disables both gates.
- *"To save tokens."* — fetching design-context for N screens costs orders of magnitude less than shipping divergent UI and re-doing the work.

**Per-screen Gate A enforcement.** After the Phase A batch-fetch, run **Gate A** from `figma-to-swiftui/SKILL.md` (the BASH block under "Gate A — Phase A Exit") for every screen individually. The flow does not advance to Phase B for ANY screen until that screen's Gate A prints `GATE: PASS`. Surface a per-screen Gate A status table to the user before proceeding.

**Phase B — implement offline from cache.** Once Phase A is complete (or complete-with-known-gaps that the user has accepted), implement screens one at a time in graph order. No further MCP calls in Phase B.

**Phase B order, flow-level (mandatory):**

1. **B0a — Copy extraction** (flow-level once). **Fast path:** loop over screens, calling `scripts/b0a-extract-copy.sh --design-context .figma-cache/<nodeId>/design-context.md --output <project>/DesignSystem/Strings.swift --screen-name <ScreenName> --merge` for each. The `--merge` flag preserves prior screens' enums and adds the new screen as a sibling. Every `Text(...)` in subsequent view files must reference this — inline English literals are banned by C3 Pass 1. See `figma-to-swiftui/SKILL.md` Step B0a.

2. **B0b — Token codegen** (flow-level once). **Fast path:** `scripts/b0b-tokens-codegen.sh --tokens .figma-cache/_shared/tokens.json --xcassets <Assets.xcassets> --out <project>/DesignSystem/`. One call emits `Color+Tokens.swift` (light-only colors), `AppFont.swift` (non-Ikame only — skipped when `usesIKFont == true`; Ikame projects use `ikFont` preset family directly per `figma-to-swiftui/references/fonts-styling-bridge.md` §3), `Spacing.swift`, plus dual-mode colorsets in the catalog. Every Color / font / spacing in subsequent view files must come from these — inline hex / font sizes are banned by C3 Pass 1. See `figma-to-swiftui/SKILL.md` Step B0b and `figma-to-swiftui/references/fonts-styling-bridge.md` §2.

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
- The tool groups imagesets into a folder named after the root node passed in the call (the screen). Two screens that both reference `eICHome` will land as `Assets.xcassets/Screen1/icAIHome.imageset` AND `Assets.xcassets/Screen2/icAIHome.imageset` — each under its screen folder. **Xcode resolves `Image(.icAIHome)` (iOS 17+ auto-generated `ImageResource`) by name across the whole catalog**, so this duplication on disk is harmless at the call site.
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

### 6.5. Flow-level coding-conventions sweep (BASH, mandatory)

Per-screen Phase C already runs Pass 5 (`scripts/c8-*.sh`) over each screen's generated files — see [`../figma-to-swiftui/SKILL.md`](../figma-to-swiftui/SKILL.md) Step C3 Pass 5. Step 6 added cross-screen router wiring + shared scaffolding (Step 4) which per-screen sweeps could not see, so a single flow-level sweep over the whole feature tree catches the rest.

**Fast path (recommended):** `scripts/c8-all.sh --src "$SWIFT_SRC" --conventions .figma-cache/_shared/c1-conventions.json` runs all six c8-* sub-gates in parallel; same enforcement semantics as the sequential block below. The explicit form remains valid when the script is unavailable.

```bash
SWIFT_SRC="<project-root or feature-folder>"
CONV=".figma-cache/_shared/c1-conventions.json"
FAIL=0

scripts/c8-conventions-gate.sh --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1
scripts/c8-vm-pattern.sh       --src "$SWIFT_SRC" || FAIL=1
scripts/c8-func-length.sh      --src "$SWIFT_SRC" || FAIL=1
scripts/c8-iknavigation.sh     --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1
scripts/c8-ikfont.sh           --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1
scripts/c8-ikpopup.sh          --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1
scripts/c8-ikfeedback.sh       --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1
scripts/c8-iktracking.sh       --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1
scripts/c8-iklocalized.sh      --src "$SWIFT_SRC" --conventions "$CONV" || FAIL=1
scripts/c8-weak-self.sh        --src "$SWIFT_SRC"

[ $FAIL -eq 0 ] && echo "GATE: PASS (Step 6.5 — flow-level coding conventions)" \
                 || { echo "GATE: FAIL (Step 6.5) — fix violations before Step 7"; exit 1; }
```

The sweep is informed by `c1-conventions.json` written at Step 2 — gates auto-skip when the corresponding flag is off (e.g. IKNavigation gate is `SKIP` when `usesIKNavigation = false`; the four ik-* gates added for Ikame skip when `usesIKPopup` / `usesIKFeedback` / `usesIKTracking` / `usesIKLocalized = false`).

### 7. Verify at Feature Level

**Step 7 has two halves: per-screen visual validation (7a) and feature-level wiring checks (7b). Both are mandatory; neither substitutes for the other. A clean compile is NOT proof the screens look right.**

#### 7a. Per-screen C5 (build + simulator screenshot, MANDATORY)

For every screen in the flow, run **Step C5** from the single-screen skill — see [`../figma-to-swiftui/SKILL.md`](../figma-to-swiftui/SKILL.md) Step C5 + [`../figma-to-swiftui/references/verification-loop.md`](../figma-to-swiftui/references/verification-loop.md) §5. C5 builds the project, boots a simulator, installs the app, screenshots each screen, and writes a visual diff vs the Figma render to `.figma-cache/<nodeId>/c5-visual-diff.md`. Persists `manifest.verification.c5.gate` per screen.

The C5.6 visual-compare procedure is the **same 6-step structured walk** the single-screen skill uses — section inventory, element census, per-section crop pairs, free-form "what's wrong" pass, 3-axis diff table, negative spot-check, 4-anchor proportional check, attestation. See [`../figma-to-swiftui/references/verification-loop.md` §C5.6](../figma-to-swiftui/references/verification-loop.md#c56--side-by-side-compare-6-step-procedure-mandatory). Run `scripts/c5-coverage-check.sh --cache .figma-cache/<nodeId>` per screen as part of Gate C5; the flow does not advance to 7b for any screen whose Gate C5 is not PASS or system-skipped. Cross-screen flow concerns (navigation, state) are 7b's job — they do not change C5.6 per-screen.

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
   - Enforced at write-time by `scripts/hooks/figma-to-swiftui-entry-bypass-gate.sh`: edits to `*App.swift`/`*ContentView.swift`/`*RootView.swift`/etc. that set `initialStep`/`currentStep`/`verifyStep` to a screen literal, look up `VERIFY_ROUTE`, or add `#if DEBUG` deep-link handlers are blocked. Legitimate flow-state initialization carries `// figma-entry-bypass-gate: legitimate-flow-state` to bypass.
2. **Repeated rebuild-with-different-initial-step pattern.** A common variant of #1: change `ContentView`'s initial step to `.splash`, rebuild, screenshot. Change to `.intro1`, rebuild, screenshot. Repeat for each screen. The agent justifies this as "the simulator CLI can't tap, so I'll boot each screen separately." This is the same bypass as #1 spread over N rebuilds — each individual edit triggers `figma-to-swiftui-entry-bypass-gate.sh`.
3. **Adding `#Preview` macros to drive each screen in Xcode previews and counting that as 7b.** Previews skip real navigation, real state, and real lifecycle events. Use them for design iteration, not for journey verification.
4. **Reading the code and asserting transitions "from logic"** (e.g. *"matching confirm pushes Face ID — verified by reading `OnboardingState.handlePINComplete`"*). Code reading is C3 Pass 1 / Pass 4, not 7b. 7b requires the simulator to actually transition.
5. **Stopping at `xcodebuild build` and treating BUILD SUCCEEDED as 7b.** A clean compile fails 7b by definition.
6. **Build → screenshot → "looks great" without running C5.6.** Capturing a simulator PNG and asserting visual fidelity from a glance is not C5. C5.6 requires `c5-sections.md` (≥ 4 sections), `c5-census.md` (element counts), per-section crop pairs, free-form "what's wrong first" pass, 3-axis diff table (≥ 3 × section count rows), negative spot-check, 4-anchor proportional check, and attestation. Skipping any of these → `c5-coverage-check.sh` fails → Stop hook blocks termination.

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
- **Never fabricate manifest fields to make a gate pass.** `manifest.json` is a record of work actually done — `phaseA = "done"` means `design-context.md`, `screenshot.png`, `metadata.json`, `tokens.json`, `fills.json`, `registry.json` all exist on disk per screen. `phaseB = "done"` means every `rows` entry has its PNG on disk (and, for tagged rows, its imageset in the catalog). `verification.c5.gate = "PASS"` means Gate C5 actually printed `GATE: PASS`. Writing these fields to satisfy a gate's bash check WITHOUT having executed the underlying step is gaming the gate and a protocol violation. If a gate would fail, do the work — do not edit the manifest. If you find yourself writing "manifests so the gate passes", **STOP** — that is the exact failure mode this rule exists to prevent.

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
