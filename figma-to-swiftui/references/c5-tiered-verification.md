# C5 verification — 3-tier requirements (P1-6)

The original C5 specification requires `simctl boot` + `simctl install` + `simctl launch` + `simctl io screenshot` + structured visual diff (C5.6) for every screen. On a real machine that's typically blocked because:

- `osascript` UI scripting requires Accessibility access not granted to terminal.
- `cliclick` is not installed.
- `ios-simulator-verify` skill not present.
- CI environment has no simulator runtime.

When the agent can't drive the simulator, the original spec offers one binary choice: succeed completely OR skip with one of four system reasons (`no_project`, `simctl_error`, `ci_environment`, `no_entry_path`). In practice this produces fake "skipped" entries from agents who didn't try Tier 1, and missing audit trails when agents hit Tier 2 limits.

This document splits C5 into three tiers. Each has explicit minimum artifacts. The Done-Gate accepts the highest tier achieved + a truthful note about what was NOT checked.

---

## Tier 1 (mandatory) — build + launch + first-screen snapshot

The non-negotiable baseline. Every C5 run, regardless of UI-driver availability, MUST produce these artifacts:

| Artifact | Path | Source |
|---|---|---|
| Build log | `.figma-cache/_shared/c5-build.log` | `xcodebuild build` stdout/stderr |
| Boot log | `.figma-cache/_shared/c5-boot.log` | `xcrun simctl boot` exit + state |
| Install log | `.figma-cache/_shared/c5-install.log` | `xcrun simctl install` exit |
| Launch log | `.figma-cache/_shared/c5-launch.log` | `xcrun simctl launch` exit + pid |
| First-screen screenshot | `.figma-cache/_shared/c5-first-screen.png` | `xcrun simctl io screenshot` after launch |

Tier 1 PASS criteria:
- `xcodebuild build` exit 0.
- Simulator booted (state == "Booted").
- App installed (exit 0).
- App launched (exit 0).
- Screenshot file exists AND is a valid PNG AND > 1 KB (proves SwiftUI rendered something, not just black).

Tier 1 cannot be skipped except for system reasons (`no_project`, `simctl_error`, `ci_environment`). Even in those cases, the build log MUST exist — `xcodebuild build` is platform-independent.

When Tier 1 succeeds and Tier 2/3 are blocked, that's fine — the agent has proof the app at least compiles and renders the entry screen.

---

## Tier 2 (recommended) — full walkthrough

Drives the simulator through the planned user journey. Each screen reachable from the entry point gets visited, screenshotted, and stored.

**Required driver:**
- `ios-simulator-verify` skill (preferred — accessibility-id based, deterministic), OR
- `computer-use` MCP with `request_access` for Simulator (pixel-coordinate clicks, requires user approval), OR
- Pre-existing XCUITest target in the project that walks the flow (run via `xcodebuild test`).

**Artifacts (in addition to Tier 1):**

| Artifact | Path |
|---|---|
| Per-screen screenshot | `.figma-cache/<nodeId>/c5-simulator.png` (one per screen) |
| Walkthrough plan | `.figma-cache/_shared/c5-walkthrough-plan.md` |
| Walkthrough log | `.figma-cache/_shared/c5-walkthrough.log` |
| Findings table | `.figma-cache/_shared/c5-findings.md` (verified / degraded / not-checked) |

PASS criteria:
- Every `registry.screens[]` (or `candidateScreens[]`) nodeId has a `c5-simulator.png` OR a documented `not-checked` reason in `c5-findings.md`.
- Findings table has at least 3 coverage axes per `feature-completeness.md`: happy path, one recovery, one conditional fork.

If `ios-simulator-verify` isn't available and `computer-use` isn't granted, Tier 2 is unattainable. Document that. Do NOT add launch-arg / env-var route override to the binary (banned per `verification-loop.md §C5 Integrity` and enforced by `figma-to-swiftui-entry-bypass-gate.sh`).

---

