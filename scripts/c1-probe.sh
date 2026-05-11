#!/usr/bin/env bash
# c1-probe.sh — emit `c1-conventions.json` from a Swift project in one call.
#
# Replaces the 11-step manual probe in figma-to-swiftui/SKILL.md Step C1 +
# references/adaptation-workflow.md §0. Each detector is a deterministic
# grep / find — same logic agents have been running by hand, just in a
# single bash invocation. Output is the SAME JSON shape the c8-* gates
# already read.
#
# Detectors (all read-only, fail open — every field is null/false when not
# detected, so an empty project still yields a valid JSON):
#
#   1. screenFolderConvention   — count Screens/<X>Screen/<X>Screen.swift hits
#   2. viewModelPattern         — open latest *ViewModel.swift, look for
#                                 @MainActor + enum Action + send() + enum Route
#   3. minDeploymentTarget      — IPHONEOS_DEPLOYMENT_TARGET from pbxproj/xcconfig
#   4. observationFlavor        — @Observable usage + minDeploymentTarget
#   5. usesIKNavigation         — import IKNavigation / IKRouter conformance
#   5b. routerName              — most recent IKRouter impl name
#   6. usesIKMacros             — import IKMacros / @APIProtocol / @JsonSerializable
#   6b. apiRepoTypeName         — IKAPIRepository conforming type
#   7. ikFontEnum / spacingEnum / colorEnum — alternative names supported
#   8. xcstringsPath            — find .xcstrings
#   9. assetCatalogPath         — find .xcassets (interactive prompt on N>1
#                                 unless --asset-catalog passed)
#  10. hasColorHexExtension     — Color(hex:) extension grep
#  11. useGeneratedSymbols      — GENERATE_ASSET_SYMBOLS = YES in pbxproj
#  11b. useStringCatalogSymbols — STRING_CATALOG_GENERATE_SYMBOLS = YES
#
# Output JSON path:
#   .figma-cache/<nodeId>/c1-conventions.json     # single screen
#   .figma-cache/_shared/c1-conventions.json      # flow
#
# Usage:
#   c1-probe.sh --project <root> --output <path/to/c1-conventions.json>
#               [--asset-catalog <path>]    # bypass interactive prompt
#
# Exit codes:
#   0 — JSON written
#   64 — bad usage
#   65 — project root missing

set -uo pipefail

PROJECT=""
OUTPUT=""
ASSET_CATALOG_OVERRIDE=""

print_usage() {
  cat <<'USAGE' >&2
usage: c1-probe.sh --project <root> --output <path>
                   [--asset-catalog <abs-path-to-.xcassets>]

Walks the Swift project and writes c1-conventions.json — the single source
of truth that C2 (implement) and Pass 5 (c8-* gates) read for routing.

When the project has multiple .xcassets, the script lists them and exits
with status 0 + writes JSON with assetCatalogPath:null. Re-invoke with
--asset-catalog set to the chosen one.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)        PROJECT="${2:-}"; shift 2 ;;
    --output)         OUTPUT="${2:-}"; shift 2 ;;
    --asset-catalog)  ASSET_CATALOG_OVERRIDE="${2:-}"; shift 2 ;;
    -h|--help)        print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$PROJECT" ] || { print_usage; exit 64; }
[ -n "$OUTPUT"  ] || { print_usage; exit 64; }
[ -d "$PROJECT" ] || { echo "FAIL: project root not a directory: $PROJECT" >&2; exit 65; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 65; }

mkdir -p "$(dirname "$OUTPUT")"

PROJECT_ABS=$(cd "$PROJECT" && pwd)

python3 - "$PROJECT_ABS" "$OUTPUT" "${ASSET_CATALOG_OVERRIDE}" <<'PY'
import json, os, re, subprocess, sys
from datetime import datetime, timezone

project, output, asset_override = sys.argv[1], sys.argv[2], sys.argv[3] or None

SKIP_DIR = {".figma-cache", ".build", "DerivedData", "Pods", ".git",
            "node_modules", "Carthage", ".swiftpm", "build"}

