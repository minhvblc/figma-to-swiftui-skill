# Figma to SwiftUI Skills

Translate Figma designs into production-ready SwiftUI code with pixel-perfect accuracy using the [Figma MCP Server](https://developers.figma.com/docs/figma-mcp-server/). Built for the [Agent Skills open format](https://agentskills.io/home).

This repository contains two companion skills:
* `figma-to-swiftui` for screen and component translation
* `figma-flow-to-swiftui-feature` for end-to-end feature orchestration across multiple screens

The base `figma-to-swiftui` skill provides a structured workflow that guides AI agents through screen discovery, fetching design context, downloading assets, and implementing native SwiftUI views — without blindly porting React + Tailwind output.

For how the two skills compose, how a source document (`.txt` / `.md`) drives Figma fetching, and how the fetch discipline avoids MCP timeouts and wasted tokens, see **[docs/workflow.md](docs/workflow.md)**.

## Who this is for

* iOS developers who receive designs in Figma and want to speed up implementation
* Teams using Figma Dev Mode who want consistent design-to-code translation
* Anyone who wants their AI coding tool to produce native SwiftUI instead of web-style layouts

## What the Skills Do

### Structured Workflow

Guides the agent through URL parsing, optional root-node screen discovery, design-context fetch, screenshot capture, token fetch, asset handling, implementation, and optional validation.

### Native SwiftUI Translation

Complete mapping tables for:
* **Layout** — Figma Auto Layout → VStack/HStack/ZStack, padding, spacing, sizing modes
* **Typography** — font family, weight, size, line height, letter spacing
* **Colors** — hex, gradients, opacity, dark mode, design tokens
* **Components** — buttons, inputs, lists, navigation, sheets, cards
* **Effects** — shadows, blur, corner radius, borders, masks, Liquid Glass (iOS 26+)
* **Animations** — prototype transitions → SwiftUI animations, matched geometry, Lottie integration

### Smart Asset Handling

* Prefers SF Symbols over custom icons (with per-asset confirmation for cross-platform projects)
* Downloads from MCP localhost URLs directly — no placeholders
* Raster images to Asset Catalog with @1x/@2x/@3x variants
* Vector assets as SVG with Preserve Vector Data

### Project-Aware

* Checks project dependencies before implementing — uses Kingfisher, Lottie, SnapKit, or whatever the project already has instead of introducing native alternatives
* Maps Figma design tokens to the project's existing color/typography/spacing system
* Skips system-provided elements (keyboard, status bar, home indicator, system alerts, etc.)
* Respects platform conventions: safe areas, Dynamic Type, accessibility

### Not Opinionated About Architecture

This skill handles visual translation only. It does not enforce MV, MVVM, or any other pattern — that's the job of your architecture skill.

### Need Full Feature Flow?

Use the companion skill `figma-flow-to-swiftui-feature` when the request is not just a screen, but a multi-screen feature or user journey. That skill handles:
* screen graph and flow planning
* ambiguous screen/action mapping with confidence checks
* navigation and state integration
* loading, error, empty, success, retry, and validation states
* project-aware reuse of routers, services, `IKFont`, `IKCoreApp`, assets, and colors

Then use `figma-to-swiftui` for the per-screen visual translation inside that flow.

## How to Use This Skill

### Quick Install

```bash
npx skills add https://github.com/minhvblc/figma-to-swiftui-skill --skill figma-to-swiftui
npx skills add https://github.com/minhvblc/figma-to-swiftui-skill --skill figma-flow-to-swiftui-feature
```

### Manual Install

1. **Clone** this repository
2. **Install or symlink** either the `figma-to-swiftui/` folder or the `figma-flow-to-swiftui-feature/` folder following your tool's skills installation docs
3. **Ensure Figma MCP server is connected** — see `figma-to-swiftui/references/figma-mcp-setup.md` for troubleshooting

Then use in your AI agent:

> Use the figma-to-swiftui skill and implement this design: https://www.figma.com/design/abc123/MyApp?node-id=10-5&m=dev

For end-to-end feature work:

> Use the figma-flow-to-swiftui-feature skill together with figma-to-swiftui and implement this flow: Login node ..., OTP node ..., Success node ...

#### Where to Save Skills

* **Codex:** [Where to save skills](https://developers.openai.com/codex/skills/#where-to-save-skills)
* **Claude Code:** [Using Skills](https://platform.claude.com/docs/en/agents-and-tools/agent-skills/overview#using-skills)
* **Cursor:** [Enabling Skills](https://cursor.com/docs/context/skills#enabling-skills)

## Prerequisites

* **Figma MCP server** connected and authenticated (see `figma-to-swiftui/references/figma-mcp-setup.md`)
* **Figma URL** with a node ID — supports `/design/` and legacy `/file/` formats, with or without `www.`, `&m=dev`, etc.
* **Xcode project** with an established SwiftUI codebase (recommended)

## Skill Structure

```text
repo-root/
  figma-to-swiftui/
    SKILL.md                              — Main workflow (Step 0 doc → Step 8)
    references/
      source-document.md                  — Read .txt/.md brief before Figma; single vs flow routing
      fetch-strategy.md                   — Metadata-first, lazy fetch, circuit breaker, call budget
      adaptation-workflow.md              — Existing screen adaptation and diff audit
      screen-discovery.md                 — Root node and multi-screen candidate mapping
      layout-translation.md               — Auto Layout → Stacks, sizing, scroll, common patterns
      responsive-layout.md                — Size classes, adaptive layouts, multi-device designs
      design-token-mapping.md             — Figma variables → Color/Font/Spacing tokens
      component-variants.md               — Figma variants → SwiftUI styles and enums
      asset-handling.md                   — SF Symbols, xcassets, SVG, remote images
      figma-mcp-setup.md                  — MCP connection, troubleshooting
  figma-flow-to-swiftui-feature/
    SKILL.md                              — Flow orchestration and feature completeness
    references/
      ambiguous-mapping.md                — Candidate screen/action mapping with confidence
      flow-input-contract.md              — Normalize user prompt into a feature contract
      feature-flow-workflow.md            — Screen graph and implementation sequence
      feature-completeness.md             — Loading/error/empty/success/validation checklist
      navigation-state-integration.md     — Reuse project routing and state patterns
      output-schema.md                    — Required pre-code contract and mapping summary
```

## Key Design Decisions

**MCP output is a spec, not code.** Figma MCP returns React + Tailwind by default. This skill treats it as a design specification and builds native SwiftUI from the extracted properties — it never ports web code.

**Ask, don't assume.** The skills now force discovery and confidence checks for ambiguous root nodes, screens, and actions before code generation continues.

**System elements are not implemented.** Keyboards, status bars, navigation back buttons, and other iOS-provided UI that designers include for mockup context are skipped automatically.

**Project dependencies take priority.** Before writing any code, the agent checks what libraries the project already uses and follows established patterns.

## Contributing

Contributions are welcome! If you have improvements to the translation tables, additional component mappings, or better reference material — please open a PR.

When contributing:
* Keep each `SKILL.md` focused on the workflow — detailed mappings go in that skill's `references/`
* Test changes against real Figma designs with the MCP server connected
* Follow the [Agent Skills open format](https://agentskills.io/home) structure
