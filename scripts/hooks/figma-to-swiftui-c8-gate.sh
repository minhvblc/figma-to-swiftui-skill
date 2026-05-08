#!/usr/bin/env bash
# PostToolUse hook for Write/Edit on *.swift — write-time C8 coding-conventions
# enforcement. Catches the most-common naming + ViewModel pattern violations
# IMMEDIATELY after the file lands, instead of relying on Pass 5 (in C3) or
# stop-gate (session end) to catch them later.
#
# Pairs with c8-conventions-gate.sh / c8-vm-pattern.sh / c8-func-length.sh /
# c8-iknavigation.sh / c8-ikfont.sh which run at session-end. This hook checks
# only what is cheap and per-file:
#
#   1. Path correctness — *Screen.swift in Subviews/Models/Enums/SubViewModels
#      (banned), parent-Screen file outside Screens/<X>Screen/, top-level files
#      in Screens/<X>Screen/ that aren't -Screen / -ViewModel.
#   2. Subview/Models/Enums prefix — file in <X>Screen/Subviews/ MUST start
#      with <X> prefix.
#   3. ViewModel content — *ViewModel.swift MUST have @MainActor +
#      enum Action + func send(_ action: Action).
#   4. IKNavigation banned APIs — when usesIKNavigation=true, NavigationStack/
#      NavigationLink/.navigationDestination on this file fails.
#   5. IKFont raw .font(.system(size:)) — when ikFontEnum is set, raw fonts
#      without @ScaledMetric fail.
#   6. Per-file function length — > 50 lines hard fail.
#
# Skipped checks (left for stop-gate):
#   - Parent-view existence (Screens/<X>Screen/ MUST contain <X>Screen.swift)
#     because at write-time the file may still be in progress.
#   - weak-self soft check (warn-only, doesn't block).
#
# Triggers only inside a figma task — i.e. there's a .figma-cache/ in the
# file's tree (walking up). Files outside such a tree skip silently.
#
# Exit codes:
#   0 — allow
#   2 — block (stderr is shown to Claude as a system reminder)

set -uo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

# Only Write/Edit on .swift; no-op otherwise.
case "$TOOL" in Write|Edit) ;; *) exit 0 ;; esac
[[ "$FILE_PATH" == *.swift ]] || exit 0
[ -f "$FILE_PATH" ] || exit 0

# Walk up from the file to find .figma-cache/ — only enforce inside a figma task.
PROJECT_ROOT=""
D=$(dirname "$FILE_PATH")
for _ in 1 2 3 4 5 6 7 8; do
  if [ -d "$D/.figma-cache" ]; then
    PROJECT_ROOT="$D"
    break
  fi
  PARENT=$(dirname "$D")
  [ "$PARENT" = "$D" ] && break
  D="$PARENT"
done
[ -z "$PROJECT_ROOT" ] && exit 0

# Track this file in session-files.json (idempotent append). Stop-gate reads
# this list to scope C8 gates to ONLY what the agent generated this session,
# instead of project-wide which would flag pre-existing tech debt.
#
# File: <PROJECT_ROOT>/.figma-cache/session-files.json
#       { "files": ["abs/path/A.swift", "abs/path/B.swift"] }
SESSION_FILES_JSON="$PROJECT_ROOT/.figma-cache/session-files.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$SESSION_FILES_JSON" "$FILE_PATH" <<'PY' 2>/dev/null || true
import json, os, sys
path, file_path = sys.argv[1], sys.argv[2]
data = {"files": []}
if os.path.isfile(path):
    try:
        data = json.load(open(path))
        if not isinstance(data, dict) or "files" not in data:
            data = {"files": []}
    except Exception:
        data = {"files": []}
files = data.get("files") or []
if file_path not in files:
    files.append(file_path)
data["files"] = files
os.makedirs(os.path.dirname(path), exist_ok=True)
json.dump(data, open(path, "w"), indent=2)
PY
fi

# Locate c1-conventions.json (flow uses _shared/, single-screen uses screen dir).
CONV=""
[ -f "$PROJECT_ROOT/.figma-cache/_shared/c1-conventions.json" ] \
  && CONV="$PROJECT_ROOT/.figma-cache/_shared/c1-conventions.json"
if [ -z "$CONV" ]; then
  shopt -s nullglob
  for d in "$PROJECT_ROOT"/.figma-cache/*/; do
    [ -f "$d/c1-conventions.json" ] && CONV="$d/c1-conventions.json" && break
  done
  shopt -u nullglob
fi

# Defaults — when no conventions JSON exists, assume screen-based + no IK
# (so naming/path checks still fire; conditional checks skip).
LAYOUT="screen-based"
USES_IK="false"
IKFONT="null"
if [ -n "$CONV" ] && [ -f "$CONV" ]; then
  v=$(grep -oE '"screenFolderConvention"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONV" \
        | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)
  [ -n "$v" ] && LAYOUT="$v"
  v=$(grep -oE '"usesIKNavigation"[[:space:]]*:[[:space:]]*(true|false)' "$CONV" \
        | sed -E 's/.*:[[:space:]]*(true|false).*/\1/' | head -n1)
  [ -n "$v" ] && USES_IK="$v"
  v=$(grep -oE '"ikFontEnum"[[:space:]]*:[[:space:]]*(null|"[^"]+")' "$CONV" \
        | sed -E 's/.*:[[:space:]]*(null|"[^"]*").*/\1/' | head -n1)
  [ -n "$v" ] && IKFONT="$v"
