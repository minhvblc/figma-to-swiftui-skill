---
name: figma-to-swiftui
description: "Translate Figma designs into production-ready SwiftUI code with 1:1 visual fidelity using the Figma MCP workflow. Trigger when the user provides Figma URLs or node IDs and wants iOS/SwiftUI implementation, asks to implement a design or component from Figma for an iOS app, or references Figma selections in the context of an Xcode/SwiftUI project. Also trigger when user asks to inspect Figma designs for iOS planning, fetch design tokens for SwiftUI, or convert Figma assets for Xcode. Requires a working Figma MCP server connection. Do NOT trigger for web/React implementations."
---

# Figma to SwiftUI Implementation Skill

Translate Figma nodes into production-ready SwiftUI views with pixel-perfect accuracy. Uses a two-phase workflow: **Phase A** fetches and caches all Figma data locally, **Phase B** implements SwiftUI from the cache without further MCP calls.

## Prerequisites

- Figma MCP server must be connected and accessible
- User must provide a Figma URL, e.g.: https://www.figma.com/design/:fileKey/:fileName?node-id=3166-70147&m=dev
  - May include &m=dev or other query params — only node-id matters
  - :fileKey — path segment after /design/
  - node-id value — the specific component or frame to implement
- OR when using figma-desktop MCP: select a node directly in the Figma desktop app (no URL required)
- Xcode project with an established SwiftUI codebase (preferred)

## MCP Connection

If any MCP call fails because Figma MCP is not connected, pause and ask the user to configure it.

---

## Phase A — Fetch & Cache (MCP-dependent)

Goal: gather all Figma data in one burst, save locally, minimize MCP exposure time. If any call fails, the manifest tracks progress so you can retry only what's missing.

**Three modes:** If the user wants to build a new screen from scratch, follow all steps sequentially. If the user wants to adapt/update an existing screen to match a Figma design, follow Steps 1–5, then do Step 5b (Adaptation Audit in Phase B). If the user provides a root node, page node, or a frame that may contain multiple screens, do Step 1b (Screen Discovery) before Step 2.

### Step 1 — Parse the Figma URL

Extract fileKey and nodeId from the URL.

Accepted URL patterns (with or without www.):
- figma.com/design/:fileKey/:fileName?node-id=...
- figma.com/file/:fileKey/:fileName?node-id=... (legacy, same behavior)

Parsing rules:
- fileKey: first path segment after /design/ or /file/
- nodeId: value of node-id query parameter. Always replace "-" with ":" (URLs use "3166-70147", MCP expects "3166:70147")
- Ignore all other query parameters (m=dev, t=..., page-id=..., etc.)
- Reject /proto/ and /board/ URLs — they are prototypes and FigJam boards, not implementable designs. Ask the user for a /design/ link instead.

When using figma-desktop MCP without a URL, tools automatically use the currently selected node. Only nodeId is needed; fileKey is inferred.

### Step 1b — Screen Discovery (for root or ambiguous nodes)

If the provided node might contain multiple screens, flows, or variants:
- Run `get_metadata` first to inspect the child tree
- Identify candidate screen frames and notable child nodes
- Build a short mapping table before fetching full design context
- Stop and ask the user if the mapping is ambiguous enough to change implementation scope

See references/screen-discovery.md for the required output format and confidence rules.

### Step 2 — Batch Fetch All MCP Data

Run all MCP calls and save results to `.figma-cache/<nodeId>/`. Create the cache directory first.

**Calls to make (in parallel where possible):**

1. `get_design_context(fileKey, nodeId, prompt="generate for iOS using SwiftUI")`
   → Save response to `.figma-cache/<nodeId>/design-context.md`

2. `get_screenshot(fileKey, nodeId)`
   → Save to `.figma-cache/<nodeId>/screenshot.png`

3. `get_variable_defs(fileKey, nodeId)`
   → Save to `.figma-cache/<nodeId>/tokens.json`

4. `get_code_connect_map(fileKey, nodeId)`
   → Save to `.figma-cache/<nodeId>/code-connect.json`

5. For complex/large designs only: `get_metadata(fileKey, nodeId)`
   → Save to `.figma-cache/<nodeId>/metadata.json`

For large/complex designs: If get_design_context is truncated, use get_metadata to find child IDs, then fetch each section individually into separate cache files (e.g., `design-context-section1.md`).

