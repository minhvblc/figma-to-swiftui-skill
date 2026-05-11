#!/usr/bin/env bash
# figma-to-swiftui-ikonboarding-pattern-gate.sh — PostToolUse hook on
# Edit/Write to AppDelegate.swift or *Onboarding*Flow*.swift. Blocks the
# wrong IKOnboardingFlow registration shape that bit Bible Widgets:
#
#   IKDI.onboardingFlow.register(forScreen: .intro) {
#       IKNavigation.makeView(router: X(), root: ...)   ← WRONG
#   }
#
# Correct shape for .intro / .splash / .introIap slots:
#
#   IKDI.onboardingFlow.register(forScreen: .intro) {
#       MyOnboardingFlow()                              ← single root View
#   }
#
# Fix-spec B enforcement.

set -uo pipefail

INPUT=$(cat)

TOOL=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_name',''))" 2>/dev/null)
case "$TOOL" in
  Edit|Write|MultiEdit) ;;
  *) exit 0 ;;
esac

PATH_=$(echo "$INPUT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool_input',{}).get('file_path',''))" 2>/dev/null)

# Only check AppDelegate / Onboarding flow files
case "$PATH_" in
  *AppDelegate.swift|*OnboardingFlow*.swift|*onboarding*flow*.swift) ;;
  *) exit 0 ;;
esac

[ -f "$PATH_" ] || exit 0

# Scan for the wrong pattern
# Match: register(forScreen: .intro|.splash|.introIap) { ... IKNavigation.makeView ... }
# Use multiline grep via python regex
python3 - "$PATH_" <<'PY'
import re
import sys

path = sys.argv[1]
src = open(path).read()

# Match register block for .intro / .splash / .introIap slots with IKNavigation.makeView inside
pattern = re.compile(
    r'register\s*\(\s*forScreen:\s*\.(intro|splash|introIap)\s*\)\s*\{[^}]*?IKNavigation\.makeView',
    re.DOTALL
)

m = pattern.search(src)
if m:
    slot = m.group(1)
    print(f"BLOCKED: ikonboarding-pattern-gate", file=sys.stderr)
    print(f"", file=sys.stderr)
    print(f"File: {path}", file=sys.stderr)
    print(f"Issue: register(forScreen: .{slot}) {{ IKNavigation.makeView(...) }}", file=sys.stderr)
    print(f"", file=sys.stderr)
    print(f"IKOnboardingFlow's .{slot} slot expects a single root View orchestrator,", file=sys.stderr)
    print(f"NOT an IKNavigation wrapper. Wrapping in IKNavigation breaks the framework's", file=sys.stderr)
    print(f"flow handoff (\\.ikOFDismiss env, finishPromise, transition behavior).", file=sys.stderr)
    print(f"", file=sys.stderr)
    print(f"Correct shape:", file=sys.stderr)
    print(f"  IKDI.onboardingFlow.register(forScreen: .{slot}) {{", file=sys.stderr)
    print(f"      MyOnboardingFlow()  // single SwiftUI View, internal state machine", file=sys.stderr)
    print(f"  }}", file=sys.stderr)
    print(f"", file=sys.stderr)
    print(f"See: figma-to-swiftui/references/ikonboardingflow-integration.md §3", file=sys.stderr)
    print(f"Reference impl: authenv2 Authenticator/Screens/Onboarding/OnboardingFlow.swift", file=sys.stderr)
    sys.exit(2)
PY
