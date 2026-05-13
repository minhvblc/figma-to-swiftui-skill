#!/usr/bin/env bash
# c3-token-trace.sh — L2 static token trace.
#
# Reads `.figma-cache/<nodeId>/c2-audit.json` (emitted by L1 PostToolUse hook)
# and cross-references every row against:
#   - tokens.json    — colors[]/typography[]/spacing[]/radius[]/opacity[]
#   - design-context.md — Tailwind classes + verbatim text
#   - metadata.json  — Figma node bbox tree (for frame match)
#   - manifest.json  — rows[].exportName / friendlyName (for image match)
#   - fills.json     — per-node fill stacks (optional)
#
# Emits:
#   .figma-cache/<nodeId>/c3-trace.md   — PASS/FAIL table
#   .figma-cache/<nodeId>/c3-trace.json — machine-readable summary
#
# Gate FAIL conditions (any of these → GATE: FAIL):
#   - audit.json missing
#   - parserMode == "missing" OR "regex-fallback" (degraded)
#   - per-file unknownModifierCount > 3
#   - any FAIL row in trace
#
# Tolerance (soft per plan):
#   - color (tokenRef) — exact swiftName match
#   - color (literal hex) — hex VERBATIM in design-context.md
#   - frame (w/h)     — ±2pt
#   - padding/spacing — ±2pt
#   - image (assetRef) — exact swiftName in manifest.rows[]
#
# Usage:
#   c3-token-trace.sh --cache <.figma-cache/nodeId> [--tolerance soft|strict]
#
# Exit:
#   0 — GATE: PASS
#   1 — GATE: FAIL
#  64 — bad usage

set -uo pipefail

CACHE=""
TOLERANCE="soft"

print_usage() {
  cat <<'USAGE' >&2
usage: c3-token-trace.sh --cache <.figma-cache/nodeId>
                         [--tolerance soft|strict]

Cross-references c2-audit.json (emitted by L1 audit-emit hook) against the
Figma artifacts in the cache, writes c3-trace.md + c3-trace.json, and exits
PASS only when every row traces back to a Figma source.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)      CACHE="${2:-}"; shift 2 ;;
    --tolerance)  TOLERANCE="${2:-soft}"; shift 2 ;;
    -h|--help)    print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 64; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 64; }

AUDIT="$CACHE/c2-audit.json"
TRACE_MD="$CACHE/c3-trace.md"
TRACE_JSON="$CACHE/c3-trace.json"

if [ ! -f "$AUDIT" ]; then
  echo "GATE: FAIL (c2-audit.json missing at $AUDIT — L1 hook didn't fire?)"
  exit 1
fi

python3 - "$CACHE" "$TOLERANCE" "$TRACE_MD" "$TRACE_JSON" <<'PY'
import json, os, re, sys
from pathlib import Path

cache_dir, tolerance, trace_md, trace_json = sys.argv[1:5]

# ── Load all sources (each is optional except audit.json) ────────────────────

def load_json(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError):
        return None

def load_text(path):
    try:
        with open(path) as f:
            return f.read()
    except FileNotFoundError:
        return ""

audit = load_json(os.path.join(cache_dir, "c2-audit.json")) or {}

# tokens.json lives in _shared/ (per Phase A flow); also accept a per-node copy
tokens = (load_json(os.path.join(cache_dir, "tokens.json"))
          or load_json(os.path.join(cache_dir, "..", "_shared", "tokens.json"))
          or {})

design_ctx = load_text(os.path.join(cache_dir, "design-context.md"))
metadata = load_json(os.path.join(cache_dir, "metadata.json")) or {}
manifest = load_json(os.path.join(cache_dir, "manifest.json")) or {}
fills = load_json(os.path.join(cache_dir, "fills.json")) or {}

# Phase 2 normalization layers (optional — fallback when absent)
extracted = load_json(os.path.join(cache_dir, "c2-extracted.json")) or {}
bbox_index = load_json(os.path.join(cache_dir, "c2-bbox-index.json")) or {}

# Plan §1.3 — per-line typography + per-node gradient stops (optional)
typography_perline = load_json(os.path.join(cache_dir, "c2-typography-perline.json")) or {}
fills_stops_index = load_json(os.path.join(cache_dir, "c2-fills-stops.json")) or {}

# Tolerance config
TOL = {"frame": 2.0, "padding": 2.0, "spacing": 2.0}
if tolerance == "strict":
    TOL = {"frame": 0.0, "padding": 0.0, "spacing": 0.0}

# ── Build lookups ────────────────────────────────────────────────────────────

