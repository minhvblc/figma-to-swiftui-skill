# Project Structure & File Naming

How `figma-to-swiftui` lays generated files into the target iOS project. Hard rules — enforced by `scripts/c8-conventions-gate.sh`.

**Canonical source for Ikame projects: `ikame-ios-coding/references/project-structure.md` and `references/ikame-decision-table.md` §3 (D-201..D-219).** This file mirrors those locked values for the canonical one-folder-per-screen layout (§2), keeps the brownfield feature-flat layout for legacy projects (§3), and documents naming + C8 gates.

These rules apply per the convention C1 probe detects (`c1-conventions.json.screenFolderConvention`). Three modes:
- `"one-screen-per-folder"` — **canonical Ikame layout** (matches ios-coding-skill) AND non-Ikame projects that already use it.
- `"ikame-feature-flat"` — brownfield Ikame (notably authenv2) where `Screens/<Feature>/<Feature>HomeScreen.swift` is the existing pattern.
- `"flat"` — single-file / library / scratch.

When the convention is `flat`, this gate becomes informational — the skill emits one file per screen at the user-requested path and respects the project's existing suffix convention (§4 naming still applies to NEW types).

---

## §1. Detection (C1 audit)

C1 sets `c1-conventions.json.screenFolderConvention` by inspecting the project tree:

| Signal | Value |
|---|---|
| Existing `Screens/<X>Screen/<X>Screen.swift` pattern for ≥ 2 X (regardless of whether IKCoreApp is present) | `"one-screen-per-folder"` |
| Fresh ikxcodegen-scaffolded project (initial `Screens/Main/MainScreen.swift` only, no feature folders yet) AND Podfile contains `pod 'IKCoreApp'` | `"one-screen-per-folder"` (canonical for new screens) |
| Existing `Screens/<Feature>/<Feature>HomeScreen.swift` + `Screens/<Feature>/ViewModel/` pattern for ≥ 2 features (legacy authenv2-style) | `"ikame-feature-flat"` |
| `Sources/<Module>/Views/*.swift` flat | `"flat"` |
| `App/Views/Home/HomeView.swift` (no `-Screen` suffix anywhere — full-screen views named with `-View`) | `"flat"` |
| Mixed — some screens follow one shape, some another | majority signal wins; apply detected convention to NEW files only; existing files left as-is unless user says align |

**Canonical Ikame layout is `one-screen-per-folder`** (per `ikame-ios-coding/references/project-structure.md`). The `ikame-feature-flat` value is brownfield-only — applies to existing projects already structured that way. **Do NOT introduce `ikame-feature-flat` into a project that doesn't already have it**, even when the project uses IKCoreApp.

If `one-screen-per-folder`: rules in §2 apply, supplementing with `references/ikame-decision-table.md` for shape-of-code decisions.
If `ikame-feature-flat`: rules in §3 apply — brownfield only.
If `flat`: skill emits one file per screen at a path the user requests, AND respects whatever suffix the project already uses (`-View` if the project uses `HomeView` for full screens; `-Screen` if it uses `HomeScreen`). §4 naming applies to NEW types regardless.

---

## §2. Folder layout — `one-screen-per-folder` (canonical, both Ikame and non-Ikame)

Generated output goes into a layout where each screen owns its own folder under `Screens/`. This is the canonical Ikame layout per `ikame-ios-coding/references/project-structure.md` and also fits non-Ikame SwiftUI projects.

