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
#   4. Patch Claude config — user-level (~/.claude.json) by default. Project-level
#      ($PWD/.claude/mcp.json) only when --project is passed AND $PWD is not this
#      skill repo. (Auto-detect of project-level was removed because the skill
#      repo itself contains a .claude/ dev config that misled the heuristic.)
#   5. Install skills into ~/.claude/skills/ (copy by default; --symlink for dev)
#   6. Install enforcement hooks (PreToolUse / PostToolUse / Stop) and register
#      them in ~/.claude/settings.json. Skip with --no-hooks.
#   7. Detect Figma.app + run doctor.sh + print test command
#
# Usage:
#   ./scripts/install.sh                          # default — download binary, install everything
#   ./scripts/install.sh --yes                    # non-interactive: auto-overwrite, default scope
#   ./scripts/install.sh --user                   # force user-level config (~/.claude.json)
#   ./scripts/install.sh --project                # force project-level ($PWD/.claude/mcp.json)
#   ./scripts/install.sh --build-from-source      # always clone + swift build
#   ./scripts/install.sh --version v0.3.0         # download a specific tag
#   ./scripts/install.sh --symlink                # symlink skills (re-run git pull to update)
#   ./scripts/install.sh --no-hooks               # skip hook installation
#   FIGMA_ACCESS_TOKEN=figd_xxx ./scripts/install.sh   # non-interactive token
#
# Headless / CI install (no prompts at all):
#   FIGMA_ACCESS_TOKEN=figd_xxx ./scripts/install.sh --yes --user
#
# What this script CANNOT do:
#   - Install the figma-desktop MCP (Figma's own product) — instructions printed at end
#   - Install Xcode / Swift (we abort with instructions if --build-from-source is needed)

set -eu

# ── flags ─────────────────────────────────────────────────────────────────────
SYMLINK_SKILLS=0
BUILD_FROM_SOURCE=0
INSTALL_HOOKS=1
PINNED_VERSION=""
ASSUME_YES=0
FORCE_SCOPE=""   # "" (default user-level) | "user" | "project"
TOTAL_GATES=""   # set by the hook-install Python heredoc (len(GATES)); empty if hooks skipped
while [ "$#" -gt 0 ]; do
  case "$1" in
    --symlink) SYMLINK_SKILLS=1; shift ;;
    --build-from-source) BUILD_FROM_SOURCE=1; shift ;;
    --no-hooks) INSTALL_HOOKS=0; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    --user) FORCE_SCOPE="user"; shift ;;
    --project) FORCE_SCOPE="project"; shift ;;
    --version)
      [ "$#" -ge 2 ] || { echo "--version needs a tag, e.g. --version v0.3.0" >&2; exit 2; }
      PINNED_VERSION="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,38p' "$0"; exit 0 ;;
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
  if [ "$ASSUME_YES" = "1" ]; then
    abort "--yes set but FIGMA_ACCESS_TOKEN env var is empty.
    Headless install must pass the token: FIGMA_ACCESS_TOKEN=figd_xxx ./scripts/install.sh --yes"
  fi
  echo "  Need a Figma Personal Access Token with 'File content read' scope."
  echo "  Steps to create one (1-2 min):"
  echo "    1. Open https://www.figma.com/settings"
  echo "    2. Scroll to 'Personal access tokens' → click 'Generate new token'"
  echo "    3. Name it (e.g. 'mcp-figma'), set scope: $(bold "File content → Read only")"
  echo "    4. Click 'Generate token' and copy the value (starts with 'figd_')"
  echo "       — Figma only shows it once; if you lose it, regenerate."
  echo
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

# Resolve canonical paths so we can compare $PWD vs the skill repo reliably.
PWD_REAL="$( cd "$PWD" && pwd -P )"
REPO_ROOT_REAL="$( cd "$REPO_ROOT" && pwd -P )"

# Decide config scope.
# Default = user-level (~/.claude.json). Project-level requires explicit
# --project flag AND $PWD must NOT be the skill repo itself (the repo ships a
# .claude/ dev config that previously misled auto-detection into installing
# figma-assets into the skill repo's local mcp.json instead of globally).
if [ "$FORCE_SCOPE" = "project" ]; then
  if [ "$PWD_REAL" = "$REPO_ROOT_REAL" ]; then
    abort "--project refused: \$PWD is the skill repo itself ($REPO_ROOT_REAL).
    Project-level config would write into the skill's dev .claude/, not your
    iOS project. cd into your iOS project first, or drop --project."
  fi
  mkdir -p "$PWD/.claude"
  CONFIG="$PWD/.claude/mcp.json"
  echo "  --project: writing $CONFIG"
elif [ "$FORCE_SCOPE" = "user" ]; then
  CONFIG="$HOME/.claude.json"
  echo "  --user: writing $CONFIG"
