# Fetch Strategy

Rules for calling Figma MCP tools in a way that avoids timeouts, minimizes wasted tokens, and allows retry without losing work. Shared by `figma-to-swiftui` and `figma-flow-to-swiftui-feature`.

## Core Principles

1. **Metadata before context.** `get_design_context` is the expensive, timeout-prone call. Never send it to a node you are not already confident is a single implementable unit.
2. **Cache everything in Phase A.** All MCP data lands in `.figma-cache/<nodeId>/` with a `manifest.json`. Phase B implements offline — no MCP calls, no timeouts, no re-fetches.
3. **Narrow with the document first.** When a source document was read in Step 0, use its screen list to decide which nodes actually need Phase A. Do not enumerate the whole Figma tree when the doc already tells you which screens matter.
4. **Dedup at the file scope.** Tokens and metadata for the same `fileKey` are reusable across nodes — fetch once, copy or symlink into each screen's cache folder.

## Decision Tree (Before Phase A)

```
Input node
├── Clearly a single leaf screen/component (user said so, URL points to a frame)
│   └── Run Phase A directly on that node
│
├── Root / page / "probably multi-screen" container
│   └── get_metadata first (Step 1b)
│       ├── Metadata shows 1 clear screen frame
│       │   └── Re-target node_id, run Phase A on that frame
│       └── Metadata shows multiple screens
│           └── Build screen map → hand off to flow skill
│               (flow skill runs Phase A per screen, then Phase B)
│
└── Unknown / user unsure
    └── get_metadata first, always
```

## Thresholds — When to Force Split Before Fetching Context

Treat any of these as "must run Step 1b before Phase A":
- `get_metadata` depth > 4 levels
- > 20 direct children
- node name contains words like "Page", "Flow", "Onboarding", "All Screens", "Desktop", "iPhone & iPad"
- file-level root node IDs like `0:1`
- source document names more screens than the Figma URL obviously contains

If any threshold trips, do not run Phase A on the parent. Map children first, then run Phase A per screen.

## Circuit Breaker (Inside Phase A)

If a `get_design_context` call times out or returns truncated output during Phase A:

1. Do NOT retry the same call with the same node — it will time out again.
2. Fall back to `get_metadata` on that node (save to cache).
3. From metadata, pick the smallest meaningful child that matches what you were trying to implement.
4. Run `get_design_context` on that child. Save to `.figma-cache/<nodeId>/design-context-<sectionName>.md`.
5. If the whole screen is still too large, implement it in sections: header → body → footer, one call per section.
6. Record every split decision in the manifest (status `split`, list section files).

Tell the user when you split a screen, so they know why the cache contains multiple design-context files for one node.

## Call Budget per Scope

For one feature (single screen OR multi-screen flow), expected call counts:

| Tool | Per feature |
|---|---|
| `get_metadata` | 0–1 on root (Step 1b) + 1 per timed-out node (circuit breaker) |
| `get_design_context` | 1 per screen (+ extras only if split by the circuit breaker) |
| `get_screenshot` | 1 per screen |
| `get_variable_defs` | **1 total per `fileKey`**. Deduplicate across screens from the same file. |
| `get_code_connect_map` | 1 per screen |
| `add_code_connect_map` | 1 per newly created reusable component, at the end of Phase B |

Exceeding this is a signal to stop and re-plan, not to keep fetching.

## Phase A for Multi-Screen Flows

For flows with N screens, Phase A runs **once, in a batch, for all N screens**, before any Phase B work. Sequence:

1. Read source document (if any) → extract screen list and actions (Step 0).
2. `get_metadata` on the root once, to confirm `screen → node` mapping (Step 1b).
3. `get_variable_defs` once for the `fileKey`; stash for reuse.
4. For each screen in the graph, in parallel where the session permits:
   - `get_design_context`
   - `get_screenshot`
   - `get_code_connect_map`
   - Copy/symlink the shared `tokens.json` into the screen's cache folder.
   - Download assets for this screen (URLs are ephemeral — do it during the same Phase A window, not later).
5. Write/update the manifest for each screen as calls complete.
6. If any fetch fails, mark it `failed` in the manifest and continue. Retry failed entries at the end of Phase A.

**Why batch, not lazy per-screen:**
- Ephemeral asset URLs expire — fetching late screens "just in time" risks URL expiry for assets already referenced.
- One interrupted Phase A can be resumed from the manifest; a lazy approach loses context between screens.
- Phase B is uninterrupted once Phase A is done — no context-switching between MCP and implementation.

## Document-Driven Narrowing

When a source document was read in Step 0:

- If the doc names N screens and a root Figma node is given, only fetch metadata on that root; match names to frames; run Phase A only for the N screens.
- If the doc names actions per screen, use them to resolve ambiguous elements rather than fetching deeper design-context per child.
- If the doc conflicts with what Figma contains (e.g., doc says 5 screens, Figma root has 8 frames), stop and ask — do not silently fetch the extra 3.

## Parallelism Inside Phase A

- Independent endpoints on the same node can be parallelized: `get_design_context(nodeA)` + `get_screenshot(nodeA)` + `get_code_connect_map(nodeA)` in parallel.
- Fetches for unrelated nodes can be parallelized only if the session is not timeout-prone. If you hit any timeout this session, serialize for safety.
- Never parallelize `get_metadata` with `get_design_context` on the same node — metadata informs whether context is safe to call.

## Resume & Retry

The manifest makes Phase A resumable:

- `status: done` → skip on retry.
- `status: failed` → retry this specific call only.
- `status: split` → already broken into sections; do not re-run the parent.
- No manifest → Phase A has not started; run from scratch.
- Manifest older than 24h → suggest re-fetch to user; cache may be stale.

## What NOT to Do

- Do not call `get_design_context` on a root/page/flow container "just to see what's there". Use `get_metadata`.
- Do not re-run `get_variable_defs` once per screen if the screens share a `fileKey`.
- Do not retry a timed-out call with the same parameters.
- Do not interleave Phase A and Phase B across screens — finish the Phase A batch first, then implement all screens in Phase B.
- Do not skip writing the manifest — it is the only thing that makes Phase A resumable.
