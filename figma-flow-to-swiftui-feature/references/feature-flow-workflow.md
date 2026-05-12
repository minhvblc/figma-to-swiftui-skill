# Feature Flow Workflow

Use this sequence for end-to-end feature generation from one or more Figma nodes.

## 1. Contract First

Convert the request into a feature contract. Do not begin by generating views. The contract should identify screens, transitions, actions, async work, and missing assumptions.
If the Figma input is broad or the document is vague, also build a candidate node mapping with confidence at this stage.

## 2. Audit Before Building

Inspect the codebase for:
- Existing feature modules with similar flow shape
- Current routing pattern
- State ownership pattern
- Service layer or repository pattern
- Shared components and modifiers
- Existing assets, colors, typography helpers, and modules such as `IKFont` or `IKCoreApp`

The fastest correct path is usually to copy the structure of the nearest existing feature, then adapt it to the new nodes.

## 3. Build the Screen Graph

Create an explicit mapping:
- `screen`
- `trigger`
- `side effect`
- `success state`
- `failure state`
- `next destination`

Even if this stays in notes only, think through it before editing files.
Express this graph through the output schema before touching code.

## 4. Create Shared Pieces Early

Implement shared parts before individual screens when multiple nodes depend on them:
- Route enum or destination type
- Shared feature model or view model
- Shared form section or reusable row/card component
- Shared asset and token mapping

This avoids redoing the same work inside each screen.

## 5. Generate Screen UI Per Node

For each screen:
- Fetch design context and screenshot for the node
- Reuse project components and modifiers first
- Reuse shared pieces created in step 4
- Only create new assets or colors when no suitable project-native option exists

If the `figma-to-swiftui` skill is available, use it here.
If the selected node was only a medium-confidence match, mention that in the notes and keep the implementation localized so it can be swapped with minimal rewrite.

## 6. Wire Actions and Transitions

After each screen exists visually, connect:
- User input bindings
- CTA enable/disable rules
- Async task triggers
- Loading overlays or inline progress
- Error presentation
- Success navigation
- Back/cancel behavior

Do not leave buttons visually present but functionally disconnected unless the user explicitly asked for scaffolding only.

## 7. Close the Happy-Path Gap

Most incomplete implementations stop after the first successful screen. Before finishing, verify:
- every CTA has behavior
- every async action has loading and failure handling
- every success path lands on a real destination
- every destination has a back or dismiss strategy if needed

## 8. Verify the Whole Journey

Preferred order:
1. compile or test if possible
2. preview or simulator check if available
3. reasoning pass over the state graph if runtime checks are unavailable

If you cannot run verification, say that clearly and list the highest-risk unverified pieces.

### 8.0 Per-screen visual compare: C5.6

Every screen runs the same 6-step C5.6 procedure as the single-screen skill — section inventory, element census, per-section crop pairs, free-form "what's wrong" pass, 3-axis diff table, negative spot-check, 4-anchor proportional check, attestation. See [`../../figma-to-swiftui/references/verification-loop.md` §C5.6](../../figma-to-swiftui/references/verification-loop.md#c56--side-by-side-compare-6-step-procedure-mandatory).

```bash
for nodeId in <every screen nodeId in the flow>; do
  scripts/c5-crop-sections.sh   --cache .figma-cache/$nodeId
  # C5.6 manual walk per ../../figma-to-swiftui/references/verification-loop.md §C5.6
done
```

The flow does not advance to journey-level verification (7b in `SKILL.md`) for any screen whose C5.6 manual walk is incomplete. Cross-screen concerns (navigation, state) live in 7b — they do not change C5.6 per-screen.

### 8a. Mandatory cross-screen gates: C6 + C7

After every screen has run its per-screen verification (C3 Pass 2 + C5), invoke the two cross-screen scripts once at the feature level. Both are hard fails — a flow is not done while either reports violations.

```bash
# Once per screen — uses that screen's registry.json:
for nodeId in <every screen nodeId in the flow>; do
  scripts/c6-asset-completeness.sh \
    --registry .figma-cache/$nodeId/registry.json \
    --xcassets <project>/Assets.xcassets \
    --src      <project-swift-src-root>
done

# Once for the whole feature src tree:
scripts/c7-no-system-chrome.sh --src <project-swift-src-root>
```

Both gates are documented in [`../../figma-to-swiftui/references/verification-loop.md`](../../figma-to-swiftui/references/verification-loop.md) §6 and §7. Neither has a user opt-out. Failures block the Done-Gate the same way C5 does.
