# swiftui-pro snapshot

**Source:** Paul Hudson `swiftui-pro` skill (MIT, v1.0)
**Snapshot from:** `<project>/.agents/skills/swiftui-pro/references/`
**Snapshot date:** 2026-04-27

This folder is a verbatim copy of swiftui-pro's reference files. They define the team's SwiftUI coding standard. The figma-to-swiftui skill applies them at Phase C2 (write-time) and Phase C3 Pass 4 (review). See `../swiftui-pro-bridge.md` for Figma-specific transforms and the iOS 16 fallback table.

## When to re-sync

If the source skill is updated in any project (vd. `authenv2/.agents/skills/swiftui-pro/`, `authenticator2/.agents/skills/swiftui-pro/`), re-snapshot here:

```bash
SRC=/path/to/project/.agents/skills/swiftui-pro/references
DST=/Users/<you>/Desktop/WORK/figma-to-swiftui-skill/figma-to-swiftui/references/swiftui-pro
diff "$SRC" "$DST"        # review changes first
cp "$SRC"/*.md "$DST"/    # overwrite snapshot
# then bump the snapshot date above
```

## Editing rules

- **Do NOT modify rules in this folder.** This is a snapshot — edits drift from the source of truth.
- If you need Figma-specific guidance for a rule, add it to `../swiftui-pro-bridge.md` instead. That doc is the bridge between Figma input patterns and swiftui-pro output.
- If you need to override or relax a rule because of iOS 16 baseline, document the fallback in `../swiftui-pro-bridge.md` §"iOS 16 fallbacks", not here.

## Files (9)

- `accessibility.md` — Dynamic Type, VoiceOver, Reduce Motion, accessibility traits
- `api.md` — Modern SwiftUI API, deprecated replacements
- `data.md` — `@Observable`, `@State`, bindings, SwiftData
- `design.md` — Design constants, HIG, system styling
- `hygiene.md` — Secrets, tests, Localizable.xcstrings, SwiftLint
- `navigation.md` — `NavigationStack`, sheets, alerts
- `performance.md` — View structure, lazy stacks, `task()`
- `swift.md` — Modern Swift idioms, concurrency
- `views.md` — View extraction, animations, `#Preview`
