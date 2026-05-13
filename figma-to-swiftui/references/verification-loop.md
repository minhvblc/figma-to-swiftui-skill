# Verification Loop

Self-check loops, gates, and visual diff procedures for C3 Pass 2 + C5 + C6 + C7.

## Canonical gate letters (C3 Pass 2)

18 letters cover every visible attribute. Each gate row carries one letter:

| Letter | Meaning |
|---|---|
| **LH** | Line height |
| **LS** | Letter spacing (tracking) |
| **SH** | Shadow (drop / inner) |
| **BD** | Border / stroke |
| **OP** | Opacity |
| **RM** | Rendering mode (template / original) |
| **IS** | Icon size |
| **AL** | Text alignment + fill-width rect (parent-aware, see §4.0) |
| **DV** | Divider / separator |
| **BG** | Background (solid / gradient / image) |
| **TR** | Tracking on Text |
| **GR** | Gradient (linear / radial / angular) |
| **SA** | Safe area handling |
| **CH** | System chrome (status bar / home indicator) — banned |
| **PD** | Padding (per edge) |
| **BS** | Border radius / shape |
| **IF** | Image fill mode (resizable + content mode + frame) |
| **SS** | Spacing-safe-area normalization (mockup frame y-adjust) |

`scripts/c3-pass2-prefill.sh` writes 9 mechanical rows (CH, PD, GR, DV, BG, TR, SA, BS, SS) + 9 TODO rows for Figma-grounded checks.

---

## 1. C3 Pass 2 — Diff Report Template

Write to `.figma-cache/<nodeId>/c3-pass2-diff.md`:

```markdown
nodeId: <id>
attempt: <N>

## Checklist coverage
- Every letter from §"Canonical gate letters" must appear in at least one Findings row.
- Minimum 15 rows total. Cover every section of the screen.
- One N/A row per absent feature, with reason.

## Findings

| # | Check | Section | Figma Spec | Source quote | Code value | File:Line | Match | Severity | Note |
|---|-------|---------|------------|--------------|------------|-----------|-------|----------|------|
| 1 | LH    | title   | line height 34 | `design-context.md L42 \`leading-[34px]\`` | `.lineSpacing(6)` | OnboardingScreen.swift:23 | PASS | - | 34 - 28 = 6 |
| 2 | RM    | close-icon | template (single-color) | `inventory row 1: renderingMode=template` | `.renderingMode(.template).foregroundStyle(...)` | OnboardingScreen.swift:41 | PASS | - | - |
| 3 | CH    | top      | no status bar redraw | `SKILL ABSOLUTE RULE` | (no FakeStatusBar in code) | - | PASS | - | - |
| 4 | SH    | -        | n/a — no shadow on screen | - | - | - | N/A | - | - |
...

## Summary
| HIGH FAILS | MEDIUM FAILS | LOW FAILS | PASS | N/A | TOTAL |
|------------|--------------|-----------|------|-----|-------|
| 0          | 2            | 1         | 12   | 3   | 18    |
```

---

## 2. Severity Rubric

| Severity | Definition | Examples |
|---|---|---|
| `high` | Visible mismatch a user notices immediately. Drives self-fix loop. | Wrong font size, missing line-height, missing shadow, wrong icon size >2pt, wrong renderingMode, drawing system chrome, `Image(systemName:)` substituting Figma asset, missing border, wrong corner radius >2pt |
| `medium` | Off-by-small. Breaks pixel parity. | Padding/spacing off 1-2pt, opacity off 0.05, gradient stop position off ≤10% |
| `low` | Cosmetic / ambiguous. Reported but never retried. | Line limit unclear from screenshot, alignment ambiguous on single-line text |
| `N/A` | Element absent on screen. Reason required. | "no divider", "no gradient" |

Self-fix loop triggers on `high` only by default. If `medium > 2`, also trigger.

**Match column is ternary** (`PASS` / `FAIL` / `N/A`). "PASS with caveat" / "PASS-ish" / "PASS — minor" is BANNED — collapse to FAIL at appropriate severity. Writing `Match=PASS` + Note "position slightly off vs Figma; minor" is a graded protocol violation: inflates PASS count, hides distribution, prevents loop from running. This is the most common way Pass 2 lies to itself.

---

## 3. Source Quote Rules (anti-hallucination)

The `Source quote` column is the anti-hallucination lever — without it, the agent could fabricate 15 plausible rows from imagination.

Rules:
1. **Verbatim only.** Copy exact characters from `design-context.md` between backticks. No paraphrase, no normalization.
2. **Cite the line:** `design-context.md L42 \`...\``.
3. Inventory rows are valid sources: `inventory row N: renderingMode=template`.
4. N/A rows: write reason in Section column, source can be `-`.
5. CH rows: source is `SKILL ABSOLUTE RULE`.

