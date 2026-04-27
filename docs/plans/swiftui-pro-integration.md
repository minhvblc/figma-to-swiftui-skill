# Plan: Tích hợp swiftui-pro vào figma-to-swiftui

## Context

`swiftui-pro` (Paul Hudson, MIT) là review skill chuẩn của team — 9 reference files (~278 lines) cover modern API, view structure, data flow, navigation, design system, accessibility, performance, Swift idioms, hygiene. Hiện skill đang nằm dưới mỗi project (vd. `authenv2/.agents/skills/swiftui-pro/`), không có ở figma-to-swiftui-skill.

Mục tiêu: code mà figma-to-swiftui sinh ra phải tự tuân swiftui-pro standards ngay từ first pass (preventive ở Phase C2), và có safety-net review ở Phase C3 để catch sót.

## Quyết định kiến trúc (chốt)

1. **Snapshot trong skill repo.** Copy 9 reference files vào `figma-to-swiftui/references/swiftui-pro/`. Ưu: standards bundle với skill, không phụ thuộc target project. Nhược: cần manual sync khi Paul Hudson cập nhật — chấp nhận, doc note trong header file.
2. **C2 + C3 cùng áp dụng.** C2 sinh code đã tuân chuẩn (preventive); C3 thêm Pass 4 (swiftui-pro review) làm safety-net.
3. **Pixel fidelity vẫn ưu tiên.** Khi swiftui-pro nói "avoid hard-coded values" mà Figma giao value cụ thể, Figma value thắng — vì swiftui-pro đã có exception "unless specifically requested" và Figma values ARE specifically requested. Cách dung hòa: route qua design constants enum nếu project có, else inline.
4. **Source-of-truth cho mỗi rule:** swiftui-pro reference files là canonical. figma-to-swiftui không duplicate text rule, chỉ link và bổ sung Figma-specific transforms.

## Files được sửa

| # | File | Loại | Nội dung |
|---|---|---|---|
| 1 | `figma-to-swiftui/references/swiftui-pro/*.md` (9 files) | **NEW (snapshot)** | Copy nguyên 9 ref files: api, views, data, navigation, design, accessibility, performance, swift, hygiene |
| 2 | `figma-to-swiftui/references/swiftui-pro/SOURCE.md` | **NEW** | Ghi nguồn: original location, version, author, ngày snapshot, instruction sync |
| 3 | `figma-to-swiftui/references/swiftui-pro-bridge.md` | **NEW** | Cầu nối Figma↔swiftui-pro: bảng before/after cho mọi pattern Figma sinh ra; tension resolutions |
| 4 | `figma-to-swiftui/SKILL.md` | EDIT | C1 thêm 5 audit; C2 thêm critical rules + reference snapshot; C3 thêm Pass 4 |
| 5 | `figma-flow-to-swiftui-feature/SKILL.md` | EDIT | §2 Audit Codebase: bắt buộc check NavigationStack + @Observable + @MainActor; §5: View structs own files |
| 6 | `figma-to-swiftui/references/visual-fidelity.md` | EDIT | §1 (token/inline source tag): thêm route qua design constants enum nếu có |
| 7 | `figma-to-swiftui/references/design-token-mapping.md` | EDIT (optional) | Update typography map: dùng `.font(.body)` khi value match Dynamic Type role |

## File 1–2: Snapshot swiftui-pro

```
figma-to-swiftui/references/swiftui-pro/
├── SOURCE.md                  ← snapshot metadata + sync instructions
├── accessibility.md           ← copy verbatim
├── api.md
├── data.md
├── design.md
├── hygiene.md
├── navigation.md
├── performance.md
├── swift.md
└── views.md
```

