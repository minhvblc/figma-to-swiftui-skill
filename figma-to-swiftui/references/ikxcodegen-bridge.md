# ikxcodegen Bridge

How `figma-to-swiftui` integrates with **ikxcodegen** — Ikame's iOS scaffold CLI. Conditional — applies only when the skill needs to **create a new project** OR is operating in an existing Ikame project (detected via `usesIKCoreApp == true` in `c1-conventions.json`).

`ikxcodegen` produces an empty Ikame-flavored Xcode project (folder tree + Podfile with the IKCoreApp umbrella + xcconfig + GoogleService templates). It does NOT generate any feature code — every Swift file is either Apple-template (`AppDelegate`, `SceneDelegate`) or empty boilerplate (`MainScreen.swift`, `MainRoute.swift`, `MainRouter.swift`). The skill fills the empty tree with feature code generated from Figma.

---

## §1. Mode detection (greenfield vs brownfield)

The skill picks ONE mode at start of run. Mode is locked for the run.

| Folder state | Mode | Skill behavior |
|---|---|---|
| Empty folder, OR no `.xcodeproj` AND no `Podfile` | **greenfield** | STOP and confirm with user before calling `ikxcodegen`. Then call CLI. Then proceed with feature generation. |
| `.xcodeproj` + `Podfile` both present, `Podfile` contains `pod 'IKCoreApp'` | **brownfield (Ikame)** | Skip `ikxcodegen`. Run C1 probe on existing project. Append features only. |
| `.xcodeproj` + `Podfile` both present, no `IKCoreApp` | **brownfield (non-Ikame)** | Skip `ikxcodegen`. Run C1 probe. Skill emits non-Ikame variant per `references/swiftui-pro-bridge.md` defaults. |
| Folder has files but no `.xcodeproj` (random asset, README, docs) | **ambiguous** | STOP. Ask user explicitly: *"Tạo project mới ở đây? Có thể overwrite các file đang có"* — do NOT delete or move existing files. |

Detection script — `scripts/mode-detect.sh`:

```bash
#!/usr/bin/env bash
# Emits one of: greenfield | brownfield-ikame | brownfield-vanilla | ambiguous
# Reads stdin: target folder. Writes mode to stdout. Exits 0.

set -euo pipefail
target="${1:-$PWD}"
cd "$target"

has_xcodeproj=$(find . -maxdepth 2 -name '*.xcodeproj' -type d 2>/dev/null | head -1)
has_podfile=$(test -f Podfile && echo yes || echo no)
has_files=$(find . -maxdepth 2 -type f ! -name '.DS_Store' 2>/dev/null | head -1)

if [[ -z "$has_xcodeproj" && "$has_podfile" == "no" ]]; then
  if [[ -z "$has_files" ]]; then
    echo "greenfield"
  else
    echo "ambiguous"
  fi
  exit 0
fi

if [[ -n "$has_xcodeproj" && "$has_podfile" == "yes" ]]; then
  if grep -qE "^\s*pod\s+'IKCoreApp'" Podfile 2>/dev/null; then
    echo "brownfield-ikame"
  else
    echo "brownfield-vanilla"
  fi
  exit 0
fi

# .xcodeproj OR Podfile present but not both — anomalous
echo "ambiguous"
```

The skill's Phase A reads this output and branches the rest of the run. **Banned**: skipping detection or assuming "greenfield because user said create app".

---

## §2. Installation

`ikxcodegen` ships through Mint (Swift CLI distribution). The skill verifies installation; does not auto-install (requires user authorization for `brew` / `mint`).

### Installation steps (one-time, per machine)

```bash
brew install mint
mint install git@gitlab.ikameglobal.com:begamob/ios/shared/cli-macos/ikxcodegen.git
```

### Verification (every run, before mode detection in greenfield path)

```bash
if ! command -v ikxcodegen >/dev/null 2>&1; then
  echo "ikxcodegen not found — install:"
  echo "  brew install mint"
  echo "  mint install git@gitlab.ikameglobal.com:begamob/ios/shared/cli-macos/ikxcodegen.git"
  exit 1
fi
```

The skill does **not** run `brew install mint` itself. If missing, STOP and surface the install commands to the user.

---

## §3. CLI usage