```
<ProjectName>/<ProjectName>/                  ← target root (created by ikxcodegen for Ikame)
│
├── App/                                      ← UIKit lifecycle entry — DO NOT MODIFY (skill never edits)
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   └── Info.plist
│
├── Core/                                     ← architectural foundation
│   ├── Router/                               ← ONE SUBFOLDER PER FEATURE ROUTER (not flat)
│   │   ├── Main/
│   │   │   ├── MainRoute.swift               ← <Feature>Route enum + IKRouteID ext helper
│   │   │   └── MainRouter.swift              ← IKRouter impl with mandatory else { EmptyView() }
│   │   ├── Auth/                             ← created when Auth feature router lands
│   │   │   ├── AuthRoute.swift
│   │   │   └── AuthRouter.swift
│   │   └── …                                 ← compose at app start with `+`
│   ├── Network/                              ← created on first repository / API call
│   │   ├── API.swift                         ← enum API registry (all repositories exposed here)
│   │   └── Repositories/
│   │       └── <Domain>Repository.swift      ← @APIProtocol-annotated; macro generates Impl
│   ├── Database/                             ← created on first DB use
│   ├── Sync/                                 ← created on first sync feature
│   └── DI/                                   ← created on first DI graph
│
├── Entities/                                 ← APP-WIDE MODELS — created on first promotion (not in initial scaffold)
│   └── <Prefix><Domain>Model.swift           ← prefix is project-specific (may be empty); group by source if project does
│
├── Components/                               ← REUSABLE across ≥2 screens — created on first promotion (not in initial scaffold)
│   ├── <Name>View.swift                      ← prefix DROPPED on promotion (e.g. ArticleRowView, not HomeArticleRowView)
│   ├── <Name>View/                           ← folder when component is multi-file
│   └── App<Name>View.swift                   ← App prefix reserved for project-wide infrastructural components (e.g. AppPopupView)
│
├── Screens/                                  ← ONE FOLDER PER SCREEN
│   └── <ScreenName>/                         ← e.g. Home/, Login/, ArticleDetail/
│       ├── <ScreenName>Screen.swift          ← the screen View
│       ├── <ScreenName>ViewModel.swift       ← co-located with the screen (NOT in a ViewModel/ subfolder)
│       ├── <ScreenName>Screen+<Topic>.swift  ← extension files when screen > ~250 lines (rare — prefer subview extraction)
│       ├── Subviews/                         ← per-screen extracted subviews
│       │   ├── <ScreenName><Role>View.swift  ← prefix = screen name; suffix `View`
│       │   └── <ScreenName><Role>View/       ← folder when subview is multi-file
│       ├── SubViewModels/                    ← rare; ONLY when a SubView has its own VM
│       │   └── <ScreenName><Role>ViewModel.swift
│       ├── Models/                           ← screen-local model types (promote to Entities when shared)
│       │   └── <ScreenName><Name>.swift
│       └── Enums/                            ← screen-local enums
│           └── <ScreenName><Name>.swift
│
├── Resources/
│   ├── Assets.xcassets                       ← single catalog; skill appends only
│   │   ├── Colors/                           ← named colorsets (dual-mode) + color<HEX>.colorset for one-off Figma hex
│   │   └── <Image assets>                    ← Image(.icXxx) generated symbols (GENERATE_ASSET_SYMBOLS = YES)
│   ├── Fonts/                                ← .ttf/.otf for additional font families (per ios-coding-skill fonts-and-styling)
│   └── Localizable.xcstrings                 ← string catalog (when localization enabled)
│
├── Environments/                             ← xcconfig + GoogleService — DO NOT MODIFY (not in target)
│
└── Utilities/
    ├── Constants.swift                       ← AppConstants (extend)
    ├── Extensions/                           ← <Type>+Ext.swift — append only; <Family>+Ext.swift for additional font families
    ├── Helpers/                              ← shared helpers (date formatters, validators)
    ├── Tracking/                             ← AppTracking.swift (Ikame projects with IKTracking)
    └── Fonts/                                ← register IKFontSystem; per-family wrappers go in Extensions/
```

**Notably absent from the initial ikxcodegen scaffold:** `Components/`, `Entities/`, `Core/Network/`. Don't create them preemptively — they appear only when there's an actual shared component, domain model, or first API call.

### Where each kind of artifact lives (`one-screen-per-folder`):

