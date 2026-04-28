# Lottie Animation Placeholders (`eAnim*`)

Designer tags animation slots in Figma with the prefix `eAnim*`. These are not raster assets — they are placeholder frames where a Lottie animation will play at runtime. The skill generates a `LottieView` stub at the right place in the SwiftUI tree so the layout works immediately; the developer replaces the placeholder name with the real Lottie file name later.

This doc covers the contract end-to-end. Phase B detects `eAnim*` from `metadata.json`; Phase C2 codegens `LottieView`; Phase C4 verifies.

---

## 1. Why `eAnim*` is different from `eIC*` / `eImage*`

| Aspect | `eIC*` / `eImage*` | `eAnim*` |
|---|---|---|
| Source format | PNG raster | Lottie JSON (separate file added later) |
| Phase B path | Tagged path → `.imageset` | **None — no download, no xcassets entry** |
| Registry surface | `taggedAssets[]` | `lottiePlaceholders[]` |
| Phase B inventory row | `exporter: "tagged"` (or fallback) | `exporter: "fallback"`, `strategy: "lottiePlaceholder"` |
| Phase C2 SwiftUI | `Image("icAI<Name>")` | `LottieView(animation: .named("placeholder_animation"))` |
| Frame size | From parent frame | From parent frame (animation slot) |
| Asset on disk after Phase C | `Assets.xcassets/.../*.imageset/*.png` | None — Lottie JSON added by developer post-skill |

**Why the tagged path skips `eAnim*`:** rasterizing an animation frame would lose the motion. The designer's intent is "play a Lottie here," not "show this static frame." So the scanner stops at `eAnim*` and does not look at children — the children are usually a stack of static keyframes Figma uses for preview.

---

## 2. Detection (Phase A2 / B0)

`figma_build_registry` (called once in A2) returns `lottiePlaceholders[]` with each entry already validated:

```json
{
  "nodeId":    "3166:71000",
  "figmaName": "eAnimLoading",
  "width":     120,
  "height":    120
}
```

Skill no longer needs to walk `metadata.json` by hand — the tool does this. `registry.json` is the source of truth.

**Validation rules** (enforced by the tool):
- First character after `eAnim` must be ASCII uppercase: `eAnimLoading` ✅, `eAnimloading` ❌
- Remaining characters: `[A-Za-z0-9_]`
- Invalid name → entry lands in `registry.warnings[]` instead of `lottiePlaceholders[]`. Skill surfaces to user at end of Phase B.

---

## 3. Inventory row

Add one row to the Phase B inventory per `lottiePlaceholders[]` entry:

| # | Purpose | NodeId | Exporter | Strategy | Filename / Lottie name |
|---|---|---|---|---|---|
| 5 | Loading animation | 3166:71000 | fallback | lottiePlaceholder | placeholder_animation |

The tool returns this row in the manifest with `status: "done"` (no download was attempted), `exportName: null`, no `outputPath`/`sharedPath`/`imagesetPath`.

---

## 4. Manifest schema

A lottie-placeholder row in `manifest.rows`:

```json
{
  "nodeId":           "3166:71000",
  "exporter":         "fallback",
  "strategy":         "lottiePlaceholder",
  "status":           "done",
  "friendlyName":     "placeholder_animation",
  "exportName":       null,
  "outputPath":       null,
  "imagesetPath":     null,
  "xcassetsImported": false,
  "sharedPath":       null,
  "reason":           null
}
```

Plus skill-side metadata you can carry in the same row (not produced by the tool, set during B1/B2):
```json
{ "displaySize": "120x120", "loopMode": "loop" }
```

Notes:
- `friendlyName` is always `"placeholder_animation"` until the developer updates it. The skill does NOT try to infer the real name.
- `displaySize` comes from `registry.lottiePlaceholders[].width / .height` (points).
- `loopMode` defaults to `"loop"`. If the designer specifies otherwise in the node name (e.g. `eAnimLoadingOnce`), that's a future extension — for now always `"loop"`.

---

## 5. Phase B gates

`eAnim*` rows do NOT need a PNG on disk and do NOT need an `.imageset`. Gate B treats `strategy == "lottiePlaceholder"` as a no-op for the file-on-disk and PNG-validity checks.

---

## 6. Phase C2 — codegen

When the implementer reaches a placeholder row in inventory order, emit:

```swift
import Lottie  // add at top of file if missing

LottieView(animation: .named("placeholder_animation"))
    .playing(loopMode: .loop)
    .frame(width: <displayW>, height: <displayH>)
    // TODO: replace "placeholder_animation" with the real Lottie file name from designer.
    // Add the .json to the app bundle (drag into Xcode, "Copy items if needed").
```