def walk_files(suffixes):
    for dirpath, dirnames, filenames in os.walk(project):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIR]
        for f in filenames:
            if any(f.endswith(s) for s in suffixes):
                yield os.path.join(dirpath, f)

def grep_first(pattern, files):
    """Return (path, line) of first match or None."""
    pat = re.compile(pattern)
    for f in files:
        try:
            with open(f, errors="replace") as fh:
                for line in fh:
                    if pat.search(line):
                        return f, line.rstrip("\n")
        except OSError:
            pass
    return None

def grep_any(pattern, files):
    return grep_first(pattern, files) is not None

def grep_first_capture(pattern, files):
    """Return first regex group(1) match across all files."""
    pat = re.compile(pattern)
    for f in files:
        try:
            with open(f, errors="replace") as fh:
                for line in fh:
                    m = pat.search(line)
                    if m:
                        try:
                            return m.group(1)
                        except IndexError:
                            return None
        except OSError:
            pass
    return None

# Pre-collect Swift / pbxproj / xcconfig file lists once.
SWIFT_FILES = list(walk_files((".swift",)))
PBXPROJ = list(walk_files(("pbxproj",)))
XCCONFIG = list(walk_files((".xcconfig",)))
PODFILE = os.path.join(project, "Podfile")
PODFILE_TEXT = ""
if os.path.isfile(PODFILE):
    try:
        PODFILE_TEXT = open(PODFILE, errors="replace").read()
    except OSError:
        pass

# ── 0. usesIKCoreApp (Ikame umbrella pod) — CASCADES ─────────────────────
# When IKCoreApp is detected (Podfile pod or Swift import), every dependent
# ik-* flag is forced to true (umbrella re-exports IKNavigation, IKFont,
# IKMacros, IKPopup, IKFeedback, IKTracking, IKLocalized, IKAsset). The
# individual sub-libs do NOT appear as separate pod lines in Podfile, so
# probing them by-name would yield false negatives for Ikame projects.
uses_ik_core_app = bool(re.search(r"^\s*pod\s+'IKCoreApp'", PODFILE_TEXT, re.MULTILINE))
if not uses_ik_core_app:
    uses_ik_core_app = grep_first(r"\bimport\s+IKCoreApp\b", SWIFT_FILES) is not None

def latest_file(paths):
    best = None
    best_mtime = -1
    for p in paths:
        try:
            m = os.path.getmtime(p)
        except OSError:
            continue
        if m > best_mtime:
            best, best_mtime = p, m
    return best

# ── 1. screenFolderConvention ────────────────────────────────────────────
screen_files = []
for f in SWIFT_FILES:
    base = os.path.splitext(os.path.basename(f))[0]
    if not base.endswith("Screen"):
        continue
    parent = os.path.basename(os.path.dirname(f))
    grand = os.path.basename(os.path.dirname(os.path.dirname(f)))
    if parent == base and grand == "Screens":
        screen_files.append(f)
screen_folder_convention = "screen-based" if len(screen_files) >= 2 else "flat"
# Ikame override — feature-flat layout when usesIKCoreApp.
if uses_ik_core_app:
    screen_folder_convention = "ikame-feature-flat"

# ── 2. viewModelPattern ───────────────────────────────────────────────────
vm_files = [f for f in SWIFT_FILES if os.path.basename(f).endswith("ViewModel.swift")]
vm_pattern = "none"
if vm_files:
    latest_vm = latest_file(vm_files)
    try:
        text = open(latest_vm, errors="replace").read()
    except OSError:
        text = ""
    has_main = "@MainActor" in text
    has_enum_action = re.search(r"\benum\s+Action\b", text) is not None
    has_send = re.search(r"\bfunc\s+send\s*\(\s*_?\s*action:\s*Action\b", text) is not None
    if has_main and has_enum_action and has_send:
        vm_pattern = "state-action-reducer"
        # Ikame variant — Combine PassthroughSubject for routes (D-405).
        # Scan ALL VM files (not just latest) — the most-recently-edited VM
        # may be a legacy form while most are routePublisher-flavored.
        if grep_any(r"\bPassthroughSubject\b", vm_files) \
                and grep_any(r"\brouteP[uU]blisher\b", vm_files):
            vm_pattern = "state-action-route-publisher"
    else:
        vm_pattern = "ad-hoc"

