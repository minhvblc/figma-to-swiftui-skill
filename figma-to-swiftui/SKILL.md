---
name: figma-to-swiftui
description: "Build pixel-perfect SwiftUI views from Figma via Figma MCP. Triggers on figma.com URLs, Figma node IDs, a current Figma selection in figma-desktop MCP, and phrases like 'implement/translate/convert Figma to SwiftUI', 'iOS UI from Figma', 'làm UI SwiftUI từ Figma', 'code màn iOS theo Figma', 'làm màn này', 'adapt SwiftUI view to Figma', or a .txt/.md brief paired with Figma work for iOS. Requires BOTH the figma-desktop MCP (get_metadata / get_design_context / get_screenshot) AND the MCPFigma server (figma_build_registry / figma_extract_tokens / figma_export_assets_unified) — STOP if either is missing, never improvise. Do NOT trigger for React, web, or Android."
---

# Figma to SwiftUI

Turn Figma nodes into production SwiftUI with pixel-matching fidelity. **Three phases, executed in strict order. Each phase has a mandatory exit gate.** You may not start the next phase until the previous gate prints `GATE: PASS`.

- **Phase A — Discover & Spec.** Fetch the design specification (context, screenshot, tokens, metadata). Cache only.
- **Phase B — Asset Pipeline.** Inventory every visible asset, classify, download as PNG, validate.
- **Phase C — Implement.** Write SwiftUI offline from the cache, self-check, copy assets to the project.

**Fidelity playbook (read first, every Phase C):** [`references/visual-fidelity.md`](references/visual-fidelity.md).

---

## Quick Reference

> Script paths shown as `scripts/X.sh` resolve to `~/.claude/scripts/X.sh`; reference docs at `~/.claude/skills/figma-to-swiftui/references/`. Run `bash ~/.claude/scripts/doctor.sh` if anything seems missing.

**Decision flow at task start:**

```
1. Mode detect → scripts/mode-detect.sh <project>
     greenfield-vanilla   → scripts/vanilla-scaffold.sh <ProjectName>
     greenfield-ikame     → scripts/ikxcodegen-scaffold.sh <ProjectName>  (ASK USER first)
     brownfield-ikame     → load Ikame conventions, no scaffold
     brownfield-vanilla   → load vanilla conventions, no scaffold
     ambiguous            → STOP, ask user
2. Pin Figma file → figma_build_registry
3. For each screen → Phase A → Phase B → Phase C (C1 audit → C2 implement → C3 self-check → C4 copy assets → C5 build/diff → C6 asset completeness → C7 no system chrome)
```

**References, by trigger:**

| When you... | Read |
|---|---|
| Reach C5 verification | [`verification-loop.md`](references/verification-loop.md) |
| Hit a banned pattern | [`anti-patterns.md`](references/anti-patterns.md) |
| Need layout / fills / tokens / fonts | [`layout-translation.md`](references/layout-translation.md), [`fills-handling.md`](references/fills-handling.md), [`design-token-mapping.md`](references/design-token-mapping.md), [`fonts-styling-bridge.md`](references/fonts-styling-bridge.md) |
| Ikame project (IKCoreApp present) | [ikame-ios-coding skill](../ikame-ios-coding/SKILL.md) is canonical; bridges in `references/ik*-bridge.md` hold only the figma-specific delta |
| Hook blocked your Write | The 1-line stderr; expand with `HOOK_VERBOSE=1` |

**P0 STOP gates:**
- Empty registry (no `screens`, no `candidateScreens`) → STOP, re-root before any Swift Write.
- `figma_extract_tokens` returned `forbidden` (non-`file_variables:read` 403) → STOP per `mcpfigma-setup.md` §Troubleshooting.
- ikxcodegen / vanilla-scaffold output already exists → refuse to overwrite, ask user.

**The two most common failure modes** (gate `figma-to-swiftui-banned-pattern-gate.sh` catches both):
1. **SwiftUI shapes for icons.** Hook blocks `Image(systemName:)` outside the system-chrome allow-list. Bypass with `// allow-systemName: <reason>` only for genuine iOS HIG glyphs.
2. **Template-from-doc on multi-screen flows.** Each screen needs its own Phase A artifact (per-screen `get_design_context`). The flow skill must reject templates built from doc wording.

## Common issues + fixes (quick reference)

| Issue | Symptom | Fix |
|---|---|---|
| **`get_design_context` truncation** | Response cut mid-section; `design-context.md` ends in `…` or short | Don't retry. Call `get_metadata` to enumerate children, then fetch each child node individually with `get_design_context(nodeId=<child>)`. Full protocol: [`references/fetch-strategy.md`](references/fetch-strategy.md) §"Circuit breaker". |
| **Variables API empty / 403** | `figma_extract_tokens` returns 200-empty + warnings, OR 403 `file_variables:read` scope | Run `scripts/c2-extract-design-context.sh` then `scripts/c2-tokens-synthesize.sh` — synthesizes `tokens.json.colors[]` from inline hex literals in `design-context.md`. Disclose verbatim 403 in Verification summary under `Variables source: inline-fallback (...)`. |
| **Asset missing from `manifest.json`** | Visible icon in screenshot but no row in `manifest.rows[]`, or row has `status: "failed"` | Re-run `figma_export_assets_unified(autoDiscover: true)` — scans subtree, picks up missed nodes. C6 + L2 both filter `status == "done"` only. |
| **L2 trace FAIL on legitimate code** | Code uses `Color.figmaGray400` matching Figma value but L2 says "not in tokens.json" | Run `c2-cache-validate.sh` first — likely `tokens.json` is degraded (empty + no `_note`). Fix by re-running Phase A or synth. |
| **iOS system chrome redraw blocked** | Hook rejects `Text("9:41")` / `Capsule().frame(height: 5)` / `cornerRadius >= 30pt` | Delete the redraw. iOS renders status bar / home indicator / device bezel. Add `// allow-screen-corner-radius: <reason>` only when intentional non-bezel curve. |

Deep dive: [`references/anti-patterns.md`](references/anti-patterns.md) catalogues real-run failure modes.

---

## Convention source of truth — Ikame projects

When `c1-conventions.json.usesIKCoreApp == true`, **`ikame-ios-coding` skill is the canonical source for every base Swift/SwiftUI convention.** This skill only adds Figma-specific patterns and code-generation flow on top.

| Topic | Canonical reference | What this skill adds |
|---|---|---|
| Folder layout, file naming | `ikame-ios-coding/references/project-structure.md` | mode detection, per-screen folder pinning from Figma frame name |
| ViewModel: `@MainActor` + `ObservableObject` + flat `@Published` + `enum Action` + `func send(_:)` + `enum Route` + `@Published var route: Route?` | `ikame-ios-coding/references/viewmodel.md` | Action-naming derived from Figma interactive nodes |
| SwiftUI view: body ≤ 50 lines, modifier order | `ikame-ios-coding/references/swiftui-view.md` | body-section splitting per Figma layout regions |
| IKNavigation: per-feature router, `IKRouteID` extension, `EmptyView()` else, compose with `+` | `ikame-ios-coding/references/iknavigation.md` | extending existing router with new cases from Figma flow |
| `@APIProtocol` + `enum API` registry + `=>` + `@JsonSerializable` | `ikame-ios-coding/references/api-ikmacros.md` | DTO ↔ Entity mapping for Figma-driven data shapes |
| IKToast / IKLoading / IKPopup | `ikame-ios-coding/references/ui-popup-toast-loading.md` | app-level `IKPopupConfiguration` extension cases |
| ikFont presets / escape hatch / `Color(hex:)` | `ikame-ios-coding/references/fonts-and-styling.md` | Figma typography token → preset or escape-hatch decision; Asset Catalog colorset codegen |

**Conflicts resolve in favor of `ikame-ios-coding`.** Bridges below hold only the **delta** (figma-specific code-gen patterns, app-level extensions) `ikame-ios-coding` does not cover.

