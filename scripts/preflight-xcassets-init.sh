#!/usr/bin/env bash
# preflight-xcassets-init.sh — guarantee an Assets.xcassets exists at a
# canonical path inside the iOS project, and persist that path to
# c1-conventions.json so MCPFigma's figma_export_assets_unified can write
# imagesets without prompting the user every run.
#
# Closes the failure mode where the skill said "0 .xcassets in project →
# ask user to create one before continuing" — agents either stalled there
# or improvised a non-canonical path, which then mismatched scaffold
# expectations and SwiftUI `Image(.X)` symbol resolution.
#
# Behavior:
#   1. Look at <project>/.figma-cache/_shared/c1-conventions.json.assetCatalogPath
#      → if set AND directory exists → PASS, no work.
#   2. Otherwise scan <project> for *.xcassets directories (max depth 6):
#        - 0 hits  → CREATE at canonical path
#                    (<project>/<ProjectName>/Resources/Assets.xcassets)
#        - 1 hit   → use it; persist to c1-conventions.json
#        - 2+ hits → STOP with explicit error listing candidates; user
#                    must pin one via --use <path>.
#   3. Always persist final path to c1-conventions.json.assetCatalogPath
#      (creates the JSON if missing, merges if present).
#
# The created catalog includes:
#   - top-level Contents.json
#   - AppIcon.appiconset/ stub (xcodebuild will fill with the actual icon
#     later)
#   - AccentColor.colorset/ stub
#   - Colors/ group with provides-namespace=false so figma_extract_tokens
#     dual-mode colorsets land as a flat ColorResource symbol
#     (Color(.appPrimary) instead of Color(.Colors.appPrimary)).
#
# Usage:
#   scripts/preflight-xcassets-init.sh --project <path>
#                                      [--name <ProjectName>]
#                                      [--use <existing-xcassets-path>]
#
# Exit codes:
#   0 — PASS (xcassets exists; path persisted)
#   1 — FAIL (ambiguous: 2+ catalogs found, --use required)
#  64 — bad usage
#  65 — project folder missing

set -uo pipefail

PROJECT=""
PROJECT_NAME=""
USE_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --name) PROJECT_NAME="$2"; shift 2 ;;
    --use) USE_PATH="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0" >&2; exit 0 ;;
    *) echo "FAIL: unknown arg $1" >&2; exit 64 ;;
  esac
done

[ -n "$PROJECT" ] || { echo "usage: preflight-xcassets-init.sh --project <path>" >&2; exit 64; }
[ -d "$PROJECT" ] || { echo "FAIL: project folder does not exist: $PROJECT" >&2; exit 65; }

PROJECT=$(cd "$PROJECT" && pwd)

# Derive ProjectName when not explicit: basename of project folder (matches
# vanilla-scaffold.sh / ikxcodegen-scaffold.sh conventions).
if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME=$(basename "$PROJECT")
  PROJECT_NAME=$(echo "$PROJECT_NAME" | sed 's/[^a-zA-Z0-9]//g')
  PROJECT_NAME="$(echo "${PROJECT_NAME:0:1}" | tr '[:lower:]' '[:upper:]')${PROJECT_NAME:1}"
fi

CACHE_DIR="$PROJECT/.figma-cache/_shared"
CONVENTIONS_JSON="$CACHE_DIR/c1-conventions.json"

# ── Helper: persist assetCatalogPath into c1-conventions.json ────────────────
persist_path() {
  local final_path="$1"
  mkdir -p "$CACHE_DIR"

  if [ -f "$CONVENTIONS_JSON" ]; then
    # Merge with existing JSON
    python3 - "$CONVENTIONS_JSON" "$final_path" <<'PY'
import json, sys
path, asset_path = sys.argv[1], sys.argv[2]
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {}
data["assetCatalogPath"] = asset_path
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
  else
    cat > "$CONVENTIONS_JSON" <<EOF
{
  "assetCatalogPath": "$final_path"
}
EOF
  fi
  echo "  persisted: $CONVENTIONS_JSON.assetCatalogPath = $final_path"
}