token_colors    = {c.get("swiftName"): c for c in (tokens.get("colors")     or []) if c.get("swiftName")}
token_fonts     = {t.get("swiftName"): t for t in (tokens.get("typography") or []) if t.get("swiftName")}
token_font_alts = {t.get("name"):      t for t in (tokens.get("typography") or []) if t.get("name")}
token_spacings  = {s.get("swiftName"): s for s in (tokens.get("spacing")    or []) if s.get("swiftName")}
token_radii     = {r.get("swiftName"): r for r in (tokens.get("radius")     or []) if r.get("swiftName")}

# Numeric reverse lookups (for soft tolerance match by value)
spacing_values = [(s.get("value"), s.get("swiftName")) for s in (tokens.get("spacing") or []) if s.get("value") is not None]
radius_values  = [(r.get("value"), r.get("swiftName")) for r in (tokens.get("radius")  or []) if r.get("value") is not None]

# ── Tailwind 3.x palette (subset of common shades — for L2 resolve) ──────────
# Source: Tailwind 3.x default palette. NOT exhaustive — covers the ~80 most
# common shades. Update when Tailwind v4 lands.
TAILWIND_PALETTE = {
    "slate-50":"#f8fafc","slate-100":"#f1f5f9","slate-200":"#e2e8f0","slate-300":"#cbd5e1",
    "slate-400":"#94a3b8","slate-500":"#64748b","slate-600":"#475569","slate-700":"#334155",
    "slate-800":"#1e293b","slate-900":"#0f172a","slate-950":"#020617",
    "gray-50":"#f9fafb","gray-100":"#f3f4f6","gray-200":"#e5e7eb","gray-300":"#d1d5db",
    "gray-400":"#9ca3af","gray-500":"#6b7280","gray-600":"#4b5563","gray-700":"#374151",
    "gray-800":"#1f2937","gray-900":"#111827","gray-950":"#030712",
    "zinc-50":"#fafafa","zinc-100":"#f4f4f5","zinc-200":"#e4e4e7","zinc-300":"#d4d4d8",
    "zinc-400":"#a1a1aa","zinc-500":"#71717a","zinc-600":"#52525b","zinc-700":"#3f3f46",
    "zinc-800":"#27272a","zinc-900":"#18181b","zinc-950":"#09090b",
    "neutral-50":"#fafafa","neutral-100":"#f5f5f5","neutral-200":"#e5e5e5","neutral-300":"#d4d4d4",
    "neutral-400":"#a3a3a3","neutral-500":"#737373","neutral-600":"#525252","neutral-700":"#404040",
    "neutral-800":"#262626","neutral-900":"#171717","neutral-950":"#0a0a0a",
    "stone-50":"#fafaf9","stone-100":"#f5f5f4","stone-200":"#e7e5e4","stone-300":"#d6d3d1",
    "stone-400":"#a8a29e","stone-500":"#78716c","stone-600":"#57534e","stone-700":"#44403c",
    "stone-800":"#292524","stone-900":"#1c1917","stone-950":"#0c0a09",
    "red-50":"#fef2f2","red-100":"#fee2e2","red-200":"#fecaca","red-300":"#fca5a5",
    "red-400":"#f87171","red-500":"#ef4444","red-600":"#dc2626","red-700":"#b91c1c",
    "red-800":"#991b1b","red-900":"#7f1d1d","red-950":"#450a0a",
    "orange-400":"#fb923c","orange-500":"#f97316","orange-600":"#ea580c","orange-700":"#c2410c",
    "amber-400":"#fbbf24","amber-500":"#f59e0b","amber-600":"#d97706",
    "yellow-400":"#facc15","yellow-500":"#eab308","yellow-600":"#ca8a04",
    "lime-400":"#a3e635","lime-500":"#84cc16","lime-600":"#65a30d",
    "green-400":"#4ade80","green-500":"#22c55e","green-600":"#16a34a","green-700":"#15803d",
    "emerald-400":"#34d399","emerald-500":"#10b981","emerald-600":"#059669",
    "teal-400":"#2dd4bf","teal-500":"#14b8a6","teal-600":"#0d9488",
    "cyan-400":"#22d3ee","cyan-500":"#06b6d4","cyan-600":"#0891b2",
    "sky-400":"#38bdf8","sky-500":"#0ea5e9","sky-600":"#0284c7",
    "blue-400":"#60a5fa","blue-500":"#3b82f6","blue-600":"#2563eb","blue-700":"#1d4ed8",
    "indigo-400":"#818cf8","indigo-500":"#6366f1","indigo-600":"#4f46e5","indigo-700":"#4338ca",
    "violet-400":"#a78bfa","violet-500":"#8b5cf6","violet-600":"#7c3aed",
    "purple-400":"#c084fc","purple-500":"#a855f7","purple-600":"#9333ea",
    "fuchsia-400":"#e879f9","fuchsia-500":"#d946ef","fuchsia-600":"#c026d3",
    "pink-400":"#f472b6","pink-500":"#ec4899","pink-600":"#db2777",
    "rose-400":"#fb7185","rose-500":"#f43f5e","rose-600":"#e11d48",
    "white":"#ffffff","black":"#000000",
}
# Bracket form `text-[#hex]` already covered by raw hex extraction.

