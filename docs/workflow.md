# Workflow — How the Skills Work End-to-End

This document describes the runtime flow of the two skills in this repo, how they decide between single-screen and feature-flow mode, how they read a source document before touching Figma, and how they avoid MCP timeouts and wasted tokens.

For the designer-facing side of this, see [designer-handoff.md](./designer-handoff.md).

## Inputs the Agent Expects

The user may send any combination of:

- A **source document** — `.txt`, `.md`, PM brief, spec, ticket description, Slack/email snippet. Describes the feature's behavior, screen list, actions, async work, and constraints.
- **Figma node(s)** — a URL with `node-id`, multiple URLs, a root/page node, or a live Figma desktop selection.
- **Free-text intent** — "adapt this existing screen to match Figma", "build the full signup flow", etc.

The doc is authoritative for **behavior and scope**. Figma is authoritative for **visuals inside that scope**.

## High-Level Flow

```
┌────────────────────────────────────────────────────────────────────┐
│ Step 0 — Read Source Document (if provided)                        │
│   extract: feature_goal, screens, actions, async, states,          │
│            constraints, out_of_scope                                │
└─────────────────────────────┬──────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────────┐
│ Route: single screen vs feature flow                               │
│   see figma-to-swiftui/references/source-document.md               │
└──────────┬────────────────────────────┬────────────────────────────┘
           │                            │
   single screen                multi-screen / flow
           │                            │
           ▼                            ▼
  ┌────────────────────┐      ┌───────────────────────────────────┐
  │  figma-to-swiftui  │      │ figma-flow-to-swiftui-feature     │
  │  Phase A: fetch &  │      │   normalize → audit → graph →     │
  │    cache to        │      │   Phase A for ALL screens in a    │
  │    .figma-cache/   │      │   batch → then Phase B per screen │
  │  Phase B: offline  │      │   (delegates to figma-to-swiftui) │
  │    implement       │      │                                   │
  └─────────┬──────────┘      └───────────────┬───────────────────┘
            │                                 │
            ▼                                 ▼
  ┌────────────────────────────────────────────────────────────────┐
  │ Fetch Discipline (shared)                                      │
  │   figma-to-swiftui/references/fetch-strategy.md                │
  │   — metadata-first, Phase A batch + manifest, dedup tokens per │
  │     fileKey, circuit breaker on timeout, resumable via manifest │
  └────────────────────────────────────────────────────────────────┘
```

## Routing: Single Screen vs Feature Flow

Decided from the inputs, before any Figma call:

| Input shape | Skill |
|---|---|
| 1 Figma node, no doc (or doc describes 1 screen only) | `figma-to-swiftui` only |
| Multiple Figma nodes, OR a root/page node that contains multiple screens, OR a doc describing a journey with transitions | `figma-flow-to-swiftui-feature` |
| 1 URL but doc lists multiple screens | Screen discovery first, then decide |
| No doc, multiple URLs OR a root node | Ask the user: single screen or flow? |

The flow skill does not replace the screen skill — it **orchestrates** around it. For each screen in a flow, it calls `figma-to-swiftui` (or follows the same rules locally) for the node-level translation.

## Step 0 — Read the Source Document

Triggered whenever a document is present. Extract a compact contract:

```text
Feature: <one line>
Screens (expected): <from doc, may not match Figma yet>
Entry point: <where the flow starts>
Actions: <per-screen primary/secondary actions>
Async work: <API calls, persistence, auth>
Required states: <loading, error, empty, retry, success>
Constraints: <libraries, architecture, tokens>
Out of scope: <anything the doc explicitly excludes>
Unclear: <items needing user confirmation>
```

This contract drives every later step. It is also used to narrow Figma fetches — if the doc names 4 screens, the agent maps exactly 4 frames rather than enumerating the whole Figma tree.

**Conflict rules** (`source-document.md`):
- Doc names a screen not in Figma → ask, don't invent.
- Figma has a frame the doc doesn't mention → ask, don't silently add.
- Doc specifies behavior (validation, timing) not visible in Figma → implement from the doc.
- Doc says "out of scope" → don't implement, even if Figma shows it.

## Fetch Discipline

