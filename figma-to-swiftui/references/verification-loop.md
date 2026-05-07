# Verification Loop

The executable procedures behind C3 Pass 2 (offline diff report) and C5 (build + simulator screenshot). Both layers exist because mental walk-throughs are easy to fake — the agent claims PASS without doing the work. This file defines artifacts that gates can grep and count, applying the same philosophy as Gate A/B in SKILL.md: *"the agent can lie, but `file <path>` cannot."*

Read this when you reach Step C3 Pass 2 or Step C5.

## Canonical gate letters

| Letter | Gate                                    | Where defined  | Hard fail? |
|--------|-----------------------------------------|----------------|------------|
| C3-Pass2 | Code-vs-screenshot diff report      | §1, §4         | yes        |
| C5     | Build + simulator screenshot + diff     | §5             | yes        |
| C6     | Asset completeness (registry ↔ xcassets, `Image(systemName:)` allow-list) | §6 | yes (mandatory after codegen) |
| C7     | No system chrome (status bar, home indicator, Dynamic Island, notch redraws) | §7 | yes (mandatory after codegen) |

**C6 and C7 are mandatory.** Both run after codegen and before declaring the task done. Either gate failing blocks the run from finishing — same status as C3 Pass 2 / C5. There is no user opt-out.

---

## 1. C3 Pass 2 — Diff Report Template

Save to `.figma-cache/<nodeId>/c3-pass2-diff.md`. Use this template verbatim — Gate C3-Pass2 grep-checks the structure.

```markdown
# C3 Pass 2 — Code vs Screenshot Diff Report
nodeId: <nodeId>
generatedAt: <ISO-8601>
attempt: <1..N>
codeFiles:
  - <relative path to swift file 1>
  - <relative path to swift file 2>

## Checklist coverage
Every check letter below MUST appear in at least one Findings row,
or be marked N/A in a Findings row with a reason.

- LH    line-height
- LS    letter-spacing / tracking
- SH    shadow (color+opacity+offset+radius, inner & outer)
- BD    border + radius combined
- OP    opacity on sub-elements
- RM    icon rendering mode (template vs original)
- IS    icon exact pixel size
- AL    text alignment + fill-width drawing rect (parent-aware: Text-layer for non-Button stacks; Button-outer-layer for Button parents)
- DV    divider color/opacity/height
- BG    background material (blur) behind text
- TR    text truncation / line limit + minimumScaleFactor on single-line Text
- GR    gradient direction & stops
- SA    safe-area behavior (background extends under chrome)
- CH    no system chrome drawn
- PD    explicit padding (no SwiftUI defaults)
- BS    .buttonStyle(.plain) on custom buttons
- IF    image fill mode (resizable + scaledToFill/scaledToFit + frame)
- SS    spacing-safe-area normalization (raw figma y minus inset, not raw)
- BW    button width source-of-truth (Figma primaryAxisSizingMode → Button outer frame; no maxWidth on inner Text/HStack)

## Findings
| # | Check | Section | Figma Spec | Source quote | Code value | File:Line | Match | Severity |
|---|-------|---------|------------|--------------|------------|-----------|-------|----------|
| 1 | LH    | <name>  | <spec>     | <verbatim>   | <code>     | <f:l>     | PASS  | -        |
| 2 | LS    | <name>  | <spec>     | <verbatim>   | <code>     | <f:l>     | FAIL  | high     |
...

## Summary
- total: <int>
- pass:  <int>
- fail:  <int>   (high: <int>, medium: <int>, low: <int>)
- n/a:   <int>
```

Required fields per row:
- **Check** — one of the 19 codes (LH/LS/SH/BD/OP/RM/IS/AL/DV/BG/TR/GR/SA/CH/PD/BS/IF/SS/BW).
- **Section** — visual section name (e.g. "Headline", "Primary CTA", "Card row 2"). Use `-` only when the row is `CH` / `SS` (screen-root) or otherwise screen-wide.
- **Figma Spec** — the value as Figma intends it (e.g. `font-size 28, line-height 34`).
- **Source quote** — verbatim string from `design-context.md` (with line number) OR from the inventory in scratch context. See §3.
- **Code value** — verbatim copy of the relevant SwiftUI modifier(s).
- **File:Line** — `<filename.swift>:<line>` pointing to the line being judged. `-` for screen-wide checks.
- **Match** — `PASS`, `FAIL`, or `N/A`.
- **Severity** — `high`, `medium`, `low` for FAIL; `-` for PASS; `-` for N/A.

Minimum 15 rows total. Every check letter must appear ≥1 time.

---

## 2. Severity Rubric

| Severity | Definition | Examples |
|----------|------------|----------|
| `high`   | Visible mismatch a user would notice immediately. Drives self-fix loop. | Wrong font size, missing line-height, missing shadow, wrong icon size by >2pt, wrong renderingMode (icon untinted that should tint), drawing system chrome (status bar/home indicator), `Image(systemName:)` substituting a Figma asset, missing border, wrong corner radius by >2pt. |
| `medium` | Off-by-small, non-obvious to most users but breaks pixel parity. | Padding off by 1–2pt, spacing off by 1–2pt, opacity off by 0.05, gradient stop position off by ≤10%. |
| `low`    | Cosmetic / ambiguous. Surfaced but does NOT trigger retry. | Line limit unclear from screenshot, alignment ambiguous when text fits in one line, `.tracking(0)` vs no `.tracking(...)` (equivalent). |
| `N/A`    | No element of this kind exists on the screen. Reason required. | "no divider in screen", "no gradient on screen", "no custom button — only NavigationLink default". |

Self-fix loop triggers on `high` only by default. If `medium` count > 2, also trigger (see §4). `low` rows are reported but never retried.

### Match column rules — when "PASS with note" is banned

The `Match` column is ternary (`PASS` / `FAIL` / `N/A`). It is **not** a place for "PASS with caveat", "PASS-ish", or "PASS — minor difference noted". Any of those collapse to **FAIL** at the corresponding severity:

| What you observed | Correct row |
|---|---|
| Code matches Figma exactly | `Match=PASS`, no note needed |
| Code differs from Figma but you think the user won't notice | `Match=FAIL`, `Severity=low` (or higher if you're not sure) |
| Code differs from Figma and the difference is ≤ 2pt / ≤ 0.05 opacity / cosmetic | `Match=FAIL`, `Severity=medium` |
| Code differs from Figma in a way a user notices | `Match=FAIL`, `Severity=high` |
| Element doesn't exist on this screen | `Match=N/A`, reason in Section column |

Writing `Match=PASS` and adding a Note like *"position slightly upper-left vs Figma center; minor"* is a graded protocol violation — it inflates the PASS count, hides the real high/medium/low distribution, and prevents the self-fix loop from running on the issue you just observed. The agent's instinct to soften FAIL into "PASS-with-note" is the most common way C3 Pass 2 lies to itself; the rule above closes it.

---

## 3. Source Quote Rules

The `Source quote` column is the anti-hallucination lever. Without it, the agent could write 15 plausible-looking rows from imagination alone.

