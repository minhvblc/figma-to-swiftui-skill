# Font Registration — auto-fetch + UIAppFonts

**Why this exists:** the Bible Widgets session referenced `Font.custom("Inter-Medium", size: 17)` and similar across DesignSystem files, but the Inter + Playfair Display `.otf`/`.ttf` files were not bundled with the app. iOS silently fell back to system fonts. The Figma typography never matched the running sim. We had to manually `curl` 6 font files from GitHub and edit Info.plist by hand.

This is preventable with two scripts:

## §1. The workflow (Phase B0c + B0d, after B0b token codegen)

```
B0a — copy extract (per screen)
B0b — token codegen → tokens.json + Color+Tokens.swift + AppFont.swift
B0c — fonts fetch ← NEW
B0d — Info.plist register ← NEW
… per-screen Phase B then C
```

When `b0b-tokens-codegen.sh` generates `AppFont.swift` with `Font.custom("Inter-Medium", ...)` calls, the matching `.otf` MUST be in `Resources/Fonts/` AND listed in `Info.plist`'s `UIAppFonts` array. Without both, iOS silently falls back.

## §2. b0c-fonts-fetch.sh — auto-download

```bash
scripts/b0c-fonts-fetch.sh \
  --tokens .figma-cache/_shared/tokens.json \
  --output BibleWidgets/Resources/Fonts/
```

Reads `tokens.json` for `fontFamilies` and downloads from a curated mirror table:

| Family | Mirror | Weights fetched by default |
|---|---|---|
| `Inter` | github.com/rsms/inter releases | Regular, Medium, SemiBold, Bold |
| `Playfair Display` | github.com/google/fonts | SemiBold, Bold |

For other families, the script STOPs and asks the user to extend the case statement. **No silent fallback** — if we can't fetch the canonical font, we surface that explicitly. Better than running with system fallback and pretending pixel match is achieved.

## §3. b0d-info-plist-fonts.sh — UIAppFonts register

```bash
scripts/b0d-info-plist-fonts.sh \
  --info BibleWidgets/BibleWidgets/App/Info.plist \
  --fonts BibleWidgets/BibleWidgets/Resources/Fonts/
```

Idempotent merge of every `.otf`/`.ttf` in `Resources/Fonts/` into `UIAppFonts` array. Uses `plistlib` for robust read+write.

## §4. c8-fonts-registered.sh — gate enforcement

After Phase B0c+B0d, the gate verifies:

- Every `Font.custom("X-Y", ...)` in code has matching `X-Y.otf` or `X-Y.ttf` in Resources/Fonts/
- Every such filename is listed in `UIAppFonts` array of Info.plist

Wired into `c8-all.sh`. Failures produce `GATE: FAIL` with the missing font name + which side (UIAppFonts / disk) it's missing from.

## §5. Adding a new font family to the mirror table

`b0c-fonts-fetch.sh` has a `case "$family" in` block. Each entry maps family name → URL pattern + weights to fetch. Extending it:

```bash
# Inside the case statement:
"Roboto Mono")
  for w in Regular Medium Bold; do
    url="https://github.com/google/fonts/raw/main/apache/robotomono/static/RobotoMono-${w}.ttf"
    dest="$OUTPUT/RobotoMono-${w}.ttf"
    curl -sLfo "$dest" "$url"
    # ... size validation, manifest append
  done
  ;;
```

Verify with a real download + size check before committing — Google Fonts mirror moves files occasionally.

## §6. PostScript names vs filenames

Convention used here: filename matches PostScript name. So `Inter-Medium.otf` registers PostScript name `Inter-Medium`, and `Font.custom("Inter-Medium", size: 17)` resolves correctly. Some fonts ship with PostScript names that differ from filenames (e.g. `PlayfairDisplay-SemiBold.ttf` may register as `PlayfairDisplay-SemiBold` AND `Playfair Display SemiBold` — UIKit accepts both). When in doubt, check via:

```swift
print(UIFont.fontNames(forFamilyName: "Inter"))
print(UIFont.fontNames(forFamilyName: "Playfair Display"))
```

## §7. Anti-pattern

```swift
.font(.custom("Inter-Medium", size: 17))   // ← font file not bundled
// Renders system font. Silent. NOT a build error. NOT a runtime crash.
```

Catches: `c8-fonts-registered.sh` (Phase C5/end-of-session) + manual `c8-fonts-registered.sh` between Phase B0d and Phase B implementation.

## §8. Related

- `scripts/b0c-fonts-fetch.sh`
- `scripts/b0d-info-plist-fonts.sh`
- `scripts/c8-fonts-registered.sh`
- `scripts/b0b-tokens-fallback.sh` — older fallback for token codegen when MCPFigma is unavailable; pairs naturally with the font-fetch path here when both extraction sources are degraded
- `figma-to-swiftui/references/fonts-styling-bridge.md` — existing font conventions doc
- `figma-to-swiftui/references/anti-patterns.md` AP-18 — silent-system-fallback anti-pattern
