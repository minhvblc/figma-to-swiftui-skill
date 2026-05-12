# Skill / Hook / Workflow Improvement Plan

**Premise:** the Bible Widgets session surfaced 9 distinct failure modes that the skill, its hooks, and its workflow map should have prevented but did not. This plan turns each into a concrete repo PR with file changes + acceptance gate.

Each fix obeys CLAUDE.md's invariant rules (Figma is single source of truth; no skipping screens; no skipping gates; banned-substitute MCPs; no system-chrome redraw). Every new script ALSO obeys the "Đồng bộ cross-file (BẮT BUỘC sau mỗi edit chạm vào scripts/)" 4-position checklist.

---

## Audit table — what broke, why, fix-spec ID

| # | Symptom in Bible Widgets session | Root cause in skill / hook / workflow | Wall-time lost | Fix-spec |
|---|---|---|---|---|
| 1 | **Bundle ID confusion** — `simctl launch com.ikame.biblewidgets` returned PIDs from a stale older app, screenshots showed wrong content, led to false "framework owns intro" diagnosis | C5 capture script `c5-capture.sh` doesn't pull bundle ID from `Info.plist`; assumes caller passes correct ID. No hook verifies bundle uniqueness before install. | ~75 min | **A** Pre-flight bundle-id verify |
| 2 | **Wrong IKOnboardingFlow registration pattern** — used `IKDI.onboardingFlow.register(forScreen: .intro) { IKNavigation.makeView(router: IntroRouter(), root: .source) }`, framework didn't honor it; correct pattern is single root View orchestrator `{ BibleOnboardingFlow() }` per authenv2 | No reference doc for IKOnboardingFlow registration semantics; `figma-flow-to-swiftui-feature` Step 4 doesn't distinguish between `.intro` (needs orchestrator View) vs `.main` (any View works) | ~45 min | **B** Ikame onboarding integration doc + gate |
| 3 | **Color name collision** — colorsets named `primary` / `secondary` shadow `Color.primary` / `Color.secondary` from SwiftUI; 2 build warnings every build | `b0b-tokens-codegen.sh` writes colorset names verbatim from token names without checking for SwiftUI built-in shadowing | 15 min | **C** Color-name collision gate + codegen prefix |
| 4 | **Custom fonts not registered** — `AppFont.custom("Inter-Medium", size: 17)` calls fell back to system font; no font files in `Resources/Fonts/`, no `UIAppFonts` in Info.plist | Skill workflow had Phase B0b token codegen but no Phase B0c "fonts fetch + register" step; user (me) had to manually `curl` from GitHub + edit Info.plist | 20 min (this session). Could be hours if user doesn't know font registration | **D** Auto font fetch + Info.plist register |
| 5 | **Built 30 dead native Intro screens** — built full Phase B for Onboarding before discovering framework was rendering "Bible Widgets onboarding" content (turned out to be wrong-bundle issue, but the wasted time was real even after correction) | Skill Phase 0 doesn't include a "launch unmodified scaffold → screenshot baseline" step. By the time C5 runs at end of Phase C, we've already burned 30 screens of effort | ~60 min effective | **E** Phase 0 smoke-test baseline |
| 6 | **`figma_extract_tokens` 403** — file is not Enterprise, returned `FIGMA_API_FORBIDDEN`, had to manually parse design-context.md for hex + font sizes | Skill workflow assumes tokens.json is available after `figma_extract_tokens`; no automated fallback to `figma_extract_fills` + design-context regex | 15 min | **F** Token extract fallback path |
| 7 | **Sim launch failures / stuck state** — multiple times simctl returned "request to open ... failed", required shutdown + boot + reinstall cycles | `c5-capture.sh` doesn't include retry with backoff; doesn't terminate-uninstall-install-launch in the documented sequence | 10 min × 3 occurrences | **G** C5 sim reliability hardening |
| 8 | **No write-time check on registration pattern** — added `register(forScreen: .intro) { IKNavigation.makeView(...) }` and it compiled, no hook flagged it | No PostToolUse hook detects mismatched registration shape | (covered by B) | **B** combined |
| 9 | **`c1-conventions.json` lacked bundleIdentifier + smokeTestResult fields** — downstream scripts couldn't verify which bundle to talk to or whether smoke-test was done | C1 probe doesn't emit these fields | (covered by A + E) | **A + E** combined |

---

## Fix-spec A — Pre-flight bundle-id verify

**Goal:** never again launch `simctl` against the wrong bundle.

