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
#   7. Enforcement hooks installed + registered in ~/.claude/settings.json
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
warn() { echo "  $(yellow ⚠) $1"; }
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

# ── 3. Binary exists + executable + responds ──────────────────────────────────
echo
echo "3. mcp-figma binary"
MCP_RESPONDS=0
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

  # Probe it with a real JSON-RPC handshake. The agent's "registered" check
  # above only proves config is wired; this proves the binary actually answers
  # tools/list AND advertises the three tools the skill depends on.
  #
  # The trailing `sleep 3` keeps stdin open long enough for the server to flush
  # responses to stdout before SIGPIPE'ing on stdin close. Without it, fast
  # exit after the last write loses the response.
  TMP_OUT=$(mktemp -t mcpfigma-probe.XXXXXX)
  trap 'rm -f "$TMP_OUT"' EXIT
  {
    printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"doctor","version":"1"}}}'
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/initialized"}'
    printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
    sleep 3
  } | FIGMA_ACCESS_TOKEN="${TOKEN:-stub}" "$MCP_BIN" >"$TMP_OUT" 2>/dev/null

  REQUIRED_TOOLS=( figma_build_registry figma_extract_tokens figma_export_assets_unified )
  MISSING_TOOLS=""
  for t in "${REQUIRED_TOOLS[@]}"; do
    grep -q "\"$t\"" "$TMP_OUT" 2>/dev/null || MISSING_TOOLS="$MISSING_TOOLS$t "
  done

  if [ -s "$TMP_OUT" ] && [ -z "$MISSING_TOOLS" ]; then
    SERVER_VER=$(grep -oE '"version":"[0-9.]+"' "$TMP_OUT" | head -1 | sed 's/"version":"//;s/"//')
    ok "Binary responds to JSON-RPC and advertises all 3 required tools (mcp-figma ${SERVER_VER:-?})"
    MCP_RESPONDS=1
    # Version gate — typography extraction needs mcp-figma >= 0.3.0. Older 0.2.x
    # responds to tools/list but silently skips typography in figma_extract_tokens,
    # forcing the agent into the inline-token fallback path.
    if [ -n "$SERVER_VER" ]; then
      VER_OK=$(python3 -c "
import sys
v = '$SERVER_VER'.split('.')
try:
    major, minor = int(v[0]), int(v[1])
    sys.exit(0 if (major, minor) >= (0, 3) else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null && echo yes || echo no)
      if [ "$VER_OK" != "yes" ]; then
        warn "mcp-figma $SERVER_VER < 0.3.0 — typography extraction missing (figma_extract_tokens.typography[] will be empty)"
        hint "Update: re-run scripts/install.sh (downloads latest release) OR cd MCPFigma && git pull && swift build -c release"
      fi
    fi
  elif [ ! -s "$TMP_OUT" ]; then
    bad "Binary did not respond to tools/list within 3s"
    hint "Try running it manually to see startup errors:"
    hint "  FIGMA_ACCESS_TOKEN=stub \"$MCP_BIN\" </dev/null"
  else
    bad "Binary responded but missing required tools: $MISSING_TOOLS"
    hint "MCPFigma version may be < 0.3.0 (typography missing) or build is corrupted"
    hint "Re-run scripts/install.sh to refresh the binary"
  fi
fi

# ── 3b. figma-audit binary (SwiftSyntax-based L1 audit parser) ──────────────
# Required for L1 audit emission (PostToolUse hook on *Screen.swift / *View.swift).
# Without it, c2-audit.json is emitted in regex-fallback / missing degraded mode,
# and the L2 gate (c3-token-trace.sh) auto-fails until repaired.
echo
echo "3b. figma-audit binary (L1 audit parser)"
AUDIT_BIN="$HOME/.local/share/figma-audit/bin/figma-audit"
if [ ! -e "$AUDIT_BIN" ]; then
  bad "figma-audit binary not found at $AUDIT_BIN"
  hint "Build it: cd scripts/figma-audit-src && swift build -c release"
  hint "Or re-run scripts/install.sh — installs the binary as step 2b"
  hint "Without it, L1 audit runs in degraded mode and L2 gate FAILs."
elif [ ! -x "$AUDIT_BIN" ]; then
  bad "figma-audit at $AUDIT_BIN is not executable"
  hint "Fix: chmod +x \"$AUDIT_BIN\""
else
  AUDIT_VER=$("$AUDIT_BIN" --version 2>/dev/null || echo "?")
  if "$AUDIT_BIN" --self-test >/dev/null 2>&1; then
    ok "figma-audit binary OK (v$AUDIT_VER, self-test passed)"
  else
    bad "figma-audit binary present (v$AUDIT_VER) but --self-test failed"
    hint "Toolchain may have changed since build. Re-build: cd scripts/figma-audit-src && swift build -c release"
  fi
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

# ── 5. figma-desktop MCP — runtime probe + config check ──────────────────────
# Two ways to install figma-desktop MCP:
#   (a) Runtime auto-discovery — user enables "Dev Mode MCP Server" in the
#       Figma desktop app (Figma → Preferences). The app listens on
#       http://127.0.0.1:3845/mcp and Claude Code auto-discovers it WITHOUT
#       any JSON config entry. This is the most common path.
#   (b) Manual JSON config — user adds an mcpServers entry for figma-desktop
#       in ~/.claude.json or ~/.../claude_desktop_config.json. Older docs
#       suggested this; current docs prefer (a).
#
# Doctor must accept either. We probe TCP first (cheap, definitive); if the
# port is up, the MCP works regardless of config state. Banned-substitute
# detection in config still runs so a stale Framelink entry surfaces.
echo
echo "5. figma-desktop MCP"

FD_PORT_UP=0
if command -v nc >/dev/null 2>&1 && nc -z -w 1 127.0.0.1 3845 2>/dev/null; then
  FD_PORT_UP=1
fi

# Always detect banned substitutes in any config — runs even when runtime
# is up, because a stale Framelink entry in config CAN shadow auto-discovery
# on some Claude Code builds (server-name collision).
BANNED_FOUND=""
if [ -n "$CONFIG_FOUND" ]; then
  BANNED_FOUND=$(python3 - "$CONFIG_FOUND" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
hits = []
for name, spec in cfg.get("mcpServers", {}).items():
    if name == "figma-assets":
        continue
    blob = json.dumps(spec).lower()
    if "figma-developer-mcp" in blob or "framelink" in blob \
       or name.lower() in ("figma", "figma-mcp"):
        hits.append(name)
print(",".join(hits))
PY
  )
fi

if [ "$FD_PORT_UP" = "1" ]; then
  ok "figma-desktop MCP listening on 127.0.0.1:3845 (Dev Mode MCP server up — runtime auto-discovered)"
  if [ -n "$BANNED_FOUND" ]; then
    bad "Banned substitute Figma MCP also registered in config: $BANNED_FOUND"
    hint "Remove from $CONFIG_FOUND — even with figma-desktop running, a substitute server entry can shadow auto-discovery on some builds"
    hint "See figma-to-swiftui/SKILL.md §\"BANNED substitute MCPs\""
  fi
elif [ -z "$CONFIG_FOUND" ]; then
  bad "figma-desktop MCP not listening on 127.0.0.1:3845 AND no Claude config to check"
  hint "Enable Dev Mode MCP server in Figma: Figma → Preferences → 'Enable Dev Mode MCP Server'"
  hint "Or install per https://developers.figma.com/docs/figma-mcp-server/"
  hint "Without it the skill MUST stop — get_design_context / get_screenshot / get_metadata are required"
else
  # Runtime not up — fall back to JSON config detection (legacy path for
  # users who manually registered figma-desktop via mcpServers config).
  # Categorize every figma-shaped MCP server in config:
  #   - figma-assets               → MCPFigma (already covered in step 2)
  #   - figma-desktop / mcp.figma.com URLs / matches Figma's official server  → REQUIRED
  #   - figma-developer-mcp / Framelink                                       → BANNED
  #   - anything else with "figma" in name                                    → UNKNOWN
  FD_INFO=$(python3 - "$CONFIG_FOUND" <<'PY' 2>/dev/null
import json, sys
try:
    cfg = json.load(open(sys.argv[1]))
except Exception:
    print("ERR")
    sys.exit(0)
servers = cfg.get("mcpServers", {})

required = []   # likely figma-desktop (official)
banned   = []   # known substitutes
unknown  = []   # something figma-shaped we don't recognize

for name, spec in servers.items():
    if name == "figma-assets":
        continue
    if "figma" not in name.lower():
        continue
    blob = json.dumps(spec).lower()
    # Required: official figma-desktop server. Recognize via:
    #   - server name containing "desktop"
    #   - URL pointing to mcp.figma.com (HTTP transport)
    #   - command name matching figma-mcp-server / figma-desktop-mcp
    is_official = (
        "desktop" in name.lower()
        or "mcp.figma.com" in blob
        or "figma-mcp-server" in blob
        or "figma-desktop" in blob
    )
    # Banned: known substitute MCPs
    is_banned = (
        "figma-developer-mcp" in blob
        or "framelink" in blob
        or name.lower() in ("figma", "figma-mcp")  # bare "figma" → usually Framelink
        and not is_official
    )
    if is_official:
        required.append(name)
    elif is_banned:
        banned.append(name)
    else:
        unknown.append(name)

if banned:
    print("BANNED", ",".join(banned))
elif required:
    print("OK", ",".join(required))
elif unknown:
    print("UNKNOWN", ",".join(unknown))
else:
    print("MISSING")
PY
)
  case "$FD_INFO" in
    "MISSING")
      bad "No figma-desktop MCP detected (only figma-assets is registered)"
      hint "Install per https://developers.figma.com/docs/figma-mcp-server/"
      hint "Without it the skill MUST stop — get_design_context / get_screenshot / get_metadata are required"
      hint "Do NOT install Framelink / figma-developer-mcp as a substitute — it is BANNED (incompatible artifacts)"
      ;;
    BANNED*)
      NAMES=$(echo "$FD_INFO" | cut -d' ' -f2-)
      bad "Banned substitute Figma MCP registered: $NAMES"
      hint "Known substitutes (e.g. figma-developer-mcp / Framelink) produce incompatible artifacts"
      hint "Remove from $CONFIG_FOUND and install figma-desktop MCP per https://developers.figma.com/docs/figma-mcp-server/"
      hint "See figma-to-swiftui/SKILL.md §\"BANNED substitute MCPs\" for why this matters"
      ;;
    UNKNOWN*)
      NAMES=$(echo "$FD_INFO" | cut -d' ' -f2-)
      bad "Unrecognized Figma MCP registered ($NAMES) — could not verify it is figma-desktop"
      hint "If this is the official figma-desktop server, rename it to include 'desktop' so doctor recognizes it"
      hint "If it is a third-party server, it is likely BANNED — see figma-to-swiftui/SKILL.md §\"BANNED substitute MCPs\""
      ;;
    OK*)
      NAMES=$(echo "$FD_INFO" | cut -d' ' -f2-)
      ok "figma-desktop MCP registered (server name: $NAMES)"
      ;;
    *) bad "Could not check ($FD_INFO)";;
  esac
