#!/usr/bin/env bash
# c2-cache-validate.sh — schema + integrity gate for .figma-cache/<nodeId>/.
#
# Runs BEFORE c3-token-trace.sh (L2). Verifies each cached artifact is:
#   - Present + parseable
#   - Schema-conformant (no empty arrays without explanation)
#   - Non-stale (cache age within threshold)
#   - Not silently degraded (manifest status, tokens form, fills imageUrl)
#
# Emits:
#   .figma-cache/<nodeId>/c3-validate.json — machine-readable report
#   .figma-cache/<nodeId>/_status.json     — updated artifact tracker
#
# Exit codes:
#   0 — GATE: PASS
#   1 — GATE: FAIL (artifact corrupt / missing / silently degraded)
#   2 — GATE: PARTIAL (cache acceptable but has explained gaps;
#                       caller can override with --accept-partial)
#  64 — bad usage
#
# Usage:
#   c2-cache-validate.sh --cache <.figma-cache/nodeId>
#                        [--max-age-days <N>]      # default 7
#                        [--accept-partial]        # treat PARTIAL as success
#                        [--strict]                # PARTIAL → FAIL

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source cache-io helpers (search repo first, then installed location)
if [ -f "$SCRIPT_DIR/_lib/cache-io.sh" ]; then
  source "$SCRIPT_DIR/_lib/cache-io.sh"
elif [ -f "$HOME/.claude/scripts/_lib/cache-io.sh" ]; then
  source "$HOME/.claude/scripts/_lib/cache-io.sh"
fi

CACHE=""
MAX_AGE_DAYS="7"
ACCEPT_PARTIAL=0
STRICT=0

print_usage() {
  cat <<'USAGE' >&2
usage: c2-cache-validate.sh --cache <.figma-cache/nodeId>
                            [--max-age-days <N>]   default 7
                            [--accept-partial]     treat PARTIAL as success
                            [--strict]             PARTIAL → FAIL

Verifies every artifact in the cache (tokens, design-context, metadata,
manifest, fills, registry) is present, parseable, and schema-conformant.
Updates _status.json with current artifact state. Emits c3-validate.json
with structured per-artifact verdict.

Exit:
  0  GATE: PASS
  1  GATE: FAIL  (corruption, missing required artifact, silent degradation)
  2  GATE: PARTIAL (acceptable gaps — empty tokens with _note, etc.)
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)           CACHE="${2:-}"; shift 2 ;;
    --max-age-days)    MAX_AGE_DAYS="${2:-7}"; shift 2 ;;
    --accept-partial)  ACCEPT_PARTIAL=1; shift ;;
    --strict)          STRICT=1; shift ;;
    -h|--help)         print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 64; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 64; }

NODE_ID="$(basename "$CACHE")"

python3 - "$CACHE" "$NODE_ID" "$MAX_AGE_DAYS" "$ACCEPT_PARTIAL" "$STRICT" <<'PY'
import json, os, re, sys, hashlib, time
from datetime import datetime, timezone

cache, node_id, max_age_days_str, accept_partial, strict = sys.argv[1:6]
max_age_days = float(max_age_days_str)
accept_partial = (accept_partial == "1")
strict = (strict == "1")

now = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

# Load existing _status.json so we don't clobber prior runs
status_path = os.path.join(cache, "_status.json")
try:
    with open(status_path) as f:
        status = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    status = {"schemaVersion": 1, "phaseA": {}, "phaseB": {}}
status.setdefault("phaseA", {})
status.setdefault("phaseB", {})

# Cache age (days since oldest mtime of any artifact file)
def cache_age_days(d):
    oldest = None
    for name in os.listdir(d):
        p = os.path.join(d, name)
        if os.path.isfile(p) and not name.startswith("."):
            m = os.path.getmtime(p)
            if oldest is None or m < oldest:
                oldest = m
    if oldest is None:
        return 0.0
    return (time.time() - oldest) / 86400

age = cache_age_days(cache)
freshness_alert = age > max_age_days
status["cache_age_days"] = round(age, 2)
status["freshness_alert"] = freshness_alert

def load_json(name):
    p = os.path.join(cache, name)
    try:
        with open(p) as f:
            return json.load(f), None
    except FileNotFoundError:
        return None, "missing"
    except json.JSONDecodeError as e:
        return None, f"json_decode_error: {e}"

def load_text(name):
    p = os.path.join(cache, name)
    try:
        with open(p) as f:
            return f.read(), None
    except FileNotFoundError:
        return None, "missing"