## Tier 3 (optional) — per-screen C5.6 visual diff

The full 6-step procedure from `verification-loop.md §C5.6` per screen.

**Artifacts (in addition to Tier 2):**

| Artifact | Path |
|---|---|
| Section inventory | `.figma-cache/<nodeId>/c5-sections.md` |
| Element census | `.figma-cache/<nodeId>/c5-census.md` |
| Per-section crops | `.figma-cache/<nodeId>/c5-crops/` |
| Visual diff | `.figma-cache/<nodeId>/c5-visual-diff.md` |
| Attestation | embedded in `c5-visual-diff.md` |

PASS criteria:
- `c5-coverage-check.sh` produces `GATE: PASS` per screen.
- `c5-weasel-detect.sh` finds no "approximately"/"roughly"/"close enough" in PASS rows.

Tier 3 is the gold standard. Skip ONLY when the user explicitly waives it OR when Tier 2 already revealed a blocker that has to be fixed before per-screen visual diff makes sense.

---

## Decision tree

```
Start C5
  │
  ├── Can run xcodebuild + simctl?
  │     No  → skip C5 entirely, manifest.skipped = "no_project"|"simctl_error"|"ci_environment"
  │           (Tier 1 unreachable — STOP)
  │     Yes → run Tier 1
  │
Tier 1 passed?
  │     No  → fix build/launch first, retry
  │     Yes → proceed
  │
Have a UI driver?
  │     ios-simulator-verify? → Tier 2 attainable
  │     computer-use w/ access? → Tier 2 attainable
  │     XCUITest already in project? → Tier 2 attainable
  │     None of the above? → STOP at Tier 1, document "no UI driver"
  │
Tier 2 passed?
  │     No  → fix walkthrough issues, retry
  │     Yes → proceed
  │
User wants pixel fidelity?
  │     Yes → Tier 3 mandatory (per-screen C5.6)
  │     No  → STOP at Tier 2 with user acceptance noted
```

---

## Manifest contract

Each screen's `.figma-cache/<nodeId>/manifest.json` records the highest tier achieved:

```json
{
  "verification": {
    "c5": {
      "tier": 1 | 2 | 3,
      "gate": "PASS" | "FAIL" | "SKIPPED",
      "skipped": null | "no_project" | "simctl_error" | "ci_environment" | "no_ui_driver" | "user_waived",
      "artifacts": {
        "tier1": { "build": "...", "launch": "...", "firstScreen": "..." },
        "tier2": { "screenshot": "...", "findings": "..." },
        "tier3": { "sections": "...", "census": "...", "diff": "...", "attested": true }
      }
    }
  }
}
```

The flow-level Verification summary aggregates per-screen tier results:

```
C5 verification summary
  Total screens: 47
  Tier 3 PASS: 32
  Tier 2 PASS: 10  (Tier 3 waived by user)
  Tier 1 PASS:  3  (no_ui_driver — UI walkthrough not run)
  SKIPPED:      2  (simctl_error)
```

Compile-pass-only ("xcodebuild succeeded so C5 done") fails this gate — that's at most Tier 0, which doesn't exist.

---

## Banned tier-bypass patterns

Some agents try to inflate Tier by adding fake artifacts. Catch via:

1. **Empty PNG.** `c5-first-screen.png` size < 1 KB or fails PNG signature check → reject. PNG validation is part of `c5-coverage-check.sh`.

2. **Plagiarized C5.6.** Copying `c5-visual-diff.md` from screen A to screen B with `s/A/B/` → catch via `c5-coverage-check.sh` checking that `c5-sections.md` enumerates DIFFERENT elements per screen.

3. **Manifest tier inflation.** Setting `tier: 3` without the Tier 3 artifacts on disk → `c5-coverage-check.sh` verifies file existence per claimed tier.

4. **"Skipped" without reason.** Setting `skipped: null` or `skipped: "other"` instead of the four canonical reasons → reject. The reasons are an enum; non-canonical values fail manifest validation.
