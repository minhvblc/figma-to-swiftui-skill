#!/usr/bin/env bash
# ikxcodegen-wrap.sh — wraps `ikxcodegen` to auto-fix the 2 system-level
# friction points discovered during real-run testing (full rationale +
# call-site contract: figma-to-swiftui/references/ikxcodegen-bridge.md §3):
#
#   1. CocoaPods + Ruby 4 unicode bug ("Encoding::CompatibilityError") —
#      `pod install` fails when LANG is not UTF-8. Wrap sets
#      LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 in subshell.
#
#   2. ikxcodegen template's "Copy InfoPlist" Run Script Phase fails when
#      GOOGLE_SERVICE_INFO_NAME is unset. The xcconfig files in
#      <Project>/<Target>/Environments/ should set this variable but
#      ikxcodegen template doesn't auto-set them as the Configuration's
#      .xcconfig source. Wrap patches the build settings so the script
#      references the correct GoogleService-Info-Firebase.plist.
#
# Usage: drop-in replacement for `ikxcodegen <ProjectName> [...]`.
#   ikxcodegen-wrap.sh <ProjectName> [--bundle-id <id>] [--output <path>]
#                                    [--skip-pods] [--verbose]
#                                    [--google-plist <name>]
#
# New flag:
#   --google-plist <filename>
#     Sets GOOGLE_SERVICE_INFO_NAME in build settings. Default:
#     'GoogleService-Info-Firebase.plist' (the firebase variant — most
#     common for development). Pass 'GoogleService-Info-Appstore.plist'
#     for production-config builds.
#
# Other flags pass through to ikxcodegen verbatim.
#
# Exit codes:
#   0 — scaffold + pod install succeeded; build settings patched
#   1 — ikxcodegen failed
#   2 — pod install failed even with LANG fix
#   3 — build settings patch failed (project file format unexpected)
#  64 — bad usage
#  65 — ikxcodegen not on PATH

set -uo pipefail

# ── Default flag values ──────────────────────────────────────────────────────
GOOGLE_PLIST="GoogleService-Info-Firebase.plist"
PROJECT_NAME=""
OUTPUT_DIR=""
PASSTHROUGH_ARGS=()
SKIP_PODS=0

print_usage() {
  sed -n '2,30p' "$0" >&2
}

# ── Parse args (mostly pass-through) ────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --google-plist)
      [ $# -ge 2 ] || { echo "FAIL: --google-plist needs a value" >&2; exit 64; }
      GOOGLE_PLIST="$2"; shift 2 ;;
    --output|-o)
      [ $# -ge 2 ] || { echo "FAIL: --output needs a value" >&2; exit 64; }
      OUTPUT_DIR="$2"
      PASSTHROUGH_ARGS+=("$1" "$2"); shift 2 ;;
    --skip-pods)
      SKIP_PODS=1
      PASSTHROUGH_ARGS+=("$1"); shift ;;
    -h|--help)
      print_usage; exit 0 ;;
    -*)
      # Other flag with value
      if [ $# -ge 2 ] && [[ "$2" != -* ]]; then
        PASSTHROUGH_ARGS+=("$1" "$2"); shift 2
      else
        PASSTHROUGH_ARGS+=("$1"); shift
      fi ;;
    *)
      if [ -z "$PROJECT_NAME" ]; then
        PROJECT_NAME="$1"
        PASSTHROUGH_ARGS+=("$1")
      else
        PASSTHROUGH_ARGS+=("$1")
      fi
      shift ;;
  esac
done

[ -n "$PROJECT_NAME" ] || { echo "FAIL: <ProjectName> required" >&2; print_usage; exit 64; }
command -v ikxcodegen >/dev/null 2>&1 || {
  echo "FAIL: ikxcodegen not found on PATH. Install:" >&2
  echo "  brew install mint" >&2
  echo "  mint install git@gitlab.ikameglobal.com:begamob/ios/shared/cli-macos/ikxcodegen.git" >&2
  exit 65
}

# Default output directory matches ikxcodegen's default behavior.
[ -z "$OUTPUT_DIR" ] && OUTPUT_DIR="./$PROJECT_NAME"

# ── 1. Run ikxcodegen with LANG=UTF-8 to avoid pod install unicode bug ──────
echo "▶ ikxcodegen $PROJECT_NAME (LANG=en_US.UTF-8 to avoid Ruby 4 unicode bug)"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 ikxcodegen "${PASSTHROUGH_ARGS[@]}"
RC=$?
if [ $RC -ne 0 ]; then
  echo "FAIL: ikxcodegen exited $RC" >&2
  exit 1