```
USAGE: ikxcodegen <project-name> [--bundle-id <bundle-id>] [--output <output>] [--skip-pods] [--verbose]

ARGUMENTS:
  <project-name>            PascalCase, no spaces. Used as target name + default bundle suffix.

OPTIONS:
  -b, --bundle-id <id>      Full bundle identifier. Default: com.ikameglobal.<ProjectName>
  -o, --output <path>       Output folder. Default: ./<ProjectName>
  --skip-pods               Skip `pod install` after scaffold. Default: pods install runs.
  --verbose                 Verbose log.
  --version                 Print CLI version.
  -h, --help                Print help.
```

### Skill invocation (greenfield path)

**Preferred entry:** call `scripts/ikxcodegen-wrap.sh` instead of `ikxcodegen` directly. The wrapper is a drop-in replacement that auto-fixes three friction points observed in real runs:

1. **CocoaPods + Ruby 4 unicode bug** (`Encoding::CompatibilityError` when `pod install` sees a non-UTF-8 `LANG`). The wrap sets `LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8` in the subshell.
2. **xcconfig files are shipped but not wired (the semantic fix).** ikxcodegen produces `<Project>/Environments/{firebase,appstore}{,-debug}.xcconfig` and adds them as PBXFileReference entries, but the app target's Debug + Release Configurations have `Based on Configuration File: None` — every xcconfig setting (`GOOGLE_SERVICE_INFO_NAME`, custom build flags, archive flags) resolves to empty at build time. **The wrap edits pbxproj to set `baseConfigurationReference`** on each Configuration of the app target (`PBXNativeTarget` whose `name == <ProjectName>`). Defaults match Ikame template's standard layout:
   - Debug Configuration → `firebase-debug.xcconfig` (override via `--debug-xcconfig <file>`)
   - Release Configuration → `appstore.xcconfig` (override via `--release-xcconfig <file>`)

   Test targets (`<Project>Tests`, `<Project>UITests`) are NOT touched — `pod install` wires their `Pods-<Project>Tests.{debug,release}.xcconfig` automatically via CocoaPods. The wrap only owns the app target's Configuration wiring.