elif [ -f "$HOME/Library/Application Support/Claude/claude_desktop_config.json" ]; then
  if [ "$ASSUME_YES" = "1" ]; then
    CONFIG="$HOME/.claude.json"
    echo "  Both Claude Code and Claude Desktop configs exist; defaulting to $CONFIG (--yes)"
  else
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
    if [ "$ASSUME_YES" = "1" ]; then
      echo "  '$name' already at $dst — overwriting (--yes)"
      rm -rf "$dst"
    else
      printf "  '$name' already installed at $dst. Overwrite? [y/N] "
      read REPLY
      case "$REPLY" in
        y|Y) rm -rf "$dst" ;;
        *) echo "  $(yellow skip) keeping existing $dst"; return ;;
      esac
    fi
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
  SCRIPTS_SRC="$REPO_ROOT/scripts"
  SCRIPTS_DST="$HOME/.claude/scripts"
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
      echo "  $(green ✓) Installed hook: $name"
    done

    # Also install all helper scripts (b0a-/b0b- codegen, c1-/c3-/c5-/
    # c6-/c7- gates + drivers, colorset-codegen, timing-report,
    # xcodeproj-add-files) to ~/.claude/scripts/, so the stop hook's
    # fallback path resolution (see scripts/hooks/figma-to-swiftui-stop-gate.sh)
    # can find them regardless of where the user runs the skill from.
    mkdir -p "$SCRIPTS_DST"
    for src in "$SCRIPTS_SRC"/b0a-*.sh "$SCRIPTS_SRC"/b0b-*.sh \
               "$SCRIPTS_SRC"/c1-*.sh "$SCRIPTS_SRC"/c3-*.sh \
               "$SCRIPTS_SRC"/c5-*.sh "$SCRIPTS_SRC"/c6-*.sh \
               "$SCRIPTS_SRC"/c7-*.sh \
               "$SCRIPTS_SRC"/preflight-*.sh \
               "$SCRIPTS_SRC"/sync-check.sh \
               "$SCRIPTS_SRC"/mode-detect.sh \
               "$SCRIPTS_SRC"/colorset-codegen.sh \
               "$SCRIPTS_SRC"/ikxcodegen-scaffold.sh \
               "$SCRIPTS_SRC"/vanilla-scaffold.sh \
               "$SCRIPTS_SRC"/xcodeproj-add-files.sh \
               "$SCRIPTS_SRC"/timing-report.sh \
               "$SCRIPTS_SRC"/timed-run.sh; do
      [ -f "$src" ] || continue
      name=$(basename "$src")
      dst="$SCRIPTS_DST/$name"
      cp "$src" "$dst"
      chmod +x "$dst"
      echo "  $(green ✓) Installed gate script: $name"
    done

    # Backup + patch ~/.claude/settings.json to register the three hooks.
    if [ -f "$SETTINGS" ]; then
      BACKUP="${SETTINGS}.bak.$(date +%Y%m%d-%H%M%S)"
      cp "$SETTINGS" "$BACKUP"
      echo "  $(green ✓) Backup: $BACKUP"
    fi
    mkdir -p "$(dirname "$SETTINGS")"

    GATES_COUNT_FILE=$(mktemp -t figma-gates-count.XXXXXX)
    python3 - "$SETTINGS" "$GATES_COUNT_FILE" <<'PY'
import json, os, sys
path = sys.argv[1]
gates_count_path = sys.argv[2]
try:
    with open(path) as f:
        cfg = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    cfg = {}

cfg.setdefault("hooks", {})

