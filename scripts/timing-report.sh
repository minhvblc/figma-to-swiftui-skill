#!/usr/bin/env bash
# timing-report.sh — print a wall-time breakdown for one screen-cache.
#
# Reads `.figma-cache/<nodeId>/manifest.json` and prints a fixed-format
# table of phase + gate timings. Used as the baseline measurement tool for
# verifying speed improvements without regressing fidelity gates.
#
# Manifest schema (additive — older manifests without `timing` are still
# valid, the report just shows fewer rows):
#
#   {
#     "timing": {
#       "phaseA":   { "startedAt": "<ISO-8601>", "endedAt": "<ISO-8601>", "ms": <int> },
#       "phaseB":   { ... },
#       "c1":       { ... },
#       "c2":       { ... },
#       "c3Pass2":  { ... },
#       "c3Pass3":  { ... },
#       "c3Pass4":  { ... },
#       "c3Pass5":  { ... },
#       "c5":       { ... },
#       "c5_6":     { ... },
#       "gates": [
#         { "name": "Gate A",       "ms": <int> },
#         { "name": "Gate B",       "ms": <int> },
#         { "name": "Gate C3-Pass2","ms": <int>, "attempt": 1 },
#         { "name": "Gate C5",      "ms": <int> }
#       ]
#     },
#     ...
#   }
#
# Rule of thumb when filling this in:
#   - phaseX.ms is the wall-time from the FIRST tool call of that phase to
#     the LAST artifact write. NOT the sum of individual tool-call latencies.
#   - gates[].ms is wall-time of the bash gate itself.
#   - When a phase is run multiple times (self-fix loop), record the LAST
#     attempt's ms here, and push earlier attempts into `gates[].attempt`.
#
# Usage:
#   timing-report.sh --cache <.figma-cache/nodeId>
#   timing-report.sh --flow  <.figma-cache>            # aggregate all nodeId/ subdirs
#
# Exit codes:
#   0 — report printed (even if some fields missing)
#   64 — bad usage
#   65 — cache dir missing

set -uo pipefail

CACHE=""
FLOW=""

print_usage() {
  cat <<'USAGE' >&2
usage: timing-report.sh --cache <.figma-cache/nodeId>
       timing-report.sh --flow  <.figma-cache>

Reads manifest.json(s) and prints a fixed-format wall-time breakdown.
--cache: single screen.
--flow:  walks every <nodeId>/ subdir of the given cache root and prints
         per-screen + total tables.

Older manifests without `timing` show empty cells (not an error); this
script is the measurement baseline, not an enforcer.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)   CACHE="${2:-}"; shift 2 ;;
    --flow)    FLOW="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || [ -n "$FLOW" ] || { print_usage; exit 64; }
[ -n "$CACHE" ] && [ -n "$FLOW" ] && { echo "FAIL: pass --cache OR --flow, not both" >&2; exit 64; }

if [ -n "$CACHE" ]; then
  [ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 65; }
fi
if [ -n "$FLOW" ]; then
  [ -d "$FLOW" ] || { echo "FAIL: flow dir not found: $FLOW" >&2; exit 65; }
fi

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 65; }

# ──────────────────────────────────────────────────────────────────────────
# Single-cache report.
if [ -n "$CACHE" ]; then
  python3 - "$CACHE" <<'PY'
import json, os, sys

cache = sys.argv[1]
manifest_path = os.path.join(cache, "manifest.json")
if not os.path.isfile(manifest_path):
    print(f"NOTE: {manifest_path} missing — no timing data yet")
    sys.exit(0)

try:
    m = json.load(open(manifest_path))
except Exception as e:
    print(f"FAIL: {manifest_path} not parseable ({e})")
    sys.exit(0)

t = m.get("timing") or {}

PHASE_KEYS = [
    ("phaseA",  "Phase A — Discover & Spec"),
    ("c1",      "  C1 probe + audit"),
    ("phaseB",  "Phase B — Asset Pipeline"),
    ("c2",      "C2 — Implement"),
    ("c3Pass2", "  C3 Pass 2 (offline diff)"),
    ("c3Pass3", "  C3 Pass 3 + 3b (asset/chrome)"),
    ("c3Pass4", "  C3 Pass 4 (swiftui-pro)"),
    ("c3Pass5", "  C3 Pass 5 (c8 conventions)"),
    ("c5",      "C5 — Build + simulator"),
    ("c5_6",    "  C5.6 (6-step compare)"),
]

