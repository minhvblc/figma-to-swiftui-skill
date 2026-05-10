# IKLocalized Bridge

How `figma-to-swiftui` localizes user-facing strings when the target project uses Ikame's `.ikLocalized()` extension on `String` (re-exported by `IKCoreApp`). Conditional — applies only when `c1-conventions.json.usesIKLocalized == true`.

Ikame uses **two paths** for localization. Picking the wrong path silently breaks localization or double-localizes — this bridge documents the exact decision rule.

The full set of localization decisions is locked in `references/ikame-decision-table.md` §9 (D-801..D-806). This file expands on the patterns with full code examples and the "two paths" decision tree.

---

## §1. Detection (C1 audit)

C1 sets `usesIKLocalized = true` when ANY of these signals are present:

| Signal | Where to look |
|---|---|
| `pod 'IKCoreApp'` in Podfile | grep |
| `import IKCoreApp` in any Swift file | grep |
| `.ikLocalized()` call in any Swift file | `grep -rE '"\..*"\.ikLocalized\(\)'` |

If any signal present → `usesIKLocalized = true`. Skill emits Ikame-flavored localization.

C1 also captures `xcstringsPath` — the project's `Localizable.xcstrings` file. Both paths below append keys to this single catalog.

---

## §2. The two paths — decision tree

```
                    ┌────────────────────────────────┐
                    │ User-facing string in code     │
                    └────────────┬───────────────────┘
                                 │
              ┌──────────────────┴────────────────────┐
              │                                       │
        Passed directly                        Stored as String,
       to Text("...")?                       passed to non-Text API,
              │                              or built via interpolation
              │                                       │
              ▼                                       ▼
    ┌──────────────────────┐              ┌────────────────────────┐
    │ PATH 1               │              │ PATH 2                 │
    │ Text("Hello")        │              │ "Hello".ikLocalized()  │
    │                      │              │                        │
    │ SwiftUI auto-        │              │ Extension method on    │
    │ localizes via        │              │ String — looks up the  │
    │ LocalizedStringKey   │              │ same xcstrings catalog │
    │                      │              │ at runtime             │
    └──────────────────────┘              └────────────────────────┘
```

**Rule:** if the literal sits directly inside `Text(...)`, leave it alone — SwiftUI infers `LocalizedStringKey`. Anywhere else, append `.ikLocalized()`.

---

## §3. Path 1 — `Text("...")` literal

When the literal sits **directly** as the first argument to `Text(_:)`, SwiftUI's `Text` initializer accepts `LocalizedStringKey` and auto-localizes via `Localizable.xcstrings`:

```swift
// ✓ All of these auto-localize via LocalizedStringKey
Text("Authenticator")
Text("Welcome back")
Text("Selected: \(count)")          // interpolation into key — SwiftUI handles it
Text("\(name), welcome to Ikame")   // same — interpolation in LocalizedStringKey

// ✓ Fine — Text init accepts LocalizedStringKey directly
let key: LocalizedStringKey = "Welcome"
Text(key)
```

**DO NOT** add `.ikLocalized()` here:

```swift
// ✗ WRONG — coerces to String, calls Text(_: String) overload, NOT auto-localized
Text("Authenticator".ikLocalized())

// ✗ WRONG — same problem (calls String overload)
Text(String(localized: "Authenticator"))
```

The `Text("Authenticator")` form relies on Swift's overload resolution choosing `Text(_: LocalizedStringKey)` over `Text(_: String)` because the literal is implicitly convertible. The moment you call a method on the literal (like `.ikLocalized()`), the type becomes `String`, and overload resolution picks the non-localizing variant.

### Localizable.xcstrings entries

When the skill emits a new `Text("Hello")` literal, it appends an entry to `Localizable.xcstrings`:

```json
{
  "sourceLanguage": "en",
  "strings": {
    "Hello": {
      "extractionState": "manual",
      "localizations": {
        "en": { "stringUnit": { "state": "translated", "value": "Hello" } }
      }
    }
  }
}
```

