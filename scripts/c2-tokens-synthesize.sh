#!/usr/bin/env bash
# c2-tokens-synthesize.sh — synthesize tokens.json from c2-extracted.json when
# Variables API returned empty (403 file_variables:read scope OR plan-gated 200-empty).
#
# Per plan §C1: skill currently writes `_note: "reconstructed from inline styles"`
# but doesn't actually synthesize token entries. L2 then has nothing to match
# against → every color row FAIL false-positive. This script fixes that by
# emitting synthesized color + spacing entries (with `_synthesized: true` flag
# so L2 can emit `SYNTHESIZED_TOKEN_USED` warning).
#
# Synthesize rule (per user clarification #2):
#   - Colors: ONLY from inline hex literals in design-context.md.
#     Tailwind palette refs resolve at L2 match-time, not as synthesized tokens
#     (avoids tokens "appearing out of thin air").
#   - Spacing: from Tailwind `p-N`/`gap-N` class numerics (4×N pt).
#
# Output: writes back to .figma-cache/<nodeId>/tokens.json (overwriting empty).
# Marks `_schemaForm: "synthesized"` so c2-cache-validate can detect.
#
# Usage:
#   c2-tokens-synthesize.sh --cache <.figma-cache/nodeId> [--force]
#
# Exit:
#   0 — synthesized OR not needed (existing tokens.json has data)
#   1 — c2-extracted.json missing or empty (Phase 2 extract didn't run)
#  64 — bad usage

set -uo pipefail

CACHE=""
FORCE=0

print_usage() {
  cat <<'USAGE' >&2
usage: c2-tokens-synthesize.sh --cache <.figma-cache/nodeId> [--force]

Synthesize tokens.json from c2-extracted.json (Phase 2 normalization) when
the Variables API returned empty. Skipped when tokens.json already has
non-empty colors[] or spacing[] arrays (use --force to re-synthesize).

Synthesized entries carry `_synthesized: true`. L2 trace marks any code
relying on them with `SYNTHESIZED_TOKEN_USED` warning (informational).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)   CACHE="${2:-}"; shift 2 ;;
    --force)   FORCE=1; shift ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 64; }

EXTRACTED="$CACHE/c2-extracted.json"
TOKENS="$CACHE/tokens.json"

if [ ! -s "$EXTRACTED" ]; then
  echo "FAIL: c2-extracted.json missing — run c2-extract-design-context.sh first" >&2
  exit 1
fi

python3 - "$EXTRACTED" "$TOKENS" "$FORCE" <<'PY'
import json, os, sys, re

extracted_path, tokens_path, force = sys.argv[1], sys.argv[2], (sys.argv[3] == "1")

with open(extracted_path) as f:
    extracted = json.load(f)

# Load existing tokens (or empty)
try:
    with open(tokens_path) as f:
        tokens = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    tokens = {}

# Skip if tokens.json already has data (unless --force)
def has_data(t):
    return any(len(t.get(k) or []) > 0 for k in ("colors", "typography", "spacing"))

if has_data(tokens) and not force:
    print(f"SKIP: tokens.json already has entries — use --force to re-synthesize")
    sys.exit(0)

# ── Synthesize colors from inline hex literals ──────────────────────────────
hex_literals = extracted.get("hexLiterals") or []
synthesized_colors = []
seen_hex = set()
for hx in hex_literals:
    hx_low = hx.lower()
    if hx_low in seen_hex:
        continue
    seen_hex.add(hx_low)
    # Generate a swiftName from hex: synth_<hex sans #>
    sn = "synth_" + hx_low.lstrip("#")[:6]
    synthesized_colors.append({
        "swiftName": sn,
        "lightHex": hx_low,
        "darkHex": None,
        "_synthesized": True,
        "_source": "design-context.md inline hex",
    })

# ── Synthesize spacing from Tailwind classes ────────────────────────────────
SPACING_CLASSES = (extracted.get("tailwindClasses") or {}).get("spacing") or []
spacing_values_seen = set()
synthesized_spacing = []
TW_NUM_RE = re.compile(r'-(\d+(?:\.\d+)?)$')
for cls in SPACING_CLASSES:
    m = TW_NUM_RE.search(cls)
    if not m:
        continue
    n = float(m.group(1))
    pt = n * 4.0   # Tailwind unit = 4pt
    if pt in spacing_values_seen:
        continue
    spacing_values_seen.add(pt)
    sn = f"synth_sp{int(pt) if pt.is_integer() else str(pt).replace('.','p')}"
    synthesized_spacing.append({
        "swiftName": sn,
        "value": pt,
        "_synthesized": True,
        "_sourceClass": cls,
    })

# Merge into existing tokens (preserve non-synth entries if any)
existing_colors = tokens.get("colors") or []
existing_spacing = tokens.get("spacing") or []
existing_typography = tokens.get("typography") or []
existing_radius = tokens.get("radius") or []

# Avoid duplicate swiftName collisions
existing_sn = {c.get("swiftName") for c in existing_colors}
final_colors = list(existing_colors) + [c for c in synthesized_colors if c["swiftName"] not in existing_sn]
existing_sp_sn = {s.get("swiftName") for s in existing_spacing}
final_spacing = list(existing_spacing) + [s for s in synthesized_spacing if s["swiftName"] not in existing_sp_sn]

synthesized = {
    "colors":     final_colors,
    "typography": existing_typography,
    "spacing":    final_spacing,
    "radius":     existing_radius,
    "opacity":    tokens.get("opacity") or [],
    "_note": tokens.get("_note") or "synthesized from design-context.md (Variables API empty or 403 file_variables:read)",
    "_schemaForm": "synthesized",
    "_synthesizeStats": {
        "colorsAdded":  len(synthesized_colors),
        "spacingAdded": len(synthesized_spacing),
    },
}

# Atomic write
tmp = tokens_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(synthesized, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, tokens_path)

print(f"WROTE: {tokens_path}")
print(f"  +{len(synthesized_colors)} synthesized colors  (hex sources)")
print(f"  +{len(synthesized_spacing)} synthesized spacing (Tailwind classes)")
print(f"  schemaForm=synthesized")
PY
RC=$?
exit $RC