def tailwind_class_to_hex(cls):
    """`text-gray-400` → `#9ca3af`. Returns None if not a known palette ref."""
    if not cls:
        return None
    # Strip prefix
    parts = cls.split("-", 1)
    if len(parts) < 2:
        return None
    prefix, rest = parts
    if prefix not in {"text","bg","border","fill","stroke","ring","placeholder",
                       "caret","divide","accent","outline","decoration"}:
        return None
    # Bracket arbitrary form: `text-[#hex]` → extract hex directly
    if rest.startswith("[#") and rest.endswith("]"):
        hex_part = rest[1:-1]   # `#hex`
        if re.fullmatch(r'#[0-9a-fA-F]{3,8}', hex_part):
            return hex_part.lower()
        return None
    # CSS var bracket form: `text-[var(--foo)]` → resolve via cssVars
    css_var_match = re.fullmatch(r'\[var\((--[a-zA-Z0-9_-]+)\)\]', rest)
    if css_var_match:
        css_vars = extracted.get("cssVars") or {}
        val = css_vars.get(css_var_match.group(1))
        if val and re.fullmatch(r'#[0-9a-fA-F]{3,8}', val):
            return val.lower()
        return None
    # Plain palette lookup
    return TAILWIND_PALETTE.get(rest.lower())

def normalize_text(s):
    """Casefold + smart-quote/dash normalize + collapse whitespace."""
    if not s:
        return ""
    s = s.replace("‘", "'").replace("’", "'")
    s = s.replace("“", '"').replace("”", '"')
    s = s.replace("–", "-").replace("—", "-")
    s = re.sub(r'\s+', ' ', s).strip()
    return s.casefold()

# Manifest assets — STRICT FILTER: only rows with status == "done" count.
# Catches the failure mode where a manifest contains `status: "failed"` rows
# and L2 would silently accept asset references that don't actually exist
# on disk. See plan §B4.
manifest_rows = manifest.get("rows") or []
asset_names = set()
manifest_failed_rows = []
for row in manifest_rows:
    row_status = row.get("status", "unknown")
    if row_status != "done":
        # Track for surfacing in coverage gate
        manifest_failed_rows.append({
            "exportName": row.get("exportName") or row.get("friendlyName") or "?",
            "status": row_status,
            "reason": row.get("reason"),
        })
        continue
    for f in ("exportName", "friendlyName"):
        v = row.get(f)
        if v:
            asset_names.add(v)

# Tailwind padding/gap classes in design-context.md (4×N pt convention)
# Match p-N, px-N, py-N, pt-N, pr-N, pb-N, pl-N, gap-N, gap-x-N, gap-y-N,
# space-x-N, space-y-N, m-N, mt-N, mr-N, mb-N, ml-N, mx-N, my-N.
TAILWIND_SPACING_RE = re.compile(r'\b(?:p[xytrbl]?|m[xytrbl]?|gap(?:-[xy])?|space-[xy])-(\d+(?:\.\d+)?)\b')
tailwind_spacings_pt = set()
for m in TAILWIND_SPACING_RE.finditer(design_ctx):
    n = float(m.group(1))
    tailwind_spacings_pt.add(n * 4.0)   # Tailwind unit = 4pt

# Walk metadata nodes for bbox match
def collect_bboxes(node, acc):
    if not isinstance(node, dict):
        return
    bbox = node.get("absoluteBoundingBox") or node.get("bbox") or node.get("box")
    if isinstance(bbox, dict):
        w = bbox.get("width")
        h = bbox.get("height")
        if isinstance(w, (int, float)) and isinstance(h, (int, float)):
            acc.append({"nodeId": node.get("id"), "name": node.get("name"), "w": float(w), "h": float(h)})
    for ch in (node.get("children") or []):
        collect_bboxes(ch, acc)

bboxes = []
if isinstance(metadata, dict):
    if "rootNode" in metadata:
        collect_bboxes(metadata["rootNode"], bboxes)
    elif "document" in metadata:
        collect_bboxes(metadata["document"], bboxes)
    else:
        collect_bboxes(metadata, bboxes)

