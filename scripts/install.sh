#!/usr/bin/env bash
# install.sh — one-shot installer for figma-to-swiftui + MCPFigma
#
# Idempotent. Safe to re-run. Always backs up your Claude config before patching.
#
# Steps:
#   1. Pre-flight (macOS, curl, python3; swift + git only if building from source)
#   2. Obtain mcp-figma binary
#        a) Try downloading the latest pre-built release from GitHub
#        b) If no release exists OR --build-from-source is passed, clone+build
#   3. Get FIGMA_ACCESS_TOKEN (env var or interactive prompt) + validate
#   4. Patch Claude config (project-level if .claude/ exists in cwd, else user-level)
#   5. Install skills into ~/.claude/skills/ (copy by default; --symlink for dev)
#   6. Install enforcement hooks (PreToolUse / PostToolUse / Stop) and register
#      them in ~/.claude/settings.json. Skip with --no-hooks.
#   7. Run doctor.sh
#
# Usage:
#   ./scripts/install.sh                          # download latest pre-built binary
#   ./scripts/install.sh --build-from-source      # always clone + swift build
#   ./scripts/install.sh --version v0.3.0         # download a specific tag
#   ./scripts/install.sh --symlink                # symlink skills (re-run git pull to update)
#   ./scripts/install.sh --no-hooks               # skip hook installation
#   FIGMA_ACCESS_TOKEN=figd_xxx ./scripts/install.sh   # non-interactive token
#
# What this script CANNOT do:
#   - Install the figma-desktop MCP (Figma's own product) — link printed at end
#   - Install Xcode / Swift (we abort with instructions if --build-from-source is needed)

set -eu

# ── flags ─────────────────────────────────────────────────────────────────────
SYMLINK_SKILLS=0
BUILD_FROM_SOURCE=0
INSTALL_HOOKS=1
PINNED_VERSION=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --symlink) SYMLINK_SKILLS=1; shift ;;
    --build-from-source) BUILD_FROM_SOURCE=1; shift ;;
    --no-hooks) INSTALL_HOOKS=0; shift ;;
    --version)
      [ "$#" -ge 2 ] || { echo "--version needs a tag, e.g. --version v0.3.0" >&2; exit 2; }
      PINNED_VERSION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

green()  { printf "\033[32m%s\033[0m" "$1"; }
red()    { printf "\033[31m%s\033[0m" "$1"; }
yellow() { printf "\033[33m%s\033[0m" "$1"; }
bold()   { printf "\033[1m%s\033[0m" "$1"; }
say()    { echo "$(bold "▶") $1"; }
abort()  { echo "$(red "✗") $1" >&2; exit 1; }

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
MCPFIGMA_REPO_URL="https://github.com/minhvblc/MCPFigma.git"
MCPFIGMA_RELEASES_API="https://api.github.com/repos/minhvblc/MCPFigma/releases"
MCPFIGMA_BUILD_DIR="${REPO_ROOT}/../MCPFigma"
BINARY_INSTALL_DIR="${HOME}/.local/share/mcp-figma"

echo
bold "figma-to-swiftui installer"
echo "Repo: $REPO_ROOT"
echo

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
say "1/6  Pre-flight"
[ "$(uname -s)" = "Darwin" ] || abort "macOS required (mcp-figma is a macOS binary)"
command -v curl    >/dev/null 2>&1 || abort "curl not found (should ship with macOS — check your PATH)"
command -v python3 >/dev/null 2>&1 || abort "python3 not found (should ship with macOS — check your PATH)"
if [ "$BUILD_FROM_SOURCE" = "1" ]; then
  command -v git   >/dev/null 2>&1 || abort "git not found. Install Xcode CLT: xcode-select --install"
  command -v swift >/dev/null 2>&1 || abort "swift not found. Install Xcode 16+ from the App Store, then re-run."
  echo "  $(green ✓) macOS, curl, python3, git, swift OK (build-from-source mode)"