fi

# Skip everything when project uses flat layout — naming/path rules don't apply.
if [ "$LAYOUT" = "flat" ]; then
  exit 0
fi

# ── Compute path facets relative to PROJECT_ROOT ─────────────────────────────
rel="${FILE_PATH#$PROJECT_ROOT/}"
base="$(basename "$FILE_PATH" .swift)"
parent_dir="$(dirname "$rel")"
parent_name="$(basename "$parent_dir")"
grandparent="$(basename "$(dirname "$parent_dir")")"

VIOLATIONS=""

# ── 1. Path correctness ─────────────────────────────────────────────────────

# 1a. -Screen suffix in subview folders → suffix misuse
if [[ "$base" == *Screen ]] && [[ "$base" != *Screens ]]; then
  case "$parent_name" in
    Subviews|Models|Enums|SubViewModels)
      VIOLATIONS+="${rel}: '-Screen' suffix is reserved for parent (full-screen) views; subviews use '-View' suffix (project-structure.md §3)\n"
      ;;
    *)
      # 1b. -Screen file but NOT at Screens/<X>Screen/<X>Screen.swift
      if [[ "$parent_name" != "$base" ]] || [[ "$grandparent" != "Screens" ]]; then
        VIOLATIONS+="${rel}: parent-view '${base}.swift' should live at Screens/${base}/${base}.swift\n"
      fi
      ;;
  esac
fi

# 1c. Top-level file in Screens/<X>Screen/ MUST end with -Screen or -ViewModel.
#     Anything else (e.g. HomeView.swift sitting at the screen folder root)
#     means the agent named a parent view incorrectly OR placed a subview at
#     the wrong level.
if [[ "$grandparent" == "Screens" ]] && [[ "$parent_name" == *Screen ]]; then
  case "$base" in
    *Screen|*ViewModel) ;;
    *)
      VIOLATIONS+="${rel}: top-level file in Screens/${parent_name}/ must end with '-Screen' (parent view) or '-ViewModel'; subviews go in Subviews/\n"
      ;;
  esac
fi

# 2. Subview prefix rule — files in <X>Screen/Subviews/ etc. start with <X>
case "$parent_name" in
  Subviews|Models|Enums|SubViewModels)
    screen_folder="$(basename "$(dirname "$parent_dir")")"
    screen_prefix="${screen_folder%Screen}"
    if [[ -n "$screen_prefix" ]] && [[ "$base" != ${screen_prefix}* ]]; then
      VIOLATIONS+="${rel}: file in '${parent_name}/' must start with screen prefix '${screen_prefix}' (got: ${base})\n"
    fi
    ;;
esac

# 3. Suffix / type-declaration agreement
if [[ "$base" == *Screen ]] && [[ "$base" != *Screens ]] \
     && ! grep -qE "(struct|class)[[:space:]]+${base}\b" "$FILE_PATH"; then
  VIOLATIONS+="${rel}: '${base}.swift' should declare a type named '${base}'\n"
fi
if [[ "$base" == *ViewModel ]] \
     && ! grep -qE "(class|final[[:space:]]+class|@Observable[[:space:]]+(@MainActor[[:space:]]+)?(final[[:space:]]+)?class)[[:space:]]+${base}\b" "$FILE_PATH"; then
  VIOLATIONS+="${rel}: '${base}.swift' should declare a class named '${base}'\n"
fi
if [[ "$base" == *View ]] && [[ "$base" != *Screen ]] \
     && ! grep -qE "struct[[:space:]]+${base}\b" "$FILE_PATH"; then
  VIOLATIONS+="${rel}: '${base}.swift' should declare a struct named '${base}'\n"
fi

# ── 4. ViewModel content checks (only when *ViewModel.swift) ────────────────
if [[ "$base" == *ViewModel ]]; then
  if ! grep -qE '@MainActor' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: ViewModel must be annotated @MainActor (viewmodel-pattern.md §3d)\n"
  fi
  if ! grep -qE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+)?enum[[:space:]]+Action\b' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: ViewModel must declare nested 'enum Action' (viewmodel-pattern.md §3b)\n"
  fi
  if ! grep -qE 'func[[:space:]]+send\([[:space:]]*_[[:space:]]+action[[:space:]]*:[[:space:]]*Action[[:space:]]*\)' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: ViewModel must declare 'func send(_ action: Action)' (viewmodel-pattern.md §1)\n"
  fi
  # Route enum required when 'route' / 'dismissRoute' is referenced
  if grep -qE '\b(route|dismissRoute)\b' "$FILE_PATH" \
       && ! grep -qE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+)?enum[[:space:]]+Route\b' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: ViewModel references 'route' but has no nested 'enum Route' (viewmodel-pattern.md §3c)\n"
  fi
  # Banned: per-method @MainActor when class-level missing
  if grep -qE '^[[:space:]]*@MainActor[[:space:]]+func\b' "$FILE_PATH" \
       && ! grep -qE '@MainActor[[:space:]]+(final[[:space:]]+)?(class|@Observable)' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: prefer class-level @MainActor over per-method (viewmodel-pattern.md §3d)\n"
  fi
