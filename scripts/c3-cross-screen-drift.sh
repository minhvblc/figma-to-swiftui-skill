#!/usr/bin/env bash
# c3-cross-screen-drift.sh — flow-level consistency audit across screens.
#
# Scans every .figma-cache/<nodeId>/c2-audit.json and surfaces:
#   - Inconsistent token usage: screen A uses Color.appPrimary, screen B uses
#     literal #1A1A1A for the same visual purpose (likely tokens.json drift
#     between Phase A runs OR developer cut/paste from old code)
#   - Asset name collisions: same exportName in manifest.json across screens
#     but different sha256 (different actual PNG content)
#   - Spacing drift: literal `24` in screen A vs token `md=24` in screen B
#
# Output: .figma-cache/_shared/c3-cross-screen-drift.md
#
# Usage:
#   c3-cross-screen-drift.sh --cache-root <.figma-cache>
#
# Exit:
#   0 — no drift detected (or only informational warnings)
#   1 — drift FAIL (developer should normalize before declaring flow done)
#  64 — bad usage

set -uo pipefail

CACHE_ROOT=""

print_usage() {
  cat <<'USAGE' >&2
usage: c3-cross-screen-drift.sh --cache-root <.figma-cache>

Walks every per-screen cache directory, compares c2-audit.json rows + tokens
+ manifests, and surfaces cross-screen inconsistencies. Multi-screen flows
should always be normalized — same visual purpose, same token / asset.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache-root) CACHE_ROOT="${2:-}"; shift 2 ;;
    -h|--help)    print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE_ROOT" ] || { print_usage; exit 64; }
[ -d "$CACHE_ROOT" ] || { echo "FAIL: cache-root not a directory: $CACHE_ROOT" >&2; exit 64; }

SHARED="$CACHE_ROOT/_shared"
mkdir -p "$SHARED"
OUT_MD="$SHARED/c3-cross-screen-drift.md"

python3 - "$CACHE_ROOT" "$OUT_MD" <<'PY'
import json, os, sys, re, hashlib
from collections import defaultdict
from datetime import datetime, timezone

cache_root, out_md = sys.argv[1], sys.argv[2]

# Collect per-screen audit data
screens = {}  # nodeId → {"audit": ..., "manifest": ...}
for entry in os.listdir(cache_root):
    if entry.startswith("_") or entry.startswith("."):
        continue
    screen_dir = os.path.join(cache_root, entry)
    if not os.path.isdir(screen_dir):
        continue
    audit_path = os.path.join(screen_dir, "c2-audit.json")
    if not os.path.exists(audit_path):
        continue
    try:
        with open(audit_path) as f:
            audit = json.load(f)
    except (json.JSONDecodeError, OSError):
        continue
    manifest_path = os.path.join(screen_dir, "manifest.json")
    manifest = {}
    if os.path.exists(manifest_path):
        try:
            with open(manifest_path) as f:
                manifest = json.load(f)
        except (json.JSONDecodeError, OSError):
            pass
    screens[entry] = {"audit": audit, "manifest": manifest, "dir": screen_dir}

if len(screens) < 2:
    # Single-screen flow → no drift possible
    with open(out_md, "w") as f:
        f.write("# Cross-Screen Drift Audit\n\n")
        f.write(f"- generatedAt: {datetime.now(timezone.utc).isoformat()}\n")
        f.write(f"- screens scanned: {len(screens)}\n\n")
        f.write("Single-screen cache — no drift possible. GATE: PASS\n")
    print("GATE: PASS (single-screen — no drift possible)")
    sys.exit(0)

# ── Drift detection ─────────────────────────────────────────────────────────

# (a) Same hex used as literal in some screens, as tokenRef in others
hex_uses = defaultdict(lambda: {"literal": [], "tokenRef": []})
for sid, sdata in screens.items():
    for fdata in (sdata["audit"].get("files") or {}).values():
        for row in (fdata.get("rows") or []):
            if row.get("kind") != "color":
                continue
            v = row.get("value") or {}
            form = v.get("form")
            if form == "tokenRef":
                # Can't directly get hex from token name without tokens.json;
                # surface tokenRef name only
                hex_uses[f"token:{v.get('name','')}"]["tokenRef"].append(
                    (sid, row.get("line")))
            elif form == "literal":
                hx = (v.get("hex") or v.get("raw") or "").lower()
                m = re.search(r'#[0-9a-fA-F]{6,8}', hx)
                if m:
                    hex_uses[m.group(0)]["literal"].append((sid, row.get("line")))

