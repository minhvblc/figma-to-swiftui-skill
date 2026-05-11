#!/usr/bin/env bash
# PostToolUse hook for Write/Edit on *.swift — write-time C8 coding-conventions
# enforcement.
#
# Improvements in this revision:
#   P0-5: Terse output. Default emits ≤ 1 line per violation + 1 doc URL.
#         Set HOOK_VERBOSE=1 for full reference block.
#   P0-6: Reads ALL fields from c1-conventions.json — mode, featureRoot,
#         viewModelPattern, usesIK* cascade — not just 3 like before.
#   P1-3: Mode-aware. When mode == "scaffold" in conventions, every block
#         becomes a WARN (printed to stderr but exit 0). Lets a greenfield
#         scaffold run land code with TODO placeholders without hitting
#         every gate up-front. mode == "production" is the strict default.
#
# Original responsibilities preserved:
#   1. Path correctness for screen-based / ikame-feature-flat / flat layouts
#   2. Subview prefix rule
#   3. ViewModel content (@MainActor + enum Action + send(_:))
#   4. IKNavigation banned APIs
#   5. IKFont raw .font(.system(size:)) when ikFontEnum is set
#   6. Per-file function length > 50 lines
#
# Triggers only inside a figma task — i.e. there's a .figma-cache/ in the
# file's tree (walking up). Files outside such a tree skip silently.
#
# Exit codes:
#   0 — allow (also used for scaffold-mode warnings, with stderr message)
#   2 — block

set -uo pipefail

INPUT=$(cat)

TOOL=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)

case "$TOOL" in Write|Edit) ;; *) exit 0 ;; esac
[[ "$FILE_PATH" == *.swift ]] || exit 0
[ -f "$FILE_PATH" ] || exit 0

# Walk up from the file to find .figma-cache/.
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

# Track this file in session-files.json (unchanged).
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

# Locate c1-conventions.json.
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

# ── P0-6: parse all relevant fields. Defaults match the legacy hook behavior
#         (production mode, screen-based, no IK) so existing projects don't
#         break silently.
LAYOUT="screen-based"
USES_IK="false"
IKFONT="null"
MODE="production"
FEATURE_ROOT="Screens"
if [ -n "$CONV" ] && [ -f "$CONV" ]; then
  # Helper: pull "key": "value" or "key": bool. We use python where jq might
  # not have been built with optional support; falls back to grep otherwise.
  if command -v python3 >/dev/null 2>&1; then
    eval "$(python3 - "$CONV" <<'PY' 2>/dev/null
import json, sys, shlex
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
def emit(name, val):
    print(f"{name}={shlex.quote(str(val))}")
for key, var in [
    ("screenFolderConvention", "LAYOUT"),
    ("usesIKNavigation", "USES_IK"),
    ("ikFontEnum", "IKFONT"),
    ("mode", "MODE"),
    ("featureRoot", "FEATURE_ROOT"),
]:
    if key in data and data[key] is not None:
        v = data[key]
        if isinstance(v, bool):
            emit(var, "true" if v else "false")
        else:
            emit(var, v)
PY
    )"
  else
    # grep fallback (legacy path)
    v=$(grep -oE '"screenFolderConvention"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONV" | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)
    [ -n "$v" ] && LAYOUT="$v"
    v=$(grep -oE '"usesIKNavigation"[[:space:]]*:[[:space:]]*(true|false)' "$CONV" | sed -E 's/.*:[[:space:]]*(true|false).*/\1/' | head -n1)
    [ -n "$v" ] && USES_IK="$v"
    v=$(grep -oE '"ikFontEnum"[[:space:]]*:[[:space:]]*(null|"[^"]+")' "$CONV" | sed -E 's/.*:[[:space:]]*(null|"[^"]*").*/\1/' | head -n1)
    [ -n "$v" ] && IKFONT="$v"
    v=$(grep -oE '"mode"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONV" | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)
    [ -n "$v" ] && MODE="$v"
    v=$(grep -oE '"featureRoot"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONV" | sed -E 's/.*"([^"]+)"$/\1/' | head -n1)
    [ -n "$v" ] && FEATURE_ROOT="$v"
  fi
fi

# Strip trailing slash and split FEATURE_ROOT path. The last component is what
# c8 compares as "grandparent" in path rules. Eg. featureRoot=BibleApp/Screens
# → SCREENS_BASENAME=Screens.
FEATURE_ROOT="${FEATURE_ROOT%/}"
SCREENS_BASENAME="$(basename "$FEATURE_ROOT")"

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
greatgrand="$(basename "$(dirname "$(dirname "$parent_dir")")")"

VIOLATIONS=""
add_violation() { VIOLATIONS+="  $1\n"; }

# ── 1. Path correctness ─────────────────────────────────────────────────────
if [ "$LAYOUT" = "ikame-feature-flat" ]; then
  if [[ "$base" == *Screen ]] && [[ "$base" != *Screens ]] && [[ "$base" != *+* ]]; then
    case "$parent_name" in
      Subviews|ViewModel|Models)
        add_violation "$rel: '-Screen' suffix reserved for parent views (project-structure.md §2)"
        ;;
      *)
        if [[ "$grandparent" != "$SCREENS_BASENAME" ]]; then
          add_violation "$rel: screen view should live at $SCREENS_BASENAME/<Feature>/$base.swift (got grandparent: $grandparent)"
        fi
        ;;
    esac
  fi
  if [[ "$base" == *ViewModel ]]; then
    if [[ "$parent_name" != "ViewModel" ]]; then
      add_violation "$rel: ViewModel should live at $SCREENS_BASENAME/<Feature>/ViewModel/$base.swift"
    fi
  fi
  if [[ "$parent_name" == "Subviews" ]] && [[ "$greatgrand" == "$SCREENS_BASENAME" ]]; then
    feature_folder="$(basename "$(dirname "$parent_dir")")"
    if [[ "$base" != ${feature_folder}* ]]; then
      add_violation "$rel: subview should start with feature folder '${feature_folder}'"
    fi
  fi
