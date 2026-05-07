# Adaptation Workflow

Guide for adapting existing SwiftUI screens to match updated Figma designs. This workflow replaces the standard "build from scratch" approach when the user asks to update, adapt, or align an existing screen.

## When to Use

Trigger this workflow when:
- The user says "adapt", "update", "align", "match" an existing screen to a Figma design
- The user provides a Figma URL and references an existing view/screen in the codebase
- The task is to modify existing code rather than create new views

## §0. Convention Probe (mandatory, run BEFORE the audit)

Before reading the existing code or comparing to Figma, the skill probes the project to learn its conventions and emits `c1-conventions.json` to `.figma-cache/<nodeId>/c1-conventions.json` (single-screen) or `.figma-cache/_shared/c1-conventions.json` (flow). The cache is shared across the run — every reference file reads from this single source of truth.

**Probe steps (in order, all read-only):**

1. **Folder layout.** `find Screens -maxdepth 2 -name '*Screen.swift'` — count matches.
   - ≥ 2 hits with the `Screens/<X>Screen/<X>Screen.swift` shape → `screenFolderConvention = "screen-based"`.
   - Otherwise → `"flat"`.
2. **ViewModel pattern.** Open the most recent `*ViewModel.swift` file. Check for: `@MainActor`, `enum Action`, `func send(_ action: Action)`, `enum Route` nested.
   - All four present → `viewModelPattern = "state-action-reducer"`.
   - Class exists but missing reducer → `viewModelPattern = "ad-hoc"` and emit a warning that new ViewModels will follow the canonical pattern (`references/viewmodel-pattern.md`).
   - No ViewModel files at all → `viewModelPattern = "none"` (skill picks reducer pattern by default).
3. **Deployment target.** Read `IPHONEOS_DEPLOYMENT_TARGET` from `.xcconfig` / `project.pbxproj`. Cache as `minDeploymentTarget` (e.g. `"16.0"`, `"17.0"`).
4. **Observation flavor.** If `minDeploymentTarget >= 17` AND project has any `@Observable` class → `observationFlavor = "observable"`. Else → `"observable-object"`.
5. **IKNavigation detection.** Per `references/iknavigation-bridge.md` §1. Cache `usesIKNavigation` (bool) and `routerName` (string, when found).
6. **IKMacros detection.** Per `references/ikmacro-bridge.md` §1. Cache `usesIKMacros` (bool) and `apiRepoTypeName` (when found).
7. **Token enums.** Search for these enum names; cache the cases when found:
   - `IKFont` / `AppFont` / `Typography` → `ikFontEnum`
   - `Spacing` / `AppSpacing` / `Padding` → `spacingEnum`
   - `IKCoreApp` / `AppColors` / `ColorPalette` → `colorEnum`
   When the enum is missing, the corresponding flag is `null` and the skill falls back to inline literals per `references/swiftui-pro-bridge.md` §1c.
8. **xcstrings catalog.** `find . -name '*.xcstrings'` — when present, cache path; the skill routes `Text(...)` through the symbol API.
9. **Asset catalog path.** `find . -name '*.xcassets' -type d` — single hit caches the path; multiple hits → interactive prompt to pin one (cached for the run).

**Output** — `c1-conventions.json` shape:

```json
{
  "screenFolderConvention": "screen-based" | "flat",
  "viewModelPattern": "state-action-reducer" | "ad-hoc" | "none",
  "minDeploymentTarget": "16.0",
  "observationFlavor": "observable" | "observable-object",
  "usesIKNavigation": true | false,
  "routerName": "AppRouter" | null,
  "viewToRouteWiring": "onChange" | "environmentRouter" | null,
  "usesIKMacros": true | false,
  "apiRepoTypeName": "AppAPIRepository" | null,
  "ikFontEnum": "IKFont" | "AppFont" | null,
  "spacingEnum": "Spacing" | null,
  "colorEnum": "IKCoreApp" | null,
  "xcstringsPath": "...path..." | null,
  "assetCatalogPath": "...path..."
}
```