For multi-device designs: If Figma contains frames for different screen sizes (iPhone + iPad), fetch all device-specific frames. See references/responsive-layout.md.

### Step 3 — Download Assets

The `get_design_context` response includes download URLs (localhost) for image assets. These URLs are ephemeral — download immediately.

1. Identify assets in the cached design-context response
2. Download ALL icons and images from Figma MCP — do NOT substitute with SF Symbols
3. Prefer `download_figma_images` MCP tool when available (handles format correctly). Otherwise: `curl -o .figma-cache/<nodeId>/assets/<filename> "<localhost-url>"`
4. **Validate file format after every download:** run `file <downloaded>` to check actual content type. If SVG/XML was saved as .png, discard and re-export with `get_screenshot(fileKey, nodeId)` as PNG
5. For icons/nodes without download URLs, use `get_screenshot(fileKey, childNodeId)` to export as PNG
6. Record each asset in the manifest

Asset rules:
- **PNG only** — never use SVG files. Always export/download as PNG
- Do NOT substitute icons with SF Symbols — download the exact Figma asset
- Do NOT import new icon packages unless the project already uses them
- Do NOT create placeholder images — always download actual assets
- Before adding a new asset, search the project's existing Asset Catalog first
- Name assets with screen/node prefix + purpose, matching project case style
- All images and icons: @1x/@2x/@3x PNG variants in Asset Catalog

See references/asset-handling.md for full details.

### Step 4 — Write Manifest

Create `.figma-cache/<nodeId>/manifest.json` tracking all fetch results:

```json
{
  "fileKey": "abc123",
  "nodeId": "3166:70147",
  "fetchedAt": "2026-04-13T10:00:00Z",
  "status": {
    "design_context": "done",
    "screenshot": "done",
    "tokens": "done",
    "code_connect": "done",
    "metadata": "skipped",
    "assets": "done"
  },
  "assetList": [
    {"name": "heroImage.png", "status": "done"},
    {"name": "icon-star.svg", "status": "done"}
  ]
}
```

Update manifest status as each call completes. If a call fails, set status to "failed" and continue with the next call. Tell the user which calls failed.

---

## Phase B — Implement SwiftUI (offline from cache)

All data comes from `.figma-cache/<nodeId>/`. No MCP calls needed. This phase can run in a separate conversation, can be retried without re-fetching, and is not affected by MCP timeouts.

### Step 5 — Audit & Prepare

Read the cached data:
- `design-context.md` for layout, typography, colors, spacing
- `screenshot.png` as visual source of truth
- `tokens.json` for design token mapping
- `code-connect.json` for existing code mappings

### Step 5b — Adaptation Audit (when modifying an existing screen)

When the user asks to adapt/update an existing screen, perform a full element-by-element audit before writing any code. See **references/adaptation-workflow.md** for the complete process.

Key steps:
1. Read the existing code and all its subcomponents
2. Build a categorized diff checklist (ADD / UPDATE / REMOVE) with exact old → new values
3. Pay special attention to spacing — it's the most commonly missed difference
4. Present the checklist to the user and clarify unknowns before implementing
5. Apply all changes — do not skip items that seem minor

### Step 6 — Implement in SwiftUI

Before writing any code:

1. Check `code-connect.json` — if Figma components have mapped code components, use that code directly.
2. Inspect the project's dependencies (Package.swift, Podfile, .xcodeproj) and existing codebase for UI-related libraries and patterns. Examples:
   - Image loading: Kingfisher, SDWebImage, Nuke instead of AsyncImage
   - Animations: Lottie instead of SwiftUI animations
   - UI components: custom design system, SnapKit, etc.
3. Inspect the project for reusable UI building blocks: shared views, ViewModifiers, button styles, text styles, typography helpers (IKFont, IKCoreApp), named colors, image assets, and token wrappers.

Reuse order:
1. Code Connect mapped component
2. Existing shared design-system component or internal UI library wrapper
3. Nearby feature component with the same role
4. Existing modifier, style, token, or helper
5. New component only when no suitable project-native option exists

Critical rule: MCP output (React + Tailwind) is a representation of design intent. Do NOT port React to SwiftUI. Read design properties and build native SwiftUI views from scratch.

Do NOT implement system-provided elements that appear in Figma mockups: keyboard, status bar, home indicator, system nav bar back button, system tab bar, system alerts/action sheets, system search bar, pull-to-refresh indicator, page indicator dots. If unsure whether an element is system-provided or custom, ask.

