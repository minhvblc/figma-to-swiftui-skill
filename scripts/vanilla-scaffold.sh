#!/usr/bin/env bash
# vanilla-scaffold.sh — Scaffolds a greenfield SwiftUI iOS project for
# figma-to-swiftui work when ikxcodegen is unavailable OR user opts out.
#
# Produces:
#   <project>/project.yml                    xcodegen config
#   <project>/<ProjectName>/<ProjectName>.swift     App entry
#   <project>/<ProjectName>/DesignSystem/          AppColor, AppFont, Spacing, Strings
#   <project>/<ProjectName>/Navigation/            AppState, RootView
#   <project>/<ProjectName>/Screens/               (empty, populated per-feature)
#   <project>/<ProjectName>/Resources/Assets.xcassets   AppIcon, AccentColor, AppBackground
#   <project>/.figma-cache/_shared/c1-conventions.json  initial conventions doc
#
# Then runs `xcodegen generate` to materialize <ProjectName>.xcodeproj.
#
# Usage:
#   scripts/vanilla-scaffold.sh <project-folder> [--name <ProjectName>]
#                               [--bundle-id <id>] [--ios-min <17.0>]
#                               [--mode scaffold|production]
#
# Exit codes:
#   0 — success
#  64 — bad usage
#  65 — xcodegen missing

set -uo pipefail

PROJECT_FOLDER=""
PROJECT_NAME=""
BUNDLE_ID=""
IOS_MIN="17.0"
MODE="scaffold"

while [ $# -gt 0 ]; do
  case "$1" in
    --name) PROJECT_NAME="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --ios-min) IOS_MIN="$2"; shift 2 ;;
    --mode) MODE="$2"; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" >&2; exit 0 ;;
    *) [ -z "$PROJECT_FOLDER" ] && PROJECT_FOLDER="$1" && shift || shift ;;
  esac
done

[ -n "$PROJECT_FOLDER" ] || { echo "usage: vanilla-scaffold.sh <project-folder>" >&2; exit 64; }
command -v xcodegen >/dev/null 2>&1 || {
  echo "FAIL: xcodegen not on PATH. Install: brew install xcodegen" >&2
  exit 65
}

if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME="$(basename "$PROJECT_FOLDER")"
  # Normalize: capitalize, strip non-alphanumeric.
  PROJECT_NAME="$(echo "$PROJECT_NAME" | sed 's/[^a-zA-Z0-9]//g')"
  PROJECT_NAME="$(echo "${PROJECT_NAME:0:1}" | tr '[:lower:]' '[:upper:]')${PROJECT_NAME:1}"
fi
[ -z "$BUNDLE_ID" ] && BUNDLE_ID="app.example.$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]')"

mkdir -p "$PROJECT_FOLDER"
cd "$PROJECT_FOLDER" || exit 1

# Don't overwrite an existing project.
if [ -f "project.yml" ] || [ -d "$PROJECT_NAME.xcodeproj" ]; then
  echo "FAIL: '$PROJECT_FOLDER' already has project.yml or .xcodeproj — refusing to overwrite" >&2
  exit 64
fi

# ── project.yml ──────────────────────────────────────────────────────────────
cat > project.yml <<EOF
name: $PROJECT_NAME
options:
  bundleIdPrefix: $(echo "$BUNDLE_ID" | rev | cut -d. -f2- | rev)
  deploymentTarget:
    iOS: "$IOS_MIN"
  developmentLanguage: en
  createIntermediateGroups: true

settings:
  base:
    SWIFT_VERSION: "5.10"
    IPHONEOS_DEPLOYMENT_TARGET: "$IOS_MIN"
    ENABLE_USER_SCRIPT_SANDBOXING: "NO"
    GENERATE_INFOPLIST_FILE: "YES"
    INFOPLIST_KEY_UILaunchScreen_Generation: "YES"
    INFOPLIST_KEY_UIApplicationSceneManifest_Generation: "YES"
    INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone: UIInterfaceOrientationPortrait
    INFOPLIST_KEY_UIStatusBarStyle: UIStatusBarStyleLightContent

targets:
  $PROJECT_NAME:
    type: application
    platform: iOS
    sources:
      - path: $PROJECT_NAME
        excludes:
          - "**/.DS_Store"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: $BUNDLE_ID
        TARGETED_DEVICE_FAMILY: "1"
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        SWIFT_EMIT_LOC_STRINGS: "YES"
EOF

# ── Directory skeleton ───────────────────────────────────────────────────────
mkdir -p \
  "$PROJECT_NAME/DesignSystem" \
  "$PROJECT_NAME/Navigation" \
  "$PROJECT_NAME/Screens" \
  "$PROJECT_NAME/Resources/Assets.xcassets/AppIcon.appiconset" \
  "$PROJECT_NAME/Resources/Assets.xcassets/AccentColor.colorset" \
  "$PROJECT_NAME/Resources/Assets.xcassets/AppBackground.colorset" \
  "$PROJECT_NAME/Resources/Assets.xcassets/Colors" \
  ".figma-cache/_shared"