The hard lesson baked into the skills: `get_design_context` is the expensive, timeout-prone call. The entire fetch strategy is organized around **not** calling it on ambiguous/large nodes.

### Order of Calls (per feature)

```
Phase A — Fetch & Cache (MCP-dependent)
  1. get_metadata       — on root, once, when node is not obviously a leaf
  2. Per screen in scope:
       get_design_context    — → .figma-cache/<nodeId>/design-context.md
       get_screenshot        — → .figma-cache/<nodeId>/screenshot.png
       get_variable_defs     — once per fileKey; reuse across screens
       get_code_connect_map  — → .figma-cache/<nodeId>/code-connect.json
       download assets       — ephemeral localhost URLs, do NOT defer
       write manifest.json   — status tracking, enables partial retry

Phase B — Implement Offline (no MCP)
  Read cache, audit project, implement SwiftUI, copy assets into
  the Xcode project. No network calls, no timeouts.
  At the end: add_code_connect_map for new reusable components.
```

### Metadata-First (default for non-leaf nodes)

`get_metadata` runs before Phase A's batch whenever the node is **not obviously** a single leaf screen. Triggers:

- root node (`0:1`), page node, container named "Flow/Onboarding/Page/All Screens"
- `get_metadata` depth > 4 or children > 20
- the Step 0 document names more screens than the Figma URL seems to point at

If metadata reveals multiple screens, the agent hands off to `figma-flow-to-swiftui-feature` instead of running Phase A on the root. Flow skill then runs Phase A **for all screens in one batch**, then Phase B per screen.

### Phase A is a Batch, Not Lazy

Why not fetch screen-by-screen just-in-time?

- **Ephemeral asset URLs.** The localhost URLs returned by `get_design_context` expire. Pulling late screens hours after early ones risks URL expiry for already-downloaded references. Batching keeps the download window tight.
- **Resumable progress.** The per-screen `manifest.json` records what's cached. If a fetch fails, retry only that entry — work on other screens is not lost.
- **Phase B is unaffected by MCP state.** Once Phase A is done, implementation runs offline. No interleaved "fetch screen N, implement screen N, fetch screen N+1" rhythm where a mid-flow timeout derails the whole session.

### Dedup at File Scope

- `get_variable_defs` is keyed by `fileKey`, not `nodeId`. Call it **once per file**; copy or symlink the resulting `tokens.json` into each screen's cache folder.
- `get_metadata` on the root covers scope mapping for all screens in the file — no need to re-run per screen unless the circuit breaker triggers.

### Circuit Breaker (on timeout or truncation, inside Phase A)

```
get_design_context timeout
         │
         ▼
  Do NOT retry same node
         │
         ▼
  get_metadata on that node → save to cache
         │
         ▼
  Pick smallest meaningful child that matches the target
         │
         ▼
  get_design_context on that child → .../design-context-<section>.md
         │
         ▼ (if still too large)
  Split further: header / body / footer — one cache file per section
         │
         ▼
  Record split status in manifest.json
```

### Resume via Manifest

Every Phase A call writes its status into `.figma-cache/<nodeId>/manifest.json`:

- `status: done` → skip on retry.
- `status: failed` → retry this specific call only.
- `status: split` → already broken into sections; don't re-run the parent.
- No manifest → start Phase A from scratch.
- Manifest older than 24h → stale; suggest re-fetch.

The user can say "continue fetch" to resume Phase A, or "implement from cache" to skip straight to Phase B if cache is intact.

### Call Budget (sanity check)

| Tool | Per feature |
|---|---|
| `get_metadata` | 0–1 on root + 1 per timed-out node (circuit breaker) |
| `get_design_context` | 1 per screen (+ extras if split) |
| `get_screenshot` | 1 per screen |
| `get_variable_defs` | **1 per fileKey**, deduped across screens |
| `get_code_connect_map` | 1 per screen |
| `add_code_connect_map` | 1 per new reusable component, at end of Phase B |

Exceeding this is a signal to stop and re-plan, not to keep fetching.

## End-to-End Example — Doc + Multi-Screen Flow

User sends: a `signup.txt` describing Login → OTP → Profile Setup → Home, and a Figma root URL.