`SOURCE.md` content:
```markdown
# swiftui-pro snapshot

Source: Paul Hudson swiftui-pro skill (MIT, v1.0)
Snapshot taken from: <project>/.agents/skills/swiftui-pro/
Snapshot date: 2026-04-27

## When to re-sync

If the source skill is updated in any project, re-snapshot here. Compare with `diff` or `git diff` against the source. Keep this folder verbatim — do NOT edit rules in place; if Figma-specific guidance is needed, put it in `../swiftui-pro-bridge.md` instead.

## Files

- `accessibility.md` — Dynamic Type, VoiceOver, Reduce Motion
- `api.md` — modern SwiftUI API, deprecated replacements
- `data.md` — @Observable, @State, bindings, SwiftData
- `design.md` — design constants, HIG, system styling
- `hygiene.md` — secrets, tests, localization, SwiftLint
- `navigation.md` — NavigationStack, sheets, alerts
- `performance.md` — view structure, lazy stacks, async
- `swift.md` — modern Swift idioms, concurrency
- `views.md` — view extraction, animations, previews
```

## File 3: swiftui-pro-bridge.md (NEW — bridge doc)

Nội dung chính: bảng transform Figma→SwiftUI áp dụng swiftui-pro rules. Mỗi row gồm: Figma input pattern, naive output, swiftui-pro-compliant output, link rule trong swiftui-pro.

Sections:
1. **Tension resolutions** — pixel fidelity vs no-hard-coded; custom fonts vs Dynamic Type; figma colors vs asset catalog
2. **High-impact transforms (apply at C2 always)** — bảng ~15 row
3. **Project-context-dependent transforms (need C1 audit)** — bảng ~5 row
4. **Structural rules (apply at C3 review)** — bảng ~7 row
5. **What stays unchanged** — Figma values cho spacing/sizing/colors khi không có design constants

Bảng High-impact:

| # | Figma input | Naive | swiftui-pro-compliant | Rule |
|---|---|---|---|---|
| 1 | Bold text | `.fontWeight(.bold)` | `.bold()` | design.md L27 |
| 2 | Color | `.foregroundColor(...)` | `.foregroundStyle(...)` | api.md L3 |
| 3 | Rounded rect | `.cornerRadius(12)` | `.clipShape(.rect(cornerRadius: 12))` | api.md L4 |
| 4 | Top toolbar leading | `.navigationBarLeading` | `.topBarLeading` | api.md L11 |
| 5 | Top toolbar trailing | `.navigationBarTrailing` | `.topBarTrailing` | api.md L11 |
| 6 | Tab bar | `.tabItem { Label(...) }` | `Tab("Home", systemImage: "house", value: .home) { ... }` (iOS 18+) | api.md L5 |
| 7 | Decorative Image | `Image("decorativeBlob")` | `Image(decorative: "decorativeBlob")` | accessibility.md L6 |
| 8 | Icon-only Button | `Button { } label: { Image(...) }` | `Button("Close", systemImage: "xmark", action: close)` + `.labelStyle(.iconOnly)` if needed; or add `.accessibilityLabel("Close")` | accessibility.md L9 |
| 9 | onTapGesture for action | `.onTapGesture { ... }` | `Button { ... } label: { ... }` | accessibility.md L12 |
| 10 | Scroll indicators off | `ScrollView(showsIndicators: false)` | `ScrollView { ... }.scrollIndicators(.hidden)` | api.md L17 |
| 11 | Overlay with content | `.overlay(Text("..."), alignment: .top)` | `.overlay(alignment: .top) { Text("...") }` | api.md L10 |
| 12 | Stroke + fill shape | `RoundedRectangle().fill(c).overlay(RoundedRectangle().stroke(...))` | chained `.fill(c).stroke(...)` (iOS 17+) | api.md L13 |
| 13 | Image accessibility | `Image("icAIClose")` no label | `Image("icAIClose").accessibilityLabel("Close")` derived from semantic Figma name | accessibility.md L6 |
| 14 | Custom Preview | `struct V_Previews: PreviewProvider { static var previews: some View { ... } }` | `#Preview { V() }` | views.md L12 |
| 15 | Conditional modifier | `if highlighted { v.opacity(0.5) } else { v }` | `v.opacity(highlighted ? 0.5 : 1.0)` | performance.md L3 |
| 16 | Animation | `.animation(.easeIn)` | `.animation(.easeIn, value: stateVar)` | views.md L20 |
| 17 | Tap area < 44 | raw `.frame(width: 24, height: 24)` Button | wrap with `.contentShape(.rect).frame(minWidth: 44, minHeight: 44)` | design.md L12 |