For non-Ikame projects (`usesIKCoreApp == false`), use the vanilla conventions in [`viewmodel-pattern.md`](references/viewmodel-pattern.md), [`project-structure.md`](references/project-structure.md).

---

## ABSOLUTE RULE — Assets come from Figma

Every visible icon, logo, illustration, image, and decorative graphic in the screenshot **MUST** be downloaded from Figma in Phase B.

**Banned substitutions:**
- `Image(systemName: ...)` for any element that exists as a Figma node
- Colored rectangles / circles / `Text("G")` standing in for real logos
- `Shape` primitives drawn to mimic an icon
- "Simplified" versions of Figma illustrations
- Any phrase like "no Figma PNG/SVG pipeline was set up"

**Allow-listed exceptions** for `Image(systemName:)`:
- iOS system chrome the user explicitly said to keep system-default (back chevron, share sheet)
- The user explicitly tells you to substitute for a missing asset

**Failure-mode self-check.** If you catch yourself thinking *"SF Symbol is close enough"*, *"the user won't notice"*, *"I'll skip the pipeline this time"*, *"build the rest with SwiftUI shapes for maintainability"*, *"these icons are simple — `Image(systemName:)` is fine"*, or *"build → screenshot → it looks great" without C5.6* — **STOP**. Go run Phase B via `figma_export_assets_unified(autoDiscover: true)`. **Disclosing the bypass in the final summary does not redeem it** — a run that ships with "non-negotiables flexed" is a failed run.

If an asset truly cannot be fetched (node missing, MCP error after retry), **STOP and tell the user**. Real failure modes catalogued in [`anti-patterns.md`](references/anti-patterns.md) — read once before Phase B, once before writing the Verification summary.

---

## ABSOLUTE RULE — Do NOT draw iOS system chrome

Figma frames often include iOS system chrome and the iPhone bezel. **These are rendered by iOS or the physical hardware.** Drawing them in SwiftUI is always a bug.

**Never draw, even if shown in screenshot:**
- Status bar (time "9:41", Dynamic Island, signal/wifi/battery)
- Home indicator (~134×5pt bar)
- System keyboard, pull-to-refresh, system nav back chevron
- Native `TabView` bar, system alerts, page dots
- **iPhone bezel / device frame** — the rounded outline (~47–55pt radius). Hardware corners produce this curve on a real device; **never** add `.cornerRadius(R)` / `.clipShape(RoundedRectangle)` to the screen-root view.

**Strip them from Visual Inventory before coding.** Use `.ignoresSafeArea(edges: .top)` if content extends behind status bar; `.safeAreaInset(edge: .bottom)` for content padding above home indicator. A custom tab bar that IS part of the app → fine, place it via `.safeAreaInset(edge: .bottom)`.

If Visual Inventory has a row like "home indicator bar", "status bar with time 9:41", "Dynamic Island pill", **or "screen container has corner radius ~47pt"** — **delete it** before coding.

---

## Prerequisites

**Two Figma MCP servers are required — both, not one.**

| MCP server | Tools used | Purpose |
|---|---|---|
| `figma-desktop` (official) | `get_metadata`, `get_design_context`, `get_screenshot`, `get_variable_defs` | Design spec, FRAME screenshot, raw variable defs |
| `figma-assets` (MCPFigma) | `figma_build_registry`, `figma_extract_tokens`, `figma_export_assets_unified`, `figma_extract_fills` | Screen graph, SwiftUI-ready tokens, per-node PNG export, fills handling |

### BANNED substitute MCPs

Third-party Figma MCPs produce **incompatible artifacts**. Detect-and-STOP:

| Tool name (substring) | Origin | Why banned |
|---|---|---|
| `mcp__figma__get_figma_data` | Framelink | Returns raw REST JSON, not the JSX/Tailwind output Pass 2 / C5 require |
| `mcp__figma__download_figma_images` | Framelink | Skips tagged-asset naming, imageset emission, lottie routing |
| Any `mcp__figma_*` not from `figma-desktop` or `figma-assets` | various | Downstream gates assume artifacts from the required servers |

If a banned tool is present AND required tools are missing → **STOP**. Tell user: *"Banned substitute MCP detected (`<tool name>`). Install `figma-desktop` and `figma-assets` per `references/mcpfigma-setup.md`."* Do not call it even once "to see what's there".

### Connection check (probe first, do not ask upfront)

1. Call `mcp__figma-desktop__get_metadata` on target node. Failure → figma-desktop missing → STOP.
2. Call `figma_build_registry(fileKey, nodeId, depth=10)`. Failure → MCPFigma missing → STOP.
3. **Sanity-check response shape:** `get_design_context` returns the JSX/Tailwind block headed by `## Design context for "<node-name>"`; `figma_build_registry` returns `rootNode`, `screens`, `taggedAssets`, `lottiePlaceholders`, `warnings`. Plain JSON tree = banned substitute, STOP.

**If only one of the two is connected → STOP.** Do not improvise a fallback. Specifically: no Pass 2/C5 visual diff without `screenshot.png`; no Phase B asset pipeline without `figma_export_assets_unified`. Never fall back to `Image(systemName:)` or hand-drawn shapes.

Other inputs:
- Figma URL `figma.com/design/:fileKey/:fileName?node-id=...`, or current selection in figma-desktop MCP
- SwiftUI Xcode project (preferred)
- Optional: `.txt`/`.md` brief — read **before** any Figma call

## Route

| Input | Use |
|---|---|
| 1 node, no doc (or doc = 1 screen) | this skill |
| Multiple nodes / root page / journey | `figma-flow-to-swiftui-feature` (delegates back per screen) |
| Ambiguous | Phase 0 + A2 first, then decide |

## Skill boundaries — when to switch / delegate