else
  echo "  $(green ✓) macOS, curl, python3 OK"
fi

# ── 2. Obtain binary ──────────────────────────────────────────────────────────
say "2/6  mcp-figma binary"

build_from_source() {
  command -v git   >/dev/null 2>&1 || abort "git required to build from source — install Xcode CLT: xcode-select --install"
  command -v swift >/dev/null 2>&1 || abort "swift required to build from source — install Xcode 16+ from the App Store"

  if [ -d "$MCPFIGMA_BUILD_DIR/.git" ]; then
    echo "  Found existing MCPFigma checkout at $MCPFIGMA_BUILD_DIR"
    ( cd "$MCPFIGMA_BUILD_DIR" && git pull --ff-only 2>&1 | sed 's/^/    /' ) || \
      echo "  $(yellow ⚠) git pull failed; continuing with current checkout"
  else
    echo "  Cloning $MCPFIGMA_REPO_URL → $MCPFIGMA_BUILD_DIR"
    git clone "$MCPFIGMA_REPO_URL" "$MCPFIGMA_BUILD_DIR" 2>&1 | sed 's/^/    /'
  fi
  echo "  Building (this takes ~30s)..."
  ( cd "$MCPFIGMA_BUILD_DIR" && swift build -c release 2>&1 | tail -10 | sed 's/^/    /' )
  MCPFIGMA_BUILD_DIR="$( cd "$MCPFIGMA_BUILD_DIR" && pwd -P )"
  BIN_PATH="$MCPFIGMA_BUILD_DIR/.build/release/mcp-figma"
  [ -x "$BIN_PATH" ] || abort "Build finished but binary missing at $BIN_PATH"
  echo "  $(green ✓) Built: $BIN_PATH"
}

download_release() {
  local tag="$1"   # empty = latest
  local api_url
  if [ -z "$tag" ]; then
    api_url="$MCPFIGMA_RELEASES_API/latest"
  else
    api_url="$MCPFIGMA_RELEASES_API/tags/$tag"
  fi

  echo "  Querying $api_url"
  local tmp_json
  tmp_json="$(mktemp)"
  local http
  http=$(curl -sL -w "%{http_code}" -o "$tmp_json" "$api_url" || echo "000")
  if [ "$http" != "200" ]; then
    rm -f "$tmp_json"
    return 1
  fi

  local asset_url version
  read -r version asset_url < <(python3 - "$tmp_json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
tag = data.get("tag_name", "").lstrip("v")
url = ""
for a in data.get("assets", []):
    if a.get("name", "").endswith("-darwin-universal.tar.gz"):
        url = a.get("browser_download_url", "")
        break
print(tag, url)
PY
)
  rm -f "$tmp_json"

  if [ -z "$asset_url" ] || [ -z "$version" ]; then
    echo "  $(yellow ⚠) Release exists but has no darwin-universal asset attached"
    return 1
  fi

  echo "  Found mcp-figma v$version"
  mkdir -p "$BINARY_INSTALL_DIR"
  local archive="$BINARY_INSTALL_DIR/mcp-figma-$version.tar.gz"
  curl -fsSL -o "$archive" "$asset_url" || abort "Download failed: $asset_url"
  tar -xzf "$archive" -C "$BINARY_INSTALL_DIR"
  rm -f "$archive"
  BIN_PATH="$BINARY_INSTALL_DIR/mcp-figma"
  chmod +x "$BIN_PATH"
  # Remove macOS quarantine attribute so Gatekeeper doesn't block first launch.
  # The binary is unsigned (no Apple Developer ID for this project), so this
  # bypass is required and safe — you just downloaded it from a known URL.
  xattr -d com.apple.quarantine "$BIN_PATH" 2>/dev/null || true
  [ -x "$BIN_PATH" ] || abort "Extracted binary missing or not executable at $BIN_PATH"
  echo "  $(green ✓) Installed: $BIN_PATH (v$version)"
  return 0
}

