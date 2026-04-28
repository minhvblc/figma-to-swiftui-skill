#!/usr/bin/env bash
# doctor.sh — verify the figma-to-swiftui install
#
# Checks (in order):
#   1. macOS + Swift toolchain
#   2. figma-assets (MCPFigma) registered in some Claude config
#   3. The configured mcp-figma binary exists + is executable
#   4. FIGMA_ACCESS_TOKEN works against the Figma API
#   5. figma-desktop MCP registered (any server name containing "figma")
#   6. Skills installed in ~/.claude/skills/ (or project .claude/skills/)
#
# Exits 0 if all checks pass, 1 otherwise.
# Always prints exact fix suggestions per failure.

set -u

PASS=0
FAIL=0

green()  { printf "\033[32m%s\033[0m" "$1"; }
red()    { printf "\033[31m%s\033[0m" "$1"; }
yellow() { printf "\033[33m%s\033[0m" "$1"; }
bold()   { printf "\033[1m%s\033[0m" "$1"; }

ok()   { echo "  $(green ✓) $1"; PASS=$((PASS+1)); }
bad()  { echo "  $(red ✗) $1"; FAIL=$((FAIL+1)); }
hint() { echo "      $(yellow →) $1"; }

# Candidate Claude config paths, in resolution order
CONFIG_PATHS=(
  "${PWD}/.claude/mcp.json"
  "${HOME}/.claude.json"
  "${HOME}/Library/Application Support/Claude/claude_desktop_config.json"
)

CONFIG_FOUND=""
for p in "${CONFIG_PATHS[@]}"; do
  [ -f "$p" ] && CONFIG_FOUND="$p" && break
done

# Skill candidate paths
SKILL_DIRS=(
  "${HOME}/.claude/skills"
  "${PWD}/.claude/skills"
)

echo
bold "figma-to-swiftui doctor"
echo

# ── 1. Toolchain ──────────────────────────────────────────────────────────────
echo "1. Toolchain"
if [ "$(uname -s)" = "Darwin" ]; then
  ok "macOS detected ($(sw_vers -productVersion 2>/dev/null || echo unknown))"
else
  bad "Not macOS — MCPFigma is macOS-only"
  hint "MCPFigma builds with Swift on macOS 13+; no other platform supported"
fi

if command -v swift >/dev/null 2>&1; then
  SV=$(swift --version 2>&1 | head -1)
  ok "swift available ($SV)"
else
  bad "swift not found in PATH"
  hint "Install Xcode 16+ from the App Store, or run: xcode-select --install"
fi

# ── 2. figma-assets registered ────────────────────────────────────────────────
echo
echo "2. figma-assets MCP registration"
if [ -z "$CONFIG_FOUND" ]; then
  bad "No Claude config file found"
  hint "Tried: ${CONFIG_PATHS[*]}"
  hint "Run scripts/install.sh OR create ~/.claude.json with a mcpServers block"
  MCP_BIN=""
  TOKEN=""
else
  ok "Claude config: $CONFIG_FOUND"
  MCP_INFO=$(python3 - "$CONFIG_FOUND" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception as e:
    print("ERR", e)
    sys.exit(0)
servers = cfg.get("mcpServers", {})
fa = servers.get("figma-assets")
if not fa:
    print("MISSING")
else:
    cmd = fa.get("command", "")
    tok = (fa.get("env") or {}).get("FIGMA_ACCESS_TOKEN", "")
    print("OK", cmd, tok)
PY
)
  case "$MCP_INFO" in
    "MISSING")
      bad "'figma-assets' not registered in $CONFIG_FOUND"
      hint "Run scripts/install.sh — it will patch this config"
      MCP_BIN=""; TOKEN=""
      ;;
    ERR*)
      bad "Could not parse $CONFIG_FOUND ($MCP_INFO)"
      hint "Fix the JSON manually, then re-run doctor"
      MCP_BIN=""; TOKEN=""
      ;;
    OK*)
      MCP_BIN=$(echo "$MCP_INFO" | awk '{print $2}')
      TOKEN=$(echo "$MCP_INFO" | awk '{print $3}')
      ok "'figma-assets' registered (command: $MCP_BIN)"
      ;;
  esac
fi

# ── 3. Binary exists + executable ─────────────────────────────────────────────
echo
echo "3. mcp-figma binary"
if [ -z "$MCP_BIN" ]; then
  bad "No binary path to check (figma-assets not registered)"