Bảng Project-context (cần C1 audit):

| # | Condition | Output if YES | Output if NO |
|---|---|---|---|
| 1 | `GENERATE_ASSET_SYMBOLS = YES` in pbxproj | `Image(.icAIClose)`, `Color(.brandRed)` | `Image("icAIClose")`, `Color("brandRed")` |
| 2 | Localizable.xcstrings exists | `Text(.welcome)` (symbol key), offer to translate | `Text("Welcome")` with `LocalizedStringKey` |
| 3 | Design constants enum exists (`Spacing`, `Sizes`, `IKFont`) | `.padding(Spacing.l24)` | `.padding(24)` |
| 4 | iOS deployment target ≥ 26 | `.font(.body.scaled(by: 16/17))` | `@ScaledMetric var fontSize: CGFloat = 16` + `.font(.system(size: fontSize))` |
| 5 | Existing `Color(hex:)` extension | `Color(hex: "#FF6600")` | Asset catalog or `Color(red:green:blue:)` |

Bảng Structural rules (C3 review):

| # | Anti-pattern | Required fix | Rule |
|---|---|---|---|
| 1 | Long view body with computed properties returning `some View` | Extract each into separate `View` struct in own file | views.md L3 |
| 2 | Multiple types in one file | Each struct/class/enum in own file | views.md L8 |
| 3 | Inline business logic in `body`/`task`/`onAppear` | Extract to method or `@Observable` view model | views.md L4-7 |
| 4 | `@Observable` class without `@MainActor` | Add `@MainActor` (unless project has main-actor isolation) | data.md L10 |
| 5 | `Binding(get:set:)` in body | Use `@State` + `onChange` | data.md L23 |
| 6 | `NavigationView` | `NavigationStack` or `NavigationSplitView` | navigation.md L3 |
| 7 | `NavigationLink(destination:)` | `navigationDestination(for:)` | navigation.md L4 |
| 8 | Force unwrap `!` on user-driven path | `if let` / `guard let` / nil-coalescing | swift.md L7 |
| 9 | `DispatchQueue.main.async` | `Task { @MainActor in ... }` | swift.md L49 |
| 10 | `GeometryReader` for size | `containerRelativeFrame`/`visualEffect`/`Layout` | api.md L7 |
| 11 | `AnyView` | `@ViewBuilder`/`Group`/generics | performance.md L4 |

## File 4: figma-to-swiftui/SKILL.md edits

### C1 Audit thêm 5 pre-flight checks

Insert sau "Project pre-flight" hiện tại trong Step C1 (~line 379):

```markdown
**swiftui-pro pre-flight (mandatory; routes downstream rules):**
6. Generated symbol assets — grep `pbxproj` for `GENERATE_ASSET_SYMBOLS = YES` or check Xcode 15+ default. If yes → emit `Image(.icAIClose)` not `Image("icAIClose")`. Stash result in run flag `useGeneratedSymbols`.
7. Design constants enum — grep `enum Spacing`, `enum Colors`, `enum Sizes`, `IKFont`, `IKCoreApp`. If any found, list them and route Figma values through them in C2. Stash list in run flag `designConstants`.
8. iOS deployment target — read `IPHONEOS_DEPLOYMENT_TARGET` from pbxproj. Decides @ScaledMetric vs `.scaled(by:)`, Tab API availability, iOS 26+ APIs. Stash as `deploymentTarget`.
9. Localizable.xcstrings vs .strings — check for `.xcstrings` files. If yes → use symbol-key API `Text(.welcomeMessage)` and offer to translate. Stash as `localizationStyle`.
10. Lottie SDK present — grep `import Lottie` or `Package.resolved` for `lottie-ios`. Decides eAnim* codegen path (already in `lottie-placeholders.md`).
```

### C2 critical rules: thêm block "swiftui-pro standards"

Insert sau bullet "Lottie placeholders" trong Critical rules (~line 491):