This skill owns Figma → SwiftUI **view code** for 1 screen. Adjacent concerns delegate to sibling skills (don't try to do them here):

| If the user wants... | Switch to |
|---|---|
| Multi-screen feature / flow / end-to-end journey | [`figma-flow-to-swiftui-feature`](../figma-flow-to-swiftui-feature/SKILL.md) |
| iOS project that uses `IKCoreApp` / `IKNavigation` / `IKMacros` (full convention canonical) | [`ikame-ios-coding`](../ikame-ios-coding/SKILL.md) — this skill calls into Ikame conventions when `c1-conventions.json.usesIKCoreApp == true` |
| VoiceOver labels, Dynamic Type, accessibilityFocusState, audit a11y after build | `ios-accessibility` skill — run as post-C7 step on screens with controls |
| `NavigationStack` / `NavigationSplitView` / deep linking design | `swiftui-navigation` skill |
| Animations, transitions, `matchedGeometryEffect`, springs, keyframes | `swiftui-animation` skill |
| Liquid Glass effects (iOS 26+), `glassEffect`, `GlassEffectContainer` | `swiftui-liquid-glass` skill |
| Drag/tap/magnify/rotate gestures, `@GestureState`, gesture composition | `swiftui-gestures` skill |
| Paywall, in-app purchase UI, `SubscriptionStoreView`, `ProductView` | `storekit` skill |
| String Catalog (`.xcstrings`), Dynamic Type Pluralization, locale formatting | `ios-localization` skill |
| Chart / data viz from Figma (line / bar / pie) | `swift-charts` skill |
| Write back to Figma canvas / create / edit Figma nodes | (out of scope — none of our skills do this; use Figma's official tools) |

**Rule of thumb.** Figma node → SwiftUI struct lives here. Anything happening AFTER the struct compiles (interactive states, animations between screens, a11y audit, in-app purchase wiring) delegates.

---

# Phase 0 — Pre-flight (MANDATORY)

Run-once-per-project. Skip Phase 0 and the mode-gate hook blocks your first Write.

### Step 0.1 — Mode detection

```bash
bash ~/.claude/scripts/mode-detect.sh <projectFolder> --write-cache
```

Writes `<projectFolder>/.figma-cache/_shared/mode.json`. Outcomes:

| mode | Required follow-up |
|---|---|
| `greenfield-ikame` | **ASK USER**: *"Detected Ikame fleet (ikxcodegen on PATH). Scaffold via ikxcodegen? [Y/n]"*. On Y → `bash ~/.claude/scripts/ikxcodegen-scaffold.sh <ProjectName>`. On n → fall through to vanilla. |
| `greenfield-vanilla` | `bash ~/.claude/scripts/vanilla-scaffold.sh <ProjectName>` |
| `brownfield-ikame` | Load Ikame conventions per [ikame-ios-coding skill](../ikame-ios-coding/SKILL.md). |
| `brownfield-vanilla` | Load vanilla conventions. |
| `ambiguous` | **STOP**, ask user. On confirm: `jq '. + {userConfirmed: true}' mode.json > tmp && mv tmp mode.json`. |

Greenfield-ikame banned: generating raw `.xcodeproj` / `Project.yml` (mode-gate hook blocks Swift writes until the scaffold runs).

### Step 0.2 — Open Xcode early (for C5 Engine A)

The deterministic engine selection runs at C5 start via `c5-engine-select.sh`. Engine A (xcode MCP `BuildProject` + `RenderPreview`) needs Xcode running with the project open. Open it now so you're not blocked later:

```bash
open -a Xcode <projectFolder>/<ProjectName>.xcworkspace  # or .xcodeproj
```

### Step 0.3 — Verify the MCP stack

Run the connection check above on `figma-desktop` AND `figma-assets`. If either is missing → STOP.

### Phase 0 exit gate

When done you have: `mode.json`, a scaffolded/existing `*.xcodeproj`, both MCPs verified. Only then proceed to Phase A.

---

# Phase A — Discover & Spec

Goal: a complete design specification in the cache. **No asset downloads.**

### Step A0 — Source Document
If a doc is attached, read it first. Extract: goal, screens, actions, states, constraints, out-of-scope.

### Step A1 — Parse URL
- `fileKey`: first path segment after `/design/` or `/file/`
- `nodeId`: `node-id` query param; replace `-` with `:` (URLs use `3166-70147`, MCP expects `3166:70147`)
- Reject `/proto/` and `/board/` — ask for a `/design/` link
- figma-desktop: uses current selection automatically

### Step A2 — Screen Discovery

Call `figma_build_registry(fileKey, nodeId, depth=10)` once. Response gives `screens[]`, `taggedAssets[]`, `lottiePlaceholders[]`. Persist to `.figma-cache/<nodeId>/registry.json`.

- 0 screens AND root is not a FRAME → ask user to point at a frame, not a page.
- 1 screen → continue with this skill.
- N > 1 screens → hand off to `figma-flow-to-swiftui-feature` (reuses same registry).
- 0 screens + non-empty `candidateScreens[]` or `rootNode.type == SECTION` → re-root per [`mcpfigma-setup.md`](references/mcpfigma-setup.md) §Troubleshooting.

### Step A2b — Screen-vs-State Disambiguation

Two screens with **same UI structure** in Figma are almost always two **states of one screen**, not separate screens. Common misleading pairs:
- "Enter PIN" + "Confirm PIN" with identical 3×4 number pad → ONE screen, two states
- "Enable Face ID" + "Scan Face ID" with same illustration → ONE screen with overlay state
- Step-1 / Step-2 / Step-3 onboarding with identical layout → ONE screen with `currentStep` enum

Detection: same frame size + ≥ 80% node-tree shape match + body copy Levenshtein > 0.8. For each hit: **stop, show both screenshots, ask the user**: *"Đây là 2 state của cùng 1 màn hay 2 màn riêng?"* Do NOT decide on your own.

### Step A3 — Batch Fetch Spec

Issue calls 1+2+4+5 in **one parallel message**. Call 3 is per-`fileKey` — issue once, reuse via symlink. Save to `.figma-cache/<nodeId>/`:

1. `get_design_context(fileKey, nodeId, prompt="generate for iOS using SwiftUI")` → `design-context.md`
2. `get_screenshot(fileKey, nodeId)` at **scale 3** → `screenshot.png`. Then `sips -Z 2000 screenshot.png --out screenshot-cmp.png` (≤2000px long-side, required for C5 many-image API).
3. `figma_extract_tokens(fileKey)` → `tokens.json` (carries `swiftName`, `lightHex`/`darkHex`, `isCapsule`, `typography[]`)
4. `get_metadata(fileKey, nodeId)` → `metadata.json`
5. `figma_extract_fills(fileKey, nodeId, depth: 10, resolveImageUrls: true)` → `fills.json` (per-node fill stack for gradients, images, stacked fills)

**Hard rule on missing tools:** if any step errors because the MCP is not connected → STOP and ask the user. **Do NOT** proceed by "reading metadata + guessing styles".

On truncation: don't retry — fall back to metadata + per-section fetch. See [`fetch-strategy.md`](references/fetch-strategy.md).

### Step A3+ — Phase B early-start (RECOMMENDED on first run)

`figma_export_assets_unified(autoDiscover: true)` only needs `nodeId` + `assetCatalogPath`. Add it to the A3 parallel batch to save ~10-15s on single-screen runs (30-60s on multi-screen flows). Cross-validate after the batch: for every visual row, check `nodeId` ∈ `manifest.rows[]`; supplementary single-row call for any missing.

### Gate A — Phase A Exit

```bash
# 1. Normalize design-context.md + build bbox index (Phase 2 layers)
bash ~/.claude/scripts/c2-extract-design-context.sh --cache .figma-cache/<nodeId>
bash ~/.claude/scripts/c2-build-bbox-index.sh        --cache .figma-cache/<nodeId>

# 1b. Per-text-segment typography index — bridges L2 trace for
#     .lineSpacing / .tracking / .kerning / .fontWeight rows so they
#     PASS/FAIL against design-context Tailwind (leading-*, tracking-*,
#     font-*) instead of degrading to N/A.
bash ~/.claude/scripts/c2-typography-extract.sh --cache .figma-cache/<nodeId>

# 1c. Per-node gradient-stop index — flattens fills.json so L2 trace
#     can do stop-by-stop comparison via `// Figma: <nodeId>` hint on
#     `.background(LinearGradient(...))`. No-op when fills.json has no
#     gradients.
bash ~/.claude/scripts/c2-fills-stops-index.sh --cache .figma-cache/<nodeId>

# 2. (Conditional) When tokens.json came back empty with _note (Variables 403):
#    synthesize fallback tokens from c2-extracted.json hex literals
bash ~/.claude/scripts/c2-tokens-synthesize.sh --cache .figma-cache/<nodeId>

# 3. Schema gate — verify every Phase A artifact is present + parseable + non-degraded.
#    Also validates c2-typography-perline.json (required if design-context
#    has text) and c2-fills-stops.json (required if fills.json has gradients).
bash ~/.claude/scripts/c2-cache-validate.sh --cache .figma-cache/<nodeId>
# Exit 0 → PASS, 1 → FAIL (corrupt/missing), 2 → PARTIAL (acceptable gap with explanation)
# `c3-driver.sh trace` will refuse to run if validate FAILs.
```

(Or run the full bash check inline — see `references/verification-loop.md` §"Gate A".)

---

# Phase B — Asset Pipeline

**The phase agents skip. Don't.** Every visible icon/logo/illustration/image from the screenshot exists as a validated PNG on disk.

Runs through **`figma_export_assets_unified`** — one call handles tagged + fallback + lottie paths:
- **Tagged path** — `eIC*` / `eImage*` nodes; renders @2x/@3x, writes `.imageset` directly into `Assets.xcassets`.
- **Fallback path** — FLATTEN regions, untagged atomic nodes; renders at scale 3, dedupes into `_shared/assets/`.
- **Lottie path** — `eAnim*` nodes; manifest row only, no PNG.

### Step B0a — Copy extraction

```bash
bash ~/.claude/scripts/b0a-extract-copy.sh \
  --design-context .figma-cache/<nodeId>/design-context.md \
  --output <project>/DesignSystem/Strings.swift \
  --screen-name <Welcome>
```

Emits a `Strings.swift` enum from every visible text in `design-context.md`. When the project uses xcstrings (`c1-conventions.json.xcstringsPath != null`), edit the catalog directly instead.

**Hard rule:** every `Text(...)` literal in a generated view file MUST be either (a) a String Catalog key, (b) a `Strings.<Screen>.<key>` reference, or (c) dynamic data. Inline English literals are banned by C3 Pass 1.

### Step B0b — Token codegen

```bash
bash ~/.claude/scripts/b0b-tokens-codegen.sh \
  --tokens .figma-cache/_shared/tokens.json \
  --xcassets <Assets.xcassets> \
  --out <project>/DesignSystem/
```

Emits dual-mode colorsets (via `colorset-codegen.sh`), `Color+Tokens.swift` (light-only), `AppFont.swift` (typography — skipped for Ikame projects per `fonts-styling-bridge.md` §3), `Spacing.swift` (only cases actually in tokens — no synthetic 8pt grid).

**Hard rule:** every `Color(...)`, `.font(...)`, padding/spacing literal in a view file MUST come from these enums OR carry an explicit `// Figma: <node-id>` comment. Made-up tokens (`surfaceCard`, `textTertiary`, etc.) are banned.

### Step B0 — Read registry, pin asset catalog

`registry.json` (from A2) already contains `taggedAssets[]`, `lottiePlaceholders[]`, naming `warnings[]`. No second probe.

1. Surface designer warnings (`eIChome` lowercase → falls back) once at end of Phase B.
2. Pin `assetCatalogPath`: 0 `.xcassets` → ask user to create; 1 → silent default; N>1 → prompt, stash in `manifest.assetCatalogPath`.

### Step B1 — Inventory (visual-first)

Open `screenshot.png` and list every visible non-text element. Cross-reference: visual scan (ground truth) + `design-context.md` `<img>`/`<svg>`/`imageRef` + `metadata.json` VECTOR/BOOLEAN_OPERATION/INSTANCE nodes named `icon`/`ic_`/`logo`/`illustration`.

Build inventory table:

| # | Purpose | NodeId | Exporter | Strategy | exportName / friendlyName / lottieName |
|---|---|---|---|---|---|
| 1 | Close icon | 3166:70211 | tagged | atomic | icAIClose |
| 2 | Hero illustration | 3166:70200 | fallback | flatten | heroArtwork |
| 5 | Loading animation | 3166:71000 | fallback | lottiePlaceholder | placeholder_animation |

**Cross-reference rule:** for every visual row matching `registry.taggedAssets[]` → set `exporter = "tagged"`. For every match in `registry.lottiePlaceholders[]` → `strategy = "lottiePlaceholder"` (no PNG). Walk the other direction too: tagged/lottie in registry NOT in inventory → **STOP, ask the user** (designer drift or you missed it).

**Hard rules:**
- Every visible non-text element → one row.
- Visible icon with no nodeId → **STOP, ask user**.
- Empty inventory on a screen with visible icons → bug, re-scan.

### Step B2 — Classify

- **FLATTEN** (one fallback row, nodeId = region root): composed artwork, layered scene, static content.
- **DECOMPOSE** (atomic rows): icon rows, grids, interactive/dynamic.
- **CODE** (SwiftUI shapes, no row): trivial primitives — rect, circle, gradient, blur. **Not for icons.**
- **MIXED**: flatten sub-frame as fallback, overlay interactive UI in ZStack at code time.
- **LOTTIE-PLACEHOLDER**: registry pre-classified; row uses `strategy: "lottiePlaceholder"`.

Heuristic: "the hero illustration" (1 thing) → flatten; "row of action icons" (N things) → decompose. **Doubt → flatten.** Never reassemble composed artwork with `.offset()`. Rules: [`asset-handling.md`](references/asset-handling.md) §1a.

### Step B3 — Unified export

If A3+ pipeline ran, B3 already executed. Otherwise:

```
figma_export_assets_unified(
  fileKey, nodeId,
  outputDir        = ".figma-cache/<nodeId>/assets",
  sharedAssetsDir  = ".figma-cache/_shared/assets",
  assetCatalogPath = <pinned in B0>,
  rows = [
    { nodeId: "3166:70211", exporter: "tagged",   exportName: "icAIClose" },
    { nodeId: "3166:70200", exporter: "fallback", friendlyName: "heroArtwork", strategy: "flatten" },
    { nodeId: "3166:71000", exporter: "fallback", friendlyName: "placeholder_animation", strategy: "lottiePlaceholder" }
  ]
)
```

Tool handles: tagged batch render → imageset write; fallback batch render → PNG validation → dedup; tagged row that errors → auto-promoted to fallback; lottie rows pass-through; `skipIfExistsInCatalog` defaults to true.

**Persist response** as `.figma-cache/<nodeId>/manifest.json`. Single source of truth. On `status: "failed"` row → tell user the `reason`, do not silently drop.

**Resume on partial failure:** read `manifest.rows[].status`; resubmit only `status != "done"` entries. Idempotency contract: keep original `exporter`/`strategy`/`exportName`.

### Gate B — Phase B Exit (STRICT)

Inline bash check verifies: manifest exists, no failed rows, registry tagged + lottie coverage, files on disk for every non-Lottie row, imageset paths, real PNG signatures. Full block in [`verification-loop.md`](references/verification-loop.md) §"Gate B". If `GATE: FAIL`: fix cause, do NOT write Swift.

---

# Phase C — Implement (offline from cache)

Goal: SwiftUI code that matches the screenshot pixel-for-pixel using only Phase B assets.

### Step C1 — Audit & Prepare

**Coding-conventions probe (mandatory).** One call writes the full audit JSON:

```bash
bash ~/.claude/scripts/c1-probe.sh --project <project-root> \
  --output .figma-cache/<nodeId>/c1-conventions.json
```

Detects: deployment target, generated symbol flags, folder layout (`one-screen-per-folder` canonical / `ikame-feature-flat` brownfield / `flat`), ViewModel pattern, observation flavor, IKNavigation/IKMacros/IKPopup/IKFeedback/IKFont (per bridge §1 detection), xcstrings + xcassets paths.

Both this skill and `figma-flow-to-swiftui-feature` read this single source of truth.

**Project pre-flight checks** (see `references/visual-fidelity.md` §6):
1. iOS deployment target (baseline iOS 16+)
2. `Color(hex:)` extension presence
3. Localization mode (`xcstrings` is canonical baseline)
4. Dark mode scope — ask user if Figma is light-only
5. Lottie SDK presence → flag `hasLottieSDK`

**Visual Inventory (mandatory).** Follow [`visual-fidelity.md`](references/visual-fidelity.md) §1–3. Every visible element → row with source tag `[tokens|inline|class|screenshot]`. Never skip `lineHeight`, `letterSpacing`, `shadow`, `border`, `renderingMode`, `textAlign`, stack alignment (both axes).

### Step C1b — Adaptation Audit (if modifying existing screen)

Element-by-element ADD/UPDATE/REMOVE diff. Read existing file, compare against Figma inventory, present table to user, await approval before coding. Scope changes to confirmed rows only; never refactor unrelated code in the same pass.

### Step C2 — Implement

**Reuse order:** Code Connect mapped component → shared design-system component → nearby feature component → existing modifier/token → new (only if nothing fits).

**Build order (outside-in):**
1. Outermost container, safe-area, background
2. Primary stack — explicit `spacing:` and alignment
3. Sections top-to-bottom, following inventory order
4. Text & icons — font, lineSpacing, tracking, color, renderingMode
5. Backgrounds, borders, shadows, corner radius (watch `.background` vs `.padding` order)
6. Effects (blur, mask, blend) — last
7. Interactions — `.buttonStyle(.plain)` for custom, navigation

**Incremental L2 trace (recommended).** L1 audit auto-emits `c2-audit.json` on every Write/Edit. After each major section (e.g. header done, hero illustration done, CTA done — not necessarily after every modifier), run:

```bash
bash ~/.claude/scripts/c3-driver.sh trace --cache .figma-cache/<nodeId>
```

L2 is deterministic + 0-token (script only) so the cost is ~1s per run. Catching `Color.madeUpToken` or `.frame(width: 99)` (no Figma node) mid-implementation is much cheaper than dumping at the end and self-fix-looping through 10 cascading FAILs. Pattern: write 1 section → run trace → fix any FAIL → next section.

**Critical rules:**

- **Xcode MCP file family** (when available): `mcp__xcode__XcodeWrite` for new files, `XcodeUpdate` for edits, `XcodeRefreshCodeIssuesInFile` after every write for sub-second compile feedback. Fallback to vanilla `Write/Edit` when `c5-engine-select.sh` reports `xcodebuild` engine OR project uses Xcode 16+ synchronized folders.
- **Tokens.** Use `tokens.json` directly — `swiftName`, `lightHex`, `darkHex`, `isCapsule`. Merge with project enums; prefer existing enum case → token → inline literal.
- **`isCapsule` → `Capsule()`** (hard rule). Never `.cornerRadius(9999)` — flattens ends on non-square pills.
- **Dual-mode colors → Asset Catalog.** `Color(.<swiftName>)` form, iOS 17+ auto-generated `ColorResource`. Never `Color("<name>")` string form.
- **`Text` → `LocalizedStringKey`**; `Text(verbatim:)` for dynamic data.
- **Use Figma assets only.** `Image(systemName:)` BANNED for Figma-designed icons. `Text("G")` / `Rectangle()` as logos BANNED.
- **Lottie placeholders.** `strategy: "lottiePlaceholder"` → `LottieView` stub (Airbnb lottie-ios). Name is literal `"placeholder_animation"`. Add `import Lottie` once per file.
- **Project token routing** (read `c1-conventions.json`):
  - Spacing → `<spacingEnum>.<token>` first; inline literal when no token matches.
  - Typography (Ikame, `fontModifier == "ikFont"`) → `.ik<Preset>()` when matches; `.ikFont(<size>, weight:)` escape hatch when off-token; `.<family>(<size>, weight:)` for additional families. See [`fonts-styling-bridge.md`](references/fonts-styling-bridge.md).
  - Typography (non-Ikame) → `AppFont.<token>()` from B0b.
  - Never invent new enum cases.
- **Coding conventions** (governed by `c1-conventions.json`): folder layout → [`project-structure.md`](references/project-structure.md) + canonical [`ikame-ios-coding/references/project-structure.md`](../ikame-ios-coding/references/project-structure.md); ViewModel → [`viewmodel-pattern.md`](references/viewmodel-pattern.md) + canonical [`ikame-ios-coding/references/viewmodel.md`](../ikame-ios-coding/references/viewmodel.md); function size ≤ 50 lines, golden path, modifier order, weak-self, error handling → [`swift-style.md`](references/swift-style.md); IKNavigation → [`iknavigation-bridge.md`](references/iknavigation-bridge.md); IKMacros → [`ikmacro-bridge.md`](references/ikmacro-bridge.md); IKPopup → [`ikpopup-bridge.md`](references/ikpopup-bridge.md); IKFeedback → [`ikfeedback-bridge.md`](references/ikfeedback-bridge.md).

**Strict-fidelity rules** (enforced by C3 Pass 1):
- No inline string literals in views — use String Catalog or `Strings.<Screen>.<key>`.
- No inline hex / RGB colors — use `Color.<token>`.
- No inline font sizes — use ikFont preset / `AppFont.<token>()`.
- No made-up token names without backing entry in `tokens.json`.
- Layout values trace to Figma (Tailwind class in `design-context.md` OR `Spacing`/`CornerRadius` enum case OR `// Figma: y=192, w=375` comment).
- `.frame(width:)` on Text BANNED unless `// Figma fixed-width: <reason>`.
- `.minimumScaleFactor(0.6)` required on single-line Text in constrained widths.
- Fill-* Image must emit `.resizable() + (.scaledToFill()|.scaledToFit()) + .frame(...)` — all three.
- Safe-area normalization for mockup frames — `.padding(.top, 44|47|59|64|67|79|88)` requires `// safe-area-adjusted: ...` comment.

**Translation references:**
- [`visual-fidelity.md`](references/visual-fidelity.md) — read first, always
- [`layout-translation.md`](references/layout-translation.md) — Auto Layout, stacks, sizing, effects, variants, responsive
- [`design-token-mapping.md`](references/design-token-mapping.md) — typography, colors, gradients
- [`fills-handling.md`](references/fills-handling.md) — read when a container has non-trivial `fills.json`

**Pre-Xcode-16 brownfield projects (traditional `PBXGroup` layout):** after writing new `.swift` files, register them in the `.xcodeproj` so the build picks them up:

```bash
bash ~/.claude/scripts/xcodeproj-add-files.sh \
  --project <path>/<ProjectName>.xcodeproj \
  --target <TargetName> \
  --files "$(find <path>/<ProjectName>/Screens/<ScreenName> -name '*.swift')"
```

No-op on Xcode 16+ "synchronized folder" projects (`PBXFileSystemSynchronizedRootGroup` — files on disk under the target folder are auto-included). Skip entirely when using the Xcode MCP file family (`mcp__xcode__XcodeWrite` / `XcodeUpdate`) — Xcode handles registration. Greenfield scaffolds (`ikxcodegen-scaffold.sh` / `vanilla-scaffold.sh`) produce synchronized-folder projects, so this step only matters for brownfield Xcode 14/15 projects.

### Step C3 — Self-Check (3 passes + L2 + gates)

**Pass 1 — Code vs Inventory.** For each inventory row, verify code matches. Fix every ✗.

**Pass 2 — Code vs Screenshot (structured diff).** Pass 2 produces `.figma-cache/<nodeId>/c3-pass2-diff.md`. Template + 6 anti-hallucination checks in [`verification-loop.md`](references/verification-loop.md) §"Pass 2".

**Pass 3 / 3b — Asset + system-chrome grep:**

```bash
bash ~/.claude/scripts/c3-static-checks.sh --files "<swift files>"
```

Covers Pass 3 (asset grep — no `Image(systemName:)` outside allow-list) and Pass 3b (system chrome grep — no "9:41"/wifi/battery redraws, no ~134×5pt Capsule). Driver writes `GATE: PASS/FAIL`. Explicit form fallback in [`verification-loop.md`](references/verification-loop.md) §"Pass 3/3b explicit".

**L2 — Static token trace (mandatory, Tier-1 co-equal with C5):**

```bash
bash ~/.claude/scripts/c3-driver.sh trace     --cache .figma-cache/<nodeId>
bash ~/.claude/scripts/c3-driver.sh safearea  --cache .figma-cache/<nodeId>
bash ~/.claude/scripts/c3-driver.sh aggregate --cache .figma-cache/<nodeId>
```

L2 cross-references the L1-auto-emitted `c2-audit.json` (every Color / Image / Text / Frame / Padding / Stack / **SafeArea** row from generated `*Screen.swift` + `*View.swift`) against `tokens.json`, `design-context.md`, `metadata.json`, `manifest.json`, `c2-typography-perline.json`, `c2-fills-stops.json`. Soft tolerance ±2pt frame/padding. Deterministic — no LLM judgment, no 2000px PNGs in context. Writes `c3-trace.md` (table) + `c3-gate.json` (aggregate gate).

**L2.5 — Safe-area + nav-bar placement gate (mandatory, blocks `.ignoresSafeArea` misuse + system nav bar overlap):**

`c3-safearea-gate.sh` (run via `c3-driver.sh safearea`) reads the `kind: "safearea"` / `kind: "navbar"` / `kind: "stack"` rows from `c2-audit.json` and flags 4 violation classes — see [`anti-patterns.md`](references/anti-patterns.md) §AP-16 + §AP-17:
- **SA-1 (FAIL)**: `.ignoresSafeArea(...)` on a content container (`ScrollView`, `VStack`, `HStack`, `ZStack`, `List`, `Form`, `LazyVStack`, ...). Only background primitives (`Color`, `Image`, `Rectangle`, `LinearGradient`, ...) may extend under system chrome.
- **SA-2 (FAIL)**: root `.frame(maxHeight: .infinity)` without any safearea row in the same file → content bleeds under status bar / home indicator. Override with `// allow-fullbleed-noinset: <reason>` only when genuinely intentional.
- **SA-3 (WARN)**: `.safeAreaInset(edge: ...)` attached to a background primitive instead of a container.
- **NB-1 (FAIL on `*Screen.swift`, WARN elsewhere)**: file wraps content in `NavigationStack` / `NavigationView` but has **zero nav-bar visibility modifiers** (no `.toolbar(.hidden, for: .navigationBar)`, no `.navigationTitle(...)`, no `.toolbarVisibility(...)`, no `.navigationBarHidden(...)`). When Figma's top zone is a custom header (X / title / icon row — the common pattern), the system nav bar adds ~44pt of empty chrome above the content. **This is the most common root cause of the user-reported "UI tràn ra ngoài safe area" bug.** See AP-17 for fix recipe.

Writes `c3-safearea.json` + surfaces as `layers.l2_safearea.gate` in `c3-gate.json`.

`c3-gate.json.layers.l2.gate == "PASS"` AND `layers.l2_safearea.gate == "PASS"` together satisfy Done-Gate (stop-gate accepts L2 + L2.5 PASS as co-equal with C5 PASS). Full reference: [`verification-loop.md`](references/verification-loop.md) §4b.

**Two failure modes:**
- **Gate FAIL** (report invalid) → regen report; no code edits. After 2 consecutive regen failures, ASK user.
- **Gate PASS, `HIGH_FAILS > 0`** → trigger self-fix loop. Default `MAX_RETRIES=2`. Snapshot to `c3-pass2-diff.attempt-<N>.md`, edit ONLY cited file:line (no refactoring), re-run Pass 2. Asymptote check: if `highFailsHistory` not decreasing → exit as exhausted.

User abort phrases (`stop fixing`, `ship as-is`) → mark `verification.c3Pass2.lastResult = "user_override"`.

### Step C4 — Copy Assets to Project

Per row in `manifest.rows`:

**`exporter == "tagged"`:** imageset already in `Assets.xcassets` (B3 wrote it). Verify `imagesetPath` exists. Rendering mode decided at SwiftUI call site.

**`exporter == "fallback"`** (non-lottie): rendering mode (template for single-color, original for else) → sips @1x/@2x/@3x from 3× source → imageset + Contents.json → copy to pinned `Assets.xcassets`.

**Lottie rows** skipped here — codegen in C2.

**SwiftUI call-site:** `Image(.<exportName>)` for tagged, `Image(.<friendlyName>)` for fallback (iOS 17+ auto-generated `ImageResource`, never string form). Always `.resizable()` + explicit `.frame()`. Single-color → `.renderingMode(.template) + .foregroundStyle()`.

> **Size-suffix awareness (MCPFigma tagged path).** The tagged exporter **appends a `WxH` suffix** to the exportName when the node has a bounding box — e.g. `eICArrow` at 24×24 → registry says `icAIArrow24x24`. Two consequences:
>
> 1. **Use the suffixed name verbatim from `manifest.rows[].exportName`** — `Image(.icAIArrow24x24)`, NOT `Image(.icAIArrow)`. Stripping the suffix produces `ImageResource not found` at build time and the agent often "fixes" that by falling back to `Image(systemName:)` (banned).
> 2. **Two sizes of the same icon → two assets**. A Figma `eICArrow` instance at 24×24 and another at 32×32 export as `icAIArrow24x24` AND `icAIArrow32x32`. Two Swift references, two `.imageset` directories. They are NOT interchangeable — Asset Catalog scales the @1x/@2x/@3x bitmap variants of each asset, not the asset as a whole.
>
> `c6-asset-completeness.sh` Check C catches `Image(.icAIArrow)` references when the registry has `icAIArrow24x24` and flags the mismatch.

Verification: every `Image(.X)` in code is in manifest; every manifest non-lottie row is referenced; every Lottie row → matching `LottieView` call; `import Lottie` present in files using `LottieView`. Full bash block in [`verification-loop.md`](references/verification-loop.md) §"Step C4".

### Step C5 — Visual Validate (mandatory)

After C3 passes, **RUN C5. Do not prompt.** Catches what Pass 2 cannot: real font rendering, shadow at simulator DPI, safe-area, keyboard avoidance, animation start state.

**Skip only when one of these system reasons applies** (user phrases CANNOT override):
- `no_project` — no `.xcodeproj` / `.xcworkspace` after walking up 3 levels.
- `simctl_error` — `xcrun simctl` errors.
- `ci_environment` — `CI=true` / `GITHUB_ACTIONS=true`.
- `no_entry_path` — screen not the launch screen, no `#Preview`/scheme/test target reaches it, no driver available. **Adding a launch-arg / env-var route override is BANNED** (entry-bypass-gate hook blocks).

User phrases like `skip C5`, `bỏ qua C5`, `no build` NOT honored.

#### C5.0 — Engine selection

```bash
bash ~/.claude/scripts/c5-engine-select.sh --screen-file <path-to-Screen.swift>
```

Probes: `xcrun mcpbridge --help` (Xcode 26+) + `pgrep -x Xcode` + `#Preview` block in file. Writes JSON `{"engine":"xcode-mcp"|"xcodebuild","reason":"…"}`. Stash `engine` into `manifest.verification.c5.engine`.

#### Engine A — xcode MCP (preferred)
1. `mcp__xcode__XcodeListWindows` → pick target window
2. `mcp__xcode__BuildProject` with resolved scheme. Errors → `mcp__xcode__XcodeListNavigatorIssues` / `GetBuildLog`. Treat each as `FAIL high` in self-fix loop.
3. `mcp__xcode__RenderPreview` targeting the `*Screen.swift` with `#Preview` → save `c5-render.png`
4. C5.6 procedure unchanged (same template as Engine B)

Engine A eliminates: `previewEntry` prompt, simctl boot cold start (~30-90s), `xcodebuild -list` SPM resolve hang, `sips -Z 2000` shrink.

**Banned:** Engine A is NOT a route-override bypass. RenderPreview renders pure `#Preview` content. No `#if DEBUG` deep-link, no launch-arg env-var. If a screen has no `#Preview`, fall back to Engine B (legitimate).

#### Engine B — xcodebuild + simctl (fallback)
6 sub-steps (commands + edge cases in [`verification-loop.md`](references/verification-loop.md) §5):
1. **C5.1** `xcodebuild -list` — pick scheme.
2. **C5.2** Pick simulator (prefer Booted iPhone, else highest-iOS iPhone 15/16). Stash UDID.
3. **C5.3** `xcodebuild build`. Build fail → FAIL high rows, self-fix loop, do NOT install.
4. **C5.4** `simctl boot/install/launch`. Wrong default screen → ask user for `previewEntry`.
5. **C5.5** + **C5.5b**: `bash ~/.claude/scripts/c5-capture.sh --cache .figma-cache/<nodeId> --udid <udid>` (2s settle, screenshot, PNG validation, long-side ≤2000px shrink).
6. **C5.6** Compare. Read `c5-simulator-cmp.png` + `screenshot-cmp.png`, write `c5-visual-diff.md` (same table format as C3 Pass 2).

Then run **Gate C5**. Full block in [`verification-loop.md`](references/verification-loop.md) §5.7. High-severity diffs feed same self-fix loop as Pass 2 (shared counter, `MAX_RETRIES=2`).

### Step C6 — Asset Completeness (mandatory)

```bash
bash ~/.claude/scripts/c6-asset-completeness.sh \
  --registry .figma-cache/<nodeId>/registry.json \
  --xcassets <project>/Resources/Assets.xcassets \
  --src <project-swift-src-root>
```

Cross-checks every `registry.taggedAssets[].nodeId` landed in `Assets.xcassets` AND is referenced from a `.swift` file, AND that no banned `Image(systemName:)` substitute exists outside the allow-list. **`GATE: PASS` is the only acceptable outcome before declaring done** — also enforced reactively by the Stop gate, but run it explicitly here so failures surface before the stop hook fires. Full reference: [`verification-loop.md`](references/verification-loop.md) §6.

### Step C7 — No System Chrome (mandatory)

```bash
bash ~/.claude/scripts/c7-no-system-chrome.sh --src <project-swift-src-root>
```

Greps the project src for status-bar / home-indicator / Dynamic Island / notch redraws and screen-root `.cornerRadius` / `.clipShape(.rect(cornerRadius:))` ≥ 30pt without `// allow-screen-corner-radius:` justification. **`GATE: PASS` mandatory before declaring done.** Full reference: [`verification-loop.md`](references/verification-loop.md) §7.

### Step C8 — Accessibility delegation (recommended, not blocking)

After C7 PASSes and the view compiles, if the screen has any of: `Button`, `TextField` / `SecureField`, `Toggle`, `Picker`, `NavigationLink`, custom interactive component, **delegate to `ios-accessibility` skill** for VoiceOver labels, Dynamic Type scaling, focus order, and accessibility traits.

This skill does NOT audit a11y itself (out of scope — Figma rarely encodes a11y semantics deterministically). But surface the delegation in the final summary:

> *"Done-Gate satisfied. Screen has interactive controls — recommend running `ios-accessibility` audit before ship."*

For screens with zero controls (pure decorative splash, marketing card), the delegation is optional. Skip silently.

### Optional — Register Code Connect
If your Figma MCP exposes Code Connect, register new reusable components. Not numbered; runs at any point after Phase B.

### Optional — Wall-time instrumentation
Wrap any phase/step with `scripts/timed-run.sh` to record wall-time into `manifest.timing.<key>`, then read it back with `scripts/timing-report.sh`. Use when investigating slow runs or comparing Engine A vs Engine B latency.

```bash
# Time a single step
bash ~/.claude/scripts/timed-run.sh --phase c5 \
  --manifest .figma-cache/<nodeId>/manifest.json \
  -- bash ~/.claude/scripts/c5-capture.sh --cache .figma-cache/<nodeId> --udid <udid>

# Read the breakdown
bash ~/.claude/scripts/timing-report.sh --cache .figma-cache/<nodeId>
bash ~/.claude/scripts/timing-report.sh --flow  .figma-cache              # aggregate across screens
```

Strictly informational — no gate, no auto-run. Skip unless the user asks for a perf trace.

---

## Resume & Retry

Check manifest. `phaseA` + `phaseB` both `done` → skip to Phase C. Some `failed` → retry those only. Cache > 24h → suggest re-fetch. User phrases: "tiếp tục fetch" (resume from last incomplete phase), "implement from cache" (Phase C, Gate B must still pass).

## MCPFigma edge cases

See [`mcpfigma-setup.md`](references/mcpfigma-setup.md) §"Edge cases" for: tokens API empty + warnings (HTTP 200 fallback), 403 `file_variables:read` scope (disclosure protocol — verbatim 403 message in Verification summary), other 401/403 (STOP, no fallback), empty `screens[]` (re-root), tagged-node naming warnings, light/dark variants, etc.

## Hooks (PreToolUse + Stop)

`scripts/install.sh` registers 5 hooks idempotently in `~/.claude/settings.json`:

1. **`figma-to-swiftui-gate.sh`** (PreToolUse Write/Edit) — Phase A+B coverage gate. Blocks Swift Write when any screen-cache lacks Phase A artifacts or Phase B incomplete (failed rows, missing tagged-asset coverage). Closes "downloaded hero, built rest with SwiftUI shapes" failure mode.

2. **`figma-to-swiftui-banned-pattern-gate.sh`** (PreToolUse Write/Edit) — Scans Swift content. Blocks `Image(systemName:)` outside allow-list, `Text("9:41")`, `Capsule()` ≤6pt (home-indicator clone), `FakeStatusBar`/`HomeIndicator`/`NotchView`/`DynamicIslandView` struct names, letter-as-logo, `Text(...).frame(width: <num>)` without `// Figma fixed-width:`, screen-root `.padding(.top, 44|47|59|64|67|79|88)` without `// safe-area-adjusted`, `Image(...)` chains missing `.resizable()`, `cornerRadius` ≥ 30pt without `// allow-screen-corner-radius:`, `Text(...).frame(maxWidth: .infinity)` inside `Button { }` without `// allow-text-fill:`, **`#Preview` block in `*Screen.swift`/`*View.swift` without `.fixedLayout(width:height:)` pinning** (required for L4 SSIM determinism — bypass with `// allow-unpinned-preview:`).

3. **`figma-to-swiftui-entry-bypass-gate.sh`** (PreToolUse Write/Edit) — Blocks edits to `*App.swift` / `*ContentView.swift` / `*RootView.swift` / `*AppRouter.swift` that set `initialStep`/`currentStep` to a screen literal, look up `VERIFY_ROUTE` env vars, or add `#if DEBUG` deep-link parsers. Closes C5 verification-integrity bypass. Legitimate flow-state initialization carries `// figma-entry-bypass-gate: legitimate-flow-state`.

4. **`figma-to-swiftui-audit-emit.sh`** (PostToolUse Write/Edit) — **L1 audit emission.** After every successful Write/Edit of `*Screen.swift` or `*View.swift` in a Figma task, runs the SwiftSyntax `figma-audit` binary on the just-written file and appends rows (color, font, padding, frame, image, text, stack) to `.figma-cache/<nodeId>/c2-audit.json`. Feeds L2 token trace. Hook never blocks; emits a degraded marker if the parser binary is missing.

5. **`figma-to-swiftui-stop-gate.sh`** (Stop) — For every screen-cache with `phaseA == "done"`, requires `phaseB == "done"` + `rows[]` non-empty + **at least one** of: (a) `verification.c5.gate == "PASS"`, (b) `c3-gate.json layers.l2.gate == "PASS"` (Tier-1 co-equal), (c) one of four C5 system skip reasons. Plus project-wide C6 (asset completeness) + C7 (no system chrome) passing.

## Worked examples

Concrete walkthroughs to calibrate flow. Same skill, different project shape.

### Example 1 — Single vanilla SwiftUI screen

**User says:** *"Implement this Figma screen: https://figma.com/design/aBc123/Onboarding?node-id=42-15"*

Project: vanilla SwiftUI, no IKCoreApp, no IKMacros, iOS 17+.

**Actions:**

1. **Phase 0**: `mode-detect.sh` → `brownfield-vanilla`. Open Xcode early.
2. **Phase A**: Parse URL → `fileKey=aBc123`, `nodeId=42:15` (note URL `-` → `:`). Single parallel batch:
   - `get_design_context` → `design-context.md`
   - `get_screenshot` (scale 3) → `screenshot.png`; `sips -Z 2000` → `screenshot-cmp.png`
   - `figma_extract_tokens` → `tokens.json` (full schema — Variables OK)
   - `get_metadata` → `metadata.json`
   - `figma_extract_fills` → `fills.json`
   - `figma_export_assets_unified(autoDiscover: true)` → `manifest.json` (rides along)
3. **Gate A**: `c2-extract-design-context.sh` + `c2-build-bbox-index.sh` + `c2-cache-validate.sh` → PASS
4. **Phase B**: B0a copy → `Strings.swift`. B0b token codegen → `Color+Tokens.swift`, `AppFont.swift`, `Spacing.swift`, dual-mode colorsets. B1 inventory cross-ref against `manifest.rows[]` — every visible element accounted for. Gate B PASS.
5. **Phase C**: `c1-probe.sh` writes `c1-conventions.json` (`usesIKCoreApp: false`, `viewModelPattern: "MVVM"`, `xcstringsPath: "Resources/Localizable.xcstrings"`). C2 builds `OnboardingScreen.swift` outside-in:
   - VStack(spacing: `.md`) → header section → run `c3-driver.sh trace` (incremental) → PASS
   - Hero illustration `Image(.heroOnboarding)` + frame from `metadata.json` bbox via nodeId hint → trace → PASS
   - CTA Button with `.frame(maxWidth: .infinity)` and primary color `Color.appAccent` → trace → PASS
6. **C3**: Pass 1/2 + L2 token trace → 0 FAIL. C4 copy assets to xcassets.
7. **C5**: Engine A `BuildProject` + `RenderPreview` → `c5-render.png`. SSIM 0.96 ≥ 0.92 → PASS.
8. **C6/C7**: asset completeness + no system chrome → PASS.

**Final**: `manifest.verification.c5.gate == "PASS"` AND `c3-gate.json.layers.l2.gate == "PASS"`. Stop-gate releases. Report Verification summary.

### Example 2 — Single Ikame project screen (with IKNavigation)

**User says:** *"làm màn PIN setup này: https://figma.com/design/xY9aB7/AuthFlow?node-id=110-42"*

Project: Ikame fleet, `IKCoreApp` ✓, `IKNavigation` ✓, `ikFont` typography.

**Actions:**

1. **Phase 0**: `mode-detect.sh` → `brownfield-ikame`. `c1-probe.sh` detects `usesIKCoreApp: true, usesIKNavigation: true, usesIKMacros: false, ikFontEnum: "ikFont"`.
2. **Phase A**: Same 5 parallel calls as Example 1. `tokens.json.typography[]` populated with ikFont presets.
3. **Phase B**: B0b skips `AppFont.swift` (Ikame uses `ikFont` family directly per `fonts-styling-bridge.md` §3). Colorsets + Spacing emitted as usual.
4. **Phase C**: Reads `c1-conventions.json` → routes typography to `.ikFont(.bodySemi)` / `.ikFont(16, weight: .semibold)`. Builds `PINSetupScreen.swift` in `Screens/Auth/PINSetup/` folder. ViewModel uses `@MainActor + ObservableObject + enum Action + send(_:)` per Ikame canonical convention.
5. **Routing**: Screen registered in feature router (IKNavigation) — agent extends existing router with `case pinSetup` rather than building a new one.
6. **C3/C5/C6/C7**: same as Example 1.

**Key delta from Example 1**: convention probe routes typography, naming, folder layout — agent doesn't hardcode "use AppFont" — reads from `c1-conventions.json`.

### Example 3 — Multi-screen flow (delegate to figma-flow-to-swiftui-feature)

**User says:** *"Build the entire onboarding flow: https://figma.com/design/aBc123/Onboarding?node-id=1-2 (this is the root frame containing 6 screens)"*

**This skill detects the input is a flow root, NOT a single screen, and hands off.**

**Actions:**

1. Parse URL → `figma_build_registry(nodeId=1:2, depth=10)`. Response: `screens.length == 6`. Multiple screens → handoff.
2. Invoke `figma-flow-to-swiftui-feature`. Pass `fileKey` + `nodeId` of the root. Flow skill takes over:
   - Step 2: convention probe + mode detection (once for whole flow)
   - Step 3: build screen graph (6 nodes + navigation edges from doc / heuristic)
   - Step 4: implement shared feature scaffolding (router, models, services)
   - Step 5: per-screen — delegates BACK to `figma-to-swiftui` for each of the 6 screens (Phase A → B → C as in Example 1/2)
   - Step 7: cross-screen drift check (`c3-cross-screen-drift.sh`)
3. Flow skill's stop-gate aggregates per-screen `c3-gate.json` + checks 7-item Mandatory Output Checklist.

**Key insight**: this skill is per-screen; do NOT try to do flow orchestration. Detect at A2 (`screens.length > 1`) → hand off.

## Key Principles

1. **Three phases, three gates, no skipping.** Each gate prints `GATE: PASS` or you do not proceed.
2. **All assets from Figma — no exceptions.** Missing asset → stop and re-fetch, never improvise.
3. **Fidelity is the goal.** Pixel-for-pixel. Approximation is a bug.
4. **MCP output is a spec.** Parse values per `visual-fidelity.md` §1. Never port React/Tailwind to SwiftUI.
5. **Every value must be traceable.** Trace to tokens, inline style, class, or design-context comment. Untraceable = guessed.
6. **Visual Inventory first, every Phase C.** Never skip lineHeight/tracking/shadow/border/textAlign/stack alignment.
7. **Self-check 3 passes + gates.** Pass 1 code-vs-inventory, Pass 2 code-vs-screenshot (writes diff), Pass 3/3b asset/chrome grep.
8. **Beware SwiftUI defaults.** Always specify `.font(.system(size:))`, `VStack(spacing:)`, `.padding(X)`, `.buttonStyle(.plain)` for custom buttons.
9. **Flatten composed artwork.** Don't reassemble atoms via `.offset()`. When in doubt → flatten.
10. **Two-MCP split is mandatory.** `get_screenshot` (figma-desktop) = FRAME for Pass 2/C5 diff; per-asset PNG = `figma_export_assets_unified` (MCPFigma). Missing either → STOP.
11. **Verification produces artifacts.** Pass 2 writes diff report; C5 captures simulator screenshot + visual diff. Gated, self-fix loop.
12. **Done-Gate.** Task NOT complete until at least ONE of: (a) `manifest.verification.c5.gate == "PASS"` (sim-render path), (b) `c3-gate.json layers.l2.gate == "PASS"` (L2 static-trace path — Tier-1 co-equal), (c) `verification.c5.skipped` is one of `no_project` / `simctl_error` / `ci_environment` / `no_entry_path`. Stating "done"/"xong"/"ship it" without one is a protocol violation. Surface gate status in final user-facing message.

## Verification summary (mandatory final block)

End of every run — success or failure — print verbatim, fill from artifacts:

```
Verification summary
- C3 Pass 2 (offline diff):    PASS / FAIL (high: N, medium: N)
- C3 Pass 3 (asset grep):      PASS / FAIL
- C3 Pass 3b (chrome grep):    PASS / FAIL
- L2 (token trace, static):    PASS / FAIL (pass: N, fail: N, na: N) — c3-gate.json
- C5 (build + simulator):      PASS / FAIL / SKIPPED (<reason>)
- C5.6 (6-step compare):       PASS / FAIL (high: N, medium: N)
- C6 (asset completeness):     PASS / FAIL
- C7 (no system chrome):       PASS / FAIL
- Variables source:            tokens.json (full) | inline-fallback (Variables API empty + warnings) | inline-fallback (file_variables:read scope unavailable)
Artifacts:
  .figma-cache/<nodeId>/c2-audit.json       (L1 audit rows)
  .figma-cache/<nodeId>/c3-trace.md         (L2 trace report)
  .figma-cache/<nodeId>/c3-gate.json        (L2 aggregate)
  .figma-cache/<nodeId>/c3-pass2-diff.md
  .figma-cache/<nodeId>/c5-build.log
  .figma-cache/<nodeId>/c5-simulator.png    (or c5-render.png on Engine A)
  .figma-cache/<nodeId>/c5-visual-diff.md
```

Never fabricate a PASS — open the file with `cat` if uncertain.
