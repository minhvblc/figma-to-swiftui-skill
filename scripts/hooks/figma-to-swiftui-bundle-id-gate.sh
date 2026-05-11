#!/usr/bin/env bash
# figma-to-swiftui-bundle-id-gate.sh — PreToolUse hook for Bash. Blocks
# `xcrun simctl install|launch|uninstall|terminate <BUNDLE>` calls when
# <BUNDLE> doesn't match the canonical bundle ID recorded by
# preflight-bundle-verify.sh.
#
# Prevents the Bible Widgets session's "launch by prefix → resolves to
# stale older app" trap.
#
# Fix-spec A enforcement.

set -uo pipefail

# Hook input on stdin = JSON of the tool call
INPUT=$(cat)

# Only act on Bash tool calls
TOOL=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
[ "$TOOL" = "Bash" ] || exit 0

CMD=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)

# Match simctl install/launch/uninstall/terminate followed by a bundle ID
if ! echo "$CMD" | grep -qE 'xcrun\s+simctl\s+(install|launch|uninstall|terminate)\s+[A-F0-9-]{20,}\s+[a-zA-Z0-9.]+'; then
  exit 0
fi

# Extract the bundle ID argument (4th positional after `simctl install ID`)
BUNDLE_ARG=$(echo "$CMD" | grep -oE 'xcrun\s+simctl\s+(install|launch|uninstall|terminate)\s+[A-F0-9-]{20,}\s+[a-zA-Z0-9.]+' \
  | awk '{print $NF}')

# `install` takes a path, not bundle ID — skip
ACTION=$(echo "$CMD" | grep -oE 'simctl\s+(install|launch|uninstall|terminate)' | awk '{print $2}')
[ "$ACTION" = "install" ] && exit 0

# Look up canonical bundle ID
# Search up from cwd for .figma-cache/_shared/bundle-id.txt
DIR="$PWD"
CANONICAL=""
while [ "$DIR" != "/" ]; do
  if [ -f "$DIR/.figma-cache/_shared/bundle-id.txt" ]; then
    CANONICAL=$(cat "$DIR/.figma-cache/_shared/bundle-id.txt")
    break
  fi
  DIR=$(dirname "$DIR")
done

# No canonical recorded — skip (preflight not yet run)
[ -z "$CANONICAL" ] && exit 0

# Compare
if [ "$BUNDLE_ARG" = "$CANONICAL" ]; then
  exit 0
fi

# Mismatch — block and suggest
cat >&2 <<EOF
BLOCKED: bundle-id-gate

Command tries to '$ACTION' bundle: $BUNDLE_ARG
Canonical bundle (from .figma-cache/_shared/bundle-id.txt): $CANONICAL

A prefix-only or wrong bundle ID will resolve to a stale older app in the
simulator. This is the root cause of the Bible Widgets session's 75-min
"framework owns intro" misdiagnosis.

Fix: replace $BUNDLE_ARG with $CANONICAL in the command.

To regenerate the canonical ID: scripts/preflight-bundle-verify.sh <project>
See: figma-to-swiftui/references/bundle-id-verification.md
EOF
exit 2