fi

# Resolve OUTPUT_DIR to absolute path (it may have been relative).
if [ -d "$OUTPUT_DIR" ]; then
  OUTPUT_DIR=$(cd "$OUTPUT_DIR" && pwd)
else
  echo "FAIL: ikxcodegen completed but output directory not found: $OUTPUT_DIR" >&2
  exit 1
fi

# ── 2. Pod install retry with LANG fix (ikxcodegen's auto-pod-install fails) ─
if [ "$SKIP_PODS" = "0" ]; then
  if [ ! -d "$OUTPUT_DIR/Pods" ] || [ -z "$(ls -A "$OUTPUT_DIR/Pods" 2>/dev/null)" ]; then
    echo "▶ pod install failed during ikxcodegen — retrying with LANG=en_US.UTF-8"
    if ! (cd "$OUTPUT_DIR" && LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 pod install); then
      echo "FAIL: pod install retry failed. Run manually:" >&2
      echo "  cd $OUTPUT_DIR && LANG=en_US.UTF-8 pod install" >&2
      exit 2
    fi
  fi
fi

# ── 3. Patch build settings to set GOOGLE_SERVICE_INFO_NAME ─────────────────
# The "Copy InfoPlist" Run Script Phase references ${GOOGLE_SERVICE_INFO_NAME}
# but ikxcodegen template doesn't wire xcconfig as the source for build
# configurations. Three ways to fix:
#   (a) set GOOGLE_SERVICE_INFO_NAME directly in pbxproj's buildSettings
#   (b) wire the xcconfig file as Configuration's baseConfigurationReference
#   (c) require user to pass GOOGLE_SERVICE_INFO_NAME via xcodebuild flag
#
# We do (a) — direct buildSettings edit. Idempotent: skipped if already set.
PBXPROJ="$OUTPUT_DIR/$PROJECT_NAME.xcodeproj/project.pbxproj"
if [ ! -f "$PBXPROJ" ]; then
  echo "WARN: pbxproj not found at $PBXPROJ — skipping GOOGLE_SERVICE_INFO_NAME patch" >&2
elif grep -q "GOOGLE_SERVICE_INFO_NAME =" "$PBXPROJ" 2>/dev/null; then
  echo "▶ GOOGLE_SERVICE_INFO_NAME already set in $PBXPROJ — skip patch"
else
  echo "▶ Patching GOOGLE_SERVICE_INFO_NAME = $GOOGLE_PLIST in $PBXPROJ"
  python3 - "$PBXPROJ" "$PROJECT_NAME" "$GOOGLE_PLIST" <<'PY'
import re, sys
path, project_name, plist = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r") as f:
    src = f.read()

# Find every XCBuildConfiguration buildSettings block that contains
# PRODUCT_BUNDLE_IDENTIFIER (the main target's configurations). Inject
# GOOGLE_SERVICE_INFO_NAME before the closing `};` of buildSettings.
pattern = re.compile(
    r"(buildSettings\s*=\s*\{[^}]*?PRODUCT_BUNDLE_IDENTIFIER[^}]*?)(\n\s*\};)",
    re.DOTALL,
)

def patch(m):
    body, close = m.group(1), m.group(2)
    if "GOOGLE_SERVICE_INFO_NAME" in body:
        return m.group(0)
    return body + f'\n\t\t\t\tGOOGLE_SERVICE_INFO_NAME = "{plist}";' + close

new = pattern.sub(patch, src)
if new == src:
    print("WARN: no PRODUCT_BUNDLE_IDENTIFIER block found to patch", file=sys.stderr)
    sys.exit(0)

with open(path, "w") as f:
    f.write(new)
print(f"  patched {new.count('GOOGLE_SERVICE_INFO_NAME')} buildSettings block(s)")
PY
  PATCH_RC=$?
  if [ $PATCH_RC -ne 0 ]; then
    echo "FAIL: pbxproj patch failed (exit $PATCH_RC)" >&2
    exit 3
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "✅ ikxcodegen-wrap done."
echo "   Project: $OUTPUT_DIR"
echo "   GOOGLE_SERVICE_INFO_NAME = $GOOGLE_PLIST"
echo ""
echo "Test build:"
echo "  cd $OUTPUT_DIR"
echo "  xcodebuild -workspace $PROJECT_NAME.xcworkspace -scheme $PROJECT_NAME \\"
echo "    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \\"
echo "    -configuration Debug build CODE_SIGNING_ALLOWED=NO"
exit 0
