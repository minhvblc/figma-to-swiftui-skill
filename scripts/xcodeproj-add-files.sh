#!/usr/bin/env bash
# xcodeproj-add-files.sh — add Swift / asset files to a .xcodeproj target.
#
# Auto-detects Xcode 16+ "synchronized folder" layout (PBXFileSystemSynchronizedRootGroup):
# when present, files placed on disk under the target's folder are AUTO-included
# in the target by Xcode itself — no manual file references needed. This script
# becomes a no-op confirmation for those projects (modern ikxcodegen output is
# in this category).
#
# Falls back to traditional file-reference + build-phase insertion for legacy
# projects that use PBXGroup-style file lists. Useful for older brownfield
# projects pre-Xcode-16.
#
# Uses Ruby `xcodeproj` gem 1.27+ (bundled with CocoaPods, also auto-installs
# via `gem install --user-install xcodeproj` on first run).
#
# Usage:
#   xcodeproj-add-files.sh --project <path-to-.xcodeproj> \
#                          --target <target-name> \
#                          --files "<space-separated-abs-paths>" \
#                          [--src-root <abs-path-to-target-src-folder>] \
#                          [--dry-run]
#
# Examples:
#   # Add Splash screen + ViewModel to FigmaSkillTest target
#   xcodeproj-add-files.sh \
#     --project ~/Desktop/WORK/figma-skill-test/FigmaSkillTest.xcodeproj \
#     --target FigmaSkillTest \
#     --files "$(find ~/Desktop/WORK/figma-skill-test/FigmaSkillTest/Screens/Splash -name '*.swift')"
#
# Group hierarchy: derived from the file path relative to --src-root. Default
# src-root is `<dir-of-project>/<target-name>` (the standard ikxcodegen layout).
#
# File-type → build phase routing:
#   *.swift                 → SourcesBuildPhase
#   *.xcassets, *.bundle    → ResourcesBuildPhase (folder reference)
#   *.plist, *.xcconfig     → file reference only (no phase)
#   *.json, *.md, *.yaml    → file reference only
#
# Exit codes:
#   0 — all files added or already present (idempotent)
#   1 — Ruby gem missing AND auto-install failed
#   64 — bad usage
#   65 — project / target not found

set -uo pipefail

PROJECT=""
TARGET=""
FILES=""
SRC_ROOT=""
DRY_RUN=0

print_usage() {
  sed -n '2,30p' "$0" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project)   PROJECT="${2:-}"; shift 2 ;;
    --target)    TARGET="${2:-}"; shift 2 ;;
    --files)     FILES="${2:-}"; shift 2 ;;
    --src-root)  SRC_ROOT="${2:-}"; shift 2 ;;
    --dry-run)   DRY_RUN=1; shift ;;
    -h|--help)   print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$PROJECT" ] || { echo "FAIL: --project required" >&2; print_usage; exit 64; }
[ -n "$TARGET" ]  || { echo "FAIL: --target required" >&2; print_usage; exit 64; }
[ -n "$FILES" ]   || { echo "FAIL: --files required (space-separated absolute paths)" >&2; print_usage; exit 64; }
[ -d "$PROJECT" ] || { echo "FAIL: project not a directory: $PROJECT" >&2; exit 65; }
[[ "$PROJECT" == *.xcodeproj ]] || { echo "FAIL: project must end in .xcodeproj: $PROJECT" >&2; exit 65; }

# Default src-root: <project-parent>/<target>
if [ -z "$SRC_ROOT" ]; then
  SRC_ROOT="$(dirname "$PROJECT")/$TARGET"
fi
[ -d "$SRC_ROOT" ] || { echo "FAIL: src-root not a directory: $SRC_ROOT (override with --src-root)" >&2; exit 65; }

# Locate Ruby + xcodeproj gem.
#   Try 1: system Ruby with user-install gem (default on macOS)
#   Try 2: CocoaPods bundled xcodeproj (when installed)
#   Try 3: auto-install via `gem install --user-install xcodeproj`
RUBY_BIN="$(command -v ruby)"
[ -x "$RUBY_BIN" ] || { echo "FAIL: ruby not found in PATH" >&2; exit 1; }

# Build RUBYLIB include paths to search for xcodeproj.rb.
RUBYLIB_PATHS=()