fi

# ── 5b. xcode MCP (Xcode 26+) — required for C5 Engine A ─────────────────────
# When `xcrun mcpbridge` exists AND Xcode is running with the project open,
# C5 uses BuildProject + RenderPreview instead of xcodebuild + simctl.
# Wins: bypass SPM "Creating working copy" hang + simctl boot cold start +
# previewEntry user prompt.
#
# Hard requirement on the Xcode 26+ baseline (memory: fleet standardized on
# Xcode 26+). xcrun + mcpbridge missing → FAIL (run `softwareupdate --install`
# or update via App Store). Xcode-not-running stays WARN — runtime state the
# user can fix in seconds by opening the project.
echo
echo "5b. xcode MCP (required for C5 Engine A)"
if ! command -v xcrun >/dev/null 2>&1; then
  bad "xcrun not found — Xcode CLT missing or PATH broken"
  hint "Install Xcode 26+ from the App Store, then: xcode-select --install"
elif ! xcrun mcpbridge --help >/dev/null 2>&1; then
  bad "xcrun mcpbridge not available — Xcode is older than 26"
  hint "Update Xcode to 26+ from the App Store. mcpbridge ships with Xcode 26 and unlocks Engine A (mcp__xcode__BuildProject / RenderPreview)."
  hint "Without it, C5 falls back to xcodebuild + simctl — slower SPM resolve + simctl cold start."