3. **`Copy InfoPlist` Run Script fails when `GOOGLE_SERVICE_INFO_NAME` is unset (fallback only).** Used only when (2) fails (xcconfig file missing from project, unexpected pbxproj structure). The wrap patches `buildSettings` directly with `GOOGLE_SERVICE_INFO_NAME = <plist>`. This is a symptom-fix for one variable; (2) is the semantic fix for all xcconfig settings. **When (2) succeeds the wrap explicitly SKIPS (3)** — because `buildSettings` overrides `xcconfig`, applying both would silently break future xcconfig edits (the developer thinks they're editing the source of truth but the buildSetting hijacks the value).

The wrap accepts every flag `ikxcodegen` accepts and adds three extras:

| New flag | Effect |
|---|---|
| `--debug-xcconfig <filename>` | xcconfig file wired into the Debug Configuration's `baseConfigurationReference`. Default `firebase-debug.xcconfig`. Must exist as a PBXFileReference in the generated pbxproj (ikxcodegen ships the standard 4; override only for custom templates). |
| `--release-xcconfig <filename>` | xcconfig file wired into the Release Configuration's `baseConfigurationReference`. Default `appstore.xcconfig`. |
| `--google-plist <filename>` | **Fallback only** — sets `GOOGLE_SERVICE_INFO_NAME` directly in `buildSettings` when xcconfig wire (step 2) fails. Default `GoogleService-Info-Firebase.plist`. Ignored when the wire succeeds. |

Arguments are derived from input:

| Skill input | CLI flag (passes through to `ikxcodegen`) |
|---|---|
| Project name (from user prompt or feature-spec) | positional `<project-name>` (PascalCase coerced) |
| Bundle ID (when user specifies) | `--bundle-id` (else default Ikame bundle prefix) |
| Output folder (always the run's target folder) | `--output <path>` |
| `--skip-pods` | only when offline OR user explicitly requested. Default: pods install. |

```bash
# Recommended — auto-fixes LANG + GOOGLE_SERVICE_INFO_NAME
scripts/ikxcodegen-wrap.sh MyAuthApp \
  --bundle-id com.ikameglobal.myauthapp \
  --output ./MyAuthApp \
  --verbose

# Raw form — only when wrap is unavailable, e.g. a sandboxed shell or the
# wrap script has not been installed yet (re-run scripts/install.sh).
ikxcodegen MyAuthApp \
  --bundle-id com.ikameglobal.myauthapp \
  --output ./MyAuthApp \
  --verbose
```

**When to NOT use the wrap:**
- The project uses a custom Configuration scheme (Staging/Beta/etc. in addition to Debug/Release). The wrap only wires Debug + Release; Staging needs manual wiring after. `ikxcodegen` raw + manual wiring is fine for that case.
- Project doesn't use the Firebase config flow (rare in Ikame).

**Wrap exit codes** (distinct from raw `ikxcodegen`):
- `0` — scaffold + pod install succeeded; xcconfig wired (§3a) OR buildSetting fallback applied (§3b). The final summary line tells you which path.
- `1` — ikxcodegen itself failed
- `2` — pod install failed even with LANG fix → surface verbatim, do NOT retry
- `3` — BOTH §3a (xcconfig wire) AND §3b (buildSetting fallback) failed → surface and ask user; usually means the pbxproj structure diverged from ikxcodegen's standard template
- `64` — bad usage
- `65` — `ikxcodegen` not on PATH (see §2 install)

**Verifying the xcconfig wire after wrap exits:** open `<ProjectName>.xcodeproj` in Xcode → Project → Info → Configurations. Debug should show `firebase-debug.xcconfig` (or whatever `--debug-xcconfig` was set to) under "Based on Configuration File" for the app target row, and Release should show `appstore.xcconfig`. Test targets show `Pods-...debug.xcconfig` / `Pods-...release.xcconfig` (wired by `pod install` independently). If any app-target row shows `None` after the wrap exited 0, the wire silently no-op'd — re-run with `--verbose` and report the §3a output.

After successful exit:
- `<output>/<ProjectName>.xcodeproj` exists
- `<output>/Podfile` exists with `pod 'IKCoreApp'`, `pod 'IKSDK'`, `pod 'IKOnboardingFlow'`, deployment target `'16.0'`
- `<output>/Pods/` populated (`pod install` ran)
- `<output>/<ProjectName>/...` empty-template tree (see §4)

The skill verifies all four after `ikxcodegen` exits; on any missing → STOP with diagnostic.

---

## §4. Output shape (what ikxcodegen produces)

```
<ProjectName>/                               ← workspace root (== --output)
├── <ProjectName>.xcodeproj/
├── <ProjectName>.xcworkspace/               ← created by `pod install`
├── Podfile                                  ← see §5
├── Pods/                                    ← populated by `pod install`
├── Products/
├── <ProjectName>Tests/
├── <ProjectName>UITests/
└── <ProjectName>/                           ← MAIN target folder
    ├── App/
    │   ├── AppDelegate.swift                ← Apple template, modified for IKCoreApp init
    │   ├── SceneDelegate.swift              ← Apple template
    │   ├── Info.plist
    │   └── LaunchScreen.storyboard
    │
    ├── Core/
    │   └── Router/
    │       └── Main/
    │           ├── MainRoute.swift          ← empty enum NavigationItem placeholder
    │           └── MainRouter.swift         ← empty IKRouter conformance
    │
    ├── Environments/
    │   ├── appstore.xcconfig
    │   ├── appstore-debug.xcconfig
    │   ├── firebase.xcconfig
    │   ├── firebase-debug.xcconfig
    │   ├── GoogleService-Info-AppStore.plist
    │   └── GoogleService-Info-Firebase.plist
    │
    ├── Resources/
    │   └── Assets.xcassets                  ← empty asset catalog (with AppIcon + AccentColor)
    │
    ├── Screens/
    │   └── Main/
    │       └── MainScreen.swift             ← empty SwiftUI screen template
    │
    └── Utilities/
        ├── Extensions/
        │   └── View+Ext.swift               ← may be empty
        └── Helpers/
            └── Constants.swift              ← may be empty
```

What this shape implies for the skill:

- **`App/`, `Environments/`, `Resources/Assets.xcassets`, `<ProjectName>.xcodeproj/`, `Podfile`, `Pods/`** — skill **must NOT modify** these except by appending (asset catalog) or extending (router files).
- **`Core/Router/Main/MainRoute.swift` and `MainRouter.swift`** — skill **extends** them with new `NavigationItem` cases and new `makeView(from:)` cases per `references/iknavigation-bridge.md` §5.
- **`Screens/Main/MainScreen.swift`** — skill MAY overwrite with a real first screen, OR leave the template and create the actual entry feature in `Screens/<Feature>/`. The user's feature-spec dictates which.
- **`Utilities/Extensions/`, `Utilities/Helpers/`** — skill appends new files when needed (e.g. `Utilities/Tracking/AppTracking.swift`, `Utilities/Fonts/AppFont.swift`) — these were not created by ikxcodegen and the skill creates them as needed.
- **`Components/`, `Entities/`** — NOT created by ikxcodegen. Skill creates these top-level folders inside `<ProjectName>/<ProjectName>/` when the first reusable component or entity model is needed.

---

## §5. Default Podfile (what ikxcodegen produces)

```ruby
source 'git@gitlab.ikameglobal.com:begamob/ios/sdk/ios-specs.git'
source 'https://github.com/CocoaPods/Specs.git'

target '<ProjectName>' do
  use_frameworks!

  pod 'IKCoreApp'
  pod 'IKSDK'
  pod 'IKOnboardingFlow'

  target '<ProjectName>Tests' do
    inherit! :search_paths
  end

  target '<ProjectName>UITests' do
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
    end
  end
end
```

**Skill rules around Podfile:**

- DO NOT add `pod 'IKNavigation'`, `pod 'IKFont'`, `pod 'IKMacros'`, etc. — they are re-exported by `IKCoreApp`. Adding them as separate lines breaks resolution.
- DO NOT lower `IPHONEOS_DEPLOYMENT_TARGET` below `16.0`.
- DO NOT remove `IKSDK` or `IKOnboardingFlow` even if the feature doesn't use them — Ikame projects depend on their global side effects.
- ADD a new `pod` ONLY when: (a) user explicitly requested a third-party lib that's not in IKCoreApp, AND (b) skill verified the lib is not already a transitive dep of IKCoreApp.
- After any Podfile edit → run `pod install` (skill prompts user; never silent).

---

## §6. Pipeline integration — when the skill calls `ikxcodegen`

Phase ordering for greenfield Ikame app generation:

```
PHASE 0 — PRE-FLIGHT
├─ Run scripts/mode-detect.sh → mode (greenfield | brownfield-* | ambiguous)
├─ If ambiguous → STOP, ask user
├─ If greenfield → confirm with user, then:
│   ├─ Verify ikxcodegen installed
│   ├─ Run ikxcodegen <ProjectName> --output <path>
│   └─ Verify output shape (§4 checklist)
└─ Proceed to Phase A

PHASE A — FETCH (Figma + project audit)
├─ figma-desktop get_metadata + get_design_context (per nodeId)
├─ figma-assets figma_extract_tokens (file-level)
├─ figma-assets figma_build_registry (image inventory)
├─ Run scripts/c1-probe.sh on the (now scaffolded) project
│   └─ Outputs c1-conventions.json with usesIKCoreApp = true
└─ Continue per references/figma-mcp-setup.md and adaptation-workflow.md §0

PHASE B — DESIGN (compose)
├─ B0a Strings extraction → append to default xcstrings (skill creates if missing)
├─ B0b Tokens codegen → append colorsets to Assets.xcassets per D-1002 + emit AppFont/Spacing extensions
├─ B0c Asset export → figma_export_assets_unified rows → Assets.xcassets

PHASE C — IMPLEMENT
├─ C1..C4 per-screen self-checks (see SKILL.md)
├─ C5 capture + side-by-side
├─ C6 asset completeness
├─ C7 no-system-chrome
├─ C8 conventions (incl. ikame-feature-flat layout)
└─ Stop hook: full-tree gate sweep
```

For brownfield-ikame, skip Phase 0 ikxcodegen step; everything else identical.

For brownfield-vanilla, the skill emits non-Ikame variant — see `references/swiftui-pro-bridge.md` defaults; this bridge does not apply.

---

## §7. C1 probe contributions

When `mode == "brownfield-ikame"` OR after `ikxcodegen` ran in greenfield, C1 probe (per `references/adaptation-workflow.md` §0) reads the project state and emits:

```json
{
  "usesIKCoreApp": true,
  "usesIKNavigation": true,
  "usesIKMacros": true,
  "usesIKFont": true,
  "usesIKPopup": true,
  "usesIKFeedback": true,
  "usesIKTracking": true,
  "usesIKLocalized": true,
  "usesIKAssetSymbol": true,

  "screenFolderConvention": "ikame-feature-flat",
  "viewModelPattern": "state-action-route-publisher",
  "observationFlavor": "observable-object",
  "minDeploymentTarget": "16.0",

  "routerName": "MainRouter",
  "navigationItemEnumName": "NavigationItem",
  "navigationItemPath": "Core/Router/Main/MainRoute.swift",
  "viewToRouteWiring": "routePublisher",

  "ikFontEnum": "AppFont",
  "spacingEnum": "Spacing",
  "colorEnum": null,
  "colorReferencePattern": "Color.<symbol>",

  "trackingEnumName": "AppTracking",
  "trackingEnumPath": "Utilities/Tracking/AppTracking.swift",
  "popupConfigurations": [
    ".menuPopup", ".defaultPopup", ".passwordPopup",
    ".authenUndoPopup", ".defaultNavigationPresentFullScreen",
    ".customAppSheetFixedHeight"
  ],
  "toastTypeEnumName": "ToastSceenType",

  "entitiesPath": "Entities",
  "entitiesPrefix": "G",
  "entitiesSources": ["GRDB", "Firebase"],

  "componentsPath": "Components",
  "appConstantsPath": "Utilities/Helpers/Constants.swift",

  "xcstringsPath": "Resources/Localizable.xcstrings",
  "assetCatalogPath": "Resources/Assets.xcassets"
}
```

The new fields above (vs the existing flag table in `references/swiftui-pro-bridge.md` §3):
- `usesIKCoreApp`, `usesIKPopup`, `usesIKFeedback`, `usesIKTracking`, `usesIKLocalized`, `usesIKAssetSymbol`
- `screenFolderConvention = "ikame-feature-flat"` (new value)
- `viewModelPattern = "state-action-route-publisher"` (new value)
- `colorReferencePattern` (new — captures whether project uses `Color.<symbol>` ext, generated symbol, or `Color(hex:)`)
- `navigationItemEnumName`, `navigationItemPath`, `trackingEnumName`, `trackingEnumPath`, `popupConfigurations`, `toastTypeEnumName`, `entitiesPath`, `entitiesPrefix`, `entitiesSources`, `componentsPath`, `appConstantsPath`

`scripts/c1-probe.sh` will be extended to populate these. Existing fields stay backwards-compatible.

---

## §8. Banned shortcuts

The skill must NOT take any of these shortcuts even when they would speed up the run:

| Shortcut | Why banned |
|---|---|
| Generating raw `.xcodeproj` / `Project.yml` for a greenfield Ikame run | Ikame's project shape is owned by `ikxcodegen`. Generating manually drifts from Ikame standard and breaks future `ikxcodegen` upgrades. |
| Generating Podfile from scratch | Same — `ikxcodegen` owns Podfile defaults. |
| Skipping `pod install` to save time on greenfield | Subsequent `xcodebuild` will fail in C5 anyway. Always run pods. |
| Modifying `App/AppDelegate.swift` to wire feature-specific logic | App entry is Ikame-owned; feature wiring goes through `MainRouter`. |
| Adding `import IKNavigation` to a file when `import IKCoreApp` is already present | Redundant — IKCoreApp re-exports. C8 gate catches this. |
| Creating a parallel router (`AuthRouter`, `OnboardingRouter`) without user approval | Default is to extend `MainRouter`. Per-flow routers reserved for explicit modular requests. |
| Lowering deployment target to support older Xcode | iOS 16.0 is the Ikame baseline. Don't negotiate. |
| Calling third-party MCP (e.g. `mcp__figma__*` other than `figma-desktop`/`figma-assets`) when Ikame setup expects the official ones | Detect-and-STOP per `references/figma-mcp-setup.md` and `references/mcpfigma-setup.md`. |

---

## §9. Failure-mode self-check

Before any greenfield run:

1. Did I run `mode-detect.sh` and read its output? (not "I'll assume greenfield")
2. Is `ikxcodegen` installed and on `$PATH`?
3. Did the user explicitly say "create new app" / "tạo app mới" — or did I infer it from absence of `.xcodeproj`?
4. Is the target folder safe to scaffold into (empty or only contains files I'd happily preserve)?
5. After `ikxcodegen` runs, did I verify all 4 §4 outputs (`.xcodeproj`, `Podfile`, `Pods/`, target folder tree)?

If any answer is "no", STOP and surface the issue. Do not proceed with feature generation on top of a half-scaffolded project.

Before any brownfield-ikame run:

1. Did `mode-detect.sh` confirm `brownfield-ikame`?
2. Did C1 probe confirm `usesIKCoreApp == true` AND populate all the §7 fields?
3. Are `MainRouter`, `NavigationItem`, `AppTracking`, `Color.<symbol>` extension all locatable in the project? (If any missing, the project may be partial-Ikame — STOP and ask the user.)

If any answer is "no" → escalate to the user. Skill does not paper over a misconfigured project.
