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

Prefer this reuse order:
1. Code Connect mapped component
2. Existing shared design-system component or internal UI wrapper
3. Nearby feature component with the same role
4. Existing modifier, style, token, or helper
5. New feature-specific implementation only when no suitable project-native option exists

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