# User-install gems (current Ruby version).
RUBY_VER=$("$RUBY_BIN" -e 'puts RUBY_VERSION.split(".")[0..1].join(".")' 2>/dev/null)
USER_GEM_DIR="$HOME/.gem/ruby/${RUBY_VER}.0/gems"
if [ -d "$USER_GEM_DIR" ]; then
  for dir in "$USER_GEM_DIR"/xcodeproj-*/lib "$USER_GEM_DIR"/nanaimo-*/lib \
             "$USER_GEM_DIR"/atomos-*/lib "$USER_GEM_DIR"/colored2-*/lib \
             "$USER_GEM_DIR"/claide-*/lib; do
    [ -d "$dir" ] && RUBYLIB_PATHS+=("$dir")
  done
fi

# CocoaPods bundle fallback.
if [ ${#RUBYLIB_PATHS[@]} -lt 5 ]; then
  for dir in /opt/homebrew/Cellar/cocoapods/*/libexec/gems/xcodeproj-*/lib \
             /opt/homebrew/Cellar/cocoapods/*/libexec/gems/nanaimo-*/lib \
             /opt/homebrew/Cellar/cocoapods/*/libexec/gems/atomos-*/lib \
             /opt/homebrew/Cellar/cocoapods/*/libexec/gems/colored2-*/lib \
             /opt/homebrew/Cellar/cocoapods/*/libexec/gems/claide-*/lib; do
    [ -d "$dir" ] && RUBYLIB_PATHS+=("$dir")
  done
fi

probe_gem() {
  RUBYLIB="$(IFS=:; echo "${RUBYLIB_PATHS[*]:-}")" "$RUBY_BIN" -e 'require "xcodeproj"; puts "ok"' 2>/dev/null
}

if [ "$(probe_gem)" != "ok" ]; then
  echo "xcodeproj gem not found — auto-installing via gem install --user-install xcodeproj"
  if ! gem install --user-install xcodeproj 2>&1 | tail -5; then
    echo "FAIL: gem install xcodeproj failed. Install manually: gem install --user-install xcodeproj" >&2
    exit 1
  fi
  # Re-probe gem locations.
  USER_GEM_DIR="$HOME/.gem/ruby/${RUBY_VER}.0/gems"
  RUBYLIB_PATHS=()
  for dir in "$USER_GEM_DIR"/xcodeproj-*/lib "$USER_GEM_DIR"/nanaimo-*/lib \
             "$USER_GEM_DIR"/atomos-*/lib "$USER_GEM_DIR"/colored2-*/lib \
             "$USER_GEM_DIR"/claide-*/lib; do
    [ -d "$dir" ] && RUBYLIB_PATHS+=("$dir")
  done
  if [ "$(probe_gem)" != "ok" ]; then
    echo "FAIL: xcodeproj gem installed but still not loadable. Check Ruby env." >&2
    exit 1
  fi
fi

export RUBYLIB="$(IFS=:; echo "${RUBYLIB_PATHS[*]}")"

# Hand off to Ruby. Pass: project, target, src-root, dry-run, then file list on stdin.
RUBYLIB="$RUBYLIB" "$RUBY_BIN" - "$PROJECT" "$TARGET" "$SRC_ROOT" "$DRY_RUN" "$FILES" <<'RUBY'
# encoding: utf-8
require "xcodeproj"

project_path = ARGV[0]
target_name  = ARGV[1]
src_root     = ARGV[2]
dry_run      = ARGV[3] == "1"
files_str    = ARGV[4]

files = files_str.split(/\s+/).reject(&:empty?).map { |f| File.expand_path(f) }
abort "FAIL: no files passed" if files.empty?

# Filter out paths INSIDE an .xcassets/ — those are managed by the parent
# xcassets folder reference (which is a single PBXFileReference). Passing
# individual imageset Contents.json / PNG paths produces a no-op (routed to
# "reference only") AND confuses the agent into thinking the imageset is
# wired when it actually isn't. Pre-flight warn + drop them; user must pass
# the parent .xcassets dir instead.
inside_xcassets = files.select { |f| f.include?("/.xcassets/") || f.include?(".xcassets/") }
files = files - inside_xcassets
unless inside_xcassets.empty?
  STDERR.puts "WARN: dropped #{inside_xcassets.size} path(s) inside .xcassets/ — these are managed by the parent xcassets folder reference (add the .xcassets dir directly, NOT files inside it):"
  inside_xcassets.first(5).each { |f| STDERR.puts "  - #{f}" }
  STDERR.puts "  ... (and #{inside_xcassets.size - 5} more)" if inside_xcassets.size > 5
end
abort "FAIL: no files remaining after .xcassets filter" if files.empty?

project = Xcodeproj::Project.open(project_path)
target  = project.targets.find { |t| t.name == target_name }
abort "FAIL: target '#{target_name}' not found in #{project_path}. Available: #{project.targets.map(&:name).join(", ")}" unless target

# Detect Xcode 16+ synchronized folder layout. When the target's main group is
# a PBXFileSystemSynchronizedRootGroup, every file placed on disk under that
# folder is AUTO-included in the target — no manual file references / build
# phases needed. Skill output that lands in such a folder is already in target.
sync_root = nil
project.main_group.children.each do |child|
  next unless child.respond_to?(:isa) || child.is_a?(Xcodeproj::Project::Object::AbstractObject)
  klass = child.class.name.split("::").last
  if klass == "PBXFileSystemSynchronizedRootGroup"
    if child.respond_to?(:path) && child.path == target_name
      sync_root = child
      break
    end
  end
end

if sync_root
  puts "Project uses Xcode 16+ synchronized folders for target '#{target_name}'."
  puts "Files placed under '#{File.join(File.dirname(project_path), target_name)}' are auto-included in the target."
  puts "No xcodeproj edit needed. (#{files.size} file(s) inspected — all already in target by virtue of being on disk in the synchronized folder.)"
  exit 0
end

# Locate / create the top-level group matching the target name (legacy layout).
top_group = project.main_group.find_subpath(target_name, true)
top_group.set_source_tree("<group>")
top_group.set_path(target_name) if top_group.path.nil?

added = 0
skipped = 0
errored = []

files.each do |abs_path|
  unless File.exist?(abs_path)
    errored << "#{abs_path}: file does not exist"
    next
  end

  # Compute relative path from src-root. abort if file is outside src-root.
  begin
    rel = Pathname.new(abs_path).relative_path_from(Pathname.new(src_root)).to_s
  rescue ArgumentError
    errored << "#{abs_path}: outside src-root #{src_root}"
    next
  end
  if rel.start_with?("..")
    errored << "#{abs_path}: outside src-root #{src_root}"
    next
  end

  # Walk relative path, creating groups as needed (every dir up to file).
  parts = rel.split("/")
  filename = parts.pop
  group = top_group
  parts.each do |dir|
    sub = group.children.find { |c| c.is_a?(Xcodeproj::Project::Object::PBXGroup) && c.display_name == dir }
    sub = group.new_group(dir, dir, "<group>") if sub.nil?
    group = sub
  end

  # Idempotent: skip if file ref already exists.
  existing = group.files.find { |f| f.path == filename || f.real_path.to_s == abs_path }
  if existing
    in_target = target.source_build_phase.files_references.include?(existing) ||
                target.resources_build_phase.files_references.include?(existing)
    if in_target
      skipped += 1
      next
    end
    file_ref = existing
  else
    file_ref = group.new_reference(filename)
    file_ref.set_source_tree("<group>")
  end

  # Route to build phase by extension.
  ext = File.extname(filename).downcase
  case ext
  when ".swift", ".m", ".mm", ".c", ".cc", ".cpp"
    target.source_build_phase.add_file_reference(file_ref, true) unless target.source_build_phase.files_references.include?(file_ref)
    added += 1
  when ".xcassets", ".bundle", ".storyboard", ".xib", ".strings", ".xcstrings"
    target.resources_build_phase.add_file_reference(file_ref, true) unless target.resources_build_phase.files_references.include?(file_ref)
    added += 1
  when ".plist", ".xcconfig", ".json", ".md", ".yaml", ".yml", ".txt"
    # Reference only; no build phase.
    added += 1
  else
    # Unknown — add as resource to be safe.
    target.resources_build_phase.add_file_reference(file_ref, true) unless target.resources_build_phase.files_references.include?(file_ref)
    added += 1
  end
end

if errored.any?
  STDERR.puts "Errors:"
  errored.each { |e| STDERR.puts "  #{e}" }
end

if dry_run
  puts "DRY-RUN: would add #{added} file(s), skip #{skipped} (already in target)"
else
  project.save unless added == 0
  puts "Added #{added} file(s) to target '#{target_name}', skipped #{skipped} (already in target)"
end

exit(errored.empty? ? 0 : 1)
RUBY
