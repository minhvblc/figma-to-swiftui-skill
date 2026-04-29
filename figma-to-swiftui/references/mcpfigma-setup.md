# MCPFigma — `figma-assets` server setup

## What this is

`figma-assets` (built from MCPFigma, Swift) is the single MCP server that powers Phase A discovery + Phase B asset pipeline + Phase C token mapping. It consolidates what used to be three separate concerns:

- **Asset discovery** — designer-tagged nodes (`eIC*` / `eImage*`), Lottie placeholders (`eAnim*`), and screen-like FRAMEs all in one walk.
- **Asset export** — tagged path (xcassets pipeline @2x/@3x) and fallback path (Figma `/v1/images` → shared cache + PNG validation) in one call.
- **Token extraction** — Figma local Variables → SwiftUI naming (camelCase, `lightHex`/`darkHex`, `isCapsule` for radius).

The Figma design-context MCP (`get_design_context`, `get_screenshot`, `get_metadata`) still runs alongside for screenshots and JSX spec — figma-assets does not replace it.

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

Binary lives at `.build/release/mcp-figma`. Server self-reports as `mcp-figma 0.3.0` — versions ≥ 0.3.0 add typography extraction (`figma_extract_tokens` now returns `tokens.json.typography[]` from `/v1/files/<key>/styles` + `/v1/files/<key>/nodes`). Older 0.2.x binaries silently skip the typography section; the skill falls back to `design-context.md` inline tokens.

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

## Tools advertised

After restart, `tools/list` advertises five tools. The skill uses three of them as the primary surface; the other two stay for backward compat / debugging:

| Tool | Purpose | Skill phase |
|---|---|---|
| `figma_build_registry` | One walk → `screens`, `taggedAssets`, `lottiePlaceholders`, `warnings` | A2 |
| `figma_export_assets_unified` | One call → tagged + fallback pipeline, returns full manifest | B3 |
| `figma_extract_tokens` | Local variables → SwiftUI tokens with naming + light/dark | A3 |
| `figma_list_assets` | Preview tagged matches without exporting | rarely; `figma_build_registry` covers this |
| `figma_export_assets` | Lower-level tagged-only export (no fallback) | rarely; `figma_export_assets_unified` covers this |

---

## Tool reference

### `figma_build_registry`

**Input:**
```json
{ "fileKey": "ABC123", "nodeId": "1:2", "depth": 10 }
```

**Output:**
```json
{
  "rootNode": { "nodeId": "1:2", "name": "OnboardingFlow", "type": "CANVAS" },
  "screens": [
    { "nodeId": "3166:70147", "name": "Welcome", "type": "FRAME",
      "width": 375, "height": 812 }
  ],
  "taggedAssets": [
    { "nodeId": "1:3", "figmaName": "eICHome", "kind": "icon", "exportName": "icAIHome" }
  ],
  "lottiePlaceholders": [
    { "nodeId": "3166:71000", "figmaName": "eAnimLoading", "width": 120, "height": 120 }
  ],
  "warnings": [
    { "nodeId": "1:5", "figmaName": "eIChome",
      "reason": "Tên 'home' không hợp lệ — first char after prefix must be uppercase ASCII" }
  ]
}
```

Screen detection rule: any direct-child FRAME of root (or root itself, if root is FRAME) with width in 320…1024 pt range. Containers (`CANVAS`/`PAGE`/`DOCUMENT`) recurse one level.

### `figma_export_assets_unified`

**Input:**
```json
{
  "fileKey":          "ABC123",
  "nodeId":           "3166:70147",
  "outputDir":        "/abs/path/.figma-cache/3166:70147/assets",
  "sharedAssetsDir":  "/abs/path/.figma-cache/_shared/assets",
  "assetCatalogPath": "/abs/path/Project/App/Assets.xcassets",
  "rows": [
    { "nodeId": "3166:70211", "exporter": "tagged",   "exportName": "icAIClose" },
    { "nodeId": "3166:70200", "exporter": "fallback", "friendlyName": "heroArtwork", "strategy": "flatten" },
    { "nodeId": "3166:71000", "exporter": "fallback", "friendlyName": "placeholder_animation", "strategy": "lottiePlaceholder" }
  ],
  "scales":              [2, 3],
  "fallbackScale":       3,
  "overwrite":           true,
  "skipIfExistsInCatalog": true
}
```

`outputDir` and `sharedAssetsDir` are absolute paths. `assetCatalogPath` is required when any tagged row is present.

