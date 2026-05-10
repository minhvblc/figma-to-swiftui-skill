#!/usr/bin/env bash
# c8-conventions-gate.sh — verify generated SwiftUI files follow the
# screen-based folder layout and naming conventions documented in
# `figma-to-swiftui/references/project-structure.md`.
#
# Skipped when the project uses a flat layout (c1-conventions.json sets
# `screenFolderConvention = "flat"`).
#
# Usage:
#   c8-conventions-gate.sh --src <path-to-swift-src-root>
#                          [--files "<space-separated-paths>"]
#                          --conventions <path-to-c1-conventions.json>
#
# Scope: --files takes precedence over --src for per-file checks (1-5).
# When --files is set, the parent-view existence check (6) is restricted to
# the screen folders that contain at least one session file. Empty --files =
# SKIP (session mode with no swift writes).
#
# Exit codes:
#   0 — PASS or SKIP
#   1 — at least one violation
#   64 — bad usage
#   65 — input not found

set -euo pipefail

SRC=""
FILES=""
FILES_PROVIDED=0
CONVENTIONS=""

print_usage() {
  cat <<'USAGE' >&2
usage: c8-conventions-gate.sh --src <swift-src-root>
                                [--files "<space-separated-paths>"]
                                --conventions <c1-conventions.json>

Verifies file paths and types follow the screen-based folder convention:
  - Screen views live at Screens/<Name>Screen/<Name>Screen.swift
  - ViewModels live alongside the Screen file
  - Subview / model / enum files in Subviews/, Models/, Enums/ have a
    parent-screen prefix
  - Type/file basenames agree on suffix (-Screen, -View, -ViewModel, +Ext)

The gate is skipped when c1-conventions.json sets screenFolderConvention to
"flat" — output is `GATE: SKIP (flat layout)`, exit 0.

Pass --files "" to explicitly skip (session-scope with no swift writes).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --src)         SRC="${2:-}"; shift 2 ;;
    --files)       FILES="${2:-}"; FILES_PROVIDED=1; shift 2 ;;
    --conventions) CONVENTIONS="${2:-}"; shift 2 ;;
    -h|--help)     print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

if [ "$FILES_PROVIDED" = "1" ] && [ -z "$FILES" ]; then
  echo "GATE: SKIP (no session-generated swift files)"
  exit 0
fi
if [ "$FILES_PROVIDED" = "0" ] && [ -z "$SRC" ]; then
  print_usage; exit 64
fi
if [ -n "$SRC" ] && [ ! -d "$SRC" ]; then
  echo "FAIL: src is not a directory: $SRC" >&2; exit 65
fi

if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
  C_RED=$(tput setaf 1); C_GRN=$(tput setaf 2); C_YEL=$(tput setaf 3); C_DIM=$(tput dim); C_RST=$(tput sgr0)
else
  C_RED=""; C_GRN=""; C_YEL=""; C_DIM=""; C_RST=""
fi

# Read screenFolderConvention from c1-conventions.json. Default = screen-based.
LAYOUT="screen-based"
if [ -n "$CONVENTIONS" ] && [ -f "$CONVENTIONS" ]; then
  LAYOUT=$(grep -oE '"screenFolderConvention"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONVENTIONS" \
    | sed -E 's/.*"([^"]+)"$/\1/' | head -n1 || true)
  [ -n "$LAYOUT" ] || LAYOUT="screen-based"
fi

if [ "$LAYOUT" = "flat" ]; then
  echo "${C_DIM}GATE: SKIP (flat layout)${C_RST}"
  exit 0
fi

