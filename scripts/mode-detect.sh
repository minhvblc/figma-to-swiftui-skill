#!/usr/bin/env bash
# mode-detect.sh — emit one of greenfield | brownfield-ikame |
# brownfield-vanilla | ambiguous to stdout, given a target folder.
#
# Used by Phase 0 of figma-to-swiftui to decide whether to invoke
# `ikxcodegen` (greenfield Ikame project) or proceed with C1 probe on
# an existing project (brownfield-*). Spec lives in
# `figma-to-swiftui/references/ikxcodegen-bridge.md` §1.
#
# Detection rules:
#   greenfield        — folder does not exist OR exists empty
#                       (also accepts: no .xcodeproj AND no Podfile in folder)
#   brownfield-ikame  — .xcodeproj + Podfile present AND Podfile contains
#                       `pod 'IKCoreApp'`
#   brownfield-vanilla — .xcodeproj + Podfile present, no IKCoreApp
#   ambiguous         — folder has files but neither .xcodeproj nor Podfile,
#                       OR exactly one of (.xcodeproj, Podfile) present
#
# Usage:
#   mode-detect.sh [<target-folder>]
#
# Default target: $PWD.
#
# Exit codes:
#   0 — emitted one of the four mode strings
#  64 — bad usage

set -euo pipefail

TARGET="${1:-$PWD}"

# Non-existing folder = greenfield (caller will create it via ikxcodegen).
# This matches ikxcodegen's "create new folder, refuse existing" semantics —
# the canonical greenfield workflow is `cd <parent> && ikxcodegen <ProjectName>`
# where <parent>/<ProjectName>/ does NOT yet exist.
if [ ! -e "$TARGET" ]; then
  echo "greenfield"
  exit 0
fi

if [ ! -d "$TARGET" ]; then
  echo "FAIL: target exists but is not a directory: $TARGET" >&2
  exit 65
fi

cd "$TARGET"

has_xcodeproj=""
if find . -maxdepth 2 -name '*.xcodeproj' -type d 2>/dev/null | head -1 | grep -q . ; then
  has_xcodeproj="yes"
fi

has_podfile="no"
[ -f "Podfile" ] && has_podfile="yes"

# Anything in folder besides .DS_Store / .git?
has_files="no"
if find . -maxdepth 2 -type f ! -name '.DS_Store' ! -path './.git/*' 2>/dev/null | head -1 | grep -q . ; then
  has_files="yes"
fi

# Decision tree.
if [ -z "$has_xcodeproj" ] && [ "$has_podfile" = "no" ]; then
  if [ "$has_files" = "no" ]; then
    echo "greenfield"
  else
    # Folder has random files (README, docs, asset, ...). Skill must STOP
    # and ask the user — do NOT scaffold over existing content.
    echo "ambiguous"
  fi
  exit 0
fi

if [ -n "$has_xcodeproj" ] && [ "$has_podfile" = "yes" ]; then
  if grep -qE "^\s*pod\s+'IKCoreApp'" Podfile 2>/dev/null; then
    echo "brownfield-ikame"
  else
    echo "brownfield-vanilla"
  fi
  exit 0
fi

# Exactly one of (.xcodeproj, Podfile) — anomalous.
echo "ambiguous"
exit 0
