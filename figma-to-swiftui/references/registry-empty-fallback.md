# Registry-empty fallback — P0-8 STOP gate

When `figma_build_registry` returns and `screens[]` is empty, the agent MUST stop and resolve **before** writing any Swift view file. This is a hard precondition, not a soft warning.

This document covers two cases:
1. **`screens: [], candidateScreens: [{...}]`** — root was a Group; MCPFigma surfaced phone-sized frames it found nested. Recoverable.
2. **`screens: [], candidateScreens: []`** — neither direct screens nor candidates. Not recoverable from this rootNodeId; re-root required.

---

## Why STOP is mandatory

The single most common failure mode in the flow skill (anti-patterns.md §13: "template-from-doc") starts here. The agent sees an empty `screens[]`, reads the product doc, sees "30 onboarding questions", and proceeds to build 30 generic views from doc wording — never fetching `get_design_context` for any individual screen.

This compiles. It runs. The simulator shows screens. The screens **do not match Figma**. The damage is distributed across 30 screens and only becomes visible when the user side-by-sides each against the design.

The STOP gate exists because by the time the agent realizes its mistake, the cost to fix is high (30 redo cycles) and trust damage is higher.

---

## Case 1 — candidateScreens populated

The MCPFigma server detected phone-sized FRAME nodes nested under your Group root. Output looks like:

```json
{
  "screens": [],
  "candidateScreens": [
    { "nodeId": "1:793", "name": "Intro 1", "type": "FRAME", "width": 375, "height": 812, "depth": 2 },
    { "nodeId": "1:823", "name": "Intro 2", "type": "FRAME", "width": 375, "height": 812, "depth": 2 },
    ...
  ],
  "warnings": [
    {
      "nodeId": "<root>",
      "reason": "ROOT_IS_GROUP: root node 3:1812 is a GROUP, not a Board/Frame. Found 47 phone-sized FRAME nodes..."
    }
  ],
  "recommendedNextCall": {
    "tool": "figma_export_assets_unified",
    "rationale": "Root is a Group — direct screens empty. Use the candidateScreens nodeIds as input.",
    "argsTemplate": { ... }
  }
}
```

### Workflow

1. **Surface to user.** Output a one-line acknowledgment:
   > Registry detected root node is a Group, not a Board. Found N candidate phone-sized frames. Treating candidateScreens[] as the screen list.

2. **Treat candidateScreens as screens.** For every downstream step (Phase A fetches, asset export, Phase B implementation), iterate over `candidateScreens[]` exactly as you would `screens[]`. The semantics are identical — these ARE the screens, MCPFigma just couldn't classify them via the standard Board-children path.

3. **Fetch Phase A artifacts per candidate.** No shortcuts. Each candidateScreen.nodeId gets `get_design_context` + `get_screenshot` + `figma_export_assets_unified(autoDiscover: true)`. Cluster in parallel batches of 3 per `fetch-strategy.md`.

4. **Cross-reference the doc.** If the product doc lists "30 onboarding screens" and `candidateScreens.length === 30`, that's confirmation — wire each candidate to a doc section. If counts differ (doc says 30, Figma has 47), surface the discrepancy. Do NOT silently pick a subset.

5. **Update `c1-conventions.json`.** Add an explicit note that this run treats candidateScreens as authoritative, so future hook/skill runs don't re-trigger the warning.

### Banned actions in Case 1

- ❌ Skip Phase A for any candidate. Even when "they all look similar" — see anti-patterns.md §13.
- ❌ Build a generic template view + feed strings from the doc. Each candidate has its own wording, options, and special states discoverable only via `get_design_context`.
- ❌ Pick the first 5 candidates as "representative" and call it done.
- ❌ Treat `candidateScreens` as untrustworthy because they're "tentative" — they're phone-sized FRAMEs, MCPFigma just couldn't trace the Board ancestor.

---

## Case 2 — both empty (re-root required)

Output looks like:

```json
{
  "screens": [],
  "candidateScreens": [],
  "warnings": [],
  "recommendedNextCall": {
    "tool": "figma_build_registry",
    "rationale": "Neither screens nor candidateScreens found. Re-root on a CANVAS/PAGE/DOCUMENT ancestor.",
    "argsTemplate": { "nodeId": "<a CANVAS or PAGE ancestor>", "depth": "5" }
  }
}
```

### Workflow

1. **Hard STOP.** No Phase A, no Phase B, no Swift writes. The rootNodeId is wrong for this tool — there's nothing to enumerate.

2. **Diagnose via metadata.** Call `get_metadata(nodeId: <current root>, depth: 1)`. The response tells you:
   - What TYPE is the current root? (If it's a PAGE/CANVAS, the file has no FRAMEs — the user pointed you at an empty page.)
   - What are the current root's children? (If they're all GROUPs or SECTIONs at width < 320, this isn't a screen-bearing area.)

3. **Find the right rootNodeId.** Usually one of:
   - The CANVAS/PAGE node that's parent to the screen group (look at the file URL — `?node-id=1-2` typically points to a frame; the page is at `0:1` or similar).
   - The next ancestor up that has multiple FRAME children at 375pt width.
   - A different Figma file or page entirely — verify with the user.

4. **Re-run `figma_build_registry` with the new rootNodeId.** Document the resolved rootNodeId in `c1-conventions.json` under `figmaRootNodeId` so future runs go straight there.

### Banned actions in Case 2

- ❌ Proceed with a flat 0-screens registry. There is literally nothing to implement.
- ❌ Use the registry's `taggedAssets[]` to "infer" screens from icon names like `eICBackground375x812` (some asset names embed dimensions; this does NOT define a screen).
- ❌ Build the app off the product doc alone. See anti-patterns.md §13.
- ❌ Ask the user only "what should I do?" — propose 2–3 candidate rootNodeIds based on `get_metadata` evidence so the user picks.

---

## Gate enforcement

The flow skill SHOULD enforce STOP via:

1. **Hook:** `figma-to-swiftui-gate.sh` (PreToolUse) already blocks Swift writes when `manifest.phaseA != "done"`. As long as the manifest correctly reflects per-screen Phase A status, the empty-registry case naturally cascades into a per-file block when the agent tries to Write `IntroOneScreen.swift` without `.figma-cache/1:793/design-context.md`.

2. **Skill self-check:** Before Phase B, the agent re-reads `registry.json` and confirms `screens.length + candidateScreens.length > 0`. If both are zero AND the agent is about to Write Swift, the agent MUST surface to user and stop.

3. **Stop-gate `c6-asset-completeness.sh`:** at end-of-run, flags every Swift screen file that has no matching cache directory. A run that built 30 views off doc with 0 cache directories will fail this gate.

---

## Anti-pattern callouts

Cross-references to anti-patterns.md:
- **§1** "Build the rest with SwiftUI shapes" — applies when candidateScreens are non-empty but you didn't fetch design-context per screen → you can't see the real icons.
- **§13** "Template-from-doc" — applies when you treat the empty `screens[]` as license to skip per-screen Phase A.
- **§7** "User wanted speed not pedantry" — the pressure that makes agents skip the STOP gate. Reject it.

The STOP gate is not bureaucracy. It is the only thing standing between the user and 47 fake screens.