# ── ikame-feature-flat branch ─────────────────────────────────────────────
# Feature-folder layout (Ikame projects):
#   Screens/<Feature>/<Name>Screen.swift           — entry + additional screens
#   Screens/<Feature>/<Name>Screen+<Topic>.swift   — extension files
#   Screens/<Feature>/ViewModel/<Name>ViewModel.swift
#   Screens/<Feature>/ViewModel/<Name>Repository.swift   (optional)
#   Screens/<Feature>/Subviews/<FeatureBase>Home<Role>View.swift
#   Screens/<Feature>/Models/<Name>.swift          (optional flow-only model)
# See references/project-structure.md §2 + §7, ikame-decision-table.md
# D-201..D-218.
if [ "$LAYOUT" = "ikame-feature-flat" ]; then
  HITS_FILE=$(mktemp -t c8-conventions.XXXXXX)
  trap 'rm -f "$HITS_FILE"' EXIT
  violation() { printf "%s\n" "$1" >> "$HITS_FILE"; }

  enum_files_ikame() {
    if [ "$FILES_PROVIDED" = "1" ]; then
      for f in $FILES; do
        [ -n "$f" ] && [ -f "$f" ] && [[ "$f" == *.swift ]] && printf '%s\0' "$f"
      done
    else
      find "$SRC" -name '*.swift' -type f -print0 2>/dev/null
    fi
  }

  while IFS= read -r -d '' file; do
    if [ -n "$SRC" ]; then
      rel="${file#$SRC/}"
    else
      rel="$file"
    fi
    base="$(basename "$file" .swift)"
    parent_dir="$(dirname "$rel")"
    parent_name="$(basename "$parent_dir")"
    grandparent="$(basename "$(dirname "$parent_dir")")"

    # 1. Screen file location: Screens/<Feature>/<Name>Screen.swift
    #    Allow extension files <Name>+<Topic>.swift in same folder.
    if [[ "$base" == *Screen ]] && [[ "$base" != *+* ]]; then
      if [[ "$parent_name" == "Subviews" ]] || [[ "$parent_name" == "ViewModel" ]] \
           || [[ "$parent_name" == "Models" ]]; then
        violation "$rel: '-Screen' suffix is reserved for parent (full-screen) views; ViewModels go in ViewModel/, subviews in Subviews/, models in Models/ (see project-structure.md §2)"
      elif [[ "$grandparent" != "Screens" ]]; then
        violation "$rel: screen view should live at Screens/<Feature>/${base}.swift (got grandparent: ${grandparent})"
      fi
    fi

    # 2. ViewModel placement: Screens/<Feature>/ViewModel/<Name>ViewModel.swift
    if [[ "$base" == *ViewModel ]]; then
      if [[ "$parent_name" != "ViewModel" ]]; then
        violation "$rel: ViewModel '${base}' should live at Screens/<Feature>/ViewModel/${base}.swift"
      fi
    fi

    # 3. Subview prefix: Screens/<Feature>/Subviews/<FeatureBase>Home*View.swift
    if [[ "$parent_name" == "Subviews" ]]; then
      feature_folder="$(basename "$(dirname "$parent_dir")")"
      grand_grand="$(basename "$(dirname "$(dirname "$parent_dir")")")"
      if [[ "$grand_grand" == "Screens" ]]; then
        prefix1="${feature_folder}Home"
        prefix2="${feature_folder}"
        if [[ "$base" != ${prefix1}* ]] && [[ "$base" != ${prefix2}* ]]; then
          violation "$rel: subview should start with parent screen prefix '${prefix1}' or '${prefix2}' (got: ${base})"
        fi
      fi
    fi

    # 4. Suffix-type agreement.
    if [[ "$base" == *Screen ]] && [[ "$base" != *+* ]] && ! grep -qE "(struct|class)[[:space:]]+${base}\b" "$file"; then
      violation "$rel: '${base}.swift' should declare a type named '${base}'"
    fi
    if [[ "$base" == *ViewModel ]] && ! grep -qE "(class|final class|@Observable[[:space:]]+(@MainActor[[:space:]]+)?(final[[:space:]]+)?class)[[:space:]]+${base}\b" "$file"; then
      violation "$rel: '${base}.swift' should declare a class named '${base}'"
    fi
    if [[ "$base" == *View ]] && [[ "$base" != *Screen ]] && [[ "$base" != *+* ]] \
         && ! grep -qE "struct[[:space:]]+${base}\b" "$file"; then
      violation "$rel: '${base}.swift' should declare a struct named '${base}'"
    fi

    # 5. Extension file naming.
    if [[ "$rel" == Utilities/Extensions/* ]] || [[ "$parent_name" == "Extensions" ]]; then
      if [[ "$base" != *+*Ext ]]; then
        violation "$rel: extension file must use '<Type>+Ext.swift' or '<Type>+<Feature>Ext.swift' naming (got: ${base}.swift)"
      fi
    fi
  done < <(enum_files_ikame)

  # Folder-level: every feature folder under Screens/ that has a session file
  # must contain at least one *Screen.swift entry. Screens/<F>/ with only
  # ViewModel/, Subviews/, etc. (no parent screen) is invalid.
  if [ "$FILES_PROVIDED" = "1" ]; then
    FEATURE_DIRS=$(for f in $FILES; do
      [ -f "$f" ] || continue
      d=$(dirname "$f")
      while [ "$d" != "/" ] && [ -n "$d" ]; do
        parent=$(basename "$(dirname "$d")")
        if [ "$parent" = "Screens" ]; then
          echo "$d"
          break
        fi
        d=$(dirname "$d")
      done
    done | sort -u)
    while IFS= read -r feature_dir; do
      [ -z "$feature_dir" ] && continue
      if ! find "$feature_dir" -maxdepth 1 -name '*Screen.swift' -type f 2>/dev/null | head -1 | grep -q . ; then
        violation "${feature_dir}/: missing parent-screen file; every feature folder must contain at least one *Screen.swift"
      fi
    done <<< "$FEATURE_DIRS"
  elif [ -d "$SRC/Screens" ]; then
    while IFS= read -r -d '' feature_dir; do
      if ! find "$feature_dir" -maxdepth 1 -name '*Screen.swift' -type f 2>/dev/null | head -1 | grep -q . ; then
        rel_dir="${feature_dir#$SRC/}"
        violation "${rel_dir}/: missing parent-screen file; every feature folder must contain at least one *Screen.swift"
      fi
    done < <(find "$SRC/Screens" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
  fi

  if [ -s "$HITS_FILE" ]; then
    COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
    echo "${C_RED}GATE: FAIL: ikame-feature-flat convention violations${C_RST} (${COUNT} hit(s)):"
    cat "$HITS_FILE"
    echo "${C_DIM}fix: see references/project-structure.md §2 (ikame-feature-flat layout) and ikame-decision-table.md D-201..D-218${C_RST}"
    exit 1
  fi

  if [ "$FILES_PROVIDED" = "1" ]; then
    echo "${C_GRN}GATE: PASS${C_RST}: ikame-feature-flat conventions OK (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
  else
    echo "${C_GRN}GATE: PASS${C_RST}: ikame-feature-flat conventions OK in $SRC"
  fi
  exit 0
fi

# ── screen-based branch (existing behavior) ───────────────────────────────
HITS_FILE=$(mktemp -t c8-conventions.XXXXXX)
trap 'rm -f "$HITS_FILE"' EXIT

violation() {
  printf "%s\n" "$1" >> "$HITS_FILE"
}

enum_files() {
  if [ "$FILES_PROVIDED" = "1" ]; then
    for f in $FILES; do
      [ -n "$f" ] && [ -f "$f" ] && [[ "$f" == *.swift ]] && printf '%s\0' "$f"
    done
  else
    find "$SRC" -name '*.swift' -type f -print0 2>/dev/null
  fi
}

# Walk every .swift file in scope (--files list or under SRC).
while IFS= read -r -d '' file; do
  if [ -n "$SRC" ]; then
    rel="${file#$SRC/}"
  else
    rel="$file"
  fi
  base="$(basename "$file" .swift)"
  parent_dir="$(dirname "$rel")"
  parent_name="$(basename "$parent_dir")"
  grandparent="$(basename "$(dirname "$parent_dir")")"

  # ── 1. Screen file location ────────────────────────────────────────────
  # *Screen.swift must be at Screens/<X>Screen/<X>Screen.swift
  if [[ "$base" == *Screen ]] && [[ "$base" != *Screens ]]; then
    expected_parent="${base}"
    if [[ "$parent_name" == "Subviews" ]] || [[ "$parent_name" == "SubViewModels" ]] \
         || [[ "$parent_name" == "Models" ]] || [[ "$parent_name" == "Enums" ]]; then
      violation "$rel: '-Screen' suffix is reserved for parent (full-screen) views; subviews use '-View' suffix (see project-structure.md §3)"
    elif [[ "$parent_name" != "$expected_parent" ]] || [[ "$grandparent" != "Screens" ]]; then
      violation "$rel: screen view should live at Screens/${expected_parent}/${base}.swift (got: ${rel})"
    fi
  fi

  # ── 1b. Parent-view existence — every Screens/<X>Screen/ folder MUST contain
  #      <X>Screen.swift (the parent View). Done in a separate pass below.

  # ── 2. ViewModel placement ────────────────────────────────────────────
  # *ViewModel.swift directly named after the screen lives at the screen's
  # folder; sub-ViewModels live in SubViewModels/ folder.
  if [[ "$base" == *ViewModel ]]; then
    screen_root="${base%ViewModel}"
    expected_parent="${screen_root}Screen"
    if [[ "$parent_name" == "SubViewModels" ]]; then
      # Sub-ViewModel: file basename must start with the parent screen name.
      screen_folder="$(basename "$(dirname "$parent_dir")")"
      screen_prefix="${screen_folder%Screen}"
      if [[ "$base" != ${screen_prefix}* ]]; then
        violation "$rel: sub-ViewModel must start with parent screen prefix '${screen_prefix}' (got: ${base})"
      fi
    elif [[ "$parent_name" == "$expected_parent" ]] && [[ "$grandparent" == "Screens" ]]; then
      : # OK — top-level ViewModel for the screen
    else
      violation "$rel: ViewModel '${base}' should live at Screens/${expected_parent}/${base}.swift OR Screens/<Parent>Screen/SubViewModels/${base}.swift"
    fi
  fi

  # ── 3. Subview / Models / Enums prefix rule ────────────────────────────
  case "$parent_name" in
    Subviews|Models|Enums|SubViewModels)
      screen_folder="$(basename "$(dirname "$parent_dir")")"
      screen_prefix="${screen_folder%Screen}"
      if [[ -n "$screen_prefix" ]] && [[ "$base" != ${screen_prefix}* ]]; then
        violation "$rel: file in '${parent_name}/' must start with screen prefix '${screen_prefix}' (got: ${base})"
      fi
      ;;
  esac

  # ── 3b. Top-level files in Screens/<X>Screen/ MUST have -Screen or
  #      -ViewModel suffix. A bare *View.swift sitting at the screen-folder
  #      root means the agent named a parent view incorrectly (should be
  #      <X>Screen.swift) or placed a subview at the wrong level (should be
  #      Subviews/<X><Y>View.swift).
  if [[ "$grandparent" == "Screens" ]] && [[ "$parent_name" == *Screen ]]; then
    case "$base" in
      *Screen|*ViewModel)
        : # OK — parent view or its ViewModel
        ;;
      *)
        violation "$rel: top-level file in Screens/${parent_name}/ must end with '-Screen' (parent view) or '-ViewModel'; subviews go in Subviews/ (got: ${base}.swift)"
        ;;
    esac
  fi

  # ── 4. Suffix / type-declaration agreement ─────────────────────────────
  # *Screen.swift declares a `*Screen` type; *View.swift declares a `*View`
  # struct; *ViewModel.swift declares a `*ViewModel` class.
  if [[ "$base" == *Screen ]] && ! grep -qE "(struct|class)\s+${base}\b" "$file"; then
    violation "$rel: '${base}.swift' should declare a type named '${base}'"
  fi
  if [[ "$base" == *ViewModel ]] && ! grep -qE "(class|final class|@Observable[[:space:]]+(@MainActor[[:space:]]+)?(final[[:space:]]+)?class)\s+${base}\b" "$file"; then
    violation "$rel: '${base}.swift' should declare a class named '${base}'"
  fi
  if [[ "$base" == *View ]] && [[ "$base" != *Screen ]] \
       && ! grep -qE "struct\s+${base}\b" "$file"; then
    violation "$rel: '${base}.swift' should declare a struct named '${base}'"
  fi

  # ── 5. Extension file naming ───────────────────────────────────────────
  # Files in Utilities/Extensions/ must match <Type>+Ext.swift or
  # <Type>+<Feature>Ext.swift.
  if [[ "$rel" == Utilities/Extensions/* ]] || [[ "$parent_name" == "Extensions" ]]; then
    if [[ "$base" != *+*Ext ]]; then
      violation "$rel: extension file must use '<Type>+Ext.swift' or '<Type>+<Feature>Ext.swift' naming (got: ${base}.swift)"
    fi
  fi

done < <(enum_files)

# ── 6. Parent-view existence ────────────────────────────────────────────────
# Every Screens/<X>Screen/ folder in scope MUST contain <X>Screen.swift (the
# parent View). Catches: agent named the parent view file `HomeView.swift`
# instead of `HomeScreen.swift`, leaving the folder without a -Screen entry.
#
# Scope:
#   --src mode → walk every Screens/<X>Screen/ under SRC.
#   --files mode → only check screen folders that contain at least one
#                  session-generated file (avoid flagging unrelated legacy
#                  screen folders that pre-date this run).
if [ "$FILES_PROVIDED" = "1" ]; then
  # Collect parent-screen folder of each session file (when path matches
  # */Screens/<X>Screen/...) and dedupe.
  SCREEN_DIRS=$(for f in $FILES; do
    [ -f "$f" ] || continue
    d=$(dirname "$f")
    while [ "$d" != "/" ] && [ -n "$d" ]; do
      parent=$(basename "$(dirname "$d")")
      this=$(basename "$d")
      if [ "$parent" = "Screens" ] && [[ "$this" == *Screen ]]; then
        echo "$d"
        break
      fi
      d=$(dirname "$d")
    done
  done | sort -u)
  while IFS= read -r screen_dir; do
    [ -z "$screen_dir" ] && continue
    folder=$(basename "$screen_dir")
    if [ ! -f "$screen_dir/${folder}.swift" ]; then
      violation "${screen_dir}/: missing parent-view file ${folder}.swift (the full-screen view must use the '-Screen' suffix matching the folder name)"
    fi
  done <<< "$SCREEN_DIRS"
elif [ -d "$SRC/Screens" ]; then
  while IFS= read -r -d '' screen_dir; do
    folder=$(basename "$screen_dir")
    [[ "$folder" == *Screen ]] || continue
    if [ ! -f "$screen_dir/${folder}.swift" ]; then
      rel_dir="${screen_dir#$SRC/}"
      violation "$rel_dir/: missing parent-view file ${folder}.swift (the full-screen view must use the '-Screen' suffix matching the folder name)"
    fi
  done < <(find "$SRC/Screens" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
fi

# Report.
if [ -s "$HITS_FILE" ]; then
  COUNT=$(wc -l < "$HITS_FILE" | tr -d ' ')
  echo "${C_RED}GATE: FAIL: convention violations${C_RST} (${COUNT} hit(s)):"
  cat "$HITS_FILE"
  echo "${C_DIM}fix: see references/project-structure.md §2 (folder layout) and §3 (file naming)${C_RST}"
  exit 1
fi

if [ "$FILES_PROVIDED" = "1" ]; then
  echo "${C_GRN}GATE: PASS${C_RST}: project-structure conventions OK (session-scope: $(echo $FILES | wc -w | tr -d ' ') file(s))"
else
  echo "${C_GRN}GATE: PASS${C_RST}: project-structure conventions OK in $SRC"
fi
exit 0