The skill's C2 implement step reads this JSON and adapts every emission decision to it. The c8-* gates also read from it to know whether to enforce or skip a particular check.

**When the probe is impossible** (e.g. brand-new empty project): skill defaults to `screenFolderConvention = "screen-based"`, `viewModelPattern = "state-action-reducer"`, `usesIKNavigation = false`, `usesIKMacros = false`. The user can override during C1 confirmation.

**Where this lives in the workflow.** For single-screen `figma-to-swiftui` runs, the probe is part of Step C1. For `figma-flow-to-swiftui-feature`, the probe runs once at flow Step 2 (Audit the Codebase) and the result is shared across all per-screen Phase A/C calls.

---

## Adaptation Audit Process

### 1. Read the Existing Code

Read the full source of the view being adapted, including:
- The main view file
- Any subcomponents it references (custom views, shared components)
- Related model types to understand available data

Note every element and its properties: spacing, padding, colors, fonts, layout structure, corner radii, opacity values.

### 2. Build a Diff Checklist

Compare the existing code against the Figma design context and screenshot **element by element**. Categorize each difference:

- **ADD** — Element exists in Figma but not in code
- **UPDATE** — Element exists in both but with different properties. Always include old → new values.
- **REMOVE** — Element exists in code but not in Figma. Always confirm with user before removing.

### 3. Spacing Audit

Spacing is the most commonly missed difference. For every container and element, explicitly compare:
- Horizontal and vertical padding values
- Stack spacing values (VStack/HStack spacing parameter)
- Gaps between elements
- Edge insets and safe area handling
- Frame sizes (width, height)

Never assume existing values are "close enough". If Figma says 20 and the code says 16, that is a change that must be listed.

### 4. Present the Checklist

Show the full checklist to the user before writing any code. Use this format:

```
Differences found:

### Structural
- ADD: timer card component (lime background, countdown, progress bar)
- ADD: illustration header with text overlay
- REMOVE: separate winner section — confirm?

### Layout & Spacing
- UPDATE: avatar size 56 → 64
- UPDATE: card spacing (avatar ↔ content) 12 → 8
- UPDATE: bottom padding per card 16 → 24
- UPDATE: divider opacity 0.12 → 0.14

### Typography
- UPDATE: title font 17pt medium → 20pt semibold
- UPDATE: team name font 17pt → 20pt regular
- UPDATE: points font 28pt semibold → 22pt expanded semibold

### Colors & Styling
- UPDATE: place badge — gold/silver/bronze gradients → purple gradient for all
- UPDATE: background gradient — hardcoded RGB → asset catalog colors

### New Data Requirements
- Timer: hardcode or needs API data?
- Stats tags: data source needed?
```

Group changes by category (structural, spacing, typography, colors) so the user can review systematically.

### 5. Clarify Unknowns

Before implementing, ask the user about:
- **New components** that need data not available in current models (e.g., timer, stats)
- **Removed elements** — confirm before deleting
- **Ambiguous elements** — when Figma shows something that could be system-provided or custom

### 6. Apply All Changes

After user confirmation, apply every item from the checklist. Do not skip items that seem minor — a 4px padding difference or a 0.02 opacity change matters for visual fidelity.

## Common Pitfalls

1. **"Close enough" bias** — When existing code looks similar to the design, it's tempting to skip small differences. The checklist prevents this.
2. **Missing new elements** — Focus on what changed in existing elements can cause you to overlook entirely new components added to the design.
3. **Ignoring removed elements** — If the design no longer shows something the code has, flag it for removal rather than leaving dead UI.
4. **Spacing shortcuts** — Never eyeball spacing. Extract exact values from `get_design_context` properties (padding, gap, itemSpacing).
5. **Font weight/width confusion** — Figma "Expanded Semibold" is `.semibold` weight + `.width(.expanded)`, not just `.semibold`. Check both weight and width.