| File | Change |
|---|---|
| `scripts/preflight-bundle-verify.sh` (NEW) | Read `Info.plist`'s `CFBundleIdentifier` via `plutil -extract`, write to `.figma-cache/_shared/bundle-id.txt`. Verify no other app with same bundle-ID-prefix is installed in target sim. If conflict, emit `GATE: FAIL` + list to user. Exit non-zero if ambiguous. |
| `scripts/c5-capture.sh` | Read `.figma-cache/_shared/bundle-id.txt` instead of accepting bundle ID as caller arg. Refuse to run if file missing. |
| `scripts/hooks/figma-to-swiftui-bundle-id-gate.sh` (NEW) | PreToolUse hook on any `Bash` tool call matching `xcrun simctl (install|launch|uninstall|terminate)`: reject if bundle ID arg ≠ value in `.figma-cache/_shared/bundle-id.txt`. |
| `c1-conventions.json` schema | Add `bundleIdentifier: string` field. `ikxcodegen-scaffold.sh` populates it post-scaffold. |
| `figma-to-swiftui/references/bundle-id-verification.md` (NEW) | Document the bundle-id gotcha (Bible Widgets case study), prefix-collision example, and the correct `plutil -extract CFBundleIdentifier raw` pattern. |
| `install.sh` glob + `doctor.sh` §7 (×2) + `doctor.sh` §9 drift + hooks Python list | Sync per CLAUDE.md anti-orphan rule. |

**Acceptance gate:** running `bash scripts/preflight-bundle-verify.sh /Users/minh/Desktop/WORK/BibleWidgets` produces `.figma-cache/_shared/bundle-id.txt = "com.ikame.biblewidgets.BibleWidgets"` and `GATE: PASS`. Calling `xcrun simctl launch <sim> com.ikame.biblewidgets` is REJECTED by the new hook (suggests `.BibleWidgets` suffix).

---

## Fix-spec B — Ikame onboarding-framework integration

**Goal:** never again use the wrong registration shape for `IKOnboardingFlow` slots.

| File | Change |
|---|---|
| `figma-to-swiftui/references/ikonboardingflow-integration.md` (NEW) | Document IKOnboardingFlow registration semantics: `.splash`/`.intro`/`.introIap` need **single root View orchestrator** that internally cycles through sub-views via `\.onboardingNextStep` env + calls `\.ikOFDismiss` to handoff. `.main` accepts any View including `IKNavigation.makeView`. Cite authenv2 `OnboardingFlow.swift` pattern; cite Bible Widgets failure case (used `IKNavigation.makeView` for `.intro`, framework ignored it). |
| `figma-flow-to-swiftui-feature/SKILL.md` Step 4 | When `usesIKOnboardingFlow == true` AND scaffolding for `.intro` / `.introIap` / `.splash` slots, generate the orchestrator-View pattern, not the IKNavigation-wrapper pattern. |
| `scripts/hooks/figma-to-swiftui-ikonboarding-pattern-gate.sh` (NEW) | PostToolUse hook on any `Edit`/`Write` touching `AppDelegate.swift` or files matching `*Onboarding*Flow*.swift`: regex-detect `IKDI.onboardingFlow.register(forScreen: .intro)\s*\{\s*IKNavigation` and reject with link to the new reference doc. |
| `c1-conventions.json` schema | Add `usesIKOnboardingFlow: bool`, `iKOnboardingSlots: [string]` (list of slots project will register; default `["main"]`; if IKOnboardingFlow pod detected, suggest `["intro", "main"]` and prompt user). |
| `ikxcodegen-scaffold.sh` | Detect `pod 'IKOnboardingFlow'` in Podfile → set `usesIKOnboardingFlow: true`. |
| Same 4-position sync. |

**Acceptance gate:** writing `IKDI.onboardingFlow.register(forScreen: .intro) { IKNavigation.makeView(router: IntroRouter(), root: .source) }` to any Swift file when `usesIKOnboardingFlow == true` is BLOCKED by hook with message:

> Wrong shape for IKOnboardingFlow `.intro` slot. Use a single root View orchestrator: `{ BibleOnboardingFlow() }`. See ~/.claude/skills/figma-to-swiftui/references/ikonboardingflow-integration.md §3.

---

## Fix-spec C — Color-name collision gate + codegen prefix

**Goal:** never again ship colorsets whose names shadow SwiftUI built-ins.

| File | Change |
|---|---|
| `scripts/c8-color-name-collision.sh` (NEW) | Scan `Assets.xcassets/Colors/` for colorset names matching `primary`/`secondary`/`accent`/`red`/`green`/`blue`/`gray`/`orange`/`pink`/`purple`/`yellow`/`black`/`white`/`clear`/`indigo`/`mint`/`teal`/`cyan`/`brown`. Emit `GATE: FAIL: rename to app<Name>`. Wire into PostToolUse + Stop hooks. |
| `scripts/b0b-tokens-codegen.sh` | When token swiftName matches a SwiftUI built-in Color name, auto-prefix with `app` (so `primary` → `appPrimary`). Emit warning to user. Skip colorset creation if user has `--no-auto-rename` flag. |
| `figma-to-swiftui/references/swiftui-pro/colors.md` (UPDATE) | Append section "Banned colorset names — SwiftUI built-in Color shadowing". List the 19 banned names + the `appX` prefix convention. |
| Same 4-position sync. |

