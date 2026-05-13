#!/usr/bin/env bash
# c3-fills-coverage.sh — verify every fills.json node with non-trivial fill
# has a corresponding visual emission in the generated SwiftUI source.
#
# Closes the Bug-1 gap: agent skips fills-handling.md Recipe 1/3 → screen
# ships without its Figma background image / gradient → silently passes
# every other gate (C6 only sees what IS referenced, never what is missing;
# L2 trace verifies emitted rows only, not the reverse direction).
#
# Rule recap (fills-handling.md): `fills.json.nodes[]` only contains nodes
# with NON-TRIVIAL fills (filter strips single SOLID 100% — those are covered
# by tokens.json). So every entry there is a paint stack that MUST be
# translated to a SwiftUI primitive — Image / LinearGradient / RadialGradient /
# AngularGradient / EllipticalGradient / MeshGradient, possibly stacked in a
# ZStack.
#
# Violations detected:
#
#   FC-1 (FAIL): fills.json has ≥1 node carrying an IMAGE fill (alone or
#                stacked) but ZERO `Image(.X)` / `Image("X")` constructors
#                across the generated source files. Recipe 1 / Recipe 3 was
#                skipped entirely.
#
#   FC-2 (FAIL): fills.json has ≥1 node carrying a GRADIENT_* fill (without
#                IMAGE) but ZERO LinearGradient / RadialGradient /
#                AngularGradient / EllipticalGradient / MeshGradient
#                constructors across the generated source files. Recipe 2
#                was skipped.
#
#   FC-3 (FAIL): fills.json has ≥1 node carrying STACKED [IMAGE, GRADIENT_*]
#                fills but the generated code emits image OR gradient — not
#                both. Recipe 3 was emitted only half-applied.
#
#   FC-4 (FAIL): fills.json declares an IMAGE fill on node X but
#                `manifest.rows[]` has NO `status=done` entry for that same
#                nodeId. Even if the agent tries to emit Image(.something),
#                the asset for THIS specific node was never exported by
#                figma_export_assets_unified. Upstream pipeline gap, not
#                an emit gap (FC-1 catches the emit side).
#
#   FC-4? (WARN): manifest.json missing — FC-4 can't run, surfaced so the
#                 agent knows to run `figma_export_assets_unified` first.
#
# Bypass: comment `// allow-no-bg-emit: <reason>` on the `var body` line (or
# any line) of any generated Swift file. The gate respects the bypass and
# downgrades the affected finding to WARN. Use this when the agent has a
# documented reason (e.g. design swapped a background image for a solid color
# at design-time but fills.json was not regenerated).
#
# Output:
#   .figma-cache/<nodeId>/c3-fills-coverage.json — machine-readable findings
#   stdout — human summary + GATE: PASS|FAIL|SKIP
#
# Usage:
#   c3-fills-coverage.sh --cache <.figma-cache/nodeId> [--src-root <abs path>]
#
# --src-root is the absolute path of the user's iOS project root, used to
# resolve audit file paths (which are relative) to absolute paths for source
# grepping. When omitted, the gate falls back to using audit row counts only
# (cannot detect gradient emission count, so FC-2 / FC-3 may under-report;
# FC-1 still works via `kind: "image"` audit rows).
#
# Exit:
#   0 — GATE: PASS (or no fills.json present)
#   1 — GATE: FAIL (one or more FC-1 / FC-2 / FC-3 violations)
#  64 — bad usage

set -uo pipefail

CACHE=""
SRC_ROOT=""