```markdown
- **swiftui-pro standards (write-time).** Code must comply with the snapshot in `references/swiftui-pro/`. The 17-row transform table in `references/swiftui-pro-bridge.md` §2 is the always-on subset:
  - `bold()` not `fontWeight(.bold)`; `foregroundStyle` not `foregroundColor`; `clipShape(.rect(cornerRadius:))` not `cornerRadius()`.
  - `.topBarLeading`/`.topBarTrailing` not `navigationBar*`.
  - `Image(decorative:)` for purely decorative Figma images; `accessibilityLabel` on every meaningful icon (derive from Figma node semantic name: `eICClose` → `"Close"`).
  - Icon-only `Button` → use `Button("Label", systemImage: "...", action: ...)` form OR explicit `.accessibilityLabel`. Never bare image-only `Button { } label: { Image(...) }` without label.
  - Tap targets < 44pt → wrap `.contentShape(.rect).frame(minWidth: 44, minHeight: 44)`.
  - `#Preview` macro, never `PreviewProvider`.
  - Modifier toggle by ternary `view.opacity(cond ? 0.5 : 1)`, not `if cond { view.opacity(0.5) } else { view }`.
  - Animations always pass a `value:`: `.animation(.easeIn, value: stateVar)`.
  - Project-context branches: see C1 audit flags `useGeneratedSymbols`, `designConstants`, `deploymentTarget`, `localizationStyle`.
- **Pixel-fidelity vs swiftui-pro tension.** Figma values for spacing/sizing/color are "specifically requested" per swiftui-pro design.md. Route them through `designConstants` if available; else emit inline literals — both are compliant.
```

Also add 1-line reminder near top of Phase C ABSOLUTE RULES:

> **All generated SwiftUI must comply with the swiftui-pro snapshot in `references/swiftui-pro/`.** Bridge transforms in `references/swiftui-pro-bridge.md` §2.

### C3: thêm Pass 4 — swiftui-pro Review

Insert sau Pass 3b (~line 568) trước "Anything in code not traceable":

```markdown
**Pass 4 — swiftui-pro Review (BASH + checklist, mandatory).**

Quick bash sweep for the highest-leverage violations:

```bash
SWIFT_FILES="<your-generated-swift-files>"

# Modern API
HITS_API=$(grep -nE 'foregroundColor\(|cornerRadius\(|fontWeight\(\.bold\)|navigationBarLeading|navigationBarTrailing|UIScreen\.main\.bounds|showsIndicators:' $SWIFT_FILES)
[ -z "$HITS_API" ] && echo "PASS: api.md modern usage" || { echo "FAIL: api.md violations:"; echo "$HITS_API"; }

# Views & previews
HITS_VIEWS=$(grep -nE 'PreviewProvider|GeometryReader|AnyView' $SWIFT_FILES)
[ -z "$HITS_VIEWS" ] && echo "PASS: views.md/performance.md" || { echo "REVIEW: views/perf hits:"; echo "$HITS_VIEWS"; }

# Concurrency
HITS_CONCURRENCY=$(grep -nE 'DispatchQueue\.|Task\.sleep\(nanoseconds:|Task\.detached' $SWIFT_FILES)
[ -z "$HITS_CONCURRENCY" ] && echo "PASS: swift.md concurrency" || { echo "FAIL: concurrency:"; echo "$HITS_CONCURRENCY"; }

# Bindings
HITS_BINDING=$(grep -nE 'Binding\(get:.*set:' $SWIFT_FILES)
[ -z "$HITS_BINDING" ] && echo "PASS: data.md bindings" || { echo "FAIL: manual bindings:"; echo "$HITS_BINDING"; }

# Accessibility — Image without label or decorative marker
ORPHAN_IMAGE=$(python3 -c "
import re, sys, pathlib
swift_files = '''$SWIFT_FILES'''.split()
for f in swift_files:
    text = pathlib.Path(f).read_text()
    for i, line in enumerate(text.splitlines(), 1):
        if re.search(r'Image\([\"\.]', line) and 'decorative' not in line:
            # Look ahead 5 lines for accessibilityLabel/Hidden
            window = '\n'.join(text.splitlines()[i-1:i+5])
            if 'accessibilityLabel' not in window and 'accessibilityHidden' not in window:
                print(f'{f}:{i}: {line.strip()}')
")
[ -z "$ORPHAN_IMAGE" ] && echo "PASS: image accessibility" || { echo "REVIEW: images missing label/decorative:"; echo "$ORPHAN_IMAGE"; }

# Force unwrap audit (informational, not always a fail)
HITS_BANG=$(grep -nE '![\.[]' $SWIFT_FILES | grep -v '!=' | grep -v '//')
[ -z "$HITS_BANG" ] && echo "PASS: no force unwraps" || { echo "REVIEW: force unwraps (verify each):"; echo "$HITS_BANG"; }
```