**Acceptance gate:** running `bash scripts/c8-color-name-collision.sh --src <proj>` on the Bible Widgets repo BEFORE R1.1 fix → `GATE: FAIL: rename primary.colorset → appPrimary.colorset, secondary.colorset → appSecondary.colorset`. After R1.1 → `GATE: PASS`.

---

## Fix-spec D — Auto font fetch + Info.plist register

**Goal:** when tokens.json names a font, the skill auto-acquires + registers it. No more silent system fallback.

| File | Change |
|---|---|
| `scripts/b0c-fonts-fetch.sh` (NEW) | Parse `tokens.json` for `fontFamilies` set. For each family, attempt download from a curated mirror table (`Inter` → rsms/inter releases; `Playfair Display` → google/fonts main; etc.). Place .otf/.ttf in `<project>/<projectName>/Resources/Fonts/`. Emit `manifest.fontsFetched: [...]`. |
| `scripts/b0d-info-plist-fonts.sh` (NEW) | Read `manifest.fontsFetched`. Insert/merge `UIAppFonts` array in `<project>/<projectName>/App/Info.plist` (or wherever Info.plist resolves). Idempotent re-run. |
| `figma-flow-to-swiftui-feature/SKILL.md` Phase B | Add B0c (fonts fetch) + B0d (Info.plist register) immediately after B0b (token codegen). |
| `figma-to-swiftui/references/font-registration.md` (NEW) | Document the workflow + fallback (if no mirror for font family, ASK USER and STOP — no silent system fallback). |
| `c1-conventions.json` schema | Add `customFonts: [{family: string, weights: [string], source: string}]`. |
| `scripts/c8-fonts-registered.sh` (NEW) | Verify every `Font.custom("X-Y", ...)` literal in code has matching entry in `UIAppFonts` AND file exists in `Resources/Fonts/`. Emit `GATE: FAIL: Font 'X-Y' referenced but not registered`. |
| Same 4-position sync. |

**Acceptance gate:** running `bash scripts/b0c-fonts-fetch.sh` on Bible Widgets repo (with tokens.json listing Inter + Playfair Display) downloads 6 files to `Resources/Fonts/`, then `b0d-info-plist-fonts.sh` injects `UIAppFonts` array. `c8-fonts-registered.sh` PASSes.

---

## Fix-spec E — Phase 0 smoke-test baseline

**Goal:** before building ANY native screens, capture a baseline screenshot of the unmodified scaffold. Surfaces framework / SDK render behavior early.

| File | Change |
|---|---|
| `scripts/preflight-smoke-test.sh` (NEW) | After scaffold, before Phase A: build → install → launch → wait 7s → screenshot → save to `.figma-cache/_shared/smoke-test-baseline.png`. Diff against an "empty-app" reference (white/black screen depending on theme). If baseline shows real UI (e.g. Bible Widgets onboarding from cached bundle), HALT and prompt user — "framework / cached app already renders something. Investigate before Phase A." |
| `figma-flow-to-swiftui-feature/SKILL.md` Phase 0 | Add smoke-test as MANDATORY step for `brownfield-ikame` mode, and OPTIONAL for `greenfield-vanilla`. |
| `c1-conventions.json` schema | Add `smokeTestResult: { baselinePath, decision: "empty" \| "framework-renders" \| "stale-cache" \| "needs-investigation" }`. |
| Same 4-position sync. |

**Acceptance gate:** running smoke-test on a fresh ikxcodegen scaffold (no `register(forScreen:.intro)` yet) produces `smokeTestResult.decision == "empty"` (yellow placeholder from `IKOFDefaultIntroVC`). Running it on Bible Widgets in stale-cache state produces `decision == "stale-cache"` and HALT.

---

## Fix-spec F — Token extract fallback path

**Goal:** when `figma_extract_tokens` returns 403 (file not Enterprise), don't fail — fall through to manual extraction.

| File | Change |
|---|---|
| `scripts/b0b-tokens-codegen.sh` | If `tokens.json` missing OR empty `colors[]` AND `usesIKAssetSymbol == true`: invoke new `b0a-tokens-from-design-context.sh` to parse design-context.md for inline hex + font sizes. Surface to user as "EXTRACT-TOKENS-403 FALLBACK USED". |
| `scripts/b0a-tokens-from-design-context.sh` (NEW) | Parse all `.figma-cache/<nodeId>/design-context.md` files. Extract `text-\[#XXXXXX\]` / `bg-\[#XXXXXX\]` hex literals + `text-\[NN px\]` font sizes via grep+sed. Emit synthesized `tokens.json`. Mark `source: "fallback-design-context"`. |
| `figma-to-swiftui/references/mcpfigma-setup.md` §"403 handling" | Document the fallback path. |
| Same 4-position sync. |

