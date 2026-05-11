#!/usr/bin/env bash
# ikxcodegen-wrap.sh — wraps `ikxcodegen` to auto-fix the 3 system-level
# friction points discovered during real-run testing (full rationale +
# call-site contract: figma-to-swiftui/references/ikxcodegen-bridge.md §3):
#
#   1. CocoaPods + Ruby 4 unicode bug ("Encoding::CompatibilityError") —
#      `pod install` fails when LANG is not UTF-8. Wrap sets
#      LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 in subshell.
#
#   2. ikxcodegen ships xcconfig files in <Project>/Environments/ but does
#      NOT wire them as the Configuration's "Based on Configuration File"
#      (pbxproj field `baseConfigurationReference`). Result: every xcconfig
#      setting (GOOGLE_SERVICE_INFO_NAME, custom build flags) resolves to
#      empty at build time. Wrap fixes this by editing pbxproj — Debug
#      configuration → firebase-debug.xcconfig; Release → appstore.xcconfig
#      (defaults match the Ikame template; override via flags).
#
#   3. Fallback ONLY when (2) fails (xcconfig file missing from project,
#      pbxproj structure unexpected): patch GOOGLE_SERVICE_INFO_NAME
#      directly into buildSettings so the "Copy InfoPlist" Run Script
#      Phase doesn't fail with an unset variable. This is a symptom-fix
#      for a single setting; (2) is the semantic fix for all xcconfig
#      settings — prefer (2) and use (3) only as fallback.
#
# Usage: drop-in replacement for `ikxcodegen <ProjectName> [...]`.
#   ikxcodegen-wrap.sh <ProjectName> [--bundle-id <id>] [--output <path>]
#                                    [--skip-pods] [--verbose]
#                                    [--debug-xcconfig <name>]
#                                    [--release-xcconfig <name>]
#                                    [--google-plist <name>]
#
# New flags:
#   --debug-xcconfig <filename>
#     xcconfig file to wire as the Debug configuration's source. Default:
#     'firebase-debug.xcconfig'. File MUST exist as a PBXFileReference in
#     the generated pbxproj (ikxcodegen template adds the standard 4 to the
#     Environments/ group; override only for custom templates).
#
#   --release-xcconfig <filename>
#     xcconfig file to wire as the Release configuration's source. Default:
#     'appstore.xcconfig'.
#
#   --google-plist <filename>
#     Fallback only: sets GOOGLE_SERVICE_INFO_NAME directly in buildSettings
#     when xcconfig wiring fails (step 2 above). Default:
#     'GoogleService-Info-Firebase.plist' (the firebase variant — most
#     common for development). Ignored when xcconfig wire succeeds.
#
# Other flags pass through to ikxcodegen verbatim.
#
# Exit codes:
#   0 — scaffold + pod install succeeded; xcconfig wired OR buildSetting
#       fallback applied (use the final summary to see which path)
#   1 — ikxcodegen failed
#   2 — pod install failed even with LANG fix
#   3 — both xcconfig wire AND buildSetting fallback failed (project file
#       format unexpected or template changed)
#  64 — bad usage
#  65 — ikxcodegen not on PATH

set -uo pipefail

# ── Default flag values ──────────────────────────────────────────────────────
GOOGLE_PLIST="GoogleService-Info-Firebase.plist"
DEBUG_XCCONFIG="firebase-debug.xcconfig"
RELEASE_XCCONFIG="appstore.xcconfig"
PROJECT_NAME=""
OUTPUT_DIR=""
PASSTHROUGH_ARGS=()
SKIP_PODS=0
WIRED=0  # set to 1 when step 3a (xcconfig wire) succeeds; gates step 3b fallback

print_usage() {
  sed -n '2,59p' "$0" >&2
}

