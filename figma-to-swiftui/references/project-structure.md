# Project Structure & File Naming

How `figma-to-swiftui` lays generated files into the target iOS project. Hard rules — enforced by `scripts/c8-conventions-gate.sh`.

These rules apply per the convention C1 probe detects (`c1-conventions.json.screenFolderConvention`). Three modes: `ikame-feature-flat` (Ikame projects, primary), `screen-based` (generic SwiftUI per-screen folder), `flat` (single-file / library / scratch).

When the convention is `flat`, this gate becomes informational — the skill emits one file per screen at the user-requested path and respects the project's existing suffix convention (§4 naming still applies to NEW types).

---

## §1. Detection (C1 audit)

C1 sets `c1-conventions.json.screenFolderConvention` by inspecting the project tree:

| Signal | Value |
|---|---|
| Podfile contains `pod 'IKCoreApp'` OR any `.swift` file imports `IKCoreApp` | `"ikame-feature-flat"` |
| `Screens/<X>Screen/<X>Screen.swift` exists for at least 2 X (and no IKCoreApp signal) | `"screen-based"` |
| `Sources/<Module>/Views/*.swift` flat | `"flat"` |
| `App/Views/Home/HomeView.swift` (no `-Screen` suffix anywhere — full-screen views named with `-View`) | `"flat"` |
| Mixed — some screens follow, some don't | majority signal wins; apply detected convention to NEW files only; existing files left as-is unless user says align |

The Ikame signal **takes precedence** over the screen-based signal. An Ikame project that happens to already have screens following `Screens/<X>Screen/<X>Screen.swift` shape is rare (Ikame standardizes on feature folder), but if it occurs, treat as `ikame-feature-flat` and align new screens to feature-folder shape; do not refactor existing files unless user requests.

If `ikame-feature-flat`: rules in §2 apply, supplementing with `references/ikame-decision-table.md` for shape-of-code decisions.
If `screen-based`: rules in §3 apply.
If `flat`: skill emits one file per screen at a path the user requests, AND respects whatever suffix the project already uses (`-View` if the project uses `HomeView` for full screens; `-Screen` if it uses `HomeScreen`). §4 naming applies to NEW types regardless.

---

## §2. Folder layout — `ikame-feature-flat` (primary, when detected)

Generated output goes into a feature-folder layout (one folder per **feature**, multiple screens per feature). This matches the layout `ikxcodegen` produces and what authenv2 (the canonical Ikame project) uses.

```
<ProjectName>/<ProjectName>/                  ← target root (created by ikxcodegen)
│
├── App/                                      ← entry point — DO NOT MODIFY (skill never edits)
│   ├── AppDelegate.swift
│   ├── SceneDelegate.swift
│   ├── Info.plist
│   └── LaunchScreen.storyboard
│
├── Core/                                     ← architectural foundation
│   ├── Router/Main/
│   │   ├── MainRoute.swift                   ← extend NavigationItem enum here
│   │   └── MainRouter.swift                  ← extend makeView(from:) switch here
│   ├── Services/                             ← API service classes (app-wide)
│   ├── Database/                             ← DB setup, GRDB, persistence services
│   ├── Sync/                                 ← local↔cloud sync logic
│   └── AppLock/                              ← app-level lock features
│
├── Entities/                                 ← APP-WIDE MODELS (sibling to Core)
│   └── <Source>/                             ← per-source bucket (GRDB, Firebase, ...)
│       └── <Prefix><Domain>Model.swift       ← prefix is project-specific (may be empty)
│                                             ← authenv2 example: GRDB/GROTPModel.swift, GRDB/GFolderModel.swift
│
├── Components/                               ← REUSABLE across ≥2 features
│   ├── App<Name>View.swift                   ← prefix App for cross-cutting reusable
│   ├── <DomainSpecific>View.swift            ← e.g. CTAButton, OTPRow, MenuPopupView
│   ├── <Name>View/                           ← folder when component is multi-file
│   └── <Name>Utils.swift                     ← e.g. AppUtils, IAPUtils
│
├── Screens/                                  ← FEATURE FOLDERS (NOT screen folders)
│   └── <Feature>/                            ← e.g. Codes/, Onboarding/, Splash/, IAP/
│       ├── <Feature>HomeScreen.swift         ← entry screen of the feature
│       ├── <Feature>HomeScreen+<Topic>.swift ← extension files when screen > 250 lines
│       ├── <Feature><Action>Screen.swift     ← additional screens belonging to this feature
│       ├── ViewModel/                        ← VM + Repository + Service for the feature
│       │   ├── <Feature>HomeViewModel.swift
│       │   ├── <Feature>HomeRepository.swift ← optional, when feature has data layer
│       │   └── <Feature><Topic>Service.swift ← optional, feature-local services
│       ├── Subviews/                         ← per-feature subviews (NOT shared)
│       │   ├── <Feature>Home<Role>View.swift
│       │   └── <Feature>Home<Role>View/      ← folder when subview is multi-file
│       └── Models/                           ← flow-only models (rare; promote to Entities when shared)
│           └── <Name>.swift
│
├── Resources/
│   └── Assets.xcassets                       ← single catalog; skill appends only
│       ├── Colors/                           ← color<HEX> + semantic names
│       └── <Image assets>                    ← Image(.icXxx) generated symbols
│
├── Environments/                             ← xcconfig + GoogleService — DO NOT MODIFY
│
└── Utilities/
    ├── Extensions/                           ← <Type>+Ext.swift — append only
    ├── Tracking/                             ← AppTracking.swift, AppTrackingFeature.swift
    ├── Helpers/                              ← Constants.swift (AppConstants), shared helpers
    └── Fonts/                                ← font register, AppFont enum
```

