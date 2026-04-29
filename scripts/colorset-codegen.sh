#!/usr/bin/env bash
# colorset-codegen.sh — emit Asset Catalog colorsets for every Figma color
# token that has BOTH lightHex and darkHex.
#
# For light-only tokens (darkHex == null), this script does nothing — those
# stay as Color extensions in DesignSystem/Color+Tokens.swift.
#
# Why: tokens.json (figma_extract_tokens) already returns the dark-mode hex.
# The default B0b path emits a single-hex Color extension and silently loses
# dark-mode fidelity. Pushing dual-mode tokens through Asset Catalog lets
# Xcode handle the appearance switch — Color("name") adapts automatically.
#
# Usage:
#   colorset-codegen.sh <tokens.json> <Assets.xcassets> [<group=Colors>]
#
# Exit codes:
#   0 — success (or nothing to emit because no darkHex tokens exist)
#   64 — bad usage
#   65 — input not found / not parsable

set -uo pipefail

TOKENS="${1:-}"
XCASSETS="${2:-}"
GROUP="${3:-Colors}"

if [ -z "$TOKENS" ] || [ -z "$XCASSETS" ]; then
  echo "usage: $0 <tokens.json> <Assets.xcassets> [<group=Colors>]" >&2
  exit 64
fi

[ -s "$TOKENS" ] || { echo "FAIL: $TOKENS missing or empty" >&2; exit 65; }
[ -d "$XCASSETS" ] || { echo "FAIL: $XCASSETS is not a directory" >&2; exit 65; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 65; }

GROUP_DIR="$XCASSETS/$GROUP"
mkdir -p "$GROUP_DIR"

# Group-level Contents.json (provides-namespace so Color("Colors/foo") resolves)
GROUP_META="$GROUP_DIR/Contents.json"
if [ ! -f "$GROUP_META" ]; then
  cat > "$GROUP_META" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "provides-namespace" : true
  }
}
EOF
fi

# Hand off to python3 for JSON emit + hex parsing — bash arithmetic on hex
# alphas is fragile across awk/printf variants, and Asset Catalog rejects
# malformed JSON quietly.
python3 - "$TOKENS" "$GROUP_DIR" "$GROUP" <<'PY'
import json, os, sys

tokens_path, group_dir, group_name = sys.argv[1], sys.argv[2], sys.argv[3]

with open(tokens_path) as f:
    tokens = json.load(f)

def parse_hex(h):
    h = h.lstrip("#")
    if len(h) not in (6, 8):
        raise ValueError(f"unsupported hex length: #{h}")
    r = int(h[0:2], 16)
    g = int(h[2:4], 16)
    b = int(h[4:6], 16)
    a = int(h[6:8], 16) if len(h) == 8 else 255
    return r, g, b, a

def color_entry(hex_str, dark=False):
    r, g, b, a = parse_hex(hex_str)
    entry = {
        "idiom": "universal",
        "color": {
            "color-space": "srgb",
            "components": {
                "alpha": f"{a/255:.3f}",
                "red":   f"0x{r:02X}",
                "green": f"0x{g:02X}",
                "blue":  f"0x{b:02X}",
            },
        },
    }
    if dark:
        entry["appearances"] = [{"appearance": "luminosity", "value": "dark"}]
    return entry

emitted = 0
skipped = 0
for c in (tokens.get("colors") or []):
    swift_name = c.get("swiftName") or ""
    figma_name = c.get("figmaName") or ""
    light = c.get("lightHex")
    dark  = c.get("darkHex")
    if not (swift_name and light and dark):
        skipped += 1
        continue
    try:
        contents = {
            "info": {
                "author": "claude-code-figma-to-swiftui",
                "version": 1,
            },
            "colors": [
                color_entry(light, dark=False),
                color_entry(dark,  dark=True),
            ],
        }
    except ValueError as e:
        print(f"SKIP {swift_name}: {e}", file=sys.stderr)
        skipped += 1
        continue
    cs_dir = os.path.join(group_dir, f"{swift_name}.colorset")
    os.makedirs(cs_dir, exist_ok=True)
    with open(os.path.join(cs_dir, "Contents.json"), "w") as f:
        json.dump(contents, f, indent=2)
        f.write("\n")
    emitted += 1
    print(f"  + {group_name}/{swift_name}.colorset (Figma: {figma_name})")

print(f"EMITTED: {emitted} colorset(s) under {group_dir} (skipped: {skipped})")
print(f'USE: Color("{group_name}/<swiftName>")  // auto-adapts to light/dark')
PY
