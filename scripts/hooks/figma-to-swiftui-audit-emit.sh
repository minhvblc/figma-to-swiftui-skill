#!/usr/bin/env bash
# PostToolUse hook for Write/Edit on *Screen.swift / *View.swift — emits one
# row per (color, font, padding, frame, image, text, stack) into
# .figma-cache/<nodeId>/c2-audit.json via the figma-audit SwiftSyntax binary.
#
# Lives at: scripts/hooks/figma-to-swiftui-audit-emit.sh
# Installed at: ~/.claude/hooks/figma-to-swiftui-audit-emit.sh
# Registered: PostToolUse matcher Write|Edit (install.sh GATES list)
#
# Scope:
#   - File must end in Screen.swift OR View.swift
#   - Must NOT be *ViewModel.swift, *Action.swift, *State.swift,
#     *Preview.swift, *Tests.swift, *Route.swift, *Type.swift
#   - Content must declare `struct …: View` (catches subviews; rejects
#     non-view View.swift files like UIView wrappers in odd projects)
#   - Must be inside a Figma task (same transcript probe banned-pattern uses)
#   - tool_response.success must be true (don't audit a rejected Write)
#
# Failure mode contract:
#   - Hook MUST NOT block. PostToolUse runs after the write — blocking is
#     pointless. Exit 0 on every path so the user's Write completes.
#   - Parser missing / parse error / lock contention → WARN to stderr,
#     emit a marker row `{parserMode: "regex-fallback"|"missing"}`.
#     The L2 trace script reads parserMode and fails its gate if degraded.
#
# Exit codes:
#   0 — always

set -uo pipefail

# ── Helper: emit degraded marker (parser missing / parse error) ─────────────
# Defined first so the main flow below can call it.
emit_degraded_marker() {
  local audit_path="$1"
  local node_id="$2"
  local file_path="$3"
  local reason="$4"
  python3 - "$audit_path" "$node_id" "$file_path" "$reason" <<'PY' 2>/dev/null
import json, os, sys
from datetime import datetime, timezone

audit_path, node_id, file_path, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    with open(audit_path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {
        "schemaVersion": 2,
        "nodeId": node_id,
        "generatedAt": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        "parserMode": "regex-fallback",
        "parserVersion": "0.0.0",
        "files": {},
    }

data["generatedAt"] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
data["parserMode"] = "regex-fallback" if reason == "parse_error" else "missing"

# Relative path heuristic mirrors the Swift parser's relativeFilePath()
rel = os.path.basename(file_path)
for marker in ["/Sources/", "/Screens/", "/App/", "/Features/"]:
    idx = file_path.find(marker)
    if idx >= 0:
        rel = file_path[idx+1:]
        break

data.setdefault("files", {})
prior = data["files"].get(rel, {}) or {}
data["files"][rel] = {
    "sha256": "",
    "writeCount": int(prior.get("writeCount", 0)) + 1,
    "lastWriteAt": datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
    "unknownModifierCount": 999,
    "unknownNodeTypes": [reason],
    "totalViewDecls": 0,
    "knownModifierCount": 0,
    "rows": [],
}
os.makedirs(os.path.dirname(audit_path), exist_ok=True)
tmp_path = audit_path + ".tmp." + str(os.getpid())
with open(tmp_path, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp_path, audit_path)
PY
}

# ── 0. Parse input ────────────────────────────────────────────────────────────
INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SUCCESS=$(printf '%s' "$INPUT" | jq -r '.tool_response.success // false' 2>/dev/null)

# ── 1. Quick filters ──────────────────────────────────────────────────────────
[ "$SUCCESS" = "true" ] || exit 0
[ -n "$FILE_PATH" ]     || exit 0

# Suffix filter: in-scope vs skipped.
# Order matters — skip suffixes are checked first so e.g. LoginViewModel.swift
# (ends with View.swift too if you squint) isn't audited.
case "$FILE_PATH" in
  *ViewModel.swift|*Action.swift|*State.swift|*Route.swift|*Type.swift|*Preview.swift|*Tests.swift|*Test.swift|*_NoFigma_*)
    exit 0
    ;;
  *Screen.swift|*View.swift)
    ;;
  *)
    exit 0
    ;;
esac

