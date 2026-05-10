#!/usr/bin/env bash
# b0b-tokens-fallback.sh — build tokens.json from design-context.md style
# notes when figma_extract_tokens(fileKey) returns "forbidden" (PAT scope
# issue) or otherwise fails.
#
# Use case: skill agent calls figma_extract_tokens, gets error. Falls back
# here. This script walks every .figma-cache/<nodeId>/design-context.md,
# parses the inline style notes section, and builds a tokens.json equivalent
# that downstream b0b-tokens-codegen.sh can consume.
#
# Inline style note format (from figma-desktop MCP get_design_context):
#   These styles are contained in the design:
#     Light/Text/900: #1A1A1A,
#     Light/Text/300: #B3B3B3,
#     Primary/100: #ECF2FF,
#     Heading 4 24px: Font(family: "SF Pro Rounded", style: Bold, size: 24,
#                          weight: 700, lineHeight: 1.3, letterSpacing: 0),
#     Body Normal 16px/Regular: Font(family: ..., style: Regular, size: 16,
#                                    weight: 400, lineHeight: 1.7, ...)
#
# Output: tokens.json shape matches what figma_extract_tokens would return
# (colors[], typography[], spacing[]) so b0b-tokens-codegen.sh consumes it
# without modification.
#
# Usage:
#   b0b-tokens-fallback.sh --cache-root <.figma-cache/> [--output <path>]
#
# Default --output: <cache-root>/_shared/tokens.json
#
# Exit codes:
#   0 — tokens.json written (may be empty if no style notes found)
#   64 — bad usage
#   65 — cache root missing OR no design-context.md files found

set -uo pipefail

CACHE_ROOT=""
OUTPUT=""

print_usage() {
  cat <<'USAGE' >&2
usage: b0b-tokens-fallback.sh --cache-root <.figma-cache/> [--output <path>]

Builds tokens.json by parsing inline style notes from every screen's
design-context.md. Use when figma_extract_tokens fails (forbidden,
network error, PAT scope issue).

Default --output: <cache-root>/_shared/tokens.json
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache-root) CACHE_ROOT="${2:-}"; shift 2 ;;
    --output)     OUTPUT="${2:-}"; shift 2 ;;
    -h|--help)    print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE_ROOT" ] || { print_usage; exit 64; }
[ -d "$CACHE_ROOT" ] || { echo "FAIL: cache-root not a directory: $CACHE_ROOT" >&2; exit 65; }
[ -z "$OUTPUT" ] && OUTPUT="$CACHE_ROOT/_shared/tokens.json"
mkdir -p "$(dirname "$OUTPUT")"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 65; }

# ── Walk every design-context.md, extract style notes ───────────────────────
python3 - "$CACHE_ROOT" "$OUTPUT" <<'PY'
# encoding: utf-8
import json, os, re, sys
from datetime import datetime, timezone

cache_root, output = sys.argv[1], sys.argv[2]

# Collect every design-context.md (one per screen). Skip _shared/ symlinks.
contexts = []
for entry in sorted(os.listdir(cache_root)):
    full = os.path.join(cache_root, entry)
    if not os.path.isdir(full) or entry == "_shared":
        continue
    dctx = os.path.join(full, "design-context.md")
    if os.path.isfile(dctx):
        try:
            contexts.append(open(dctx, errors="replace").read())
        except OSError:
            pass

if not contexts:
    print("WARN: no design-context.md found under " + cache_root, file=sys.stderr)
    json.dump({"colors": [], "typography": [], "spacing": [], "_note": "fallback parser found 0 design-context.md"}, open(output, "w"), indent=2)
    sys.exit(0)

# Match style note line. Two flavors:
#   "These styles are contained in the design: <list>"   (figma-desktop output)
#   "## Colors" / "## Typography" headed sections        (design-context.md sections)
# The inline form is the most common; parse it.
all_text = "\n\n".join(contexts)

# Extract "These styles are contained..." paragraphs (may span multi-line).
style_pattern = re.compile(
    r"These styles are contained in the design:\s*(.+?)(?=\n\n|\nIMPORTANT|\Z)",
    re.DOTALL,
)
style_blobs = style_pattern.findall(all_text)

# Build colors + typography dictionaries (dedupe by name).
colors = {}      # name -> {swiftName, lightHex, figmaName}
typography = {}  # name -> {swiftName, fontFamily, fontWeight, fontSize, lineHeight, letterSpacing, ...}