Gate verifies ≥50% of quoted strings appear in `design-context.md`. The 50% threshold accommodates inventory-sourced quotes.

**Backtick scope:** gate ONLY scans the `Source quote` column. Backticks elsewhere are decorative. Markdown's escape for `|` inside cells is `\|` — needed when Code value contains a pipe.

---

## 4. Self-Fix Loop

### 4.0 Prefill (recommended)

```bash
bash ~/.claude/scripts/c3-pass2-prefill.sh <nodeId>
```

Emits the report with 9 mechanical rows decided + 9 TODO rows for the Figma-grounded checks. Agent fills TODO rows. Refuses to overwrite an existing report unless `--force`. Saves ~30-50% Phase C tokens on multi-screen flows.

Key TODO checks:
- **AL** (text alignment): for any Text with Figma `textAlignHorizontal=CENTER/RIGHT/JUSTIFIED` AND fill-width layout, verify code emits BOTH `.multilineTextAlignment(...)` AND a fill-width drawing rect. Drawing rect on the right layer (Text directly when parent is non-Button stack; Button's OUTER frame when parent is `Button { }`). Common bug: `.multilineTextAlignment(.center)` alone with no fill-width rect → Text hugs intrinsic width, alignment invisible.
- **IF** (image fill mode): for every Image filling its parent, verify `.resizable() + (.scaledToFill() | .scaledToFit()) + .frame(...)` — all three.
- **SS** (safe-area normalization): screen-root `.padding(.top, N)` where N ∈ {44, 47, 59, 64, 67, 79, 88} requires `// safe-area-adjusted: ...` comment.
- **BW** (button width source-of-truth): button width MUST come from Figma `primaryAxisSizingMode` applied on Button's OUTER frame. FILL → `.frame(maxWidth: .infinity)` on outer (no maxWidth on inner Text/HStack); FIXED → `.frame(width: W)` on outer; AUTO/HUG → no width modifier.

### 4.1 Gate C3-Pass2

```bash
CACHE=".figma-cache/<nodeId>"; REPORT="$CACHE/c3-pass2-diff.md"; DESIGN_CTX="$CACHE/design-context.md"
SWIFT_FILES="<your-generated-swift-files>"; FAIL=0

# Report exists
[ -s "$REPORT" ] && echo "PASS: report" || { echo "FAIL: $REPORT missing"; FAIL=1; }

# Structure
grep -q '^nodeId:' "$REPORT" && grep -q '^attempt:' "$REPORT" \
  && grep -q '^## Findings' "$REPORT" && grep -q '^## Summary' "$REPORT" \
  && echo "PASS: structure" || { echo "FAIL: missing sections"; FAIL=1; }

# Row count ≥ 15
ROW_COUNT=$(grep -cE '^\| *[0-9]+ *\|' "$REPORT")
[ "${ROW_COUNT:-0}" -ge 15 ] && echo "PASS: $ROW_COUNT rows" \
  || { echo "FAIL: only $ROW_COUNT rows (need >=15)"; FAIL=1; }

# Anti-hallucination: ≥50% quotes match design-context.md (python parser)
QUOTES_INFO=$(python3 - "$REPORT" "$DESIGN_CTX" <<'PY'
import re, sys
from pathlib import Path
report, ctx = sys.argv[1], sys.argv[2]
ctx_text = Path(ctx).read_text(errors='replace')
quotes = []
for line in Path(report).read_text(errors='replace').splitlines():
    if not re.match(r'^\|\s*\d+\s*\|', line): continue
    cells = re.split(r'(?<!\\)\|', line)
    if len(cells) < 6: continue
    quotes.extend(re.findall(r'`([^`]+)`', cells[5]))   # Source quote column only
total = len(quotes); hits = sum(1 for q in quotes if q in ctx_text)
pct = (hits * 100 // total) if total else 100
print(f"{hits} {total} {pct}")
PY
)
read HIT TOT PCT <<< "$QUOTES_INFO"
if [ "${TOT:-0}" -gt 0 ]; then
  [ "${PCT:-0}" -ge 50 ] && echo "PASS: ${PCT}% quotes ($HIT/$TOT)" \
    || { echo "FAIL: only ${PCT}% match ($HIT/$TOT)"; FAIL=1; }
fi

# Surface high FAIL count (drives loop)
HIGH_FAILS=$(grep -cE '\| *FAIL *\| *high *\|' "$REPORT")
echo "INFO: $HIGH_FAILS high-severity FAIL rows"

[ $FAIL -eq 0 ] && echo "GATE: PASS (C3 Pass 2)" || echo "GATE: FAIL (C3 Pass 2 — report invalid)"
```

### 4.2 Loop pseudocode

Default `MAX_RETRIES=2`. User overrides with `max 3 retries`.

1. Run Pass 2 → write `c3-pass2-diff.md` → run Gate (§4.1).
2. **Gate FAIL** → regen report (no code edits, no counter bump). After 2 consecutive regen failures, ASK user.
3. **Gate PASS, `HIGH_FAILS > 0`:**
   - `count=$(cat $CACHE/c3-retry-count 2>/dev/null || echo 0)`
   - If `count >= MAX_RETRIES`: STOP. Report remaining FAIL rows.
   - Else: snapshot `cp c3-pass2-diff.md c3-pass2-diff.attempt-$((count+1)).md`, append `HIGH_FAILS` to `manifest.verification.c3Pass2.highFailsHistory`, increment counter, edit ONLY cited file:line (no refactoring), re-run.
4. **Asymptote check** (before each retry): if `highFailsHistory` not strictly decreasing → exit early.
5. **Gate PASS, no high, `medium <= 2`** → reset counter, proceed to Pass 3.
6. `medium > 2` → step 3 limited to medium rows.

User abort phrases (`stop fixing`, `ship as-is`) → mark `manifest.verification.c3Pass2.lastResult = "user_override"`.

State storage:
- `.figma-cache/<nodeId>/c3-retry-count` — single integer
- `c3-pass2-diff.md` — current report; `c3-pass2-diff.attempt-N.md` — snapshots
- `manifest.json → verification.c3Pass2.{lastAttempt, lastResult, highFailsHistory}`

### 4.3 Pass 3 / 3b — explicit fallback

Fast path: `bash ~/.claude/scripts/c3-static-checks.sh --files "<paths>"`. Below is the explicit form when the script isn't available:

```bash
SWIFT_FILES="<your-generated-swift-files>"

# Pass 3 — Asset substitution
HITS=$(grep -rnE 'Image\(systemName:' $SWIFT_FILES)
[ -z "$HITS" ] && echo "PASS: no SF Symbol substitution" \
  || { echo "FAIL: SF Symbol where Figma asset expected:"; echo "$HITS"; }

# Pass 3b — System chrome redraws
grep -rnE 'Text\("9:41"\)|FakeStatusBar|HomeIndicator|NotchView|DynamicIslandView|StatusBarView' $SWIFT_FILES
grep -rnE 'Capsule\(\)\..+\.frame\([^)]*height:\s*[1-6][^0-9]' $SWIFT_FILES
```

---

## 4b. L2 Token Trace (static — Tier-1, mandatory)

C5 (build + simulator/render) is expensive: subjective compare, 15-30K tokens/screen, 30-90s sim cold start. L2 trace is the **deterministic** static counterpart — every value in the generated Swift file traces to a Figma source or fails.

L2 is **mandatory** alongside C5 in Tier-1. Either gate passing satisfies stop-gate Done-Gate (`(a) C5 PASS, OR (b) L2 PASS, OR (c) system-skip reason`).

### Inputs (all already exist after Phase A+B+C2)

| File | Source | Used for |
|---|---|---|
| `.figma-cache/<nodeId>/c2-audit.json` | L1 PostToolUse hook auto-emits on every Write/Edit of `*Screen.swift` / `*View.swift` | Rows from generated code: color/font/padding/frame/image/text/stack/**safearea** |
| `tokens.json` | A3 `figma_extract_tokens` | Color swiftName, typography preset, spacing/radius values |
| `design-context.md` | A3 `get_design_context` | Verbatim hex, Tailwind classes, text content |
| `metadata.json` | A3 `get_metadata` | Frame bbox for `.frame(w,h)` tracing |
| `manifest.json` | A3+/B3 `figma_export_assets_unified` | `manifest.rows[].exportName` for `Image(.X)` tracing |
| `fills.json` | A3 `figma_extract_fills` | Source for per-node gradient stop comparison (via c2-fills-stops.json) |
| `c2-typography-perline.json` | Gate A `c2-typography-extract.sh` | Per-text-segment typography (leading/tracking/fontWeight from Tailwind classes); used by L2 to PASS/FAIL `.lineSpacing` / `.tracking` / `.kerning` / `.fontWeight` modifiers via `value.textHint` |
| `c2-fills-stops.json` | Gate A `c2-fills-stops-index.sh` | Per-`nodeId` gradient stop list (color + position + opacity); used by L2 for `.background(LinearGradient(...))` rows that carry `// Figma: <nodeId>` |

### Run

```bash
bash ~/.claude/scripts/c3-driver.sh trace --cache .figma-cache/<nodeId>
bash ~/.claude/scripts/c3-driver.sh aggregate --cache .figma-cache/<nodeId>
```

`trace` invokes `c3-token-trace.sh` and writes `c3-trace.md` + `c3-trace.json`. `aggregate` reads all layer artifacts and writes `c3-gate.json` with the final `GATE: PASS|FAIL`.

### Match rules (soft tolerance, ±2pt frame/padding/spacing)

| Kind | Match against | Tolerance |
|---|---|---|
| `color` (tokenRef) | `tokens.json.colors[].swiftName` (exact) | 0 |
| `color` (literal hex) | hex string VERBATIM in `design-context.md` | 0 |
| `font` (preset) | preset name in typography whitelist OR `tokens.json.typography[].swiftName` | 0 |
| `font` (size+weight) | tuple in `tokens.json.typography[]` matching exact size + weight | 0 |
| `padding`/`spacing` | `tokens.json.spacing[]` OR Tailwind `p-N`/`gap-N` (4×N pt) in design-context.md | ±2pt |
| `frame` (w/h) | metadata.json node `absoluteBoundingBox` (any node, both dims match) | ±2pt |
| `image` (assetRef) | `manifest.rows[].exportName` or `friendlyName` (exact) | 0 |
| `stack.spacing` | `tokens.json.spacing[]` OR Tailwind `gap-N` | ±2pt |
| `text` (literal) | substring in `design-context.md` OR `Strings.<Screen>.<key>` reference | 0 |

### Coverage gate (anti-silent-pass)

L2 emits `GATE: FAIL` when:
- `parserMode` is `"missing"` or `"regex-fallback"` (figma-audit binary failed) → `PARSER_DEGRADED`
- Per-file `unknownModifierCount > 3` (parser couldn't classify too many modifiers) → block
- Any FAIL row in trace

Override: set `manifest.json.verification.c3.layers.l1.acceptUnknown = true` (explicit risk acceptance).

### Self-fix loop semantics

L2 is **deterministic** — same audit + same Figma artifacts → same trace. Wedge detection:

```
if iteration > 0 and L2_FAILS[i] >= L2_FAILS[i-1] and no_cited_file_was_edited:
    ASK_USER (wedged)
```

Default `MAX_RETRIES = 2`. Each iteration: fix the file:line cited in FAIL rows (use the **Suggested** column), Write/Edit the file → PostToolUse hook re-emits audit → re-run trace.

### Skill how-to (per-screen)

After C2 write (and Phase B done), do this **before** C5:

```bash
bash ~/.claude/scripts/c3-driver.sh trace --cache .figma-cache/<nodeId>
# If GATE: FAIL with suggestions → fix file:line, repeat
# If GATE: PASS → move to C5 (or skip C5 in Tier-1 default when L2 PASS)
bash ~/.claude/scripts/c3-driver.sh aggregate --cache .figma-cache/<nodeId>
```

`c3-gate.json` is what the stop-gate hook reads to release Done-Gate.

### What L2 does NOT cover (delegate to L3/C5)

L2 is structural + token-level only. The following live in L3 (focused LLM judge, Phase 2) or C5 (sim render):
- Shadow blur radius / offset / color
- Gradient angle / center / transform (per-stop colors + positions ARE checked when `// Figma: <nodeId>` is present — see §4b.2)
- Text alignment in compound layouts (Button { HStack {...} })
- Blend mode, opacity stacking
- Border-radius shape semantics (Capsule vs RoundedRectangle on non-square)
- Composite button internal layout (icon-text spacing)

When L2 row is `kind: color, owner: shadow|opacity|blendMode` it auto-marks `N/A` — these axes pass through to L3.

### §4b.1 — Typography per-line (new)

`c2-typography-extract.sh` walks `design-context.md` as JSX, attributes each text-bearing element to its enclosing class stack, and resolves Tailwind typography utilities into normalized values per text segment:

| Tailwind class | Resolved field | Units |
|---|---|---|
| `text-xs ... text-9xl` or `text-[14px]` | `fontSize` | pt |
| `font-light ... font-black` | `fontWeight` | SwiftUI weight keyword |
| `leading-tight ... leading-loose` or `leading-[1.4]` | `leading` | ratio (or pt for `leading-[Npx]`) |
| `tracking-tighter ... tracking-widest` or `tracking-[-0.5px]` | `tracking` | em (auto-converted to pt via fontSize) or pt |
| `uppercase` / `lowercase` / `capitalize` | `textCase` | enum |
| `italic` / `not-italic` | `italic` | bool |
| `text-left ... text-justify` | `textAlign` | enum |

L1 audit attaches `value.textHint` to every `font`/`fontWeight`/`tracking`/`kerning`/`lineSpacing` row by walking down the modifier chain to the closest `Text("…")` literal. L2 looks up `byTextNormalized[hint]` and:

- `.lineSpacing(N)` — flag obvious mismatch (Tailwind `leading-tight` (1.25) paired with `.lineSpacing(>=6)` → FAIL); compatible otherwise.
- `.tracking(N)` / `.kerning(N)` — convert Tailwind em-tracking to pt via fontSize, compare ±0.5pt.
- `.fontWeight(.X)` — string equality against Tailwind weight keyword.

When the per-line map has no entry for the textHint, row degrades to N/A (safe — no false positive).

### §4b.2 — Gradient stops (new)

`c2-fills-stops-index.sh` flattens `fills.json` into `byNodeId[<id>] → [{type, opacity, stops:[{pos, hex, opacity}]}]`. L2 looks up the gradient row's `nodeIdHint` (set via `// Figma: <id>` trailing comment on the `.background(...)` line) and:

- Verifies the matching node has a GRADIENT_* fill (not SOLID — `FAIL` with type mismatch detail).
- Surfaces the stop list in the PASS reason: `fills-stops nodeId X has 3-stop gradient: [#1a1a1a@0.00,#ffffff@0.50,#0066ff@1.00]`.

Stop-by-stop comparison against Swift `LinearGradient(stops:)` literals is a future enhancement — for now Pass 2 visual diff catches stop divergence. Adding `// Figma: <nodeId>` to gradient lines is recommended (single-source-of-truth comment).

### §4b.3 — Safe-area + nav-bar placement gate (L2.5, new)

Separate sub-gate. Reads `kind: "safearea"` / `kind: "navbar"` / `kind: "stack"` rows from `c2-audit.json` (emitted for `.ignoresSafeArea` / `.safeAreaInset` / `.safeAreaPadding` / `.toolbar` / `.toolbarVisibility` / `.navigationBarHidden` / `.navigationTitle` / `.navigationBarTitleDisplayMode` plus `NavigationStack` / `NavigationView` constructors) and checks placement rules from layout-translation.md + AP-16 + AP-17. See [`anti-patterns.md`](anti-patterns.md) §AP-16 / §AP-17 for the rule rationale + fix recipe.

Run via `c3-driver.sh safearea` (also called from `aggregate`). FAIL violations:
- **SA-1** — `.ignoresSafeArea` on content container (`ScrollView`/`VStack`/`HStack`/`ZStack`/`List`/`Form`/`LazyVStack`/`NavigationStack`/`TabView`). Allowed only on background primitives (`Color`/`Image`/`Rectangle`/`RoundedRectangle`/`Capsule`/`Ellipse`/`Circle`/`LinearGradient`/`RadialGradient`/`AngularGradient`/`EllipticalGradient`/`MeshGradient`).
- **SA-2** — root `.frame(maxHeight: .infinity)` with zero safearea rows in the file. Override: `// allow-fullbleed-noinset: <reason>` on the `.frame` line.
- **SA-3 (WARN)** — `.safeAreaInset` on a background primitive (likely belongs on the screen-root container).
- **NB-1** — file wraps content in `NavigationStack`/`NavigationView` but has zero nav-bar visibility modifiers (`.toolbar(.hidden, for: .navigationBar)` / `.navigationTitle(...)` / `.toolbarVisibility(...)` / `.navigationBarHidden(...)`). **FAIL** on `*Screen.swift` (single-screen pattern where Figma custom top bar is the strong default), **WARN** elsewhere (App/Router files legitimately host the root NavigationStack without a toolbar — child views own that). Override: `// nav-bar-intentional: <reason>` comment on the NavigationStack line.

---

## 5. C5 Simulator Workflow

**C5 is mandatory.** Runs after Gate C3-Pass2 PASSes. No user opt-out phrases. Skip only on 4 system reasons:
- `no_project` — no `.xcodeproj`/`.xcworkspace` after walking up 3 levels
- `simctl_error` — `xcrun simctl` errors, missing runtime
- `ci_environment` — `CI=true`/`GITHUB_ACTIONS=true`
- `no_entry_path` — screen not launch screen, no `#Preview`/scheme/test entry, no driver. **Adding launch-arg / env-var route override is BANNED** (entry-bypass-gate hook blocks).

User phrases `skip C5` / `bỏ qua C5` / `không cần build` NOT honored.

### Engine A (xcode MCP — Xcode 26+ default)

`scripts/c5-engine-select.sh` deterministically picks Engine A when xcrun mcpbridge available + Xcode running + screen has `#Preview`. Engine A bypasses SPM resolve hang + simctl cold start.

1. `mcp__xcode__XcodeListWindows` → pick window
2. `mcp__xcode__BuildProject` with scheme. Errors → `XcodeListNavigatorIssues` / `GetBuildLog`. FAIL high → self-fix loop.
3. `mcp__xcode__RenderPreview` on the `*Screen.swift` with `#Preview { }` → `c5-render.png`
4. C5.6 procedure runs unchanged

**Banned:** Engine A is NOT a route-override bypass. RenderPreview renders pure `#Preview` content. No `#if DEBUG` deep-link / launch-arg env-var. If screen has no `#Preview`, fall back to Engine B (legitimate skip path).

### Engine B (xcodebuild + simctl)

**C5.1 — Detect scheme.** `xcodebuild -list`. 1 scheme → use; N>1 → ASK user, stash; 0 → `manifest.verification.c5.skipped = "no_project"`.

**C5.2 — Pick simulator.**
```bash
xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devs in data['devices'].items():
    if 'iOS' not in runtime: continue
    for d in devs:
        if d['state'] == 'Booted' or 'iPhone' in d['name']:
            print(f\"{d['udid']} {d['name']} ({runtime.split('.')[-1]})\")
"
```
Prefer Booted iPhone; else highest-iOS iPhone 15/16. Stash UDID.

**C5.3 — Build (with fast-fail).**
```bash
LOG=".figma-cache/<nodeId>/c5-build.log"
( xcodebuild -scheme "$SCHEME" -destination "platform=iOS Simulator,id=$UDID" \
    -configuration Debug -derivedDataPath ".figma-cache/<nodeId>/derived" build 2>&1 ) \
  | tee "$LOG" | awk '
      /^[[:space:]]*error:/        { print; exit 0 }
      /BUILD FAILED/               { print; exit 0 }
      /^\*\* BUILD SUCCEEDED \*\*/ { print; exit 0 }
      { print }
    '
```
On build failure: parse last 50 lines for compile errors. Surface each as FAIL high row in `c5-visual-diff.md` (Section: `build`). Self-fix loop. Do NOT install.

**C5.4 — Boot / install / launch.**
```bash
xcrun simctl boot "$UDID" 2>/dev/null
APP_PATH=$(find ".figma-cache/<nodeId>/derived/Build/Products/Debug-iphonesimulator" -name "*.app" -maxdepth 2 | head -1)
xcrun simctl install "$UDID" "$APP_PATH"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist")
xcrun simctl launch "$UDID" "$BUNDLE_ID"
open -a Simulator
```
Wrong default screen → ASK user once for `previewEntry`, stash. Reuse on re-runs.

**C5.5 / C5.5b — Capture + comparison-safe pair.**

Fast path: `bash ~/.claude/scripts/c5-capture.sh --cache .figma-cache/<nodeId> --udid <udid>` (handles 2s settle + screenshot + PNG validation + long-side ≤2000px shrink for both pair members).

Explicit form:
```bash
sleep 2
xcrun simctl io "$UDID" screenshot ".figma-cache/<nodeId>/c5-simulator.png"
# Claude many-image API rejects >2000px long-side. iPhone-native captures break this.
LONG=$(sips -g pixelWidth -g pixelHeight ".figma-cache/<nodeId>/c5-simulator.png" \
       | awk '/pixel(Width|Height)/ {print $2}' | sort -n | tail -1)
[ "$LONG" -gt 2000 ] && sips -Z 2000 ".figma-cache/<nodeId>/c5-simulator.png" \
  --out ".figma-cache/<nodeId>/c5-simulator-cmp.png" \
  || cp ".figma-cache/<nodeId>/c5-simulator.png" ".figma-cache/<nodeId>/c5-simulator-cmp.png"
```

`screenshot-cmp.png` should already exist from Phase A. Missing = Phase A artifact lost — re-run figma export rescue path (see backup `_rescue` workflow if needed).

### C5 Verification Integrity (banned shortcuts)

1. **Launch-arg / env-var route override** to "jump" to the screen: `LaunchEnvironment["VERIFY_ROUTE"] = "PINSetup"`, `--initial-screen` CLI flag, `#if DEBUG` deep-link parser. Banned. Even gated by `#if DEBUG`, ships a debug entrypoint to development-provisioned devices. Screenshot then shows the screen mounted **without** navigation push / prerequisite state / lifecycle events that real users hit.
2. **Adding `#Preview` macros purely to satisfy C5.** Previews skip real navigation, real state init, real lifecycle. Existing previews are fine; new ones for C5 reachability are not.
3. **Stating C5 PASS without real render + visual compare.** Clean build ≠ C5. Need `c5-render.png` (Engine A) or `c5-simulator.png` (Engine B).
4. **Reading code and asserting "the transition works because ..."**. That's Pass 1/4. C5 requires actual transition in simulator.

Allowed paths for non-default screen during C5:
- User provides `previewEntry` (existing `#Preview` / scheme / test target). Stash and reuse.
- `ios-simulator-verify` skill drives via accessibility identifiers (no binary changes).
- `computer-use` MCP drives by pixel taps (with `request_access`).

None available + screen not default → `manifest.verification.c5.skipped = "no_entry_path"`. Tell user verbatim: *"C5 cannot reach <ScreenName> from launch. Provide an existing #Preview / scheme / test entry, or install `ios-simulator-verify` skill, or grant `computer-use` access. I will NOT add a debug route to the binary."*

### C5.6 — 6-step compare

Write to `.figma-cache/<nodeId>/c5-visual-diff.md`.

**Step 1 — Section census (`c5-sections.md`).** Walk Figma `metadata.json` for top-level visual sections. For each: `nodeId`, semantic name, `bbox_pct` (x%, y%, w%, h%), `expected_count` (e.g. "4 trailing nav icons"). Source: `scripts/c5-crop-sections.sh` (when available).

**Step 2 — Per-section crop pairs.** For each section in census, crop both `screenshot-cmp.png` and `c5-simulator-cmp.png` to `bbox_pct`. Normalize to width 1024 for vision parity. Open each crop pair and compare in isolation — full-image compare routinely misses small-section differences.

**Step 3 — Free-form "what's wrong first" pass.**
```markdown
## What's wrong (free-form, before structured analysis)
Pretend a hostile stranger wrote this code. List 3–5 most obvious visual differences in plain prose.
No PASS verdicts here, only differences. If 0 differences, write "0 differences because:" + concrete pixel evidence.
```

This forces difference-first thinking before the structured table induces confirmation bias.

**Step 4 — Structured 3-axis diff table.**

| Axis | Meaning |
|---|---|
| **PR** | Presence — does sim show it; count matches `expected_count` |
| **LY** | Layout — position, size, internal spacing, container alignment (`counterAxisAlignItems`, `primaryAxisAlignItems`). **Width threshold 5pp**, **tightened to 3pp** when section contains `button`/`cta`/`primary`/`submit`/`action` |
| **ST** | Styling — color, typography weight/size, icon shape, shadows, borders, text alignment |

For each section, emit 3 rows (PR/LY/ST). Same `Match` (PASS/FAIL/N/A) + Severity columns as Pass 2.

**Banned weasel language in PASS rows.** `approximately`, `roughly`, `looks similar`, `close enough`, `minor difference`, `slightly`, `nearly`, `almost identical` — Gate C5 auto-converts to `FAIL medium`.

**Step 5 — Negative spot-check + 4-anchor proportional check.**

```markdown
## Negative spot-check
Q: Anything visible in sim NOT in Figma?  A: <enumerate or "none">
Q: Anything visible in Figma NOT in sim?  A: <enumerate or "none">

## 4-anchor proportional check
| anchor | figma (x%,y%) | sim (x%,y%) | delta | verdict |
|---|---|---|---|---|
| top-left element | 4,3 | 4,4 | 0,1 | PASS |
| top-right element | 92,3 | 88,4 | 4,1 | PASS |
| primary CTA center | 50,82 | 50,86 | 0,4 | PASS |
| bottom-most element | 50,95 | 50,98 | 0,3 | PASS |

## Button width check (mandatory if buttons exist)
| button | figma w% | sim w% | delta | verdict |
|---|---|---|---|---|
| "Continue" (primary CTA) | 87 | 100 | 13 | FAIL |
| "Skip" (secondary) | 30 | 30 | 0 | PASS |

## Button internal layout check (mandatory if buttons have composite content)
| button | figma text x% | sim text x% | figma icon x% | sim icon x% | match |
|---|---|---|---|---|---|
| "Continue" | 50 | 32 | 92 | 92 | FAIL |
| "Skip" | 50 | 50 | n/a | n/a | PASS |

## Navigation visibility check (mandatory)
| chrome | figma shows? | sim shows? | match | note |
|---|---|---|---|---|
| nav bar | no | yes | FAIL | Figma has custom in-content header; sim shows system nav — missing `.toolbar(.hidden, for: .navigationBar)` |
| tab bar | yes | yes | PASS | - |
```

Anchor delta > 5pp on either axis = `FAIL high`. Button width delta ≥ 3pp = `FAIL high` (cascade-trap bug). Button internal layout delta ≥ 3pp = `FAIL high`. No buttons → `n/a — no buttons` (still write block).

**Step 6 — Attestation.**
```markdown
## Attestation
I opened both screenshots and each crop pair, walked the 6-step procedure, and the
differences listed above are real. I did not skip any section in c5-sections.md. — verifier
```

Missing attestation = Gate C5 fails.

### Gate C5

```bash
CACHE=".figma-cache/<nodeId>"; FAIL=0

# Build succeeded
[ -s "$CACHE/c5-build.log" ] && grep -qE 'BUILD SUCCEEDED' "$CACHE/c5-build.log" \
  && echo "PASS: build" || { echo "FAIL: build"; FAIL=1; }

# Simulator screenshot real PNG (Engine A: c5-render.png; Engine B: c5-simulator.png)
RENDER="$CACHE/c5-render.png"; SIM="$CACHE/c5-simulator.png"
[ -f "$RENDER" ] || [ -f "$SIM" ] && {
  TARGET=$([ -f "$RENDER" ] && echo "$RENDER" || echo "$SIM")
  file "$TARGET" | grep -q "PNG image data" \
    && echo "PASS: render/screenshot" || { echo "FAIL: render/screenshot"; FAIL=1; }
} || { echo "FAIL: no render or screenshot"; FAIL=1; }

# Comparison-safe pair ≤ 2000px
for IMG in screenshot-cmp.png c5-simulator-cmp.png; do
  if [ -f "$CACHE/$IMG" ]; then
    LONG=$(sips -g pixelWidth -g pixelHeight "$CACHE/$IMG" | awk '/pixel(Width|Height)/ {print $2}' | sort -n | tail -1)
    [ "${LONG:-9999}" -le 2000 ] && echo "PASS: $IMG ($LONG px)" \
      || { echo "FAIL: $IMG long-side=$LONG"; FAIL=1; }
  fi
done

# C5.6 structural coverage: report exists + 6 sections present
REPORT="$CACHE/c5-visual-diff.md"
[ -s "$REPORT" ] && \
  grep -q '## What.*wrong' "$REPORT" && grep -q '## Findings' "$REPORT" \
  && grep -q '## Negative spot-check' "$REPORT" && grep -q '## 4-anchor' "$REPORT" \
  && grep -q '## Button width' "$REPORT" && grep -q '## Navigation visibility' "$REPORT" \
  && grep -q '## Attestation' "$REPORT" \
  && echo "PASS: C5.6 structure" || { echo "FAIL: C5.6 structure"; FAIL=1; }

# High-severity FAIL count (informational, drives same loop as Pass 2)
HIGH_FAILS=$(grep -cE '\| *FAIL *\| *high *\|' "$REPORT" 2>/dev/null)
echo "INFO: C5 has $HIGH_FAILS high-severity FAIL rows"

[ $FAIL -eq 0 ] && echo "GATE: PASS (C5)" || echo "GATE: FAIL (C5)"
```

High-severity diffs feed the same self-fix loop as Pass 2 (shared counter, MAX_RETRIES=2, scoped edits only).

---

## 6. C6 — Asset Completeness (mandatory)

Every Figma-tagged asset MUST land in `Assets.xcassets`; `Image(systemName:)` MUST NOT silently substitute a Figma asset.

```bash
bash ~/.claude/scripts/c6-asset-completeness.sh \
  --registry .figma-cache/<nodeId>/registry.json \
  --xcassets <project>/Assets.xcassets \
  --src      <project-swift-src-root>
```

Allow-list for `Image(systemName:)` (no comment required):
- `chevron.backward` / `chevron.left` — in files using `NavigationStack` or `.toolbar`
- `square.and.arrow.up` — for `ShareLink`
- `xmark.circle.fill` — for `.searchable` clear button
- `keyboard*` — keyboard control glyphs

Anything else needs `// allow-systemName: <reason>` on same or previous line.

Fix loop on FAIL:
1. Re-run `figma_export_assets_unified(autoDiscover: true)` — autoDiscover scans subtree, picks up missed icons.
2. Replace `Image(systemName: "shield.fill")` with `Image(.icAIShield)`. If genuinely a system glyph, add allow comment.

---

## 7. C7 — No System Chrome (mandatory)

Generated SwiftUI MUST NOT redraw iOS system chrome (status bar, home indicator, Dynamic Island, notch).

```bash
bash ~/.claude/scripts/c7-no-system-chrome.sh --src <project-swift-src-root>
```

Greps for: `FakeStatusBar`, `HomeIndicator`, `DynamicIsland(...)` as custom view, `NotchView`, `*StatusBar*` view names (excluding UIKit's `UIStatusBar`); `Text("9:41")`; `Image(systemName: "wifi"|"cellularbars"|"battery.*")`; `Capsule().<...>.frame(height: 1..6)`.

Fix loop on FAIL:
1. Delete the `FakeStatusBar` / `HomeIndicator` view structs entirely.
2. Remove every call site mounting them.
3. If Figma frame showed content extending behind status bar → `.ignoresSafeArea(edges: .top)` on the **background only**, never on content.

`PASS` is the only acceptable outcome before declaring done.