**Acceptance gate:** running `b0b-tokens-codegen.sh` on a non-Enterprise Figma file produces a valid `tokens.json` with `source: "fallback-design-context"` instead of failing.

---

## Fix-spec G — C5 sim reliability hardening

**Goal:** retry / recovery / clean state for sim install + launch.

| File | Change |
|---|---|
| `scripts/c5-capture.sh` | Wrap install+launch in retry-with-backoff (3 attempts, 2s/4s/8s). Before install: `terminate` → `uninstall` → wait 1s → `install`. Before launch: poll until `simctl get_app_container <bundle>` returns valid path (max 5s). If launch fails 3×: shutdown + boot + retry. |
| `figma-to-swiftui/references/c5-sim-reliability.md` (NEW) | Document the failure modes seen in Bible Widgets session: "request to open com.X failed" → typically stuck installd state, retry after shutdown+boot. Lists the exit codes + diagnostic commands. |
| Same 4-position sync. |

**Acceptance gate:** `c5-capture.sh` succeeds against a freshly-rebooted sim, AND against a sim with stuck installd, both within 30s wall time.

---

## Fix-spec H — Update anti-patterns.md with this session's cases

**Goal:** prevent recurrence by codifying the lesson.

| File | Change |
|---|---|
| `figma-to-swiftui/references/anti-patterns.md` | Append 4 new entries:<br>**AP-15 Bundle ID prefix-launch.** Symptom: simctl launches succeed but screenshots show wrong app. Cause: prefix bundle ID resolves to stale older app. Fix: always `plutil -extract CFBundleIdentifier raw` from Info.plist.<br>**AP-16 IKNavigation-wrapped intro registration.** Symptom: `.intro` slot doesn't render our view. Cause: framework requires a single root View orchestrator. Fix: register `{ <FeatureFlow>() }`, never `{ IKNavigation.makeView(...) }` for onboarding slots.<br>**AP-17 SwiftUI Color built-in shadowing.** Symptom: 2 warnings every build, "color asset name resolves to conflicting Color symbol". Cause: colorset named `primary`/`secondary`/etc. Fix: `app<Name>` prefix convention.<br>**AP-18 Silent system-font fallback.** Symptom: typography renders close to but not exactly matching Figma. Cause: `Font.custom("X-Y", ...)` falls back to system because font file not in bundle. Fix: B0c+B0d auto-fetch + UIAppFonts register. |
| Same 4-position sync (just doc, no script). |

---

## Fix-spec I — `scripts/sync-check.sh` to enforce cross-file sync at PR time

**Goal:** never again merge a new gate that's missing from install.sh / doctor.sh — root cause of past `ikxcodegen-wrap.sh` orphan bug (CLAUDE.md historical incident).

