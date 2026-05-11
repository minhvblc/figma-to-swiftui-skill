#!/usr/bin/env bash
# preflight-smoke-test.sh — build + launch unmodified scaffold + screenshot,
# BEFORE any Phase A work. Surfaces SDK-driven / stale-cache rendering
# behavior early so we don't waste hours building native screens that won't
# be reached.
#
# Fix-spec E from SKILL_IMPROVEMENT_PLAN.md. Bible Widgets session: built
# 30 native Intro stub screens before discovering the framework intro was
# rendering different content. Smoke test would have caught it in 60s.
#
# Output: .figma-cache/_shared/smoke-test-baseline.png + smoke-test-result.json
#         with classification: "empty" / "framework-renders" / "stale-cache" /
#         "needs-investigation"
#
# Usage:
#   scripts/preflight-smoke-test.sh <project-folder> [--sim <udid>]
#
# Exit codes:
#   0 — smoke test ran; result classified empty or framework-renders (proceed)
#   1 — stale-cache or needs-investigation (HALT, ask user)
#   2 — build failed or sim error
#  64 — bad usage

set -uo pipefail

PROJECT=""
SIM_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sim) SIM_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,20p' "$0" >&2; exit 0 ;;
    *) PROJECT="$1"; shift ;;
  esac
done

[ -n "$PROJECT" ] || { echo "usage: preflight-smoke-test.sh <project> [--sim <id>]" >&2; exit 64; }
[ -d "$PROJECT" ] || { echo "FAIL: $PROJECT not a directory" >&2; exit 64; }

PROJECT=$(cd "$PROJECT" && pwd)
CACHE="$PROJECT/.figma-cache/_shared"
mkdir -p "$CACHE"

# Auto-pick first booted sim if none specified
if [ -z "$SIM_ID" ]; then
  SIM_ID=$(xcrun simctl list devices booted 2>/dev/null | grep -oE '\([A-F0-9-]{36}\)' | head -1 | tr -d '()')
fi
if [ -z "$SIM_ID" ]; then
  # Boot first available iPhone 15+
  SIM_ID=$(xcrun simctl list devices available 2>/dev/null | grep -m 1 "iPhone 1[56]" | grep -oE '\([A-F0-9-]{36}\)' | tr -d '()')
  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  sleep 4
fi

# Resolve bundle ID — prerequisite per Fix-spec A
if [ ! -f "$CACHE/bundle-id.txt" ]; then
  echo "Running preflight-bundle-verify first..."
  if ! bash "$(dirname "$0")/preflight-bundle-verify.sh" "$PROJECT" --sim "$SIM_ID"; then
    echo "FAIL: bundle-id verification failed; cannot smoke-test"
    exit 2
  fi
fi
BUNDLE_ID=$(cat "$CACHE/bundle-id.txt")

# Detect workspace + scheme
WORKSPACE=$(find "$PROJECT" -maxdepth 2 -name "*.xcworkspace" -not -path "*/Pods/*" | head -1)
PROJ=$(find "$PROJECT" -maxdepth 2 -name "*.xcodeproj" -not -path "*/Pods/*" | head -1)
SCHEME=$(basename "${WORKSPACE:-$PROJ}" | sed -E 's/\.(xcworkspace|xcodeproj)$//')

WS_FLAG=""
if [ -n "$WORKSPACE" ]; then
  WS_FLAG="-workspace $WORKSPACE"
else
  WS_FLAG="-project $PROJ"
fi

echo "Smoke test: $SCHEME → sim $SIM_ID → bundle $BUNDLE_ID"

# Build
cd "$PROJECT" || exit 2
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 xcodebuild $WS_FLAG -scheme "$SCHEME" \
  -sdk iphonesimulator -destination "id=$SIM_ID" -configuration Debug \
  build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -1

# Locate app
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData -name "*.app" \
  -path "*Debug-iphonesimulator*" -type d 2>/dev/null \
  | xargs ls -dt 2>/dev/null | head -1)

if [ ! -d "$APP_PATH" ]; then
  echo "FAIL: build artifact not found"
  exit 2
fi

# Clean install + launch
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
sleep 1
xcrun simctl install "$SIM_ID" "$APP_PATH" 2>&1 | tail -1
xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" 2>&1 | tail -1
sleep 7

# Screenshot
xcrun simctl io "$SIM_ID" screenshot "$CACHE/smoke-test-baseline.png" 2>&1 | tail -1

if [ ! -f "$CACHE/smoke-test-baseline.png" ]; then
  echo "FAIL: screenshot capture failed"
  exit 2
fi

# Classify the baseline.
# Heuristics (simple, no ML):
#   - Image solid color (single dominant color > 90%): "empty"
#   - Has visible UI text but app was unmodified template: "framework-renders" — flag
#   - PID returned but screen on home: "stale-cache" — HALT
# For now we just save + emit a classification JSON for caller to inspect.

# Use sips to extract some pixel stats
SIZE=$(stat -f%z "$CACHE/smoke-test-baseline.png" 2>/dev/null || echo 0)

RESULT="needs-investigation"
HINT=""
if [ "$SIZE" -lt 50000 ]; then
  RESULT="empty"
  HINT="Image small, likely solid color (empty scaffold)"
elif [ "$SIZE" -gt 200000 ]; then
  RESULT="framework-renders"
  HINT="Image complex — visible UI present. Inspect baseline to decide native-impl strategy."
fi

cat > "$CACHE/smoke-test-result.json" <<JSON
{
  "baselinePath": "$CACHE/smoke-test-baseline.png",
  "bundleId": "$BUNDLE_ID",
  "simulator": "$SIM_ID",
  "imageSize": $SIZE,
  "classification": "$RESULT",
  "hint": "$HINT",
  "nextAction": "Inspect $CACHE/smoke-test-baseline.png and update c1-conventions.json smokeTestResult.decision"
}
JSON

echo "Result: $RESULT"
echo "Baseline: $CACHE/smoke-test-baseline.png"
echo "Hint: $HINT"

case "$RESULT" in
  "empty") echo "GATE: PASS"; exit 0 ;;
  "framework-renders") echo "GATE: PASS (with flag — inspect baseline before Phase A)"; exit 0 ;;
  *) echo "GATE: FAIL: classification=$RESULT — HALT and inspect baseline"; exit 1 ;;
esac
