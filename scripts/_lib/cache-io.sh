#!/usr/bin/env bash
# _lib/cache-io.sh — atomic write + integrity helpers for .figma-cache/ writers.
#
# Source from any script that writes cache artifacts:
#   source "$(dirname "$0")/_lib/cache-io.sh"
#
# Why atomic: Ctrl-C / kill -9 mid-write produces half-formed JSON. L2 then
# JSON-decode-errors. Tmp-write + rename keeps the file at either fully-old
# or fully-new state — never partial.
#
# Exposed functions:
#   write_atomic <path> <content>             — write content to path atomically
#   write_atomic_stdin <path>                 — write stdin to path atomically
#   write_json_atomic <path> <json>           — same + validate JSON parses first
#   read_cache_safe <path>                    — cat $path; returns "" if missing
#   emit_status <cache-dir> <phase> <name> <status> [<key>=<val>...]
#                                              — update _status.json artifact entry
#   cache_age_days <cache-dir>                — print float days since oldest mtime
#   ensure_cache_dir <path>                   — mkdir -p; verify writable
#
# Reads no env vars. POSIX-compatible (macOS BSD utilities).

# ── write_atomic <path> <content> ─────────────────────────────────────────────
write_atomic() {
  local path="$1"
  local content="$2"
  local dir tmp
  dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="${path}.tmp.$$"
  printf '%s' "$content" > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
  return 0
}

# ── write_atomic_stdin <path> ─────────────────────────────────────────────────
# Reads stdin, writes atomically. Use when content is large or piped from another tool.
write_atomic_stdin() {
  local path="$1"
  local dir tmp
  dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="${path}.tmp.$$"
  cat > "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
  return 0
}

# ── write_json_atomic <path> <json> ──────────────────────────────────────────
# Validate JSON parses before renaming. Refuses to write garbage.
write_json_atomic() {
  local path="$1"
  local json="$2"
  local dir tmp
  dir="$(dirname "$path")"
  [ -d "$dir" ] || mkdir -p "$dir"
  tmp="${path}.tmp.$$"
  printf '%s' "$json" > "$tmp" || { rm -f "$tmp"; return 1; }
  # Validate JSON
  if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "write_json_atomic: invalid JSON, refusing to write $path" >&2
    return 1
  fi
  mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
  return 0
}

# ── read_cache_safe <path> ───────────────────────────────────────────────────
read_cache_safe() {
  local path="$1"
  [ -f "$path" ] && [ -r "$path" ] && cat "$path"
  return 0
}

# ── emit_status <cache-dir> <phase> <name> <status> [key=val...] ─────────────
# Update .figma-cache/<nodeId>/_status.json with an artifact entry.
# Phase: "phaseA" | "phaseB". Name: artifact filename (e.g. "tokens.json").
# Status: "done" | "failed" | "partial" | "missing".
# Extra fields: any number of key=val pairs added to the entry.
#
# Atomic: read existing _status.json, modify in memory, write tmp+rename.
emit_status() {
  local cache_dir="$1"; shift
  local phase="$1";    shift
  local name="$1";     shift
  local entry_status="$1"; shift   # avoid 'status' — zsh reserves it
  # Remaining args are key=val extras
  local status_path="$cache_dir/_status.json"
  python3 - "$status_path" "$phase" "$name" "$entry_status" "$@" <<'PY' 2>/dev/null
import json, os, sys, hashlib
from datetime import datetime, timezone

path, phase, name, entry_status, *extras = sys.argv[1:]

try:
    with open(path) as f:
        data = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    data = {"schemaVersion": 1, "phaseA": {}, "phaseB": {}}

data.setdefault("schemaVersion", 1)
data.setdefault("phaseA", {})
data.setdefault("phaseB", {})

entry = data.get(phase, {}).get(name, {}) or {}
entry["status"] = entry_status
entry["writtenAt"] = datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')

# Auto-compute sha256 + size if artifact exists on disk
cache_dir = os.path.dirname(path)
artifact_path = os.path.join(cache_dir, name)
if os.path.exists(artifact_path) and os.path.isfile(artifact_path):
    try:
        with open(artifact_path, "rb") as f:
            content = f.read()
        entry["sha256"] = hashlib.sha256(content).hexdigest()
        entry["size"] = len(content)
    except Exception:
        pass

# Apply key=val extras (parse as JSON value when possible)
for kv in extras:
    if "=" not in kv:
        continue
    k, v = kv.split("=", 1)
    try:
        entry[k] = json.loads(v)
    except json.JSONDecodeError:
        entry[k] = v

data[phase][name] = entry

tmp = path + ".tmp." + str(os.getpid())
os.makedirs(os.path.dirname(tmp), exist_ok=True)
with open(tmp, "w") as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
PY
  return $?
}

# ── cache_age_days <cache-dir> ──────────────────────────────────────────────
# Print floating-point days since oldest cache file's mtime. Empty cache = 0.
cache_age_days() {
  local dir="$1"
  [ -d "$dir" ] || { echo "0"; return 0; }
  python3 - "$dir" <<'PY' 2>/dev/null
import os, sys, time
root = sys.argv[1]
oldest = None
for f in os.listdir(root):
    p = os.path.join(root, f)
    if os.path.isfile(p):
        m = os.path.getmtime(p)
        if oldest is None or m < oldest:
            oldest = m
if oldest is None:
    print("0")
else:
    age_days = (time.time() - oldest) / 86400
    print(f"{age_days:.2f}")
PY
}

# ── ensure_cache_dir <path> ─────────────────────────────────────────────────
ensure_cache_dir() {
  local path="$1"
  mkdir -p "$path" 2>/dev/null
  if [ ! -d "$path" ] || [ ! -w "$path" ]; then
    echo "ensure_cache_dir: cannot create/write $path" >&2
    return 1
  fi
  return 0
}