### Where each kind of artifact lives (`ikame-feature-flat`):

| Artifact | Location | Decision ID |
|---|---|---|
| Main feature screen | `Screens/<Feature>/<Feature>HomeScreen.swift` | D-202 |
| Additional feature screen | `Screens/<Feature>/<Feature><Action>Screen.swift` | D-202 |
| Screen extension (split when > 250 lines) | `Screens/<Feature>/<Feature>HomeScreen+<Topic>.swift` | D-203 |
| Feature ViewModel | `Screens/<Feature>/ViewModel/<Feature>HomeViewModel.swift` | D-208 |
| Feature Repository | `Screens/<Feature>/ViewModel/<Feature>HomeRepository.swift` | D-209 |
| Feature Service | `Screens/<Feature>/ViewModel/<Feature><Topic>Service.swift` | D-210 |
| Subview ≤ 50 lines, no own state | inline `@ViewBuilder` computed property in the screen file (or its extension file) | — |
| Subview > 50 lines OR owns `@State` | extract to `Screens/<Feature>/Subviews/<Feature>Home<Role>View.swift` | D-204, D-205 |
| Subview that itself splits into multiple files | folder `Screens/<Feature>/Subviews/<Feature>Home<Role>View/` | D-206 |
| Flow-only model (used in 1 feature) | `Screens/<Feature>/Models/<Name>.swift` | D-211 |
| App-wide model | `Entities/<Source>/<Prefix><Domain>Model.swift` | D-214 |
| Reusable component (≥ 2 features) | `Components/App<Name>View.swift` (App prefix when cross-cutting) or `Components/<Name>View.swift` | D-212 |
| Reusable multi-file component | `Components/<Name>View/` folder | D-213 |
| API service (app-wide) | `Core/Services/<Name>Service.swift` | D-215 |
| Database service / persistence | `Core/Database/<Name>.swift` | D-216 |
| Sync service | `Core/Sync/<Name>.swift` | D-217 |
| Router / route enum | `Core/Router/Main/Main{Route,Router}.swift` (extend, never replace) | D-218 |
| Color asset | `Resources/Assets.xcassets/Colors/color<HEX>.colorset` (or semantic name when matched) | D-1002 |
| Image asset | `Resources/Assets.xcassets/<name>.imageset` | D-901 |
| Tracking enum | `Utilities/Tracking/AppTracking.swift` (extend) | D-704 |
| Font enum | `Utilities/Fonts/<EnumName>.swift` | D-1101 |
| App constants | `Utilities/Helpers/Constants.swift` (extend) | D-1304 |

For the full set of shape-of-code decisions in this layout (state, navigation, popup, feedback, tracking, etc.), see **`references/ikame-decision-table.md`** — it locks every pattern with a stable D-ID for subagents to reference.

---

## §3. Folder layout — `screen-based` (generic SwiftUI per-screen)

For non-Ikame projects that follow the one-folder-per-screen convention (typical when no design-system framework is used). The generated output goes into:

