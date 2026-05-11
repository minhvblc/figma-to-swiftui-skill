#!/usr/bin/env bash
# ikxcodegen-scaffold.sh — Thin wrapper around ~/.claude/scripts/ikxcodegen-wrap.sh
# that also writes c1-conventions.json with Ikame-default fields so the
# figma-to-swiftui hooks/skills know to apply Ikame conventions immediately.
#
# Use this for greenfield-ikame mode. For brownfield-ikame projects, do NOT
# scaffold (project already exists) — just run the convention probe and let
# c8-gate.sh detect Ikame from the Podfile.
#
# Usage:
#   scripts/ikxcodegen-scaffold.sh <ProjectName> [--output <path>]
#                                  [--bundle-id <id>] [--mode scaffold|production]
#                                  [<passthrough flags to ikxcodegen-wrap.sh>]
#
# Exit codes:
#   0 — success
#  64 — bad usage
#  65 — ikxcodegen / wrap script missing
#  other — propagated from ikxcodegen-wrap.sh

set -uo pipefail

WRAP_SCRIPT="$HOME/.claude/scripts/ikxcodegen-wrap.sh"
if [ ! -x "$WRAP_SCRIPT" ]; then
  echo "FAIL: $WRAP_SCRIPT not found or not executable" >&2
  echo "      Install ikxcodegen and ensure ~/.claude/scripts/ikxcodegen-wrap.sh exists." >&2
  exit 65
fi

PROJECT_NAME=""
OUTPUT_DIR=""
MODE="scaffold"
PASSTHROUGH=()

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --output|-o) OUTPUT_DIR="$2"; PASSTHROUGH+=("--output" "$2"); shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0" >&2
      exit 0
      ;;
    -*)
      if [ $# -ge 2 ] && [[ "$2" != -* ]]; then
        PASSTHROUGH+=("$1" "$2"); shift 2
      else
        PASSTHROUGH+=("$1"); shift
      fi
      ;;
    *)
      if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME="$1"
        PASSTHROUGH+=("$1")
      else
        PASSTHROUGH+=("$1")
      fi
      shift
      ;;
  esac
done

[ -n "$PROJECT_NAME" ] || { echo "usage: ikxcodegen-scaffold.sh <ProjectName>" >&2; exit 64; }
[ -z "$OUTPUT_DIR" ] && OUTPUT_DIR="./$PROJECT_NAME"

# Delegate the heavy lifting (scaffold + pod install + xcconfig wire) to the
# proven wrapper.
"$WRAP_SCRIPT" "${PASSTHROUGH[@]}"
RC=$?
if [ $RC -ne 0 ]; then
  echo "FAIL: ikxcodegen-wrap.sh exited $RC — see its output for details" >&2
  exit "$RC"
fi

# Resolve to absolute path.
if [ -d "$OUTPUT_DIR" ]; then
  OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
fi

# Detect runtime facts the c1-conventions.json should record so downstream
# scripts (preflight-bundle-verify, ikonboarding-pattern-gate, etc.) have
# something to compare against — see SKILL_IMPROVEMENT_PLAN Fix-spec A + B.
PODFILE="$OUTPUT_DIR/Podfile"
USES_IKONBOARDING="false"
if [ -f "$PODFILE" ] && grep -qE "^[[:space:]]*pod[[:space:]]+['\"]IKOnboardingFlow['\"]" "$PODFILE"; then
  USES_IKONBOARDING="true"
fi

# Extract bundleIdentifier from project.pbxproj if available — preflight
# verify can populate it post-build, but recording the source pbxproj value
# at scaffold time gives a starting reference.
PBXPROJ="$OUTPUT_DIR/$PROJECT_NAME.xcodeproj/project.pbxproj"
BUNDLE_ID=""
if [ -f "$PBXPROJ" ]; then
  BUNDLE_ID=$(grep -m 1 "PRODUCT_BUNDLE_IDENTIFIER = " "$PBXPROJ" 2>/dev/null \
    | sed -E 's/.*= ([^;]+);.*/\1/' | tr -d ' "')
