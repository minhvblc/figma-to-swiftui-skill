#!/usr/bin/env bash
# c1-project-color-audit.sh — scan a Swift project for existing color tokens
# and emit a hex→swiftPath map for C1.
#
# Goal: when a Figma color hex matches an existing project color, C2 should
# route through the existing token (e.g. IKCoreApp.colors.brandPrimary or
# Color("Colors/textPrimary")) instead of inventing a new one. Without this
# audit the agent eyeballs the project, misses matches, and emits parallel
# tokens that drift over time.
#
# Sources scanned:
#   1. Asset Catalog colorsets (*.colorset/Contents.json) — most reliable
#   2. Color extensions: `static let <name> = Color(...)` in Color+*.swift
#   3. IKCoreApp / theme color declarations (any file matching *Color*.swift,
#      *Theme*.swift, IKCoreApp*.swift)
#
# Output JSON shape:
#   {
#     "scannedAt": "<iso>",
#     "projectRoot": "<abs path>",
#     "colors": [
#       {
#         "hex": "#FF0080",
#         "swiftPath": "Color(\"Colors/primary500\")",
#         "source": "MyApp/Assets.xcassets/Colors/primary500.colorset",
#         "lightHex": "#FF0080",
#         "darkHex": "#E60074"      // null if light-only
#       },
#       ...
#     ]
#   }
#
# Usage:
#   c1-project-color-audit.sh <project-root> [<output-path>]
#   default output: .figma-cache/_shared/project-colors.json

set -uo pipefail

PROJECT_ROOT="${1:-}"
OUTPUT="${2:-.figma-cache/_shared/project-colors.json}"

if [ -z "$PROJECT_ROOT" ]; then
  echo "usage: $0 <project-root> [<output-path>]" >&2
  exit 64
fi

[ -d "$PROJECT_ROOT" ] || { echo "FAIL: $PROJECT_ROOT is not a directory" >&2; exit 65; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 65; }

mkdir -p "$(dirname "$OUTPUT")"

python3 - "$PROJECT_ROOT" "$OUTPUT" <<'PY'
import json, os, re, sys
from datetime import datetime, timezone

project_root, output = sys.argv[1], sys.argv[2]
project_root = os.path.abspath(project_root)

SKIP_DIR_NAMES = {".figma-cache", ".build", "DerivedData", "Pods", ".git",
                  "node_modules", "Carthage", ".swiftpm"}

results = []

# --- 1. Asset Catalog colorsets --------------------------------------------
def parse_colorset(path):
    try:
        with open(path) as f:
            doc = json.load(f)
    except Exception:
        return None
    light, dark = None, None
    for entry in doc.get("colors", []):
        comps = (entry.get("color") or {}).get("components") or {}
        if not comps:
            continue
        # components: { "alpha": "...", "red": "0xFF" | "1.000" | "255", ... }
        def to_int(v):
            v = (v or "").strip()
            if v.startswith("0x") or v.startswith("0X"):
                return int(v, 16)
            if "." in v:  # 0..1 normalized
                return round(float(v) * 255)
            try:
                return int(v)
            except ValueError:
                return None
        r = to_int(comps.get("red"))
        g = to_int(comps.get("green"))
        b = to_int(comps.get("blue"))
        a_raw = (comps.get("alpha") or "").strip()
        try:
            a = round(float(a_raw) * 255) if a_raw else 255
        except ValueError:
            a = 255
        if None in (r, g, b):
            continue
        hex_str = f"#{r:02X}{g:02X}{b:02X}" + (f"{a:02X}" if a != 255 else "")
        appearances = entry.get("appearances") or []
        is_dark = any((a.get("appearance") == "luminosity" and a.get("value") == "dark")
                      for a in appearances)
        if is_dark:
            dark = hex_str
        else:
            light = hex_str
    return light, dark

def colorset_swift_name(catalog_path):
    # Walk up to the namespaced group, if any. The Swift name used at runtime
    # is the *path* below Assets.xcassets when any ancestor folder has
    # provides-namespace=true; otherwise it's the bare colorset basename.
    name = os.path.basename(catalog_path).removesuffix(".colorset")
    parts = [name]
    cur = os.path.dirname(catalog_path)
    while cur and not cur.endswith(".xcassets"):
        meta = os.path.join(cur, "Contents.json")
        ns = False
        if os.path.isfile(meta):
            try:
                with open(meta) as f:
                    d = json.load(f)
                ns = (d.get("properties") or {}).get("provides-namespace") is True
            except Exception:
                ns = False
        if ns:
            parts.insert(0, os.path.basename(cur))
            cur = os.path.dirname(cur)
        else:
            break
    return "/".join(parts)