# ── Parse args (mostly pass-through) ────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --google-plist)
      [ $# -ge 2 ] || { echo "FAIL: --google-plist needs a value" >&2; exit 64; }
      GOOGLE_PLIST="$2"; shift 2 ;;
    --debug-xcconfig)
      [ $# -ge 2 ] || { echo "FAIL: --debug-xcconfig needs a value" >&2; exit 64; }
      DEBUG_XCCONFIG="$2"; shift 2 ;;
    --release-xcconfig)
      [ $# -ge 2 ] || { echo "FAIL: --release-xcconfig needs a value" >&2; exit 64; }
      RELEASE_XCCONFIG="$2"; shift 2 ;;
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

PBXPROJ="$OUTPUT_DIR/$PROJECT_NAME.xcodeproj/project.pbxproj"

# ── 3a. Wire xcconfig files as Configuration's baseConfigurationReference ────
# Semantic fix (option b from the bridge doc): set the app target's Debug and
# Release Configuration "Based on Configuration File" to the xcconfig files
# ikxcodegen already ships in <Project>/Environments/. This matches what a
# developer would do in Xcode: project → target → Info → Configurations →
# pick xcconfig from the dropdown. Once wired, GOOGLE_SERVICE_INFO_NAME and
# every other xcconfig setting propagates correctly; the buildSetting patch
# in §3b becomes unnecessary (and would override xcconfig — banned).
if [ ! -f "$PBXPROJ" ]; then
  echo "WARN: pbxproj not found at $PBXPROJ — skipping xcconfig wire" >&2
else
  echo "▶ Wiring xcconfig: Debug → $DEBUG_XCCONFIG, Release → $RELEASE_XCCONFIG"
  python3 - "$PBXPROJ" "$PROJECT_NAME" "$DEBUG_XCCONFIG" "$RELEASE_XCCONFIG" <<'PY'
import plistlib
import subprocess
import sys
from pathlib import Path

pbxproj_path, project_name, debug_name, release_name = sys.argv[1:5]
pbx_file = Path(pbxproj_path)
backup = pbx_file.read_bytes()  # restore on any failure mid-edit

def restore_and_exit(code, msg):
    pbx_file.write_bytes(backup)
    # Best-effort: re-assert openstep format if plutil left it in xml1.
    subprocess.run(['plutil', '-convert', 'openstep', pbxproj_path],
                   stderr=subprocess.DEVNULL)
    print(msg, file=sys.stderr)
    sys.exit(code)

# Convert openstep → xml1 so plistlib can parse.
r = subprocess.run(['plutil', '-convert', 'xml1', pbxproj_path],
                   stderr=subprocess.PIPE)
if r.returncode != 0:
    restore_and_exit(1, f"FAIL: plutil convert to xml1 failed: {r.stderr.decode()}")

try:
    with open(pbxproj_path, 'rb') as f:
        pbx = plistlib.load(f)
    objects = pbx['objects']

    def find_file_ref(name):
        # Match PBXFileReference whose path is exactly `name` (top-level) or
        # ends with `/name` (nested e.g. Environments/firebase-debug.xcconfig).
        for uuid, obj in objects.items():
            if not isinstance(obj, dict) or obj.get('isa') != 'PBXFileReference':
                continue
            p = obj.get('path', '')
            if p == name or p.endswith('/' + name):
                return uuid
        return None

    debug_uuid = find_file_ref(debug_name)
    release_uuid = find_file_ref(release_name)
    missing = [n for n, u in [(debug_name, debug_uuid),
                              (release_name, release_uuid)] if not u]
    if missing:
        restore_and_exit(2, f"FAIL: PBXFileReference missing for: {', '.join(missing)}")

    # App target = PBXNativeTarget with name == project_name. ikxcodegen names
    # the main app target after the project; tests/UI-tests have suffixes.
    target_uuid = next(
        (uuid for uuid, obj in objects.items()
         if isinstance(obj, dict)
         and obj.get('isa') == 'PBXNativeTarget'
         and obj.get('name') == project_name),
        None,
    )
    if not target_uuid:
        restore_and_exit(3, f"FAIL: no PBXNativeTarget named '{project_name}'")

    cfg_list_uuid = objects[target_uuid].get('buildConfigurationList')
    if not cfg_list_uuid or cfg_list_uuid not in objects:
        restore_and_exit(3, f"FAIL: target '{project_name}' has no buildConfigurationList")

    patched = 0
    for cfg_uuid in objects[cfg_list_uuid].get('buildConfigurations', []):
        cfg = objects.get(cfg_uuid)
        if not isinstance(cfg, dict):
            continue
        name = cfg.get('name')
        if name == 'Debug':
            cfg['baseConfigurationReference'] = debug_uuid
            patched += 1
        elif name == 'Release':
            cfg['baseConfigurationReference'] = release_uuid
            patched += 1
    if patched < 2:
        restore_and_exit(3, f"FAIL: expected Debug+Release configurations, wired only {patched}")

    with open(pbxproj_path, 'wb') as f:
        plistlib.dump(pbx, f)
    r = subprocess.run(['plutil', '-convert', 'openstep', pbxproj_path],
                       stderr=subprocess.PIPE)
    if r.returncode != 0:
        restore_and_exit(4, f"FAIL: plutil convert back to openstep failed: {r.stderr.decode()}")

    print(f"  OK: wired baseConfigurationReference on {patched} configuration(s)")
    sys.exit(0)
except Exception as exc:
    restore_and_exit(99, f"FAIL: {exc}")
PY
  WIRE_RC=$?
  if [ $WIRE_RC -eq 0 ]; then
    WIRED=1
  else
    echo "WARN: xcconfig wire failed (exit $WIRE_RC) — will fall back to GOOGLE_SERVICE_INFO_NAME buildSetting patch in §3b"
  fi
fi

# ── 3b. Fallback: patch GOOGLE_SERVICE_INFO_NAME buildSetting ───────────────
# Run ONLY when §3a (semantic wire) failed. Patching the buildSetting fixes
# the immediate "Copy InfoPlist" failure for a single variable but leaves
# every other xcconfig setting dangling — that's why §3a is preferred.
# If both succeed, buildSettings wins over xcconfig and silently breaks
# future xcconfig edits — exactly the trap we are avoiding.
if [ "$WIRED" = "1" ]; then
  echo "▶ xcconfig wired — skipping §3b GOOGLE_SERVICE_INFO_NAME buildSetting patch (xcconfig provides it)"
elif [ ! -f "$PBXPROJ" ]; then
  echo "WARN: pbxproj not found at $PBXPROJ — skipping §3b too" >&2
elif grep -q "GOOGLE_SERVICE_INFO_NAME =" "$PBXPROJ" 2>/dev/null; then
  echo "▶ GOOGLE_SERVICE_INFO_NAME already set in $PBXPROJ — skip §3b patch"
else
  echo "▶ Patching GOOGLE_SERVICE_INFO_NAME = $GOOGLE_PLIST in $PBXPROJ (§3a fallback)"
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
    echo "FAIL: pbxproj patch failed (exit $PATCH_RC) — both §3a and §3b unsuccessful" >&2
    exit 3
  fi
fi

# ── Done ─────────────────────────────────────────────────────────────────────
echo ""
echo "✅ ikxcodegen-wrap done."
echo "   Project: $OUTPUT_DIR"
if [ "$WIRED" = "1" ]; then
  echo "   xcconfig wire: Debug → $DEBUG_XCCONFIG, Release → $RELEASE_XCCONFIG (semantic fix, preferred)"
else
  echo "   xcconfig wire: FAILED — fell back to GOOGLE_SERVICE_INFO_NAME = $GOOGLE_PLIST in buildSettings"
fi
echo ""
echo "Test build:"
echo "  cd $OUTPUT_DIR"
echo "  xcodebuild -workspace $PROJECT_NAME.xcworkspace -scheme $PROJECT_NAME \\"
echo "    -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \\"
echo "    -configuration Debug build CODE_SIGNING_ALLOWED=NO"
exit 0