| Artifact | Location | Decision ID |
|---|---|---|
| Screen file | `Screens/<ScreenName>/<ScreenName>Screen.swift` | D-202 |
| Screen extension (when file > ~250 lines) | `Screens/<ScreenName>/<ScreenName>Screen+<Topic>.swift` | D-203 |
| ViewModel | `Screens/<ScreenName>/<ScreenName>ViewModel.swift` (co-located, NO `ViewModel/` subfolder) | D-207 |
| Subview > 50 lines or with `@State` | `Screens/<ScreenName>/Subviews/<ScreenName><Role>View.swift` | D-204, D-205 |
| Subview ≤ 50 lines, no own state | inline `@ViewBuilder` computed property in the screen file | — |
| Subview that itself splits into multiple files | `Screens/<ScreenName>/Subviews/<ScreenName><Role>View/` folder | D-206 |
| Sub-ViewModel (rare — for a stateful SubView with its own VM) | `Screens/<ScreenName>/SubViewModels/<ScreenName><Role>ViewModel.swift` | D-208 |
| Screen-only model | `Screens/<ScreenName>/Models/<ScreenName><Name>.swift` | D-209 |
| Screen-only enum | `Screens/<ScreenName>/Enums/<ScreenName><Name>.swift` | D-210 |
| Reusable component (≥ 2 screens) | `Components/<Name>View.swift` — prefix dropped on promotion | D-211 |
| Reusable multi-file component | `Components/<Name>View/` folder | D-212 |
| App-wide model | `Entities/<Prefix><Domain>Model.swift` (or `Entities/<Source>/<Prefix><Domain>Model.swift`) | D-213 |
| API repository protocol | `Core/Network/Repositories/<Domain>Repository.swift` | D-214 |
| API registry | `Core/Network/API.swift` (`enum API` with `static var <name>Repository`) | D-215 |
| Database / persistence | `Core/Database/<Name>.swift` (created on demand) | D-216 |
| Sync service | `Core/Sync/<Name>.swift` (created on demand) | D-217 |
| Per-feature router | `Core/Router/<Feature>/<Feature>{Route,Router}.swift` — extend matching feature when adding routes; compose with `+` | D-218 |
| Color asset (named token, dual-mode) | `Resources/Assets.xcassets/Colors/<swiftName>.colorset` | D-1001 |
| Color asset (one-off Figma hex) | `Resources/Assets.xcassets/Colors/color<HEX>.colorset` | D-1002 |
| Image asset | `Resources/Assets.xcassets/<name>.imageset` | D-901 |
| Additional font family helper (4-layer) | `Utilities/Extensions/<Family>+Ext.swift` | D-1106 |
| Tracking enum | `Utilities/Tracking/AppTracking.swift` (extend) | D-704 |
| App constants | `Utilities/Constants.swift` (extend) | D-1304 |

For the full set of shape-of-code decisions in this layout (state, navigation, popup, feedback, tracking, etc.), see **`references/ikame-decision-table.md`** — it locks every pattern with a stable D-ID, mirroring `ikame-ios-coding/references/<topic>.md`.

---

## §3. Folder layout — `ikame-feature-flat` (brownfield only — legacy Ikame projects)

For older Ikame projects (notably authenv2) that already organize by feature folder with multiple screens per feature. C1 detects this by finding `Screens/<Feature>/<Feature>HomeScreen.swift` + `Screens/<Feature>/ViewModel/` patterns. **Do NOT introduce this layout into a new project** — canonical Ikame is `one-screen-per-folder` (§2).

```
<ProjectName>/<ProjectName>/                  ← target root (created by ikxcodegen)
│
├── App/                                      ← entry point — DO NOT MODIFY (skill never edits)
├── Core/
│   ├── Router/Main/                          ← single MainRouter (brownfield often keeps one flat NavigationItem enum)
│   │   ├── MainRoute.swift
│   │   └── MainRouter.swift
│   ├── Services/                             ← app-wide API services
│   ├── Database/
│   └── Sync/
│
├── Entities/<Source>/<Prefix><Domain>Model.swift
├── Components/{App<Name>View, <DomainSpecific>View}.swift
│
├── Screens/                                  ← FEATURE FOLDERS (not screen folders)
│   └── <Feature>/                            ← e.g. Codes/, Onboarding/, Splash/, IAP/
│       ├── <Feature>HomeScreen.swift         ← entry screen of the feature
│       ├── <Feature>HomeScreen+<Topic>.swift ← extension files when screen > 250 lines
│       ├── <Feature><Action>Screen.swift     ← additional screens belonging to this feature
│       ├── ViewModel/                        ← VM + Repository + Service for the feature
│       │   ├── <Feature>HomeViewModel.swift
│       │   ├── <Feature>HomeRepository.swift ← optional, when feature has data layer
│       │   └── <Feature><Topic>Service.swift ← optional, feature-local services
│       ├── Subviews/
│       │   ├── <Feature>Home<Role>View.swift
│       │   └── <Feature>Home<Role>View/      ← folder when subview is multi-file
│       └── Models/                           ← flow-only models (rare; promote to Entities when shared)
│
├── Resources/Assets.xcassets
├── Environments/
└── Utilities/{Extensions, Tracking, Helpers, Fonts}
```

