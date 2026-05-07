# Project Structure & File Naming

How `figma-to-swiftui` lays generated files into the target iOS project. Hard rules — enforced by `scripts/c8-conventions-gate.sh`.

These rules apply **only when the project follows the screen-based convention** (detected at C1 — see `c1-conventions.json.screenFolderConvention`). If the project uses a different layout (single-file scratch project, library target, etc.), C1 records `screenFolderConvention = "flat"` and this gate is skipped.

---

## §1. Detection (C1 audit)

C1 sets `c1-conventions.json.screenFolderConvention` by inspecting the project tree:

| Signal | Value |
|---|---|
| `Screens/<X>Screen/<X>Screen.swift` exists for at least 2 X | `"screen-based"` |
| `Sources/<Module>/Views/*.swift` flat | `"flat"` |
| `App/Views/Home/HomeView.swift` (no `-Screen` suffix anywhere — full-screen views named with `-View`) | `"flat"` |
| Mixed — some screens follow, some don't | `"screen-based"` (apply to NEW files only; existing files left as-is unless user says align) |

If `screen-based`: every rule below is **hard** — including the `-Screen` suffix for full-screen views. If `flat`: skill emits one file per screen at a path the user requests, AND respects whatever suffix the project already uses (`-View` if the project uses `HomeView` for full screens; `-Screen` if it uses `HomeScreen`). §3 naming applies to NEW types regardless.

---

## §2. Folder layout (when `screen-based`)

Generated screen output goes into:

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

**Where each kind of artifact lives:**

| Artifact | Location |
|---|---|
| Main screen view | `Screens/<Name>Screen/<Name>Screen.swift` |
| Screen's ViewModel | `Screens/<Name>Screen/<Name>ViewModel.swift` (same level — NOT in a subfolder) |
| Subview ≤ 50 lines, no own state | inline `@ViewBuilder` computed property in the screen file (e.g. `var headerSection: some View`) |
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

## §3. File / type naming (always — even when `flat`)

The single most important distinction:

- **Parent View = the full-screen view** that fills the device frame, owns a ViewModel, and represents one entry in the navigation graph → suffix **`-Screen`**.
- **Subview = anything composed inside a parent view** (header, row, card, badge, footer section, modal sheet body) → suffix **`-View`**.

Both are SwiftUI `struct ...: View`. The suffix tells the reader which one it is.

| Concept | Suffix | Case | Example |
|---|---|---|---|
| Parent View (full screen) | `-Screen` | PascalCase | `OnboardingScreen`, `HomeScreen`, `ArticleListScreen` |
| Subview (composed inside a screen) | `-View` | PascalCase | `OnboardingProgressView`, `HomeArticleRowView`, `UserAvatarView` |
| ViewModel (1 per screen) | `-ViewModel` | PascalCase | `OnboardingViewModel`, `HomeViewModel` |
| Sub-ViewModel (for a complex subview) | `-ViewModel` | PascalCase | `OnboardingProgressViewModel` |
| Reusable component (≥ 2 screens) | `-View` | PascalCase | `Components/ArticleRowView.swift` (no screen prefix once promoted) |
| Protocol | `-able` or domain-specific | PascalCase | `Fetchable`, `LoginService` |
| Type extension file | `+Ext` | `<Type>+Ext.swift` | `String+Ext.swift`, `View+Ext.swift` |
| Type extension by feature | `+<Feature>Ext` | `<Type>+<Feature>Ext.swift` | `Date+FormatExt.swift`, `Color+ThemeExt.swift` |

**Banned naming patterns:**
- `HomeView.swift` for a full-screen view → use `HomeScreen.swift` (`-Screen` suffix is reserved for parent views).
- `OnboardingHeaderScreen.swift` for a subview component → use `OnboardingHeaderView.swift` (`-Screen` is reserved for full screens).
- `Home.swift` (no suffix) for either → choose `HomeScreen.swift` or `HomeView.swift` per the table.

`scripts/c8-conventions-gate.sh` checks the filename ↔ declared-type agreement (a `*Screen.swift` file declares a `*Screen` type; a `*View.swift` file declares a `*View` struct), but does NOT detect "this `HomeView` is actually a full-screen view, should be `HomeScreen`" — that decision belongs to the agent at C2 and is documented here so the agent makes it correctly.

**Screen prefix rule (mandatory).** Every file in `Subviews/`, `SubViewModels/`, `Models/`, `Enums/` MUST start with the parent screen's name (the prefix is the screen name with `Screen` suffix stripped — folder `OnboardingScreen` → prefix `Onboarding`):