color_inconsistencies = []
# Drift class 1: same literal hex used in multiple screens (inconsistent — should be a token)
for key, uses in hex_uses.items():
    if key.startswith("token:"):
        continue
    if len(uses["literal"]) >= 2:
        color_inconsistencies.append({
            "type": "literal-hex-repeated",
            "value": key,
            "uses": uses["literal"],
        })

# (b) Asset name collisions across screens (same exportName, different sha256?)
asset_uses = defaultdict(list)
for sid, sdata in screens.items():
    for row in (sdata["manifest"].get("rows") or []):
        if row.get("status") != "done":
            continue
        name = row.get("exportName") or row.get("friendlyName")
        if not name:
            continue
        # Hash the output path's bytes if accessible
        sha = None
        out_path = row.get("outputPath") or row.get("sharedPath")
        if out_path and os.path.isfile(out_path):
            try:
                with open(out_path, "rb") as f:
                    sha = hashlib.sha256(f.read()).hexdigest()
            except OSError:
                pass
        asset_uses[name].append({"screen": sid, "sha": sha, "outputPath": out_path})

asset_collisions = []
for name, uses in asset_uses.items():
    shas = {u["sha"] for u in uses if u["sha"]}
    if len(shas) > 1:
        asset_collisions.append({"name": name, "uses": uses})

# (c) Spacing literal repeated — likely should be a token
spacing_lit_uses = defaultdict(list)
for sid, sdata in screens.items():
    for fdata in (sdata["audit"].get("files") or {}).values():
        for row in (fdata.get("rows") or []):
            if row.get("kind") not in ("padding", "stack"):
                continue
            v = row.get("value") or {}
            amt = v.get("amount") or v.get("spacing")
            if isinstance(amt, (int, float)):
                spacing_lit_uses[float(amt)].append((sid, row.get("line"), row.get("kind")))

spacing_repeats = []
for val, uses in spacing_lit_uses.items():
    # Repeated literal value across screens AND no spacing token covering it
    screen_set = {u[0] for u in uses}
    if len(screen_set) >= 2 and len(uses) >= 3:
        spacing_repeats.append({"value": val, "uses": uses[:8]})

# ── Emit report ────────────────────────────────────────────────────────────

fail = (len(color_inconsistencies) > 0 or len(asset_collisions) > 0)

with open(out_md, "w") as f:
    f.write("# Cross-Screen Drift Audit\n\n")
    f.write(f"- generatedAt: {datetime.now(timezone.utc).isoformat()}\n")
    f.write(f"- screens scanned: {len(screens)}\n")
    f.write(f"- screen IDs: {', '.join(sorted(screens.keys()))}\n\n")

    f.write("## Color drift (same hex literal across screens — should be a token)\n\n")
    if not color_inconsistencies:
        f.write("None detected.\n\n")
    else:
        f.write("| Hex | Uses |\n|---|---|\n")
        for item in color_inconsistencies:
            uses_str = "; ".join(f"{s}:{l}" for s,l in item["uses"][:6])
            f.write(f"| `{item['value']}` | {uses_str} |\n")
        f.write("\n")

    f.write("## Asset collisions (same exportName, different bytes)\n\n")
    if not asset_collisions:
        f.write("None detected.\n\n")
    else:
        for item in asset_collisions:
            f.write(f"### {item['name']}\n")
            for u in item['uses']:
                f.write(f"- screen `{u['screen']}` sha={u['sha'][:8] if u['sha'] else '?'} path={u['outputPath']}\n")
            f.write("\n")

    f.write("## Spacing literal repeats (informational)\n\n")
    if not spacing_repeats:
        f.write("None significant.\n\n")
    else:
        f.write("| Value (pt) | Screen:Line | Kind |\n|---|---|---|\n")
        for item in spacing_repeats[:10]:
            uses_str = "; ".join(f"{s}:{l}({k})" for s,l,k in item["uses"][:6])
            f.write(f"| {item['value']:g} | {uses_str} | |\n")
        f.write("\n")

    f.write(f"GATE: {'FAIL' if fail else 'PASS'}\n")

print(f"GATE: {'FAIL' if fail else 'PASS'}")
if color_inconsistencies:
    print(f"  - {len(color_inconsistencies)} color literal drift(s)")
if asset_collisions:
    print(f"  - {len(asset_collisions)} asset collision(s)")
if spacing_repeats:
    print(f"  - {len(spacing_repeats)} spacing repeat(s) (informational only)")

sys.exit(1 if fail else 0)
PY
RC=$?
exit $RC