# Asset catalog metadata.
cat > "$PROJECT_NAME/Resources/Assets.xcassets/Contents.json" <<'JSON'
{ "info": { "author": "xcode", "version": 1 } }
JSON
cat > "$PROJECT_NAME/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json" <<'JSON'
{
  "images": [{ "idiom": "universal", "platform": "ios", "size": "1024x1024" }],
  "info": { "author": "xcode", "version": 1 }
}
JSON
cat > "$PROJECT_NAME/Resources/Assets.xcassets/AccentColor.colorset/Contents.json" <<'JSON'
{
  "colors": [{ "idiom": "universal", "color": { "color-space": "srgb",
    "components": { "alpha": "1.000", "red": "0xB8", "green": "0x9B", "blue": "0x5E" } } }],
  "info": { "author": "xcode", "version": 1 }
}
JSON
cat > "$PROJECT_NAME/Resources/Assets.xcassets/AppBackground.colorset/Contents.json" <<'JSON'
{
  "colors": [{ "idiom": "universal", "color": { "color-space": "srgb",
    "components": { "alpha": "1.000", "red": "0x10", "green": "0x10", "blue": "0x10" } } }],
  "info": { "author": "xcode", "version": 1 }
}
JSON
# Colors/ group with provides-namespace=false so colorset-codegen.sh emits flat
# Color(.appPrimary) symbols rather than nested Color(.Colors.appPrimary).
# Matches references/colorset-codegen.md.
cat > "$PROJECT_NAME/Resources/Assets.xcassets/Colors/Contents.json" <<'JSON'
{
  "info": { "author": "xcode", "version": 1 },
  "properties": { "provides-namespace": false }
}
JSON

# ── App entry ───────────────────────────────────────────────────────────────
cat > "$PROJECT_NAME/$PROJECT_NAME.swift" <<EOF
import SwiftUI

@main
struct ${PROJECT_NAME}App: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
        }
    }
}
EOF

# ── DesignSystem stubs ──────────────────────────────────────────────────────
cat > "$PROJECT_NAME/DesignSystem/AppColor.swift" <<'EOF'
import SwiftUI

enum AppColor {
    static let background = Color("AppBackground")
    static let accent = Color("AccentColor")
    // Token codegen (figma-to-swiftui Step B0b) will append color tokens here.
}
EOF

cat > "$PROJECT_NAME/DesignSystem/AppFont.swift" <<'EOF'
import SwiftUI

enum AppFont {
    static func serif(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .serif)
    }
    static func sans(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        Font.system(size: size, weight: weight, design: .default)
    }
    // Token codegen (figma-to-swiftui Step B0b) will append text-style tokens here.
}
EOF

cat > "$PROJECT_NAME/DesignSystem/Spacing.swift" <<'EOF'
import Foundation

enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
}
EOF

cat > "$PROJECT_NAME/DesignSystem/Strings.swift" <<'EOF'
import Foundation

// String constants. figma-to-swiftui Step B0a appends per-screen enums here.
enum Strings {
    enum Common {
        static let continueCTA = "Continue"
        static let cancel = "Cancel"
    }
}
EOF

# ── Navigation stubs ────────────────────────────────────────────────────────
cat > "$PROJECT_NAME/Navigation/AppState.swift" <<'EOF'
import Foundation

final class AppState: ObservableObject {
    @Published var hasCompletedOnboarding: Bool = false
}
EOF

cat > "$PROJECT_NAME/Navigation/RootView.swift" <<'EOF'
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        ZStack {
            AppColor.background.ignoresSafeArea()
            // figma-to-swiftui Step 4 populates this root with the entry screen.
            Text("Bootstrap — replace with onboarding entry")
                .foregroundStyle(.white)
        }
    }
}
EOF

# ── Initial conventions doc ─────────────────────────────────────────────────
# Resolve absolute path to assetCatalogPath so MCPFigma's
# figma_export_assets_unified can consume it directly without re-deriving.
PROJECT_FOLDER_ABS=$(cd "$PROJECT_FOLDER" && pwd)
ASSET_CATALOG_PATH="$PROJECT_FOLDER_ABS/$PROJECT_NAME/Resources/Assets.xcassets"
cat > .figma-cache/_shared/c1-conventions.json <<EOF
{
  "screenFolderConvention": "ikame-feature-flat",
  "viewModelPattern": "state-action-reducer",
  "usesIKNavigation": false,
  "usesIKMacros": false,
  "usesIKCoreApp": false,
  "usesIKPopup": false,
  "usesIKFeedback": false,
  "usesIKTracking": false,
  "usesIKLocalized": false,
  "usesIKAssetSymbol": true,
  "ikFontEnum": "AppFont",
  "spacingEnum": "Spacing",
  "colorEnum": "AppColor",
  "featureRoot": "$PROJECT_NAME/Screens",
  "navigationStyle": "vanilla-navigationstack",
  "swiftMinTarget": "$IOS_MIN",
  "mode": "$MODE",
  "scaffoldVariant": "vanilla",
  "assetCatalogPath": "$ASSET_CATALOG_PATH",
  "notes": "Greenfield-vanilla scaffold from vanilla-scaffold.sh. Switch mode to 'production' once assets exported and screens implemented per Figma."
}
EOF

# ── Generate Xcode project ──────────────────────────────────────────────────
xcodegen generate

echo ""
echo "✅ vanilla-scaffold done."
echo "   Project: $PROJECT_FOLDER/$PROJECT_NAME.xcodeproj"
echo "   Mode: $MODE (in .figma-cache/_shared/c1-conventions.json)"
echo ""
echo "Next:"
echo "  1. Pin Figma file → run figma_build_registry on the flow root."
echo "  2. Per screen: figma_export_assets_unified(autoDiscover: true, "
echo "     assetCatalogPath: '$PROJECT_FOLDER/$PROJECT_NAME/Resources/Assets.xcassets')"
echo "  3. Implement screens under $PROJECT_NAME/Screens/<Feature>/<Name>Screen.swift"
echo "  4. Switch mode → production in c1-conventions.json before final review."
echo ""
echo "Test build:"
echo "  cd $PROJECT_FOLDER && xcodebuild -project $PROJECT_NAME.xcodeproj -scheme $PROJECT_NAME -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' build"
exit 0
