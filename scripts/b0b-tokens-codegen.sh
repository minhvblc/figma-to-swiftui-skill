#!/usr/bin/env bash
# b0b-tokens-codegen.sh — emit DesignSystem token files from tokens.json.
#
# Replaces the manual B0b step in figma-to-swiftui/SKILL.md by writing all
# four artifacts in one call:
#
#   1. <Assets.xcassets>/Colors/<swiftName>.colorset/        — dual-mode tokens
#      (delegates to colorset-codegen.sh — single source of truth)
#   2. <out-dir>/Color+Tokens.swift                          — light-only colors
#   3. <out-dir>/AppFont.swift                               — typography tokens
#   4. <out-dir>/Spacing.swift                               — spacing + radius
#
# Skill rules preserved verbatim:
#   - Dual-mode tokens (lightHex AND darkHex) → Asset Catalog colorsets,
#     reference as Color(.<swiftName>) — iOS 17+ auto-generated ColorResource
#   - Light-only tokens (darkHex == null)     → Color extension, reference
#     as Color.<swiftName>
#   - radius with isCapsule:true              → Capsule() not RoundedRectangle
#   - typography: emit static func per token, plus *LineSpacing / *Tracking
#     constants. textAlignHorizontal NOT baked into the font helper.
#   - Spacing.swift: ONLY emit cases that exist in tokens.json — never
#     fabricate an 8pt grid.
#
# Usage:
#   b0b-tokens-codegen.sh
#       --tokens <path/to/tokens.json>
#       --xcassets <path/to/Assets.xcassets>
#       --out <project/DesignSystem/>
#       [--skip-colorset]   # reuse existing colorsets (testing only)
#
# Exit codes:
#   0 — all four artifacts written
#   64 — bad usage
#   65 — tokens.json missing / not parseable
#   1 — colorset-codegen.sh failed

set -uo pipefail

TOKENS=""
XCASSETS=""
OUTDIR=""
SKIP_COLORSET=0

print_usage() {
  cat <<'USAGE' >&2
usage: b0b-tokens-codegen.sh
       --tokens <path/to/tokens.json>
       --xcassets <path/to/Assets.xcassets>
       --out <project/DesignSystem/>
       [--skip-colorset]

Emits the four DesignSystem artifacts described in figma-to-swiftui/SKILL.md
Step B0b. Pure code generation — never reads the project's existing
DesignSystem files (overwrites them).

When --skip-colorset is passed, the colorset emission step is bypassed
(useful when the user wants to inspect Color+Tokens.swift / AppFont.swift /
Spacing.swift without touching the catalog).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --tokens)         TOKENS="${2:-}"; shift 2 ;;
    --xcassets)       XCASSETS="${2:-}"; shift 2 ;;
    --out)            OUTDIR="${2:-}"; shift 2 ;;
    --skip-colorset)  SKIP_COLORSET=1; shift ;;
    -h|--help)        print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$TOKENS"   ] || { print_usage; exit 64; }
[ -n "$XCASSETS" ] || [ "$SKIP_COLORSET" = "1" ] || { print_usage; exit 64; }
[ -n "$OUTDIR"   ] || { print_usage; exit 64; }
[ -s "$TOKENS"   ] || { echo "FAIL: tokens.json missing or empty: $TOKENS" >&2; exit 65; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 65; }

mkdir -p "$OUTDIR"

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_GRN=$(tput setaf 1); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_GRN=""; C_DIM=""; C_RST=""
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── 1. Colorset emission (delegates to colorset-codegen.sh) ──────────────
if [ "$SKIP_COLORSET" = "0" ]; then
  CS="$SCRIPT_DIR/colorset-codegen.sh"
  if [ ! -x "$CS" ]; then
    echo "FAIL: colorset-codegen.sh missing or not executable at $CS" >&2
    exit 1
  fi
  if ! "$CS" "$TOKENS" "$XCASSETS" "Colors"; then
    echo "FAIL: colorset-codegen.sh exited non-zero" >&2
    exit 1
  fi
fi

# ── 2/3/4. Color+Tokens.swift, AppFont.swift, Spacing.swift ─────────────
python3 - "$TOKENS" "$OUTDIR" <<'PY'
import json, os, re, sys

tokens_path, out_dir = sys.argv[1], sys.argv[2]

try:
    tokens = json.load(open(tokens_path))