GATES = [
    ("PreToolUse",  "Write|Edit", "~/.claude/hooks/figma-to-swiftui-gate.sh"),
    ("PreToolUse",  "Write|Edit", "~/.claude/hooks/figma-to-swiftui-banned-pattern-gate.sh"),
    ("PreToolUse",  "Write|Edit", "~/.claude/hooks/figma-to-swiftui-entry-bypass-gate.sh"),
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

with open(gates_count_path, "w") as cf:
    cf.write(str(len(GATES)))

print(f"REGISTERED {added}")
PY
    TOTAL_GATES=$(cat "$GATES_COUNT_FILE")
    rm -f "$GATES_COUNT_FILE"
    echo "  $(green ✓) Patched $SETTINGS — gates run automatically next session"
    echo "      (PreToolUse — Phase A+B coverage gate, blocks .swift writes when"
    echo "         assets missing or registry coverage incomplete;"
    echo "       PreToolUse — banned-pattern detector, blocks Image(systemName:),"
    echo "         status-bar/home-indicator redraws, letter-as-logo, screen-bezel"
    echo "         radius, button-bloat, .frame(width:) on Text;"
    echo "       PreToolUse — entry-path bypass detector, blocks edits that set"
    echo "         initial route on App.swift/ContentView.swift for verification;"
    echo "       PreToolUse — mode gate, blocks .swift writes until mode-detect"
    echo "         has run (mode.json present; ambiguous needs userConfirmed);"
    echo "       PreToolUse — engine gate, blocks raw xcodebuild/simctl in"
    echo "         figma sessions when Engine A (xcode MCP) is available;"
    echo "       PreToolUse — bundle-id gate, blocks simctl install/launch/"
    echo "         uninstall/terminate when bundle ID doesn't match the"
    echo "         preflight-bundle-verify canonical;"
    echo "       PreToolUse — scaffold gate, blocks vanilla-scaffold.sh when"
    echo "         mode.json.mode == greenfield-ikame AND userOptOutIkame"
    echo "         is not true (Ikame fleet → ikxcodegen is mandatory);"
    echo "       PreToolUse — asset-export gate, blocks Image(.X) / Image(\"X\")"
    echo "         writes when X is not in Assets.xcassets and not in any"
    echo "         .figma-cache manifest (forces Phase B before code);"
    echo "       PreToolUse — asset-symbol-case gate, catches Image(.NameWith"
    echo "         inner-digit-x) — Xcode 15+ uppercases inner-digit 'x' in"
    echo "         the auto-generated ImageResource symbol;"
    echo "       PostToolUse — auto-runs Gate C3-Pass2;"
    echo "       PostToolUse — C8 coding-conventions gate (folder/naming/"
    echo "         ViewModel pattern/function-length; conditional IKNavigation"
    echo "         + IKFont per c1-conventions.json);"
    echo "       PostToolUse — IKOnboarding pattern gate, blocks wrong"
    echo "         IKOnboardingFlow registration (IKNavigation.makeView body"
    echo "         instead of single root View);"
    echo "       Stop — blocks termination when C5/C6/C7/C8 Done-Gate unsatisfied)"
  fi
fi

# ── Figma desktop app detection ───────────────────────────────────────────────
echo
bold "figma-desktop MCP — required, install separately"
echo
if [ -d "/Applications/Figma.app" ]; then
  echo "  $(green ✓) Figma.app detected at /Applications/Figma.app"
  echo "  Enable Figma's official local MCP server:"
  echo "    1. Open Figma → menu Figma → Preferences (⌘,)"
  echo "    2. Toggle ON 'Enable Dev Mode MCP Server' (Dev Mode required)"
  echo "    3. Claude will auto-discover it via http://127.0.0.1:3845/mcp"
  echo "       — no config edit needed if Claude Code ≥ recent version."
  echo "  Reference: $(yellow https://developers.figma.com/docs/figma-mcp-server/)"
else
  echo "  $(yellow ⚠) Figma.app NOT found in /Applications/."
  echo "  Browser-only Figma cannot host the MCP server. Download Figma Desktop:"
  echo "    $(yellow https://www.figma.com/downloads/)"
  echo "  Then re-open this guide: $(yellow https://developers.figma.com/docs/figma-mcp-server/)"
fi
echo
echo "  After enabling figma-desktop, $(bold "restart Claude") (Cmd+Q + reopen) so both MCPs load."

# ── Doctor verify ─────────────────────────────────────────────────────────────
echo
say "Running doctor to verify..."
echo
DOCTOR_RC=0
"$REPO_ROOT/scripts/doctor.sh" || DOCTOR_RC=$?

# ── Final summary + test command ──────────────────────────────────────────────
echo
bold "Install summary"
echo
[ -n "$BIN_PATH" ] && echo "  • mcp-figma binary  : $BIN_PATH"
echo "  • Skills installed  : ~/.claude/skills/figma-to-swiftui"
echo "                        ~/.claude/skills/figma-flow-to-swiftui-feature"
echo "  • Claude config     : $CONFIG"
if [ "$INSTALL_HOOKS" = "1" ]; then
  echo "  • Enforcement hooks : ${TOTAL_GATES:-?} gates registered in ~/.claude/settings.json"
else
  echo "  • Enforcement hooks : $(yellow "skipped (--no-hooks)")"
fi
echo "  • Doctor status     : $([ "$DOCTOR_RC" = "0" ] && green "all checks passed" || yellow "issues reported above")"
echo
bold "Test it end-to-end"
echo
echo "  1. Make sure figma-desktop is running with Dev Mode MCP enabled (see above)."
echo "  2. cd into your iOS SwiftUI project:"
echo "       $(yellow "cd ~/path/to/your-ios-project")"
echo "  3. Open Claude Code:"
echo "       $(yellow "claude")"
echo "  4. Run the skill with a Figma URL that has a node-id:"
echo "       $(yellow "/figma-to-swiftui https://www.figma.com/design/<fileKey>/...?node-id=<nodeId>")"
echo
echo "  Re-verify any time: $(yellow "$REPO_ROOT/scripts/doctor.sh")"
echo "  Re-install headless: $(yellow "FIGMA_ACCESS_TOKEN=figd_xxx $REPO_ROOT/scripts/install.sh --yes")"
echo

if [ "$DOCTOR_RC" != "0" ]; then
  echo "$(yellow "Doctor reported issues — fix them and re-run: $REPO_ROOT/scripts/doctor.sh")"
fi
exit 0