The `extractionState: "manual"` flags it for the next translation pass. Skill does NOT auto-translate; user runs translation via Xcode or external pipeline.

---

## §4. Path 2 — `String` constants and non-Text APIs

When the string is stored as `String` (constants, popup args, format strings, computed values), call `.ikLocalized()` explicitly:

```swift
// ✓ Static constants — `static let X: String` infers String, NOT LocalizedStringKey
struct CodesHomeScreenConstants {
    static let title: String = "Authenticator".ikLocalized()
    static let renameTitle: String = "Rename".ikLocalized()
    static let renameDescription: String = "Please enter the folder name below".ikLocalized()
}

// ✓ Text consuming a String constant — pass-through; constant is already localized
Text(CodesHomeScreenConstants.title)
    .appFontHeading3()

// ✓ Format string for non-Text API
let formatted = String(format: "Selected: %d".ikLocalized(), count)

// ✓ Popup / alert title (these APIs accept String)
let result = await AppUtils.shared.showAlertPopup(
    title: "Delete Folder?".ikLocalized(),
    message: "Choose how you want to delete this folder.".ikLocalized(),
    alertButtonTitle: "Delete Everything".ikLocalized(),
    cancelButtonTitle: "Cancel".ikLocalized()
)

// ✓ Toast / haptic message (when constructing dynamic text for non-Text contexts)
let label = "Tap to dismiss".ikLocalized()
showCustomTooltip(text: label)

// ✓ Concatenation building a String (not for Text)
let joined = "Hello".ikLocalized() + ", " + userName + "!"
```

The `.ikLocalized()` extension internally looks up the same `Localizable.xcstrings` SwiftUI uses. It uses the English source as the key.

### When to use a per-screen `Constants` struct

When a label is reused 2+ times within the same screen, declare it once in a nested constants struct:

```swift
struct CodesHomeScreen: View {
    struct CodesHomeScreenConstants {
        static let title: String = "Authenticator".ikLocalized()
        static let confirmDelete: String = "Are you sure?".ikLocalized()
        static let cancelButton: String = "Cancel".ikLocalized()
    }

    var body: some View {
        VStack {
            Text(CodesHomeScreenConstants.title)
                .appFontHeading3()
            // ...
        }
    }

    func showConfirm() {
        Task {
            let result = await IKPopup.shared.showPopup(
                swiftUIView: ConfirmView(
                    title: CodesHomeScreenConstants.confirmDelete,    // String constant
                    cancel: CodesHomeScreenConstants.cancelButton
                ),
                configuration: .defaultPopup
            )
        }
    }
}
```

This avoids duplicating the localization key and keeps the source-of-truth label in one place.

---

## §5. Banned patterns

| Pattern | Why banned | Replacement |
|---|---|---|
| `Text(NSLocalizedString("Hello", comment: ""))` | NSLocalizedString predates xcstrings; using it bypasses Ikame's catalog management | `Text("Hello")` |
| `NSLocalizedString("Hello", comment: "")` direct | Same | `"Hello".ikLocalized()` |
| `Text(String(localized: "Hello"))` | iOS 15+ form, but coerces to String and skips LocalizedStringKey path | `Text("Hello")` |
| `Text(.welcomeMessage)` symbol-key API | Ikame doesn't use String Catalog Symbols build setting | `Text("Welcome")` |
| `Text(LocalizedStringKey("Hello"))` manual constructor | Redundant — let SwiftUI infer | `Text("Hello")` |
| `Text("Hello".ikLocalized())` (double-localize) | Coerces to String; bypasses LocalizedStringKey path | `Text("Hello")` |
| Inline string at file scope (`let title = "Hello"`) for user-facing | Untracked by xcstrings | `let title = "Hello".ikLocalized()` (Path 2) |

---

