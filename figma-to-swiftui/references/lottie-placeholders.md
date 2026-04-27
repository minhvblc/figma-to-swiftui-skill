# Lottie Animation Placeholders (`eAnim*`)

Designer tags animation slots in Figma with the prefix `eAnim*`. These are not raster assets — they are placeholder frames where a Lottie animation will play at runtime. The skill generates a `LottieView` stub at the right place in the SwiftUI tree so the layout works immediately; the developer replaces the placeholder name with the real Lottie file name later.

This doc covers the contract end-to-end. Phase B detects `eAnim*` from `metadata.json`; Phase C2 codegens `LottieView`; Phase C4 verifies.

---

## 1. Why `eAnim*` is different from `eIC*` / `eImage*`

| Aspect | `eIC*` / `eImage*` | `eAnim*` |
|---|---|---|
| Source format | PNG raster | Lottie JSON (separate file added later) |
| Phase B path | MCPFigma `figma_export_assets` → `.imageset` | **None — no download, no xcassets entry** |
| MCPFigma scanner | Surfaces in `matches` | Skipped (does NOT recurse into children) |
| Phase B inventory row | `exporter: "mcpfigma"` (or fallback) | `exporter: "none"`, `kind: "lottie-placeholder"` |
| Phase C2 SwiftUI | `Image("icAI<Name>")` | `LottieView(animation: .named("placeholder_animation"))` |
| Frame size | From parent frame | From parent frame (animation slot) |
| Asset on disk after Phase C | `Assets.xcassets/.../*.imageset/*.png` | None — Lottie JSON added by developer post-skill |

**Why MCPFigma skips `eAnim*`:** rasterizing an animation frame would lose the motion. The designer's intent is "play a Lottie here," not "show this static frame." So MCPFigma's scanner stops at `eAnim*` and does not look at children — the children are usually a stack of static keyframes Figma uses for preview.

---

## 2. Detection (Phase B Step B0)

After the `figma_list_assets` probe, scan `metadata.json` for nodes whose name starts with `eAnim`. These appear in `metadata.json` (which lists every node) but are absent from `figma_list_assets.matches` (which intentionally skips them).

Reference pseudocode:

```python
import json, re
meta = json.load(open(".figma-cache/<nodeId>/metadata.json"))

def walk(node, out):
    name = node.get("name", "")
    if re.match(r"^eAnim[A-Z]", name):
        out.append({
            "sourceNodeId": node["id"],
            "figmaName":    name,
            "kind":         "lottie-placeholder",
            "frame":        node.get("absoluteBoundingBox"),  # width/height
        })
        return  # do NOT recurse — children are preview keyframes
    for child in node.get("children", []):
        walk(child, out)

placeholders = []
walk(meta, placeholders)
```

Persist to `.figma-cache/<nodeId>/lottie-placeholders.json` so Phase C2 can read without re-scanning.

**Validation rules** (mirror MCPFigma's tagged-asset rules):
- First character after `eAnim` must be ASCII uppercase: `eAnimLoading` ✅, `eAnimloading` ❌
- Remaining characters: `[A-Za-z0-9_]`
- Invalid name → log warning, do NOT generate a row. Surface to user once at end of Phase B.

---

## 3. Inventory row

Add one row to the Phase B inventory per detected `eAnim*` node:

| # | Purpose | NodeId | Tagged | Strategy | Exporter | Filename / Lottie name |
|---|---|---|---|---|---|---|
| 5 | Loading animation | 3166:71000 | n/a | lottie-placeholder | none | placeholder_animation |

`Exporter = none`, `Strategy = lottie-placeholder`. No PNG, no xcassets entry.

---

## 4. Manifest schema

A lottie-placeholder row in `manifest.assetList`:

```json
{
  "sourceNodeId":  "3166:71000",
  "figmaName":     "eAnimLoading",
  "tagged":        false,
  "exporter":      "none",
  "kind":          "lottie-placeholder",
  "lottieName":    "placeholder_animation",
  "displaySize":   "120x120",
  "loopMode":      "loop",
  "status":        "done"
}
```

Notes:
- `lottieName` is always `"placeholder_animation"` until the developer updates it. The skill does NOT try to infer the real name.
- `displaySize` comes from the parent frame's bounding box (width × height in points).
- `loopMode` defaults to `"loop"`. If the designer specifies otherwise in the node name (e.g. `eAnimLoadingOnce`), that's a future extension — for now always `"loop"`.

---

## 5. Phase B gates

`eAnim*` rows do NOT need a PNG on disk and do NOT need an `.imageset`. The Gate B bash already loads paths from manifest and only fails when `outputPath`, `sharedPath`, and `friendlyName.png` are all missing — for placeholder rows, none of those keys are set, but the gate must not flag them as missing.

The Gate B bash should treat `kind == "lottie-placeholder"` as a no-op for the file-on-disk and PNG-validity checks. The single-screen SKILL.md gate already has a guard; verify it explicitly skips placeholder rows.

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
for a in m['assetList']:
    if a.get('kind') == 'lottie-placeholder':
        print(a['sourceNodeId'])
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
