# Project Structure & File Naming

**Canonical source for Ikame projects: [`ikame-ios-coding/references/project-structure.md`](../../ikame-ios-coding/references/project-structure.md)** — the `one-screen-per-folder` layout, naming rules, promotion conventions. This file holds only:
- Detection rules for the 3 layout modes
- Brownfield `ikame-feature-flat` variant
- Vanilla / `flat` layout
- C8 gate enforcement

## §1. Detection (C1 audit)

C1 sets `c1-conventions.json.screenFolderConvention` by inspecting the project tree:

| Signal | Value |
|---|---|
| Existing `Screens/<X>/<X>Screen.swift` for ≥ 2 X | `"one-screen-per-folder"` (canonical, both Ikame + non-Ikame) |
| Fresh ikxcodegen scaffold (only `Screens/Main/MainScreen.swift`) + `pod 'IKCoreApp'` | `"one-screen-per-folder"` |
| `Screens/<Feature>/<Feature>HomeScreen.swift` + `Screens/<Feature>/ViewModel/` for ≥ 2 features | `"ikame-feature-flat"` (brownfield Ikame, e.g. authenv2) |
| `Sources/<Module>/Views/*.swift` flat OR `App/Views/Home/HomeView.swift` (no `-Screen` suffix) | `"flat"` |
| Mixed | Majority signal wins; new files follow detected convention; existing files left alone unless user says align |

**Canonical Ikame layout is `one-screen-per-folder`.** `ikame-feature-flat` is brownfield-only — **do NOT introduce it into a project that doesn't have it.**

## §2. Canonical `one-screen-per-folder` (both Ikame + non-Ikame)

For full layout details see `ikame-ios-coding/references/project-structure.md`. Summary:

```
<ProjectName>/
├── App/                                   ← UIKit lifecycle entry — skill never edits
├── Core/Router/<Feature>/                 ← per-feature router (see iknavigation-bridge.md)
├── Environments/                          ← env config
├── Resources/Assets.xcassets/
├── Screens/
│   └── <Name>/
│       ├── <Name>Screen.swift             ← View
│       ├── <Name>ViewModel.swift          ← VM (co-located, NOT in ViewModel/)
│       ├── Subviews/                      ← present only when ≥1 extracted SubView with state
│       │   └── <Name><Role>View.swift     ← prefix = screen name
│       ├── Models/<Name><Type>.swift      ← screen-only models (1-screen use → prefix)
│       ├── Enums/<Name><Enum>.swift
│       └── SubViewModels/                 ← rare; prefer parent's @Published first
└── Utilities/Extensions/<Type>+Ext.swift
```

**Promotion rule:** screen-prefixed SubView/Model/Enum used by 2+ screens → drop prefix, move to `Components/` (UI) or `Entities/` (model). These folders are NOT in the initial scaffold — appear on first promotion.

**Banned:** `-Screen` suffix outside the root file (no `Subviews/HomeArticleRowScreen.swift`); creating `ViewModel/` subfolder; per-screen network/repository files (repositories live in `Core/Network/Repositories/`).

## §3. Brownfield `ikame-feature-flat` (legacy)

Used by older Ikame projects (notably authenv2). Don't introduce; only follow when C1 detects.

```
Screens/
└── <Feature>/                         ← one folder per feature, not per screen
    ├── <Feature>HomeScreen.swift      ← home/landing screen of the feature
    ├── <Feature><Action>Screen.swift  ← additional screens (e.g. AuthLoginScreen, AuthSignupScreen)
    ├── ViewModel/                     ← VMs in a subfolder (not co-located)
    │   ├── <Feature>HomeViewModel.swift
    │   └── <Feature><Action>ViewModel.swift
    └── Subviews/                      ← shared across the feature's screens
```

C8 gate enforces feature-flat shape when `c1-conventions.json.screenFolderConvention == "ikame-feature-flat"`.

## §4. Vanilla / `flat`

Single-file / library / scratch projects:
- No `Screens/` folder enforced
- Skill emits one file per screen at user-requested path
- Respects existing suffix convention: `HomeView.swift` (no Screen suffix) for projects using `-View`, `HomeScreen.swift` for projects using `-Screen`

§5 naming applies to NEW types regardless of layout.

## §5. Naming (universal)

| Kind | Pattern | Example |
|---|---|---|
| Screen | `<Name>Screen` | `HomeScreen`, `LoginScreen` |
| SubView | `<Name>View` | `ArticleRowView` |
| ViewModel | `<Name>ViewModel` | `HomeViewModel` |
| Repository protocol | `<Domain>Repository` | `UserRepository` |
| IKMacros impl | `<Domain>RepositoryImpl` (auto-generated) | `UserRepositoryImpl` |
| Extension file | `<Type>+Ext.swift` | `String+Ext.swift` |
| Verb-prefixed function | `didTap…`, `fetch…`, `setup…`, `handle…`, `validate…`, `bind…`, `convert…` | `didTapLogin()` |

Types PascalCase; vars/functions camelCase; enum cases camelCase.

## §6. Promotion examples

**SubView promotion** (used by 1 screen → 2 screens):
```diff
- Screens/Home/Subviews/HomeArticleRowView.swift
+ Components/ArticleRowView.swift
```
Drop the `Home` prefix when moving. Update all call sites.

**Model promotion**:
```diff
- Screens/Home/Models/HomeArticle.swift
+ Entities/Article.swift
```

## §7. C8 gate enforcement (write-time)

The figma-to-swiftui-gate hook (PreToolUse Write/Edit) catches at write-time when `c1-conventions.json.screenFolderConvention != "flat"`:

- Path correctness — `<X>Screen.swift` files must live at the layout-appropriate path
- ViewModel placement — `<X>ViewModel.swift` co-located (one-screen-per-folder) OR under `ViewModel/` (feature-flat)
- Subview prefix — files in `Subviews/` start with parent screen / feature base name
- `-Screen` suffix banned outside the root screen file

When `screenFolderConvention == "flat"`, the gate is informational (no enforcement).