# ── 3. minDeploymentTarget ────────────────────────────────────────────────
min_target = None
for src in PBXPROJ + XCCONFIG:
    try:
        text = open(src, errors="replace").read()
    except OSError:
        continue
    m = re.search(r"IPHONEOS_DEPLOYMENT_TARGET\s*=\s*([0-9]+(?:\.[0-9]+)?)", text)
    if m:
        v = m.group(1)
        if min_target is None or float(v) < float(min_target):
            min_target = v
# Fallback: try Package.swift platforms.
if min_target is None:
    for f in walk_files(("Package.swift",)):
        try:
            text = open(f, errors="replace").read()
        except OSError:
            continue
        m = re.search(r"\.iOS\(\.v([0-9]+)\)", text)
        if m:
            min_target = f"{m.group(1)}.0"
            break

# ── 4. observationFlavor ──────────────────────────────────────────────────
has_observable_macro = grep_any(r"@Observable\b", SWIFT_FILES)
target_major = None
if min_target:
    try:
        target_major = int(float(min_target))
    except ValueError:
        target_major = None
if target_major is not None and target_major >= 17 and has_observable_macro:
    observation_flavor = "observable"
else:
    observation_flavor = "observable-object"

# ── 5. usesIKNavigation + routerName ─────────────────────────────────────
ikn_signals = [
    r"\bimport\s+IKNavigation\b",
    r"\bIKNavigation\.makeView\b",
    r":\s*IKRouter\b",
    r"@Environment\(\\\.ikNavigationable\)|@Environment\(\\\.ik_navigation\)",
]
uses_iknavigation = uses_ik_core_app or any(grep_any(p, SWIFT_FILES) for p in ikn_signals)
router_name = None
if uses_iknavigation:
    # Find class/struct that conforms to IKRouter — most recent one wins.
    for f in sorted(SWIFT_FILES, key=lambda p: -os.path.getmtime(p)):
        try:
            text = open(f, errors="replace").read()
        except OSError:
            continue
        m = re.search(r"(?:class|struct|final\s+class)\s+(\w+)\s*:[^{]*\bIKRouter\b", text)
        if m:
            router_name = m.group(1)
            break

# ── 6. usesIKMacros + apiRepoTypeName ────────────────────────────────────
ikm_signals = [
    r"\bimport\s+IKMacros\b",
    r"@APIProtocol\b",
    r"@JsonSerializable\b",
]
uses_ikmacros = uses_ik_core_app or any(grep_any(p, SWIFT_FILES) for p in ikm_signals)
api_repo_type = None
if uses_ikmacros:
    api_repo_type = grep_first_capture(
        r"(?:class|struct|final\s+class)\s+(\w+)\s*:[^{]*\bIKAPIRepository\b",
        SWIFT_FILES,
    )

# ── 7. token enums (ikFont / spacing / color) ────────────────────────────
def find_enum_alt(names):
    """Return (chosen_name, [cases]) or (None, [])."""
    for n in names:
        for f in SWIFT_FILES:
            try:
                text = open(f, errors="replace").read()
            except OSError:
                continue
            m = re.search(rf"\b(?:enum|struct)\s+{re.escape(n)}\b\s*\{{(.*?)^\}}",
                          text, re.DOTALL | re.MULTILINE)
            if m:
                body = m.group(1)
                cases = re.findall(r"case\s+(\w+)", body)
                # Also grep static let inside struct (IKCoreApp shape).
                statics = re.findall(r"static\s+(?:let|var)\s+(\w+)", body)
                return n, list(dict.fromkeys(cases + statics))[:80]
    return None, []

ik_font_enum, ik_font_cases = find_enum_alt(["IKFont", "AppFont", "Typography"])
spacing_enum, spacing_cases = find_enum_alt(["Spacing", "AppSpacing", "Padding"])
color_enum, color_cases     = find_enum_alt(["IKCoreApp", "AppColors", "ColorPalette"])