## §6. Mixed-context examples (real-world)

These are common patterns where the wrong path is easy to pick. Decision per case:

```swift
// 1. Button label — Text inside, Path 1
Button(action: save) {
    Text("Save")        // ← Path 1: Text init takes LocalizedStringKey
}

// 2. Button with ikLocalized String label — Path 2 because Button("...") takes String
Button("Save".ikLocalized(), action: save)
//      ^^^^^^^^^^^^^^^^^^ this Button overload is `init(_: String, action:)` — needs ikLocalized

// 3. Navigation title — String, Path 2
.navigationTitle("Profile".ikLocalized())   // navigationTitle accepts String OR LocalizedStringKey;
                                            // when project uses ikLocalized convention, prefer Path 2 explicitly

// 4. Plural with count
Text("Selected: \(count)")              // Path 1 — SwiftUI handles interpolated key
// vs
let countLabel = String(format: "Selected: %d".ikLocalized(), count)
Text(countLabel)                         // Path 2 — pre-formatted String

// 5. Error message stored on a ViewModel (String type)
@Published var errorMessage: String?
// In reducer:
errorMessage = "Network error".ikLocalized()    // Path 2
// In View:
if let msg = errorMessage { Text(msg) }          // Pass-through

// 6. Accessibility label — accepts LocalizedStringKey OR String
Image(.icClose)
    .accessibilityLabel("Close".ikLocalized())  // Path 2 — be explicit; the modifier has String overload
```

When in doubt: **does the call site accept `LocalizedStringKey`?** If yes (e.g. `Text(_:)`, `navigationTitle(_:)` on `LocalizedStringKey`), Path 1. If it only accepts `String` (e.g. `IKPopup` titles, `String(format:)`, custom popup view init taking `String`), Path 2.

---

## §7. C8-iklocalized.sh enforcement

When `c1-conventions.json.usesIKLocalized == true`, the gate flags:

1. **`Text("...".ikLocalized())`** — double-localize anti-pattern (calls Text(_: String) which doesn't auto-localize).
2. **`Text(LocalizedStringKey("..."))`** — manual constructor (let SwiftUI infer).
3. **`NSLocalizedString(...)`** — anywhere in this run's generated files.
4. **`String(localized: ...)`** — same.
5. **`Text(.<symbolKey>)`** — symbol-key API not used in Ikame.
6. **`static let <name>: String = "<literal>"`** — static String constant without `.ikLocalized()` (unless the constant is non-user-facing — heuristic: name doesn't suggest a label, e.g. `static let tableName = "users"` is fine).

When `usesIKLocalized == false`, the gate prints `GATE: SKIP (project does not use IKLocalized)` and exits 0.

The gate has known false-positive risk on rule 6 (false flag for non-user-facing constants like SQL table names). When triggered, agent adds inline comment `// not-user-facing: <reason>` to suppress.

---

## §8. Failure-mode self-check

Before emitting a user-facing string:

1. **Picked the right path?** Literal directly inside `Text(...)` → Path 1 (no `.ikLocalized()`). Anywhere else → Path 2 (`.ikLocalized()`).
2. **Avoided `Text("...".ikLocalized())`?** That's the double-localize anti-pattern.
3. **Avoided `Text(LocalizedStringKey("..."))` manual constructor?** Let SwiftUI infer.
4. **For static `String` constants** (e.g. `static let title: String = "..."`) → Path 2 always (because `String` infers).
5. **For popup titles, alert messages, format strings** → Path 2 (these APIs take `String`).
6. **No `NSLocalizedString` / `String(localized:)`** anywhere in the file?
7. **Non-user-facing String constants** (SQL table names, asset symbol keys, debug labels) — they do NOT need `.ikLocalized()`. If the gate flags one, add `// not-user-facing: <reason>` comment to suppress.

If any answer is "no" / "unsure", STOP and consult `references/ikame-decision-table.md` §9.
