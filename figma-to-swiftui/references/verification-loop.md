# Verification Loop

The executable procedures behind C3 Pass 2 (offline diff report) and C5 (build + simulator screenshot). Both layers exist because mental walk-throughs are easy to fake — the agent claims PASS without doing the work. This file defines artifacts that gates can grep and count, applying the same philosophy as Gate A/B in SKILL.md: *"the agent can lie, but `file <path>` cannot."*

Read this when you reach Step C3 Pass 2 or Step C5.

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
- DV    divider color/opacity/height
- BG    background material (blur) behind text
- TR    text truncation / line limit
- GR    gradient direction & stops
- SA    safe-area behavior
- CH    no system chrome drawn
- PD    explicit padding (no SwiftUI defaults)
- BS    .buttonStyle(.plain) on custom buttons

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
- **Check** — one of the 15 codes (LH..BS).
- **Section** — visual section name (e.g. "Headline", "Primary CTA", "Card row 2"). Use `-` only when the row is `CH` or otherwise screen-wide.
- **Figma Spec** — the value as Figma intends it (e.g. `font-size 28, line-height 34`).
- **Source quote** — verbatim string from `design-context.md` (with line number) OR from the inventory in scratch context. See §3.
- **Code value** — verbatim copy of the relevant SwiftUI modifier(s).
- **File:Line** — `<filename.swift>:<line>` pointing to the line being judged. `-` for screen-wide checks.
- **Match** — `PASS`, `FAIL`, or `N/A`.
- **Severity** — `high`, `medium`, `low` for FAIL; `-` for PASS; `-` for N/A.

Minimum 12 rows total. Every check letter must appear ≥1 time.

---

## 2. Severity Rubric

| Severity | Definition | Examples |
|----------|------------|----------|
| `high`   | Visible mismatch a user would notice immediately. Drives self-fix loop. | Wrong font size, missing line-height, missing shadow, wrong icon size by >2pt, wrong renderingMode (icon untinted that should tint), drawing system chrome (status bar/home indicator), `Image(systemName:)` substituting a Figma asset, missing border, wrong corner radius by >2pt. |
| `medium` | Off-by-small, non-obvious to most users but breaks pixel parity. | Padding off by 1–2pt, spacing off by 1–2pt, opacity off by 0.05, gradient stop position off by ≤10%. |
| `low`    | Cosmetic / ambiguous. Surfaced but does NOT trigger retry. | Line limit unclear from screenshot, alignment ambiguous when text fits in one line, `.tracking(0)` vs no `.tracking(...)` (equivalent). |
| `N/A`    | No element of this kind exists on the screen. Reason required. | "no divider in screen", "no gradient on screen", "no custom button — only NavigationLink default". |

Self-fix loop triggers on `high` only by default. If `medium` count > 2, also trigger (see §4). `low` rows are reported but never retried.

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
for code in LH LS SH BD OP RM IS DV BG TR GR SA CH PD BS; do
  grep -qE "^\| *[0-9]+ *\| *${code} *\|" "$REPORT" || MISSING="$MISSING $code"
done
[ -z "$MISSING" ] && echo "PASS: all checks covered" || { echo "FAIL: missing checks:$MISSING"; FAIL=1; }

# 4. Row count
ROW_COUNT=$(grep -cE '^\| *[0-9]+ *\|' "$REPORT")
[ "${ROW_COUNT:-0}" -ge 12 ] && echo "PASS: $ROW_COUNT rows" \
  || { echo "FAIL: only $ROW_COUNT rows (need >=12)"; FAIL=1; }

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

C5 is `mandatory-with-opt-out`: by default, after C3 Pass 2 succeeds, propose this validation. User can decline with phrases like `skip C5`, `skip validate`, `no build`, `bỏ qua C5`, `không cần build`. Persist the choice in `manifest.verification.c5.userChoice` so re-runs don't re-prompt.

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

### C5.3 — Build for simulator

```bash
mkdir -p ".figma-cache/<nodeId>"
xcodebuild -scheme "$SCHEME" \
  -destination "platform=iOS Simulator,id=$UDID" \
  -configuration Debug \
  -derivedDataPath ".figma-cache/<nodeId>/derived" \
  build 2>&1 | tee ".figma-cache/<nodeId>/c5-build.log"
```