else
  # screen-based branch (default)
  if [[ "$base" == *Screen ]] && [[ "$base" != *Screens ]]; then
    case "$parent_name" in
      Subviews|Models|Enums|SubViewModels)
        add_violation "$rel: '-Screen' suffix reserved for parent views"
        ;;
      *)
        if [[ "$parent_name" != "$base" ]] || [[ "$grandparent" != "$SCREENS_BASENAME" ]]; then
          add_violation "$rel: parent-view should live at $SCREENS_BASENAME/$base/$base.swift"
        fi
        ;;
    esac
  fi
  if [[ "$grandparent" == "$SCREENS_BASENAME" ]] && [[ "$parent_name" == *Screen ]]; then
    case "$base" in
      *Screen|*ViewModel) ;;
      *)
        add_violation "$rel: top-level file in $SCREENS_BASENAME/$parent_name/ must end with '-Screen' or '-ViewModel'"
        ;;
    esac
  fi
  case "$parent_name" in
    Subviews|Models|Enums|SubViewModels)
      screen_folder="$(basename "$(dirname "$parent_dir")")"
      screen_prefix="${screen_folder%Screen}"
      if [[ -n "$screen_prefix" ]] && [[ "$base" != ${screen_prefix}* ]]; then
        add_violation "$rel: file in $parent_name/ must start with prefix '$screen_prefix'"
      fi
      ;;
  esac
fi

# 3. Suffix / type-declaration agreement
if [[ "$base" == *Screen ]] && [[ "$base" != *Screens ]] \
     && ! grep -qE "(struct|class)[[:space:]]+${base}\b" "$FILE_PATH"; then
  add_violation "$rel: '$base.swift' should declare a type named '$base'"
fi
if [[ "$base" == *ViewModel ]] \
     && ! grep -qE "(class|final[[:space:]]+class|@Observable[[:space:]]+(@MainActor[[:space:]]+)?(final[[:space:]]+)?class)[[:space:]]+${base}\b" "$FILE_PATH"; then
  add_violation "$rel: '$base.swift' should declare a class named '$base'"
fi
if [[ "$base" == *View ]] && [[ "$base" != *Screen ]] \
     && ! grep -qE "struct[[:space:]]+${base}\b" "$FILE_PATH"; then
  add_violation "$rel: '$base.swift' should declare a struct named '$base'"
fi

# 3b. #Preview block required in parent *Screen.swift files.
# Engine A (xcode MCP RenderPreview) snapshots the file's top-level #Preview
# directly — without it, C5 falls back to the slower xcodebuild/simctl path
# and the user pays the SPM-resolve + simctl-cold-start penalty. SKILL.md C2
# critical rules mandate this. Subviews (under Subviews/) and ViewModels are
# exempt — #Preview is only required on the parent screen file.
if [[ "$base" == *Screen ]] && [[ "$base" != *Screens ]] \
     && [[ "$parent_name" != "Subviews" ]] \
     && [[ "$parent_name" != "Models" ]] \
     && [[ "$parent_name" != "Enums" ]] \
     && [[ "$parent_name" != "SubViewModels" ]] \
     && ! grep -qE '^[[:space:]]*#Preview[[:space:]]*\{?' "$FILE_PATH"; then
  add_violation "$rel: missing top-level '#Preview { … }' block (required for C5 Engine A RenderPreview — see SKILL.md §C2)"
fi