# Verbatim hex literals in design-context.md — prefer the pre-extracted set
# from c2-extracted.json (Phase 2) for cleanliness, fall back to regex sweep.
if extracted and isinstance(extracted.get("hexLiterals"), list):
    design_hexes = set(h.lower() for h in extracted["hexLiterals"])
    # Also pull in resolved Tailwind palette refs as legitimate hexes
    for cls in (extracted.get("tailwindClasses") or {}).get("color") or []:
        resolved = tailwind_class_to_hex(cls)
        if resolved:
            design_hexes.add(resolved.lower())
    # Add CSS var values
    for var_name, val in (extracted.get("cssVars") or {}).items():
        if isinstance(val, str) and re.fullmatch(r'#[0-9a-fA-F]{3,8}', val):
            design_hexes.add(val.lower())
else:
    HEX_RE = re.compile(r'#[0-9a-fA-F]{6,8}\b')
    design_hexes = set(m.group(0).lower() for m in HEX_RE.finditer(design_ctx))

# Pre-normalized text segments for matching (Phase 2)
if extracted and isinstance(extracted.get("textSegmentsNormalized"), list):
    text_segments_normalized = set(extracted["textSegmentsNormalized"])
else:
    text_segments_normalized = set()

def text_in_design_ctx(t):
    """Two paths: normalized comparison (preferred) or raw substring (fallback)."""
    if not t:
        return False
    if text_segments_normalized:
        norm = normalize_text(t)
        if norm in text_segments_normalized:
            return True
        # Allow partial match (text segment contains the literal, e.g. "Welcome back" in design)
        return any(norm in seg or seg in norm for seg in text_segments_normalized if len(seg) > 2)
    return t in design_ctx

# ── Match logic per row ─────────────────────────────────────────────────────