Rules:
1. **Verbatim only.** Copy the exact characters from `design-context.md` between backticks. No paraphrasing, no normalization (don't change `'` to `"`, don't drop `px`).
2. **Cite the line.** Prepend the source location: `design-context.md L42 \`...\``. Gate doesn't check line numbers, but humans reviewing do.
3. **Inventory rows are valid sources.** When the value comes from the Visual Inventory in scratch context (e.g. icon `renderingMode: template`), write `inventory row N: renderingMode=template` — backticks optional, but the substring must be unique enough that the reader can find it.
4. **For N/A rows**, write a reason in the Section column instead of a quote (e.g. `Section: "n/a — no divider in screen"`). The Source quote column can be `-`.
5. **For CH (system chrome)** rows, source is `SKILL ABSOLUTE RULE` — that's enough.

Gate C3-Pass2 verifies that ≥50% of quoted strings (between backticks) actually `grep -F` in `design-context.md`. The 50% threshold accommodates inventory-sourced quotes that won't appear in design-context.

---

## 4. Self-Fix Loop

### 4.0 — Prefill mechanical rows (recommended)

Before writing the report by hand, run:

```bash
scripts/c3-pass2-prefill.sh <nodeId>
```

This emits `.figma-cache/<nodeId>/c3-pass2-diff.md` with 9 rows already decided mechanically (CH, PD, GR, DV, BG, TR, SA, BS, SS — based on greps over `design-context.md` and the listed swift files) plus 9 TODO rows for the checks that **must** be cross-checked against Figma values (LH, LS, SH, BD, OP, RM, IS, **AL**, **IF**). The agent only fills the TODO rows.

`AL` (text alignment + fill-width drawing rect, parent-aware): for any text whose Figma `textAlignHorizontal` is `CENTER` / `RIGHT` / `JUSTIFIED` AND whose layout is fill-width, the agent must verify code emits BOTH `.multilineTextAlignment(...)` AND a fill-width drawing rect for the Text. The fill-width rect comes from one of two layers depending on parent context:
  - **Parent is a non-Button stack (VStack/HStack/ZStack/screen-root)** → `.frame(maxWidth: .infinity, alignment: ...)` ON THE TEXT
  - **Parent is `Button { ... }`** → `.frame(maxWidth: .infinity)` ON THE BUTTON's OUTER frame (NOT on inner Text — that cascades up and bloats the button — banned by Check 8 + check letter `BW` below). The Button's outer fill propagates the drawing rect down to the Text for free, so `.multilineTextAlignment(.center)` works without an inner-Text maxWidth.

  The common bug is emitting `.multilineTextAlignment(.center)` only without any fill-width rect anywhere in the chain — Text hugs its intrinsic width and the alignment is visually invisible (reads as left-aligned). Second-most-common bug is putting maxWidth on the Text inside a Button — the alignment looks right but the Button bloats to screen width. If the screen has zero text with non-LEFT alignment, mark the row N/A with reason. Source `references/visual-fidelity.md` §Text + §"Stack alignment" + §"`.frame(maxWidth: .infinity)` cascade trap".

`IF` (image fill mode): for every Image whose Figma node fills its parent (fill-width / fill-height / both), the agent must verify code emits ALL THREE — `.resizable()` + content mode (`.scaledToFill()` / `.scaledToFit()` / `.aspectRatio(_:contentMode:)`) + `.frame(...)`. Common bug is `Image("hero").frame(maxWidth: .infinity, height: 240)` without `.resizable()` and `.scaledToFill()` — image stays at intrinsic size, frame reserves blank space. If the screen has no fill-* images (only hug icons), mark N/A with reason. Source `references/visual-fidelity.md` §1 "Image fill mode" + §4 Image + `references/layout-translation.md` §"Image content-mode → SwiftUI".

`SS` (spacing-safe-area normalization): the prefill script's mechanical detector greps for screen-root `.padding(.top, N)` / `Spacer().frame(height: N)` where N ∈ {44, 47, 59, 64, 67, 79, 88}; if any hit lacks a `// safe-area-adjusted: ...` comment, prefill emits FAIL high. Otherwise PASS. The agent verifies inventory CONTAINER row had `mockupChrome` + `safeAreaInsets` set; if not, the row is incomplete regardless of grep result. Source `references/visual-fidelity.md` §4 "Safe area & spacing normalization" + `references/layout-translation.md` §"Safe Area Normalization for Mockup Frames".

`BW` (button width source-of-truth): for every Button in the Visual Inventory, the agent verifies the WIDTH of the button comes from the Button's OWN Figma `primaryAxisSizingMode`, applied on the Button's OUTER frame:
  - Figma `primaryAxisSizingMode: FILL` → code emits `.frame(maxWidth: .infinity)` on Button outer; **no maxWidth on inner Text or inner HStack**
  - Figma `primaryAxisSizingMode: FIXED` (button width is W) → code emits `.frame(width: W)` on Button outer; **no width on inner Text/HStack**
  - Figma `primaryAxisSizingMode: AUTO/HUG` (button hugs its label) → no width modifier; let Button intrinsic-size to its label

The prefill script's mechanical detector greps for the inner-Text bug specifically: a `Text(...).frame(maxWidth: .infinity)` whose enclosing scope is `Button { ... }` body without `// allow-text-fill:` justification. When detected → FAIL high (this is the same condition as banned-pattern Check 8; if Check 8 was somehow bypassed, BW catches it on the verification side). When clean → TODO (the agent must still verify the Button's OUTER frame matches the Figma sizingmode).

If the screen has zero buttons, mark the row N/A with reason. If the screen has multiple buttons, emit one BW row per button (or one PASS row covering all if every button checks out — but for FAIL rows, name each offending button explicitly). Source `references/visual-fidelity.md` §"`.frame(maxWidth: .infinity)` cascade trap" + §7 Hard Rule #14 + `references/layout-translation.md` §"Button sizing-mode → SwiftUI" + `references/anti-patterns.md` §12.

The script never invents `Source quote` text — TODO rows ship with explicit `<verbatim>` placeholders that the agent replaces with strings copied verbatim from `design-context.md`. Gate C3-Pass2 still validates the final report unchanged (structure, 18-letter coverage, ≥14 rows, ≥50% quote anchor, valid file:line refs). If the script's mechanical PASS/NA is wrong for a given screen (rare), the agent flips it to FAIL and adds a justification — same as any manual row.

Expected token saving on flows of 5+ screens: ~30–50% off Phase C, because the verification step is what dominates per-screen token cost.

If `.figma-cache/<nodeId>/c3-pass2-diff.md` already exists (a prior attempt), the script refuses to overwrite. Pass `--force` only when starting fresh.

### 4.1 — Gate C3-Pass2 (BASH, mandatory)

Run after writing `c3-pass2-diff.md`. Two failure modes — handle them differently:
- **Gate FAIL** (report structurally invalid) → regen the report, do NOT touch code, do NOT increment the retry counter. After 2 consecutive regen failures, ASK user.
- **Gate PASS but findings have FAIL high rows** → trigger the loop pseudocode in §4.3.

