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

After restart, `tools/list` advertises six tools. The skill uses four of them as the primary surface; the other two stay for backward compat / debugging:

| Tool | Purpose | Skill phase |
|---|---|---|
| `figma_build_registry` | One walk → `screens`, `taggedAssets`, `lottiePlaceholders`, `warnings` | A2 |
| `figma_export_assets_unified` | One call → tagged + fallback pipeline, returns full manifest | B3 |
| `figma_extract_tokens` | Local variables + shared text styles → SwiftUI tokens with naming + light/dark + typography | A3 |
| `figma_extract_fills` | Per-screen subtree → background image / gradient overlay / stacked fills with stops + handle positions + imageRef→URL resolution | A3 |
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
  "skipIfExistsInCatalog": true,
  "autoDiscover":        true
}
```

`outputDir` and `sharedAssetsDir` are absolute paths. `assetCatalogPath` is required when any tagged row is present.

#### `autoDiscover: true` (recommended)

When set, the server walks the subtree under `nodeId` via `AssetScanner` and auto-builds tagged rows (`exporter: "tagged"`, `strategy: "atomic"`) for every `eIC*` / `eImage*` it finds. Auto-built rows are **merged** with `rows[]` — caller-supplied rows win on duplicate `nodeId`. With `autoDiscover: true`, `rows` may be empty (`[]`) — the server discovers everything itself.

The response gains a `coverage` block proving completeness:

```json
{
  "rows": [ ... ],
  "warnings": [],
  "assetCatalogPath": "/abs/.../Assets.xcassets",
  "coverage": {
    "discoveredCount": 12,
    "exportedCount":   12,
    "autoAddedRows":   ["3166:70211", "3166:70300", "..."],
    "skippedNodeIds":  []
  }
}
```

Use this for Phase B unless you have a specific reason to lock the row set manually. It is the single mitigation for the "icons quietly missing from xcassets" failure mode that script `c6-asset-completeness.sh` detects.

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

1. Tagged rows → batch render @2x/@3x via `/v1/images` → write PNG to `outputDir/_mcpfigma/` → import into `assetCatalogPath` as `Assets.xcassets/<RootName>/<exportName>.imageset/`. SwiftUI's `Image(.<exportName>)` (iOS 17+ auto-generated `ImageResource`) resolves by name across the whole catalog regardless of folder.
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

`warnings` non-empty + all tokens empty + HTTP 200 → file does not have Variables API access (Figma plan limit). Skill falls back to reading inline tokens from `design-context.md`. **A second fallback case** — `forbidden` (HTTP 403) with `message` containing `"requires the file_variables:read scope"` — is the plan-gated Variables scope case (Free / Professional / Organization without Enterprise) and is also allowed to fall back, but **only with the disclosure protocol** in [`figma-to-swiftui/SKILL.md` §"MCPFigma edge cases"](../SKILL.md). Every OTHER `forbidden` (403) or `unauthorized` (401) is a token-scope / file-access problem and is **NOT** a fallback trigger — STOP and ask the user to fix the token (see Troubleshooting below).

### `figma_extract_fills`

**Input:**
```json
{ "fileKey": "ABC123", "nodeId": "3:24644", "depth": 10, "resolveImageUrls": true }
```

**Output:**
```json
{
  "fileKey": "ABC123",
  "rootNodeId": "3:24644",
  "nodes": [
    {
      "nodeId": "4:1", "nodeName": "HeroBanner", "nodeType": "FRAME",
      "width": 375, "height": 422,
      "fills": [
        { "type": "image", "imageRef": "5f8e...", "scaleMode": "FILL",
          "opacity": 1.0, "visible": true,
          "imageUrl": "https://s3-alpha-sig.figma.com/img/..." },
        { "type": "gradient", "kind": "linear",
          "stops": [
            { "position": 0.0, "hex": "#00000000" },
            { "position": 1.0, "hex": "#000000" }
          ],
          "startPoint": { "x": 0.5, "y": 0.0 },
          "endPoint":   { "x": 0.5, "y": 1.0 },
          "opacity": 0.65, "visible": true }
      ]
    }
  ],
  "warnings": []
}
```

Walks the subtree from `nodeId` (default depth 10) and returns **only nodes whose fills are non-trivial**:
- Any GRADIENT (linear / radial / angular / diamond)
- Any IMAGE (with `imageRef`)
- Multiple visible fills stacked on one node (e.g. `[IMAGE, GRADIENT]`)
- SOLID with paint-level opacity < 1.0, or non-NORMAL `blendMode`

Single 100%-opacity SOLID fills are **filtered out** — those are already covered by `tokens.json` + `design-context.md`. The skill consumes the output via [`fills-handling.md`](fills-handling.md): IMAGE fills compose with assets from `manifest.rows[]`, gradients emit as inline `LinearGradient(stops:[...])`, stacked fills become `ZStack { Image; LinearGradient }` in the bottom-to-top order Figma stores.

When `resolveImageUrls: true` (default), the tool also calls `/v1/files/<key>/images` once and populates `imageUrl` on every IMAGE fill. If that secondary call fails, the IMAGE fills still come back (with `imageUrl: null`) and a warning is appended; the skill can still resolve the asset locally via `manifest.rows[]`.

Variants `GRADIENT_ANGULAR` / `GRADIENT_DIAMOND` are emitted as `kind: "angular" | "diamond"` for completeness, but SwiftUI emit guidance (`AngularGradient`) is best-effort — verify against `screenshot.png` in C5 Pass 2. Truly unknown paint types (`EMOJI`, `VIDEO`, future Figma additions) emit `type: "unsupported"` with `rawType` preserved so the agent can surface them in the run summary.

**Failure modes:**
- `/v1/files/<key>/nodes` 401/403/404 → throw (same as other tools). STOP and fix token / nodeId.
- `/v1/files/<key>/images` failure → degraded run: fills returned without `imageUrl`, warning logged. Continue.
- Empty `nodes[]` with no warnings → screen has no interesting fills (plain solid backgrounds throughout). Continue normally; `Gate A` accepts an empty `nodes` array.

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
| `forbidden` (HTTP 403) on `figma_extract_tokens` with `message` containing `"requires the file_variables:read scope"` | PAT lacks `file_variables:read`. Two indistinguishable sub-cases: (a) **plan-gated** — the Figma plan does not expose this scope in the PAT settings UI (Free / Professional / Organization without Enterprise add-on); unfixable without plan upgrade. (b) **user-omitted** — plan exposes the scope but PAT was generated without ticking `Variables → Read` (off by default); fixable by re-issuing PAT. Agent cannot programmatically distinguish. | **Fallback allowed under disclosure protocol** (see [`figma-to-swiftui/SKILL.md` §"MCPFigma edge cases"](../SKILL.md)): write `tokens.json` with `_note: "reconstructed from inline styles — file_variables:read scope missing on PAT (Figma 403). Plan-gated for non-Enterprise; user-fixable if scope option is visible at https://figma.com/settings → Personal access tokens."` AND surface the verbatim Figma 403 `message` field plus a `Variables source: inline-fallback (...)` line in the Verification summary. User should verify in https://www.figma.com/settings → Personal access tokens whether `Variables → Read` is offered: if yes, regenerate PAT with it and re-run; if no, plan-limit confirmed and inline-fallback is the long-term answer (or upgrade plan). |
| `forbidden` (HTTP 403) on `figma_extract_tokens` with any other `message` | PAT missing `File content: Read` scope, OR file is in a workspace the token-owner does not belong to | Re-issue PAT with `File content: Read` enabled. Verify the file opens in a browser logged in as the token-owner. Restart Claude after updating mcp config. **Do NOT fall back to inline tokens for this case** — fallback is only allowed for the `requires the file_variables:read scope` case above and the empty-with-warnings case below. |
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