1. **Step 0**: agent reads `signup.txt`, extracts the contract. Finds 4 screens, 3 async calls, validation rules per screen.
2. **Route**: doc describes a journey → `figma-flow-to-swiftui-feature`.
3. **Normalize** (`flow-input-contract.md`): produce the feature contract + output schema.
4. **Scope mapping**: `get_metadata` on root → match 4 frames to the 4 doc screens, build node mapping table.
5. **Audit codebase**: find router pattern, service layer, `IKFont`, `IKCoreApp`, nearest similar feature.
6. **Screen graph**: emit screen → transition → side-effect → state table.
7. **Phase A — batch-fetch all 4 screens**:
   - `get_variable_defs` once for the file → symlink into all 4 cache folders.
   - For each of Login, OTP, Profile Setup, Home (in parallel where possible):
     - `get_design_context` → cache
     - `get_screenshot` → cache
     - `get_code_connect_map` → cache
     - Download assets → cache (ephemeral URLs — do it now)
     - Write/update `manifest.json`
   - Retry any screen whose manifest shows `failed`.
8. **Shared scaffolding (Phase B starts)**: route enum, feature view model, shared components.
9. **Phase B — implement per screen, offline from cache**: Login → OTP → Profile Setup → Home. No MCP calls.
10. **Wire behavior**: validation, disabled states, loading, error, retry, success navigation — from the doc's required states, not just Figma.
11. **Verify**: compile, preview, or reasoning pass over the state graph.

If the session ends between Phase A and Phase B (context limit, user break), Phase B can resume in a new conversation from the cache alone.

## End-to-End Example — Single Screen, No Doc

User sends one Figma URL pointing at a single frame, asks to build it.

1. **Step 0**: no doc → skip.
2. **Route**: 1 node, 1 screen → `figma-to-swiftui` only.
3. **Step 1**: parse URL → `fileKey` + `nodeId`.
4. **Step 1b**: URL points at a leaf frame → skip metadata.
5. **Phase A (Steps 2–4)**: batch-fetch `get_design_context`, `get_screenshot`, `get_variable_defs`, `get_code_connect_map`, download assets → all into `.figma-cache/<nodeId>/`, write manifest.
6. **Phase B (Steps 5–9)**: read cache, audit dependencies, implement in SwiftUI, copy assets into Xcode project. Validate if user asked. Register Code Connect map if component is reusable.

## What This Buys

- **Token efficiency**: no blind `get_design_context` on roots; no repeated `get_variable_defs`; doc narrows Phase A to screens actually in scope.
- **Timeout resilience**: metadata-first + circuit breaker + manifest mean a single timeout is recoverable — retry one entry, not the whole feature.
- **Resumability**: Phase B can run in a separate conversation entirely from cache. Lost context is not lost work.
- **Scope correctness**: the doc (not Figma mockups) decides what is in scope and what isn't.
- **Parity between single and flow**: one set of fetch rules, one place to change them (`fetch-strategy.md`).

## Reference Map

- [figma-to-swiftui/SKILL.md](../figma-to-swiftui/SKILL.md) — single-screen workflow (Phase A/B)
- [figma-flow-to-swiftui-feature/SKILL.md](../figma-flow-to-swiftui-feature/SKILL.md) — feature-flow orchestration (Phase A batch → Phase B per screen)
- [figma-to-swiftui/references/source-document.md](../figma-to-swiftui/references/source-document.md) — doc extraction + routing decision
- [figma-to-swiftui/references/fetch-strategy.md](../figma-to-swiftui/references/fetch-strategy.md) — metadata-first, Phase A batch, circuit breaker, manifest, call budget
- [figma-to-swiftui/references/screen-discovery.md](../figma-to-swiftui/references/screen-discovery.md) — confidence table format
- [figma-to-swiftui/references/asset-handling.md](../figma-to-swiftui/references/asset-handling.md) — PNG-only policy, format validation, no SF Symbols
- [figma-flow-to-swiftui-feature/references/flow-input-contract.md](../figma-flow-to-swiftui-feature/references/flow-input-contract.md) — feature contract fields
- [figma-flow-to-swiftui-feature/references/output-schema.md](../figma-flow-to-swiftui-feature/references/output-schema.md) — required pre-code output