else
  ok "xcrun mcpbridge available (Engine A path enabled)"
  if pgrep -lf "Xcode[^/]*\.app/Contents/MacOS/Xcode$" >/dev/null 2>&1; then
    ok "Xcode app is running (BuildProject will use the live session)"
  else
    warn "Xcode not running — start Xcode and open the target project before C5"
    hint "Engine A needs a live Xcode session. Open: open -a Xcode <project>.xcworkspace"
    hint "C5 falls back to Engine B (xcodebuild) when Xcode is not running."
  fi
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

# ── 7. Verification gate scripts (C5 + C6 + C7 + drivers/codegen) ────────────
echo
echo "7. Verification gate scripts"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
for script in c5-capture.sh c5-engine-select.sh \
              c6-asset-completeness.sh c7-no-system-chrome.sh \
              c3-static-checks.sh c3-token-trace.sh c3-driver.sh \
              c3-cross-screen-drift.sh c3-safearea-gate.sh \
              c3-fills-coverage.sh \
              c2-cache-validate.sh c2-extract-design-context.sh \
              c2-build-bbox-index.sh c2-tokens-synthesize.sh \
              c2-typography-extract.sh c2-fills-stops-index.sh \
              c2-prototype-extract.sh \
              c1-probe.sh \
              b0a-extract-copy.sh b0b-tokens-codegen.sh \
              preflight-bundle-verify.sh preflight-smoke-test.sh \
              sync-check.sh mode-detect.sh \
              colorset-codegen.sh timing-report.sh timed-run.sh \
              ikxcodegen-scaffold.sh vanilla-scaffold.sh \
              xcodeproj-add-files.sh; do
  path="$SCRIPTS_DIR/$script"
  if [ ! -f "$path" ]; then
    bad "$script missing at $path"
    hint "Re-run scripts/install.sh, or restore from the skill repo"
  elif [ ! -x "$path" ]; then
    bad "$script not executable"
    hint "Fix: chmod +x \"$path\""
  else
    ok "$script present and executable"
  fi