#### Translation References

For detailed translation rules, see:
- **Layout** (Auto Layout, stacks, sizing, scroll, absolute positioning): references/layout-translation.md
- **Typography & Colors** (font mapping, color tokens, spacing tokens, shadows): references/design-token-mapping.md
- **Components** (variants, state/size/style, content toggles): references/component-variants.md
- **Responsive** (size classes, iPhone+iPad merging, adaptive layouts): references/responsive-layout.md

#### Effects and Decorations

Figma drop shadow -> .shadow(color:, radius:, x:, y:)
Figma inner shadow -> .overlay() with shadow or custom shape stroke
Figma blur (layer) -> .blur(radius:)
Figma blur (background) -> .background(.ultraThinMaterial) or .regularMaterial
Figma corner radius -> .clipShape(.rect(cornerRadius:))
Figma individual corners -> UnevenRoundedRectangle(topLeadingRadius:, ...)
Figma border/stroke -> .overlay(RoundedRectangle(...).stroke(...))
Figma clip content -> .clipped() or .clipShape()
Figma mask -> .mask { ... }
Figma blend mode -> .blendMode()
Figma Liquid Glass (iOS 26+) -> .glassEffect() with appropriate shape

#### Animations and Transitions

Figma prototype connections define transitions between frames — interpret as navigation or state-change animations, not literal animation specs.

Figma dissolve -> .opacity() + withAnimation(.easeInOut)
Figma move in / slide in -> .transition(.move(edge:)) or .offset()
Figma push -> NavigationStack push (system transition)
Figma smart animate -> withAnimation { } on state change
Figma scroll animate -> ScrollView with .scrollTransition()

Rules:
- Check project dependencies for Lottie or other animation libraries — use them if present
- Do not over-animate. Prototype links = navigation, not custom animation
- If complex choreographed animations, ask user whether to implement fully or simplify

### Step 7 — Copy Assets to Project

Move downloaded assets from `.figma-cache/<nodeId>/assets/` to the project's Asset Catalog:
- Add to Assets.xcassets with proper Contents.json
- See references/asset-handling.md for imageset structure and scale variants

### Step 8 — Validate (on user request only)

Do NOT auto-validate. Ask the user how they want to validate. If the user does not specify, skip validation entirely.

### Step 9 — Register Code Connect Mappings

After creating reusable SwiftUI components that correspond to Figma components:

`add_code_connect_map(fileKey, nodeId, componentPath, componentName)`

Only register components that are reusable and stable (not one-off screen-specific views).

---

## Resume & Retry

If the workflow is interrupted (MCP timeout, conversation ended, context limit):

1. Check `.figma-cache/<nodeId>/manifest.json`
2. If manifest exists and all statuses are "done" → skip Phase A, go directly to Phase B
3. If manifest exists with some "failed" items → retry only the failed MCP calls, update manifest
4. If no manifest → start Phase A from scratch
5. Cache is considered fresh for 24 hours. After that, suggest re-fetching.

User can say "tiếp tục fetch" or "continue" to resume Phase A, or "implement from cache" to skip to Phase B.

## Handling Complex Designs

1. get_metadata to get the node tree → save to cache
2. Identify major sections and child node IDs
3. Implement top-down: container first, then sections
4. Fetch each section into separate cache files
5. If user requested validation, validate per section, then full composition

## MCP Tools Reference

get_design_context: Design data + default code + asset download URLs. Primary source.
get_metadata: Sparse node tree. Use for large designs, structure first.
get_screenshot: Visual reference PNG. Validation truth.
get_variable_defs: Design tokens. Use when project has design system tokens.
get_code_connect_map: Existing code mappings. Check before creating components.
add_code_connect_map: Register new mappings. After creating reusable components.

## Key Principles

1. Never implement from assumptions. Always fetch context + screenshot first.
2. MCP output is a spec, not code. Read properties, build native SwiftUI.
3. Use what the project uses. Check dependencies and existing patterns first.
4. Project tokens win. Prefer project tokens, adjust minimally for visual match.
5. Validate only when asked. Ask the user how they want to validate.
6. Always download from Figma. Never substitute with SF Symbols — use exact assets from the design. PNG only, validate format after download.
7. Platform conventions matter. iOS navigation, safe areas, Dynamic Type, accessibility > pixel-perfect Figma replication.
8. Cache first. All MCP data cached locally — implement offline, retry without re-fetching.