# Color name normalization: "Light/Text/900" -> swiftName "text900"
def color_swift_name(figma_name):
    # Strip Light/ prefix; replace / with empty; lowercase first char.
    n = figma_name
    n = re.sub(r"^Light/", "", n)
    n = re.sub(r"^Dark/", "", n)
    n = n.replace("/", "")
    # PascalCase to camelCase: "Text900" -> "text900"
    if n and n[0].isupper():
        n = n[0].lower() + n[1:]
    n = re.sub(r"[^A-Za-z0-9]", "", n)
    return n

# Typography name normalization: "Heading 4 24px" -> swiftName "heading424px"
def typo_swift_name(figma_name):
    n = figma_name
    # Strip "/Regular" / "/Semibold" suffix variants
    n = re.sub(r"/[A-Za-z]+$", "", n)
    n = n.replace(" ", "").replace("/", "")
    n = re.sub(r"[^A-Za-z0-9]", "", n)
    if n and n[0].isupper():
        n = n[0].lower() + n[1:]
    return n

# Color regex: "Light/Text/900: #1A1A1A" or "Primary/Main Color: #3377FF"
COLOR_RE = re.compile(r"([A-Za-z][A-Za-z0-9 /]+):\s*(#[0-9A-Fa-f]{6,8})")

# Typography regex: "Heading 4 24px: Font(family: \"<font>\", style: <s>, size: <n>, weight: <w>, lineHeight: <h>, letterSpacing: <l>)"
TYPO_RE = re.compile(
    r"([A-Za-z][A-Za-z0-9 /]+):\s*Font\(\s*"
    r'family:\s*"([^"]+)",\s*'
    r"style:\s*([A-Za-z]+),\s*"
    r"size:\s*([0-9.]+),\s*"
    r"weight:\s*([0-9]+),\s*"
    r"lineHeight:\s*([0-9.]+),\s*"
    r"letterSpacing:\s*([0-9.]+)\s*\)"
)

for blob in style_blobs:
    # Typography first (Font() pattern is more specific).
    for m in TYPO_RE.finditer(blob):
        name, family, style, size, weight, lh, tracking = m.groups()
        sn = typo_swift_name(name)
        if sn in typography:
            continue
        typography[sn] = {
            "name": name.strip(),
            "swiftName": sn,
            "fontFamily": family,
            "fontWeight": int(weight),
            "fontSize": float(size),
            "lineHeight": float(lh),
            "letterSpacing": float(tracking),
            "italic": "italic" in style.lower(),
        }

    # Colors — but exclude lines that are inside Font(...) parens (already matched).
    # Strip Font(...) substrings from the blob first to avoid false matches.
    blob_no_fonts = re.sub(r"Font\([^)]+\)", "", blob)
    for m in COLOR_RE.finditer(blob_no_fonts):
        name, hex_val = m.groups()
        # Skip names that contain digits AND look typographic ("Heading 4 24px").
        if re.search(r"\d+px", name):
            continue
        # Skip system color references like "system/blue" / "var(--system\\/blue,#007aff)".
        if "system/" in name.lower() or "system\\" in name.lower() or "label\\" in name.lower():
            continue
        sn = color_swift_name(name)
        if not sn or sn in colors:
            continue
        colors[sn] = {
            "name": name.strip(),
            "swiftName": sn,
            "lightHex": hex_val.upper(),
            "darkHex": None,  # Not detectable from inline style notes
            "figmaName": name.strip(),
        }

# ── Spacing — heuristic; design-context inline notes don't include spacing tokens.
# Set to empty; user can override after run.
spacing = []

result = {
    "_generatedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "_source": "b0b-tokens-fallback.sh — parsed from design-context.md inline style notes",
    "_note": (
        "Fallback tokens — figma_extract_tokens may have failed (forbidden/network). "
        "Light-only colors (no darkHex). Spacing not extractable from inline notes."
    ),
    "colors": list(colors.values()),
    "typography": list(typography.values()),
    "spacing": spacing,
}

with open(output, "w") as f:
    json.dump(result, f, indent=2, ensure_ascii=False)

print(f"WROTE: {output}")
print(f"  colors: {len(colors)}")
print(f"  typography: {len(typography)}")
print(f"  spacing: 0 (not extractable from inline style notes)")
PY
