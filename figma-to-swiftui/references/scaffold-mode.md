# Scaffold mode — opt-in relaxed enforcement (P1-8)

Scaffold mode is an explicit project-level flag that softens hook enforcement during the **structural** phase of a greenfield build, then strengthens it again before production. It exists because the strict-all-the-time enforcement of the figma-to-swiftui hooks works well for brownfield + production runs but produces a frustrating bypass loop on a 47-screen greenfield start.

This document covers: when to use scaffold mode, what changes, how to switch back, and what is NOT relaxed.

---

## When to use

✅ **Use scaffold mode when:**
- Starting a greenfield project from zero (no existing `.xcodeproj`).
- The feature has ≥10 screens AND you haven't completed Phase A for any of them yet.
- You're wiring shared scaffolding (App.swift, RootView, AppState, DesignSystem stubs) that won't pass the strict gates yet because the per-screen Figma artifacts don't exist.
- The user explicitly says "rough first pass" / "scaffold" / "structural" / "we'll polish later".

❌ **Do NOT use scaffold mode when:**
- Working in a brownfield project (existing `.xcodeproj` with shipped features). The strict gates exist to keep the codebase consistent.
- Implementing a specific screen (one screen at a time → strict mode protects you from icon shortcuts).
- The user asked for a polished deliverable.
- Phase A is complete (all per-screen cache directories populated) — at that point you have no excuse to skip the icon/visual checks.

---

## How to opt in

Edit `.figma-cache/_shared/c1-conventions.json`:

```json
{
  "screenFolderConvention": "ikame-feature-flat",
  "mode": "scaffold",
  "featureRoot": "BibleApp/Screens",
  ...
}
```

All hooks that respect the mode field (P1-3 implementation) downgrade their behavior:
- `figma-to-swiftui-banned-pattern-gate.sh` — still hard-blocks (icons need real assets even during scaffold).
- `figma-to-swiftui-c8-gate.sh` — WARN instead of BLOCK on path/naming/ViewModel-pattern violations. Stderr message has `WARN [figma-c8, scaffold mode]:` prefix.
- `figma-to-swiftui-entry-bypass-gate.sh` — WARN instead of BLOCK on entry-path edits.
- `figma-to-swiftui-pass2-gate.sh` — WARN instead of BLOCK on Pass 2 content checks.

The Write/Edit operations complete (exit 0) but the WARN messages stay visible to the agent so it knows what will need fixing later.

---

## What is NOT relaxed (even in scaffold mode)

These hooks ignore the mode field and always BLOCK:

1. **`banned-pattern-gate.sh` Check 1 (SF Symbols outside allow-list)** — using `Image(systemName:)` without `// allow-systemName:` is always wrong. There is no scaffold-phase use case for this — even prototype views should reference real Figma assets so the asset export pipeline pulls them.

2. **`banned-pattern-gate.sh` Check 2 (iOS system chrome redraws)** — drawing the status bar / Dynamic Island / home indicator is always a bug. Scaffold mode does not legitimize this.

3. **`banned-pattern-gate.sh` Check 7 (cornerRadius ≥ 30 at screen root)** — bezel mistake. Always wrong.

The reasoning: icon shortcuts and chrome redraws are NEVER acceptable. Path/naming/ViewModel-pattern violations are recoverable refactors once scaffolding is done.

---

## How to switch back to production

Before final review / merge:

1. Set `mode: "production"` in `c1-conventions.json`.

2. Run the full session-end sweep:
   ```bash
   SWIFT_SRC="<project root>"
   CONV=".figma-cache/_shared/c1-conventions.json"
   scripts/c8-all.sh --src "$SWIFT_SRC" --conventions "$CONV"
   ```
   This re-runs every c8-* sub-gate against every Swift file in scope. Any WARN that became silent in scaffold mode now BLOCKs.

3. Fix every blocker. The terse output makes the queue manageable.

4. Re-run the C5 verification gate per screen (`c5-coverage-check.sh`).

5. Re-run `xcodebuild build` + simulator install + visual diff.

If any of these fail and you can't fix in one session, **revert mode to scaffold** for the next session — don't ship a half-converted project. The mode field is your audit trail.

---

## Audit trail expectation

Every scaffold-mode run MUST end with a Verification summary that includes the line:

```
Mode: scaffold (NOT production). Outstanding WARNs to convert before merge: <count>
  WARN summary path: .figma-cache/_shared/scaffold-warnings.log
```

This makes scaffold-mode runs impossible to silently ship as "done". Reviewers see the mode in the summary and check the WARN log before approving.

Skipping this line is itself a banned shortcut (anti-patterns.md §5: "Disclosing the bypass in the final summary is enough" — this is the inverse: NOT disclosing the mode in the summary is a violation).

---

## Anti-patterns the scaffold mode does NOT excuse

Scaffold mode is NOT permission to:
- Skip Phase A per screen (anti-patterns.md §13 still applies — fetch design-context per screen).
- Use SF Symbols as permanent icon implementations (banned-pattern gate still hard-blocks; the WARN downgrade is path/naming only).
- Add debug routes to bypass C5 (entry-bypass gate downgrades to WARN but the WARN should be acted on).
- Ship without C5 verification (C5 is still mandatory at production-switch time).

The goal of scaffold mode: let the agent **land the structural skeleton without 6 hours of hook ping-pong**, while keeping the icon/chrome rules strict and ensuring the WARN backlog gets resolved before production.