Rules:
- Always use the literal `"placeholder_animation"` string. Do not derive from `eAnimLoading` → `"loading"` etc. — that lies to the developer.
- Always emit the `// TODO:` comment block right after the modifier chain.
- `import Lottie` goes at the top of the file (insert if missing). If multiple placeholders are in the same file, only one `import Lottie` is needed.
- If the project already has a Lottie wrapper (audit in C1, e.g. `IKLottieView`, `AnimatedView`), prefer the wrapper and pass `name: "placeholder_animation"` per its API. Default to raw `LottieView` from `lottie-ios` 4.x when no wrapper exists.

**Frame sizing:** read `displaySize` from the manifest row. Always set `.frame(width:height:)` explicitly — don't rely on intrinsic size of an empty Lottie view (it'd be zero).

**Loop mode:** default `.loop`. Other modes in the future may be inferred from designer naming convention; for now `loop` everywhere.

---

## 7. Phase C4 verification

Lottie placeholders are not assets, so C4 has nothing to copy. Add a verification bash check alongside the existing `Image("...")` orphan scan:

```bash
PLACEHOLDERS=$(python3 -c "
import json
m = json.load(open('.figma-cache/<nodeId>/manifest.json'))
for r in m.get('rows', []):
    if r.get('strategy') == 'lottiePlaceholder':
        print(r['nodeId'])
")
SWIFT_FILES="<your-generated-swift-files>"
for nid in $PLACEHOLDERS; do
  HITS=$(grep -nE 'LottieView\(animation: \.named\("placeholder_animation"\)\)' $SWIFT_FILES | wc -l)
  if [ "$HITS" -eq 0 ]; then
    echo "FAIL: lottie placeholder for $nid not in any view"
  fi
done

# Optional: warn if any placeholder name was changed (developer started replacing)
NON_PLACEHOLDER=$(grep -nE 'LottieView\(animation: \.named\("[^"]+"\)\)' $SWIFT_FILES \
                  | grep -v 'placeholder_animation')
if [ -n "$NON_PLACEHOLDER" ]; then
  echo "INFO: real Lottie names already in code (developer replaced placeholders):"
  echo "$NON_PLACEHOLDER"
fi
```

The skill's first run should produce only `placeholder_animation` strings; any real animation names indicate the developer has begun replacing.

---

## 8. Tell the user what to do next

After the run, explicitly surface the placeholder list so the developer doesn't forget to swap them. End-of-run summary template:

```
# Lottie placeholders to wire up

The skill generated <N> Lottie placeholders with the constant name "placeholder_animation".
Each needs a real Lottie .json file before the feature ships.

| Source nodeId | Figma name      | Frame    | File:Line  |
|---------------|-----------------|----------|------------|
| 3166:71000    | eAnimLoading    | 120x120  | LoginView.swift:42 |
| 3166:71050    | eAnimSuccess    | 80x80    | LoginView.swift:78 |

Next steps:
1. Get the .json from the designer (or lottiefiles.com)
2. Drag into Xcode (Copy items if needed)
3. Replace "placeholder_animation" with the asset's filename (without .json)
4. Adjust loopMode if needed (.playOnce, .autoReverse, etc.)
```

---

## 9. Edge cases

- **Lottie SDK not in project.** Skill audits in C1 (project pre-flight). If `import Lottie` would fail, surface to the user before C2: *"Lottie SDK not detected — add `lottie-ios` (Airbnb) via SPM or CocoaPods, or convert these placeholders to static images."* Do NOT auto-install.
- **Custom wrapper preferred.** If C1 audit finds an existing wrapper (e.g. `IKLottieView(name: "...")`), use it. The placeholder name string stays `"placeholder_animation"`.
- **Designer ships `eAnim*` inside a flattened parent.** The flatten parent will export as a static raster (which freezes the animation in one frame — not ideal, but unavoidable for `get_screenshot`). The placeholder `LottieView` overlays in `ZStack` on top. Document this tradeoff with the user; usually the designer should pull the animation out of any flatten region.
- **Many placeholders in the same view.** Only one `import Lottie` needed at the top of each file. Verify with a single grep, not per-row.
- **Gate B re-runs.** Placeholder rows are pure metadata — no PNG to lose. Re-run is idempotent at zero cost.

---

## 10. Designer-side rules (mirror in `docs/designer-handoff.md` §9.5)

- Tag animation slots with `eAnim<Name>` (UpperCamel after the prefix).
- The frame containing the `eAnim*` node defines the animation's display size.
- Children of an `eAnim*` node are ignored by the skill — they're treated as preview keyframes for the designer's benefit only. Do not nest interactive UI inside an animation slot.
- One animation = one `eAnim*` node. If the same animation plays in multiple screens, that's fine — both screens get a `LottieView` placeholder; the developer wires both to the same Lottie file.