### Where each kind of artifact lives (`ikame-feature-flat`):

| Artifact | Location |
|---|---|
| Main feature screen | `Screens/<Feature>/<Feature>HomeScreen.swift` |
| Additional feature screen | `Screens/<Feature>/<Feature><Action>Screen.swift` |
| Screen extension | `Screens/<Feature>/<Feature>HomeScreen+<Topic>.swift` |
| Feature ViewModel | `Screens/<Feature>/ViewModel/<Feature>HomeViewModel.swift` |
| Feature Repository | `Screens/<Feature>/ViewModel/<Feature>HomeRepository.swift` |
| Feature Service | `Screens/<Feature>/ViewModel/<Feature><Topic>Service.swift` |
| Subview > 50 lines or with `@State` | `Screens/<Feature>/Subviews/<Feature>Home<Role>View.swift` |
| Flow-only model | `Screens/<Feature>/Models/<Name>.swift` |
| Router | `Core/Router/Main/{MainRoute,MainRouter}.swift` (single router, extend) |
| Tracking, fonts, etc. | same as §2 |

**When skill is editing a brownfield ikame-feature-flat project:** match the existing flat-feature shape. Do not refactor to one-folder-per-screen unless user explicitly requests. **When skill is adding a new feature to a brownfield project:** ask the user first whether to follow the legacy feature-flat shape or kick off the canonical layout for the new feature only — mixing is OK if the user okays it.

---

## §4. File / type naming (universal — applies in all 3 modes)

The single most important distinction:

- **Parent View = the full-screen view** that fills the device frame, owns a ViewModel, and represents one entry in the navigation graph → suffix **`-Screen`**.
- **Subview = anything composed inside a parent view** (header, row, card, badge, footer section, modal sheet body) → suffix **`-View`**.

Both are SwiftUI `struct ...: View`. The suffix tells the reader which one it is.

| Concept | Suffix | Case | Example (one-screen-per-folder, canonical) | Example (ikame-feature-flat, brownfield) |
|---|---|---|---|---|
| Parent View (full screen) | `-Screen` | PascalCase | `OnboardingScreen`, `HomeScreen`, `ArticleListScreen` | `CodesHomeScreen`, `Edit2FACodeScreen`, `ScanCodeScreen` |
| Subview (composed inside a screen) | `-View` | PascalCase | `OnboardingProgressView`, `HomeArticleRowView` | `CodesHomeHeaderView`, `CodesHomeEmptyView`, `CodesHomeAddCodeSuccessView` |
| ViewModel (1 per screen) | `-ViewModel` | PascalCase | `OnboardingViewModel`, `HomeViewModel` | `CodesHomeViewModel` |
| Sub-ViewModel (for a complex subview) | `-ViewModel` | PascalCase | `OnboardingProgressViewModel` | rare; usually parent VM owns subview state |
| Reusable component (≥ 2 screens / features) | `-View` | PascalCase | `Components/ArticleRowView.swift` (prefix dropped on promotion) | `Components/AppPopupView.swift`, `Components/CTAButton.swift` |
| Protocol | `-able` or domain-specific | PascalCase | `Fetchable`, `ArticleRepository` | same |
| Type extension file | `+Ext` | `<Type>+Ext.swift` | `String+Ext.swift`, `View+Ext.swift` | same |
| Type extension by feature | `+<Feature>Ext` | `<Type>+<Feature>Ext.swift` | `Date+FormatExt.swift` | same |
| Additional font family helper | `+Ext` | `<Family>+Ext.swift` | `FiraCode+Ext.swift` (per ios-coding-skill 4-layer pattern) | same |

