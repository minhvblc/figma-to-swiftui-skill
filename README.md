# Figma to SwiftUI Skills

Translate Figma designs into production-ready SwiftUI code with pixel-perfect accuracy. Built for the [Agent Skills open format](https://agentskills.io/home).

This repository contains two companion skills:
* `figma-to-swiftui` — single-screen / single-component translation
* `figma-flow-to-swiftui-feature` — end-to-end feature orchestration across multiple screens

The pipeline is **Figma-first** by design: every visible icon, color, font, padding, and string in the generated SwiftUI must trace back to a Figma node. Inventing copy, colors, SF-Symbol substitutions for designed icons, or "approximation" shortcuts is forbidden by mandatory bash gates inside each skill (see `figma-to-swiftui/SKILL.md` Gate A / B / C3 Pass 1–4 / C5).

For how the two skills compose, how a source document (`.txt` / `.md`) drives Figma fetching, and how the fetch discipline avoids MCP timeouts and wasted tokens, see **[docs/workflow.md](docs/workflow.md)**.

## Who this is for

* iOS developers who receive designs in Figma and want to speed up implementation
* Teams using Figma Dev Mode who want consistent design-to-code translation
* Anyone who wants their AI coding tool to produce native SwiftUI instead of web-style layouts or improvised UI

## Prerequisites — two MCP servers, both required

The skill orchestrates two complementary MCPs. **If either is missing, the skill will STOP** rather than improvise (this is a hard rule, not a fallback case).

| MCP server | Provides | Install |
|---|---|---|
| **`figma-desktop`** (official Figma) | `get_metadata`, `get_design_context`, `get_screenshot`, `get_variable_defs` — design spec, FRAME screenshot, variable defs | [developers.figma.com/docs/figma-mcp-server](https://developers.figma.com/docs/figma-mcp-server/) |
| **`figma-assets`** (this org's MCPFigma) | `figma_build_registry`, `figma_extract_tokens`, `figma_export_assets_unified` — screen graph, SwiftUI-ready tokens, per-asset PNG export into `Assets.xcassets` | See [Install MCPFigma](#install-mcpfigma) below, or [`figma-to-swiftui/references/mcpfigma-setup.md`](figma-to-swiftui/references/mcpfigma-setup.md) |

Plus the obvious:
* **Figma URL** with a node ID (`/design/...?node-id=...`) — or a current selection in the Figma desktop app
* **Xcode SwiftUI project** (deployment target iOS 16+ recommended; the skill auto-detects and emits iOS 16 fallbacks where relevant)
* **Figma Personal Access Token** with `File content read` scope (used by MCPFigma; create at [figma.com/settings](https://www.figma.com/settings))

## Install

### One-line install (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/minhvblc/figma-to-swiftui-skill/master/scripts/bootstrap.sh \
  | FIGMA_ACCESS_TOKEN=figd_xxx bash
```

The bootstrap clones this repo to `~/.local/share/figma-to-swiftui-skill/`, then runs `install.sh --yes --user` for you. Idempotent — re-running fast-forwards the checkout.

Pin a release or pass extra flags through:

```bash
# pin to a specific tag
curl -fsSL <URL> | FIGMA_ACCESS_TOKEN=figd_xxx BOOTSTRAP_REF=v0.3.0 bash

# forward install.sh flags after bash -s --
curl -fsSL <URL> | FIGMA_ACCESS_TOKEN=figd_xxx bash -s -- --no-hooks --version v0.3.0
```

After it finishes, do the two manual steps the bootstrap **cannot** do for you (Figma's product, Claude is a separate process):

1. Open Figma → Preferences (⌘,) → enable **Dev Mode MCP server** (Dev Mode required). Bootstrap detects whether `/Applications/Figma.app` exists and prints the exact steps.
2. Restart Claude Code (⌘Q + reopen) so the new MCP config loads.

### Easy path — clone + run script

If you'd rather review the source first or you don't want to set the env var inline:

```bash
git clone https://github.com/minhvblc/figma-to-swiftui-skill.git
cd figma-to-swiftui-skill
./scripts/install.sh
```

The installer is idempotent and safe to re-run. It will:

1. Check toolchain (macOS, curl, python3 — and git+swift only if it has to build from source)
2. **Download the latest pre-built `mcp-figma` binary** from the [MCPFigma releases page](https://github.com/minhvblc/MCPFigma/releases) (universal binary for arm64 + x86_64). Falls back to clone+`swift build` if no release is available — or pass `--build-from-source` to force the build path.
3. Prompt for your `FIGMA_ACCESS_TOKEN` (with step-by-step instructions) and validate it against the Figma API
4. Back up your existing Claude config, then patch in the `figma-assets` MCP entry — **user-level (`~/.claude.json`) by default**. Use `--project` to register inside a specific iOS project's `.claude/mcp.json` instead.
5. Copy the two skill folders into `~/.claude/skills/` (use `--symlink` if you want to `git pull` to update later)
6. Install + register 6 enforcement hooks (PreToolUse / PostToolUse / Stop) into `~/.claude/settings.json` — disable with `--no-hooks`
7. Detect Figma.app + run `scripts/doctor.sh` + print a copy-paste test command

Useful flags:

```bash
./scripts/install.sh                       # default — download binary, install everything
./scripts/install.sh --yes                 # non-interactive (re-install / CI / scripts)
./scripts/install.sh --user                # force user-level config (~/.claude.json)
./scripts/install.sh --project             # force project-level ($PWD/.claude/mcp.json)
./scripts/install.sh --version v0.3.0      # pin a specific release
./scripts/install.sh --build-from-source   # always clone + swift build (for hacking on MCPFigma)
./scripts/install.sh --symlink             # symlink skills (re-run git pull to update)
./scripts/install.sh --no-hooks            # skip hook installation
FIGMA_ACCESS_TOKEN=figd_xxx ./scripts/install.sh                # non-interactive token
FIGMA_ACCESS_TOKEN=figd_xxx ./scripts/install.sh --yes --user   # fully headless (CI / onboarding)
```

After it finishes, install the **figma-desktop MCP** separately (Figma Preferences → enable Dev Mode MCP server — the installer prints exact steps once it detects `/Applications/Figma.app`) and restart Claude.

You can verify any time with:

```bash
./scripts/doctor.sh
```

The doctor checks 6 things and prints exact fix commands for any failure.

> **About the unsigned binary.** The pre-built binary is unsigned (no Apple Developer ID). The installer automatically removes the macOS quarantine attribute (`xattr -d com.apple.quarantine`) so Gatekeeper doesn't block first launch. If you'd rather build it yourself, use `--build-from-source`.

### Manual install

#### 1. Install MCPFigma (`figma-assets` server)

**Option A — pre-built binary (recommended).** Download the latest universal binary from the [releases page](https://github.com/minhvblc/MCPFigma/releases):

```bash
mkdir -p ~/.local/share/mcp-figma && cd ~/.local/share/mcp-figma
curl -fsSL -o mcp-figma.tar.gz \
  https://github.com/minhvblc/MCPFigma/releases/latest/download/mcp-figma-<VERSION>-darwin-universal.tar.gz
tar -xzf mcp-figma.tar.gz && rm mcp-figma.tar.gz
chmod +x mcp-figma
xattr -d com.apple.quarantine mcp-figma 2>/dev/null || true   # bypass Gatekeeper (binary is unsigned)
```

Binary lives at `~/.local/share/mcp-figma/mcp-figma`. The `--latest/download/` URL pattern requires you to substitute the actual version into the filename — or pull the release page first to grab the exact asset name.

**Option B — build from source.** Requires macOS 13+ and Swift 6.0+ (Xcode 16+):

```bash
git clone https://github.com/minhvblc/MCPFigma.git
cd MCPFigma
swift build -c release
```

Binary then lives at `<repo>/.build/release/mcp-figma`.

Register with Claude Code at the **project level** (recommended, so the token stays out of `~/`):

```jsonc
// <project>/.claude/mcp.json
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

Or globally at `~/.claude.json`. Claude Desktop uses `~/Library/Application Support/Claude/claude_desktop_config.json` with the same shape. Restart Claude after editing. Full options + troubleshooting: [`figma-to-swiftui/references/mcpfigma-setup.md`](figma-to-swiftui/references/mcpfigma-setup.md).

#### 2. Install figma-desktop MCP

Follow Figma's official guide: [Figma MCP Server docs](https://developers.figma.com/docs/figma-mcp-server/). Verify with `claude mcp list` — you should see both `figma-assets` AND `figma-desktop` (or `figma`, depending on how Figma names it in your version).

#### 3. Install the skills

**Via the Agent Skills CLI:**

```bash
npx skills add https://github.com/minhvblc/figma-to-swiftui-skill --skill figma-to-swiftui
npx skills add https://github.com/minhvblc/figma-to-swiftui-skill --skill figma-flow-to-swiftui-feature
```

**Or copy / symlink** the two skill folders into your tool's skills directory:
* **Claude Code:** `~/.claude/skills/` (user) or `<project>/.claude/skills/` (project) — see [Using Skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview#using-skills)
* **Codex:** see [Where to save skills](https://developers.openai.com/codex/skills/#where-to-save-skills)
* **Cursor:** see [Enabling Skills](https://cursor.com/docs/context/skills#enabling-skills)

#### 4. Verify

Run `./scripts/doctor.sh` from this repo, or manually inside Claude Code:

```
List the MCP tools available right now. I should see figma_build_registry, figma_extract_tokens, figma_export_assets_unified, get_design_context, get_screenshot, get_metadata.
```

If any of those six are missing, fix the MCP install before running the skill — the skill will refuse to proceed without them.

## Use

Single screen / component:

> Use the figma-to-swiftui skill and implement this design: `https://www.figma.com/design/abc123/MyApp?node-id=10-5&m=dev`

Multi-screen flow:

> Use the figma-flow-to-swiftui-feature skill and implement this onboarding flow: Welcome `node-id=10-5`, PIN `node-id=10-6`, Success `node-id=10-7`. The PM brief is in `brief.md`.

Resume after a partial run (cache persists across sessions):

> Resume the figma-to-swiftui run for node `10-5` from cache.

The skill writes its working state under `.figma-cache/<nodeId>/` next to the project. Add this to `.gitignore`.

## What the Skills Do

### Three-phase workflow with mandatory gates

`figma-to-swiftui` runs Phase A (Discover & Spec) → Phase B (Asset Pipeline) → Phase C (Implement). Each phase ends with a bash gate that prints `GATE: PASS` or fails — the next phase will not start without a pass. Phase C also runs four self-check passes (offline diff, asset-substitution grep, system-chrome grep, swiftui-pro review) plus a C5 simulator build + screenshot diff.

### Native SwiftUI translation

Complete mapping tables for layout (Figma Auto Layout → VStack/HStack/ZStack), typography (font family, weight, size, line height, letter spacing), colors (hex / gradients / opacity / dark mode / design tokens), components, effects (shadows, blur, corner radius, borders, masks, Liquid Glass for iOS 26+), and animations including Lottie placeholders.

### Strict-fidelity asset handling

* **Every visible icon, logo, illustration → downloaded from Figma as PNG.** SF Symbols, colored shapes standing in for logos, "simplified" illustrations, and `Text("G")` placeholders are **banned** — enforced by Pass 3 grep.
* Designer-tagged assets (`eIC*` / `eImage*`) → `.imageset` written directly into `Assets.xcassets` at @2x/@3x with iOS naming convention (`icAIClose`, `imageAIBanner`).
* Non-tagged regions → flatten or decompose per visual rules in `figma-to-swiftui/references/asset-handling.md`.
* Lottie placeholders (`eAnim*`) → `LottieView` stubs with literal name `"placeholder_animation"` plus a `// TODO` for the developer.

### Strict-fidelity copy and tokens

* Every visible string is extracted from `design-context.md` once, written to a String Catalog or `Strings.swift` enum keyed by Figma node ID, and referenced from views. Inline English literals (`Text("Continue")`) are **banned** by Pass 1.
* Every color / font / spacing literal is extracted from Figma Variables once via `figma_extract_tokens`, codegened into `DesignSystem/Color+Tokens.swift` / `AppFont.swift` / `Spacing.swift`, and referenced from views. Inline hex / RGB / font-size literals in views are **banned** by Pass 1.

### iOS system chrome is never drawn

Status bar, Dynamic Island, home indicator, system keyboard, system back chevron — even if the Figma frame includes a mockup of them — are stripped from the visual inventory. iOS renders these. Drawing them in SwiftUI duplicates what iOS already shows and breaks on real devices.

### Project-aware

* Detects `Spacing` / `IKFont` / `IKCoreApp` / `Color(hex:)` / Lottie SDK / String Catalog / generated symbol assets in the project, and routes Figma values through them where present (no parallel abstractions).
* Auto-detects `IPHONEOS_DEPLOYMENT_TARGET` and emits iOS 16 fallbacks for iOS 17/18/26 APIs with a search-replaceable comment marker.
* Uses `NavigationStack` + `.navigationDestination(for:)`; refuses to mix in deprecated `NavigationView` / `NavigationLink(destination:)`.
* Per-screen C5 = build with `xcodebuild`, boot simulator, install, screenshot, visual-diff vs Figma.

### Not opinionated about architecture

Visual translation only. Does not enforce MV / MVVM / TCA / any pattern — that's the job of your architecture skill.

### Need full feature flow?

`figma-flow-to-swiftui-feature` orchestrates multiple screens: builds a screen graph, resolves ambiguous screen-to-node mapping with confidence checks, wires navigation and shared state via the project's existing routing pattern, fills in non-happy-path states (loading / error / empty / success / retry / validation), and delegates each screen back to `figma-to-swiftui` for pixel-level translation.

After all screens are built, it hands the planned walkthrough off to the `ios-simulator-verify` skill to drive the journey end-to-end in a simulator and report `verified / degraded / not-checked` per step.

## Skill Structure

```text
repo-root/
  figma-to-swiftui/
    SKILL.md                              — Phase A → B → C with mandatory gates
    references/
      source-document.md                  — Read .txt/.md brief before Figma; single vs flow routing
      fetch-strategy.md                   — Lazy fetch, circuit breaker, call budget
      figma-mcp-setup.md                  — figma-desktop MCP setup + troubleshooting
      mcpfigma-setup.md                   — figma-assets (MCPFigma) setup + tool reference
      screen-discovery.md                 — Registry-first screen detection, state-vs-screen disambiguation
      adaptation-workflow.md              — Existing screen adaptation and diff audit
      visual-fidelity.md                  — Inventory codes, parsing rules, Pass 2 template
      verification-loop.md                — C3 Pass 2 + C5 build/screenshot/diff workflow
      layout-translation.md               — Auto Layout → Stacks, sizing, scroll
      responsive-layout.md                — Size classes, adaptive layouts
      design-token-mapping.md             — Figma variables → Color/Font/Spacing
      component-variants.md               — Figma variants → SwiftUI styles and enums
      asset-handling.md                   — Tagged path, fallback path, dedupe, naming
      lottie-placeholders.md              — eAnim* → LottieView stub codegen
      swiftui-pro-bridge.md               — Always-on transforms + iOS 16 fallbacks + token routing
      swiftui-pro/                        — swiftui-pro standards snapshot (api, views, data, accessibility, ...)
  figma-flow-to-swiftui-feature/
    SKILL.md                              — Flow orchestration, screen graph, integration
    references/
      flow-input-contract.md              — Normalize user prompt into a feature contract
      ambiguous-mapping.md                — Candidate screen/action mapping with confidence
      feature-flow-workflow.md            — Screen graph and implementation sequence
      feature-completeness.md             — Loading/error/empty/success/validation checklist
      navigation-state-integration.md     — Reuse project routing and state patterns
      output-schema.md                    — Required pre-code contract and mapping summary
  docs/
    workflow.md                           — How the two skills compose end-to-end
    designer-handoff.md                   — Tagging conventions for designers
  scripts/
    install.sh                            — One-shot installer (clone+build+config+skills+doctor)
    doctor.sh                             — Verify install (toolchain, MCPs, token, skills)
```

## Key Design Decisions

**Figma is ground truth.** Every visible value in generated code traces to a Figma node, a token, or a `data-node-id` in `design-context.md`. Untraceable = guessed = bug. Source-of-truth conflicts: Figma decides structure, the source document decides behavior.

**MCP output is a spec, not code.** The figma-desktop MCP returns React + Tailwind by default. The skill parses values out of it and builds native SwiftUI — it never ports web code.

**Two MCPs, both mandatory.** figma-desktop provides spec + screenshots; MCPFigma provides screen graph + tokens + asset export. Missing one → STOP, never fall back to substitutions.

**Ask, don't assume.** Ambiguous root nodes, screen-vs-state pairs, and low-confidence action mappings stop the run for user confirmation before any code is written.

**System elements are not drawn.** Keyboards, status bars, Dynamic Island, home indicator, system back chevron — iOS renders these; the skill enforces with a Pass 3b grep.

**Verification produces artifacts.** `c3-pass2-diff.md`, `c5-build.log`, `c5-simulator.png`, `c5-visual-diff.md` per screen. The model's claim of "done" is checked against these files. The Done-Gate refuses to declare a task complete until C5 has actually run (or has been auto-skipped for a system reason like CI / no project / missing simctl).

**Project dependencies take priority.** Existing `Spacing` / `IKFont` / `IKCoreApp` / Lottie SDK / String Catalog / `NavigationStack` patterns are detected and reused — the skill refuses to introduce parallel tokens, parallel routers, or unwanted dependencies.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Skill says "MCPFigma not configured" and stops | `figma-assets` MCP not registered | Re-do step 1 of Install + restart Claude |
| Skill says "Pass 2 cannot run without screenshot.png" | `figma-desktop` MCP not registered | Re-do step 2 of Install + restart Claude |
| `figma_build_registry` errors with "unauthorized" | Bad / expired `FIGMA_ACCESS_TOKEN` | Regenerate at [figma.com/settings](https://www.figma.com/settings), update MCP env |
| Gate B fails with "rows empty but design has N hints" | B1 Inventory missed nodes | Re-scan `screenshot.png` and `design-context.md`; do NOT bypass the gate |
| `cornerRadius()` / `foregroundColor()` lint failures in Pass 4 | Used deprecated SwiftUI API | Replace per `references/swiftui-pro-bridge.md` §2 (always-on transforms) |
| C5 says "FAIL: build" | `xcodebuild` build error | Open `c5-build.log`, fix compile errors, re-run C5 |
| Agent claims done without C5 results | Done-Gate violation | Ask the agent to re-run; consider enabling the Stop hook (see "Strongly recommended hooks" in `figma-to-swiftui/SKILL.md`) |

More: [`figma-to-swiftui/references/mcpfigma-setup.md`](figma-to-swiftui/references/mcpfigma-setup.md) and [`figma-to-swiftui/references/figma-mcp-setup.md`](figma-to-swiftui/references/figma-mcp-setup.md).

## Contributing

Contributions are welcome — improvements to translation tables, additional component mappings, better reference material, designer tagging conventions, or new failure modes for the banned-phrase grep.

When contributing:
* Keep each `SKILL.md` focused on the workflow — detailed mappings live in that skill's `references/`
* Test changes against real Figma designs with both MCPs connected
* Never relax a fidelity rule without a corresponding new gate replacing it
* Follow the [Agent Skills open format](https://agentskills.io/home) structure