```
Screens/
└── <Name>Screen/
    ├── <Name>Screen.swift            # the View struct (suffix `-Screen`)
    ├── <Name>ViewModel.swift         # the ViewModel (suffix `-ViewModel`)
    ├── Subviews/                     # one file per extracted subview
    │   ├── <Name><Sub>View.swift
    │   └── ...
    ├── SubViewModels/                # ONLY when a subview owns nontrivial state
    │   └── <Name><Sub>ViewModel.swift
    ├── Models/                       # screen-local model types (≥2 subviews share them)
    │   └── <Name><Type>.swift
    └── Enums/                        # screen-local enums
        └── <Name><Type>.swift
```

**Where each kind of artifact lives (`screen-based`):**

| Artifact | Location |
|---|---|
| Main screen view | `Screens/<Name>Screen/<Name>Screen.swift` |
| Screen's ViewModel | `Screens/<Name>Screen/<Name>ViewModel.swift` (same level — NOT in a subfolder) |
| Subview ≤ 50 lines, no own state | inline `@ViewBuilder` computed property in the screen file |
| Subview > 50 lines OR owns `@State` | extract to `Subviews/<Name><Role>View.swift` |
| ViewModel for a complex subview | `SubViewModels/<Name><Role>ViewModel.swift` |
| Model used in ≥ 2 subviews of the same screen | `Models/<Name><Type>.swift` |
| Enum used in ≥ 2 subviews of the same screen | `Enums/<Name><Type>.swift` |
| Cross-screen reusable view | promote to `Components/<Type>View.swift` (drop screen prefix) |
| Cross-screen reusable model | promote to `Entities/<Type>.swift` (drop screen prefix) |

**Reusable utilities:**

