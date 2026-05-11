# C5 Sim Reliability — retry, recovery, clean-state

**Why this exists:** the Bible Widgets session hit simctl errors several times: "The request to open 'com.X' failed", apps stuck in installd transition state, screenshots taken before launch completes, and 30+ minutes of cumulative wall time wasted on shutdown+boot cycles + uninstall+install retries.

## §1. The five failure modes seen in Bible Widgets

1. **Sim Shutdown after long idle** — `simctl install` returns "Unable to lookup in current state: Shutdown" repeatedly. Fix: `simctl boot $SIM`, wait 4-6s for SpringBoard ready.
2. **installd state stuck** — install succeeds but launch fails: `domain=FBSOpenApplicationServiceErrorDomain, code=4`. Logs show installd terminate requests in flight. Fix: shutdown+boot cycle.
3. **Screenshot too early** — launch returns PID, screenshot taken at +3s before SwiftUI hierarchy fully renders. Result: blank/transitional frame captured. Fix: `sleep 6-7` after launch.
4. **Stale binary** — `simctl install <path>` against an already-installed bundle. Sometimes the OLD binary stays running. Fix: `terminate` + `uninstall` BEFORE install.
5. **Bundle prefix collision** — covered separately in `bundle-id-verification.md`.

## §2. The c5-capture.sh sequence (Fix-spec G)

The hardened sequence:

```bash
SIM_ID="<udid>"
BUNDLE_ID=$(cat .figma-cache/_shared/bundle-id.txt)   # Fix-spec A prerequisite
APP_PATH="<built .app>"

# Step 1: ensure sim is booted with retries
for i in 1 2 3; do
  if xcrun simctl bootstatus "$SIM_ID" -b 2>/dev/null | grep -q "Booted"; then break; fi
  xcrun simctl boot "$SIM_ID" 2>/dev/null || true
  sleep $((i*2))    # 2s, 4s, 8s
done

# Step 2: clean state
xcrun simctl terminate "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
xcrun simctl uninstall "$SIM_ID" "$BUNDLE_ID" 2>/dev/null || true
sleep 1

# Step 3: install
xcrun simctl install "$SIM_ID" "$APP_PATH"

# Step 4: launch with retries — handles installd transition state
for i in 1 2 3; do
  out=$(xcrun simctl launch "$SIM_ID" "$BUNDLE_ID" 2>&1)
  if echo "$out" | grep -qE ': [0-9]+$'; then
    break  # got PID
  fi
  if [ $i -eq 3 ]; then
    echo "FAIL: launch failed 3× — recovering with shutdown+boot"
    xcrun simctl shutdown "$SIM_ID"
    sleep 2
    xcrun simctl boot "$SIM_ID"
    sleep 4
    xcrun simctl install "$SIM_ID" "$APP_PATH"
    xcrun simctl launch "$SIM_ID" "$BUNDLE_ID"
    break
  fi
  sleep $((i*2))
done

# Step 5: wait for first render
sleep 7

# Step 6: screenshot
xcrun simctl io "$SIM_ID" screenshot "$OUTPUT"
```

## §3. Status check before each `simctl` call

```bash
# Sim must be Booted for install/launch
state=$(xcrun simctl list devices "$SIM_ID" 2>/dev/null | grep "$SIM_ID" | grep -oE "\((Booted|Shutdown|Booting|Shutting Down)\)" | tr -d '()')
case "$state" in
  Booted) ;;   # OK
  Shutdown) xcrun simctl boot "$SIM_ID"; sleep 4 ;;
  Booting|*) sleep 4 ;;
esac
```

## §4. Detecting "installd terminating bundleID" mid-flight

If `simctl launch` immediately after `install` returns FBSOpenApplicationServiceErrorDomain code=4, check `simctl spawn $SIM log show --predicate 'subsystem == "com.apple.runningboard"' --last 30s`. A line like:

```
runningboard: ... Executing termination request for: <RBSProcessPredicate ... com.X.Y>
```

means installd is still terminating the previous install. Wait 2-3s and retry launch.

## §5. Anti-pattern

```bash
xcrun simctl install $SIM $APP_PATH
xcrun simctl launch $SIM $BUNDLE
xcrun simctl io $SIM screenshot $OUT     # ← too fast; SwiftUI not yet rendered
```

Symptoms: blank/wrong-frame screenshots, false "view doesn't render" diagnoses.

Fix: insert `sleep 6` between launch and screenshot. For complex initial flows (multiple async loads), bump to 8-10s. There is no faster reliable way without view-hierarchy polling, which is overkill for C5.

## §6. Related

- `scripts/c5-capture.sh` — implementation
- `scripts/preflight-bundle-verify.sh` — prerequisite (bundle-id.txt)
- `figma-to-swiftui/references/bundle-id-verification.md`
- `figma-to-swiftui/references/anti-patterns.md` (sim-related entries)