**Banned naming patterns:**
- `HomeView.swift` for a full-screen view → use `HomeScreen.swift` (`-Screen` suffix is reserved for parent views).
- `OnboardingHeaderScreen.swift` for a subview component → use `OnboardingHeaderView.swift` (`-Screen` is reserved for full screens).
- `Home.swift` (no suffix) for either → choose `HomeScreen.swift` or `HomeView.swift` per the table.

`scripts/c8-conventions-gate.sh` checks the filename ↔ declared-type agreement (a `*Screen.swift` file declares a `*Screen` type; a `*View.swift` file declares a `*View` struct), but does NOT detect "this `HomeView` is actually a full-screen view, should be `HomeScreen`" — that decision belongs to the agent at C2 and is documented here so the agent makes it correctly.

### Subview prefix rule (per convention)

| Mode | Prefix rule |
|---|---|
| `one-screen-per-folder` | Prefix = parent screen name with `Screen` suffix stripped. Folder `Screens/Onboarding/` → subview prefix `Onboarding`. |
| `ikame-feature-flat` (brownfield) | Prefix = parent screen base name (typically `<Feature>Home`). Folder `Screens/Codes/Subviews/` → file prefix `CodesHome`. The prefix is more specific so subviews of `CodesHomeScreen` and `CodesEditScreen` don't collide. |
| `flat` | No enforced prefix — match project's existing convention. |

```
# one-screen-per-folder (canonical)
Screens/Onboarding/Subviews/OnboardingProgressView.swift          ✓
Screens/Onboarding/Subviews/OnboardingHeaderView.swift            ✓
Screens/Onboarding/Subviews/ProgressView.swift                    ✗  (no prefix; collides with SwiftUI ProgressView)
Screens/Onboarding/Subviews/OnboardingScreen.swift                ✗  (subviews use `-View` not `-Screen`)
Screens/Onboarding/Models/Step.swift                              ✗  (no prefix; promote to Entities or rename OnboardingStep)
Screens/Onboarding/Models/OnboardingStep.swift                    ✓

# ikame-feature-flat (brownfield)
Screens/Codes/Subviews/CodesHomeHeaderView.swift                  ✓
Screens/Codes/Subviews/CodesHomeAddCodeSuccessView.swift          ✓
Screens/Codes/Subviews/HeaderView.swift                           ✗  (no feature-screen prefix)
Screens/Codes/Subviews/CodesHomeListView/                         ✓  (folder when subview is multi-file)
Screens/Codes/Models/Step.swift                                   ✗  (no prefix; promote to Entities or rename CodesStep)
Screens/Codes/Models/CodesStep.swift                              ✓
```

The prefix exists so a reader scanning `Subviews/` knows which screen owns a file without opening it, and to avoid collisions with framework types or other features' subviews.

**Exception — nested type.** A model nested inside a screen view or its ViewModel does NOT need the prefix (its scope is already the parent type):

```swift
// ✓ Nested — no prefix needed
struct CodesHomeScreen: View {
    enum CodesHomeState { case normal, edit, empty }
    enum RetryAction { case scanQRCode, uploadFromLibrary, uploadFromFile }
}

// ✗ Standalone in Models/RetryAction.swift — must be CodesHomeRetryAction
```

---

## §5. Promotion rules

When a model or view originally scoped to one screen / feature needs to be reused, **promote it before the second consumer lands** — never let the second consumer import from the first feature's folder.

| Mode | From | To | Action |
|---|---|---|---|
| one-screen-per-folder | `Screens/Home/Subviews/HomeArticleRowView.swift` | `Components/ArticleRowView.swift` | Move file, drop prefix, update all references. |
| one-screen-per-folder | `Screens/Home/Models/HomeSection.swift` | `Entities/Section.swift` | Move file, drop prefix, update all references. |
| ikame-feature-flat (brownfield) | `Screens/Codes/Subviews/CodesHomeAddCodeSuccessView.swift` | `Components/AppAddCodeSuccessView.swift` | Move file, drop feature prefix, **add `App` prefix** when cross-cutting infrastructural, update references. |
| ikame-feature-flat (brownfield) | `Screens/Codes/Models/CodesStep.swift` | `Entities/<Source>/G<Domain>Model.swift` | Move file to appropriate `<Source>` bucket, change to project's entity prefix, update references. |