# ── 8. xcstringsPath ──────────────────────────────────────────────────────
xcstrings_files = list(walk_files((".xcstrings",)))
xcstrings_path = xcstrings_files[0] if xcstrings_files else None

# ── 9. assetCatalogPath ──────────────────────────────────────────────────
asset_catalogs = []
for dirpath, dirnames, _ in os.walk(project):
    dirnames[:] = [d for d in dirnames if d not in SKIP_DIR]
    for d in list(dirnames):
        if d.endswith(".xcassets"):
            asset_catalogs.append(os.path.join(dirpath, d))

asset_catalog_path = None
asset_catalog_choices = []
if asset_override:
    asset_catalog_path = asset_override
elif len(asset_catalogs) == 1:
    asset_catalog_path = asset_catalogs[0]
elif len(asset_catalogs) > 1:
    asset_catalog_choices = asset_catalogs

# ── 10. hasColorHexExtension ─────────────────────────────────────────────
color_hex_ext = grep_any(r"extension\s+Color\s*\{[^}]*init\(\s*hex:\s*String", SWIFT_FILES)
# Multi-line variant.
if not color_hex_ext:
    for f in SWIFT_FILES:
        try:
            text = open(f, errors="replace").read()
        except OSError:
            continue
        if re.search(r"extension\s+Color\s*\{[^}]*?init\(\s*hex:\s*String",
                     text, re.DOTALL):
            color_hex_ext = True
            break

# ── 11. useGeneratedSymbols + useStringCatalogSymbols ────────────────────
# GENERATE_ASSET_SYMBOLS is YES by default on Xcode 15+. The skill's baseline
# is Xcode 15+ (most users on Xcode 26+), so treat the flag's absence as YES.
# Only flip to False when the project explicitly opts out with NO.
generate_asset_symbols = True
string_catalog_symbols = False
for src in PBXPROJ + XCCONFIG:
    try:
        text = open(src, errors="replace").read()
    except OSError:
        continue
    if re.search(r"GENERATE_ASSET_SYMBOLS\s*=\s*NO", text):
        generate_asset_symbols = False
    if re.search(r"STRING_CATALOG_GENERATE_SYMBOLS\s*=\s*YES", text):
        string_catalog_symbols = True

# ── 11b. Greenfield Ikame defaults — when usesIKCoreApp but user code is empty ──
# In greenfield mode (just-ran ikxcodegen, no user-defined enums yet), the
# probes above return None for ikFontEnum / trackingEnumName / toastTypeEnum /
# entitiesPath. But the bridge files reference these names. Subagents emit
# code that references AppTracking.<case> or AppFont.<token>; without the
# enums existing, compile fails.
#
# When usesIKCoreApp is true AND the corresponding probe returned None,
# set the canonical Ikame default name. The skill's B0b/B0c phase auto-creates
# skeleton enum files; subagents' emitted references then resolve.
if uses_ik_core_app:
    if ik_font_enum is None:
        ik_font_enum = "AppFont"
        # ik_font_cases stays empty — agent populates per-feature
    # tracking_enum_name set later (it has independent grep)
    # entities_path set later

# ── 12. Ikame cascade flags + Entities + Tracking/Toast/NavItem captures ─
uses_ikpopup = uses_ik_core_app \
    or grep_any(r"IKPopup\.shared\.showPopup", SWIFT_FILES) \
    or grep_any(r"@Environment\(\\.ikPopupDismiss\)", SWIFT_FILES)
uses_ikfeedback = uses_ik_core_app \
    or grep_any(r"\bIKLoading\.(show|dismiss)Loading", SWIFT_FILES) \
    or grep_any(r"\bIKHaptics\.", SWIFT_FILES) \
    or grep_any(r"showAppBottomToast", SWIFT_FILES)
uses_iktracking = uses_ik_core_app \
    or grep_any(r"\.ikLogScreenActive\(", SWIFT_FILES) \
    or grep_any(r"AppTrackingFeature\.shared", SWIFT_FILES)