# ── 4. ViewModel content checks ─────────────────────────────────────────────
if [[ "$base" == *ViewModel ]]; then
  if ! grep -qE '@MainActor' "$FILE_PATH"; then
    add_violation "$rel: ViewModel must be @MainActor (viewmodel-pattern.md §3d)"
  fi
  if ! grep -qE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+)?enum[[:space:]]+Action\b' "$FILE_PATH"; then
    add_violation "$rel: ViewModel must declare 'enum Action' (viewmodel-pattern.md §3b)"
  fi
  if ! grep -qE 'func[[:space:]]+send\([[:space:]]*_[[:space:]]+action[[:space:]]*:[[:space:]]*Action[[:space:]]*\)' "$FILE_PATH"; then
    add_violation "$rel: ViewModel must declare 'func send(_ action: Action)' (viewmodel-pattern.md §1)"
  fi
  if grep -qE '\b(route|dismissRoute)\b' "$FILE_PATH" \
       && ! grep -qE '^[[:space:]]*(public[[:space:]]+|private[[:space:]]+|fileprivate[[:space:]]+|internal[[:space:]]+)?enum[[:space:]]+Route\b' "$FILE_PATH"; then
    add_violation "$rel: ViewModel references 'route' but has no 'enum Route' (viewmodel-pattern.md §3c)"
  fi
  if grep -qE '^[[:space:]]*@MainActor[[:space:]]+func\b' "$FILE_PATH" \
       && ! grep -qE '@MainActor[[:space:]]+(final[[:space:]]+)?(class|@Observable)' "$FILE_PATH"; then
    add_violation "$rel: prefer class-level @MainActor over per-method (viewmodel-pattern.md §3d)"
  fi
fi

# ── 5. IKNavigation banned APIs ─────────────────────────────────────────────
if [ "$USES_IK" = "true" ]; then
  if grep -qE '\bNavigationStack[[:space:]]*[({]' "$FILE_PATH"; then
    add_violation "$rel: NavigationStack banned in IKNavigation projects (iknavigation-bridge.md §7)"
  fi
  if grep -qE '\bNavigationLink[[:space:]]*[({]' "$FILE_PATH"; then
    add_violation "$rel: NavigationLink banned in IKNavigation projects"
  fi
  if grep -qE '\.navigationDestination[[:space:]]*\(' "$FILE_PATH"; then
    add_violation "$rel: .navigationDestination banned in IKNavigation projects"
  fi
fi

# ── 6. IKFont raw fonts ─────────────────────────────────────────────────────
if [ "$IKFONT" != "null" ] && [ -n "$IKFONT" ]; then
  IKFONT_NAME=$(printf '%s' "$IKFONT" | sed -E 's/^"//;s/"$//')
  if grep -qE '\.font\([[:space:]]*\.system\([[:space:]]*size:' "$FILE_PATH" \
       && ! grep -qE '@ScaledMetric' "$FILE_PATH"; then
    add_violation "$rel: raw .font(.system(size:)) — use $IKFONT_NAME.<token>"
  fi
  if grep -qE 'Font\.custom\(' "$FILE_PATH"; then
    add_violation "$rel: Font.custom() banned when $IKFONT_NAME enum exists"
  fi
fi

# ── 7. Per-file function length ─────────────────────────────────────────────
LONG=$(awk -v file="$rel" -v fail=50 '
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
      if (func_body >= fail) printf("  %s:%d: function %s exceeds %d lines (%d)\n", file, func_start, func_name, fail, func_body)
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
if [ -z "$VIOLATIONS" ]; then
  exit 0
fi

# ── P1-3 + P0-5: mode-aware terse output ────────────────────────────────────
TAG="figma-c8"
HEADER=""
EXIT_CODE=2
if [ "$MODE" = "scaffold" ]; then
  HEADER="WARN [$TAG, scaffold mode]: $(basename "$FILE_PATH") — not blocking, fix before production switch"
  EXIT_CODE=0
else
  HEADER="BLOCKED [$TAG]: $(basename "$FILE_PATH")"
fi

{
  if [ "${HOOK_VERBOSE:-0}" = "1" ]; then
    echo "$HEADER"
    echo ""
    echo "C8 violations:"
    printf "%b" "$VIOLATIONS"
    echo ""
    echo "Conventions detected:"
    echo "  layout=$LAYOUT featureRoot=$FEATURE_ROOT mode=$MODE"
    echo "  usesIKNavigation=$USES_IK ikFontEnum=$IKFONT"
    echo ""
    echo "Docs:"
    echo "  ~/.claude/skills/figma-to-swiftui/references/project-structure.md"
    echo "  ~/.claude/skills/figma-to-swiftui/references/viewmodel-pattern.md"
    echo "  ~/.claude/skills/figma-to-swiftui/references/swift-style.md"
    [ "$USES_IK" = "true" ] && echo "  ~/.claude/skills/figma-to-swiftui/references/iknavigation-bridge.md"
    [ "$IKFONT" != "null" ] && [ -n "$IKFONT" ] && echo "  ~/.claude/skills/figma-to-swiftui/references/swiftui-pro-bridge.md §7"
  else
    echo "$HEADER"
    printf "%b" "$VIOLATIONS"
    echo "Docs: ~/.claude/skills/figma-to-swiftui/references/{project-structure,viewmodel-pattern,swift-style}.md"
    [ "${HOOK_VERBOSE:-0}" != "1" ] && echo "(HOOK_VERBOSE=1 for full reference)"
  fi
} >&2

exit "$EXIT_CODE"