done

# Verify the same scripts are also installed under ~/.claude/scripts/ so the
# stop hook's fallback resolution finds them when the user is running the
# skill in an iOS project unrelated to this repo.
INSTALLED_SCRIPTS_DIR="$HOME/.claude/scripts"
if [ -d "$INSTALLED_SCRIPTS_DIR" ]; then
  for script in c5-capture.sh c5-engine-select.sh \
                c6-asset-completeness.sh c7-no-system-chrome.sh \
                c3-static-checks.sh c3-token-trace.sh c3-driver.sh \
                c3-cross-screen-drift.sh c3-safearea-gate.sh \
                c3-fills-coverage.sh \
                c2-cache-validate.sh c2-extract-design-context.sh \
                c2-build-bbox-index.sh c2-tokens-synthesize.sh \
                c2-typography-extract.sh c2-fills-stops-index.sh \
                c2-prototype-extract.sh \
                c1-probe.sh \
                b0a-extract-copy.sh b0b-tokens-codegen.sh \
                preflight-bundle-verify.sh preflight-smoke-test.sh \
                sync-check.sh mode-detect.sh \
                timing-report.sh timed-run.sh \
                colorset-codegen.sh \
                ikxcodegen-scaffold.sh vanilla-scaffold.sh \
                xcodeproj-add-files.sh; do
    p="$INSTALLED_SCRIPTS_DIR/$script"
    if [ ! -x "$p" ]; then
      bad "$script not installed at $p (stop-gate fallback may miss it)"
      hint "Re-run scripts/install.sh — it copies gate scripts to ~/.claude/scripts/"
    fi
  done