for dirpath, dirnames, filenames in os.walk(project_root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
    if dirpath.endswith(".colorset"):
        out = parse_colorset(os.path.join(dirpath, "Contents.json"))
        if not out:
            continue
        light, dark = out
        if not light:
            continue
        name = colorset_swift_name(dirpath)
        rel = os.path.relpath(dirpath, project_root)
        results.append({
            "hex":       light,
            "swiftPath": f'Color("{name}")',
            "source":    rel,
            "lightHex":  light,
            "darkHex":   dark,
        })
        # For dual-mode entries, also index by darkHex so a Figma dark hex
        # match still maps to the same Color("name") (Xcode auto-adapts).
        if dark and dark != light:
            results.append({
                "hex":       dark,
                "swiftPath": f'Color("{name}")',
                "source":    rel + " (dark appearance)",
                "lightHex":  light,
                "darkHex":   dark,
            })

# --- 2. Swift `Color(red:green:blue)` and `Color(hex:)` literals -----------
SWIFT_PATTERNS = [
    # Color(red: 0xFF/255, green: 0x00/255, blue: 0x80/255[, opacity: …])
    re.compile(
        r'Color\(\s*red:\s*0[xX]([0-9A-Fa-f]{2})\s*/\s*255\s*,'
        r'\s*green:\s*0[xX]([0-9A-Fa-f]{2})\s*/\s*255\s*,'
        r'\s*blue:\s*0[xX]([0-9A-Fa-f]{2})\s*/\s*255'
        r'(?:\s*,\s*opacity:\s*([0-9.]+))?\s*\)'
    ),
    # Color(red: 1.0, green: 0.0, blue: 0.5)
    re.compile(
        r'Color\(\s*red:\s*([0-9.]+)\s*,'
        r'\s*green:\s*([0-9.]+)\s*,'
        r'\s*blue:\s*([0-9.]+)'
        r'(?:\s*,\s*opacity:\s*([0-9.]+))?\s*\)'
    ),
    # Color(hex: "#RRGGBB" | "RRGGBB" | "#RRGGBBAA")
    re.compile(r'Color\(\s*hex:\s*"#?([0-9A-Fa-f]{6}|[0-9A-Fa-f]{8})"\s*\)'),
]

# Capture: `static let <name> = ...` on the same line so we can produce a
# stable swiftPath when the literal is in a Color extension.
EXT_DECL = re.compile(r'\bstatic\s+(?:let|var)\s+(\w+)\s*[:=]')

def hex_from_floats(r, g, b, a=None):
    try:
        rv, gv, bv = float(r), float(g), float(b)
    except ValueError:
        return None
    rb, gb, bb = round(rv*255), round(gv*255), round(bv*255)
    if not all(0 <= v <= 255 for v in (rb, gb, bb)):
        return None
    s = f"#{rb:02X}{gb:02X}{bb:02X}"
    if a is not None:
        try:
            ab = round(float(a)*255)
            if ab != 255:
                s += f"{ab:02X}"
        except ValueError:
            pass
    return s

for dirpath, dirnames, filenames in os.walk(project_root):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIR_NAMES]
    for fn in filenames:
        if not fn.endswith(".swift"):
            continue
        full = os.path.join(dirpath, fn)
        try:
            with open(full, errors="replace") as f:
                lines = f.readlines()
        except Exception:
            continue
        for lineno, line in enumerate(lines, 1):
            decl = EXT_DECL.search(line)
            decl_name = decl.group(1) if decl else None
            for idx, pat in enumerate(SWIFT_PATTERNS):
                for m in pat.finditer(line):
                    hex_str = None
                    if idx == 0:
                        r, g, b = (int(x, 16) for x in m.group(1, 2, 3))
                        a = m.group(4)
                        hex_str = f"#{r:02X}{g:02X}{b:02X}"
                        if a:
                            try:
                                ab = round(float(a)*255)
                                if ab != 255:
                                    hex_str += f"{ab:02X}"
                            except ValueError:
                                pass
                    elif idx == 1:
                        hex_str = hex_from_floats(*m.group(1, 2, 3, 4))
                    elif idx == 2:
                        h = m.group(1).upper()
                        hex_str = "#" + h
                    if not hex_str:
                        continue
                    rel = os.path.relpath(full, project_root)
                    swift_path = f"Color.{decl_name}" if decl_name else m.group(0)
                    results.append({
                        "hex":       hex_str,
                        "swiftPath": swift_path,
                        "source":    f"{rel}:{lineno}",
                        "lightHex":  hex_str,
                        "darkHex":   None,
                    })

# --- Dedup on (hex, swiftPath) keeping first occurrence --------------------
seen = set()
deduped = []
for r in results:
    key = (r["hex"].upper(), r["swiftPath"])
    if key in seen:
        continue
    seen.add(key)
    r["hex"] = r["hex"].upper()
    if r["lightHex"]:
        r["lightHex"] = r["lightHex"].upper()
    if r["darkHex"]:
        r["darkHex"] = r["darkHex"].upper()
    deduped.append(r)

doc = {
    "scannedAt":   datetime.now(timezone.utc).isoformat(),
    "projectRoot": project_root,
    "colors":      sorted(deduped, key=lambda r: r["hex"]),
}

with open(output, "w") as f:
    json.dump(doc, f, indent=2)
    f.write("\n")

print(f"WROTE: {output}")
print(f"  {len(deduped)} entries from {project_root}")
PY
