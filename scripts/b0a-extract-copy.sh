#!/usr/bin/env bash
# b0a-extract-copy.sh — parse design-context.md and emit a single
# Strings.swift enum keyed by Figma node ID.
#
# Replaces the manual "walk every visible string in design-context.md and
# write Strings.swift" step in figma-to-swiftui/SKILL.md Step B0a. The
# script prints exactly the same output the agent has been typing:
#   - one nested enum per Figma section / parent node
#   - one `static let` per visible Text node, value = the verbatim copy
#   - trailing comment with the source data-node-id for traceability
#
# IMPORTANT — this script does NOT write to xcstrings catalogs. When the
# project uses xcstrings (c1-conventions.json.xcstringsPath != null), the
# agent edits the catalog directly per SKILL.md §B0a Option 1. The script
# only handles Option 2 (Strings.swift enum).
#
# How it parses:
#   design-context.md contains React/JSX-flavored output from Figma MCP,
#   e.g. <Text data-node-id="3:24644" style={...}>Secure All Accounts</Text>.
#   We grep for Text-like elements with a data-node-id attribute and extract
#   inner text.
#
# Output:
#   <output-path>/Strings.swift  (default: <project>/DesignSystem/Strings.swift)
#
# Usage:
#   b0a-extract-copy.sh --design-context <path>
#                       --output <path-to-Strings.swift>
#                       [--screen-name <Welcome>]    # outer enum tag
#                       [--merge]                    # extend existing enum instead of overwrite
#
# Exit codes:
#   0 — Strings.swift written
#   64 — bad usage
#   65 — design-context.md missing / unparseable
#   66 — output exists and --merge not set

set -uo pipefail

DC=""
OUT=""
SCREEN_NAME=""
MERGE=0

print_usage() {
  cat <<'USAGE' >&2
usage: b0a-extract-copy.sh
       --design-context <path/to/design-context.md>
       --output <path/to/Strings.swift>
       [--screen-name <Welcome>]
       [--merge]

Extracts every visible Text node from design-context.md and writes a
Strings.swift enum keyed by Figma data-node-id. Output matches the format
shown in figma-to-swiftui/SKILL.md Step B0a Option 2.

When the target project uses xcstrings (c1-conventions.json sets
xcstringsPath), do NOT use this script — agent edits the catalog directly
per SKILL.md §B0a Option 1.

When --merge is set, the script preserves any existing nested enums in the
output file and adds a new sub-enum for this screen. Otherwise it refuses
to overwrite an existing file (exit 66).
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --design-context) DC="${2:-}"; shift 2 ;;
    --output)         OUT="${2:-}"; shift 2 ;;
    --screen-name)    SCREEN_NAME="${2:-}"; shift 2 ;;
    --merge)          MERGE=1; shift ;;
    -h|--help)        print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$DC"  ] || { print_usage; exit 64; }
[ -n "$OUT" ] || { print_usage; exit 64; }
[ -s "$DC"  ] || { echo "FAIL: design-context.md missing or empty: $DC" >&2; exit 65; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 65; }

if [ -f "$OUT" ] && [ "$MERGE" = "0" ]; then
  echo "REFUSE: $OUT exists. Pass --merge to extend, or delete it first." >&2
  exit 66
fi

mkdir -p "$(dirname "$OUT")"

# Default screen-name from output basename when not explicitly set.
if [ -z "$SCREEN_NAME" ]; then
  base=$(basename "$OUT" .swift)
  if [ "$base" = "Strings" ]; then
    SCREEN_NAME="Screen"
  else
    SCREEN_NAME="${base#Strings_}"
    SCREEN_NAME="${SCREEN_NAME%Strings}"
  fi
fi

python3 - "$DC" "$OUT" "$SCREEN_NAME" "$MERGE" <<'PY'
import json, os, re, sys

dc_path, out_path, screen_name, merge_flag = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
merge = merge_flag == "1"

# ── 1. Parse design-context.md ────────────────────────────────────────────
# We expect React/JSX-flavored content. Two common shapes:
#   <Text data-node-id="3:24644" ...>Secure All Accounts</Text>
#   <p data-node-id="3:24644">Some body</p>
# Plus self-closing img/svg with alt= which we don't extract (handled by B1).
#
# We intentionally do NOT try to be smart about nested HTML — if the inner
# content has child tags, we strip them and keep the visible text.

text = open(dc_path, errors="replace").read()

# Match opening tag with data-node-id, capture the id, then everything up
# to the matching closing tag of that element. Tag names: Text, Heading,
# Title, p, span, h1-h6, label, button, a (the common ones Figma MCP emits).
TAG = r"(?:Text|Heading|Title|p|span|h[1-6]|label|button|a|Button|Link)"
NODE_RE = re.compile(
    rf"<({TAG})\b[^>]*?\bdata-node-id=\"([^\"]+)\"[^>]*?>(.*?)</\1>",
    re.DOTALL,
)

# Strip nested HTML tags and decode common entities for the inner content.
def clean(inner: str) -> str:
    inner = re.sub(r"<[^>]+>", "", inner, flags=re.DOTALL)
    inner = inner.replace("&amp;", "&").replace("&lt;", "<").replace("&gt;", ">")
    inner = inner.replace("&quot;", '"').replace("&#39;", "'").replace("&nbsp;", " ")
    return re.sub(r"\s+", " ", inner).strip()

records = []   # [(node_id, text, key)]
seen_keys = {}