```
Screens/OnboardingScreen/Subviews/OnboardingProgressView.swift    ✓  (parent screen prefix `Onboarding`, subview suffix `View`)
Screens/OnboardingScreen/Subviews/OnboardingHeaderView.swift      ✓
Screens/OnboardingScreen/Subviews/ProgressView.swift              ✗  (no `Onboarding` prefix; also collides with SwiftUI ProgressView)
Screens/OnboardingScreen/Subviews/OnboardingScreen.swift          ✗  (subviews use `-View` suffix, not `-Screen`)
Screens/OnboardingScreen/Models/Step.swift                        ✗  (no prefix)
Screens/OnboardingScreen/Models/OnboardingStep.swift              ✓
```

The prefix exists so a reader scanning `Subviews/` knows which screen owns a file without opening it, and to avoid collisions with framework types or other screens' subviews.

**Exception — nested type.** A model nested inside a screen view or its ViewModel does NOT need the prefix (its scope is already the parent type):

```swift
// ✓ Nested — no prefix needed
struct OnboardingScreen: View {
    struct Step: Identifiable { let id: UUID; let title: String }
}

// ✗ Standalone in Models/Step.swift — must be `OnboardingStep`
```

---

## §4. Promotion rules

When a model or view originally scoped to one screen needs to be reused, **promote it before the second screen lands** — never let the second screen import from the first screen's folder.

| From | To | Action |
|---|---|---|
| `Screens/HomeScreen/Subviews/HomeArticleRowView.swift` | `Components/ArticleRowView.swift` | Move file, drop prefix, update all references. |
| `Screens/HomeScreen/Models/HomeSection.swift` | `Entities/Section.swift` | Move file, drop prefix, update all references. |

**Skill rule**: when the agent generates a feature flow (`figma-flow-to-swiftui-feature`) and a component is referenced by ≥ 2 screens in the screen graph, emit it in `Components/` (or `Entities/`) FROM THE START — do not place it inside one screen's folder and then move it.

---

## §5. Naming verbs (function names)

Action handler functions should start with a domain-specific verb. C8-vm-pattern.sh treats these as informational, not hard fail, but the convention is:

| Prefix | Use for |
|---|---|
| `didTap...` | tap action handler — `didTapLoginButton()` |
| `fetch...` | data retrieval — `fetchUserProfile()` |
| `load...` | initial-load variant of fetch — `loadDashboard()` |
| `setup...` | one-time setup — `setupNavigationBar()` |
| `handle...` | event/response handler — `handleResponse(_:)` |
| `validate...` | data validation — `validateEmail(_:)` |
| `configure...` | configure UI/data — `configureCell(_:)` |
| `bind...` | data binding setup — `bindData(to:)` |
| `convert...` | type conversion — `convertToDisplayFormat(_:)` |
| `make...` | factory — `makeIterator()` |

**Side effect convention (Swift API design):** mutating verbs are imperative (`sort()`, `append()`); non-mutating are nouns or `-ed/-ing` (`sorted()`, `reversed()`, `successor`). Pair them as `sort()`/`sorted()`, never just one.

---

## §6. C8-conventions-gate enforcement

`scripts/c8-conventions-gate.sh` runs at the end of Step C4 (after copy assets) and checks, for every Swift file generated by this run:

1. **Screen file location.** Type ending in `Screen` is at `Screens/<Name>Screen/<Name>Screen.swift`.
2. **ViewModel placement.** Type ending in `ViewModel` is in the same folder as its Screen, NOT in `SubViewModels/` (unless it IS a sub-ViewModel — owned by a non-screen parent).
3. **Subview prefix.** Files in `Subviews/`, `SubViewModels/`, `Models/`, `Enums/` start with the parent folder's screen name (folder `OnboardingScreen` → files start with `Onboarding`).
4. **Suffix match.** Type and file basename agree on suffix: `*Screen.swift` declares a `*Screen` type; `*ViewModel.swift` declares a `*ViewModel` class; `*View.swift` declares a `*View` struct.
5. **Extension file naming.** A file at `Utilities/Extensions/*.swift` matches `<Type>+Ext.swift` or `<Type>+<Feature>Ext.swift`.

Output: `GATE: PASS` or `GATE: FAIL: <reason>` — exit code matches.

The gate is skipped (printed `GATE: SKIP (flat layout)`) when `c1-conventions.json.screenFolderConvention == "flat"`.