**Output:**
```json
{
  "rows": [
    {
      "nodeId": "3166:70211",
      "exporter": "tagged",
      "strategy": "atomic",
      "status": "done",
      "exportName": "icAIClose",
      "outputPath": "/abs/.../assets/_mcpfigma/icAIClose@3x.png",
      "imagesetPath": "/abs/.../Assets.xcassets/Welcome/icAIClose.imageset",
      "xcassetsImported": true,
      "sharedPath": null,
      "friendlyName": null,
      "reason": null
    },
    {
      "nodeId": "3166:70200",
      "exporter": "fallback",
      "strategy": "flatten",
      "status": "done",
      "sharedPath": "/abs/.../_shared/assets/3166_70200.png",
      "friendlyName": "heroArtwork",
      "exportName": null,
      "outputPath": null,
      "imagesetPath": null,
      "xcassetsImported": false,
      "reason": null
    },
    {
      "nodeId": "3166:71000",
      "exporter": "fallback",
      "strategy": "lottiePlaceholder",
      "status": "done",
      "friendlyName": "placeholder_animation",
      "exportName": null, "outputPath": null,
      "imagesetPath": null, "xcassetsImported": false,
      "sharedPath": null, "reason": null
    }
  ],
  "warnings": [],
  "assetCatalogPath": "/abs/.../Assets.xcassets"
}
```

### Internal pipeline behavior

1. Tagged rows → batch render @2x/@3x via `/v1/images` → write PNG to `outputDir/_mcpfigma/` → import into `assetCatalogPath` as `Assets.xcassets/<RootName>/<exportName>.imageset/`. SwiftUI's `Image("<exportName>")` resolves by name across the whole catalog regardless of folder.
2. Fallback rows → check `sharedAssetsDir/<nodeId-with-:_>.png` for a cached PNG (skip if found and `overwrite=false`) → batch render at `fallbackScale` via `/v1/images` → download → validate first 8 bytes match PNG signature (`89 50 4E 47 0D 0A 1A 0A`) → save to shared cache. Non-PNG (SVG/XML) → row marked `failed` with reason. Tool **never** converts SVG locally.
3. Tagged row whose render fails → automatically promoted to fallback path; final row reports `exporter: "fallback"` with both reasons concatenated.
4. Lottie rows → no network call, returned with `status: "done"` for codegen.

### `figma_extract_tokens`

**Input:**
```json
{ "fileKey": "ABC123" }
```

**Output:**
```json
{
  "colors": [
    { "figmaName": "primary/500", "swiftName": "primary500",
      "lightHex": "#FF0080", "darkHex": "#E60074" }
  ],
  "spacing": [
    { "figmaName": "spacing/md", "swiftName": "md", "value": 12, "isCapsule": false }
  ],
  "radius": [
    { "figmaName": "radius/full", "swiftName": "full", "value": 9999, "isCapsule": true }
  ],
  "opacity": [],
  "other": [],
  "warnings": []
}
```

Naming style:
- Color uses `joinAll` (`primary/500` → `primary500`).
- Spacing/radius/opacity drop the leading collection segment (`spacing/md` → `md`).
- Radius value ≥ 999 → `isCapsule: true` (`Capsule()` instead of `RoundedRectangle`).
- Mode pairs are detected by mode name: `light` / `default` / `mode 1` → `lightHex`; `dark` → `darkHex`.
- Color aliases (variable references) are resolved up to 4 hops; longer chains land in `warnings`.

`warnings` non-empty + all tokens empty + HTTP 200 → file does not have Variables API access (Figma plan limit). Skill falls back to reading inline tokens from `design-context.md`. **This rule applies only when the response is HTTP 200.** A `forbidden` (403) or `unauthorized` (401) error is a token-scope / file-access problem and is **NOT** a fallback trigger — STOP and ask the user to fix the token (see Troubleshooting below).

---

## Naming convention (designer side)

| Prefix in Figma | Meaning | Exports as |
|---|---|---|
| `eIC<Name>` | Icon | `icAI<Name>@2x.png`, `icAI<Name>@3x.png`, imageset `icAI<Name>` |
| `eImage<Name>` | Image / illustration / brand | `imageAI<Name>@2x.png`, `imageAI<Name>@3x.png`, imageset `imageAI<Name>` |
| `eAnim<Name>` | Lottie animation placeholder | NOT exported as PNG; codegen as `LottieView` stub |

**Validation rules:**
- First character after the prefix must be ASCII uppercase: `eICHome` ✅, `eIChome` ❌
- Remaining characters: `[A-Za-z0-9_]` only: `eICHome_2` ✅, `eICHome-2` ❌, `eICHomé` ❌
- Invalid names → registry warning; the node falls back to fallback path (icons/images) or is skipped (Lottie).

See `docs/designer-handoff.md` §9.4 for designer guidance.

---

## Why `assetCatalogPath` is required (no `xcodeProjectPath` auto-resolve)