**Skill rule**: when the agent generates a feature flow (`figma-flow-to-swiftui-feature`) and a component is referenced by ≥ 2 screens or features in the screen graph, emit it in `Components/` (or `Entities/`) FROM THE START — do not place it inside one feature's folder and then move it.

For Ikame projects, see `references/ikame-decision-table.md` §16 — subagents must escalate via delta-request when a new `Components/` or `Entities/` member is needed, rather than creating it locally first.

---

## §6. Naming verbs (function names)

Action handler functions should start with a domain-specific verb. C8-vm-pattern.sh treats these as informational, not hard fail, but the convention is:

| Prefix | Use for | Generic example | Ikame example |
|---|---|---|---|
| `didTap...` | tap action handler | `didTapLoginButton()` | rare in Ikame; prefer reducer-driven handlers |
| `action...` | top-level handler triggered by route | — | `actionShowCameraView()`, `actionUploadFromLibrary()` |
| `show...` | UI presentation (popup, sheet, modal) | `showLoginAlert()` | `showPopupConfirmDeleteOTP(objectIds:)`, `showRenameFolderPopup(...)` |
| `fetch...` | data retrieval | `fetchUserProfile()` | `fetchOTPs()` |
| `load...` | initial-load variant of fetch | `loadDashboard()` | `loadCodes()` |
| `process...` | data processing | `processPayment()` | `processCodeFromString(_:)` |
| `setup...` | one-time setup | `setupNavigationBar()` | `setupView()` |
| `handle...` | event/response handler | `handleResponse(_:)` | `handleNavigation(to:)` |
| `validate...` | data validation | `validateEmail(_:)` | same |
| `configure...` | configure UI/data | `configureCell(_:)` | same |
| `bind...` | data binding setup | `bindData(to:)` | rare in Ikame; reducer pattern instead |
| `convert...` | type conversion | `convertToDisplayFormat(_:)` | same |
| `make...` | factory | `makeIterator()` | same |
| `onNavigation(to:)` | route handler in extension | — | `func onNavigation(to route: VM.Route) { ... }` (Ikame canonical) |

**Side effect convention (Swift API design):** mutating verbs are imperative (`sort()`, `append()`); non-mutating are nouns or `-ed/-ing` (`sorted()`, `reversed()`, `successor`). Pair them as `sort()`/`sorted()`, never just one.

---

## §7. C8-conventions-gate enforcement

`scripts/c8-conventions-gate.sh` runs at the end of Step C4 (after copy assets) and checks, for every Swift file generated by this run, branched on `screenFolderConvention`:

### When `screenFolderConvention == "one-screen-per-folder"` (canonical)