Then walk the **structural rules table** in `references/swiftui-pro-bridge.md` §4 manually for each generated file:
- Long view body? Extract to separate `View` structs in own files.
- Multiple types per file? Split.
- Inline business logic? Extract to method/view model.
- `@Observable` without `@MainActor`?
- `NavigationView` / `NavigationLink(destination:)`?

Output format follows swiftui-pro SKILL.md "Output Format" — group by file, name rule violated, before/after fix. Fix everything before declaring Pass 4 PASS.
```

### Update C5 (Validate) suggestion to mention swiftui-pro

Optional: nếu user chấp nhận C5 review, mention chạy thêm full swiftui-pro skill.

## File 5: figma-flow-to-swiftui-feature/SKILL.md edits

### §2 Audit the Codebase — thêm bắt buộc

Sau bullet "routing pattern":

```markdown
- swiftui-pro audit: confirm the routing uses `NavigationStack` / `NavigationSplitView` (not deprecated `NavigationView`) and that destinations register via `navigationDestination(for:)`. If the existing codebase mixes `NavigationLink(destination:)` with `navigationDestination(for:)`, **STOP** — flag to the user before writing new screens; mixing breaks navigation. See `../figma-to-swiftui/references/swiftui-pro/navigation.md`.
- swiftui-pro audit: confirm shared state uses `@Observable` + `@MainActor` (not `ObservableObject` / `@Published` / `@StateObject`) unless the project has legacy reasons. See `../figma-to-swiftui/references/swiftui-pro/data.md`.
```

### §5 Per-screen rules — thêm 2 bullet

Sau bullet "Reuse existing project components":

```markdown
- swiftui-pro structural rules apply: each screen view is its own file; sub-sections >40 lines extract into separate `View` structs in their own files (not computed properties returning `some View`). See `../figma-to-swiftui/references/swiftui-pro/views.md`.
- All generated screen views run the C3 Pass 4 swiftui-pro Review before declaring done.
```

## File 6: visual-fidelity.md update

§1 source-tag table thêm 1 cột "swiftui-pro route":

| Tag | Source | Example | swiftui-pro route |
|---|---|---|---|
| tokens | Figma variable | `--text-primary` | `Color(.textPrimary)` if `useGeneratedSymbols`, else `Color("textPrimary")` |
| inline | Figma node style | `font-weight: 700` | `.bold()` (api transform) |
| class | Figma component class | shared button style | Reuse via project's `ButtonStyle` |
| screenshot | Visual measurement | spacing 24px | `.padding(Spacing.l24)` if enum exists, else `.padding(24)` |

## Critical Files

- `/Users/minh/Desktop/WORK/figma-to-swiftui-skill/figma-to-swiftui/references/swiftui-pro/` (new dir, 9+1 files)
- `/Users/minh/Desktop/WORK/figma-to-swiftui-skill/figma-to-swiftui/references/swiftui-pro-bridge.md` (new)
- `/Users/minh/Desktop/WORK/figma-to-swiftui-skill/figma-to-swiftui/SKILL.md` (C1 audit + C2 rules + C3 Pass 4)
- `/Users/minh/Desktop/WORK/figma-to-swiftui-skill/figma-flow-to-swiftui-feature/SKILL.md` (§2 audit + §5 structural)

## Verification (sau khi edits land)

Test scenario: 1 Figma node với mix patterns sẽ trigger swiftui-pro:
- Bold text → check `.bold()` không `.fontWeight(.bold)`
- Rounded rect 12px → check `.clipShape(.rect(cornerRadius: 12))` không `.cornerRadius(12)`
- Icon-only close button → check có `accessibilityLabel("Close")` hoặc `Button("Close", systemImage:...)` form
- Decorative blob → check `Image(decorative:)` hoặc `.accessibilityHidden(true)`
- Top bar leading item → check `.topBarLeading`
- Toolbar item color → check `.foregroundStyle()` không `.foregroundColor()`

Steps:
1. Chạy skill như bình thường
2. Sau Phase C → đọc Pass 4 output, kỳ vọng `PASS:` cho mọi check
3. Inject 1 violation thủ công (vd. đổi `.bold()` thành `.fontWeight(.bold)`), chạy lại C3 Pass 4 → expect FAIL với line number cụ thể
4. C1 audit output phải in ra: `useGeneratedSymbols=<bool>`, `designConstants=[...]`, `deploymentTarget=...`, `localizationStyle=...` để trace decision

Negative tests:
- Project iOS 16 (no Tab API) → C2 fall back sang `tabItem()` form thay vì swiftui-pro's `Tab(...)`. Nên có conditional logic trong bridge.
- Project không có `enum Spacing` → C2 emit inline `.padding(24)` (compliant per swiftui-pro exception).

## Execution order

1. Copy 9 files vào `figma-to-swiftui/references/swiftui-pro/` + tạo SOURCE.md
2. Viết `swiftui-pro-bridge.md` (3 bảng + tension resolutions)
3. Sửa `figma-to-swiftui/SKILL.md`: C1 audit (5 mới), C2 critical rules block, C3 Pass 4
4. Sửa `figma-flow-to-swiftui-feature/SKILL.md`: §2 audit + §5 structural
5. Update `visual-fidelity.md` source-tag table với swiftui-pro route column
6. (Optional) Update `design-token-mapping.md` typography map cho Dynamic Type fits

## Open questions cho user — đã chốt

1. **iOS deployment target:** **iOS 16+**. Nhiều rule swiftui-pro phải có fallback (xem §"iOS 16 baseline" bên dưới).
2. **Localization:** **`Localizable.xcstrings`** (string catalog). C2 ưu tiên `Text(.symbolKey)` API, offer translate vào mọi language project hỗ trợ.
3. **Design constants enum:** chưa chốt — C1 audit grep và list ra. Nếu không có, route inline.
4. **Hook để enforce Pass 4:** **KHÔNG dùng hook.** Lý do: skill phải share được cho nhiều user qua git, hook config sẽ bắt mỗi user setup lại trong `.claude/settings.json`. Pass 4 enforce qua prompt-level (skill không tuyên bố `GATE: PASS` nếu chưa qua). User vẫn có thể tự thêm hook theo guide trong `figma-to-swiftui/SKILL.md` "Recommended hooks" section nếu họ muốn.

## iOS 16 baseline — fallback table cho swiftui-pro rules

Nhiều rule trong swiftui-pro (viết bởi Paul Hudson) giả định iOS 18/26. Với iOS 16+ baseline, một số rule phải condition theo `deploymentTarget`. Bridge doc (`swiftui-pro-bridge.md` §6) cần section "iOS 16 fallbacks" với bảng:

| swiftui-pro rule | API minimum | iOS 16 behavior |
|---|---|---|
| `Tab("...", systemImage:..., value:..)` (api.md L5) | iOS 18 | Fallback `tabItem { Label("...", systemImage: "...") }`. Codegen detect target và branch. |
| `.topBarLeading` / `.topBarTrailing` (api.md L11) | iOS 17 | Fallback `.navigationBarLeading` / `.navigationBarTrailing`. Comment marker `// iOS 16 fallback — switch to .topBarLeading at iOS 17+`. |
| `.clipShape(.rect(cornerRadius:))` (api.md L4) | iOS 17 (the `.rect(cornerRadius:)` shape literal) | Fallback `.clipShape(RoundedRectangle(cornerRadius: 12))`. Same intent, different shape API. |
| `@Entry` macro (api.md L9) | iOS 18 / Xcode 16 | Fallback manual `EnvironmentKey` + `EnvironmentValues` extension. |
| `@Observable` (data.md L11) | iOS 17 | Fallback `ObservableObject` + `@Published` + `@StateObject`/`@ObservedObject`. swiftui-pro disprefers this — but it is unavoidable on iOS 16. Document explicitly. |
| `@Bindable` (data.md L11) | iOS 17 | With `ObservableObject` fallback, use `@ObservedObject` and pass bindings via `$model.field`. |
| `WebView` native (api.md L15) | iOS 26 | Fallback `UIViewRepresentable` wrap of `WKWebView`. |
| `Image(.assetName)` symbol API (api.md L14) | Xcode 15+ project setting `GENERATE_ASSET_SYMBOLS = YES`, available on iOS 13+ runtime | ✓ Use directly — purely a build-time codegen. C1 audit gates this. |
| `Text(.symbolKey)` xcstrings symbol | Xcode 15+ + `extractionState: manual` | ✓ Use directly — purely build-time. Pair with `String Catalog Symbols` build setting. |
| `#Preview` macro (views.md L12) | Xcode 15+ runtime any | ✓ Use directly — preview runs in Xcode, not on device. |
| `containerRelativeFrame()` (api.md L7) | iOS 17 | Fallback `GeometryReader` (allowed since alternative not available). swiftui-pro rule yields. |
| `.scrollIndicators(.hidden)` (api.md L17) | iOS 16 | ✓ Use directly. |
| `bold()` modifier on views (design.md L27) | iOS 16 | ✓ Use directly. |
| `.foregroundStyle()` (api.md L3) | iOS 15 | ✓ Always. |
| `overlay(alignment:content:)` (api.md L10) | iOS 15 | ✓ Always. |
| `RoundedRectangle().fill().stroke()` chain (api.md L13) | iOS 17 | iOS 16 fallback: keep `.overlay { RoundedRectangle().stroke(...) }`. |
| `sensoryFeedback()` (api.md L8) | iOS 17 | iOS 16 fallback: `UIImpactFeedbackGenerator`. swiftui-pro rule yields. |
| `NavigationStack` (navigation.md L3) | iOS 16 | ✓ Use directly. |
| `navigationDestination(for:)` (navigation.md L4) | iOS 16 | ✓ Use directly. |
| `task()` modifier (performance.md L13) | iOS 15 | ✓ Always. |
| `LazyVStack`/`LazyHStack` | iOS 14 | ✓ Always. |
| `.font(.body.scaled(by:))` (accessibility.md L5) | iOS 26 | iOS 16 → `@ScaledMetric var fontSize: CGFloat = 16` + `.font(.system(size: fontSize))`. |
| `String Catalog Symbols` API (hygiene.md L8) | Xcode 15+ project setting | ✓ Use directly via `Text(.welcomeMessage)`. Build setting must be enabled. |