| File | Change |
|---|---|
| `scripts/sync-check.sh` (NEW) | For each `scripts/*.sh` (excl. install/doctor/bootstrap), assert: (a) referenced in `install.sh` SCRIPTS_SRC glob; (b) listed in `doctor.sh` §7 first array; (c) listed in `doctor.sh` §7 second array (`INSTALLED_SCRIPTS_DIR`); (d) listed in `doctor.sh` §9 drift glob; (e) mentioned in ≥1 reference doc (SKILL.md or references/*.md). Emit `GATE: FAIL: <script> missing from <position>` per gap. |
| `scripts/install.sh` | Run sync-check at end of install (after deploy). Refuse to declare success if sync-check FAILs. |
| `scripts/doctor.sh` | Add §10 "sync-check" calling sync-check.sh. |
| `figma-to-swiftui-skill/CLAUDE.md` "Khi sửa script" section | Reference sync-check.sh as the automated way to satisfy the 4-position checklist. |

**Acceptance gate:** running `bash scripts/sync-check.sh` against current repo passes. Adding a new script `scripts/c8-foo.sh` without updating install/doctor → sync-check FAILs.

---

## Sequencing + effort budget

| PR | Effort | Depends on | Priority |
|---|---|---|---|
| A — Bundle-id verify | 2 h | none | **P0** — root cause of biggest time loss |
| B — IKOnboarding integration | 2 h | none | **P0** — second biggest |
| C — Color-name collision gate | 1 h | none | **P1** |
| D — Auto font fetch | 3 h | C (uses tokens.json shape) | **P1** |
| E — Smoke-test baseline | 1.5 h | A (needs bundle-id.txt) | **P1** |
| F — Token extract fallback | 1.5 h | none | **P2** |
| G — C5 sim reliability | 1 h | A | **P2** |
| H — Anti-patterns update | 30 min | A, B, C, D | **P2** (doc only) |
| I — sync-check.sh | 1.5 h | none | **P0** — prevents future orphans |

**Total:** ~14 hours / 3-4 focused sessions.

**Recommended order:** I → A → B → C → D → E → F → G → H. (I first because everything else adds scripts that I will validate.)

---

## Per-fix acceptance gates summary

Each fix is "done" only when:

1. **Code change implemented** in repo.
2. **All 4-position sync done** (install/doctor×2/drift/refdoc) per CLAUDE.md.
3. **Acceptance gate from this doc executed** + screenshot/output saved as evidence.
4. **`bash scripts/doctor.sh` prints `All N of N checks passed`** with N updated.
5. **`bash scripts/sync-check.sh` PASSes** (after I lands).
6. **Replay against Bible Widgets repo** — re-running session intent should HALT or auto-correct at the point where original session went wrong.

The replay gate is the integration test. If we re-do the Bible Widgets session with all 9 fixes installed:
- Phase 0 smoke-test (E) catches the stale-bundle state BEFORE any native code is written.
- Bundle-id gate (A) blocks the prefix `simctl launch` that misled us.
- IKOnboarding integration gate (B) blocks the wrong `register(forScreen: .intro) { IKNavigation.makeView(...) }` shape at write time.
- Color-collision gate (C) flags `primary`/`secondary` colorset names at write time.
- Font-fetch (D) auto-downloads Inter + Playfair Display and registers UIAppFonts as part of B0c+B0d.
- Token fallback (F) silently handles the 403, no manual parsing.
- C5 reliability (G) recovers from the simctl stuck-state without manual shutdown+boot.

Net effect: a future run of the same Bible Widgets project burns ~3 hours instead of ~7. The wasted "30 dead Intro stubs" wouldn't happen because smoke-test catches it.

---

## Invariants to never violate while implementing these fixes

1. **No skill change is allowed to relax F1-F8 from the per-project improvement plan.** If a fix accidentally weakens "no SF Symbols", "no system chrome redraw", "no weasel words", "STOP-and-surface before improvise" — it's rejected.
2. **Every new script obeys 4-position cross-file sync.** Verified by I (sync-check.sh) automatically.
3. **Reference doc per new script.** No orphan scripts (per CLAUDE.md historical bug).
4. **Hooks block at write-time, not just at end-of-session.** PostToolUse on Edit/Write of the specific failing pattern. Stop-gate alone is too late.
5. **Pre-flight gates fail loud.** No `GATE: SKIP` for things that should be PASS. `SKIP` is for genuine system-level unavailability (no sim, no MCP), not for "let's skip this one".

---

# Round 2 — BibleWidgetsApp session (2026-05-12)

A second end-to-end run against the same Figma file `qKOTZUKyYFV4GCn4FMMehS` (47 screens, 422 tagged assets), in a fresh `/Users/minh/Desktop/WORK/BibleWidgetsApp` greenfield-vanilla project. Many of A-I fixes from Round 1 are now landed (preflight bundle verify works, smoke test runs, token codegen pipeline exists). This round surfaces **NEW gaps** the first run didn't hit, plus some Round-1 fixes that need tuning.

Each entry: `Symptom` (what hurt) → `Where` (file/line/script) → `Fix-spec` (concrete change).

## Tier 1 — Blockers / High friction

### G24. `figma_extract_tokens` 403 fallback assumes per-screen design contexts already exist

**Symptom.** `b0a-tokens-from-design-context.sh` (the F-fix from Round 1) requires `.figma-cache/<nodeId>/design-context.md` to already exist. But token codegen is supposed to run BEFORE Phase A (so view files can reference `Color.X`). On Bible Widgets I had to fetch design-context for the style-guide node manually then write `tokens.json` by hand from the inline hex declarations.

**Fix-spec.** Add new script `scripts/b0a-tokens-from-style-guide.sh <fileKey> <styleGuideNodeId> --output tokens.json` that:
1. Calls `mcp__figma-desktop__get_design_context` on `<styleGuideNodeId>` (no per-screen loop)
2. Regex-extracts inline hex (`#RRGGBB[AA]?`), `Font(family:..., size:..., weight:...)` declarations, and the "Styles used" footer
3. Emits tokens.json with whatever it found
4. Updates the F-fix error message to mention BOTH fallback paths.

### G25. Style-guide page is incomplete — actual screens use tokens NOT advertised by style guide

**Symptom.** Style guide (3:1972) only showed `Heading 1-6` (Inter Bold/SemiBold 56/48/40/32/24/20). But actual intro screens use **Playfair Display SemiBold 28** (Large Title/28/Semibold) and **Inter Medium 17** (Headline/17/Medium), neither in the style-guide page. Required 3 rounds of tokens.json augmentation as I encountered each new style in per-screen design-contexts.

**Fix-spec.**
1. Add `scripts/b0a-token-coverage.sh` that after Phase A walks every `design-context.md` in `.figma-cache/<nodeId>/`, extracts the "*Styles used in this design*" footer (designer-named tokens, not just literals), unions with `_shared/tokens.json`, emits delta report ("8 colors + 5 typography NOT in style-guide-page; appended to tokens.json").
2. Re-run `b0b-tokens-codegen.sh` after coverage pass before any Phase B implementation.
3. SKILL.md callout: *"Treat the style-guide page as one sample of the design system, not a contract. The actual token set lives in per-screen Styles-used footers."*

### G26. `b0c-fonts-fetch.sh` mirror URLs are dead (Inter v4 + Playfair Display)

**Symptom.** Called `b0c-fonts-fetch.sh --tokens .../tokens.json` for Inter + Playfair Display. ALL 6 fetches returned `curl failed` (verified `HTTP 404` on `https://github.com/rsms/inter/raw/v4.0/docs/font-files/Inter-Regular.otf`). The rsms/inter repo restructured — `docs/font-files/` no longer exists in v4; fonts now ship in `Inter-4.0.zip` release artifact under `extras/ttf/`. Had to manually `curl` + `unzip` + place files.

**Fix-spec.**
1. Update Inter URL to release-zip extraction: `https://github.com/rsms/inter/releases/download/v4.0/Inter-4.0.zip` → `unzip -j … extras/ttf/Inter-${w}.ttf`. **Verified live 2026-05-12.**
2. Update Playfair URL to: `https://github.com/google/fonts/raw/main/ofl/playfairdisplay/PlayfairDisplay%5Bwght%5D.ttf` (variable font). **Verified live 2026-05-12.**
3. Add `curl -fsLI <url>` precheck before each download — if 404 emit `GATE: FAIL — mirror dead at scripts/b0c-fonts-fetch.sh:<line>, please update`.
4. Move curated URLs to JSON config (`scripts/fonts-mirrors.json`) so updating doesn't require editing bash.

### G27. `b0c-fonts-fetch.sh` only reads `typography[].family`, not `typography[].fontFamily`

**Symptom.** My `tokens.json` typography entries used `fontFamily` (matches `figma_extract_tokens` 0.3.0+ output schema). The script parsing at line 61-63 only checks `entry.get('family')`. So even with full typography data, output was "No custom fonts in tokens.json". Workaround: add top-level `fontFamilies: ["Inter"]`.

**Fix-spec.** Change parsing to: `name = entry.get('fontFamily') or entry.get('family'); if name: fams.add(name)`.

### G28. Color shadowing call-form ambiguity not visible in skill output

**Symptom.** `b0b-tokens-codegen.sh` emits *light-only* tokens as `extension Color { static let appPrimary = … }` (call site: `Color.appPrimary`). *Dual-mode* tokens (darkHex present) go to Asset Catalog colorsets (call site: `Color(.appPrimary)`). Two forms NOT interchangeable. With tokens.json from style-guide fallback (all light-only), every reference must be `Color.X`. I wrote `Color(.appBlack)` in 3 files based on iOS-17 default docs; compile failed with cryptic `Reference to member 'appBlack' cannot be resolved without a contextual type`. Required bulk-rewrite.

**Fix-spec.**
1. Add `scripts/c2-color-call-form-gate.sh` (PostToolUse) that scans `*.swift` for `Color(.X)` where X is in light-only set per `Color+Tokens.swift`, OR `Color.X` where X is dual-mode. FAIL with file:line + correct form.
2. Update `b0b-tokens-codegen.sh` output to PRINT call form table per token (e.g. `appPrimary → Color.appPrimary (light-only)`).
3. SKILL.md C2 note: *"If unsure: light-only tokens (no darkHex) → `Color.X`. Dual-mode → `Color(.X)`. Check `Color+Tokens.swift` static let listing."*

### G29. Asset symbol `x` between digits auto-converts to `X` — silent compile fail

**Symptom.** Asset export produces imageset `icAIBackground375x812.imageset`. Xcode's auto-generated `ImageResource` extension converts inner `x` between digits to `X`: `static let icAIBackground375X812 = …`. My SwiftUI code wrote `Image(.icAIBackground375x812)` (matched the exportName from manifest) → compile error `type 'ImageResource' has no member 'icAIBackground375x812'`. Affected 9 references across 3 files. Required regex bulk-fix.

**Fix-spec.**
1. **MCPFigma server-side (preferred):** `figma_export_assets_unified` should rename imagesets with `X` (uppercase) between digits so Xcode-generated symbol matches exportName. e.g. `icAIBackground375X812.imageset`.
2. **Skill-side fallback:** add write-time hook `scripts/hooks/figma-to-swiftui-asset-symbol-case-gate.sh` that converts inner `x` → `X` in `Image(.X)` references against `manifest.rows[].exportName`.
3. Add to `references/asset-handling.md` §"Naming convention" the precise rule + example.

## Tier 2 — Workflow friction

### G30. Preflight script CLI flags inconsistent

**Symptom.** `preflight-bundle-verify.sh` and `preflight-smoke-test.sh` take POSITIONAL arg (project folder), not `--project <path>` flag. `b0d-info-plist-fonts.sh` takes `--info` + `--fonts` (no `--project`). `b0c-fonts-fetch.sh` takes `--tokens` + `--output`. Three different conventions; agents try `--project` first and get FAIL.

**Fix-spec.** Standardize ALL preflight + B0* scripts on `--project <path>` flag. Each script auto-derives sub-paths. Update SKILL.md examples. Add `scripts/script-cli-conventions.md`.

### G31. Bundle-id prefix collision uses substring match (overly broad)

**Symptom.** Set `PRODUCT_BUNDLE_IDENTIFIER: com.ikame.biblewidgetsapp`. `preflight-bundle-verify.sh` flagged collision with `com.ikameglobal.FigmaSkillTestV2` — but `com.ikame` is NOT a dotted-component prefix of `com.ikameglobal`. They're distinct namespaces.

**Fix-spec.** Change collision detection to dotted-component aware: `grep -E "^${escaped_prefix}\.[^.]+$|^${escaped_prefix}$"` — require the next char after prefix be `.` or EOL. Add unit test.

### G32. `preflight-smoke-test.sh` invokes xcodebuild with `-scheme project` (typo bug)

**Symptom.** Output: `xcodebuild: error: The workspace named "BibleWidgetsApp" does not contain a scheme named "project"`. Script presumably derives scheme name from project arg but interpolates wrong (passes literal string `project`).

**Fix-spec.** Use `xcodebuild -list -project <path> -json` to discover real scheme name, cache to `.figma-cache/_shared/scheme.txt`. Add fixture-based unit test.

### G33. `preflight-smoke-test.sh` overly conservative classification

**Symptom.** Smoke test built + installed + launched scaffold successfully. Screenshot showed literal scaffold copy "Bootstrap — replace with onboarding entry". Classification returned `needs-investigation` → HALT. The screenshot was the LEGITIMATE scaffold output.

**Fix-spec.** Add `empty-scaffold-text-match` heuristic: if screenshot contains text matching `/Bootstrap.*onboarding|replace with/i` (literal copy from `vanilla-scaffold.sh`), classify `empty` not `needs-investigation`. Use the bundle-id we just installed as additional confirmation.

### G34. `vanilla-scaffold.sh` writes `screenFolderConvention: "ikame-feature-flat"` for non-Ikame greenfield

**Symptom.** Scaffold output `c1-conventions.json` set `screenFolderConvention: "ikame-feature-flat"` with `usesIKCoreApp: false`. That's the brownfield-Ikame layout, but project is greenfield-vanilla. Canonical for vanilla is `one-screen-per-folder`. Had to manually edit.

**Fix-spec.** Map `scaffoldVariant: "vanilla"` → `screenFolderConvention: "one-screen-per-folder"`. Map `scaffoldVariant: "ikxcodegen"` → preserved. Add unit test.

### G35. `vanilla-scaffold.sh` `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS` not set by default

**Symptom.** After exporting 422 assets, `Image(.icAIBackground375X812)` calls compile-failed because asset symbols weren't auto-generated. Had to add `ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS: "YES"` + `ASSETCATALOG_COMPILER_GENERATE_ASSET_SYMBOLS: "YES"` to project.yml.

**Fix-spec.** `vanilla-scaffold.sh` should emit both settings by default in `project.yml`. Xcode 15+ supports it; for Xcode 14 fallback, add a conditional.

### G36. `vanilla-scaffold.sh` uses `GENERATE_INFOPLIST_FILE: YES` — blocks UIAppFonts injection

**Symptom.** Scaffold sets `GENERATE_INFOPLIST_FILE: YES` (no source Info.plist file). To register custom fonts via `UIAppFonts`, you need a real Info.plist (or build-setting `INFOPLIST_KEY_UIAppFonts` which doesn't support array values well). Had to switch to `GENERATE_INFOPLIST_FILE: NO` + create Info.plist + inject UIAppFonts.

**Fix-spec.** `vanilla-scaffold.sh` should ALWAYS emit a real Info.plist (with sensible defaults) + reference it in `project.yml` via `INFOPLIST_FILE:`. This lets `b0d-info-plist-fonts.sh` work out-of-the-box.

## Tier 3 — Agent ergonomics

### G37. No write-time gate for `Image(systemName:)` violations

**Symptom.** I wrote `Image(systemName: "checkmark")` in `IntroBackground.swift:107` for option-row selected indicator. The c6-asset-completeness.sh hook (set up by F-fix) didn't catch this at write time (runs at session end). I caught it on review and rewrote to `CheckmarkShape`.

**Fix-spec.** `scripts/hooks/figma-to-swiftui-banned-pattern-gate.sh` should PostToolUse-grep ALL Swift Write/Edit content for `Image\(systemName:` and FAIL with `Did you mean to use an exported Figma asset? Check .figma-cache/<nodeId>/manifest.rows[].exportName.` Allow comment-bypass `// allow-systemName: <reason>`.

### G38. `IntroTopBar(onBack:..., showSkip: false)` — arg-order Swift error at build time

**Symptom.** Wrote callers passing args in semantic-natural order. Swift requires declaration order. 4 files needed fixing. Avoidable if write-time gate validates.

**Fix-spec.** Add `scripts/c8-arg-order.sh` (warn only) that parses Swift call sites against declarations. Low priority — Swift compiler catches; just slows iteration.

### G39. `figma_extract_fills` returns empty for solid-only nodes (style guide)

**Symptom.** Called `figma_extract_fills(qKOTZUKyYFV4GCn4FMMehS, 3:1972)` for the style-guide node. Got `nodes: []` because server filters out "uninteresting" SOLID fills. But for token-fallback I'd WANT them.

**Fix-spec.** Add `--include-all-fills` flag (default false) to `figma_extract_fills`. When true, return SOLID fills with full opacity too.

## Tier 4 — Scope / process

### G40. 47-screen flow blows past skill's parallelism budget

**Symptom.** Skill default `parallelBudget=3` (cluster of 3 screens). For 47 screens: 16 clusters × ~10s wall-time = ~3 min for design-context fetches alone. Plus 47 screenshots, 47 asset exports, 47 manifest writes. Total Phase A: 15+ min. Context budget binding.

**Fix-spec.**
1. For flows ≥ 20 screens, raise default `parallelBudget` to 6.
2. Add `--archetype-mode` flag: identify 5-7 representative screens, do full Phase A on those, lighter pass on rest. Phase B pattern-clones from archetypes.
3. Add timing-budget tracker — if wall-time > N seconds, warn before continuing.

### G41. "Big-flow" mode (N > 20 screens) not documented

**Symptom.** Skill gates (C5+C5.6) designed for 5-15 screens. On 47-screen flows, full per-screen C5 = ~3-5min × 47 = ~3+ hours wall-time. Impractical.

**Fix-spec.** Add `figma-flow-to-swiftui-feature/SKILL.md` Step 7 sub-section: "When N > 20 screens, full per-screen C5 is impractical. Run full C5 on `tier1Screens` (user-selected or auto-archetype-detected). For tier2: require only (a) Gate C5 build PASS, (b) per-screen cache exists, (c) screen appears in ios-simulator-verify walkthrough output."

### G42. Stub-view template for "partial slice" deliveries

**Symptom.** When delivering N main screens + (47-N) stubs (partial slice), the agent rewrites 40 boilerplate views. Skill should provide a generator.

**Fix-spec.** Add `scripts/c2-stub-screen.sh --screen <Name> --figma-node <nodeId> --feature <Feature>` that generates a minimal compile-clean view with `// TODO: implement from figma node <nodeId>` + the right folder location per `screenFolderConvention`.

## Summary

| Tier | Round-2 count | Notes |
|---|---|---|
| 1 Blockers | 6 (G24-G29) | Token API 403 fallback path, style-guide ≠ truth, font mirrors dead, x→X case, color call-form |
| 2 Workflow friction | 7 (G30-G36) | CLI flags, prefix matching, smoke-test bug + classification, scaffold defaults |
| 3 Agent ergonomics | 3 (G37-G39) | systemName gate, arg-order gate, include-all-fills flag |
| 4 Scope/process | 3 (G40-G42) | Big-flow parallelism, archetype mode, stub generator |
| **Total** | **19** | **+ Round 1's 9 = 28 total documented gaps** |

**Bottom line.** Round 1 fixes (A-I) successfully closed the bundle-id and IKOnboardingFlow failure modes. The skill now produces correct, build-passing SwiftUI for a Figma file — proven by `BibleWidgetsApp` rendering Intro 2 visually faithful to Figma. But getting there required 6 explicit workarounds for Tier-1 gaps (G24-G29) + manual font fetch + bulk asset-symbol fix.

**Highest-leverage fixes:**
1. **G24+G25** (style-guide token coverage): closes the "tokens.json is incomplete on first try" pain. Saves ~15 min per new file.
2. **G26+G27** (font fetch reliability): unblocks Phase B0c entirely. Saves ~10 min when mirrors die.
3. **G29** (x→X case): silent compile fail that no agent will guess. Saves ~10 min debug time.
4. **G33** (smoke-test classification): unblocks Phase 0 GATE. Saves ~5 min false-positive.

Closing the 4 highest-leverage Tier-1 gaps would cut a 47-screen flow run by ~40 minutes and eliminate the need for agent improvisation on first contact.