fi

# Shared helper library (_lib/cache-io.sh) for c2-*/c3-* scripts
for lib in cache-io.sh; do
  src_lib="$SCRIPTS_DIR/_lib/$lib"
  if [ ! -f "$src_lib" ]; then
    bad "_lib/$lib missing at $src_lib"
    hint "Restore from the skill repo: scripts/_lib/$lib"
  else
    ok "_lib/$lib present"
  fi
  if [ -d "$INSTALLED_SCRIPTS_DIR" ]; then
    inst_lib="$INSTALLED_SCRIPTS_DIR/_lib/$lib"
    if [ ! -f "$inst_lib" ]; then
      bad "_lib/$lib not installed at $inst_lib"
      hint "Re-run scripts/install.sh — it installs _lib/ alongside gate scripts"
    fi
  fi
done

# Image cropping tool — c5-crop-sections.sh prefers ImageMagick, falls back
# to macOS sips. macOS always ships sips, so this is a soft check that warns
# only when neither is found (rare).
if   command -v magick  >/dev/null 2>&1; then ok "image crop tool: magick (preferred)"
elif command -v convert >/dev/null 2>&1; then ok "image crop tool: convert (ImageMagick)"
elif command -v sips    >/dev/null 2>&1; then ok "image crop tool: sips (macOS built-in)"
else
  bad "no image crop tool found (need magick / convert / sips)"
  hint "Install ImageMagick: brew install imagemagick"
fi

# ── 8. Enforcement hooks ──────────────────────────────────────────────────────
echo
echo "8. Enforcement hooks"
HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS_PATH="$HOME/.claude/settings.json"
EXPECTED_HOOKS=(
  "figma-to-swiftui-gate.sh:PreToolUse"
  "figma-to-swiftui-banned-pattern-gate.sh:PreToolUse"
  "figma-to-swiftui-entry-bypass-gate.sh:PreToolUse"
  "figma-to-swiftui-audit-emit.sh:PostToolUse"
  "figma-to-swiftui-stop-gate.sh:Stop"
)

for entry in "${EXPECTED_HOOKS[@]}"; do
  name="${entry%:*}"
  event="${entry#*:}"
  hook_path="$HOOKS_DIR/$name"

  if [ ! -f "$hook_path" ]; then
    bad "$name missing at $hook_path"
    hint "Run scripts/install.sh (auto-installs hooks), or scripts/install.sh --no-hooks to skip"
    continue
  fi
  if [ ! -x "$hook_path" ]; then
    bad "$name not executable"
    hint "Fix: chmod +x \"$hook_path\""
    continue
  fi

  if [ ! -f "$SETTINGS_PATH" ]; then
    bad "$name installed but $SETTINGS_PATH missing — gate will not fire"
    hint "Run scripts/install.sh to register hooks"
    continue
  fi

  REG=$(python3 - "$SETTINGS_PATH" "$event" "$name" <<'PY' 2>/dev/null
import json, sys, os
path, event, name = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    cfg = json.load(open(path))
except Exception:
    print("ERR")
    sys.exit(0)
expected = os.path.expanduser(f"~/.claude/hooks/{name}")
for b in (cfg.get("hooks", {}).get(event) or []):
    for h in (b.get("hooks") or []):
        cmd = os.path.expanduser(h.get("command", ""))
        if cmd == expected:
            print("OK")
            sys.exit(0)
print("MISSING")
PY
)
  case "$REG" in
    OK)      ok "$name registered ($event)";;
    MISSING) bad "$name installed but NOT registered in settings.json ($event)"
             hint "Run scripts/install.sh to patch settings.json";;
    *)       bad "Could not parse $SETTINGS_PATH"
             hint "Fix the JSON manually, then re-run doctor";;
  esac