Decision rule: nếu `deploymentTarget < apiMinimum` → emit fallback path. Comment fallback bằng marker chuẩn để dễ search-replace khi project bump iOS:
```swift
// iOS 16 fallback — switch to <modern API> at iOS <N>+
```

## Multi-user / share-skill considerations

Skill này dùng cho nhiều user qua git. Yêu cầu:
1. **Tuyệt đối không bake hook vào `.claude/settings.json`** ở repo. User nào muốn enforce thì tự thêm — guide trong `figma-to-swiftui/SKILL.md` §"Recommended hooks" giữ nguyên.
2. **MCP config (`mcp.json`) là per-user.** Mỗi người tự setup `figma-assets` server theo hướng dẫn trong `mcpfigma-setup.md`. Skill chạy fallback `get_screenshot` nếu chưa setup.
3. **`figma-to-swiftui/references/swiftui-pro/` snapshot là tự chứa.** Không cần user clone repo gốc của Paul Hudson hay setup external path.
4. **Token (`FIGMA_ACCESS_TOKEN`) per-user.** Skill nhận diện qua probe; thiếu token = fall back `get_screenshot` + 1-line warning.
5. **Plan / docs / verification scripts** chỉ assume tools có sẵn trên macOS (bash, python3, file, sips, find, grep) — không deps thêm.

Giữ self-contained là ưu tiên cao hơn việc enforce strict.
