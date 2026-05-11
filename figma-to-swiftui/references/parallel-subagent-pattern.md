# Per-screen subagent delegation (P1-7) — flows ≥ 10 screens

For small flows (3–5 screens), the main agent runs Phase A + Phase B + Phase C inline. Context stays manageable.

For flows ≥ 10 screens (Bible app onboarding: 30 intro screens; profile feature: 12 variants), running everything inline burns context fast. Phase A for 30 screens alone is 30× `get_design_context` + 30× `get_screenshot` + 30 manifest writes. Phase B then writes 30 view files. By the time you reach Phase C, the main agent has consumed most of its context window on per-screen artifacts.

The solution: **delegate per-feature-area to subagents**. Main agent owns orchestration; subagents own per-feature implementation.

---

## When to delegate

✅ **Delegate when:**
- Flow has ≥ 10 screens.
- Screens cluster into ≥ 3 feature areas (e.g. Onboarding / Read / Profile / Explore).
- Each area is implementable in isolation (its own folder under `featureRoot`, minimal cross-area dependencies beyond shared DesignSystem + Navigation).
- Total Phase A artifact count would be > 50 (rough heuristic: 30 screens × ≥ 2 artifacts per screen).

❌ **Do NOT delegate when:**
- Flow has < 10 screens. Inline is faster.
- Areas share too much state (multi-area refactors are coordination-heavy).
- The user is iterating fast on a single area (subagent round-trips slow down feedback).
- Phase A artifacts already exist for most screens (delegation overhead exceeds Phase B inline cost).

---

## Delegation contract

Each subagent owns ONE feature area end-to-end:

**Inputs:**
- `featureName` — e.g. "Onboarding"
- `featureRoot` — absolute path, e.g. `/Users/me/MyApp/MyApp/Screens/Onboarding`
- `screenList` — array of `{ nodeId, name }` from `registry.screens[]` or `registry.candidateScreens[]`
- `fileKey` — Figma file key
- `figmaCachePath` — absolute path to `.figma-cache/`
- `assetCatalogPath` — absolute path to the single project `.xcassets`
- `conventionsPath` — `.figma-cache/_shared/c1-conventions.json`
- `sharedSymbols` — list of types/enums the subagent can reference (AppColor, AppFont, Spacing, Strings, AppState, …)

**Phase order (mandatory):**
1. **Phase A per screen:** fetch design-context + screenshot + asset registry per `nodeId`. Use parallel cluster of 3 (`fetch-strategy.md §Parallelism`).
2. **Asset export per screen:** `figma_export_assets_unified(autoDiscover: true)` against the shared `assetCatalogPath`. The `skipIfExistsInCatalog: true` default deduplicates across subagents.
3. **Phase B implementation:** write view files under `featureRoot/<ScreenName>.swift`. Reference `sharedSymbols` for tokens; do NOT redefine them.
4. **Per-screen C5.6:** simulator screenshot + visual diff. Each subagent owns C5 for its area.

**Outputs:**
- 1-line per-screen status table:
  ```
  ✓ IntroOneScreen.swift   Phase A ✓ B ✓ C5 PASS
  ✓ IntroTwoScreen.swift   Phase A ✓ B ✓ C5 PASS
  ⚠ IntroThreeScreen.swift Phase A ✓ B ✓ C5 DEGRADED (StoreKit unconfigured)
  ✗ IntroFourScreen.swift  Phase A ✗ — figma 404 on nodeId 1:1234
  ```
- List of new `Strings.<Feature>.*` enum cases added (so main agent merges them).
- List of new asset names imported into `.xcassets` (so other subagents see them via `skipIfExistsInCatalog`).
- Any **delta-requests** for shared mutations (new MainRoute cases, new TrackingScreen cases — only main agent merges these).

**Subagent must NOT:**
- Edit shared files: `Navigation/AppState.swift`, `Navigation/RootView.swift`, `<App>.swift`, `Core/Router/Main/MainRoute.swift`. Subagents emit delta-requests; main agent merges.
- Run `xcodegen generate` (main agent owns project regeneration).
- Touch other features' folders.
- Run the flow-level coding-conventions sweep (Step 6.5) — main agent does that after all subagents return.

---

## Main agent's orchestration