except Exception as e:
    print(f"FAIL: cannot parse {tokens_path}: {e}", file=sys.stderr)
    sys.exit(65)

# Helpers ────────────────────────────────────────────────────────────────
def parse_hex(h):
    if not h: return None
    h = h.lstrip("#")
    if len(h) not in (6, 8): return None
    try:
        r = int(h[0:2], 16); g = int(h[2:4], 16); b = int(h[4:6], 16)
        a = int(h[6:8], 16) if len(h) == 8 else 255
        return r, g, b, a
    except ValueError:
        return None

def color_init(hex_str):
    rgba = parse_hex(hex_str)
    if rgba is None: return None
    r, g, b, a = rgba
    if a == 255:
        return f"Color(red: 0x{r:02X}/255, green: 0x{g:02X}/255, blue: 0x{b:02X}/255)"
    return (f"Color(red: 0x{r:02X}/255, green: 0x{g:02X}/255, "
            f"blue: 0x{b:02X}/255, opacity: {a/255:.3f})")

# ── 2. Color+Tokens.swift (light-only tokens) ────────────────────────────
light_only_lines = []
all_colors = tokens.get("colors") or []
for c in all_colors:
    sn = c.get("swiftName")
    if not sn:
        continue
    if c.get("darkHex"):
        # Dual-mode → handled by colorset-codegen.sh, skip here.
        continue
    init = color_init(c.get("lightHex"))
    if init is None:
        continue
    fig = c.get("figmaName") or sn
    light_only_lines.append(f"    /// Figma: {fig}")
    light_only_lines.append(f"    static let {sn} = {init}")
    light_only_lines.append("")

color_path = os.path.join(out_dir, "Color+Tokens.swift")
with open(color_path, "w") as f:
    f.write("// Auto-generated by b0b-tokens-codegen.sh — do not edit by hand.\n")
    f.write("// Source of truth: tokens.json (figma_extract_tokens). Light-only tokens\n")
    f.write("// only — dual-mode (light + dark) tokens are emitted as Asset Catalog\n")
    f.write("// colorsets via colorset-codegen.sh; reference those as Color(.<name>) — iOS 17+ auto-gen ColorResource.\n\n")
    f.write("import SwiftUI\n\n")
    f.write("extension Color {\n")
    if light_only_lines:
        f.write("\n".join(light_only_lines).rstrip() + "\n")
    else:
        f.write("    // (no light-only color tokens in tokens.json — all dual-mode entries\n")
        f.write("    //  live as Asset Catalog colorsets)\n")
    f.write("}\n")
print(f"WROTE: {color_path} ({sum(1 for l in light_only_lines if l.startswith('    static let'))} light-only color(s))")

# ── 3. AppFont.swift (typography tokens) ─────────────────────────────────
typography = tokens.get("typography") or []
font_blocks = []
const_blocks = []  # *LineSpacing, *Tracking constants
for t in typography:
    name = t.get("swiftName") or t.get("name")
    if not name:
        continue
    family = t.get("fontFamily") or ""
    weight = t.get("fontWeight") or ""
    ps_name = t.get("fontPostScriptName") or ""
    size = t.get("fontSize")
    line_h = t.get("lineHeightPx")
    tracking = t.get("letterSpacing")
    if size is None:
        continue
    fig_name = t.get("figmaName") or name
    family_disp = f"{family} {weight}".strip() or ps_name or "system"
    lh_disp = f" / lh {line_h}" if line_h else ""
    tk_disp = f" / tracking {tracking}" if tracking is not None else ""
    font_blocks.append(
        f"    /// Figma: {fig_name} — {family_disp} {size}{lh_disp}{tk_disp}\n"
        f"    static func {name}() -> Font {{\n"
        + (f'        Font.custom("{ps_name}", size: {size})\n' if ps_name
           else f'        Font.system(size: {size})\n')
        + "    }"
    )
    if line_h is not None and size is not None:
        try:
            ls = float(line_h) - float(size)
        except (ValueError, TypeError):
            ls = None
        if ls is not None:
            const_blocks.append(f"    static let {name}LineSpacing: CGFloat = {ls:g}")
    if tracking is not None:
        const_blocks.append(f"    static let {name}Tracking: CGFloat = {tracking:g}")