# ── Helper: create a minimal Assets.xcassets skeleton ────────────────────────
create_xcassets() {
  local target="$1"
  mkdir -p "$target"

  # Top-level Contents.json
  cat > "$target/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

  # AppIcon.appiconset stub — Xcode requires an empty appiconset to validate
  # the catalog; we leave images[] empty and let the user drop in a real
  # AppIcon via Figma export later.
  mkdir -p "$target/AppIcon.appiconset"
  cat > "$target/AppIcon.appiconset/Contents.json" <<'EOF'
{
  "images" : [
    {
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

  # AccentColor.colorset stub — used by SwiftUI's default tint.
  mkdir -p "$target/AccentColor.colorset"
  cat > "$target/AccentColor.colorset/Contents.json" <<'EOF'
{
  "colors" : [
    {
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

  # Colors/ group — provides-namespace=false so dual-mode colorsets emitted
  # by colorset-codegen.sh become flat Color(.appPrimary) symbols rather
  # than Color(.Colors.appPrimary). Matches the convention documented in
  # references/colorset-codegen.md and the b0b-tokens-codegen.sh output.
  mkdir -p "$target/Colors"
  cat > "$target/Colors/Contents.json" <<'EOF'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "provides-namespace" : false
  }
}
EOF

  echo "  created: $target"
  echo "          (AppIcon.appiconset, AccentColor.colorset, Colors/ with provides-namespace=false)"
}

# ── 0. Honor --use override ──────────────────────────────────────────────────
if [ -n "$USE_PATH" ]; then
  if [ ! -d "$USE_PATH" ]; then
    echo "FAIL: --use path does not exist: $USE_PATH" >&2
    exit 1
  fi
  # Normalize to absolute
  USE_PATH=$(cd "$USE_PATH" && pwd)
  echo "preflight-xcassets-init: --use $USE_PATH"
  persist_path "$USE_PATH"
  echo "GATE: PASS (using explicit --use path)"
  exit 0
fi

# ── 1. Check c1-conventions.json.assetCatalogPath first ─────────────────────
if [ -s "$CONVENTIONS_JSON" ]; then
  EXISTING=$(python3 -c "
import json, sys
try:
    with open('$CONVENTIONS_JSON') as f:
        data = json.load(f)
    print(data.get('assetCatalogPath', '') or '')
except Exception:
    print('')
")
  if [ -n "$EXISTING" ] && [ -d "$EXISTING" ]; then
    echo "preflight-xcassets-init: $EXISTING (from c1-conventions.json)"
    echo "GATE: PASS (already pinned and valid)"
    exit 0
  fi
fi

# ── 2. Scan project for existing *.xcassets ─────────────────────────────────
# Bash 3.2 (macOS default) lacks `mapfile`, so build the array manually.
FOUND=()
while IFS= read -r line; do
  [ -n "$line" ] && FOUND+=("$line")
done < <(find "$PROJECT" -maxdepth 6 -type d -name '*.xcassets' 2>/dev/null | sort)

case "${#FOUND[@]}" in
  0)
    # 0 hits → CREATE at canonical path
    CANONICAL="$PROJECT/$PROJECT_NAME/Resources/Assets.xcassets"
    echo "preflight-xcassets-init: no .xcassets found — creating at canonical path"
    create_xcassets "$CANONICAL"
    persist_path "$CANONICAL"
    echo "GATE: PASS (created and pinned)"
    exit 0
    ;;
  1)
    # 1 hit → use it
    FINAL="${FOUND[0]}"
    echo "preflight-xcassets-init: 1 existing .xcassets found"
    echo "  using: $FINAL"
    persist_path "$FINAL"
    echo "GATE: PASS (existing pinned)"
    exit 0
    ;;
  *)
    # 2+ hits → ambiguous, refuse silently
    {
      echo "FAIL: multiple .xcassets found in $PROJECT — cannot auto-pin."
      echo ""
      echo "Candidates:"
      for f in "${FOUND[@]}"; do
        echo "  - $f"
      done
      echo ""
      echo "Re-run with --use <path> to pin one explicitly:"
      echo "  scripts/preflight-xcassets-init.sh --project '$PROJECT' --use '<one-of-the-paths-above>'"
    } >&2
    exit 1
    ;;
esac
