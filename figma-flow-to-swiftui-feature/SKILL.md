---
name: figma-flow-to-swiftui-feature
description: "Orchestrate one or more Figma nodes plus a user-provided feature flow brief into a production-ready SwiftUI feature. Trigger when the user wants a full user journey, end-to-end flow, or multi-screen feature in an iOS project, including navigation, state handling, validation, loading/error/success states, and project-aware integration. Use together with figma-to-swiftui when pixel-accurate screen generation is also required."
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

- `get_metadata` on the root **once**, to confirm screen → node mapping.
- `get_variable_defs` **once per fileKey**; copy/symlink the resulting `tokens.json` into each screen's cache folder instead of refetching per screen.
- `figma_list_assets` (MCPFigma) **once on the root flow node**, after `get_metadata` confirms screen mapping. The result is the **flow-global tagged-asset registry** — every match has a single source nodeId regardless of how many screens reference it. Cache as `.figma-cache/_shared/mcpfigma-list.json`. The registry is per `(fileKey, rootNodeId)`, not per screen; the single-screen skill filters it by sub-tree containment per screen.
- If `figma_list_assets` is unavailable (server not configured, token bad), log it once at the flow level. Each screen's Phase B falls back to `get_screenshot` independently — do not retry the probe per screen.
- **Lottie placeholders (`eAnim*`)** are detected per-screen by walking the screen's `metadata.json` in single-screen B0 step 5 — no flow-global pre-fetch is needed. Each screen's Phase B inventory ends up with `kind: "lottie-placeholder"` rows; Phase C2 codegens `LottieView` stubs using the literal name `"placeholder_animation"`. See `../figma-to-swiftui/references/lottie-placeholders.md`. The flow skill should surface a combined end-of-run summary across all screens listing every placeholder the developer needs to replace.
- Run `figma-to-swiftui`'s **Phase A for ALL screens** in one batch (populates `.figma-cache/<nodeId>/` + manifest per screen), then run Phase B for each screen in graph order. Do not interleave A and B across screens.
- If any call times out, apply the circuit breaker in fetch-strategy.md. Do not retry the same node — split into sections instead.
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

Use `figma-to-swiftui`'s two-phase workflow across the whole flow:

**Phase A sub-step A0 (flow-global): tagged-asset registry.** Once per flow, before fetching any screen:
1. Call `figma_list_assets(fileKey, rootNodeId, depth=10)`.
2. Save to `.figma-cache/_shared/mcpfigma-list.json`.
3. Pin a single `assetCatalogPath` for the whole flow (interactive prompt if the project has multiple `.xcassets`). Stash in the shared cache folder so every screen's Phase B reads the same value.
4. When delegating Phase B to `figma-to-swiftui` for each screen, pass `mcpfigmaListPath = .figma-cache/_shared/mcpfigma-list.json`. The single-screen skill's B0 step reads from this file instead of re-calling `figma_list_assets` per screen.
5. The single-screen skill filters the global registry per screen: a screen's tagged-asset registry is the subset of global matches whose `nodeId` is (or is a descendant of) the screen's nodeId.

If `figma_list_assets` returns auth error or the tool is not registered, skip A0 entirely and let each screen fall back to `get_screenshot` independently (the single-screen skill handles this in B0).

**Phase A — batch-fetch ALL screens first.** For every screen in the graph, run Phase A (Step 1–4 of `figma-to-swiftui`), populating `.figma-cache/<nodeId>/` with design-context, screenshot, tokens, code-connect, assets, and a manifest. Do this for all screens in one burst, not interleaved with Phase B. Reasons:
- Minimizes total MCP exposure time (ephemeral asset URLs, session windows).
- Lets the manifest checkpoint partial progress — if a fetch fails, retry only the failed node instead of losing work.
- Keeps Phase B free of MCP calls, so it is unaffected by timeouts.

**Dedup the file-scoped data.** `get_variable_defs` is per `fileKey`, not per node. If all screens come from the same Figma file, fetch tokens once and copy/symlink the same `tokens.json` into each screen's cache folder.

**If a Phase A fetch fails** on a screen: the manifest records it as `failed`; continue with the next screen, then retry failed ones at the end. Do NOT retry the same node on timeout — apply the circuit breaker from fetch-strategy.md and split the screen into sections.

**Phase B — implement offline from cache.** Once Phase A is complete (or complete-with-known-gaps that the user has accepted), implement screens one at a time in graph order. No further MCP calls in Phase B.

Per-screen implementation rules:
- Reuse existing project components, modifiers, styles, assets, and colors before creating new ones
- Prefer `IKFont`, `IKCoreApp`, and project-native helpers over raw implementations
- Name any new Figma-derived assets with a screen or source-node prefix
- Avoid placeholder UI or fake data if the real integration already exists in the project
- **swiftui-pro structural rules apply:** each screen view in its own file; sub-sections > ~40 lines extract into separate `View` structs (in their own files), not computed properties returning `some View`. See `../figma-to-swiftui/references/swiftui-pro/views.md` and `../figma-to-swiftui/references/swiftui-pro-bridge.md` §4.
- **All generated screen views run C3 Pass 4 (swiftui-pro Review)** before declaring done. Surface a flow-level summary listing every Pass 4 finding across screens, prioritized.

Prefer this reuse order:
1. Code Connect mapped component
2. Existing shared design-system component or internal UI wrapper
3. Nearby feature component with the same role
4. Existing modifier, style, token, or helper
5. New feature-specific implementation only when no suitable project-native option exists

### 5.5 xcassets import order (multi-screen flows)

For each screen's Phase B:
- Tagged assets (MCPFigma path) write directly into `Assets.xcassets` during B3a, **per screen, in the order screens are processed**.
- MCPFigma groups imagesets into a folder named after the root node passed in the call (the screen). Two screens that both reference `eICHome` will land as `Assets.xcassets/Screen1/icAIHome.imageset` AND `Assets.xcassets/Screen2/icAIHome.imageset` — each under its screen folder. **Xcode resolves `Image("icAIHome")` by name across the whole catalog**, so this duplication on disk is harmless at the call site (SwiftUI doesn't care which folder it's in).
- `skipIfExistsInCatalog` (default `true`) means a re-run will not re-download/re-import an imageset whose name already exists anywhere in the catalog. Effective behavior: the FIRST screen that processes a shared icon "wins" the import; subsequent screens silently skip it. Re-runs become cheap.
- Different source nodeIds with the same Figma name (rare; two designers used `eICClose` on different nodes) → MCPFigma deduplicates with suffix (`icAIClose_2`). Surface as a warning.
- Untagged assets (`get_screenshot` path) are written in Phase C4 per screen, after the screen's view code is done.
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

Verify the whole flow, not just each screen:
- Routes are reachable
- State transitions are coherent
- Errors surface on the correct screen
- Success moves to the correct next screen
- Shared components stay consistent across the journey

If the project has tests for similar features, extend that pattern. If verification cannot be run, say exactly what was not checked.

## Non-Negotiable Rules

- Do not port React/Tailwind MCP output into SwiftUI directly
- Do not introduce new dependencies unless the user asks
- Do not invent backend contracts or business rules from a mockup
- Do not create duplicate tokens, duplicate routers, or duplicate shared components
- Do not stop at static UI when the request is for a feature flow

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