font_path = os.path.join(out_dir, "AppFont.swift")
with open(font_path, "w") as f:
    f.write("// Auto-generated by b0b-tokens-codegen.sh — do not edit by hand.\n")
    f.write("// Source of truth: tokens.json.typography[] (figma_extract_tokens 0.3.0+).\n")
    f.write("// Each font helper does NOT bake .multilineTextAlignment(...) — alignment\n")
    f.write("// lives at the call site (per-node textAlignHorizontal override).\n\n")
    f.write("import SwiftUI\n\n")
    f.write("enum AppFont {\n")
    if font_blocks:
        f.write("\n\n".join(font_blocks))
        f.write("\n")
        if const_blocks:
            f.write("\n")
            f.write("\n".join(const_blocks))
            f.write("\n")
    else:
        f.write("    // (no typography tokens in tokens.json — fall back to inline\n")
        f.write("    //  tokens parsed from design-context.md per references/design-token-mapping.md)\n")
    f.write("}\n")
print(f"WROTE: {font_path} ({len(font_blocks)} typography token(s))")

# ── 4. Spacing.swift (spacing + radius) ──────────────────────────────────
spacing_entries = tokens.get("spacing") or []
radius_entries  = tokens.get("radius") or []
opacity_entries = tokens.get("opacity") or []
spacing_lines = []
radius_lines = []
opacity_lines = []

for s in spacing_entries:
    sn = s.get("swiftName")
    val = s.get("value")
    if not sn or val is None: continue
    fig = s.get("figmaName") or sn
    spacing_lines.append(f"    /// Figma: {fig}")
    spacing_lines.append(f"    static let {sn}: CGFloat = {val:g}")
    spacing_lines.append("")

for r in radius_entries:
    sn = r.get("swiftName")
    val = r.get("value")
    if not sn or val is None: continue
    fig = r.get("figmaName") or sn
    is_capsule = bool(r.get("isCapsule"))
    radius_lines.append(f"    /// Figma: {fig}{' (capsule)' if is_capsule else ''}")
    if is_capsule:
        radius_lines.append(f"    /// Use Capsule() instead of RoundedRectangle(cornerRadius: {sn}) — "
                            f"isCapsule=true means width-independent pill shape.")
    radius_lines.append(f"    static let {sn}: CGFloat = {val:g}")
    radius_lines.append("")

for o in opacity_entries:
    sn = o.get("swiftName")
    val = o.get("value")
    if not sn or val is None: continue
    fig = o.get("figmaName") or sn
    opacity_lines.append(f"    /// Figma: {fig}")
    opacity_lines.append(f"    static let {sn}: Double = {val:g}")
    opacity_lines.append("")

spacing_path = os.path.join(out_dir, "Spacing.swift")
with open(spacing_path, "w") as f:
    f.write("// Auto-generated by b0b-tokens-codegen.sh — do not edit by hand.\n")
    f.write("// Source of truth: tokens.json (figma_extract_tokens).\n")
    f.write("// Only emits cases that actually appear in tokens.json — does NOT add\n")
    f.write("// a generic 8pt grid (xxs/xs/s/m/l/xl) unless those literal values\n")
    f.write("// exist in the source.\n\n")
    f.write("import CoreGraphics\n\n")
    f.write("enum Spacing {\n")
    if spacing_lines:
        f.write("\n".join(spacing_lines).rstrip() + "\n")
    else:
        f.write("    // (no spacing tokens in tokens.json — use design-context.md inline values)\n")
    f.write("}\n\n")
    f.write("enum CornerRadius {\n")
    if radius_lines:
        f.write("\n".join(radius_lines).rstrip() + "\n")
    else:
        f.write("    // (no radius tokens in tokens.json)\n")
    f.write("}\n")
    if opacity_lines:
        f.write("\n")
        f.write("enum Opacity {\n")
        f.write("\n".join(opacity_lines).rstrip() + "\n")
        f.write("}\n")

n_sp = sum(1 for l in spacing_lines if l.startswith("    static let"))
n_rd = sum(1 for l in radius_lines  if l.startswith("    static let"))
n_op = sum(1 for l in opacity_lines if l.startswith("    static let"))
print(f"WROTE: {spacing_path} ({n_sp} spacing, {n_rd} radius, {n_op} opacity)")
PY

echo "${C_GRN}DONE${C_RST}: B0b token codegen complete in $OUTDIR"
exit 0