Projects with multiple `.xcassets` (per-target, per-feature, modular) cannot be auto-resolved safely. The skill always pins `assetCatalogPath` explicitly in B0:

- 0 `.xcassets` → ask user to create one before Phase B (no fallback for the import step).
- 1 `.xcassets` → silent default, tell the user which one.
- N > 1 → interactive prompt; stash answer in `manifest.assetCatalogPath` for re-runs.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Missing FIGMA_ACCESS_TOKEN env var` | Env not set in MCP config | Add `"env": { "FIGMA_ACCESS_TOKEN": "..." }` to mcp.json |
| Auth error / `unauthorized` (HTTP 401) on any tool | Token wrong, expired, or revoked | Regenerate PAT at https://www.figma.com/settings. Skill MUST stop and ask — no fallback path is allowed for 401. |
| `forbidden` (HTTP 403) on `figma_extract_tokens` | PAT missing `File content: Read` and/or `Variables: Read` scope, OR file is in a workspace the token-owner does not belong to | Re-issue PAT with both scopes enabled (the Variables scope is **off by default**). Verify the file opens in a browser logged in as the token-owner. Restart Claude after updating mcp config. **Do NOT fall back to inline tokens for this case** — that fallback is only for the empty-with-warnings case below. |
| `forbidden` (HTTP 403) on `figma_build_registry` or `figma_export_assets_unified` | Same as above — token scope or workspace access | Same fix as above. STOP, do NOT improvise (do NOT enumerate sibling frames manually, do NOT swap in a substitute MCP). |
| `notFound` | Wrong `fileKey` or `nodeId` | Re-check Figma URL; `nodeId` uses `:` not `-` |
| `figma_build_registry` returns empty `screens[]` AND `rootNode.type` is `VECTOR` / `TEXT` / `INSTANCE` | Root is a leaf (icon, label, single component) | Point the skill at a parent FRAME instead |
| `figma_build_registry` returns empty `screens[]` AND `rootNode.type` is `SECTION` | Section container holds the actual frames as children, but the registry tool does not currently recurse into SECTION | Surface the section's child FRAME list to the user and ask which one to point at, OR pass the parent CANVAS / PAGE node ID. **Do NOT silently enumerate the section's siblings yourself** — that bypasses the screen-detection rules (320–1024pt width range) and includes off-canvas drafts. Tracking issue: server-side recursion into SECTION should be added to MCPFigma. |
| `figma_build_registry` returns empty `screens[]` AND `rootNode.type` is `CANVAS` / `PAGE` with > 0 FRAME children but none in 320–1024pt width range | Frames are desktop / oversize / web canvases | Ask the user which iOS frame to use, or have the designer add an iPhone-sized frame. |
| Empty `taggedAssets` and empty `warnings` | No node in scope is tagged `eIC*`/`eImage*` | Designer needs to tag (see §9.4 in handoff) — fallback path runs anyway |
| `figma_export_assets_unified` row `status: "failed"` reason "Output không phải PNG" | Designer published node as SVG-only with no raster | Ask designer to flatten in Figma, or accept that node won't export. **Do NOT fall back to `mcp__figma__download_figma_images`** — that path is banned per `figma-to-swiftui/SKILL.md` §"BANNED substitute MCPs". |
| `figma_export_assets_unified` errors with `"Không tìm thấy outcome cho row"` (or any internal error not tied to an input row) | MCPFigma server bug — input rows were valid but the server failed to map a result back to a row | STOP, surface the error verbatim to the user, and ask them to file a MCPFigma issue. Do NOT fall back to a banned substitute. The skill cannot ship correct artifacts without the unified pipeline. |
| `figma_extract_tokens` returns HTTP 200 with empty `colors[]` / `typography[]` AND `warnings[]` non-empty | Figma file plan does not expose Variables API (Free / older Starter), or no shared text styles defined | Skill falls back to inline tokens from `design-context.md` per `references/design-token-mapping.md`. Write `tokens.json` with `_note: "reconstructed from inline styles — Variables API empty + warnings"`. **This is the ONLY case where inline-token fallback is allowed.** |
| Multiple `.xcassets` error | Project has > 1 catalog | Pass `assetCatalogPath` directly; B0 handles this |
| Claude doesn't see the tools after install | Claude wasn't restarted | Cmd+Q and reopen |
| `tools/list` shows `mcp__figma__get_figma_data` / `mcp__figma__download_figma_images` but not `figma_build_registry` | A different Figma MCP (Framelink / `figma-developer-mcp`) is registered instead of MCPFigma | **Do NOT use the substitute** — its output shape breaks every gate. Install MCPFigma per the steps above, then verify with `scripts/doctor.sh`. See `figma-to-swiftui/SKILL.md` §"BANNED substitute MCPs" for the full ban list. |