| Artifact | Location |
|---|---|
| Reusable component (used in ≥ 2 screens) | `Components/<Type>View.swift` |
| Reusable model | `Entities/<Type>.swift` |
| Networking service | `Core/Network/<Service>.swift` |
| Router definition | `Core/Router/AppRouter.swift` (or per-feature router file) |
| Extension on a Swift / SwiftUI / UIKit type | `Utilities/Extensions/<Type>+Ext.swift` |
| Custom font enum | `Utilities/Fonts/IKFont.swift` (if convention; otherwise project's existing path) |
| Color/asset constants | `Resources/Assets.xcassets` + a `Color+Theme.swift` extension |

---

## §4. File / type naming (universal — applies in all 3 modes)

The single most important distinction:

- **Parent View = the full-screen view** that fills the device frame, owns a ViewModel, and represents one entry in the navigation graph → suffix **`-Screen`**.
- **Subview = anything composed inside a parent view** (header, row, card, badge, footer section, modal sheet body) → suffix **`-View`**.

Both are SwiftUI `struct ...: View`. The suffix tells the reader which one it is.

| Concept | Suffix | Case | Example (screen-based) | Example (ikame-feature-flat) |
|---|---|---|---|---|
| Parent View (full screen) | `-Screen` | PascalCase | `OnboardingScreen`, `HomeScreen`, `ArticleListScreen` | `CodesHomeScreen`, `Edit2FACodeScreen`, `ScanCodeScreen` |
| Subview (composed inside a screen) | `-View` | PascalCase | `OnboardingProgressView`, `HomeArticleRowView` | `CodesHomeHeaderView`, `CodesHomeEmptyView`, `CodesHomeAddCodeSuccessView` |
| ViewModel (1 per screen) | `-ViewModel` | PascalCase | `OnboardingViewModel`, `HomeViewModel` | `CodesHomeViewModel` |
| Sub-ViewModel (for a complex subview) | `-ViewModel` | PascalCase | `OnboardingProgressViewModel` | rare in Ikame; usually feature ViewModel owns subview state |
| Reusable component (≥ 2 screens / features) | `-View` | PascalCase | `Components/ArticleRowView.swift` (no screen prefix) | `Components/AppPopupView.swift`, `Components/CTAButton.swift` |
| Protocol | `-able` or domain-specific | PascalCase | `Fetchable`, `LoginService` | same |
| Type extension file | `+Ext` | `<Type>+Ext.swift` | `String+Ext.swift`, `View+Ext.swift` | same |
| Type extension by feature | `+<Feature>Ext` | `<Type>+<Feature>Ext.swift` | `Date+FormatExt.swift` | same |

**Banned naming patterns:**
- `HomeView.swift` for a full-screen view → use `HomeScreen.swift` (`-Screen` suffix is reserved for parent views).
- `OnboardingHeaderScreen.swift` for a subview component → use `OnboardingHeaderView.swift` (`-Screen` is reserved for full screens).
- `Home.swift` (no suffix) for either → choose `HomeScreen.swift` or `HomeView.swift` per the table.

`scripts/c8-conventions-gate.sh` checks the filename ↔ declared-type agreement (a `*Screen.swift` file declares a `*Screen` type; a `*View.swift` file declares a `*View` struct), but does NOT detect "this `HomeView` is actually a full-screen view, should be `HomeScreen`" — that decision belongs to the agent at C2 and is documented here so the agent makes it correctly.

### Subview prefix rule (per convention)

| Mode | Prefix rule |
|---|---|
| `screen-based` | Prefix = parent screen name with `Screen` suffix stripped. Folder `OnboardingScreen` → file prefix `Onboarding`. |
| `ikame-feature-flat` | Prefix = parent screen base name (typically `<Feature>Home`). Folder `Codes/Subviews/` → file prefix `CodesHome`. The prefix is more specific so subviews of `CodesHomeScreen` and `CodesEditScreen` don't collide in the same `Codes/Subviews/` folder. |
| `flat` | No enforced prefix — match project's existing convention. |

```
# screen-based
Screens/OnboardingScreen/Subviews/OnboardingProgressView.swift    ✓
Screens/OnboardingScreen/Subviews/OnboardingHeaderView.swift      ✓
Screens/OnboardingScreen/Subviews/ProgressView.swift              ✗  (no prefix; collides with SwiftUI ProgressView)
Screens/OnboardingScreen/Subviews/OnboardingScreen.swift          ✗  (subviews use `-View` not `-Screen`)

# ikame-feature-flat
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
| screen-based | `Screens/HomeScreen/Subviews/HomeArticleRowView.swift` | `Components/ArticleRowView.swift` | Move file, drop prefix, update all references. |
| screen-based | `Screens/HomeScreen/Models/HomeSection.swift` | `Entities/Section.swift` | Move file, drop prefix, update all references. |
| ikame-feature-flat | `Screens/Codes/Subviews/CodesHomeAddCodeSuccessView.swift` | `Components/AppAddCodeSuccessView.swift` | Move file, drop feature prefix, **add `App` prefix** for cross-cutting reusable, update references. |
| ikame-feature-flat | `Screens/Codes/Models/CodesStep.swift` | `Entities/<Source>/G<Domain>Model.swift` | Move file to appropriate `<Source>` bucket, change to project's entity prefix, update references. |

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

### When `screenFolderConvention == "ikame-feature-flat"`

1. **Screen file location.** Type ending in `Screen` is at `Screens/<Feature>/<Name>Screen.swift` (any depth ≤ 2 inside `Screens/`).
2. **ViewModel placement.** Type ending in `ViewModel` is at `Screens/<Feature>/ViewModel/<Name>ViewModel.swift`.
3. **Subview prefix.** Files in `Screens/<Feature>/Subviews/` start with the parent screen's base name (e.g. `CodesHome*View.swift` for the `Codes` feature whose entry screen is `CodesHomeScreen`).
4. **Suffix match.** Type and file basename agree on suffix: `*Screen.swift` declares a `*Screen` type; `*ViewModel.swift` declares a `*ViewModel` class; `*View.swift` declares a `*View` struct.
5. **Extension file naming.** A file at `Utilities/Extensions/*.swift` matches `<Type>+Ext.swift` or `<Type>+<Feature>Ext.swift`.
6. **No subagent writes to shared paths.** When run is part of a multi-screen orchestration (subagent), files outside `Screens/<assigned-feature>/` fail unless they are explicit delta-request resolutions — see `references/ikame-decision-table.md` §16.

### When `screenFolderConvention == "screen-based"`

1. **Screen file location.** Type ending in `Screen` is at `Screens/<Name>Screen/<Name>Screen.swift`.
2. **ViewModel placement.** Type ending in `ViewModel` is in the same folder as its Screen, NOT in `SubViewModels/` (unless it IS a sub-ViewModel — owned by a non-screen parent).
3. **Subview prefix.** Files in `Subviews/`, `SubViewModels/`, `Models/`, `Enums/` start with the parent folder's screen name (folder `OnboardingScreen` → files start with `Onboarding`).
4. **Suffix match.** Same as above.
5. **Extension file naming.** Same as above.

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