def trace_row(row, file_rel):
    """Return (verdict: 'PASS'|'FAIL'|'N/A', reason, suggestion)."""
    kind = row.get("kind")
    value = row.get("value") or {}
    form = value.get("form")
    owner = row.get("ownerType", "")

    # ── color
    if kind == "color":
        if form == "tokenRef":
            name = value.get("name") or ""
            if not name:
                return "FAIL", "color row has no token name", ""
            if name in token_colors:
                return "PASS", f"tokens.json#{name}", ""
            # Common SwiftUI built-in tokens — accept but warn
            builtins = {"accentColor", "primary", "secondary", "clear", "black", "white",
                        "red", "blue", "green", "yellow", "orange", "pink", "purple",
                        "gray", "infinity"}
            if name in builtins:
                return "PASS", f"SwiftUI built-in Color.{name}", ""
            return "FAIL", f"swiftName '{name}' not in tokens.json", suggest_color(name)
        if form == "literal":
            hex_val = (value.get("hex") or value.get("raw") or "").lower()
            for h in design_hexes:
                if h in hex_val or hex_val.startswith(h):
                    return "PASS", f"hex {h} verbatim in design-context.md", ""
            # Owner might be a modifier with no extractable value (e.g. opacity 0.7)
            if owner in {"opacity", "blendMode"}:
                return "N/A", f"{owner} modifier — visual review only", ""
            if owner == "shadow":
                return "N/A", "shadow — L3 visual review", ""
            return "FAIL", "no matching hex in design-context.md", suggest_color_hex(hex_val)

    # ── image
    if kind == "image":
        if form == "assetRef":
            name = value.get("name") or ""
            if name in asset_names:
                return "PASS", f"manifest#{name}", ""
            return "FAIL", f"asset '{name}' not in manifest.rows", suggest_asset(name)
        if form == "systemNamedAllowed":
            sym = value.get("systemName") or ""
            allow = {"chevron.backward", "chevron.left", "square.and.arrow.up",
                     "xmark.circle.fill"}
            if sym in allow or sym.startswith("keyboard"):
                return "PASS", f"systemName '{sym}' in C6 allow-list", ""
            return "FAIL", f"systemName '{sym}' outside allow-list — use Figma asset", suggest_asset(sym)
        if form == "literal":
            return "FAIL", "Image(\"name\") string form — banned, use Image(.swiftName)", ""

    # ── frame
    if kind == "frame":
        if owner == "frame":
            w = value.get("width")
            h = value.get("height")
            if w is None and h is None:
                return "N/A", "frame with no fixed w/h (likely maxWidth)", ""
            # Phase 2: prefer nodeId hint lookup via c2-bbox-index.json
            hint = (row.get("claim") or {}).get("nodeIdHint")
            if hint and bbox_index:
                by_id = (bbox_index.get("byNodeId") or {})
                if hint in by_id:
                    target = by_id[hint]
                    w_ok = w is None or abs(target["w"] - w) <= TOL["frame"]
                    h_ok = h is None or abs(target["h"] - h) <= TOL["frame"]
                    if w_ok and h_ok:
                        return "PASS", f"bbox-index#{hint} {target['w']:.0f}×{target['h']:.0f} (nodeId hint)", ""
                    else:
                        return "FAIL", f"nodeId hint {hint} bbox {target['w']:.0f}×{target['h']:.0f} doesn't match w={w} h={h} (±{TOL['frame']}pt)", ""
            # Phase 2: try byBboxKey index (O(1) hit before falling back to walk)
            if bbox_index and isinstance(w, (int, float)) and isinstance(h, (int, float)):
                key = f"{int(round(w))}x{int(round(h))}"
                hits = (bbox_index.get("byBboxKey") or {}).get(key)
                if hits:
                    if len(hits) == 1:
                        return "PASS", f"bbox-index#{hits[0]} {w:.0f}×{h:.0f}", ""
                    else:
                        return "PASS", f"bbox-index ambiguous ({len(hits)} nodes: {','.join(hits[:3])}) — consider adding `// Figma: <nodeId>` comment", ""
            # Fallback: walk bboxes (legacy path; used when no Phase 2 index)
            for bb in bboxes:
                if w is not None and abs(bb["w"] - w) > TOL["frame"]:
                    continue
                if h is not None and abs(bb["h"] - h) > TOL["frame"]:
                    continue
                return "PASS", f"metadata#{bb['nodeId']} bbox {bb['w']:.0f}×{bb['h']:.0f} (Δ≤{TOL['frame']}pt)", ""
            return "FAIL", f"no metadata node bbox matches w={w} h={h} (±{TOL['frame']}pt)", ""
        if owner == "cornerRadius":
            amt = value.get("amount")
            if amt is None:
                return "N/A", "cornerRadius — value not extracted", ""
            for v, sn in radius_values:
                if abs(v - amt) <= TOL["frame"]:
                    return "PASS", f"radius#{sn}={v}", ""
            return "FAIL", f"cornerRadius {amt}pt not in tokens.radius[]", ""
        if owner in {"clipShape", "blur", "shadow"}:
            return "N/A", f"{owner} — L3 visual review", ""

    # ── padding
    if kind == "padding":
        amt = value.get("amount")
        if amt is None:
            return "N/A", "padding() with no amount — system default", ""
        # 1. Token match
        for v, sn in spacing_values:
            if abs(v - amt) <= TOL["padding"]:
                return "PASS", f"spacing#{sn}={v}", ""
        # 2. Tailwind class match
        for t in tailwind_spacings_pt:
            if abs(t - amt) <= TOL["padding"]:
                return "PASS", f"design-context Tailwind class p-{int(t/4)} = {t}pt", ""
        return "FAIL", f"padding {amt}pt not in tokens.spacing[] or design-context Tailwind", suggest_padding(amt)

    # ── stack (spacing field)
    if kind == "stack":
        sp = value.get("spacing")
        if sp is None:
            return "N/A", f"{owner} default spacing", ""
        for v, sn in spacing_values:
            if abs(v - sp) <= TOL["spacing"]:
                return "PASS", f"spacing#{sn}={v} (stack spacing)", ""
        for t in tailwind_spacings_pt:
            if abs(t - sp) <= TOL["spacing"]:
                return "PASS", f"design-context gap-{int(t/4)} = {t}pt", ""
        return "FAIL", f"stack spacing {sp}pt not in tokens.spacing[] or design-context gap-N", ""

    # ── font
    if kind == "font":
        preset = value.get("preset")
        if preset:
            if preset in token_fonts or preset in token_font_alts:
                return "PASS", f"typography#{preset}", ""
            # SwiftUI built-in
            builtins = {"system", "body", "title", "title2", "title3", "headline",
                        "subheadline", "callout", "footnote", "caption", "caption2",
                        "largeTitle"}
            if preset in builtins:
                if preset == "system":
                    # .font(.system(size:, weight:)) — must match a typography entry
                    sz = value.get("size")
                    wt = value.get("weight")
                    if sz is not None:
                        for tk in (tokens.get("typography") or []):
                            if abs((tk.get("size") or -999) - sz) < 0.5:
                                tk_wt = (tk.get("weight") or "").lower()
                                if not wt or tk_wt == wt.lower():
                                    return "PASS", f"typography#{tk.get('swiftName')} size={sz} weight={wt}", ""
                        return "FAIL", f".font(.system(size: {sz}, weight: {wt})) — no typography entry matches", ""
                    return "N/A", ".system without size — caller-driven", ""
                return "PASS", f"SwiftUI built-in .{preset}", ""
            return "FAIL", f"font preset '{preset}' not in tokens.typography[]", suggest_font(preset)
        # Modifier like .fontWeight / .tracking / .lineSpacing — Plan §1.3
        # bridges these to c2-typography-perline.json via value.textHint
        # (closest Text("…") literal in the same modifier chain, captured by
        # the L1 audit). When the per-line map has the entry, we PASS/FAIL
        # against Figma's Tailwind class instead of degrading to N/A.
        if owner in {"fontWeight", "tracking", "kerning", "lineSpacing"}:
            txt_hint = value.get("textHint")
            perline = (typography_perline.get("byTextNormalized") or {})
            if txt_hint and perline:
                norm = normalize_text(txt_hint)
                entry = perline.get(norm)
                if not entry:
                    # try partial match
                    for k, v in perline.items():
                        if norm and (norm in k or k in norm):
                            entry = v
                            break
                if entry:
                    amt = value.get("amount")
                    if owner == "lineSpacing" and amt is not None:
                        # SwiftUI .lineSpacing(N) is ADDITIONAL spacing on top of
                        # font's natural line height; Tailwind `leading-X` is the
                        # TOTAL line-height (ratio of fontSize, or pt). The two
                        # are not directly comparable as numbers — we only flag
                        # the OBVIOUS mismatch: Tailwind leading-tight (1.25)
                        # paired with SwiftUI .lineSpacing(>= 8) is suspicious.
                        expected = entry.get("leading")
                        if expected is None:
                            return "N/A", f".lineSpacing({amt}) — no leading in design-context for '{txt_hint}'", ""
                        # Ratio: 1.0 = none extra, > 1.5 = generous
                        if expected <= 1.1 and amt >= 6:
                            return "FAIL", f".lineSpacing({amt}) but design-context says leading={expected} (tight) for '{txt_hint}'", ""
                        if expected >= 1.5 and amt <= 1:
                            return "FAIL", f".lineSpacing({amt}) but design-context says leading={expected} (loose) for '{txt_hint}'", ""
                        return "PASS", f"typography-perline leading={expected} for '{txt_hint}' (compatible with .lineSpacing({amt}))", ""
                    if owner in {"tracking", "kerning"} and amt is not None:
                        expected = entry.get("tracking")
                        if expected is None:
                            return "N/A", f".{owner}({amt}) — no tracking in design-context for '{txt_hint}'", ""
                        # Tailwind tracking is in em. SwiftUI .tracking is in pt
                        # (absolute). Convert design value if it was an em ratio
                        # against entry.fontSize.
                        font_sz = entry.get("fontSize")
                        if abs(expected) < 1.0 and font_sz:
                            # em → pt
                            expected_pt = expected * font_sz
                        else:
                            expected_pt = expected  # already pt
                        if abs(expected_pt - amt) <= 0.5:
                            return "PASS", f"typography-perline tracking={expected_pt:.2f}pt for '{txt_hint}'", ""
                        return "FAIL", f".{owner}({amt}) but design-context says {expected_pt:.2f}pt for '{txt_hint}'", ""
                    if owner == "fontWeight":
                        w = (value.get("weight") or "").lower()
                        expected = (entry.get("fontWeight") or "").lower()
                        if not expected:
                            return "N/A", f".fontWeight — no weight in design-context for '{txt_hint}'", ""
                        if w == expected:
                            return "PASS", f"typography-perline fontWeight={expected} for '{txt_hint}'", ""
                        return "FAIL", f".fontWeight(.{w}) but design-context says {expected} for '{txt_hint}'", ""
            return "N/A", f"{owner} — no textHint linkage to design-context (re-run c2-typography-extract.sh)", ""
        return "N/A", "font row without preset", ""

    # ── fill (gradient / image background) — Plan §1.3 adds nodeIdHint-based
    # stop-by-stop comparison via c2-fills-stops.json when available.
    if kind == "fill":
        gradient_kind = (value.get("preset") or "").lower()
        # When `// Figma: <nodeId>` comment exists, prefer exact lookup
        # against c2-fills-stops.json (per-node stop array). Otherwise fall
        # back to global presence check (legacy behavior).
        hint = (row.get("claim") or {}).get("nodeIdHint")
        per_node = (fills_stops_index.get("byNodeId") or {})

        if hint and per_node and gradient_kind in {"lineargradient", "radialgradient", "angulargradient", "ellipticalgradient"}:
            entry_fills = per_node.get(hint) or []
            gradient_entries = [
                e for e in entry_fills
                if str(e.get("type", "")).startswith("GRADIENT")
            ]
            if not gradient_entries:
                # Check for type mismatch: code says gradient, Figma says solid
                solid_entries = [e for e in entry_fills if e.get("type") == "SOLID"]
                if solid_entries:
                    sh = solid_entries[0].get("hex")
                    return "FAIL", f".background({gradient_kind}) but Figma nodeId {hint} is SOLID ({sh}) — wrong fill type", ""
                return "FAIL", f".background({gradient_kind}) but Figma nodeId {hint} has no GRADIENT fill in fills.json", ""
            # We have at least one gradient — compare top one
            stops = gradient_entries[0].get("stops") or []
            # For now, surface the stop list in the PASS reason — Pass 2 visual
            # diff verifies the precise rendering. Future enhancement: parse
            # the Swift `LinearGradient(stops:)` literal and compare per-stop.
            stop_summary = ",".join(f"{s['hex']}@{s['pos']:.2f}" for s in stops[:4])
            extra = f" (+{len(stops)-4} more)" if len(stops) > 4 else ""
            return "PASS", f"fills-stops nodeId {hint} has {len(stops)}-stop gradient: [{stop_summary}{extra}]", ""

        # Legacy global-presence path (no nodeIdHint or no fills-stops index)
        fills_nodes = (fills.get("nodes") or [])
        has_gradient = False
        has_image = False
        for n in fills_nodes:
            for f_ in (n.get("fills") or []):
                f_type = (f_.get("type") or f_.get("kind") or "").upper()
                if f_type.startswith("GRADIENT") or "GRADIENT" in f_type:
                    has_gradient = True
                if f_type == "IMAGE":
                    has_image = True
        if gradient_kind in {"lineargradient", "radialgradient", "angulargradient", "ellipticalgradient"}:
            if has_gradient:
                return "PASS", f"fills.json has GRADIENT fill ({gradient_kind}; add `// Figma: <nodeId>` for stop-level check)", ""
            else:
                return "FAIL", f".background({gradient_kind}) but fills.json has no GRADIENT node — gradient should come from Figma", ""
        if gradient_kind == "image":
            if has_image:
                return "PASS", "fills.json has IMAGE fill (matched)", ""
            else:
                return "FAIL", ".background(Image(...)) but fills.json has no IMAGE fill", ""
        return "N/A", f"fill kind '{gradient_kind}' — L3 visual review", ""

    # ── safearea — actual enforcement happens in c3-safearea-gate.sh which
    # cross-references the row's target/edges against inventory.CONTAINER
    # (mockupChrome, stickyBottom, frame device class). L2 just emits N/A to
    # avoid double-counting the rule.
    if kind == "safearea":
        owner = row.get("ownerType") or ""
        target = value.get("target") or "?"
        edges = value.get("edges") or "?"
        return "N/A", f".{owner}(edges={edges}) on {target} — checked by c3-safearea-gate.sh", ""

    # ── text
    if kind == "text":
        if form == "literal":
            t = value.get("text") or ""
            if not t:
                return "N/A", "Text with empty literal", ""
            # Phase 2: normalized match (smart quotes / case / whitespace)
            if text_in_design_ctx(t):
                return "PASS", "text literal in design-context.md (normalized)", ""
            return "FAIL", f"Text literal {t!r} not in design-context.md — either typo or not from Figma", ""
        if form == "computed":
            return "PASS", "Text from Strings/dynamic source — caller-verified", ""

    return "N/A", f"{kind} row — no check", ""