done

# ── 9. Drift detection — repo vs installed copies ────────────────────────────
# Catches the "I updated the skill but forgot to re-run install.sh" failure
# mode. Compares sha256 of every script in the repo's scripts/ + scripts/hooks/
# to the corresponding installed copy. Mismatch → warn user to re-run install.
echo
echo "9. Drift between repo and installed copies"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPTS_REPO="$REPO_ROOT/scripts"
HOOKS_REPO="$REPO_ROOT/scripts/hooks"
SCRIPTS_INSTALLED="$HOME/.claude/scripts"
HOOKS_INSTALLED="$HOME/.claude/hooks"

DRIFT_COUNT=0
sha() {
  shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
}

if [ -d "$SCRIPTS_INSTALLED" ]; then
  for src in "$SCRIPTS_REPO"/c1-*.sh "$SCRIPTS_REPO"/c2-*.sh \
             "$SCRIPTS_REPO"/c3-*.sh "$SCRIPTS_REPO"/c5-*.sh \
             "$SCRIPTS_REPO"/c6-*.sh "$SCRIPTS_REPO"/c7-*.sh \
             "$SCRIPTS_REPO"/b0a-*.sh "$SCRIPTS_REPO"/b0b-*.sh \
             "$SCRIPTS_REPO"/preflight-*.sh "$SCRIPTS_REPO"/sync-check.sh \
             "$SCRIPTS_REPO"/mode-detect.sh "$SCRIPTS_REPO"/colorset-codegen.sh \
             "$SCRIPTS_REPO"/timing-report.sh "$SCRIPTS_REPO"/timed-run.sh \
             "$SCRIPTS_REPO"/ikxcodegen-scaffold.sh \
             "$SCRIPTS_REPO"/vanilla-scaffold.sh \
             "$SCRIPTS_REPO"/xcodeproj-add-files.sh; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dst="$SCRIPTS_INSTALLED/$name"
    if [ -f "$dst" ]; then
      if [ "$(sha "$src")" != "$(sha "$dst")" ]; then
        DRIFT_COUNT=$((DRIFT_COUNT+1))
        bad "$name: drift between repo and installed (repo updated, install.sh not re-run)"
        hint "Repo: $src"
        hint "Installed: $dst"
      fi
    else
      DRIFT_COUNT=$((DRIFT_COUNT+1))
      bad "$name: in repo but NOT installed (new script added; install.sh's glob loop never copied it)"
      hint "Repo: $src"
      hint "Expected at: $dst"
      hint "Fix: scripts/install.sh --yes (re-runs install loops to pick up new files)"
    fi
  done
fi

if [ -d "$HOOKS_INSTALLED" ] && [ -d "$HOOKS_REPO" ]; then
  for src in "$HOOKS_REPO"/*.sh; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    dst="$HOOKS_INSTALLED/$name"
    if [ -f "$dst" ]; then
      if [ "$(sha "$src")" != "$(sha "$dst")" ]; then
        DRIFT_COUNT=$((DRIFT_COUNT+1))
        bad "hooks/$name: drift between repo and installed"
        hint "Repo: $src"
        hint "Installed: $dst"
      fi
    fi
  done
fi

if [ "$DRIFT_COUNT" -eq 0 ]; then
  ok "no drift detected — repo and installed copies match"
else
  hint "Fix all drift at once: scripts/install.sh --yes (re-runs the install loops)"
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