```bash
CACHE=".figma-cache/<nodeId>"
REPORT="$CACHE/c3-pass2-diff.md"
SWIFT_FILES="<your-generated-swift-files>"
DESIGN_CTX="$CACHE/design-context.md"
FAIL=0

# 1. Report exists
[ -s "$REPORT" ] && echo "PASS: report exists" || { echo "FAIL: $REPORT missing"; FAIL=1; }

# 2. Required structure
grep -q '^nodeId:'      "$REPORT" && \
grep -q '^attempt:'     "$REPORT" && \
grep -q '^## Findings'  "$REPORT" && \
grep -q '^## Summary'   "$REPORT" \
  && echo "PASS: report structure" \
  || { echo "FAIL: report missing required sections"; FAIL=1; }

# 3. Every required check letter appears in a Findings row
MISSING=""
for code in LH LS SH BD OP RM IS AL DV BG TR GR SA CH PD BS IF SS BW; do
  grep -qE "^\| *[0-9]+ *\| *${code} *\|" "$REPORT" || MISSING="$MISSING $code"
done
[ -z "$MISSING" ] && echo "PASS: all checks covered" || { echo "FAIL: missing checks:$MISSING"; FAIL=1; }

# 4. Row count
ROW_COUNT=$(grep -cE '^\| *[0-9]+ *\|' "$REPORT")
[ "${ROW_COUNT:-0}" -ge 15 ] && echo "PASS: $ROW_COUNT rows" \
  || { echo "FAIL: only $ROW_COUNT rows (need >=15)"; FAIL=1; }

# 5. Anti-hallucination: every File:Line in PASS/FAIL rows points to a real line
BAD_REFS=$(awk -F'|' '/^\| *[0-9]+ *\|/ {
    file_line=$8; gsub(/^ +| +$/,"",file_line);
    match_col=$9; gsub(/^ +| +$/,"",match_col);
    if ((match_col=="PASS"||match_col=="FAIL") && file_line!="-" && file_line!="") print file_line
  }' "$REPORT" | while read -r ref; do
    [ -z "$ref" ] && continue
    f="${ref%%:*}"; l="${ref##*:}"
    found=$(echo $SWIFT_FILES | tr ' ' '\n' | grep -E "/$f$|^$f$" | head -1)
    [ -z "$found" ] && { echo "BAD_FILE:$ref"; continue; }
    total=$(wc -l < "$found" 2>/dev/null)
    [ -n "$total" ] && [ "$l" -gt "$total" ] 2>/dev/null && echo "BAD_LINE:$ref"
  done)
[ -z "$BAD_REFS" ] && echo "PASS: file:line refs valid" \
  || { echo "FAIL: invalid refs: $BAD_REFS"; FAIL=1; }

# 6. Anti-hallucination: ≥50% of `quoted` strings actually appear in design-context.md
QUOTED=$(awk -F'|' '/^\| *[0-9]+ *\|/ { print $6 }' "$REPORT" | grep -oE '`[^`]+`' | sed 's/`//g')
TOTAL_Q=$(echo "$QUOTED" | grep -c .)
HIT_Q=0
while IFS= read -r q; do
  [ -z "$q" ] && continue
  grep -qF "$q" "$DESIGN_CTX" 2>/dev/null && HIT_Q=$((HIT_Q+1))
done <<< "$QUOTED"
if [ "$TOTAL_Q" -gt 0 ]; then
  PCT=$(( HIT_Q * 100 / TOTAL_Q ))
  [ "$PCT" -ge 50 ] && echo "PASS: $PCT% quotes verified ($HIT_Q/$TOTAL_Q)" \
    || { echo "FAIL: only $PCT% quotes match design-context.md ($HIT_Q/$TOTAL_Q)"; FAIL=1; }
fi

# 7. Surface high-severity FAIL count (informational — drives loop in §4.3)
HIGH_FAILS=$(grep -cE '\| *FAIL *\| *high *\|' "$REPORT")
echo "INFO: $HIGH_FAILS high-severity FAIL rows"

[ $FAIL -eq 0 ] && echo "GATE: PASS (C3 Pass 2)" || echo "GATE: FAIL (C3 Pass 2 — report invalid)"
```

### 4.2 — FAQ

**When does the loop trigger?**
After Gate C3-Pass2 prints `GATE: PASS` AND the report contains ≥1 row with `Match=FAIL Severity=high`. Also triggers if `medium` count > 2.

**When does it stop?**
- All checks PASS or N/A, no high, ≤2 medium → success, proceed to C5 prompt.
- `c3-retry-count` reaches `MAX_RETRIES` (default 2) → exhausted; tell user the remaining FAIL rows and ask how to proceed.
- `highFailsHistory` not monotonically decreasing across attempts → asymptote bail-out (the model is fixing one row but breaking another). Treat as exhausted.
- User says `stop fixing` / `ship as-is` → mark `verification.c3Pass2.lastResult = "user_override"`, continue.

**What may a retry edit?**
ONLY the file:line cited in a FAIL row. No refactoring, no renaming, no restructuring. The retry exists to apply specific fixes the report identified, not to clean up code.

**What if the gate itself keeps failing (report invalid)?**
Regen the report; do NOT touch code; do NOT increment the retry counter. After 2 failed regen attempts in a row, ask the user to review — the model is bugging out.

**Where is state stored?**
- `.figma-cache/<nodeId>/c3-retry-count` — single integer, plain text.
- `.figma-cache/<nodeId>/c3-pass2-diff.md` — current report.
- `.figma-cache/<nodeId>/c3-pass2-diff.attempt-<N>.md` — snapshot per attempt for debugging.
- `manifest.json` → `verification.c3Pass2.{lastAttempt, lastResult, highFailsHistory}` — array of `high` counts across attempts; the asymptote check reads this.

**Does this loop apply to `figma-flow-to-swiftui-feature`?**
Indirectly. The flow skill delegates per-screen back to `figma-to-swiftui`, so each per-screen sub-task runs its own C3 Pass 2 + self-fix loop independently. No changes needed to the flow skill.

### 4.3 — Loop Pseudocode

Default `MAX_RETRIES=2` (3 attempts total). User can override at task start with phrase `max 3 retries`.

1. Run Pass 2 → write `c3-pass2-diff.md` → run Gate C3-Pass2 (§4.1).
2. **Gate FAIL** → regen report (no code edits, no counter bump). After 2 consecutive regen failures, ASK user.
3. **Gate PASS, `HIGH_FAILS > 0`:**
   - Read counter: `count=$(cat $CACHE/c3-retry-count 2>/dev/null || echo 0)`
   - If `count >= MAX_RETRIES`: STOP. Tell user *"Self-fix exhausted. Remaining FAIL rows: <list each row's Section + Figma Spec + Severity>. How would you like to proceed?"*
   - Else: snapshot `cp c3-pass2-diff.md c3-pass2-diff.attempt-$((count+1)).md`, append `HIGH_FAILS` to `manifest.verification.c3Pass2.highFailsHistory`, increment counter, edit ONLY the file:line cited in each FAIL row (no refactoring), then re-run from step 1.
4. **Asymptote check** (run before each retry):
   ```bash
   python3 -c "
   import json
   h=json.load(open('$CACHE/manifest.json')).get('verification',{}).get('c3Pass2',{}).get('highFailsHistory',[])
   if len(h)>=2 and h[-1]>=h[-2]: print('ASYMPTOTE')"
   ```
   If `ASYMPTOTE` → exit early as exhausted.
5. **Gate PASS, no high, `medium <= 2`** → reset counter (`echo 0 > $CACHE/c3-retry-count`), proceed to Pass 3.
6. `medium > 2` → same as step 3 but limit edits to medium-severity rows.

User abort phrases (`stop fixing`, `ship as-is`) → mark `manifest.verification.c3Pass2.lastResult = "user_override"`, continue.

---

## 5. C5 Simulator Workflow

**C5 is mandatory.** It runs unconditionally after Gate C3-Pass2 prints `GATE: PASS`. There are no user opt-out phrases. The agent only skips C5 when one of four system reasons applies (auto-detected, persisted in `manifest.verification.c5.skipped`):

- `no_project` — no `.xcodeproj` / `.xcworkspace` after walking up 3 levels (handled in C5.1).
- `simctl_error` — `xcrun simctl` errors, missing simulator runtime, missing Xcode CLT (handled in C5.2 / C5.4).
- `ci_environment` — `CI=true` or `GITHUB_ACTIONS=true` env present (no GUI simulator in CI).
- `no_entry_path` — the screen is not the app's launch screen, no existing `#Preview` / scheme / test target reaches it, and no `ios-simulator-verify` / `computer-use` driver is available. Adding a debug route override to the binary to bypass this is **banned** per §"C5 Verification Integrity" — surfacing the limitation truthfully is the correct action.

User phrases like `skip C5` / `bỏ qua C5` / `không cần build` are NOT honored. Reply with the Done-Gate (`SKILL.md` Key Principle #12) and proceed.

### C5.1 — Detect build target

```bash
xcodebuild -list 2>/dev/null
```

Parse the output for schemes. Decision tree:
- 1 scheme → use it silently.
- N > 1 schemes → ASK user once, stash in `manifest.verification.c5.scheme`.
- No `.xcodeproj` / `.xcworkspace` in pwd → walk up 3 levels. Still none → tell user "no Xcode project found, skipping C5" and mark `manifest.verification.c5.skipped = "no_project"`.

### C5.2 — Pick simulator destination

```bash
xcrun simctl list devices available -j | python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devs in data['devices'].items():
    if 'iOS' not in runtime:
        continue
    for d in devs:
        if d['state'] == 'Booted' or 'iPhone' in d['name']:
            print(f\"{d['udid']} {d['name']} ({runtime.split('.')[-1]})\")
"
```

Prefer a Booted iPhone. Else pick the highest-iOS iPhone 15/16 generic. Stash UDID in `manifest.verification.c5.udid`.

### C5.3 — Build for simulator (with fast-fail)

`xcodebuild` typically prints `error:` lines mid-stream and only finalizes with `BUILD FAILED` after another 30–60s of cleanup. Watch the log live and exit early when failure is certain — saves wall-time + spares the user a long wait that ends the same way.

```bash
mkdir -p ".figma-cache/<nodeId>"
LOG=".figma-cache/<nodeId>/c5-build.log"

(
  xcodebuild -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$UDID" \
    -configuration Debug \
    -derivedDataPath ".figma-cache/<nodeId>/derived" \
    build 2>&1
) | tee "$LOG" | (
  # Fast-fail: kill the pipeline on first ❌ error: line that doesn't look
  # like a warning. xcodebuild's own exit code still lands in the log via tee.
  awk '
    /^[[:space:]]*error:/        { print; bad=1; exit 0 }
    /BUILD FAILED/               { print; exit 0 }
    /^\*\* BUILD SUCCEEDED \*\*/ { print; exit 0 }
    { print }
  '
)
```

On build failure: parse the last 50 lines of `c5-build.log` for compile errors. Surface each error as a FAIL row in `c5-visual-diff.md` (Section: `build`, Severity: `high`). Trigger self-fix loop on those. Do NOT proceed to install.

Common early-exit signals to grep for (any one ⇒ build is dead, stop waiting):
- `error:` not followed by `warning:` on the same logical line
- `Linker command failed`
- `Undefined symbol:`
- `❌` (Xcode 16+ pretty-printed errors)
- `cannot find type ... in scope` / `use of unresolved identifier`

### C5.4 — Boot, install, launch

```bash
xcrun simctl boot "$UDID" 2>/dev/null   # idempotent; ignore "already booted"
APP_PATH=$(find ".figma-cache/<nodeId>/derived/Build/Products/Debug-iphonesimulator" \
  -name "*.app" -maxdepth 2 | head -1)
xcrun simctl install "$UDID" "$APP_PATH"
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP_PATH/Info.plist")
xcrun simctl launch "$UDID" "$BUNDLE_ID"
open -a Simulator
```

If the app's default screen is NOT the Figma screen we just built (very common — most apps boot into Login/Home), we have a navigation problem. ASK user once: "Which scheme/target shows the new view? Or add a `#Preview` and tell me the file." Stash the answer in `manifest.verification.c5.previewEntry`. Reuse on subsequent runs.

### C5 Verification Integrity (banned shortcuts)

C5 must screenshot the app **as it will ship**. The following shortcuts are banned even when they would make verification easier:

1. **Adding a launch-arg / env-var route override to "jump" to the screen.** For example: `LaunchEnvironment["VERIFY_ROUTE"] = "PINSetup"`, a `--initial-screen` CLI flag, or a `#if DEBUG` deep-link parser added solely to make C5 reachable. Reasons banned:
   - The override compiles into the binary unless it is gated by `#if DEBUG` AND the build configuration is strictly `Debug` AND the user is informed it must be removed before TestFlight. Even then, it ships a debug entrypoint that an attacker / curious user can trigger via `xcrun simctl launch <bundle> --args VERIFY_ROUTE=PINSetup` on a jailbroken / development-provisioned device.
   - The screenshot then shows the screen **mounted in isolation** without the navigation push, prerequisite-screen state, and lifecycle events that real users will hit. C5's job is to catch what offline diff cannot (real font rendering, real safe area, real animation start state) — bypassing those defeats it.
   - It teaches the agent that "if the simulator is hard to drive, change the binary." Once that's normalized, every future C5 quietly carries debug surface.

2. **Adding `#Preview` macros purely to satisfy C5.** Previews skip real navigation, real state initialization, and real lifecycle events. They are a design tool, not a verification tool. Existing `#Preview`s the project already shipped are fine to use; new ones added solely to make C5 reachable are not.

3. **Stating C5 PASS without `simctl launch` + `simctl io screenshot` + visual compare.** A clean `xcodebuild build` is not C5. Compile-passed alone fails C5 by definition.

4. **Reading code and asserting "the transition works because `OnboardingState.handlePINComplete` pushes Face ID".** Code-reading is C3 Pass 1 / Pass 4. C5 requires the simulator to actually transition.

The only allowed paths for getting to a non-default screen during C5:
- The user provides a `previewEntry` value (existing `#Preview`, existing test target entry, scheme that boots directly into the screen). Stash and reuse.
- The `ios-simulator-verify` skill drives via accessibility identifiers (no binary changes).
- The `computer-use` MCP drives by pixel taps (with `request_access` for Simulator.app — explicit user approval required).

If none of those is available and the screen is not the app's default → mark `manifest.verification.c5.skipped = "no_entry_path"` and tell the user verbatim: *"C5 cannot reach <ScreenName> from launch. Provide an existing #Preview / scheme / test target entry, or install the `ios-simulator-verify` skill, or grant `computer-use` access to Simulator. I will NOT add a debug route to the binary to bypass this."*

### C5.5 — Capture

```bash
sleep 2
xcrun simctl io "$UDID" screenshot ".figma-cache/<nodeId>/c5-simulator.png"
file ".figma-cache/<nodeId>/c5-simulator.png" | grep -q "PNG image data" \
  || { echo "FAIL: simctl screenshot did not produce PNG"; exit 1; }
```

### C5.5b — Comparison-safe pair (MANDATORY before C5.6)

Claude's many-image API rejects any image with long-side >2000px (`An image in the conversation exceeds the dimension limit for many-image requests (2000px). Start a new session with fewer images.`). iPhone-native captures break this:
- Figma `get_screenshot` at scale 3 → e.g. 1125×2436 (iPhone X), 1179×2556 (iPhone 14 Pro)
- `simctl io screenshot` → device-native, e.g. 1170×2532, 1290×2796

Either alone may load fine; loading **both together** (which C5.6.1, .2, .4, .5 all do) trips the limit and aborts the run.

**`screenshot-cmp.png` should already exist** — Phase A Step A3 sub-step 2 produces it via `sips -Z 2000` right after `get_screenshot`, and Gate A validates it. C5.5b's only mandatory work is the simulator side:

```bash
CACHE=".figma-cache/<nodeId>"

# 1. Verify Phase A's screenshot-cmp.png is present and valid (≤2000px).
#    Missing = Phase A artifact lost — go to Rescue path below, do NOT silently skip.
file "$CACHE/screenshot-cmp.png" 2>/dev/null | grep -q "PNG image data" || {
  echo "screenshot-cmp.png missing — see Rescue path"; exit 1
}

# 2. Produce simulator-cmp.png from C5.5's c5-simulator.png.
LONG=$(sips -g pixelWidth -g pixelHeight "$CACHE/c5-simulator.png" \
       | awk '/pixel(Width|Height)/ {print $2}' | sort -n | tail -1)
if [ "$LONG" -gt 2000 ]; then
  sips -Z 2000 "$CACHE/c5-simulator.png" --out "$CACHE/c5-simulator-cmp.png" >/dev/null
else
  cp "$CACHE/c5-simulator.png" "$CACHE/c5-simulator-cmp.png"
fi
```

**Rescue path — `screenshot.png` missing or unreadable at C5 time.** If `screenshot.png` is gone (cache pruned, figma-desktop session died after Phase A, etc.) and you cannot re-run Phase A right now, render the figma reference directly via MCPFigma:

```jsonc
// figma_export_assets_unified
{
  "fileKey": "...",
  "nodeId": "<screen root>",
  "outputDir": "<abs>/.figma-cache/<nodeId>/_rescue",
  "sharedAssetsDir": "<abs>/.figma-cache/<nodeId>/_rescue",
  "rows": [
    { "nodeId": "<screen root>", "exporter": "fallback", "strategy": "flatten" }
  ],
  "fallbackScale": 2          // scale 2 keeps iPhone frames under 2000px
}
```

Copy the resulting PNG to `$CACHE/screenshot-cmp.png`. **This is a C5-only rescue, not a Phase A substitute.** Phase A's hard STOP for missing figma-desktop (§"Hard rule on missing tools") is unchanged — the rescue exists only because by C5 the agent has already passed Phase A successfully and cannot replay it on the spot. `design-context.md` and `metadata.json` cannot be reconstructed this way; if those are also missing, you cannot run C5 — surface to user.

C5.6.3 crops still operate on the **originals** (`screenshot.png` + `c5-simulator.png`) — high-res input gives better section crops, and the crop script normalizes to width 1024 anyway. C5.6.1, .2, .4, .5 read the `-cmp.png` copies.

### C5.6 — Side-by-side compare (6-step procedure, MANDATORY)

The skill does not ship a pixel-diff binary; the agent's vision is the diff engine. The previous version of this step let the agent write 0–3 generic rows and declare PASS even when whole sections were missing. The procedure below is anti-confirmation-bias by construction: each step produces a file artifact that Gate C5 greps. **Walk every step in order. No shortcuts.**

The Figma screenshot and the simulator screenshot will have different pixel sizes / scales. Compare composition and values, not absolute pixel positions.

**Image inputs.** All sub-steps that load full-frame PNGs into the conversation read the C5.5b comparison-safe pair (`screenshot-cmp.png` + `c5-simulator-cmp.png`), not the originals. C5.6.3 crops are the only step that reads originals (the crop script handles its own resize).

#### C5.6.1 — Section inventory (MANDATORY first step)

Open `.figma-cache/<nodeId>/screenshot-cmp.png` (the C5.5b comparison-safe copy of `screenshot.png`) and write `.figma-cache/<nodeId>/c5-sections.md`. One row per visible section, top-down. Schema:

```markdown
| # | section            | bbox_pct                  | expected_count | notes                              |
|---|--------------------|---------------------------|----------------|------------------------------------|
| 1 | top nav bar        | x:0 y:0 w:100 h:6         | 1              | Edit / + / title / search          |
| 2 | section header     | x:5 y:8 w:60 h:5          | 1              | "My Tokens 4"                      |
| 3 | account row        | x:5 y:15 w:90 h:11        | 4              | logo + label + countdown + code    |
| 4 | bottom tab bar     | x:0 y:90 w:100 h:10       | 5              | 5 icons + labels                   |
```

Rules:
- `bbox_pct` is in **percentages of canvas** (`x`, `y` = top-left corner; `w`, `h` = width/height). Resolution-agnostic on purpose — the same row works for the Figma render and the simulator capture.
- Element-bearing sections (rows, lists, grids) include `expected_count`. Background, padding, dividers are NOT sections — only things the user looks at.
- **Write at least 4 sections.** Single-section screens are vanishingly rare. If you genuinely think there are <4, justify in a `## Why fewer than 4` block at the bottom of the file. Gate C5 fails the run if neither condition holds.

#### C5.6.2 — Element census

Write `.figma-cache/<nodeId>/c5-census.md` — explicit counts of:

- buttons
- text labels (rough estimate, ±2 OK)
- icons (anything that looks like a glyph)
- input fields
- images / illustrations

Count from the Figma screenshot first, then from the simulator. **Mismatch = high FAIL.** This is the cheap catch for missing/extra elements (e.g. 6 brand icons in Figma vs 5 in the simulator) that section-by-section comparison routinely misses because the difference is a single column in a row.

#### C5.6.3 — Per-section crop pairs (MANDATORY)

For each row in `c5-sections.md`, run:

```bash
scripts/c5-crop-sections.sh --cache .figma-cache/<nodeId>
```

Produces:
- `.figma-cache/<nodeId>/crops/<N>-<section-slug>-figma.png`
- `.figma-cache/<nodeId>/crops/<N>-<section-slug>-sim.png`

Both crops are normalized to width 1024 so the agent's vision sees them at comparable scale. Open each crop **pair** and look at the section in isolation — full-image comparison routinely misses small-section differences because the section is a few percent of the canvas. The script prefers ImageMagick if available, falls back to `sips` on macOS, and exits 2 if neither is found (so Gate C5 can distinguish "tool missing" from "real failure").

#### C5.6.4 — Free-form "what's wrong first" pass (anti-confirmation)

Before writing the structured diff table, write a free-form paragraph at the top of `.figma-cache/<nodeId>/c5-visual-diff.md`:

```markdown
## What's wrong (free-form, before structured analysis)
Pretend a hostile stranger wrote this code. List the 3–5 most obvious visual differences you see, in plain prose. No PASS verdicts here, only differences. If you genuinely see 0 differences, write "0 differences observed because:" and provide concrete pixel-level evidence (which colors, which text strings, which positions match).
```

This forces difference-first thinking before the structured table induces confirmation bias. Confirmation bias is the #1 reason visual diffs get missed — once a row reads PASS, every other row is biased toward PASS.

#### C5.6.5 — Structured 3-axis diff table

For each row in `c5-sections.md`, produce **3 rows** in `c5-visual-diff.md` — one per axis:

- `PR` — **Presence** (does the simulator show it; count matches `expected_count`)
- `LY` — **Layout** (position, size, internal spacing relative to siblings — use `bbox_pct` from `c5-sections.md`; **container alignment**: stack children appear at the side / center / distribution Figma's `counterAxisAlignItems` + `primaryAxisAlignItems` specify — e.g. row that should be SPACE_BETWEEN with leftmost + rightmost children flush to edges, vs simulator showing them packed at start). **Width threshold (default 5pp).** **Tightened to 3pp when the section name contains `button` / `cta` / `primary` / `submit` / `action`** — primary CTAs are the most common bug surface for cascading maxWidth (button bloats to screen width, ignoring caller padding); 3pp ≈ 12pt on a 393pt iPhone, the smallest noticeable button-width difference. Per-button width is also covered by the dedicated "Button width check" block in C5.6.6 below.
- `ST` — **Styling** (color, typography weight/size, icon shape, shadows, borders; **text alignment**: a Text whose Figma `textAlignHorizontal=CENTER`/`RIGHT` must visually center/end-align inside its drawing rect — common bug is text that looks left-aligned in simulator because `.multilineTextAlignment(.center)` was emitted without a fill-width drawing rect on the right layer (Text-layer for non-Button parents; Button-outer-layer for Button parents). See `references/visual-fidelity.md` §"Stack alignment" + §Text + §"`.frame(maxWidth: .infinity)` cascade trap")

Each row carries Match (`PASS` / `FAIL` / `N/A`) and Severity. Schema mirrors C3 Pass 2 (replace `Source quote` with `Note`):

```markdown
## Findings
| # | Axis | Section          | Figma                        | Actual                       | Match | Severity | Note                                |
|---|------|------------------|------------------------------|------------------------------|-------|----------|-------------------------------------|
| 1 | PR   | top nav bar      | 4 trailing controls          | 3 trailing controls          | FAIL  | high     | search icon missing in sim          |
| 2 | LY   | top nav bar      | x:0 y:0 w:100 h:6            | h ≈ 8 (pushed down by inset) | FAIL  | medium   | likely safe-area treatment off      |
| 3 | ST   | top nav bar      | title weight regular         | title weight semibold        | FAIL  | high     | .fontWeight(.semibold) on Text     |
| 4 | PR   | section header   | 1 label + 1 count            | 1 label + 1 count            | PASS  | -        | -                                   |
...
```

**Banned weasel language in PASS rows.** If a `Match=PASS` row contains any of: `approximately`, `roughly`, `looks similar`, `close enough`, `minor difference`, `slightly`, `nearly`, `almost identical` — Gate C5 auto-converts it to `FAIL medium`. Decisive verdicts only. The list lives in `scripts/c5-weasel-detect.sh` (single source of truth, also called by Gate C5).

The same `Match=PASS` rule from C3 Pass 2 §2 applies: PASS-with-caveat is banned. Either the section matches and you write PASS with no hedge, or it doesn't and you write FAIL at the appropriate severity.

#### C5.6.6 — Negative spot-check + 4-anchor proportional check

Append two explicit Q&A blocks to `c5-visual-diff.md`:

```markdown
## Negative spot-check
Q: Is there anything visible in the simulator screenshot that is NOT in the Figma screenshot?
A: <enumerate or "none">

Q: Is there anything visible in the Figma screenshot that is NOT in the simulator screenshot?
A: <enumerate or "none">

## 4-anchor proportional check
| anchor               | figma (x%,y%) | sim (x%,y%) | delta | verdict |
|----------------------|---------------|-------------|-------|---------|
| top-left element     | 4,3           | 4,4         | 0,1   | PASS    |
| top-right element    | 92,3          | 88,4        | 4,1   | PASS    |
| primary CTA center   | 50,82         | 50,86       | 0,4   | PASS    |
| bottom-most element  | 50,95         | 50,98       | 0,3   | PASS    |

## Button width check
| button label / role     | figma w% | sim w% | delta | verdict |
|-------------------------|----------|--------|-------|---------|
| "Continue" (primary CTA)| 87       | 100    | 13    | FAIL    |
| "Skip" (secondary)      | 30       | 30     | 0     | PASS    |
```

Anchor delta > 5pp on either axis = `FAIL high`. If primary CTA isn't present, write `n/a — no CTA` in that row and explain.

**Button width check (mandatory if any button exists on screen).** For every button visible in the simulator AND Figma, measure its width as a percentage of the canvas width (visually estimate from `screenshot-cmp.png` and `c5-simulator-cmp.png`, or use the per-section crop pair from C5.6.3). Compute `delta = |figma_w% - sim_w%|`. **Threshold 3pp** — anything ≥ 3pp is `FAIL high`. The example row above (delta 13 — Continue button bloated from 343pt design to 393pt screen-width) is exactly the cascade-trap bug from `anti-patterns.md` §12.

If no buttons exist on the screen, write `n/a — no buttons on screen` as the only row (still write the block — Gate C5 verifies the block is present). If the screen has buttons but they're invisible in the simulator (hidden, off-screen, conditional), explain per-row instead of skipping the block.

The negative spot-check exists because the structured table is biased toward "does Figma's element appear in the simulator" — it never asks the inverse, so spurious extra simulator content (e.g. system-chrome redraws, debug overlays, leftover placeholder text) routinely escapes detection. The button width check exists because the structured table compares position percentages but rarely catches *width* mismatches at primary-CTA scale; a button stretched from 343pt to 393pt is the most common silent C5 escape.

#### C5.6.7 — Self-attestation

End of `c5-visual-diff.md`:

```markdown
## Attestation
I opened both screenshots and each crop pair, walked the 6-step procedure, and the differences listed above are real. I did not skip any section in c5-sections.md. — verifier
```

Missing attestation = Gate C5 fails. The block is short on purpose — the cost is not the typing, it is signing the audit trail.

After C5.6.7, run Gate C5 (§5.7).

### C5 Edge Cases

| Case | Handling |
|------|----------|
| No Xcode project found | Skip C5, mark `manifest.verification.c5.skipped = "no_project"`. |
| Multiple schemes | Ask user once, stash in `manifest.verification.c5.scheme`. |
| Build fails | Surface compile errors as FAIL high rows, self-fix loop. |
| App boots wrong screen, existing `#Preview` / scheme / test target reaches the screen | Ask once for `previewEntry`, stash and reuse. |
| App boots wrong screen, no existing entry, no driver MCP | Mark `manifest.verification.c5.skipped = "no_entry_path"` and tell the user verbatim per §"C5 Verification Integrity". **Do NOT add a debug route override to the binary** — banned. |
| `osascript` / Simulator clicks blocked (sandbox / permission) | Use the `ios-simulator-verify` skill or `computer-use` MCP (with `request_access`). Do NOT add a launch-arg / env-var override to the binary as a workaround — banned. |
| Simulator unavailable / `simctl` errors | Tell user, mark `manifest.verification.c5.skipped = "simctl_error"`, do not block. |
| Re-run after fix | Reuse `scheme`, `udid`, `previewEntry` from manifest. |
| CI / headless | Detect `CI=true` or `GITHUB_ACTIONS=true` → mark `manifest.verification.c5.skipped = "ci_environment"`. Rely on a follow-up local C5 run before merge. |
| User says "skip C5" / "bỏ qua C5" | NOT honored. Reply with Done-Gate (`SKILL.md` Principle #12) and proceed. The only valid bypasses are the four system reasons listed above. |

### 5.7 — Gate C5 (BASH, mandatory after C5.6)

The build / screenshot checks live here. The structural C5.6 checks (sections file, census, crop count, free-form block, 3-axis row count, negative spot-check, 4-anchor table, attestation, weasel detection) are encapsulated in `scripts/c5-coverage-check.sh` so this block stays short.

```bash
CACHE=".figma-cache/<nodeId>"
FAIL=0

# 1. Build succeeded
[ -s "$CACHE/c5-build.log" ] && grep -qE 'BUILD SUCCEEDED' "$CACHE/c5-build.log" \
  && echo "PASS: build" || { echo "FAIL: build"; FAIL=1; }

# 2. Simulator screenshot is a real PNG
file "$CACHE/c5-simulator.png" 2>/dev/null | grep -q "PNG image data" \
  && echo "PASS: simulator screenshot" || { echo "FAIL: simulator screenshot"; FAIL=1; }

# 2b. C5.5b comparison-safe pair exists (≤2000px on long side)
for IMG in screenshot-cmp.png c5-simulator-cmp.png; do
  if ! file "$CACHE/$IMG" 2>/dev/null | grep -q "PNG image data"; then
    echo "FAIL: $IMG (run C5.5b)"; FAIL=1; continue
  fi
  LONG=$(sips -g pixelWidth -g pixelHeight "$CACHE/$IMG" 2>/dev/null \
         | awk '/pixel(Width|Height)/ {print $2}' | sort -n | tail -1)
  if [ -n "$LONG" ] && [ "$LONG" -le 2000 ]; then
    echo "PASS: $IMG ($LONG px long-side)"
  else
    echo "FAIL: $IMG long-side=$LONG (>2000, many-image limit)"; FAIL=1
  fi
done

# 3. C5.6 coverage (delegates to script — single source of truth)
if scripts/c5-coverage-check.sh --cache "$CACHE"; then
  echo "PASS: C5.6 coverage"
else
  echo "FAIL: C5.6 coverage"
  FAIL=1
fi

# 4. Surface high-severity FAIL count (informational — drives self-fix loop)
HIGH=$(grep -cE '\| *FAIL *\| *high *\|' "$CACHE/c5-visual-diff.md" 2>/dev/null)
[ "${HIGH:-0}" -eq 0 ] && echo "PASS: no high-severity diffs" \
  || echo "INFO: $HIGH high-severity diffs — trigger self-fix"

[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase C5)" || echo "GATE: FAIL (Phase C5)"
```

High-severity diffs feed into the same self-fix loop as C3 Pass 2 (shared counter, `MAX_RETRIES=2`, scoped edits only). Build failures count as FAIL high. A C5.6-coverage FAIL is a structural failure (the agent skipped a step); regen the missing artifacts, do NOT touch code, do NOT bump the retry counter — same handling as a Gate C3-Pass2 structural FAIL.

---

## 6. Example C3 Pass 2 Report

This is a complete, realistic report you can use as a shape reference. Mix of PASS, FAIL high, FAIL medium, N/A.

```markdown
# C3 Pass 2 — Code vs Screenshot Diff Report
nodeId: 3166:70147
generatedAt: 2026-04-26T11:22:33Z
attempt: 1
codeFiles:
  - Features/Onboarding/OnboardingView.swift
  - Features/Onboarding/OnboardingHeader.swift

## Checklist coverage
- LH LS SH BD OP RM IS AL DV BG TR GR SA CH PD BS IF SS

## Findings
| #  | Check | Section        | Figma Spec                              | Source quote                                                              | Code value                                              | File:Line                       | Match | Severity |
|----|-------|----------------|-----------------------------------------|---------------------------------------------------------------------------|---------------------------------------------------------|---------------------------------|-------|----------|
| 1  | LH    | Headline       | font 28, line-height 34                 | design-context.md L42 `style={{fontSize:'28px',lineHeight:'34px'}}`       | .font(.system(size:28)).lineSpacing(6)                  | OnboardingHeader.swift:18       | PASS  | -        |
| 2  | LS    | Headline       | letter-spacing -0.4px                   | design-context.md L43 `letterSpacing:'-0.4px'`                            | (no .tracking modifier on Text)                         | OnboardingHeader.swift:18       | FAIL  | high     |
| 3  | SH    | Primary CTA    | shadow #000 8% y4 blur16                | design-context.md L91 `boxShadow:'0 4px 16px rgba(0,0,0,0.08)'`           | .shadow(radius:8)                                       | OnboardingView.swift:73         | FAIL  | high     |
| 4  | BD    | Card           | 1pt border #E5E5EA, radius 12           | design-context.md L57 `border:'1px solid #E5E5EA',borderRadius:'12px'`    | .overlay { RoundedRectangle(cornerRadius:12).stroke(Color(hex:"E5E5EA"),lineWidth:1) } | OnboardingView.swift:48 | PASS  | -        |
| 5  | OP    | Subtitle       | opacity 0.6                             | design-context.md L46 `opacity:'0.6'`                                     | .opacity(0.6)                                           | OnboardingHeader.swift:25       | PASS  | -        |
| 6  | RM    | Close icon     | tinted to text/secondary                | inventory row 7: renderingMode=template, tint=textSecondary               | Image("icAIClose").resizable() (no .renderingMode)      | OnboardingView.swift:24         | FAIL  | high     |
| 7  | IS    | Facebook icon  | 24x24                                   | inventory row 4: 24x24                                                    | .frame(width:24,height:24)                              | OnboardingView.swift:55         | PASS  | -        |
| 8  | IS    | Close icon     | 20x20                                   | inventory row 7: 20x20                                                    | .frame(width:24,height:24)                              | OnboardingView.swift:25         | FAIL  | medium   |
| 9  | AL    | Headline       | textAlignHorizontal=CENTER, fill-width  | design-context.md L41 `class="text-center"`                               | .multilineTextAlignment(.center) (no .frame(maxWidth:.infinity)) | OnboardingHeader.swift:19       | FAIL  | high     |
| 10 | DV    | n/a — no divider in screen | -                           | -                                                                         | -                                                       | -                               | N/A   | -        |
| 11 | BG    | Sheet header   | ultraThin material                      | design-context.md L37 `backdrop-filter:blur(20px)`                        | .background(.ultraThinMaterial)                         | OnboardingView.swift:14         | PASS  | -        |
| 12 | TR    | Primary CTA    | label single-line, button width 343pt   | inventory row 11: lineCount=1, frame=fill-width                           | .lineLimit(1) (no .minimumScaleFactor)                  | OnboardingView.swift:71         | FAIL  | medium   |
| 13 | GR    | Hero card      | linear top→bottom #FF6B6B → #FFD93D     | design-context.md L62 `linear-gradient(180deg,#FF6B6B,#FFD93D)`           | LinearGradient(colors:[Color(hex:"FF6B6B"),Color(hex:"FFD93D")],startPoint:.top,endPoint:.bottom) | OnboardingView.swift:34 | PASS  | -        |
| 14 | SA    | Container      | content extends behind status bar       | screenshot shows hero gradient continuing under status area              | .ignoresSafeArea(edges:.top) on background only         | OnboardingView.swift:11         | PASS  | -        |
| 15 | CH    | -              | iOS draws status bar / home indicator   | SKILL ABSOLUTE RULE                                                       | grep clean (no "9:41", no Capsule(width:134))           | -                               | PASS  | -        |
| 16 | PD    | Card padding   | 16pt all sides                          | design-context.md L55 `padding:'16px'`                                    | .padding(16)                                            | OnboardingView.swift:50         | PASS  | -        |
| 17 | BS    | Primary CTA    | custom-styled button                    | inventory row 11: customStyle, no system chrome                          | Button { ... }.buttonStyle(.plain)                      | OnboardingView.swift:70         | PASS  | -        |
| 18 | IF    | Hero artwork   | fill-width, scaleMode=FILL              | inventory row 2: contentMode=fill, frame=fill-width                       | Image("heroArtwork").frame(maxWidth:.infinity, height:240) (no .resizable, no .scaledToFill) | OnboardingView.swift:36 | FAIL  | high     |
| 19 | SS    | -              | mockupChrome=true, frame H=812, inset.top=44; headline raw y=88 → adjusted=44 | inventory CONTAINER row: safeAreaInsets=top:44,bottom:34; mockupChrome=true | .padding(.top, 88) (raw figma y, no comment, no subtraction) | OnboardingView.swift:13         | FAIL  | high     |
| 20 | BW    | Primary CTA    | Figma primaryAxisSizingMode=FILL on Button node (button width=343pt = fill the 16pt-padded slot, NOT 393pt screen-width) | inventory row 11: button sizingMode=FILL | Button { HStack { Text("Continue").frame(maxWidth:.infinity); Image("icAIArrow") } } (inner-Text maxWidth cascades up through Button — Button bloats to 393pt screen-width, caller .padding(.horizontal, 16) overridden) | OnboardingView.swift:70 | FAIL  | high     |

## Summary
- total: 20
- pass:  10
- fail:  9   (high: 7, medium: 2, low: 0)
- n/a:   1
```

This report has 7 high FAILs (rows 2, 3, 6, 9, 18, 19, 20) → triggers self-fix loop. After retry, those 7 file:line locations get edits; rows 8 + 12 (medium severity — icon size, missing minimumScaleFactor) also pull into the fix because medium count = 2 > threshold trigger when paired with the high count. Row 19 is the safe-area double-count from `anti-patterns.md` §9; row 18 is the image-fill-mode bug from §10; row 20 is the button-bloat cascade-trap bug from §12 — fixed by moving `.frame(maxWidth: .infinity)` from the inner Text to the Button's outer modifier chain (`Button { HStack { Text("Continue"); Spacer(); Image(...) } }.frame(maxWidth: .infinity)`).

---

## 7. Example C5 Visual Diff Report

This shape mirrors what the C5.6 procedure produces — sections inventory, free-form pass, 3-axis structured table, negative spot-check, 4-anchor proportional check, attestation. Use it as a reference, not a template (the actual artifact lives at `.figma-cache/<nodeId>/c5-visual-diff.md` and references the sibling `c5-sections.md` + `c5-census.md` files).

```markdown
# C5 Visual Diff Report — Figma vs Simulator
nodeId: 3166:70147
generatedAt: 2026-04-26T11:30:14Z
scheme: MyApp
udid: 9F8E7D6C-...
previewEntry: OnboardingView_Previews
sections: 4 (see c5-sections.md)

## What's wrong (free-form, before structured analysis)
The headline weight is clearly wrong — Figma is regular-expanded, simulator
renders semibold-default. The hero CTA's drop shadow has a hard edge in the
simulator vs the soft Figma blur. There is also a white gap at the top of
the simulator screen above the gradient, suggesting `.ignoresSafeArea` is
applied to the container rather than the background.

## Findings
| # | Axis | Section          | Figma                        | Actual                              | Match | Severity | Note                                                         |
|---|------|------------------|------------------------------|-------------------------------------|-------|----------|--------------------------------------------------------------|
| 1 | PR   | Hero card        | 1 illustration + 1 headline  | 1 illustration + 1 headline         | PASS  | -        | -                                                            |
| 2 | LY   | Hero card        | x:0 y:8 w:100 h:38           | y ≈ 12 (top gap)                    | FAIL  | high     | safe-area gap at top                                         |
| 3 | ST   | Hero card        | gradient #FF6B6B → #FFD93D   | banding at midpoint                 | FAIL  | medium   | likely 8-bit color compression                               |
| 4 | PR   | Headline         | 1 line                       | 1 line                              | PASS  | -        | -                                                            |
| 5 | LY   | Headline         | x:8 y:50 w:84 h:6            | matches                             | PASS  | -        | -                                                            |
| 6 | ST   | Headline         | regular, expanded            | semibold, default                   | FAIL  | high     | .fontWeight(.semibold) — needs .regular.fontWidth(.expanded) |
| 7 | PR   | Primary CTA      | 1 button                     | 1 button                            | PASS  | -        | -                                                            |
| 8 | LY   | Primary CTA      | x:8 y:80 w:84 h:6            | matches                             | PASS  | -        | -                                                            |
| 9 | ST   | Primary CTA      | shadow blur=16, y=4          | hard edge, no blur                  | FAIL  | high     | .shadow(radius:8) — needs explicit color+opacity             |
| 10| PR   | Bottom inset     | -                            | -                                   | PASS  | -        | matches safeAreaInset                                        |
| 11| LY   | Bottom inset     | 16pt above home indicator    | matches                             | PASS  | -        | -                                                            |
| 12| ST   | Bottom inset     | transparent                  | transparent                         | PASS  | -        | -                                                            |

## Negative spot-check
Q: Is there anything visible in the simulator screenshot that is NOT in the Figma screenshot?
A: none.

Q: Is there anything visible in the Figma screenshot that is NOT in the simulator screenshot?
A: none — both have hero card, headline, primary CTA, bottom inset.

## 4-anchor proportional check
| anchor               | figma (x%,y%) | sim (x%,y%) | delta | verdict |
|----------------------|---------------|-------------|-------|---------|
| top-left element     | 4,3           | 4,7         | 0,4   | PASS    |
| top-right element    | 92,3          | 92,7        | 0,4   | PASS    |
| primary CTA center   | 50,82         | 50,84       | 0,2   | PASS    |
| bottom-most element  | 50,95         | 50,96       | 0,1   | PASS    |

## Attestation
I opened both screenshots and each crop pair, walked the 6-step procedure, and the differences listed above are real. I did not skip any section in c5-sections.md. — verifier

## Summary
- total: 12
- pass:  7
- fail:  5   (high: 3, medium: 2, low: 0)
```

Note: rows 6 and 9 are the same root cause as C3 Pass 2 high FAILs, but C5 catches them visually if Pass 2 missed them (or confirms the fix worked). Row 2 (safe-area gap) is a runtime-only issue Pass 2 cannot see — it requires the simulator to render. This is the value of C5.

---

## 6. C6 — Asset Completeness (mandatory)

Every Figma-tagged asset MUST land in `Assets.xcassets`, and `Image(systemName:)` MUST NOT silently substitute a Figma asset. This gate is the executable form of the "Assets come from Figma" ABSOLUTE RULE in `SKILL.md`. It runs after codegen + asset copy (Step C4) and before declaring the task done.

```bash
scripts/c6-asset-completeness.sh \
  --registry .figma-cache/<nodeId>/registry.json \
  --xcassets <project>/Assets.xcassets \
  --src      <project-swift-src-root>
```

The script (1) lists every `taggedAssets[].exportName` from `registry.json` and confirms a matching `*.imageset/` directory exists under `--xcassets`, and (2) greps `--src` for `Image(systemName:` violations.

Allow-list (no comment required) for `Image(systemName:)`:
- `chevron.backward` / `chevron.left` — only when the file uses `NavigationStack` or `.toolbar` (heuristic match in the same file).
- `square.and.arrow.up` — for `ShareLink`.
- `xmark.circle.fill` — for `.searchable` clear button.
- `keyboard*` — keyboard control glyphs.

Anything else MUST carry an explicit opt-in comment on the same line OR the previous line: `// allow-systemName: <reason>`. When in doubt, require the comment.

### Example FAIL output → fix → re-run

```
$ scripts/c6-asset-completeness.sh --registry .figma-cache/3166:70147/registry.json --xcassets MyApp/Assets.xcassets --src MyApp/Sources
MISSING IMAGESETS (registry says 12 tagged, 2 not in xcassets):
  - icAIShield.imageset (expected under MyApp/Assets.xcassets)
  - imageAIHero.imageset (expected under MyApp/Assets.xcassets)
SYSTEMNAME VIOLATIONS (1):
  - MyApp/Sources/Onboarding.swift:42: Image(systemName: "shield.fill") — needs Figma asset OR allow comment
FAIL: 2 missing assets, 1 systemName violations
```

Fix:
1. Re-run B3 (`figma_export_assets_unified` with `autoDiscover: true`) to import the missing imagesets — the autoDiscover flag scans the subtree under `nodeId`, so missed icons get picked up automatically.
2. Replace `Image(systemName: "shield.fill")` with `Image("icAIShield")` (the Figma source). If a system glyph is genuinely correct, add `// allow-systemName: <reason>` directly above the call site.

Re-run the script — `PASS` is the only acceptable outcome before declaring done.

---

## 7. C7 — No System Chrome (mandatory)

Generated SwiftUI MUST NOT redraw iOS system chrome (status bar, home indicator, Dynamic Island, notch). iOS already renders these. Drawing them is the executable form of the "Do NOT draw iOS system chrome" ABSOLUTE RULE in `SKILL.md`. This gate runs after codegen and before declaring the task done.

```bash
scripts/c7-no-system-chrome.sh --src <project-swift-src-root>
```

The script greps `*.swift` files for:
- Banned identifiers: `FakeStatusBar`, `HomeIndicator`, `DynamicIsland(...)` used as a custom view, `NotchView`, any `*StatusBar*` view name (excluding UIKit's `UIStatusBar`).
- Status-bar clock literal: `Text("9:41")` and similar.
- Status-bar icons: `Image(systemName: "wifi" | "cellularbars" | "battery.*")`.
- Home-indicator-ish capsule: `Capsule().<...>.frame(...height: 1..6)`.

Apple APIs that legitimately use these names (e.g. `ToolbarItem(placement: .dynamicIsland)`) are excluded by the regex.

### Example FAIL output → fix → re-run

```
$ scripts/c7-no-system-chrome.sh --src MyApp/Sources
SYSTEM CHROME REDRAWS DETECTED (4 hit(s)):
MyApp/Sources/Components.swift:189: [FakeStatusBar] struct FakeStatusBar: View {
MyApp/Sources/Components.swift:192: [status-clock]               Text("9:41")
MyApp/Sources/HomeView.swift:23:     [FakeStatusBar]                   FakeStatusBar()
MyApp/Sources/HomeView.swift:135:    [HomeIndicator]                   HomeIndicator()
fix: delete these views — iOS renders status bar / home indicator / Dynamic Island.
```

Fix:
1. Delete the `FakeStatusBar` / `HomeIndicator` view structs entirely.
2. Remove every call site that mounts them.
3. If the original Figma frame showed content extending behind the status bar, replace with `.ignoresSafeArea(edges: .top)` on the background only — never on the content layer.

Re-run the script — `PASS` is the only acceptable outcome before declaring done.