BIN_PATH=""
if [ "$BUILD_FROM_SOURCE" = "1" ]; then
  echo "  --build-from-source set; skipping download"
  build_from_source
elif [ -n "$PINNED_VERSION" ]; then
  echo "  Downloading pinned version $PINNED_VERSION"
  download_release "$PINNED_VERSION" || abort "Could not download $PINNED_VERSION (no such release, or no asset)"
else
  echo "  Trying to download latest pre-built release..."
  if ! download_release ""; then
    echo "  $(yellow ⚠) No suitable release available — falling back to build from source"
    build_from_source
  fi
fi

# ── 3. FIGMA_ACCESS_TOKEN ─────────────────────────────────────────────────────
say "3/6  Figma access token"
TOKEN="${FIGMA_ACCESS_TOKEN:-}"
if [ -z "$TOKEN" ]; then
  echo "  Need a Figma Personal Access Token with 'File content read' scope."
  echo "  Create one at: https://www.figma.com/settings"
  printf "  Paste token (input hidden): "
  stty -echo
  read TOKEN
  stty echo
  echo
fi
[ -n "$TOKEN" ] || abort "No token provided"

echo "  Validating token against api.figma.com..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -H "X-Figma-Token: $TOKEN" \
  "https://api.figma.com/v1/me")
case "$HTTP" in
  200) echo "  $(green ✓) Token valid";;
  401|403) abort "Token rejected (HTTP $HTTP). Check scope = File content read.";;
  000) abort "Could not reach api.figma.com — check internet";;
  *)   abort "Unexpected HTTP $HTTP from Figma API";;
esac

# ── 4. Patch Claude config ────────────────────────────────────────────────────
say "4/6  Claude config"

if [ -d "$PWD/.claude" ]; then
  CONFIG="$PWD/.claude/mcp.json"
  echo "  Project-level config detected: $CONFIG"
elif [ -f "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ]; then
  echo "  Both Claude Code (~/.claude.json) and Claude Desktop config exist."
  echo "  Which to patch?"
  echo "    1) ~/.claude.json (Claude Code)"
  echo "    2) ~/Library/Application Support/Claude/claude_desktop_config.json (Claude Desktop)"
  printf "  Choice [1]: "
  read CHOICE
  echo
  if [ "$CHOICE" = "2" ]; then
    CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  else
    CONFIG="$HOME/.claude.json"
  fi
else
  CONFIG="$HOME/.claude.json"
  echo "  Will use $CONFIG"
fi

if [ -f "$CONFIG" ]; then
  BACKUP="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  echo "  $(green ✓) Backup: $BACKUP"
fi

mkdir -p "$(dirname "$CONFIG")"

python3 - "$CONFIG" "$BIN_PATH" "$TOKEN" <<'PY'
import json, os, sys
config_path, bin_path, token = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    with open(config_path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}
cfg.setdefault("mcpServers", {})
cfg["mcpServers"]["figma-assets"] = {
    "command": bin_path,
    "env": {"FIGMA_ACCESS_TOKEN": token},
}
with open(config_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PY
echo "  $(green ✓) Patched 'figma-assets' into $CONFIG"
echo "  $(yellow ⚠) Note: token is stored in plaintext at the path above."
echo "      If you store this config in git, exclude it from version control."

# ── 5. Install skills ─────────────────────────────────────────────────────────
say "5/6  Skills"
SKILL_DIR="$HOME/.claude/skills"
mkdir -p "$SKILL_DIR"

install_one() {
  local name="$1"
  local src="$REPO_ROOT/$name"
  local dst="$SKILL_DIR/$name"

  if [ ! -d "$src" ]; then
    abort "Skill source missing: $src"
  fi

  if [ -e "$dst" ] || [ -L "$dst" ]; then
    printf "  '$name' already installed at $dst. Overwrite? [y/N] "
    read REPLY
    case "$REPLY" in
      y|Y) rm -rf "$dst" ;;
      *) echo "  $(yellow skip) keeping existing $dst"; return ;;
    esac
  fi

  if [ "$SYMLINK_SKILLS" = "1" ]; then
    ln -s "$src" "$dst"
    echo "  $(green ✓) Symlinked $name → $src"
  else
    cp -R "$src" "$dst"
    echo "  $(green ✓) Copied $name to $dst"
  fi
}