# ── Suggestion helpers ───────────────────────────────────────────────────────

def suggest_color(name):
    if not token_colors: return ""
    # closest by edit distance
    from difflib import get_close_matches
    matches = get_close_matches(name, list(token_colors), n=1, cutoff=0.5)
    return f"Suggested: Color(.{matches[0]})" if matches else ""

def suggest_color_hex(hex_val):
    return f"Suggested: convert literal hex {hex_val} to a tokens.json swiftName, or add // Figma: <node-id>"

def suggest_asset(name):
    if not asset_names: return ""
    from difflib import get_close_matches
    matches = get_close_matches(name, list(asset_names), n=1, cutoff=0.5)
    return f"Suggested: Image(.{matches[0]})" if matches else "Suggested: re-run figma_export_assets_unified(autoDiscover: true)"

def suggest_padding(amt):
    if not spacing_values: return ""
    best = min(spacing_values, key=lambda sv: abs(sv[0] - amt))
    return f"Suggested: spacing#{best[1]}={best[0]}"

def suggest_font(name):
    if not token_fonts: return ""
    from difflib import get_close_matches
    matches = get_close_matches(name, list(token_fonts) + list(token_font_alts), n=1, cutoff=0.5)
    return f"Suggested: .font(.{matches[0]})" if matches else ""

