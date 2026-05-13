#!/usr/bin/env bash
# c3-safearea-gate.sh — flag SwiftUI safe-area + nav-bar visibility misuse.
#
# Reads `.figma-cache/<nodeId>/c2-audit.json` (emitted by L1 PostToolUse hook)
# and cross-references every `kind: "safearea"` / `kind: "navbar"` row +
# `kind: "stack"` row with ownerType ∈ {NavigationStack, NavigationView}
# against placement rules from layout-translation.md, anti-patterns.md §AP-16
# (safe-area), and §AP-17 (nav-bar visibility).
#
# Violations detected:
#
#   SA-1 (FAIL): `.ignoresSafeArea(...)` applied to a CONTENT target
#                (VStack / HStack / ZStack / LazyVStack / ScrollView / List
#                / Form). Only visual background primitives may extend
#                under system chrome — content layers must respect the safe
#                area. Move .ignoresSafeArea to the background sibling.
#
#   SA-2 (FAIL): Root frame uses `.frame(maxHeight: .infinity)` without
#                any `.ignoresSafeArea` row in the same file — content will
#                bleed under status bar / home indicator on real devices.
#                (Heuristic — agent may have a legit reason; bypass with
#                `// allow-fullbleed-noinset: <reason>` on the .frame line.)
#
#   SA-3 (WARN): `.safeAreaInset(edge: ...)` with a target that doesn't
#                look like a screen-root container (e.g. inside a sub-view).
#                Bottom CTAs MUST attach to the screen root, not a child.
#
#   NB-1 (FAIL when *Screen.swift, WARN elsewhere): file uses NavigationStack
#                / NavigationView but has zero nav-bar visibility modifiers
#                (no .toolbar(.hidden, for: .navigationBar), no
#                .navigationTitle, no .navigationBarHidden, no
#                .toolbarVisibility). When the Figma frame uses a CUSTOM top
#                bar (the common pattern), the system nav bar adds ~44pt of
#                empty chrome above the content — exactly the "tràn ra ngoài
#                safe area" symptom user-reported. Bypass with comment
#                `// nav-bar-intentional: <reason>` on the NavigationStack
#                line when the design genuinely uses a system-style nav bar
#                with a title.
#
# Allowed background targets (any of these may carry .ignoresSafeArea
# without a flag): Color, Image, Rectangle, RoundedRectangle, Capsule,
# Ellipse, Circle, LinearGradient, RadialGradient, AngularGradient,
# EllipticalGradient, MeshGradient.
#
# Output:
#   .figma-cache/<nodeId>/c3-safearea.json  — machine-readable findings
#   stdout:                                  — human summary + `GATE: PASS|FAIL`
#
# Usage:
#   c3-safearea-gate.sh --cache <.figma-cache/nodeId>
#
# Exit:
#   0 — GATE: PASS  (or no safearea rows present)
#   1 — GATE: FAIL  (one or more SA-1 / SA-2 violations)
#  64 — bad usage

set -uo pipefail

CACHE=""
SRC_ROOT=""

print_usage() {
  cat <<'USAGE' >&2
usage: c3-safearea-gate.sh --cache <.figma-cache/nodeId> [--src-root <path>]

Cross-references c2-audit.json safearea rows against placement rules.
Flags .ignoresSafeArea on content containers (SA-1), full-bleed root
frames without inset handling (SA-2), and .safeAreaInset on non-root
targets (SA-3 warn). See anti-patterns.md §AP-16.

--src-root resolves audit's relative file paths to absolute paths so the
gate can read source lines and respect the `// safearea-target-confirmed:`
bypass comment. Without --src-root, ambiguous target rows escalate to FAIL
with no bypass option.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)    CACHE="${2:-}"; shift 2 ;;
    --src-root) SRC_ROOT="${2:-}"; shift 2 ;;
    -h|--help)  print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 64; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 64; }