print()
print(f"Timing report — {cache}")
print(f"Manifest nodeId: {m.get('nodeId', '?')}")
print()
print(f"{'Phase / Step':<40} {'wall (ms)':>12} {'started':<22} {'ended':<22}")
print("─" * 100)

total_ms = 0
for key, label in PHASE_KEYS:
    block = t.get(key) or {}
    ms = block.get("ms")
    started = block.get("startedAt", "")
    ended = block.get("endedAt", "")
    ms_disp = f"{ms:>12,}" if isinstance(ms, int) else f"{'-':>12}"
    print(f"{label:<40} {ms_disp} {started:<22} {ended:<22}")
    if isinstance(ms, int) and not key.startswith(("  ", "c1", "c3", "c5_6")):
        # Only top-level phases sum into total — sub-steps would double-count.
        total_ms += ms

print("─" * 100)
print(f"{'(top-level phases sum)':<40} {total_ms:>12,}")

gates = t.get("gates") or []
if gates:
    print()
    print(f"{'Gate':<35} {'wall (ms)':>12} {'attempt':>8}")
    print("─" * 60)
    for g in gates:
        name = g.get("name", "?")
        ms = g.get("ms")
        att = g.get("attempt", "")
        ms_disp = f"{ms:>12,}" if isinstance(ms, int) else f"{'-':>12}"
        att_disp = f"{att:>8}" if att != "" else f"{'':>8}"
        print(f"{name:<35} {ms_disp} {att_disp}")

print()
PY
  exit 0
fi

# ──────────────────────────────────────────────────────────────────────────
# Flow report — walk subdirectories, aggregate, plus per-screen table.
if [ -n "$FLOW" ]; then
  python3 - "$FLOW" <<'PY'
import json, os, sys

root = sys.argv[1]
rows = []

for entry in sorted(os.listdir(root)):
    sub = os.path.join(root, entry)
    if not os.path.isdir(sub):
        continue
    if entry == "_shared":
        continue
    manifest_path = os.path.join(sub, "manifest.json")
    if not os.path.isfile(manifest_path):
        continue
    try:
        m = json.load(open(manifest_path))
    except Exception:
        continue
    t = m.get("timing") or {}
    rows.append({
        "nodeId": m.get("nodeId", entry),
        "name":   m.get("name") or m.get("screenName") or entry,
        "phaseA": (t.get("phaseA") or {}).get("ms"),
        "phaseB": (t.get("phaseB") or {}).get("ms"),
        "c2":     (t.get("c2") or {}).get("ms"),
        "c5":     (t.get("c5") or {}).get("ms"),
    })

if not rows:
    print(f"NOTE: no per-screen manifests with timing data under {root}")
    sys.exit(0)

print()
print(f"Flow timing report — {root}  ({len(rows)} screen(s))")
print()
print(f"{'Screen':<28} {'nodeId':<18} {'phaseA':>10} {'phaseB':>10} {'C2':>10} {'C5':>10} {'sum':>10}")
print("─" * 100)

totals = {"phaseA": 0, "phaseB": 0, "c2": 0, "c5": 0, "sum": 0}
for r in rows:
    parts = []
    s = 0
    for k in ("phaseA", "phaseB", "c2", "c5"):
        v = r[k]
        if isinstance(v, int):
            parts.append(f"{v:>10,}")
            totals[k] += v
            s += v
        else:
            parts.append(f"{'-':>10}")
    totals["sum"] += s
    sum_disp = f"{s:>10,}" if s else f"{'-':>10}"
    print(f"{r['name'][:28]:<28} {r['nodeId'][:18]:<18} {parts[0]} {parts[1]} {parts[2]} {parts[3]} {sum_disp}")

print("─" * 100)
print(f"{'TOTAL':<28} {'':<18} "
      f"{totals['phaseA']:>10,} {totals['phaseB']:>10,} "
      f"{totals['c2']:>10,} {totals['c5']:>10,} {totals['sum']:>10,}")
print()
PY
  exit 0
fi