uses_iklocalized = uses_ik_core_app or grep_any(r"\.ikLocalized\(\)", SWIFT_FILES)
uses_ikfont = uses_ik_core_app or (ik_font_enum is not None)
uses_ikasset_symbol = uses_ik_core_app or generate_asset_symbols

# Entities folder + per-source buckets + prefix detection.
entities_path = None
entities_prefix = ""
entities_sources = []
candidate_roots = [os.path.join(project, "Entities")]
try:
    candidate_roots += [
        os.path.join(project, d, "Entities")
        for d in os.listdir(project)
        if os.path.isdir(os.path.join(project, d)) and d not in SKIP_DIR
    ]
except OSError:
    pass
for candidate_root in candidate_roots:
    if not os.path.isdir(candidate_root):
        continue
    entities_path = os.path.relpath(candidate_root, project)
    sources = sorted(
        d for d in os.listdir(candidate_root)
        if os.path.isdir(os.path.join(candidate_root, d))
    )
    entities_sources = sources
    prefixes = []
    for source in sources:
        sdir = os.path.join(candidate_root, source)
        try:
            for f in os.listdir(sdir):
                m = re.match(r"^([A-Z])\w+Model\.swift$", f)
                if m:
                    prefixes.append(m.group(1))
        except OSError:
            pass
    if prefixes:
        from collections import Counter
        entities_prefix = Counter(prefixes).most_common(1)[0][0]
    break

# Greenfield Ikame default: when usesIKCoreApp but no Entities folder exists,
# default to "Entities" path so subagents have a place to escalate new app-wide
# models to. Empty prefix (project decides) and empty sources (no buckets yet).
if uses_ik_core_app and entities_path is None:
    entities_path = "Entities"

# Locate NavigationItem / AppRoute / MainRoute enum.
navigation_item_enum_name = None
navigation_item_path = None
if uses_iknavigation:
    for f in SWIFT_FILES:
        try:
            text = open(f, errors="replace").read()
        except OSError:
            continue
        m = re.search(r"\benum\s+(NavigationItem|AppRoute|MainRoute)\b", text)
        if m:
            navigation_item_enum_name = m.group(1)
            navigation_item_path = os.path.relpath(f, project)
            break

# Locate AppTracking enum.
tracking_enum_name = None
tracking_enum_path = None
for f in SWIFT_FILES:
    try:
        text = open(f, errors="replace").read()
    except OSError:
        continue
    m = re.search(r"\benum\s+(AppTracking)\b", text)
    if m:
        tracking_enum_name = m.group(1)
        tracking_enum_path = os.path.relpath(f, project)
        break

# Greenfield Ikame default: when usesIKCoreApp but no AppTracking enum,
# default to "AppTracking" name. Subagent delta-requests will populate cases.
if uses_ik_core_app and tracking_enum_name is None:
    tracking_enum_name = "AppTracking"

# Locate ToastSceenType / ToastScreenType / ToastType.
toast_type_enum_name = None
for f in SWIFT_FILES:
    try:
        text = open(f, errors="replace").read()
    except OSError:
        continue
    m = re.search(r"\benum\s+(ToastSceenType|ToastScreenType|ToastType|AppToastType)\b", text)
    if m:
        toast_type_enum_name = m.group(1)
        break

# Greenfield Ikame default: ToastSceenType is the authenv2 convention.
if uses_ik_core_app and toast_type_enum_name is None:
    toast_type_enum_name = "ToastSceenType"