# ── Traverse audit, build trace ──────────────────────────────────────────────

parser_mode = audit.get("parserMode", "unknown")
files = audit.get("files") or {}

trace_rows = []
fail_count = 0
pass_count = 0
na_count = 0

degraded_files = []
for file_rel, file_data in files.items():
    if file_data.get("unknownModifierCount", 0) > 3:
        degraded_files.append((file_rel, file_data["unknownModifierCount"]))
    if (file_data.get("unknownNodeTypes") or []):
        degraded_files.append((file_rel, "unknown node types: " + ",".join(file_data["unknownNodeTypes"])))

    for r in file_data.get("rows", []):
        verdict, reason, suggestion = trace_row(r, file_rel)
        trace_rows.append({
            "file": file_rel,
            "line": r.get("line"),
            "kind": r.get("kind"),
            "owner": r.get("ownerType"),
            "literal": r.get("literal"),
            "verdict": verdict,
            "reason": reason,
            "suggestion": suggestion,
        })
        if verdict == "FAIL":   fail_count += 1
        elif verdict == "PASS": pass_count += 1
        else:                   na_count += 1

# ── Gate decision ────────────────────────────────────────────────────────────

gate = "PASS"
gate_reasons = []

if parser_mode in {"missing", "regex-fallback"}:
    gate = "FAIL"
    gate_reasons.append(f"parserMode={parser_mode} (degraded — install/repair figma-audit binary)")