On build failure: parse the last 50 lines of `c5-build.log` for compile errors. Surface each error as a FAIL row in `c5-visual-diff.md` (Section: `build`, Severity: `high`). Trigger self-fix loop on those. Do NOT proceed to install.

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

### C5.5 — Capture

```bash
sleep 2
xcrun simctl io "$UDID" screenshot ".figma-cache/<nodeId>/c5-simulator.png"
file ".figma-cache/<nodeId>/c5-simulator.png" | grep -q "PNG image data" \
  || { echo "FAIL: simctl screenshot did not produce PNG"; exit 1; }
```

### C5.6 — Side-by-side compare

The skill does not ship a pixel-diff binary. Use the model's vision:

1. Open `.figma-cache/<nodeId>/screenshot.png` (Figma) and `.figma-cache/<nodeId>/c5-simulator.png` (actual) in context.
2. Walk the screen top-down. For each visual section, write one row in `.figma-cache/<nodeId>/c5-visual-diff.md` using the same table format as C3 Pass 2 (replace the `Source quote` column with a `Note` column for free-text observations like "actual is 4pt taller, looks like extra padding above subtitle").
3. Special focus on items Pass 2 cannot see — these are the reasons C5 exists at all:
   - Real font rendering at simulator DPI (Pass 2 can't see this; the font may render lighter than expected).
   - Real shadow appearance (radius 16 in code may look different from the Figma render at 1×).
   - Real safe-area on the chosen simulator (iPhone 15 Pro vs iPhone SE).
   - Real keyboard avoidance (if the screen has a TextField, focus it and re-screenshot).
   - Real animation start state (sheet/popover entry).
4. Run Gate C5 (BASH).

The Figma screenshot and the simulator screenshot will have different pixel sizes / scales. Compare composition and values, not absolute pixel positions.

### C5 Edge Cases

| Case | Handling |
|------|----------|
| No Xcode project found | Skip C5, mark `manifest.verification.c5.skipped = "no_project"`. |
| Multiple schemes | Ask user once, stash in `manifest.verification.c5.scheme`. |
| Build fails | Surface compile errors as FAIL high rows, self-fix loop. |
| App boots wrong screen | Ask once for `previewEntry`, stash and reuse. |
| Simulator unavailable / `simctl` errors | Tell user, mark `manifest.verification.c5.skipped = "simctl_error"`, do not block. |
| User opts out | Mark `manifest.verification.c5.userChoice = "opt_out"`, finish without running. |
| Re-run after fix | Reuse `scheme`, `udid`, `previewEntry` from manifest. |
| CI / headless | C5 requires a Mac with Xcode + simulators. In CI, skip C5; rely on C3 Pass 2. |

### 5.7 — Gate C5 (BASH, mandatory after C5.6)

```bash
CACHE=".figma-cache/<nodeId>"
FAIL=0
[ -s "$CACHE/c5-build.log" ] && grep -qE 'BUILD SUCCEEDED' "$CACHE/c5-build.log" \
  && echo "PASS: build" || { echo "FAIL: build"; FAIL=1; }
file "$CACHE/c5-simulator.png" 2>/dev/null | grep -q "PNG image data" \
  && echo "PASS: simulator screenshot" || { echo "FAIL: simulator screenshot"; FAIL=1; }
[ -s "$CACHE/c5-visual-diff.md" ] && grep -q '^## Summary' "$CACHE/c5-visual-diff.md" \
  && echo "PASS: visual diff report" || { echo "FAIL: visual diff report"; FAIL=1; }
HIGH=$(grep -cE '\| *FAIL *\| *high *\|' "$CACHE/c5-visual-diff.md" 2>/dev/null)
[ "${HIGH:-0}" -eq 0 ] && echo "PASS: no high-severity diffs" \
  || echo "INFO: $HIGH high-severity diffs — trigger self-fix"
[ $FAIL -eq 0 ] && echo "GATE: PASS (Phase C5)" || echo "GATE: FAIL (Phase C5)"
```

High-severity diffs feed into the same self-fix loop as C3 Pass 2 (shared counter, `MAX_RETRIES=2`, scoped edits only). Build failures count as FAIL high.

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
- LH LS SH BD OP RM IS DV BG TR GR SA CH PD BS

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
| 9  | DV    | n/a — no divider in screen | -                           | -                                                                         | -                                                       | -                               | N/A   | -        |
| 10 | BG    | Sheet header   | ultraThin material                      | design-context.md L37 `backdrop-filter:blur(20px)`                        | .background(.ultraThinMaterial)                         | OnboardingView.swift:14         | PASS  | -        |
| 11 | TR    | Subtitle       | maxLines 2                              | design-context.md L48 `WebkitLineClamp:'2'`                               | .lineLimit(2)                                           | OnboardingHeader.swift:26       | PASS  | -        |
| 12 | GR    | Hero card      | linear top→bottom #FF6B6B → #FFD93D     | design-context.md L62 `linear-gradient(180deg,#FF6B6B,#FFD93D)`           | LinearGradient(colors:[Color(hex:"FF6B6B"),Color(hex:"FFD93D")],startPoint:.top,endPoint:.bottom) | OnboardingView.swift:34 | PASS  | -        |
| 13 | SA    | Container      | content extends behind status bar       | screenshot shows hero gradient continuing under status area              | .ignoresSafeArea(edges:.top) on background only         | OnboardingView.swift:11         | PASS  | -        |
| 14 | CH    | -              | iOS draws status bar / home indicator   | SKILL ABSOLUTE RULE                                                       | grep clean (no "9:41", no Capsule(width:134))           | -                               | PASS  | -        |
| 15 | PD    | Card padding   | 16pt all sides                          | design-context.md L55 `padding:'16px'`                                    | .padding(16)                                            | OnboardingView.swift:50         | PASS  | -        |
| 16 | BS    | Primary CTA    | custom-styled button                    | inventory row 11: customStyle, no system chrome                          | Button { ... }.buttonStyle(.plain)                      | OnboardingView.swift:70         | PASS  | -        |

## Summary
- total: 16
- pass:  12
- fail:  3   (high: 3, medium: 1, low: 0)
- n/a:   1
```

This report has 3 high FAILs (rows 2, 3, 6) → triggers self-fix loop. After retry, those 3 file:line locations get edits; row 8 (medium icon size) is also fixed if `medium > 2` threshold met (here it's only 1 medium, so it stays as-is and surfaces to the user at the end if not auto-fixed).

---

## 7. Example C5 Visual Diff Report

```markdown
# C5 Visual Diff Report — Figma vs Simulator
nodeId: 3166:70147
generatedAt: 2026-04-26T11:30:14Z
scheme: MyApp
udid: 9F8E7D6C-...
previewEntry: OnboardingView_Previews

## Findings
| # | Section        | Figma                        | Actual                              | Match | Severity | Note                                              |
|---|----------------|------------------------------|-------------------------------------|-------|----------|---------------------------------------------------|
| 1 | Hero gradient  | smooth #FF6B6B → #FFD93D     | banding visible at midpoint         | FAIL  | medium   | Likely 8-bit color compression — acceptable on device |
| 2 | Headline       | regular weight, expanded     | semibold weight rendered            | FAIL  | high     | .fontWeight(.semibold) on text — should be .regular.fontWidth(.expanded) |
| 3 | CTA shadow     | soft blur                    | hard edge, no blur                  | FAIL  | high     | .shadow(radius:8) renders sharp; need explicit color+opacity |
| 4 | Safe area top  | gradient extends behind      | white gap above gradient            | FAIL  | high     | .ignoresSafeArea applied wrong — on container, not background |
| 5 | Close icon     | tinted secondary             | full color (untinted)               | FAIL  | high     | matches C3 Pass 2 row 6 — same root cause       |
| 6 | Bottom spacing | 16pt above home indicator    | matches                             | PASS  | -        | .safeAreaInset working as expected               |

## Summary
- total: 6
- pass:  1
- fail:  5   (high: 4, medium: 1, low: 0)
```

Note: row 5 here is the same root cause as C3 Pass 2 row 6, but C5 catches it visually if Pass 2 missed it (or confirms the fix worked). Row 4 (safe-area gap) is a runtime-only issue Pass 2 cannot see — it requires the simulator to render. This is the value of C5.
