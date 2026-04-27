# MCPFigma — `figma-assets` server setup

## What this is

`figma-assets` is a separate MCP server (built from [MCPFigma](https://github.com/...)) that batch-exports designer-tagged assets (`eIC*` / `eImage*`) at iOS scales, renames them to iOS convention (`icAI*` / `imageAI*`), and (when an `assetCatalogPath` is supplied) writes `.imageset` directories directly into `Assets.xcassets`.

It complements the Figma design-context MCP (`get_metadata`, `get_design_context`, `get_screenshot`, `get_variable_defs`) — it does **not** replace it. The two run side by side:

- **Figma design-context MCP** → spec, screenshots, tokens, metadata (Phase A).
- **`figma-assets` MCP** → tagged-asset export to xcassets (Phase B fast-path).
- **`get_screenshot`** → per-node fallback for FLATTEN regions, untagged nodes, and degraded environments.

---

## Prerequisites

- macOS 13+ (Ventura)
- Swift 6.0+ (Xcode 16+ or matching toolchain) — only required to build from source
- Figma Personal Access Token with **File content read** scope (create at https://www.figma.com/settings)

---

## Install

```bash
git clone <repo-url> MCPFigma
cd MCPFigma
swift build -c release
```

Binary lives at `.build/release/mcp-figma`.

---

## Configure Claude Code

### Project-level (recommended) — `.claude/mcp.json`

```json
{
  "mcpServers": {
    "figma-assets": {
      "command": "/ABSOLUTE/PATH/TO/MCPFigma/.build/release/mcp-figma",
      "env": {
        "FIGMA_ACCESS_TOKEN": "figd_xxxxxxxxxxxxxxxxxxxxxxxxxx"
      }
    }
  }
}
```

### User-level — `~/.claude.json`

Same shape. Pick one location; if both define `figma-assets`, project-level wins.

### Claude Desktop — `~/Library/Application Support/Claude/claude_desktop_config.json`

Same shape.

After editing config: **restart Claude (Cmd+Q, reopen)** to load the server.

---

## Verify

After restart, the tool list (`tools/list`) advertises:

- `mcp__figma-assets__figma_list_assets`
- `mcp__figma-assets__figma_export_assets`

If they don't appear, run the troubleshooting steps below before proceeding to Phase B.

---

## Runtime probe contract (used by Phase B Step B0)

The skill probes availability once at the top of Phase B and falls back gracefully:

```
Step B0: figma_list_assets(fileKey, nodeId, depth=10)

Outcomes:
  a) Tool not found / not registered     → mcpfigmaAvailable = false
                                           Print: WARN: figma-assets MCP not configured
                                           Phase B uses get_screenshot for every asset
  b) Auth error (unauthorized/forbidden) → mcpfigmaAvailable = false
                                           Print: WARN: FIGMA_ACCESS_TOKEN missing or invalid
  c) 200 with empty matches AND warnings → mcpfigmaAvailable = true
                                           No tagged assets in scope; identical to fallback
  d) Matches and/or warnings returned    → mcpfigmaAvailable = true
                                           Proceed with split-path Phase B
```

Skill never retries the probe. One miss = fallback for the whole run.

---

## Data flow

```
Figma node (eICHome, eImageBanner, …)
        │
        ▼   figma_list_assets / figma_export_assets
  figma-assets MCP server (Swift)
        │
        ▼   PNG @2x + @3x, iOS naming, optional xcassets import
  /your/ios/project/Assets.xcassets/icAIHome.imageset/
                                    icAIHome@2x.png
                                    icAIHome@3x.png
                                    Contents.json
```

---

## Naming convention (designer side)

| Prefix in Figma | Meaning | Exports as |
|---|---|---|
| `eIC<Name>` | Icon | `icAI<Name>@2x.png`, `icAI<Name>@3x.png`, imageset `icAI<Name>` |
| `eImage<Name>` | Image / illustration / brand | `imageAI<Name>@2x.png`, `imageAI<Name>@3x.png`, imageset `imageAI<Name>` |

**Validation rules:**
- First character after the prefix must be ASCII uppercase: `eICHome` ✅, `eIChome` ❌
- Remaining characters: `[A-Za-z0-9_]` only: `eICHome_2` ✅, `eICHome-2` ❌, `eICHomé` ❌
- Invalid names → MCPFigma skips and emits a warning row in `figma_list_assets` output.

**Other prefixes recognized by the scanner:**
- `eAnim*` — Lottie animation placeholders. MCPFigma's scanner skips these and does NOT recurse into their children (children are designer preview keyframes). They do NOT appear in `figma_list_assets.matches`. Phase B Step B0 step 5 detects them by walking `metadata.json` separately and adds inventory rows with `kind: "lottie-placeholder"`. Phase C2 emits a `LottieView` placeholder using the literal name `"placeholder_animation"` for the developer to swap later. Full contract in [`lottie-placeholders.md`](./lottie-placeholders.md). If a tagged Lottie placeholder needs to be exported as a static raster instead, rename it to `eImage*`.

Skill behavior on validation failure: log the warning, surface to user, fall back to `get_screenshot` for that one node only. Other tagged nodes still take the MCPFigma path.

See `docs/designer-handoff.md` §9.4 for designer guidance.

---

## Tool reference

### `figma_list_assets`

Preview which assets the export would pick up, without downloading.

**Input:**
```json
{
  "fileKey": "ABC123xyz",
  "nodeId":  "1:2",
  "depth":   10
}
```

**Output:**
```json
{
  "matches": [
    { "nodeId": "1:3", "figmaName": "eICHome",       "kind": "icon",  "exportName": "icAIHome" },
    { "nodeId": "1:4", "figmaName": "eImageBanner",  "kind": "image", "exportName": "imageAIBanner" }
  ],
  "warnings": [
    { "nodeId": "1:5", "figmaName": "eIChome", "reason": "Tên 'eIChome' không hợp lệ — first char after prefix must be uppercase ASCII" }
  ]
}
```

### `figma_export_assets`

Batch-render PNG @2x + @3x, save to `outputDir`. If `xcodeProjectPath` or `assetCatalogPath` is supplied, also imports as `.imageset` into `Assets.xcassets`.

**Input:**
```json
{
  "fileKey":          "ABC123xyz",
  "nodeId":           "1:2",
  "outputDir":        ".figma-cache/<rootNodeId>/assets/_mcpfigma",
  "assetCatalogPath": "/Users/me/Project/App/Assets.xcassets",
  "nodeIds":          ["1:3", "1:4"],
  "scales":           [2, 3],
  "overwrite":        true
}
```

- `nodeIds` (optional): export a subset; omit to export every match in the registry.
- `scales` (optional): defaults to `[2, 3]`. We do not ship `@1x` for modern iOS.
- `overwrite` (optional): defaults to `true` (idempotent re-runs of the disk write).
- `skipIfExistsInCatalog` (optional, default `true`): if an imageset with the target name already exists anywhere in `.xcassets`, skip download AND import for that node. Set to `false` to force re-import. The skill leaves it default-true so Phase B re-runs after partial success only re-fetch the still-missing imagesets.
- `xcodeProjectPath` (optional): path to `.xcodeproj`/`.xcworkspace`/project root for auto-resolving the catalog.
- `assetCatalogPath` (optional): direct path to `.xcassets` — **prefer this over `xcodeProjectPath`** to avoid multi-catalog ambiguity.

**xcassets folder grouping:** when importing, MCPFigma creates a folder inside the catalog named after the root node (e.g. the screen name). Imagesets land at `Assets.xcassets/<RootNodeName>/icAI<Name>.imageset/`. Two screens that share the same icon will produce two imagesets under their respective folders by default (idempotent on re-run). To force a flat layout, the user can manually move the imagesets after import.

**Output:**
```json
{
  "savedFiles": [
    { "figmaName": "eICHome", "exportName": "icAIHome", "scale": 2, "path": "/.../_mcpfigma/icAIHome@2x.png" },
    { "figmaName": "eICHome", "exportName": "icAIHome", "scale": 3, "path": "/.../_mcpfigma/icAIHome@3x.png" }
  ],
  "skipped": [],
  "errors":  [],
  "warnings": [],
  "assetCatalog": {
    "catalogPath": "/Users/me/Project/App/Assets.xcassets",
    "savedFiles": [
      { "figmaName": "eICHome", "exportName": "icAIHome", "scale": 2, "path": ".../Assets.xcassets/icAIHome.imageset/icAIHome@2x.png" },
      { "figmaName": "eICHome", "exportName": "icAIHome", "scale": 3, "path": ".../Assets.xcassets/icAIHome.imageset/icAIHome@3x.png" }
    ],
    "skipped": [],
    "errors":  []
  }
}
```

---

## Why `assetCatalogPath` over `xcodeProjectPath`

`xcodeProjectPath` lets MCPFigma auto-resolve the `.xcassets` from the `.xcodeproj`. Fine when there's exactly one catalog, fragile otherwise (per-target catalogs, modular projects). The skill always pins `assetCatalogPath` explicitly in Step B0:

- 0 `.xcassets` → ask user to create one before Phase B (no fallback).
- 1 `.xcassets` → silent default, tell the user which one.
- N > 1 → interactive prompt; stash answer in `manifest.mcpfigma.assetCatalogPath` for re-runs.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Missing FIGMA_ACCESS_TOKEN env var` | Env not set in MCP config | Add `"env": { "FIGMA_ACCESS_TOKEN": "..." }` to mcp.json |
| Auth error / `unauthorized` | Token wrong or expired | Regenerate at https://www.figma.com/settings |
| `forbidden` | Token lacks `File content read` scope or no access to the file | Re-issue with proper scope; verify file is in your workspace |
| `notFound` | Wrong `fileKey` or `nodeId` | Re-check Figma URL; `nodeId` uses `:` not `-` |
| Empty `matches` and `warnings` | No node in scope is tagged `eIC*`/`eImage*` | Designer needs to tag (see §9.4 in handoff) — fallback path runs anyway |
| `figma_list_assets` matches but `figma_export_assets` errors on a specific node | Render failed for that node | Skill auto-falls back to `get_screenshot` for that node only |
| "Multiple `.xcassets` — please specify `assetCatalogPath`" | Project has > 1 catalog | Pass `assetCatalogPath` directly; B0 handles this |
| Claude doesn't see the tools after install | Claude wasn't restarted | Cmd+Q and reopen |