elif [ ! -e "$MCP_BIN" ]; then
  bad "Binary not found at $MCP_BIN"
  hint "Re-run scripts/install.sh, or build manually:"
  hint "  cd <MCPFigma checkout> && swift build -c release"
elif [ ! -x "$MCP_BIN" ]; then
  bad "Binary at $MCP_BIN is not executable"
  hint "Fix: chmod +x \"$MCP_BIN\""
else
  SIZE=$(stat -f%z "$MCP_BIN" 2>/dev/null || echo "?")
  ok "Binary executable (${SIZE} bytes)"
fi

# ── 4. FIGMA_ACCESS_TOKEN works ───────────────────────────────────────────────
echo
echo "4. FIGMA_ACCESS_TOKEN"
if [ -z "$TOKEN" ]; then
  bad "Token not set in figma-assets env block"
  hint "Get one at https://figma.com/settings (scope: File content read)"
  hint "Re-run scripts/install.sh and paste it when prompted"
else
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "X-Figma-Token: $TOKEN" \
    "https://api.figma.com/v1/me" 2>/dev/null || echo "000")
  case "$HTTP_CODE" in
    200) ok "Token valid (Figma API /v1/me returned 200)";;
    401|403) bad "Token rejected by Figma API (HTTP $HTTP_CODE)"
             hint "Token expired or wrong scope. Regenerate at https://figma.com/settings";;
    000) bad "Could not reach api.figma.com (no network?)"
         hint "Check internet connection, then re-run doctor";;
    *) bad "Unexpected HTTP $HTTP_CODE from Figma API"
       hint "Inspect manually: curl -H \"X-Figma-Token: <token>\" https://api.figma.com/v1/me";;
  esac
fi

# ── 5. figma-desktop MCP registered ───────────────────────────────────────────
echo
echo "5. figma-desktop MCP"
if [ -z "$CONFIG_FOUND" ]; then
  bad "No config to check"
else
  FD_INFO=$(python3 - "$CONFIG_FOUND" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print("ERR")
    sys.exit(0)
servers = cfg.get("mcpServers", {})
# figma-desktop or any server that exposes get_design_context-style tools
candidates = [k for k in servers if "figma" in k.lower() and k != "figma-assets"]
if not candidates:
    print("MISSING")
else:
    print("OK", ",".join(candidates))
PY
)
  case "$FD_INFO" in
    "MISSING")
      bad "No figma-desktop MCP detected (only figma-assets is registered)"
      hint "Install per https://developers.figma.com/docs/figma-mcp-server/"
      hint "Without it, the skill cannot fetch get_design_context / get_screenshot — Pass 2 + C5 will not run"
      ;;
    OK*)
      NAMES=$(echo "$FD_INFO" | cut -d' ' -f2-)
      ok "figma-desktop MCP registered (server name: $NAMES)"
      ;;
    *) bad "Could not check ($FD_INFO)";;
  esac
fi

# ── 6. Skills installed ───────────────────────────────────────────────────────
echo
echo "6. Skills installed"
SKILL_FOUND=0
for d in "${SKILL_DIRS[@]}"; do
  if [ -f "$d/figma-to-swiftui/SKILL.md" ]; then
    ok "figma-to-swiftui found at $d/figma-to-swiftui"
    SKILL_FOUND=1
  fi
  if [ -f "$d/figma-flow-to-swiftui-feature/SKILL.md" ]; then
    ok "figma-flow-to-swiftui-feature found at $d/figma-flow-to-swiftui-feature"
    SKILL_FOUND=1
  fi
done
if [ "$SKILL_FOUND" -eq 0 ]; then
  bad "No skill folders found"
  hint "Searched: ${SKILL_DIRS[*]}"
  hint "Run scripts/install.sh, or copy figma-to-swiftui/ and figma-flow-to-swiftui-feature/ to ~/.claude/skills/"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo
TOTAL=$((PASS+FAIL))
if [ "$FAIL" -eq 0 ]; then
  echo "$(green "All $TOTAL checks passed.") Restart Claude if you just changed config."
  exit 0
else
  echo "$(red "$FAIL of $TOTAL checks failed.") Apply the fixes above, then re-run: ./scripts/doctor.sh"
  exit 1
fi
