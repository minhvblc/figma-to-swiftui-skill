#!/usr/bin/env bash
# c3-driver.sh — orchestrator for C3 verification layers.
#
# Subcommands:
#   trace      — L2 static token trace (calls c3-token-trace.sh)
#   residual   — L3 focused LLM judge prompt (not implemented in MVP — placeholder)
#   ssim       — L4 Engine-A SSIM gate    (not implemented in MVP — placeholder)
#   aggregate  — read all layer artifacts in cache, emit c3-gate.json with
#                final GATE: PASS|FAIL
#
# Lives at: scripts/c3-driver.sh
# Installed at: ~/.claude/scripts/c3-driver.sh
#
# Usage:
#   c3-driver.sh trace      --cache .figma-cache/<nodeId>
#   c3-driver.sh aggregate  --cache .figma-cache/<nodeId>
#
# Exit:
#   0 — GATE: PASS (or subcommand-specific success)
#   1 — GATE: FAIL
#  64 — bad usage
#  65 — missing dependency

set -uo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

SUBCOMMAND=""
CACHE=""
TOLERANCE="soft"
ACCEPT_PARTIAL=0
STRICT=0
SKIP_VALIDATE=0

print_usage() {
  cat <<'USAGE' >&2
usage: c3-driver.sh <subcommand> --cache <.figma-cache/nodeId> [...]

Subcommands:
  validate     Run cache-integrity schema check (c2-cache-validate.sh)
  trace        Run L2 static token trace, write c3-trace.md + c3-trace.json
               (auto-runs validate first unless --skip-validate)
  safearea     Run safe-area placement gate (c3-safearea-gate.sh), write
               c3-safearea.json
  residual     Compose L3 LLM judge prompt (NOT IMPLEMENTED — Phase 2)
  ssim         Run L4 Engine-A SSIM gate  (NOT IMPLEMENTED — Phase 3)
  aggregate    Read all layer artifacts, write c3-gate.json + final GATE

Common flags:
  --tolerance soft|strict     L2 frame/padding tolerance (default soft)
  --accept-partial            validate PARTIAL → PASS (otherwise blocks trace)
  --strict                    validate PARTIAL → FAIL
  --skip-validate             trace runs without prior validate (NOT recommended)

Examples:
  c3-driver.sh validate  --cache .figma-cache/1234:5678
  c3-driver.sh trace     --cache .figma-cache/1234:5678
  c3-driver.sh safearea  --cache .figma-cache/1234:5678
  c3-driver.sh aggregate --cache .figma-cache/1234:5678
USAGE
}

[ $# -ge 1 ] || { print_usage; exit 64; }
SUBCOMMAND="$1"; shift

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)            CACHE="${2:-}"; shift 2 ;;
    --tolerance)        TOLERANCE="${2:-soft}"; shift 2 ;;
    --accept-partial)   ACCEPT_PARTIAL=1; shift ;;
    --strict)           STRICT=1; shift ;;
    --skip-validate)    SKIP_VALIDATE=1; shift ;;
    -h|--help)          print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { echo "FAIL: --cache required" >&2; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 64; }

# Resolve sibling scripts: prefer repo location (running from clone) over
# installed location, but fall back to ~/.claude/scripts/ when invoked from a
# user's iOS project where this driver was copied to.
resolve_script() {
  local name="$1"
  if [ -x "$SCRIPT_DIR/$name" ]; then
    echo "$SCRIPT_DIR/$name"
    return 0
  fi
  if [ -x "$HOME/.claude/scripts/$name" ]; then
    echo "$HOME/.claude/scripts/$name"
    return 0
  fi
  return 1
}

# ── validate ─────────────────────────────────────────────────────────────────
cmd_validate() {
  local validate_script
  validate_script=$(resolve_script "c2-cache-validate.sh") || {
    echo "FAIL: c2-cache-validate.sh not found (looked in $SCRIPT_DIR and ~/.claude/scripts/)" >&2
    exit 65
  }
  local args=("--cache" "$CACHE")
  [ "$ACCEPT_PARTIAL" = "1" ] && args+=("--accept-partial")
  [ "$STRICT" = "1" ] && args+=("--strict")
  bash "$validate_script" "${args[@]}"
}

