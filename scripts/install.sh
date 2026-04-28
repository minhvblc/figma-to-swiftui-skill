#!/usr/bin/env bash
# install.sh — one-shot installer for figma-to-swiftui + MCPFigma
#
# Idempotent. Safe to re-run. Always backs up your Claude config before patching.
#
# Steps:
#   1. Pre-flight (macOS, swift, git, python3)
#   2. Clone (or pull) MCPFigma into a sibling directory
#   3. Build mcp-figma binary
#   4. Get FIGMA_ACCESS_TOKEN (env var or interactive prompt) + validate
#   5. Patch Claude config (project-level if .claude/ exists in cwd, else user-level)
#   6. Install skills into ~/.claude/skills/ (copy by default; --symlink for dev)
#   7. Run doctor.sh
#
# Usage:
#   ./scripts/install.sh                 # interactive
#   ./scripts/install.sh --symlink       # symlink skills (re-run git pull to update)
#   FIGMA_ACCESS_TOKEN=figd_xxx ./scripts/install.sh   # non-interactive token
#
# What this script CANNOT do:
#   - Install the figma-desktop MCP (Figma's own product) — link printed at end
#   - Install Xcode / Swift (we abort with instructions if missing)

set -eu

# ── flags ─────────────────────────────────────────────────────────────────────
SYMLINK_SKILLS=0
for arg in "$@"; do
  case "$arg" in
    --symlink) SYMLINK_SKILLS=1 ;;
    -h|--help)
      sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; exit 2 ;;
  esac
done

green()  { printf "\033[32m%s\033[0m" "$1"; }
red()    { printf "\033[31m%s\033[0m" "$1"; }
yellow() { printf "\033[33m%s\033[0m" "$1"; }
bold()   { printf "\033[1m%s\033[0m" "$1"; }
say()    { echo "$(bold "▶") $1"; }
abort()  { echo "$(red "✗") $1" >&2; exit 1; }

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd )"
MCPFIGMA_DIR="${REPO_ROOT}/../MCPFigma"
MCPFIGMA_REPO="https://github.com/minhvblc/MCPFigma.git"

echo
bold "figma-to-swiftui installer"
echo "Repo: $REPO_ROOT"
echo

# ── 1. Pre-flight ─────────────────────────────────────────────────────────────
say "1/6  Pre-flight"
[ "$(uname -s)" = "Darwin" ] || abort "macOS required (MCPFigma is Swift, macOS-only)"
command -v git     >/dev/null 2>&1 || abort "git not found. Install Xcode CLT: xcode-select --install"
command -v swift   >/dev/null 2>&1 || abort "swift not found. Install Xcode 16+ from the App Store, then re-run."
command -v python3 >/dev/null 2>&1 || abort "python3 not found (should ship with macOS — check your PATH)"
echo "  $(green ✓) macOS, git, swift, python3 OK"

# ── 2. Clone / update MCPFigma ────────────────────────────────────────────────
say "2/6  MCPFigma source"
if [ -d "$MCPFIGMA_DIR/.git" ]; then
  echo "  Found existing checkout at $MCPFIGMA_DIR"
  ( cd "$MCPFIGMA_DIR" && git pull --ff-only 2>&1 | sed 's/^/    /' ) || \
    echo "  $(yellow ⚠) git pull failed; continuing with current checkout"
else
  echo "  Cloning $MCPFIGMA_REPO → $MCPFIGMA_DIR"
  git clone "$MCPFIGMA_REPO" "$MCPFIGMA_DIR" 2>&1 | sed 's/^/    /'
fi

# ── 3. Build binary ───────────────────────────────────────────────────────────
say "3/6  Build mcp-figma"
( cd "$MCPFIGMA_DIR" && swift build -c release 2>&1 | tail -20 | sed 's/^/    /' )
# Canonicalize so the path written into config has no `..` segments
MCPFIGMA_DIR="$( cd "$MCPFIGMA_DIR" && pwd -P )"
BIN_PATH="$MCPFIGMA_DIR/.build/release/mcp-figma"
[ -x "$BIN_PATH" ] || abort "Build finished but binary missing at $BIN_PATH"
echo "  $(green ✓) Built: $BIN_PATH"

# ── 4. FIGMA_ACCESS_TOKEN ─────────────────────────────────────────────────────
say "4/6  Figma access token"
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

# ── 5. Patch Claude config ────────────────────────────────────────────────────
say "5/6  Claude config"

# Decide which config to patch.
# Priority: project-level if cwd has a .claude/ dir, else user-level ~/.claude.json,
# else create user-level fresh.
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

# Backup if file exists
if [ -f "$CONFIG" ]; then
  BACKUP="${CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG" "$BACKUP"
  echo "  $(green ✓) Backup: $BACKUP"
fi

# Make sure parent dir exists
mkdir -p "$(dirname "$CONFIG")"

# Patch in figma-assets entry, preserving any existing keys
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

# ── 6. Install skills ─────────────────────────────────────────────────────────
say "6/6  Skills"
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
