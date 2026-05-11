# Bundle ID Verification — preflight gate

**Why this exists:** the Bible Widgets session lost ~75 minutes because `simctl launch com.ikame.biblewidgets` (prefix only) succeeded — returning PIDs — but resolved to a **stale older app** with the same prefix. All screenshots showed wrong content, leading to a totally bogus "framework owns intro" diagnosis. The actual bundle ID was `com.ikame.biblewidgets.BibleWidgets`.

## The trap

iOS LaunchServices is permissive: `simctl launch <sim> <bundle>` matches by exact bundle ID. But if you pass a prefix that happens to match an **older installation** still in the sim (from a prior project, a different scaffold attempt, or a renamed bundle), the launch succeeds against that older app silently. There is NO warning.

Symptoms:
- `simctl launch` returns a PID (success-looking)
- Screenshots show UI you don't recognize
- Your code changes don't appear to take effect after rebuild
- Code-changes to strings/colors don't propagate to sim render

These are easy to misdiagnose as: "framework owns this screen", "build cache is stale", "DI registration overridden", etc. None of those are the real cause.

## The fix

Run `scripts/preflight-bundle-verify.sh <project-folder> [--sim <udid>]` BEFORE any `simctl` invocation. It:

1. Reads `CFBundleIdentifier` from the **compiled** Info.plist in DerivedData (truth source after a build), falling back to source Info.plist with `$()` substitution resolution from `project.pbxproj`.
2. Writes the canonical bundle ID to `.figma-cache/_shared/bundle-id.txt`.
3. If `--sim <udid>` is provided, lists all bundles installed in that sim sharing the same prefix and FAILs if more than just our app is present.

```bash
scripts/preflight-bundle-verify.sh /Users/me/MyApp --sim BB494079-E0F2-4FA4-86F0-FA2219BAE5F7
# → Bundle ID: com.foo.MyApp
# → GATE: PASS  (no conflicting prefix bundles in sim)
```

After this, the bundle-id gate hook (`scripts/hooks/figma-to-swiftui-bundle-id-gate.sh`) blocks any `simctl install|launch|uninstall|terminate <bundle>` call where `<bundle>` doesn't match the canonical ID. The block message includes the correct ID, so the agent can self-correct.

## How to find the right bundle ID by hand

```bash
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "*.app" \
  -path "*Debug-iphonesimulator*" -type d 2>/dev/null \
  | xargs ls -dt 2>/dev/null | head -1)
plutil -extract CFBundleIdentifier raw "$APP_PATH/Info.plist"
```

This is what `simctl` actually launches. If your Info.plist source uses `$(PRODUCT_BUNDLE_IDENTIFIER)`, the **compiled** plist after a build has the resolved value — use that.

## Anti-pattern to avoid

```bash
xcrun simctl launch <sim> com.foo                     # ← prefix-only, ambiguous
xcrun simctl launch <sim> $(echo $bundle | head -c X) # ← truncating
```

When you don't know the full bundle ID, **STOP** and run preflight-bundle-verify. Don't guess. The prefix-launch trap is silent and ate ~75 minutes of a real session.

## Related

- `scripts/preflight-bundle-verify.sh` — the script
- `scripts/preflight-smoke-test.sh` — Phase 0 baseline smoke test that depends on this script having run (Fix-spec E)
- `scripts/hooks/figma-to-swiftui-bundle-id-gate.sh` — write-time enforcement
- `c1-conventions.json` — `bundleIdentifier` field (populated by `ikxcodegen-scaffold.sh`)
- `figma-to-swiftui/references/anti-patterns.md` AP-15 — the canonical anti-pattern entry
- `figma-to-swiftui/references/c5-sim-reliability.md` — C5 capture retry strategy that also depends on canonical bundle ID
