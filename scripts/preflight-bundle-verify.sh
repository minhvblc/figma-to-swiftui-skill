#!/usr/bin/env bash
# preflight-bundle-verify.sh — extract + verify the bundle ID before any
# simctl install/launch. Root cause of Bible Widgets session's biggest time
# loss: launched with `com.ikame.biblewidgets` prefix → simctl resolved to a
# stale older app → screenshots showed wrong content → 75 min wasted on a
# bogus "framework owns intro" diagnosis.
#
# What this fixes (Fix-spec A, SKILL_IMPROVEMENT_PLAN.md):
#   - Reads CFBundleIdentifier from compiled Info.plist (truth source)
#   - Writes to .figma-cache/_shared/bundle-id.txt for downstream scripts
#   - Detects sim-installed-bundle conflicts at the same prefix
#   - Emits GATE: FAIL with specific suffix recommendation if ambiguous
#
# Usage:
#   scripts/preflight-bundle-verify.sh <project-folder> [--sim <udid>]
#   scripts/preflight-bundle-verify.sh /Users/me/BibleWidgets
#
# Exit codes:
#   0 — bundle ID extracted + no conflicts; bundle-id.txt written
#   1 — bundle conflict at same prefix in target sim (prefix-launch ambiguous)
#   2 — Info.plist not found or unreadable
#  64 — bad usage

set -uo pipefail

PROJECT=""
SIM_ID=""

while [ $# -gt 0 ]; do
  case "$1" in
    --sim) SIM_ID="$2"; shift 2 ;;
    -h|--help) sed -n '2,25p' "$0" >&2; exit 0 ;;
    -*) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
    *)
      if [ -z "$PROJECT" ]; then PROJECT="$1"; fi
      shift
      ;;
  esac
done

[ -n "$PROJECT" ] || { echo "usage: preflight-bundle-verify.sh <project-folder>" >&2; exit 64; }
[ -d "$PROJECT" ] || { echo "FAIL: $PROJECT not a directory" >&2; exit 64; }

PROJECT=$(cd "$PROJECT" && pwd)

# Find compiled Info.plist in DerivedData — that's the truth source after
# build. Fall back to source Info.plist if no build yet.
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData \
  -name "*.app" -path "*Debug-iphonesimulator*" -type d 2>/dev/null \
  | xargs ls -dt 2>/dev/null | head -1)

INFO_PLIST=""
if [ -n "$APP_PATH" ] && [ -f "$APP_PATH/Info.plist" ]; then
  INFO_PLIST="$APP_PATH/Info.plist"
  SOURCE="compiled DerivedData ($(basename "$APP_PATH"))"
else
  # Source Info.plist as fallback
  candidate=$(find "$PROJECT" -maxdepth 3 -name "Info.plist" -not -path "*/Pods/*" -not -path "*/build/*" 2>/dev/null | head -1)
  if [ -n "$candidate" ] && [ -f "$candidate" ]; then
    INFO_PLIST="$candidate"
    SOURCE="source $candidate"
  fi
fi

if [ -z "$INFO_PLIST" ]; then
  echo "FAIL: no Info.plist found in $PROJECT or DerivedData" >&2
  exit 2
fi

# Extract bundle ID. If source plist has $(PRODUCT_BUNDLE_IDENTIFIER)
# placeholder, fall back to looking in .xcodeproj.
BUNDLE_ID=$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST" 2>/dev/null || true)

if [ -z "$BUNDLE_ID" ] || [[ "$BUNDLE_ID" == *'$('* ]]; then
  # Try project.pbxproj
  PBXPROJ=$(find "$PROJECT" -maxdepth 2 -name "project.pbxproj" -not -path "*/Pods/*" 2>/dev/null | head -1)
  if [ -n "$PBXPROJ" ]; then
    BUNDLE_ID=$(grep -m 1 "PRODUCT_BUNDLE_IDENTIFIER = " "$PBXPROJ" 2>/dev/null \
      | sed -E 's/.*= ([^;]+);.*/\1/' | tr -d ' "')
  fi
fi

if [ -z "$BUNDLE_ID" ]; then
  echo "FAIL: could not extract CFBundleIdentifier from $INFO_PLIST" >&2
  exit 2
fi

# Write cache
CACHE_DIR="$PROJECT/.figma-cache/_shared"
mkdir -p "$CACHE_DIR"
echo "$BUNDLE_ID" > "$CACHE_DIR/bundle-id.txt"

echo "Bundle ID: $BUNDLE_ID"
echo "Source: $SOURCE"
echo "Written: $CACHE_DIR/bundle-id.txt"

# If a sim is specified, check for installed bundles at same prefix
if [ -n "$SIM_ID" ]; then
  # Strip last segment to get prefix
  PREFIX="${BUNDLE_ID%.*}"
  if [ "$PREFIX" = "$BUNDLE_ID" ]; then
    PREFIX="" # no dot — nothing to conflict with
  fi

  if [ -n "$PREFIX" ]; then
    INSTALLED=$(xcrun simctl listapps "$SIM_ID" 2>/dev/null | grep -oE "$PREFIX[^\"\\}]*" | sort -u)
    CONFLICT_COUNT=$(echo "$INSTALLED" | grep -v "^$BUNDLE_ID\$" | grep -c . || true)
    if [ "$CONFLICT_COUNT" -gt 0 ]; then
      echo "GATE: FAIL: prefix collision detected" >&2
      echo "Other installed bundles sharing prefix '$PREFIX':" >&2
      echo "$INSTALLED" | grep -v "^$BUNDLE_ID\$" | sed 's/^/  - /' >&2
      echo "  Recommendation: uninstall the conflicting bundle(s):" >&2
      echo "$INSTALLED" | grep -v "^$BUNDLE_ID\$" | sed "s|^|    xcrun simctl uninstall $SIM_ID |" >&2
      exit 1
    fi
  fi
fi

echo "GATE: PASS"
exit 0