fi

# ── 5. IKNavigation banned APIs (only when usesIKNavigation=true) ───────────
if [ "$USES_IK" = "true" ]; then
  if grep -qE '\bNavigationStack[[:space:]]*[({]' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: NavigationStack banned in IKNavigation projects — use @Environment(\\.ikNavigationable) (iknavigation-bridge.md §7)\n"
  fi
  if grep -qE '\bNavigationLink[[:space:]]*[({]' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: NavigationLink banned in IKNavigation projects — use navigation.push(to:) (iknavigation-bridge.md §7)\n"
  fi
  if grep -qE '\.navigationDestination[[:space:]]*\(' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: .navigationDestination banned in IKNavigation projects — IKNavigation handles destination resolution (iknavigation-bridge.md §7)\n"
  fi
fi

# ── 6. IKFont raw fonts (only when ikFontEnum is set) ───────────────────────
if [ "$IKFONT" != "null" ] && [ -n "$IKFONT" ]; then
  IKFONT_NAME=$(printf '%s' "$IKFONT" | sed -E 's/^"//;s/"$//')
  if grep -qE '\.font\([[:space:]]*\.system\([[:space:]]*size:' "$FILE_PATH" \
       && ! grep -qE '@ScaledMetric' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: raw .font(.system(size:)) — use ${IKFONT_NAME}.<token> (swiftui-pro-bridge.md §7)\n"
  fi
  if grep -qE 'Font\.custom\(' "$FILE_PATH"; then
    VIOLATIONS+="${rel}: Font.custom() banned when ${IKFONT_NAME} enum exists (swiftui-pro-bridge.md §7)\n"
  fi
fi

# ── 7. Per-file function-length check (hard fail at 50 lines) ────────────────
# Inline implementation — no script-path resolution needed. SwiftUI body is
# exempt because it's a `var`, not a `func`.
LONG=$(awk -v file="$rel" -v warn=30 -v fail=50 '
  function count_char(s, ch,    n, i) {
    n = 0
    for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == ch) n++
    return n
  }
  BEGIN { in_func=0; func_start=0; func_name=""; func_body=0; brace_depth=0 }
  {
    line = $0
    if (in_func == 0) {
      if (line ~ /[[:space:]]func[[:space:]]+[A-Za-z_]/ || line ~ /^func[[:space:]]+[A-Za-z_]/) {
        tail = line
        sub(/.*func[[:space:]]+/, "", tail)
        name = tail
        gsub(/[^A-Za-z0-9_].*$/, "", name)
        func_name = (name == "" ? "?" : name)
        func_start = NR
        func_body = 0
        in_func = 1
        n_open = count_char(line, "{")
        n_close = count_char(line, "}")
        brace_depth = (n_open > 0 ? n_open - n_close : 0)
        if (n_open > 0 && brace_depth <= 0) { in_func = 0; brace_depth = 0 }
        next
      }
      next
    }
    if (brace_depth == 0) {
      n_open = count_char(line, "{")
      n_close = count_char(line, "}")
      if (n_open > 0) brace_depth = n_open - n_close
      next
    }
    func_body++
    n_open = count_char(line, "{")
    n_close = count_char(line, "}")
    brace_depth += (n_open - n_close)
    if (brace_depth <= 0) {
      if (func_body >= fail) printf("%s:%d: function %s exceeds %d lines (%d) — swift-style.md §2\n", file, func_start, func_name, fail, func_body)
      in_func = 0
      brace_depth = 0
      func_name = ""
    }
  }
' "$FILE_PATH")
if [ -n "$LONG" ]; then
  VIOLATIONS+="${LONG}\n"
fi

# ── Report ──────────────────────────────────────────────────────────────────
if [ -n "$VIOLATIONS" ]; then
  {
    echo "C8 coding-conventions violations in just-written file:"
    printf "%b" "$VIOLATIONS"
    echo ""
    echo "Fix the file, then re-Write/Edit. References:"
    echo "  - figma-to-swiftui/references/project-structure.md  (folder + naming)"
    echo "  - figma-to-swiftui/references/viewmodel-pattern.md  (Action + send + @MainActor)"
    echo "  - figma-to-swiftui/references/swift-style.md         (function size, golden path)"
    if [ "$USES_IK" = "true" ]; then
      echo "  - figma-to-swiftui/references/iknavigation-bridge.md (active — usesIKNavigation=true)"
    fi
    if [ "$IKFONT" != "null" ] && [ -n "$IKFONT" ]; then
      echo "  - figma-to-swiftui/references/swiftui-pro-bridge.md §7 (active — ikFontEnum=${IKFONT})"
    fi
  } >&2
  exit 2
fi

exit 0
