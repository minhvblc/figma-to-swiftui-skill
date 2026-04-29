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
| `get_metadata` | **1 per screen (mandatory)** — needed for icon node-ID registry. Additional calls per timed-out node (circuit breaker). |
| `get_design_context` | 1 per screen (+ extras only if split by the circuit breaker) |
| `get_screenshot` | 1 per screen + 1 per flattened region + 1 per icon with no download URL (typical: 3–10 per screen) |
| `figma_extract_tokens` | **1 total per `fileKey`**. Deduplicate across screens from the same file. |
| Code Connect lookup (if MCP exposes one) | 1 per screen — optional, skip if unavailable |
| Code Connect register (if MCP exposes one) | 1 per newly created reusable component — optional, skip if unavailable |

`get_screenshot` is the workhorse for assets — it's cheap, fast, and always returns PNG. Don't skimp on per-icon calls.

Exceeding this is a signal to stop and re-plan, not to keep fetching.

## Asset Dedup Across Screens (shared nodeId store)

An icon appearing on 5 screens should be fetched **once**, stored once, referenced by all 5.

**Layout:**
```
.figma-cache/
├── _shared/assets/
│   ├── 3166_70211.png         ← keyed by source nodeId (: → _)
│   └── 3166_70211.meta.json   ← displaySize, renderingMode, friendlyName
├── <screen1NodeId>/manifest.json    ← references _shared/assets/3166_70211.png
└── <screen2NodeId>/manifest.json    ← also references _shared/assets/3166_70211.png
```

**Fetch rule (before any download):**
```bash
NODE_ID="3166:70211"
SAFE_ID="${NODE_ID//:/_}"
if [ -f ".figma-cache/_shared/assets/${SAFE_ID}.png" ]; then
  echo "SKIP: already cached"  # reuse
else
  # fetch via REST API or get_screenshot → save to _shared/assets/
fi
```

**REST API batch across screens:** Collect all unique nodeIds across ALL screens in the flow, make one batch call, download all URLs. Far cheaper than per-screen fetches.

**Asset Catalog (Step 7):** one imageset per unique source nodeId, not per screen. Screens referencing the same node share the Catalog entry → consistency automatic.

## Phase A for Multi-Screen Flows

For flows with N screens, Phase A runs **once, in a batch, for all N screens**, before any Phase B work. Sequence:

1. Read source document (if any) → extract screen list and actions (Step 0).
2. `get_metadata` on the root once, to confirm `screen → node` mapping (Step 1b).
3. `figma_extract_tokens` once for the `fileKey`; stash for reuse.
4. For each screen in the graph, in parallel where the session permits:
   - `get_design_context`
   - `get_screenshot`
   - Code Connect lookup (optional, only if MCP exposes it)
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

Phase A wall-time on a 5–8 screen flow is dominated by `get_design_context` + `get_screenshot` round-trips (~5–15s each). Sequential per-screen fetch is the #1 wall-time bottleneck. The rules below define a deterministic batch strategy that preserves the per-screen circuit breaker.

### Default cluster (mandatory for flows ≥ 3 screens)

Issue **one message with `parallelBudget × 2` tool calls** — `get_design_context` + `get_screenshot` for each screen in the cluster — and wait for all to land before starting the next cluster.

- `parallelBudget` default = **3 screens per cluster** (6 tool calls in flight).
- Persist `parallelBudget` in `.figma-cache/_shared/registry.json` under `fetchPolicy.parallelBudget` so re-runs stay deterministic.
- User may override via the source document or by saying "fetch sequentially" → set `parallelBudget = 1` and note in manifest.
- Each screen still writes its own `.figma-cache/<nodeId>/` cache + manifest entry; clusters share nothing.

### Per-screen independent endpoints (always)

Within a single screen, `get_design_context(nodeA)` + `get_screenshot(nodeA)` (+ Code Connect lookup, if available) are issued in the same parallel batch. They never serialize.

### Same-node ordering (always)

Never parallelize `get_metadata` with `get_design_context` on the **same** node — metadata informs whether context is safe to call. `get_metadata` for all screens may itself be parallelized in one cluster (it is cheap and timeout-resistant).

### Cluster failure handling

When a cluster lands, partition results:

- **All success** → write manifest entries `phaseA: "done"` for each screen, advance to next cluster.
- **Partial success** → succeeded screens are committed; failed screens are recorded `status: "failed"` in their manifest with the error reason, and **excluded from subsequent clusters**. Continue clustering with remaining screens.
- **Timeout on a specific screen** → that screen drops out of the parallel path entirely. After all clusters finish, retry failed screens **one at a time using the circuit-breaker section-split** below — never retry the same parallel call shape.
- **Auth / 401-403 (any tool, including `figma_extract_tokens`)** → STOP the entire Phase A and surface to user; this is not a per-screen issue. Do **NOT** treat `forbidden` from `figma_extract_tokens` as the "Variables API not available" case — that case is HTTP 200 with empty arrays + warnings (see "Token-extract fallback rule" below). Confusing the two leads to the agent silently proceeding without Variables data when the real fix is a token re-issue. STOP, show the verbatim error to the user, link to `references/mcpfigma-setup.md` §Troubleshooting.

### Token-extract fallback rule (`figma_extract_tokens` only)

`figma_extract_tokens` has three distinct outcomes. Do not collapse them:

| Outcome | Signal | Allowed action |
|---|---|---|
| **Success** | HTTP 200, `colors[]` / `typography[]` populated, `warnings[]` empty (or per-section advisory only). | Use the returned `tokens.json` directly. |
| **Empty (Variables API not exposed by file plan)** | HTTP 200, `colors[]` / `typography[]` empty, `warnings[]` non-empty. | Fall back to inline tokens parsed from `design-context.md` per `references/design-token-mapping.md`. Write `tokens.json` with `_note: "reconstructed from inline styles — Variables API empty + warnings"`. |
| **Permission failure** | HTTP 401 (`unauthorized`) or HTTP 403 (`forbidden`). | **STOP**. Do NOT fall back. Surface verbatim to the user with the fix path: re-issue PAT at https://figma.com/settings with scopes `File content: Read` + `Variables: Read`, and verify the file is in the token-owner's workspace. See `references/mcpfigma-setup.md` §Troubleshooting. |

The same three-outcome split applies to `figma_build_registry` and `figma_export_assets_unified` — `forbidden` is always a STOP, never a fallback trigger.

### Auto-degrade on session-wide timeout pressure

If two clusters in a row produce ≥ 1 timeout, halve `parallelBudget` for the rest of the run (3 → 2 → 1) and record the degrade in `fetchPolicy.degraded: true`. This keeps a flaky session from cascading.

### Wall-time accounting

Each screen's manifest records `timing.phaseA.startedAt` / `endedAt`; the flow-level run summary should print wall-time delta vs. theoretical sequential (sum of per-screen durations) so regressions in batch size show up immediately.

## Resume & Retry

The manifest makes Phase A resumable:

- `status: done` → skip on retry.
- `status: failed` → retry this specific call only.
- `status: split` → already broken into sections; do not re-run the parent.
- No manifest → Phase A has not started; run from scratch.
- Manifest older than 24h → suggest re-fetch to user; cache may be stale.

## What NOT to Do

- Do not call `get_design_context` on a root/page/flow container "just to see what's there". Use `get_metadata`.
- Do not re-run `figma_extract_tokens` once per screen if the screens share a `fileKey`.
- Do not retry a timed-out call with the same parameters.
- Do not interleave Phase A and Phase B across screens — finish the Phase A batch first, then implement all screens in Phase B.
- Do not skip writing the manifest — it is the only thing that makes Phase A resumable.