# ── trace ────────────────────────────────────────────────────────────────────
# Pre-flight: run validate first to ensure cache integrity before trusting
# any trace result. User can --skip-validate but that defeats the safety.
cmd_trace() {
  if [ "$SKIP_VALIDATE" != "1" ]; then
    local validate_script
    validate_script=$(resolve_script "c2-cache-validate.sh")
    if [ -n "$validate_script" ]; then
      echo "── pre-flight: cache integrity ──"
      local v_args=("--cache" "$CACHE")
      [ "$ACCEPT_PARTIAL" = "1" ] && v_args+=("--accept-partial")
      [ "$STRICT" = "1" ] && v_args+=("--strict")
      if ! bash "$validate_script" "${v_args[@]}"; then
        echo "" >&2
        echo "FAIL: cache integrity gate failed — refuse to run L2 trace on suspect cache" >&2
        echo "  Fix issues above, then re-run." >&2
        echo "  To override (NOT recommended): add --skip-validate" >&2
        exit 1
      fi
      echo ""
      echo "── L2 token trace ──"
    fi
  fi

  local trace_script
  trace_script=$(resolve_script "c3-token-trace.sh") || {
    echo "FAIL: c3-token-trace.sh not found (looked in $SCRIPT_DIR and ~/.claude/scripts/)" >&2
    exit 65
  }
  bash "$trace_script" --cache "$CACHE" --tolerance "$TOLERANCE"
}

# ── safearea ─────────────────────────────────────────────────────────────────
cmd_safearea() {
  local sa_script
  sa_script=$(resolve_script "c3-safearea-gate.sh") || {
    echo "FAIL: c3-safearea-gate.sh not found (looked in $SCRIPT_DIR and ~/.claude/scripts/)" >&2
    exit 65
  }
  bash "$sa_script" --cache "$CACHE"
}

# ── residual (placeholder) ───────────────────────────────────────────────────
cmd_residual() {
  cat <<EOF
SKIP: L3 residual judge not implemented in MVP.

When implemented (Phase 2), this subcommand will:
  - Compose a focused LLM prompt with: Swift file + screenshot.png +
    design-context.md + c3-trace.md (already-audited)
  - Limit review to 7 residual axes: shadow, gradient stops, text alignment
    in compound layouts, blend mode, letter spacing precision, border-radius
    shape, button internal layout
  - Emit c3-residual-diff.md (FAIL/N/A rows only — PASS banned)

For now, treat L3 as N/A in c3-gate.json aggregate.
EOF
  exit 0
}

# ── ssim (placeholder) ───────────────────────────────────────────────────────
cmd_ssim() {
  cat <<EOF
SKIP: L4 Engine-A SSIM gate not implemented in MVP.

When implemented (Phase 3), this subcommand will:
  - Probe manifest.json.verification.c3.l4Trigger; skip unless "onPreship" or "forced"
  - Instruct agent to call mcp__xcode__BuildProject + mcp__xcode__RenderPreview
  - Compute SSIM via ImageMagick: compare -metric SSIM screenshot-cmp.png c5-render-cmp.png diff-mask.png
  - SSIM ≥ 0.92 → PASS; emit diff-mask.png only (no full pair)
  - SSIM < 0.92 → feed diff-mask.png back to L3 round 2

For now, treat L4 as N/A in c3-gate.json aggregate.
EOF
  exit 0
}