install_one figma-to-swiftui
install_one figma-flow-to-swiftui-feature

# ── 6. Hooks ──────────────────────────────────────────────────────────────────
say "6/6  Enforcement hooks"

if [ "$INSTALL_HOOKS" = "0" ]; then
  echo "  $(yellow skip) --no-hooks set; gates will rely on agent honoring them"
else
  HOOKS_SRC="$REPO_ROOT/scripts/hooks"
  HOOKS_DST="$HOME/.claude/hooks"
  SETTINGS="$HOME/.claude/settings.json"

  if [ ! -d "$HOOKS_SRC" ]; then
    echo "  $(red ✗) Hooks source missing: $HOOKS_SRC"
    echo "      → re-clone the repo or install manually per SKILL.md §Strongly recommended hooks"
  else
    mkdir -p "$HOOKS_DST"
    for src in "$HOOKS_SRC"/*.sh; do
      [ -f "$src" ] || continue
      name=$(basename "$src")
      dst="$HOOKS_DST/$name"
      cp "$src" "$dst"
      chmod +x "$dst"
      echo "  $(green ✓) Installed $name"
    done

    # Backup + patch ~/.claude/settings.json to register the three hooks.
    if [ -f "$SETTINGS" ]; then
      BACKUP="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
      cp "$SETTINGS" "$BACKUP"
      echo "  $(green ✓) Backup: $BACKUP"
    fi
    mkdir -p "$(dirname "$SETTINGS")"

    python3 - "$SETTINGS" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}

cfg.setdefault("hooks", {})

GATES = [
    ("PreToolUse",  "Write|Edit", "~/.claude/hooks/figma-to-swiftui-gate.sh"),
    ("PostToolUse", "Write|Edit", "~/.claude/hooks/figma-to-swiftui-pass2-gate.sh"),
    ("Stop",        None,         "~/.claude/hooks/figma-to-swiftui-stop-gate.sh"),
]

def already_registered(blocks, command):
    for b in blocks or []:
        for h in (b.get("hooks") or []):
            if h.get("command") == command:
                return True
    return False

added = 0
for event, matcher, command in GATES:
    blocks = cfg["hooks"].setdefault(event, [])
    if already_registered(blocks, command):
        continue
    entry = {"hooks": [{"type": "command", "command": command, "timeout": 10}]}
    if matcher:
        entry["matcher"] = matcher
    blocks.append(entry)
    added += 1

with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")

print(f"REGISTERED {added}")
PY
    echo "  $(green ✓) Patched $SETTINGS — gates run automatically next session"
    echo "      (PreToolUse blocks .swift writes when assets missing,"
    echo "       PostToolUse auto-runs Gate C3-Pass2,"
    echo "       Stop blocks termination when C5 Done-Gate unsatisfied)"
  fi
fi

# ── Final ─────────────────────────────────────────────────────────────────────
echo
bold "Almost done — one manual step left:"
echo
echo "  Install the figma-desktop MCP server (provides get_metadata, get_design_context, get_screenshot)."
echo "  This skill cannot run without it."
echo "  Guide: $(yellow https://developers.figma.com/docs/figma-mcp-server/)"
echo
echo "Then restart Claude (Cmd+Q) so it picks up the new MCP config."
echo
say "Running doctor to verify..."
echo
"$REPO_ROOT/scripts/doctor.sh" || {
  echo
  echo "$(yellow "Doctor reported issues — fix them and re-run: ./scripts/doctor.sh")"
  exit 0
}