1. **Screen file location.** Type ending in `Screen` is at `Screens/<ScreenName>/<ScreenName>Screen.swift`.
2. **ViewModel placement.** Type ending in `ViewModel` is co-located: `Screens/<ScreenName>/<ScreenName>ViewModel.swift`. NOT in a `ViewModel/` subfolder (that's the brownfield feature-flat convention).
3. **Subview prefix.** Files in `Screens/<ScreenName>/Subviews/`, `SubViewModels/`, `Models/`, `Enums/` start with `<ScreenName>` (folder `Onboarding/` → files start with `Onboarding`).
4. **Suffix match.** Type and file basename agree on suffix: `*Screen.swift` declares a `*Screen` type; `*ViewModel.swift` declares a `*ViewModel` class; `*View.swift` declares a `*View` struct.
5. **Extension file naming.** A file at `Utilities/Extensions/*.swift` matches `<Type>+Ext.swift` or `<Type>+<Feature>Ext.swift`; `<Family>+Ext.swift` is valid for additional font family helpers.
6. **Per-feature router.** New routes land in the matching `Core/Router/<Feature>/<Feature>Route.swift` + `<Feature>Router.swift` pair. No parallel feature routers created without explicit user authorization (see `references/iknavigation-bridge.md` §5).
7. **No subagent writes to shared paths.** When run is part of a multi-screen orchestration (subagent), files outside `Screens/<assigned-screen>/` fail unless they are explicit delta-request resolutions — see `references/ikame-decision-table.md` §16.

### When `screenFolderConvention == "ikame-feature-flat"` (brownfield)

1. **Screen file location.** Type ending in `Screen` is at `Screens/<Feature>/<Name>Screen.swift` (any depth ≤ 2 inside `Screens/`).
2. **ViewModel placement.** Type ending in `ViewModel` is at `Screens/<Feature>/ViewModel/<Name>ViewModel.swift`.
3. **Subview prefix.** Files in `Screens/<Feature>/Subviews/` start with the parent screen's base name (e.g. `CodesHome*View.swift` for the `Codes` feature whose entry screen is `CodesHomeScreen`).
4. **Suffix match.** Same as canonical.
5. **Extension file naming.** Same as canonical.
6. **Router.** Routes go through the single existing `Core/Router/Main/MainRouter.swift` — don't split into per-feature routers in this layout.
7. **No subagent writes to shared paths.** Same as canonical, scoped to `Screens/<assigned-feature>/`.

### When `screenFolderConvention == "flat"`

The gate prints `GATE: SKIP (flat layout)` and exits 0. §4 naming rules still apply via inline grep checks in C3 Pass 1.

Output (all branches): `GATE: PASS` or `GATE: FAIL: <reason>` — exit code matches.

---

## §8. Registering generated files in `.xcodeproj`

After Phase C writes Swift / asset files to disk, Xcode needs to see them as members of the target. Two cases — driven by the project's `.xcodeproj` shape, NOT by the skill:

### Xcode 16+ synchronized folders (default for ikxcodegen output)

Modern projects use `PBXFileSystemSynchronizedRootGroup`. Files placed on disk under the target's source folder are **auto-included** in the target by Xcode — no `pbxproj` edit needed. The skill writes files via `Write` / `Edit` and Xcode picks them up on next open / build.

Detection: grep `pbxproj` for `PBXFileSystemSynchronizedRootGroup`. Present → skip §8 entirely.

### Pre-Xcode-16 projects (PBXGroup-style file lists)

Legacy projects use explicit file references inside `PBXGroup` and `PBXSourcesBuildPhase`. Writing a `.swift` file to disk does NOT add it to the build — the project file must be edited too. For these projects the skill calls `scripts/xcodeproj-add-files.sh`:

```bash
scripts/xcodeproj-add-files.sh \
  --project   <abs-path>/<Name>.xcodeproj \
  --target    <TargetName> \
  --files     "<space-separated absolute paths to new Swift / asset files>" \
  [--src-root <abs-path-to-target-src-folder>] \
  [--dry-run]
```

The script uses the Ruby `xcodeproj` gem (1.27+, bundled with CocoaPods or installed via `gem install --user-install xcodeproj`). It:

1. Auto-detects synchronized-folder mode and exits as no-op (idempotent).
2. Else derives group hierarchy from `<file path> - <src-root>` so the new file lands in the right group tree.
3. Routes by extension:
   - `*.swift` → `PBXSourcesBuildPhase`
   - `*.xcassets`, `*.bundle` → `PBXResourcesBuildPhase` (folder reference)
   - `*.plist`, `*.xcconfig`, `*.json`, `*.md`, `*.yaml` → file reference only, no build phase

**Exit codes:**
- `0` — all files added (or already present — script is idempotent)
- `1` — Ruby gem missing AND auto-install failed → surface to user
- `64` — bad usage
- `65` — project / target not found

**When the skill calls this script:**

- After `Phase C4 — Copy Assets to Project` AND the project's `pbxproj` lacks `PBXFileSystemSynchronizedRootGroup`. Surface `--dry-run` output to user once before applying for the first time per session.
- Greenfield via `ikxcodegen` → the produced project is Xcode 16+ synchronized → script is a no-op. Run anyway as a sanity confirmation.
- Brownfield Ikame on an older project (Xcode 14 / 15 import) → script does the real work.
- Vanilla SwiftUI projects post-Xcode 16 → typically no-op.

**Banned:** hand-editing `pbxproj` to add file references. The format is fragile (UUID stability, build-phase ordering, group nesting); use the script. If the script fails on a project the user maintains by hand, surface the failure and ask — do NOT improvise a `sed` patch.