fi

# Write c1-conventions.json. ikxcodegen template uses fixed paths/names so we
# can hard-wire most fields. featureRoot is <ProjectName>/Screens; navigationItem
# enum is MainRoute at Core/Router/Main/MainRoute.swift; tracking enum and toast
# enum names are the Ikame standards (TrackingScreen / AppToastType) — adjust
# per project if your variant differs.
mkdir -p "$OUTPUT_DIR/.figma-cache/_shared"
cat > "$OUTPUT_DIR/.figma-cache/_shared/c1-conventions.json" <<EOF
{
  "screenFolderConvention": "ikame-feature-flat",
  "viewModelPattern": "state-action-route-publisher",
  "usesIKNavigation": true,
  "usesIKMacros": true,
  "usesIKCoreApp": true,
  "usesIKPopup": true,
  "usesIKFeedback": true,
  "usesIKTracking": true,
  "usesIKLocalized": true,
  "usesIKAssetSymbol": true,
  "ikFontEnum": "IKFont",
  "spacingEnum": "Spacing",
  "colorEnum": "AppColor",
  "featureRoot": "$PROJECT_NAME/Screens",
  "routerName": "MainRouter",
  "navigationItemEnumName": "MainRoute",
  "navigationItemPath": "$PROJECT_NAME/Core/Router/Main/MainRoute.swift",
  "trackingEnumName": "TrackingScreen",
  "trackingEnumPath": "$PROJECT_NAME/Core/Tracking/TrackingScreen.swift",
  "toastTypeEnumName": "AppToastType",
  "entitiesPath": "$PROJECT_NAME/Entities",
  "entitiesPrefix": "",
  "apiRepoTypeName": "APIRepo",
  "swiftMinTarget": "17.0",
  "usesIKOnboardingFlow": $USES_IKONBOARDING,
  "bundleIdentifier": "$BUNDLE_ID",
  "smokeTestResult": null,
  "customFonts": [],
  "mode": "$MODE",
  "scaffoldVariant": "ikame",
  "notes": "Ikame scaffold from ikxcodegen. All Ikame umbrella conventions active. Switch mode to 'production' before final review. Run scripts/preflight-bundle-verify.sh post-build to confirm bundleIdentifier matches Info.plist (it may differ from pbxproj when build settings interpolate)."
}
EOF

# After scaffold, emit pointer hints for the new preflight gates.
if [ "$USES_IKONBOARDING" = "true" ]; then
  echo ""
  echo "⚠️  IKOnboardingFlow pod detected in Podfile."
  echo "   Phase 0 smoke-test is MANDATORY before Phase A:"
  echo "     scripts/preflight-smoke-test.sh $OUTPUT_DIR"
  echo "   Onboarding registration uses single-View orchestrator (NOT IKNavigation.makeView):"
  echo "     see ~/.claude/skills/figma-to-swiftui/references/ikonboardingflow-integration.md"
fi

echo ""
echo "✅ ikxcodegen-scaffold done."
echo "   Project: $OUTPUT_DIR"
echo "   Conventions: $OUTPUT_DIR/.figma-cache/_shared/c1-conventions.json"
echo "   Mode: $MODE"
echo ""
echo "Next:"
echo "  1. Pin Figma file → run figma_build_registry on the flow root."
echo "  2. Per screen: figma_export_assets_unified(autoDiscover: true,"
echo "     assetCatalogPath: '$OUTPUT_DIR/$PROJECT_NAME/Resources/Assets.xcassets')"
echo "  3. Implement screens under $PROJECT_NAME/Screens/<Feature>/<Name>Screen.swift"
echo "  4. New MainRoute cases → emit delta-request, do NOT mutate MainRoute.swift directly."
echo "  5. New TrackingScreen cases → emit delta-request, same rule."
echo "  6. Switch mode → production before final review."
exit 0