def sha256_of(name):
    p = os.path.join(cache, name)
    if not os.path.isfile(p):
        return None
    try:
        with open(p, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()
    except Exception:
        return None

def size_of(name):
    p = os.path.join(cache, name)
    return os.path.getsize(p) if os.path.isfile(p) else 0

# Track per-artifact verdicts
artifacts = {}

def record(phase, name, verdict, **fields):
    """verdict: present|missing|invalid|degraded|partial"""
    entry = status[phase].get(name, {}) or {}
    # Map verdict → status enum
    status_enum = {
        "present":  "done",
        "missing":  "missing",
        "invalid":  "failed",
        "degraded": "partial",
        "partial":  "partial",
    }.get(verdict, "unknown")
    entry["status"] = status_enum
    entry["writtenAt"] = now
    sh = sha256_of(name)
    if sh: entry["sha256"] = sh
    sz = size_of(name)
    if sz: entry["size"] = sz
    for k, v in fields.items():
        entry[k] = v
    status[phase][name] = entry
    artifacts[name] = {
        "verdict": verdict,
        "schemaOK": verdict in ("present", "partial"),
        **fields,
    }

# ── tokens.json ──────────────────────────────────────────────────────────────
tokens, err = load_json("tokens.json")
if err:
    record("phaseA", "tokens.json", "missing" if err == "missing" else "invalid",
           reason=err)
else:
    colors_n   = len(tokens.get("colors") or [])
    typo_n     = len(tokens.get("typography") or [])
    spacing_n  = len(tokens.get("spacing") or [])
    radius_n   = len(tokens.get("radius") or [])
    note       = tokens.get("_note") or tokens.get("note")
    synth      = bool(tokens.get("_schemaForm") in ("synthesized", "inline-fallback")
                      or tokens.get("_synthesized"))
    has_any    = (colors_n + typo_n + spacing_n + radius_n) > 0

    # Determine schemaForm
    if synth and has_any:
        form = "synthesized"
        record("phaseA", "tokens.json", "partial",
               schemaForm=form, colorCount=colors_n, typographyCount=typo_n,
               spacingCount=spacing_n, hasNote=bool(note))
    elif has_any:
        form = "full"
        record("phaseA", "tokens.json", "present",
               schemaForm=form, colorCount=colors_n, typographyCount=typo_n,
               spacingCount=spacing_n)
    elif note:
        # Empty but explained — acceptable degraded
        form = "empty-explained"
        record("phaseA", "tokens.json", "partial",
               schemaForm=form, reason=note)
    else:
        # Empty without explanation — bug
        form = "empty-unexplained"
        record("phaseA", "tokens.json", "degraded",
               schemaForm=form,
               reason="tokens.json has no entries AND no _note field — Variables API likely failed silently")

# ── design-context.md ────────────────────────────────────────────────────────
text, err = load_text("design-context.md")
if err:
    record("phaseA", "design-context.md", "missing" if err == "missing" else "invalid",
           reason=err)
elif len(text) < 100:
    record("phaseA", "design-context.md", "invalid",
           reason=f"file too small ({len(text)} bytes — likely truncated)")
elif "## Design context for" not in text and "Design context for" not in text:
    record("phaseA", "design-context.md", "degraded",
           reason="missing '## Design context for \"<node>\"' heading — wrong source or partial fetch")
else:
    truncated = text.rstrip().endswith("...truncated") or text.rstrip().endswith("…")
    record("phaseA", "design-context.md", "partial" if truncated else "present",
           bytes=len(text), truncationSuspect=truncated)

# ── metadata.json ────────────────────────────────────────────────────────────
metadata, err = load_json("metadata.json")
if err:
    record("phaseA", "metadata.json", "missing" if err == "missing" else "invalid",
           reason=err)
else:
    # Walk for bbox coverage
    nodes_with_bbox = 0
    nodes_total = 0
    missing_bbox_ids = []
    def walk(n):
        global nodes_with_bbox, nodes_total
        if not isinstance(n, dict):
            return
        nodes_total += 1
        bbox = n.get("absoluteBoundingBox") or n.get("bbox")
        node_type = n.get("type", "")
        if isinstance(bbox, dict):
            nodes_with_bbox += 1
        elif node_type not in {"DOCUMENT", "CANVAS"}:
            nid = n.get("id")
            if nid: missing_bbox_ids.append(f"{nid} ({node_type})")
        for ch in (n.get("children") or []):
            walk(ch)
    root = metadata.get("rootNode") or metadata.get("document") or metadata
    walk(root)
    coverage = (nodes_with_bbox / max(nodes_total, 1))
    if nodes_total == 0:
        record("phaseA", "metadata.json", "invalid",
               reason="no nodes found in tree")
    elif coverage < 0.5:
        record("phaseA", "metadata.json", "degraded",
               reason=f"only {coverage*100:.0f}% nodes have absoluteBoundingBox",
               nodesTotal=nodes_total, nodesWithBbox=nodes_with_bbox,
               missingBboxNodes=missing_bbox_ids[:10])
    else:
        record("phaseA", "metadata.json", "present",
               nodesTotal=nodes_total, nodesWithBbox=nodes_with_bbox)

# ── fills.json (optional — absent OK) ────────────────────────────────────────
fills, err = load_json("fills.json")
if err == "missing":
    record("phaseA", "fills.json", "missing", optional=True)
elif err:
    record("phaseA", "fills.json", "invalid", reason=err)
else:
    image_url_nulls = 0
    image_fills = 0
    for n in fills.get("nodes") or []:
        for f_ in (n.get("fills") or []):
            if (f_.get("type") or "").upper() == "IMAGE" or f_.get("kind") == "IMAGE":
                image_fills += 1
                if not f_.get("imageUrl"):
                    image_url_nulls += 1
    record("phaseA", "fills.json", "partial" if image_url_nulls > 0 else "present",
           imageFills=image_fills, imageUrlNulls=image_url_nulls)

# ── manifest.json (phase B) ──────────────────────────────────────────────────
manifest, err = load_json("manifest.json")
if err == "missing":
    record("phaseB", "manifest.json", "missing")
elif err:
    record("phaseB", "manifest.json", "invalid", reason=err)
else:
    rows = manifest.get("rows") or []
    done = sum(1 for r in rows if r.get("status") == "done")
    failed = [r.get("exportName") or r.get("nodeId") or "?"
              for r in rows if r.get("status") == "failed"]
    other = sum(1 for r in rows if r.get("status") not in ("done", "failed"))
    if len(rows) == 0:
        record("phaseB", "manifest.json", "degraded",
               reason="rows[] empty — no assets exported",
               doneRows=0, failedRows=0)
    elif failed:
        record("phaseB", "manifest.json", "degraded",
               reason=f"{len(failed)} row(s) failed: {','.join(failed[:5])}",
               doneRows=done, failedRows=len(failed), failedNames=failed[:10])
    else:
        record("phaseB", "manifest.json", "present" if other == 0 else "partial",
               doneRows=done, failedRows=0)

# ── c2-typography-perline.json (Plan §1.3 — optional but required when
#    design-context has text segments). Bridges textHint on font sub-axis
#    rows so L2 can PASS/FAIL instead of N/A.
typo_perline, err = load_json("c2-typography-perline.json")
if err == "missing":
    # Only required when design-context.md has text segments
    extracted, _ = load_json("c2-extracted.json")
    has_text = bool(extracted and (extracted.get("textSegmentsNormalized") or extracted.get("textSegments")))
    if has_text:
        record("phaseA", "c2-typography-perline.json", "degraded",
               reason="design-context has text segments but c2-typography-perline.json missing — "
                      "run scripts/c2-typography-extract.sh")
    else:
        record("phaseA", "c2-typography-perline.json", "missing", optional=True,
               reason="no text segments to extract")
elif err:
    record("phaseA", "c2-typography-perline.json", "invalid", reason=err)
else:
    perline = (typo_perline.get("byTextNormalized") or {})
    if not perline:
        record("phaseA", "c2-typography-perline.json", "partial",
               segmentCount=0, reason="no typography classes resolved (design-context may use raw CSS or be sparse)")
    else:
        record("phaseA", "c2-typography-perline.json", "present", segmentCount=len(perline))

# ── c2-fills-stops.json (Plan §1.3 — optional, required when fills.json
#    has ≥1 GRADIENT node). Lets L2 do per-stop comparison via nodeIdHint.
fills_stops, err = load_json("c2-fills-stops.json")
if err == "missing":
    # Only required when fills.json has gradient nodes
    fills_for_check, _ = load_json("fills.json")
    has_gradient = False
    if fills_for_check:
        for n in (fills_for_check.get("nodes") or []):
            for f_ in (n.get("fills") or []):
                ft = (f_.get("type") or f_.get("kind") or "").upper()
                if ft.startswith("GRADIENT") or "GRADIENT" in ft:
                    has_gradient = True
                    break
            if has_gradient:
                break
    if has_gradient:
        record("phaseA", "c2-fills-stops.json", "degraded",
               reason="fills.json has GRADIENT node(s) but c2-fills-stops.json missing — "
                      "run scripts/c2-fills-stops-index.sh")
    else:
        record("phaseA", "c2-fills-stops.json", "missing", optional=True,
               reason="no gradient fills to index")
elif err:
    record("phaseA", "c2-fills-stops.json", "invalid", reason=err)
else:
    by_node = (fills_stops.get("byNodeId") or {})
    record("phaseA", "c2-fills-stops.json", "present", indexedNodes=len(by_node))

# ── registry.json (optional shared) ──────────────────────────────────────────
registry, err = load_json("registry.json")
if err == "missing":
    # Look in _shared
    shared_path = os.path.join(cache, "..", "_shared", "registry.json")
    if os.path.isfile(shared_path):
        with open(shared_path) as f:
            try:
                registry = json.load(f)
                err = None
            except json.JSONDecodeError:
                registry = None
if registry is not None:
    warnings_n = len(registry.get("warnings") or [])
    if warnings_n > 0:
        record("phaseA", "registry.json", "partial",
               warningsCount=warnings_n,
               warnings=[(w.get("figmaName") or "?") + ": " + (w.get("reason") or "")
                         for w in (registry.get("warnings") or [])[:5]])
    else:
        record("phaseA", "registry.json", "present")

# ── Aggregate verdict ────────────────────────────────────────────────────────
# Optional artifacts (fills.json, registry.json) missing alone is NOT a FAIL.
fail_count = sum(
    1 for a in artifacts.values()
    if a["verdict"] in ("missing", "invalid", "degraded")
    and not a.get("optional")
)
partial_count = sum(1 for a in artifacts.values() if a["verdict"] == "partial")

# Required (phase A core)
required_missing = []
for required_name in ("tokens.json", "design-context.md", "metadata.json"):
    a = artifacts.get(required_name)
    if a is None or a["verdict"] in ("missing", "invalid"):
        required_missing.append(required_name)

if required_missing:
    gate = "FAIL"
elif fail_count > 0:
    gate = "FAIL"
elif partial_count > 0:
    gate = "PARTIAL"
else:
    gate = "PASS"

# Freshness escalation: stale cache → at least PARTIAL
if freshness_alert and gate == "PASS":
    gate = "PARTIAL"

if strict and gate == "PARTIAL":
    gate = "FAIL"

# Write c3-validate.json
validate_out = {
    "schemaVersion": 1,
    "nodeId": node_id,
    "generatedAt": now,
    "gate": gate,
    "artifacts": artifacts,
    "freshness": {
        "ageDays": round(age, 2),
        "alert": freshness_alert,
        "maxAgeDays": max_age_days,
    },
    "requiredMissing": required_missing,
}

# Atomic write c3-validate.json
v_path = os.path.join(cache, "c3-validate.json")
v_tmp = v_path + ".tmp." + str(os.getpid())
with open(v_tmp, "w") as f:
    json.dump(validate_out, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(v_tmp, v_path)

# Atomic write _status.json
s_tmp = status_path + ".tmp." + str(os.getpid())
with open(s_tmp, "w") as f:
    json.dump(status, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(s_tmp, status_path)

# Human-readable summary
print(f"GATE: {gate}")
print(f"  cacheAge: {age:.1f}d (max {max_age_days:.0f}d){' ⚠ STALE' if freshness_alert else ''}")
for name, a in sorted(artifacts.items()):
    v = a["verdict"]
    if v == "present":
        print(f"  ✓ {name}")
    elif v == "partial":
        why = a.get("reason") or a.get("schemaForm") or ""
        print(f"  ⚠ {name}: PARTIAL {why}")
    elif v == "missing":
        opt = " (optional)" if a.get("optional") else ""
        print(f"  ✗ {name}: MISSING{opt}")
    elif v == "invalid":
        print(f"  ✗ {name}: INVALID — {a.get('reason')}")
    elif v == "degraded":
        print(f"  ✗ {name}: DEGRADED — {a.get('reason')}")

if required_missing:
    print(f"  → Required artifacts missing: {','.join(required_missing)}")

# Exit code
if gate == "PASS":
    sys.exit(0)
elif gate == "PARTIAL":
    sys.exit(0 if accept_partial else 2)
else:
    sys.exit(1)
PY
RC=$?
exit $RC