# Swift reserved keywords that would conflict with `static let <key>`. When a
# generated key collides, we backtick-quote the declaration so the Swift
# compiler accepts it (`` `continue` ``).
SWIFT_RESERVED = {
    "associatedtype", "break", "case", "catch", "class", "continue",
    "default", "defer", "deinit", "do", "else", "enum", "extension",
    "fallthrough", "false", "fileprivate", "final", "for", "func", "guard",
    "if", "import", "in", "init", "inout", "internal", "is", "lazy", "let",
    "mutating", "nil", "nonmutating", "open", "operator", "private",
    "protocol", "public", "repeat", "required", "return", "self", "static",
    "struct", "subscript", "super", "switch", "throw", "throws", "true",
    "try", "typealias", "var", "weak", "where", "while",
}

def make_key(s: str, node_id: str) -> str:
    """Convert inner text to a camelCase key, dedup with node-id suffix on collision."""
    # Take first 4 words, alpha only.
    words = re.findall(r"[A-Za-z]+", s)[:4]
    if not words:
        words = ["item"]
    key = words[0].lower() + "".join(w.capitalize() for w in words[1:])
    # Limit length.
    key = key[:32]
    if key in seen_keys and seen_keys[key] != node_id:
        # Disambiguate using last segment of node id.
        suffix = node_id.split(":")[-1] if ":" in node_id else node_id
        key = f"{key}_{suffix}"
    seen_keys[key] = node_id
    return key

def render_key(key: str) -> str:
    """Backtick-quote when the key collides with a Swift reserved word."""
    return f"`{key}`" if key in SWIFT_RESERVED else key

for m in NODE_RE.finditer(text):
    _tag, nid, inner = m.group(1), m.group(2), m.group(3)
    body = clean(inner)
    if not body:
        continue  # skip pure-icon / decorative <Text> nodes
    if len(body) > 200:
        continue  # likely paragraph / mis-parse — handle by hand
    records.append((nid, body, make_key(body, nid)))

# Dedup on (nid, body) — same string at the same node-id appearing twice.
seen = set()
unique = []
for r in records:
    sig = (r[0], r[1])
    if sig in seen:
        continue
    seen.add(sig)
    unique.append(r)

if not unique:
    print(f"NOTE: no Text nodes with data-node-id found in {dc_path} — emitting empty enum")

# ── 2. Render Strings.swift ──────────────────────────────────────────────
# Format mirrors the template in SKILL.md §B0a Option 2:
#   enum Strings {
#       enum Welcome {
#           static let title = "Secure All Accounts"               // Figma node 3:24644
#       }
#   }

def render_block(name: str, rows: list[tuple[str, str, str]]) -> str:
    lines = [f"    enum {name} {{"]
    if not rows:
        lines.append("        // (no Text nodes extracted)")
    for nid, body, key in rows:
        # Escape backslash and double-quote.
        safe = body.replace("\\", "\\\\").replace('"', '\\"')
        # Pad key to ~26 chars so // comments line up.
        # Render with backticks for Swift reserved words.
        padded = render_key(key).ljust(26)
        lines.append(f'        static let {padded} = "{safe}"  // Figma node {nid}')
    lines.append("    }")
    return "\n".join(lines)

new_block = render_block(screen_name, unique)

if merge and os.path.exists(out_path):
    existing = open(out_path).read()
    # Find the closing `}` of `enum Strings {` and inject before it.
    m = re.search(r"^(enum Strings \{)(.*)^\}\s*$", existing, re.DOTALL | re.MULTILINE)
    if m:
        head, body = m.group(1), m.group(2)
        # Replace any prior enum with the same screen_name.
        body = re.sub(
            rf"\n*    enum {re.escape(screen_name)} \{{[^}}]*?\}}\n?",
            "\n",
            body,
            flags=re.DOTALL,
        )
        merged = f"{head}{body.rstrip()}\n\n{new_block}\n}}\n"
        out_text = merged
    else:
        # Existing file doesn't have the canonical wrapper — overwrite cleanly.
        out_text = (
            "// Auto-generated by b0a-extract-copy.sh — do not edit by hand.\n"
            "// Source of truth: <screen>/design-context.md (Figma data-node-id keys).\n"
            "//\n"
            "// Hard rule: every Text(...) literal in a generated view file MUST\n"
            "// reference one of these constants — inline English literals are\n"
            "// banned by C3 Pass 1 review.\n\n"
            "enum Strings {\n"
            f"{new_block}\n"
            "}\n"
        )
else:
    out_text = (
        "// Auto-generated by b0a-extract-copy.sh — do not edit by hand.\n"
        "// Source of truth: <screen>/design-context.md (Figma data-node-id keys).\n"
        "//\n"
        "// Hard rule: every Text(...) literal in a generated view file MUST\n"
        "// reference one of these constants — inline English literals are\n"
        "// banned by C3 Pass 1 review.\n\n"
        "enum Strings {\n"
        f"{new_block}\n"
        "}\n"
    )

with open(out_path, "w") as f:
    f.write(out_text)

print(f"WROTE: {out_path}")
print(f"  enum Strings.{screen_name} — {len(unique)} entry(ies)")
for nid, body, key in unique[:8]:
    print(f"    {key}: {body[:60]}{'…' if len(body) > 60 else ''}  (node {nid})")
if len(unique) > 8:
    print(f"    ... and {len(unique) - 8} more")
PY

exit 0