AUDIT="$CACHE/c2-audit.json"
OUT="$CACHE/c3-safearea.json"

if [ ! -f "$AUDIT" ]; then
  # No audit emitted — skip cleanly (some flows like docs-only edits won't
  # produce one). Different from FAIL because there's nothing to check.
  echo "GATE: SKIP (c2-audit.json missing — L1 hook didn't fire)"
  exit 0
fi

python3 - "$AUDIT" "$OUT" "$SRC_ROOT" <<'PY'
import json, os, re, sys

audit_path, out_path, src_root = sys.argv[1], sys.argv[2], sys.argv[3]

with open(audit_path) as f:
    audit = json.load(f)

# Visual background primitives — these are the only targets allowed to carry
# .ignoresSafeArea(...). Everything else is content and must respect the
# safe area (Apple HIG, see layout-translation.md §"Safe Area Normalization").
BACKGROUND_TARGETS = {
    "Color", "Image",
    "Rectangle", "RoundedRectangle", "Capsule", "Ellipse", "Circle",
    "LinearGradient", "RadialGradient", "AngularGradient", "EllipticalGradient",
    "MeshGradient",
}

# Content containers — `.ignoresSafeArea` on these is the SA-1 bug we are
# trying to catch. ScrollView in particular is the highest-frequency offender.
CONTENT_CONTAINERS = {
    "VStack", "HStack", "ZStack", "LazyVStack", "LazyHStack", "Grid",
    "LazyVGrid", "LazyHGrid",
    "ScrollView", "List", "Form",
    "NavigationStack", "NavigationView", "NavigationSplitView",
    "TabView",
}

findings = []
violations = 0
warnings = 0

# Bypass comment marker for ambiguous SA-1 targets. Agent must explicitly
# confirm the `.ignoresSafeArea` target is a background primitive when the
# audit can't trace it from the chain. See anti-patterns.md §AP-16.
BYPASS_RE = re.compile(r"//\s*safearea-target-confirmed\s*:\s*\S")

# Per-file line cache so we don't re-read source on every safearea row.
_src_cache = {}
def source_lines(rel):
    """Return the file's line list, or None when --src-root not provided or
    file cannot be read. Cached per rel path."""
    if not src_root:
        return None
    if rel in _src_cache:
        return _src_cache[rel]
    abs_path = os.path.join(src_root, rel)
    try:
        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()
    except OSError:
        lines = None
    _src_cache[rel] = lines
    return lines

def has_target_bypass(rel, line):
    """True when the source line at line# carries `// safearea-target-confirmed: <X>`.
    Returns False when source isn't resolvable (no bypass possible → escalate)."""
    if not line:
        return False
    lines = source_lines(rel)
    if not lines:
        return False
    idx = int(line) - 1
    if idx < 0 or idx >= len(lines):
        return False
    return bool(BYPASS_RE.search(lines[idx]))

files = audit.get("files") or {}