print_usage() {
  cat <<'USAGE' >&2
usage: c3-fills-coverage.sh --cache <.figma-cache/nodeId> [--src-root <path>]

Cross-references fills.json.nodes[] against generated source files. Flags
nodes with IMAGE / GRADIENT / stacked fills that have no corresponding
SwiftUI emission. Bypass: `// allow-no-bg-emit: <reason>` in any generated
source file.
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

FILLS="$CACHE/fills.json"
AUDIT="$CACHE/c2-audit.json"
OUT="$CACHE/c3-fills-coverage.json"

if [ ! -f "$FILLS" ]; then
  # Phase A Step 5 wasn't run, or the node had no non-trivial fills. Either
  # way there is nothing to check — emit SKIP cleanly.
  echo "GATE: SKIP (fills.json missing — no non-trivial fills extracted, or Phase A Step 5 not run)"
  exit 0
fi

python3 - "$FILLS" "$AUDIT" "$SRC_ROOT" "$OUT" <<'PY'
import json, os, re, sys

fills_path, audit_path, src_root, out_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    with open(fills_path) as f:
        fills = json.load(f)
except (FileNotFoundError, json.JSONDecodeError) as e:
    print(f"GATE: SKIP (fills.json unreadable: {e})")
    sys.exit(0)

nodes = fills.get("nodes") or []

if not nodes:
    # fills.json present but empty — no non-trivial fills in this screen.
    result = {
        "schemaVersion": 1,
        "nodeId": fills.get("rootNodeId"),
        "gate": "PASS",
        "findings": [],
        "summary": {"imageNodes": 0, "gradientNodes": 0, "stackedNodes": 0,
                    "imageEmissions": 0, "gradientEmissions": 0,
                    "violations": 0, "warnings": 0},
    }
    tmp = out_path + ".tmp." + str(os.getpid())
    with open(tmp, "w") as f:
        json.dump(result, f, indent=2, sort_keys=True)
        f.write("\n")
    os.replace(tmp, out_path)
    print("GATE: PASS  (fills.json has no non-trivial fill nodes — nothing to verify)")
    sys.exit(0)

# Classify nodes by fill composition. A node is in exactly one bucket.
# Stacked = has BOTH image and gradient. Image-only / gradient-only otherwise.
def fill_types(node):
    types = set()
    for fill in (node.get("fills") or []):
        if not fill.get("visible", True):
            continue
        t = (fill.get("type") or "").upper()
        if t == "IMAGE":
            types.add("image")
        elif t == "GRADIENT" or t.startswith("GRADIENT_"):
            # MCPFigma normalizes to lowercase "gradient" with a "kind" field;
            # some upstream paths still emit GRADIENT_LINEAR etc. Accept both.
            types.add("gradient")
    return types

image_nodes    = []  # IMAGE only
gradient_nodes = []  # GRADIENT only
stacked_nodes  = []  # IMAGE + GRADIENT

for n in nodes:
    types = fill_types(n)
    has_image    = "image"    in types
    has_gradient = "gradient" in types
    if has_image and has_gradient:
        stacked_nodes.append(n)
    elif has_image:
        image_nodes.append(n)
    elif has_gradient:
        gradient_nodes.append(n)
    # else: node has only SOLID / unsupported fills — out of scope here
    # (would have been filtered by figma_extract_fills anyway).

# Load audit to know which source files were generated this cycle. Audit
# captures every Write/Edit of *.swift in the session.
audit_files = []
audit_image_rows = 0
if os.path.exists(audit_path):
    try:
        with open(audit_path) as f:
            audit = json.load(f)
        files = audit.get("files") or {}
        audit_files = list(files.keys())
        for rel, fd in files.items():
            for r in (fd.get("rows") or []):
                if r.get("kind") == "image":
                    audit_image_rows += 1
    except (json.JSONDecodeError, FileNotFoundError):
        pass

# Resolve files to absolute paths via --src-root so we can grep their content.
# Used both for gradient emission counting (the audit has no gradient kind —
# kinds are color|font|padding|spacing|frame|image|text|stack) and for bypass
# comment detection.
GRADIENT_RE = re.compile(
    r"\b(LinearGradient|RadialGradient|AngularGradient|EllipticalGradient|MeshGradient)\s*\(",
)
IMAGE_RE   = re.compile(r"\bImage\s*\(\s*(\.|\")")
BYPASS_RE  = re.compile(r"//\s*allow-no-bg-emit\s*:\s*\S")

def resolve(rel):
    if not src_root:
        return None
    # rel is already a project-relative path like "Screens/Onboarding/OnboardingScreen.swift"
    return os.path.join(src_root, rel)

source_image_emissions    = 0
source_gradient_emissions = 0
bypass_present            = False
bypass_files              = []

for rel in audit_files:
    abs_path = resolve(rel)
    if not abs_path or not os.path.exists(abs_path):
        continue
    try:
        with open(abs_path, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        continue
    source_image_emissions    += len(IMAGE_RE.findall(text))
    source_gradient_emissions += len(GRADIENT_RE.findall(text))
    if BYPASS_RE.search(text):
        bypass_present = True
        bypass_files.append(rel)

# When --src-root not provided we degrade to audit-row counts. FC-1 still
# works via `kind: "image"` rows; FC-2 / FC-3 gradient detection becomes
# unreliable (audit has no gradient row kind), so we surface a degraded
# mode flag in the output.
degraded = (not src_root) or (not audit_files)
image_emissions    = source_image_emissions    if not degraded else audit_image_rows
gradient_emissions = source_gradient_emissions if not degraded else 0  # cannot detect

findings = []
violations = 0
warnings   = 0

def add(code, level, rule, detail):
    global violations, warnings
    findings.append({"code": code, "level": level, "rule": rule, "detail": detail})
    if level == "FAIL":
        violations += 1
    else:
        warnings += 1

# FC-1 — IMAGE node(s) but no Image emission ----------------------------------
expect_image_count = len(image_nodes) + len(stacked_nodes)
if expect_image_count > 0 and image_emissions == 0:
    level = "WARN" if bypass_present else "FAIL"
    node_names = ", ".join(
        f"{n.get('nodeName') or '?'} ({n.get('nodeId')})"
        for n in (image_nodes + stacked_nodes)
    )[:300]
    add(
        "FC-1", level,
        "fills.json IMAGE node(s) with no Image() emission",
        f"fills.json has {expect_image_count} node(s) carrying an IMAGE fill — "
        f"{node_names} — but generated source has zero `Image(.X)` / `Image(\"X\")` "
        f"constructors. Recipe 1 / Recipe 3 (fills-handling.md) was skipped. "
        f"Emit `Image(.assetName).resizable().scaledToFill().clipped()` for the "
        f"background; if the design legitimately replaced the image with a solid "
        f"color, regenerate fills.json or add `// allow-no-bg-emit: <reason>` on "
        f"the `var body` line.",
    )

# FC-2 — GRADIENT-only node(s) but no Gradient emission -----------------------
if gradient_nodes and gradient_emissions == 0 and not degraded:
    level = "WARN" if bypass_present else "FAIL"
    node_names = ", ".join(
        f"{n.get('nodeName') or '?'} ({n.get('nodeId')})" for n in gradient_nodes
    )[:300]
    add(
        "FC-2", level,
        "fills.json GRADIENT node(s) with no gradient emission",
        f"fills.json has {len(gradient_nodes)} node(s) carrying GRADIENT_* fills — "
        f"{node_names} — but generated source has zero LinearGradient / "
        f"RadialGradient / AngularGradient / EllipticalGradient / MeshGradient "
        f"constructors. Recipe 2 (fills-handling.md) was skipped. Emit the "
        f"matching SwiftUI gradient with stops + startPoint/endPoint from "
        f"fills.json (NOT eyeballed from screenshot).",
    )
elif gradient_nodes and degraded:
    add(
        "FC-2?", "WARN",
        "gradient emission check skipped (degraded mode)",
        f"fills.json has {len(gradient_nodes)} GRADIENT-only node(s), but the gate "
        f"could not source-grep for gradient constructors (no --src-root provided "
        f"or no audit files). Re-run with `--src-root <project root>` to enforce "
        f"FC-2; otherwise verify manually.",
    )

# FC-3 — stacked [IMAGE, GRADIENT] but only one half emitted ------------------
if stacked_nodes and not degraded:
    has_image_ok    = image_emissions    > 0
    has_gradient_ok = gradient_emissions > 0
    if not (has_image_ok and has_gradient_ok):
        # If image is missing → already covered by FC-1. Only add FC-3 when
        # image IS present but gradient is missing (the "Recipe 3 half-applied"
        # case the agent slips into when it remembers the photo but drops the
        # overlay).
        if has_image_ok and not has_gradient_ok:
            level = "WARN" if bypass_present else "FAIL"
            node_names = ", ".join(
                f"{n.get('nodeName') or '?'} ({n.get('nodeId')})" for n in stacked_nodes
            )[:300]
            add(
                "FC-3", level,
                "stacked [IMAGE, GRADIENT] but gradient overlay missing",
                f"fills.json has {len(stacked_nodes)} node(s) with stacked "
                f"[IMAGE, GRADIENT_*] fills — {node_names} — code emits Image but no "
                f"matching gradient overlay. Recipe 3 (fills-handling.md) was "
                f"half-applied. The gradient is part of the visible composition "
                f"per the Figma paint stack — add the matching LinearGradient / "
                f"RadialGradient on top of the Image inside the ZStack.",
            )

# FC-4 — fills.json IMAGE node has no manifest.rows[] entry -------------------
# Closes the Bug-1 sub-gap: even when the agent DOES emit `Image(.something)`,
# the asset for THIS specific Figma node must have been exported by
# `figma_export_assets_unified` and recorded in `manifest.rows[]` with
# `status=done`. Otherwise the code references something that exists in
# xcassets only by coincidence (or doesn't exist at all → C6 dangling
# check catches that case but the diagnostic points at the wrong fix).
#
# This check has a higher specificity than FC-1: FC-1 catches "no Image
# emitted at all"; FC-4 catches "exporter pipeline missed the asset for
# this fills.json node". Both can fire together when the node was missed
# AND the agent gave up trying to emit.
manifest_path = os.path.join(os.path.dirname(out_path), "manifest.json")
manifest_node_ids = set()
manifest_loaded   = False
manifest_total    = 0
manifest_done     = 0
if os.path.exists(manifest_path):
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
        rows = manifest.get("rows") or []
        manifest_total = len(rows)
        for row in rows:
            if row.get("status") == "done" and row.get("nodeId"):
                manifest_node_ids.add(row["nodeId"])
                manifest_done += 1
        manifest_loaded = True
    except (json.JSONDecodeError, FileNotFoundError):
        pass

image_carrying_nodes = image_nodes + stacked_nodes
if manifest_loaded and image_carrying_nodes:
    missing_manifest = [
        n for n in image_carrying_nodes
        if n.get("nodeId") and n["nodeId"] not in manifest_node_ids
    ]
    if missing_manifest:
        level = "WARN" if bypass_present else "FAIL"
        node_names = ", ".join(
            f"{n.get('nodeName') or '?'} ({n.get('nodeId')})"
            for n in missing_manifest
        )[:300]
        add(
            "FC-4", level,
            "fills.json IMAGE node has no manifest.rows[] entry",
            f"fills.json declares {len(missing_manifest)} IMAGE-carrying node(s) — "
            f"{node_names} — but manifest.rows[] has no `status=done` row for them. "
            f"The asset was never exported by figma_export_assets_unified, so even "
            f"if the agent emits Image(.something) the reference points at the "
            f"wrong asset (or a phantom one). Fix: re-run "
            f"figma_export_assets_unified(autoDiscover: true) — picks up the node "
            f"if it's named `eImage*`. If the node is NOT tagged with the e-prefix, "
            f"manually add a fallback row to manifest.rows[] with "
            f"`exporter: \"fallback\"`, `strategy: \"atomic\"`, and a friendlyName "
            f"per asset-handling.md §6, then re-run the exporter for that single "
            f"row.",
        )
elif image_carrying_nodes and not manifest_loaded:
    # manifest.json missing — can't run FC-4. Surface as WARN so the agent
    # knows there's an upstream pipeline gap to close before this gate is
    # meaningful.
    add(
        "FC-4?", "WARN",
        "manifest.json missing — cannot verify fills.json IMAGE exports",
        f"fills.json has {len(image_carrying_nodes)} IMAGE-carrying node(s) but "
        f"manifest.json is not in the cache dir. Run "
        f"figma_export_assets_unified(autoDiscover: true) (Phase A Step 6) to "
        f"produce manifest.json, then re-run this gate to verify each IMAGE node "
        f"has a corresponding export row.",
    )

gate = "PASS" if violations == 0 else "FAIL"

result = {
    "schemaVersion": 1,
    "nodeId":   fills.get("rootNodeId"),
    "gate":     gate,
    "degraded": degraded,
    "bypass":   {"present": bypass_present, "files": bypass_files},
    "manifest": {
        "loaded":      manifest_loaded,
        "totalRows":   manifest_total,
        "doneRows":    manifest_done,
    },
    "findings": findings,
    "summary":  {
        "imageNodes":         len(image_nodes),
        "gradientNodes":      len(gradient_nodes),
        "stackedNodes":       len(stacked_nodes),
        "imageEmissions":     image_emissions,
        "gradientEmissions":  gradient_emissions,
        "violations":         violations,
        "warnings":           warnings,
    },
}

tmp = out_path + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(result, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out_path)

# Human summary
extra_mode = " [degraded — no --src-root]" if degraded else ""
if not findings:
    print(f"GATE: PASS  (fills.json: {len(image_nodes)} image-only, "
          f"{len(gradient_nodes)} gradient-only, {len(stacked_nodes)} stacked "
          f"→ source emits {image_emissions} Image() / {gradient_emissions} Gradient){extra_mode}")
else:
    print(f"GATE: {gate}  (violations={violations}, warnings={warnings}){extra_mode}")
    for fnd in findings:
        marker = "✗" if fnd["level"] == "FAIL" else "⚠"
        print(f"  {marker} [{fnd['code']}] {fnd['rule']}")
        print(f"      {fnd['detail']}")
    if bypass_present:
        print(f"  ⓘ bypass `// allow-no-bg-emit:` found in: {', '.join(bypass_files)} — FAILs downgraded to WARN")

sys.exit(0 if gate == "PASS" else 1)
PY
RC=$?
exit $RC