# ── aggregate ────────────────────────────────────────────────────────────────
cmd_aggregate() {
  python3 - "$CACHE" <<'PY'
import json, os, sys
from datetime import datetime, timezone

cache = sys.argv[1]

def load(name):
    p = os.path.join(cache, name)
    try:
        with open(p) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None

audit    = load("c2-audit.json")
trace    = load("c3-trace.json")
validate = load("c3-validate.json")
safearea = load("c3-safearea.json")

layers = {}

# L0 — Cache validate
if validate:
    layers["l0"] = {
        "gate": validate.get("gate"),
        "artifacts": {k: v.get("verdict") for k, v in (validate.get("artifacts") or {}).items()},
        "freshnessAlert": (validate.get("freshness") or {}).get("alert"),
        "requiredMissing": validate.get("requiredMissing", []),
        "artifact": "c3-validate.json",
    }
else:
    layers["l0"] = {"gate": "SKIP", "reason": "c3-validate.json missing — run `c3-driver.sh validate` first"}


# L1 — Audit emission
if audit:
    files = audit.get("files") or {}
    total_rows = sum(len(f.get("rows") or []) for f in files.values())
    unknown = sum(int(f.get("unknownModifierCount", 0)) for f in files.values())
    parser_mode = audit.get("parserMode", "unknown")
    l1_gate = "PASS"
    if parser_mode in {"missing", "regex-fallback"}:
        l1_gate = "FAIL"
    elif unknown > 3:
        l1_gate = "FAIL"
    layers["l1"] = {
        "gate": l1_gate,
        "parserMode": parser_mode,
        "fileCount": len(files),
        "totalRows": total_rows,
        "unknownModifierCount": unknown,
        "artifact": "c2-audit.json",
    }
else:
    layers["l1"] = {"gate": "SKIP", "reason": "c2-audit.json missing — L1 hook didn't fire"}

# L2 — Token trace
if trace:
    layers["l2"] = {
        "gate": trace.get("gate"),
        "summary": trace.get("summary"),
        "gateReasons": trace.get("gateReasons", []),
        "artifact": "c3-trace.md",
    }
else:
    layers["l2"] = {"gate": "SKIP", "reason": "c3-trace.json missing — run `c3-driver.sh trace` first"}

# L2.5 — Safe-area placement gate (anti-patterns.md AP-13)
if safearea:
    layers["l2_safearea"] = {
        "gate": safearea.get("gate"),
        "summary": safearea.get("summary"),
        "findingsCount": len(safearea.get("findings") or []),
        "artifact": "c3-safearea.json",
    }
else:
    layers["l2_safearea"] = {"gate": "SKIP", "reason": "c3-safearea.json missing — run `c3-driver.sh safearea` first"}

# L3/L4 — not implemented in MVP
layers["l3"] = {"gate": "SKIP", "reason": "L3 residual judge not implemented in MVP (Phase 2)"}
layers["l4"] = {"gate": "SKIP", "reason": "L4 SSIM not implemented in MVP (Phase 3)"}

# Final gate: PASS when L1+L2 PASS (or one SKIP with reason). FAIL when any FAIL.
final_gate = "PASS"
for name, l in layers.items():
    if l.get("gate") == "FAIL":
        final_gate = "FAIL"
        break

aggregate = {
    "schemaVersion": 1,
    "nodeId": (audit or {}).get("nodeId") or (trace or {}).get("nodeId"),
    "generatedAt": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "gate": final_gate,
    "layers": layers,
}

out_path = os.path.join(cache, "c3-gate.json")
tmp = out_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(aggregate, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out_path)

print(f"GATE: {final_gate}")
for name in ("l0", "l1", "l2", "l2_safearea", "l3", "l4"):
    l = layers[name]
    g = l.get("gate", "?")
    extra = ""
    if name == "l0" and "artifacts" in l:
        good = sum(1 for v in l["artifacts"].values() if v == "present")
        total = len(l["artifacts"])
        stale = " ⚠STALE" if l.get("freshnessAlert") else ""
        extra = f" ({good}/{total} artifacts present{stale})"
    elif name == "l1" and "totalRows" in l:
        extra = f" (parserMode={l['parserMode']}, files={l['fileCount']}, rows={l['totalRows']}, unknown={l['unknownModifierCount']})"
    elif name == "l2" and "summary" in l and l["summary"]:
        s = l["summary"]
        extra = f" (pass={s.get('pass', 0)}, fail={s.get('fail', 0)}, na={s.get('na', 0)})"
    elif name == "l2_safearea" and "summary" in l and l["summary"]:
        s = l["summary"]
        extra = f" (violations={s.get('violations', 0)}, warnings={s.get('warnings', 0)})"
    elif "reason" in l:
        extra = f" ({l['reason']})"
    label = "L2.5" if name == "l2_safearea" else name.upper()
    print(f"  {label}: {g}{extra}")

sys.exit(0 if final_gate == "PASS" else 1)
PY
}

case "$SUBCOMMAND" in
  validate)   cmd_validate ;;
  trace)      cmd_trace ;;
  safearea)   cmd_safearea ;;
  residual)   cmd_residual ;;
  ssim)       cmd_ssim ;;
  aggregate)  cmd_aggregate ;;
  -h|--help)  print_usage; exit 0 ;;
  *) echo "unknown subcommand: $SUBCOMMAND" >&2; print_usage; exit 64 ;;
esac
