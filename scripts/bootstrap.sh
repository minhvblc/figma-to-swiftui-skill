#!/usr/bin/env bash
# bootstrap.sh — true one-line installer for figma-to-swiftui + MCPFigma
#
# Designed for `curl | bash`. Clones the skill repo to a canonical location,
# then exec's install.sh in headless mode (--yes --user). Idempotent: re-runs
# do `git pull --ff-only` instead of re-cloning.
#
# Usage (the only line a user has to type):
#   curl -fsSL https://raw.githubusercontent.com/minhvblc/figma-to-swiftui-skill/master/scripts/bootstrap.sh \
#     | FIGMA_ACCESS_TOKEN=figd_xxx bash
#
# Pass extra flags through to install.sh:
#   curl -fsSL <URL> | FIGMA_ACCESS_TOKEN=figd_xxx bash -s -- --version v0.3.0
#   curl -fsSL <URL> | FIGMA_ACCESS_TOKEN=figd_xxx bash -s -- --no-hooks
#
# Env vars:
#   FIGMA_ACCESS_TOKEN  REQUIRED — your Figma PAT (https://www.figma.com/settings,
#                                   scope: File content → Read only).
#                                   Required because curl|bash has no stdin for prompts.
#   BOOTSTRAP_DIR       optional — clone location.
#                                   Default: ~/.local/share/figma-to-swiftui-skill
#   BOOTSTRAP_REF       optional — branch / tag / SHA to check out (default: master).
#
# What this CANNOT do (by design — they belong to other vendors):
#   - Install Figma Desktop / enable its Dev Mode MCP server
#   - Restart Claude Code after the new MCP config lands
#   install.sh prints exact instructions for both at the end.

set -eu

REPO_URL="https://github.com/minhvblc/figma-to-swiftui-skill.git"
BOOTSTRAP_DIR="${BOOTSTRAP_DIR:-$HOME/.local/share/figma-to-swiftui-skill}"
BOOTSTRAP_REF="${BOOTSTRAP_REF:-master}"

green()  { printf "\033[32m%s\033[0m" "$1"; }
red()    { printf "\033[31m%s\033[0m" "$1"; }
yellow() { printf "\033[33m%s\033[0m" "$1"; }
bold()   { printf "\033[1m%s\033[0m" "$1"; }
say()    { echo "$(bold "▶") $1"; }
abort()  { echo "$(red "✗") $1" >&2; exit 1; }

echo
echo "$(bold "figma-to-swiftui bootstrap")"
echo "Will clone → $BOOTSTRAP_DIR (ref: $BOOTSTRAP_REF), then run install.sh --yes --user"
echo

# ── Pre-flight ────────────────────────────────────────────────────────────────
say "Pre-flight"
[ "$(uname -s)" = "Darwin" ] || abort "macOS required (mcp-figma is a macOS binary)"
command -v curl    >/dev/null 2>&1 || abort "curl not found (should ship with macOS)"
command -v git     >/dev/null 2>&1 || abort "git not found. Install Xcode CLT: xcode-select --install"
command -v python3 >/dev/null 2>&1 || abort "python3 not found (should ship with macOS)"

if [ -z "${FIGMA_ACCESS_TOKEN:-}" ]; then
  abort "FIGMA_ACCESS_TOKEN env var is required for one-line install.
    Get a token at https://www.figma.com/settings (scope: File content → Read only).
    Usage:
      curl -fsSL <bootstrap-url> | FIGMA_ACCESS_TOKEN=figd_xxx bash
    Or use the interactive path:
      git clone $REPO_URL && cd figma-to-swiftui-skill && ./scripts/install.sh"
fi
echo "  $(green ✓) macOS, curl, git, python3 OK; FIGMA_ACCESS_TOKEN set"

# ── Clone or update ───────────────────────────────────────────────────────────
say "Repo at $BOOTSTRAP_DIR"
if [ -d "$BOOTSTRAP_DIR/.git" ]; then
  echo "  Existing checkout found — fetching $BOOTSTRAP_REF..."
  (
    cd "$BOOTSTRAP_DIR"
    git fetch --quiet origin "$BOOTSTRAP_REF" \
      || abort "git fetch failed — check network or remove $BOOTSTRAP_DIR and retry"
    git checkout --quiet "$BOOTSTRAP_REF" \
      || abort "git checkout $BOOTSTRAP_REF failed"
    # Only fast-forward if we're on a branch (not a detached tag/SHA).
    if git symbolic-ref --quiet HEAD >/dev/null; then
      git pull --ff-only --quiet \
        || abort "git pull --ff-only failed — local checkout may have diverged. Remove $BOOTSTRAP_DIR and retry."
    fi
  )
  echo "  $(green ✓) Updated to $BOOTSTRAP_REF"
else
  mkdir -p "$(dirname "$BOOTSTRAP_DIR")"
  echo "  Cloning $REPO_URL..."
  git clone --quiet --branch "$BOOTSTRAP_REF" "$REPO_URL" "$BOOTSTRAP_DIR" \
    || abort "git clone failed — check network and that ref '$BOOTSTRAP_REF' exists"
  echo "  $(green ✓) Cloned"
fi

# ── Hand off to install.sh ────────────────────────────────────────────────────
INSTALLER="$BOOTSTRAP_DIR/scripts/install.sh"
[ -x "$INSTALLER" ] || abort "Installer missing or not executable at $INSTALLER (corrupted clone?)"

echo
say "Running $INSTALLER --yes --user $*"
echo
exec "$INSTALLER" --yes --user "$@"
