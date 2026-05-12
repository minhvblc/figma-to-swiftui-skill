#!/usr/bin/env bash
# timed-run.sh — wrap a command, record wall-time into manifest.json's timing block.
#
# Drop-in instrumentation: any existing gate or pipeline step can be timed
# without modifying its source. Records the wall-time from invocation to
# completion (NOT the sum of nested call latencies).
#
# Usage:
#   timed-run.sh --phase <key> --manifest <path/to/manifest.json> -- <command...>
#
# Manifest update (idempotent overwrite of last attempt):
#   manifest.timing.<key> = {
#     "startedAt": "<ISO-8601 UTC>",
#     "endedAt":   "<ISO-8601 UTC>",
#     "ms":        <int>
#   }
#
# When `<key>` already exists, the previous entry is preserved under
# `manifest.timing._history[<key>]` (capped at 5 entries) so a self-fix
# loop's later attempts don't lose earlier timings.
#
# Examples:
#   scripts/timed-run.sh --phase phaseA --manifest .figma-cache/3166_70147/manifest.json \
#     -- mcp_get_design_context fileKey=... nodeId=...
#
#   scripts/timed-run.sh --phase c5 --manifest .figma-cache/3166_70147/manifest.json \
#     -- scripts/c5-capture.sh --cache .figma-cache/3166_70147 --udid <udid>
#
#   scripts/timed-run.sh --phase c3Pass3 --manifest .figma-cache/3166_70147/manifest.json \
#     -- scripts/c3-static-checks.sh --files Sources/IntroScreen.swift
#
# Exit code: pass-through from the wrapped command.
#   64 — bad usage (missing --phase / --manifest / command)

set -uo pipefail

PHASE=""
MANIFEST=""

print_usage() {
  cat <<'USAGE' >&2
usage: timed-run.sh --phase <key> --manifest <path/to/manifest.json> -- <command...>

Wraps a command and writes its wall-time into manifest.timing.<key>.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --phase)    PHASE="${2:-}"; shift 2 ;;
    --manifest) MANIFEST="${2:-}"; shift 2 ;;
    --)         shift; break ;;
    -h|--help)  print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$PHASE" ]    || { echo "FAIL: --phase required"    >&2; exit 64; }
[ -n "$MANIFEST" ] || { echo "FAIL: --manifest required" >&2; exit 64; }
[ "$#" -ge 1 ]     || { echo "FAIL: command missing after --" >&2; exit 64; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 65; }

now_ms() {
  # Portable millisecond epoch — BSD date doesn't support %3N.
  python3 -c 'import time; print(int(time.time()*1000))'
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

START_MS=$(now_ms)
START_ISO=$(now_iso)

# Run the command, preserving its exit code.
"$@"
RC=$?

END_MS=$(now_ms)
END_ISO=$(now_iso)
MS=$((END_MS - START_MS))

# Atomically update manifest.timing.<key>; preserve prior attempts under _history.
python3 - "$MANIFEST" "$PHASE" "$START_ISO" "$END_ISO" "$MS" <<'PY' 2>/dev/null || true
import json, os, sys
path, phase, started, ended, ms = sys.argv[1:6]
data = {}
if os.path.isfile(path):
    try:
        data = json.load(open(path))
    except Exception:
        data = {}
if not isinstance(data, dict):
    data = {}
t = data.setdefault("timing", {})
if not isinstance(t, dict):
    t = {}
    data["timing"] = t
prior = t.get(phase)
if isinstance(prior, dict):
    history = t.setdefault("_history", {})
    if not isinstance(history, dict):
        history = {}
        t["_history"] = history
    bucket = history.setdefault(phase, [])
    if not isinstance(bucket, list):
        bucket = []
        history[phase] = bucket
    bucket.append(prior)
    # Keep last 5 entries to bound manifest growth.
    if len(bucket) > 5:
        del bucket[:-5]
t[phase] = {"startedAt": started, "endedAt": ended, "ms": int(ms)}
os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PY

exit $RC