for rel_path, file_data in files.items():
    rows = file_data.get("rows") or []
    safearea_rows = [r for r in rows if r.get("kind") == "safearea"]
    frame_rows    = [r for r in rows if r.get("kind") == "frame"]
    navbar_rows   = [r for r in rows if r.get("kind") == "navbar"]
    nav_stack_rows = [
        r for r in rows
        if r.get("kind") == "stack" and r.get("ownerType") in {"NavigationStack", "NavigationView"}
    ]

    # Build a quick lookup of safearea line numbers — used by SA-2 to see if
    # ANY safearea modifier exists in the file alongside the suspect frame.
    has_any_safearea = len(safearea_rows) > 0

    # SA-1: .ignoresSafeArea / .safeAreaPadding on content target ────────────
    for r in safearea_rows:
        owner = r.get("ownerType") or ""
        v = r.get("value") or {}
        target = v.get("target") or "?"
        edges = v.get("edges") or "?"
        line = r.get("line")

        if owner in {"ignoresSafeArea", "safeAreaPadding"}:
            if target in CONTENT_CONTAINERS:
                findings.append({
                    "code":   "SA-1",
                    "level":  "FAIL",
                    "file":   rel_path,
                    "line":   line,
                    "rule":   f".{owner} on content target",
                    "detail": f".{owner}({edges}) attached to {target} — only background primitives "
                              f"(Color/Image/Rectangle/RoundedRectangle/LinearGradient/...) "
                              f"may extend under system chrome; move to the background sibling.",
                })
                violations += 1
            elif target == "?" or target is None:
                # Cannot determine target from chain. Default FAIL — the
                # whole point of AP-16 is "STOP and confirm BEFORE acting,
                # not confess after". Agent can bypass with an inline
                # `// safearea-target-confirmed: <Color|Image|Gradient|...>`
                # comment on the same line when they verified manually.
                bypassed = has_target_bypass(rel_path, line)
                lvl = "WARN" if bypassed else "FAIL"
                findings.append({
                    "code":   "SA-1?",
                    "level":  lvl,
                    "file":   rel_path,
                    "line":   line,
                    "rule":   f".{owner} on unknown target",
                    "detail": f".{owner}({edges}) — could not determine target type from chain. "
                              f"Only visual background primitives (Color/Image/Rectangle/"
                              f"RoundedRectangle/LinearGradient/RadialGradient/...) may "
                              f"extend under system chrome. If this IS a background, add "
                              f"`// safearea-target-confirmed: <Color|Image|Gradient|...>` "
                              f"on this line. If it's a content container (ZStack/VStack/"
                              f"ScrollView), move the modifier to the background sibling "
                              f"inside the ZStack and let content respect the safe area.",
                })
                if lvl == "FAIL":
                    violations += 1
                else:
                    warnings += 1
            elif target in BACKGROUND_TARGETS:
                # Allowed — no finding
                pass
            else:
                # Custom view type or third-party — could be a wrapper around a
                # background primitive OR a content composite. Default FAIL so
                # the agent has to confirm with `safearea-target-confirmed:`.
                bypassed = has_target_bypass(rel_path, line)
                lvl = "WARN" if bypassed else "FAIL"
                findings.append({
                    "code":   "SA-1?",
                    "level":  lvl,
                    "file":   rel_path,
                    "line":   line,
                    "rule":   f".{owner} on non-standard target",
                    "detail": f".{owner}({edges}) on {target} — unrecognized as visual "
                              f"background. If this is a wrapper around a background "
                              f"primitive, add `// safearea-target-confirmed: <kind>` "
                              f"on this line. If it's a content composite, move the "
                              f"modifier off and onto a background sibling.",
                })
                if lvl == "FAIL":
                    violations += 1
                else:
                    warnings += 1

        # SA-3: safeAreaInset target sanity — must be a screen-root container.
        # We can't strictly verify "root" without inventory, but at minimum
        # the immediate target should be a container that CAN have a bottom
        # bar (ZStack / VStack / NavigationStack / ScrollView), not a leaf.
        if owner == "safeAreaInset":
            if target in BACKGROUND_TARGETS:
                findings.append({
                    "code":   "SA-3",
                    "level":  "WARN",
                    "file":   rel_path,
                    "line":   line,
                    "rule":   "safeAreaInset on background primitive",
                    "detail": f".safeAreaInset(edge={edges}) attached to {target} — typically "
                              f"belongs on a screen-root container (ZStack/VStack/NavigationStack).",
                })
                warnings += 1

    # SA-2: maxHeight: .infinity at root without any safearea handling ─────
    # Heuristic: if the file has a frame row with maxHeight=".infinity" but
    # zero safearea rows AND the frame is on the FIRST 20 lines of body
    # (likely root-level), flag it.
    for r in frame_rows:
        v = r.get("value") or {}
        maxh = v.get("maxHeight")
        line = r.get("line") or 0
        if maxh == ".infinity" and not has_any_safearea and line <= 40:
            findings.append({
                "code":   "SA-2",
                "level":  "FAIL",
                "file":   rel_path,
                "line":   line,
                "rule":   "fullbleed frame without safe-area handling",
                "detail": ".frame(maxHeight: .infinity) at screen root with no .ignoresSafeArea or "
                          ".safeAreaInset companion — content may bleed under status bar / home indicator. "
                          "Add background .ignoresSafeArea(edges: .top) OR safeAreaInset for bottom CTA, "
                          "OR add `// allow-fullbleed-noinset: <reason>` if intentional.",
            })
            violations += 1

    # NB-1: NavigationStack/View wraps content but file has zero nav-bar
    # visibility modifiers. Common failure mode: agent reaches for
    # NavigationStack out of habit, designer didn't ask for a nav bar, system
    # nav bar adds ~44pt of empty chrome → content overlaps with where the
    # Figma custom header sits → "tràn ra ngoài safe area".
    #
    # We flag the EARLIEST NavigationStack in the file (the root one). Inner
    # NavigationLink-pushed NavigationStacks are uncommon; if multiple exist,
    # one flag is enough to surface the file for review.
    if nav_stack_rows and not navbar_rows:
        # FAIL for *Screen.swift (single-screen pattern where custom top bar
        # in Figma is the strong default — user explicitly reported this
        # bug). WARN for *View.swift and other files (App.swift /
        # RouterView.swift / NavigationStack at app root legitimately has no
        # toolbar — child views own that).
        file_basename = rel_path.rsplit("/", 1)[-1]
        is_screen = file_basename.endswith("Screen.swift")
        level = "FAIL" if is_screen else "WARN"
        earliest = min(nav_stack_rows, key=lambda r: r.get("line") or 0)
        findings.append({
            "code":   "NB-1",
            "level":  level,
            "file":   rel_path,
            "line":   earliest.get("line"),
            "rule":   "NavigationStack without nav-bar visibility handling",
            "detail": "NavigationStack / NavigationView wraps content but the file has zero nav-bar "
                      "visibility modifiers (.toolbar(.hidden, for: .navigationBar), .navigationTitle, "
                      ".toolbarVisibility, .navigationBarHidden). The system nav bar adds ~44pt of "
                      "empty chrome above the content — this is the common cause of 'UI tràn ra "
                      "ngoài safe area' when Figma uses a custom top bar. "
                      "Fix: add `.toolbar(.hidden, for: .navigationBar)` to the root content view "
                      "when Figma shows a custom header (X / title / icon row at top); add "
                      "`.navigationTitle(\"…\")` when Figma's top zone matches iOS system nav bar. "
                      "Bypass: `// nav-bar-intentional: <reason>` comment on the NavigationStack line.",
        })
        if level == "FAIL":
            violations += 1
        else:
            warnings += 1

# ── Emit JSON + summary ─────────────────────────────────────────────────────

gate = "PASS" if violations == 0 else "FAIL"

result = {
    "schemaVersion": 1,
    "nodeId":   audit.get("nodeId"),
    "gate":     gate,
    "findings": findings,
    "summary":  {
        "violations": violations,
        "warnings":   warnings,
    },
}

tmp = out_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(result, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out_path)

# Human summary
if not findings:
    print(f"GATE: PASS  (no safe-area violations)")
else:
    print(f"GATE: {gate}  (violations={violations}, warnings={warnings})")
    for fnd in findings:
        lvl = fnd["level"]
        marker = "✗" if lvl == "FAIL" else "⚠"
        print(f"  {marker} [{fnd['code']}] {fnd['file']}:{fnd['line']} — {fnd['rule']}")
        print(f"      {fnd['detail']}")

sys.exit(0 if gate == "PASS" else 1)
PY
RC=$?
exit $RC