# ── Assemble JSON ────────────────────────────────────────────────────────
result = {
    "_probedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "projectRoot": project,
    "screenFolderConvention": screen_folder_convention,
    "viewModelPattern": vm_pattern,
    "minDeploymentTarget": min_target,
    "observationFlavor": observation_flavor,
    "usesIKCoreApp": uses_ik_core_app,
    "usesIKNavigation": uses_iknavigation,
    "routerName": router_name,
    "navigationItemEnumName": navigation_item_enum_name,
    "navigationItemPath": navigation_item_path,
    "viewToRouteWiring": "routePublisher" if vm_pattern == "state-action-route-publisher" else None,
    "usesIKMacros": uses_ikmacros,
    "apiRepoTypeName": api_repo_type,
    "usesIKPopup": uses_ikpopup,
    "usesIKFeedback": uses_ikfeedback,
    "usesIKTracking": uses_iktracking,
    "usesIKLocalized": uses_iklocalized,
    "usesIKFont": uses_ikfont,
    "usesIKAssetSymbol": uses_ikasset_symbol,
    "trackingEnumName": tracking_enum_name,
    "trackingEnumPath": tracking_enum_path,
    "toastTypeEnumName": toast_type_enum_name,
    "ikFontEnum": ik_font_enum,
    "ikFontCases": ik_font_cases if ik_font_enum else [],
    "spacingEnum": spacing_enum,
    "spacingCases": spacing_cases if spacing_enum else [],
    "colorEnum": color_enum,
    "colorCases": color_cases if color_enum else [],
    "entitiesPath": entities_path,
    "entitiesPrefix": entities_prefix,
    "entitiesSources": entities_sources,
    "xcstringsPath": xcstrings_path,
    "assetCatalogPath": asset_catalog_path,
    "assetCatalogChoices": asset_catalog_choices,
    "hasColorHexExtension": color_hex_ext,
    "useGeneratedSymbols": generate_asset_symbols,
    "useStringCatalogSymbols": string_catalog_symbols,
}

with open(output, "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")

# Pretty-print resolved flags so the agent can verify routing decisions
# before C2 (matches the SKILL.md C1 print-block contract).
print(f"WROTE: {output}")
print()
print(f"  screenFolderConvention    = {result['screenFolderConvention']}")
print(f"  viewModelPattern          = {result['viewModelPattern']}")
print(f"  minDeploymentTarget       = {result['minDeploymentTarget']}")
print(f"  observationFlavor         = {result['observationFlavor']}")
print(f"  usesIKCoreApp             = {result['usesIKCoreApp']}")
print(f"  usesIKNavigation          = {result['usesIKNavigation']}    routerName = {result['routerName']}")
print(f"  usesIKMacros              = {result['usesIKMacros']}    apiRepoTypeName = {result['apiRepoTypeName']}")
print(f"  usesIKPopup/Feedback/Tracking/Localized/Font/AssetSymbol")
print(f"                            = {result['usesIKPopup']}/{result['usesIKFeedback']}/{result['usesIKTracking']}/"
      f"{result['usesIKLocalized']}/{result['usesIKFont']}/{result['usesIKAssetSymbol']}")
print(f"  ikFontEnum                = {result['ikFontEnum']}    ({len(result['ikFontCases'])} case(s))")
print(f"  spacingEnum               = {result['spacingEnum']}    ({len(result['spacingCases'])} case(s))")
print(f"  colorEnum                 = {result['colorEnum']}    ({len(result['colorCases'])} case(s))")
print(f"  trackingEnum              = {result['trackingEnumName']}    path = {result['trackingEnumPath']}")
print(f"  toastTypeEnum             = {result['toastTypeEnumName']}")
print(f"  navigationItemEnum        = {result['navigationItemEnumName']}    path = {result['navigationItemPath']}")
print(f"  entitiesPath              = {result['entitiesPath']}    prefix = '{result['entitiesPrefix']}'    sources = {result['entitiesSources']}")
print(f"  hasColorHexExtension      = {result['hasColorHexExtension']}")
print(f"  useGeneratedSymbols       = {result['useGeneratedSymbols']}")
print(f"  useStringCatalogSymbols   = {result['useStringCatalogSymbols']}")
print(f"  xcstringsPath             = {result['xcstringsPath']}")
print(f"  assetCatalogPath          = {result['assetCatalogPath']}")

if result["assetCatalogChoices"]:
    print()
    print(f"NOTE: project has {len(result['assetCatalogChoices'])} .xcassets — pin one and re-run:")
    for c in result["assetCatalogChoices"]:
        print(f"  {c}")
    print(f"  → re-invoke: c1-probe.sh --project ... --output ... --asset-catalog <chosen>")
PY

exit 0