# ── 2. Figma task gate (reuse probe shared with banned-pattern-gate.sh) ──────
PROBE="$(dirname "$0")/_figma-task-probe.sh"
IS_FIGMA="no"
if [ -x "$PROBE" ]; then
  IS_FIGMA=$(printf '%s' "$INPUT" | "$PROBE" 2>/dev/null || echo "no")
fi
[ "$IS_FIGMA" = "yes" ] || exit 0

# ── 3. Locate the screen cache (.figma-cache/<nodeId>/) ──────────────────────
find_screen_cache() {
  local dir
  dir="$(dirname "$FILE_PATH")"
  while [ "$dir" != "/" ] && [ "$dir" != "" ]; do
    if [ -d "$dir/.figma-cache" ]; then
      local cache_root="$dir/.figma-cache"
      local latest
      latest=$(find "$cache_root" -mindepth 1 -maxdepth 1 -type d ! -name "_shared" 2>/dev/null \
        | xargs -I{} stat -f "%m %N" {} 2>/dev/null \
        | sort -rn | head -1 | awk '{print $2}')
      if [ -n "$latest" ] && [ -d "$latest" ]; then
        printf '%s\n' "$latest"
        return 0
      fi
    fi
    dir="$(dirname "$dir")"
  done
  return 1
}

CACHE_DIR=$(find_screen_cache)
[ -z "$CACHE_DIR" ] && exit 0

AUDIT_PATH="$CACHE_DIR/c2-audit.json"
NODE_ID=$(basename "$CACHE_DIR")

# ── 4. File must exist + declare `struct ...: View` ─────────────────────────
[ -f "$FILE_PATH" ] || exit 0

if ! grep -qE 'struct[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*:[[:space:]]*View' "$FILE_PATH" 2>/dev/null; then
  exit 0
fi

# ── 5. Locate the figma-audit binary ─────────────────────────────────────────
AUDIT_BIN="$HOME/.local/share/figma-audit/bin/figma-audit"
if [ ! -x "$AUDIT_BIN" ]; then
  printf '[figma-audit-emit] WARN: %s missing — emitting degraded marker for %s\n' \
    "$AUDIT_BIN" "$FILE_PATH" >&2
  emit_degraded_marker "$AUDIT_PATH" "$NODE_ID" "$FILE_PATH" "binary_missing"
  exit 0
fi

# ── 6. Acquire lock ──────────────────────────────────────────────────────────
# macOS-portable lock via mkdir (atomic). flock(1) isn't on macOS by default.
LOCK_DIR="$CACHE_DIR/.audit.lock.dir"
LOCK_HELD=0

acquire_lock() {
  local tries=10
  while [ $tries -gt 0 ]; do
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$LOCK_DIR/pid"
      LOCK_HELD=1
      return 0
    fi
    sleep 0.5
    tries=$((tries - 1))
  done
  return 1
}

cleanup() {
  [ "$LOCK_HELD" = "1" ] && rm -rf "$LOCK_DIR"
  [ -n "${TMP_OUT:-}" ] && rm -f "$TMP_OUT"
}
trap cleanup EXIT

if ! acquire_lock; then
  printf '[figma-audit-emit] WARN: lock contention on %s — skipping audit emit for %s\n' \
    "$CACHE_DIR" "$FILE_PATH" >&2
  exit 0
fi

# ── 7. Parse the file via figma-audit binary ────────────────────────────────
TMP_OUT=$(mktemp -t figma-audit.XXXXXX)

if [ -f "$AUDIT_PATH" ]; then
  if ! "$AUDIT_BIN" --in "$FILE_PATH" --out "$TMP_OUT" \
        --node-id "$NODE_ID" --merge-into "$AUDIT_PATH" 2>/dev/null; then
    printf '[figma-audit-emit] WARN: parser failed on %s\n' "$FILE_PATH" >&2
    emit_degraded_marker "$AUDIT_PATH" "$NODE_ID" "$FILE_PATH" "parse_error"
    exit 0
  fi
else
  if ! "$AUDIT_BIN" --in "$FILE_PATH" --out "$TMP_OUT" \
        --node-id "$NODE_ID" 2>/dev/null; then
    printf '[figma-audit-emit] WARN: parser failed on %s\n' "$FILE_PATH" >&2
    emit_degraded_marker "$AUDIT_PATH" "$NODE_ID" "$FILE_PATH" "parse_error"
    exit 0
  fi
fi

# Atomic move
if [ -s "$TMP_OUT" ]; then
  mv -f "$TMP_OUT" "$AUDIT_PATH"
fi

exit 0