if degraded_files:
    gate = "FAIL"
    for f, why in degraded_files:
        gate_reasons.append(f"{f}: {why}")

if fail_count > 0:
    gate = "FAIL"
    gate_reasons.append(f"{fail_count} row(s) failed")

if manifest_failed_rows:
    gate = "FAIL"
    names = ", ".join(r["exportName"] for r in manifest_failed_rows[:5])
    more = f" (+{len(manifest_failed_rows)-5} more)" if len(manifest_failed_rows) > 5 else ""
    gate_reasons.append(
        f"manifest.json has {len(manifest_failed_rows)} non-done row(s): {names}{more} "
        "— re-run figma_export_assets_unified(autoDiscover: true)"
    )

# ── Emit trace.md ────────────────────────────────────────────────────────────

with open(trace_md, "w") as f:
    f.write("# C3 L2 Token Trace\n\n")
    f.write(f"- nodeId: `{audit.get('nodeId', '?')}`\n")
    f.write(f"- parserMode: `{parser_mode}`\n")
    f.write(f"- generatedAt: `{audit.get('generatedAt', '?')}`\n")
    f.write(f"- tolerance: `{tolerance}` (frame/padding/spacing ±{TOL['frame']}pt)\n\n")
    f.write(f"## Summary\n\n| PASS | FAIL | N/A | TOTAL |\n|---|---|---|---|\n")
    f.write(f"| {pass_count} | {fail_count} | {na_count} | {pass_count + fail_count + na_count} |\n\n")
    f.write(f"## Findings\n\n")
    f.write("| # | File:Line | Kind | Owner | Literal | Verdict | Source / Reason |\n")
    f.write("|---|---|---|---|---|---|---|\n")
    for i, t in enumerate(trace_rows, 1):
        lit = (t["literal"] or "").replace("|", "\\|").replace("\n", " ")
        if len(lit) > 60:
            lit = lit[:57] + "…"
        f.write(f"| {i} | {t['file']}:{t['line']} | {t['kind']} | {t['owner']} | `{lit}` | **{t['verdict']}** | {t['reason']}")
        if t["suggestion"]:
            f.write(f"<br/>↳ {t['suggestion']}")
        f.write(" |\n")
    f.write("\n")
    if gate_reasons:
        f.write("## Gate failures\n\n")
        for r in gate_reasons:
            f.write(f"- {r}\n")
        f.write("\n")
    f.write(f"GATE: {gate}\n")

# ── Emit trace.json ──────────────────────────────────────────────────────────

with open(trace_json, "w") as f:
    json.dump({
        "nodeId": audit.get("nodeId"),
        "gate": gate,
        "gateReasons": gate_reasons,
        "parserMode": parser_mode,
        "tolerance": tolerance,
        "summary": {"pass": pass_count, "fail": fail_count, "na": na_count, "total": pass_count + fail_count + na_count},
        "rows": trace_rows,
    }, f, indent=2, sort_keys=True)
    f.write("\n")

print(f"GATE: {gate}  (pass={pass_count}, fail={fail_count}, na={na_count})")
if gate_reasons:
    for r in gate_reasons:
        print(f"  - {r}")
sys.exit(0 if gate == "PASS" else 1)
PY
RC=$?
exit $RC