```
1. Run mode-detect.sh, write_cache. Resolve mode + conventions.
2. Run figma_build_registry. Resolve screens / candidateScreens.
3. Group screens by feature area. Heuristic:
   - Name prefix ("Intro N" → Onboarding feature)
   - Y-coordinate clusters in the flow board (similar y = same row = same feature)
   - User confirmation when ambiguous
4. For each feature area, spawn ONE subagent with the contract above.
   - Spawn in parallel via a single message with N Agent tool calls (when N ≤ 4)
   - Spawn sequentially if subagents need to see prior delta-requests merged
5. Wait for ALL subagents. Aggregate status tables.
6. Apply each delta-request: open MainRoute.swift, append new cases, etc.
   - Each delta-request is a small Edit; main agent runs c8-gate on the result.
7. Run flow-level coding-conventions sweep (Step 6.5).
8. Per-screen C5 results already in manifests; verify via c5-coverage-check.sh.
9. Write final Verification summary aggregating per-subagent reports.
```

---

## Subagent prompt template

When spawning, give the subagent a self-contained prompt:

```
You are implementing the <Onboarding> feature area of <MyApp> SwiftUI iOS app.
Project root: /Users/me/MyApp
Feature root: <ProjectRoot>/MyApp/Screens/Onboarding
Figma file key: qKOTZUKyYFV4GCn4FMMehS
Conventions: .figma-cache/_shared/c1-conventions.json (read this first)
Mode: scaffold|production (read from conventions)

Screens you own (do NOT touch others):
  - 1:793 "Intro 1"
  - 1:823 "Intro 2"
  - ...

Phase A (mandatory): for EACH screen, fetch
  - get_design_context(nodeId: <id>) → .figma-cache/<id>/design-context.md
  - get_screenshot(nodeId: <id>) → .figma-cache/<id>/screenshot.png
  - figma_export_assets_unified(
      autoDiscover: true,
      assetCatalogPath: <ProjectRoot>/MyApp/Resources/Assets.xcassets,
      sharedAssetsDir: .figma-cache/_shared/assets
    )
Cluster fetches in batches of 3 per fetch-strategy.md.

Phase B: implement per-screen view at Onboarding/<ScreenName>.swift.
  - Use AppColor / AppFont / Spacing / Strings from DesignSystem/ (do NOT redefine).
  - Use Image(.icAI<Name>) for icons (NOT Image(systemName:)).
  - Hooks will block SF Symbol substitution and convention violations.
  - For shared components like OnboardingScaffold, OptionPillButton — put them
    in <feature>/Components/, prefixed with the feature name.

C5: per screen, build + simctl launch + screenshot + visual-diff vs Figma.

DO NOT EDIT:
  - <ProjectRoot>/MyApp/MyApp.swift
  - <ProjectRoot>/MyApp/Navigation/AppState.swift
  - <ProjectRoot>/MyApp/Navigation/RootView.swift
  - Any file outside Onboarding/

DO emit delta-requests for:
  - New strings (which Strings.Onboarding.* cases you added)
  - New navigation routes needed
  - Any shared symbol you propose to extract

Return: status table + delta-requests list. Keep return ≤ 500 words.
```

---

## Failure mode: subagent silent drift

The biggest risk of delegation: a subagent silently drifts into anti-pattern §13 (template-from-doc) because the main agent isn't watching every step. Mitigations:

1. **Per-screen artifact assertion in subagent return.** Each subagent's status table line must reference a real `.figma-cache/<nodeId>/design-context.md` byte count. Main agent verifies non-zero before accepting PASS.

2. **Asset-count cross-check.** Subagent reports `assetsImported: N`. Main agent compares against `registry.taggedAssets[]` filtered to that subagent's screen subtree. If `N == 0` but registry has 50 assets for those screens, the subagent skipped asset export.

3. **C5 mandatory per screen.** Main agent rejects subagent results that mark C5 as `skipped` for non-system reasons.

4. **Sample audit.** Main agent picks 2 random screens from the subagent's domain, reads both `design-context.md` and the generated `<ScreenName>.swift`, and verifies wording + structure match. If mismatch, the subagent's work is REJECTED — re-spawn with explicit feedback.

The delegation pattern works only when the main agent stays accountable for verification. Delegating without auditing is delegating the failure.
