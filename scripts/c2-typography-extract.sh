#!/usr/bin/env bash
# c2-typography-extract.sh — pair text segments with parent typography classes.
#
# Walks design-context.md as JSX, attributes each text-bearing element to its
# closest enclosing className stack, and resolves Tailwind typography utilities
# (`leading-*`, `tracking-*`, `text-<size>`, `font-<weight>`, case modifiers,
# alignment) into normalized numeric / enum values per text segment.
#
# Output schema (`.figma-cache/<nodeId>/c2-typography-perline.json`):
#   {
#     "schemaVersion": 1,
#     "sourceFile": "design-context.md",
#     "byTextNormalized": {
#       "welcome back": {
#         "fontSize": 24,              # pt (Tailwind text-2xl → 24px → 24pt approx)
#         "fontWeight": "bold",        # tailwind weight keyword
#         "leading": 1.25,             # ratio (1.4 = 1.4×fontSize); or pt if leading-[Npx]
#         "tracking": -0.02,           # em (Tailwind tracking-tight) or pt if tracking-[Npx]
#         "textCase": "uppercase",     # uppercase|lowercase|capitalize|null
#         "italic": false,
#         "textAlign": "center",       # left|center|right|justify|null
#         "classes": ["text-2xl", "font-bold", "leading-tight", "tracking-tight"]
#       }
#     }
#   }
#
# L2 trace (c3-token-trace.sh) reads this map for `.lineSpacing(N)` /
# `.tracking(N)` audit rows via `value.textHint` to decide PASS/FAIL instead
# of N/A. See verification-loop.md §"L2 typography per-line".
#
# Usage:
#   c2-typography-extract.sh --cache <.figma-cache/nodeId>
#
# Exit:
#   0 — c2-typography-perline.json written (may be empty {} when no text)
#   1 — design-context.md missing or empty
#  64 — bad usage

set -uo pipefail

CACHE=""

print_usage() {
  cat <<'USAGE' >&2
usage: c2-typography-extract.sh --cache <.figma-cache/nodeId>

Pairs every text segment in design-context.md with its enclosing Tailwind
typography classes, normalizes them, and emits c2-typography-perline.json.
L2 trace consumes this to PASS/FAIL `.lineSpacing` / `.tracking` rows.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --cache)   CACHE="${2:-}"; shift 2 ;;
    -h|--help) print_usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; print_usage; exit 64 ;;
  esac
done

[ -n "$CACHE" ] || { print_usage; exit 64; }
[ -d "$CACHE" ] || { echo "FAIL: cache dir not found: $CACHE" >&2; exit 64; }

SRC="$CACHE/design-context.md"
OUT="$CACHE/c2-typography-perline.json"

if [ ! -s "$SRC" ]; then
  echo "FAIL: design-context.md missing or empty at $SRC" >&2
  exit 1
fi

python3 - "$SRC" "$OUT" <<'PY'
import json, os, re, sys
from html import unescape

src, out = sys.argv[1], sys.argv[2]
with open(src) as f:
    text = f.read()

# ── Tailwind typography resolution tables ───────────────────────────────────

# text-<size> → font-size in pt (assume 1px = 1pt for SwiftUI; design uses px)
TEXT_SIZE_MAP = {
    "text-xs":   12,
    "text-sm":   14,
    "text-base": 16,
    "text-lg":   18,
    "text-xl":   20,
    "text-2xl":  24,
    "text-3xl":  30,
    "text-4xl":  36,
    "text-5xl":  48,
    "text-6xl":  60,
    "text-7xl":  72,
    "text-8xl":  96,
    "text-9xl":  128,
}

# font-<weight> → Tailwind weight keyword (matches SwiftUI .font weight enum)
FONT_WEIGHT_MAP = {
    "font-thin":       "ultraLight",
    "font-extralight": "thin",
    "font-light":      "light",
    "font-normal":     "regular",
    "font-medium":     "medium",
    "font-semibold":   "semibold",
    "font-bold":       "bold",
    "font-extrabold":  "heavy",
    "font-black":      "black",
}

# leading-<name> → ratio (multiplier of fontSize). Tailwind defaults:
LEADING_KEYWORD_MAP = {
    "leading-none":    1.0,
    "leading-tight":   1.25,
    "leading-snug":    1.375,
    "leading-normal":  1.5,
    "leading-relaxed": 1.625,
    "leading-loose":   2.0,
}

# tracking-<name> → letter-spacing in em (Tailwind defaults)
TRACKING_KEYWORD_MAP = {
    "tracking-tighter": -0.05,
    "tracking-tight":   -0.025,
    "tracking-normal":  0.0,
    "tracking-wide":    0.025,
    "tracking-wider":   0.05,
    "tracking-widest":  0.1,
}

TEXT_CASE_CLASSES = {"uppercase", "lowercase", "capitalize", "normal-case"}
TEXT_ALIGN_MAP = {
    "text-left":    "left",
    "text-center":  "center",
    "text-right":   "right",
    "text-justify": "justify",
}

# ── Lightweight JSX scanner: tags + classNames stack ───────────────────────
#
# We tokenize the text into a stream of (kind, payload, position) where kind ∈
# {open_tag, close_tag, text}. For each text node we collect the merged class
# stack (concat of parents' classNames). The deepest class wins for typography
# resolution.
#
# Self-closing tags (`<br/>`, `<img ... />`) don't push onto the stack. Special
# tags like `<style>` / `<script>` we ignore entirely (text inside isn't UI
# copy).

OPEN_TAG_RE   = re.compile(r'<([A-Za-z][A-Za-z0-9._-]*)((?:\s+[^<>]*?)?)>')
CLOSE_TAG_RE  = re.compile(r'</([A-Za-z][A-Za-z0-9._-]*)\s*>')
SELF_CLOSE_RE = re.compile(r'/\s*$')
CLASS_ATTR_RE = re.compile(r'class(?:Name)?\s*=\s*"([^"]*)"')

# Tokenize: walk indices, alternate open/close/text.
tokens = []
i = 0
n = len(text)
while i < n:
    c = text[i]
    if c == '<':
        m_close = CLOSE_TAG_RE.match(text, i)
        if m_close:
            tokens.append(("close", m_close.group(1), i))
            i = m_close.end()
            continue
        m_open = OPEN_TAG_RE.match(text, i)
        if m_open:
            tag = m_open.group(1)
            attrs = m_open.group(2) or ""
            self_close = bool(SELF_CLOSE_RE.search(attrs))
            class_m = CLASS_ATTR_RE.search(attrs)
            cls = class_m.group(1) if class_m else ""
            if self_close:
                tokens.append(("selfclose", (tag, cls), i))
            else:
                tokens.append(("open", (tag, cls), i))
            i = m_open.end()
            continue
        # Not a recognizable tag — fall through as text char
    # Text node: read until next '<'
    j = text.find('<', i)
    if j == -1:
        j = n
    segment = text[i:j]
    if segment.strip():
        tokens.append(("text", segment, i))
    i = j

# Walk tokens, maintain stack of (tag, className), emit text segments with
# merged class stack.
stack = []
SKIP_TAGS = {"style", "script", "head", "noscript"}
skipping = 0  # depth counter for skip-content tags
text_buckets = []   # list of (raw_text, merged_classes_str)

for kind, payload, pos in tokens:
    if kind == "open":
        tag, cls = payload
        if tag.lower() in SKIP_TAGS:
            skipping += 1
        stack.append((tag, cls))
    elif kind == "selfclose":
        tag, cls = payload
        # No stack push (self-closing)
    elif kind == "close":
        tag_name = payload
        if tag_name.lower() in SKIP_TAGS and skipping > 0:
            skipping -= 1
        # Pop nearest matching open. Tolerant of mismatched markdown — pop
        # one level if last on stack matches by name, else leave alone.
        for k in range(len(stack) - 1, -1, -1):
            if stack[k][0] == tag_name:
                stack = stack[:k]
                break
    elif kind == "text":
        if skipping > 0:
            continue
        seg = payload.strip()
        if not seg:
            continue
        # Filter: skip JSX expression placeholders {var}, pure punctuation,
        # 1-char strings.
        if len(seg) < 2:
            continue
        if re.fullmatch(r'\{[^}]*\}', seg):
            continue
        if re.fullmatch(r'[\s,.:;\-—–_(){}\[\]<>=+/\\|*&^%$#@!?"\']+', seg):
            continue
        # Strip nested JSX expressions inside the segment
        cleaned = re.sub(r'\{[^}]+\}', '', seg).strip()
        if not cleaned or len(cleaned) < 2:
            continue
        cleaned = unescape(cleaned)
        merged_classes = " ".join(cls for _, cls in stack if cls)
        text_buckets.append((cleaned, merged_classes))

# ── Resolve typography per text segment ─────────────────────────────────────

def normalize_text(s):
    s = s.replace("‘", "'").replace("’", "'")
    s = s.replace("“", '"').replace("”", '"')
    s = s.replace("–", "-").replace("—", "-")
    s = re.sub(r'\s+', ' ', s).strip()
    return s.casefold()

def resolve_typography(class_str):
    """Walk the merged class string left-to-right, applying matching rules.
    Innermost (rightmost in the merged stack) wins by virtue of overwriting."""
    out = {
        "fontSize": None,
        "fontWeight": None,
        "leading": None,
        "tracking": None,
        "textCase": None,
        "italic": None,
        "textAlign": None,
        "classes": [],
    }
    for cls in class_str.split():
        if not cls:
            continue
        # Track every Tailwind class that hits a rule for debug
        matched = False
        # Plain text-<size>
        if cls in TEXT_SIZE_MAP:
            out["fontSize"] = TEXT_SIZE_MAP[cls]
            matched = True
        # Arbitrary size: text-[14px], text-[1.125rem]
        elif cls.startswith("text-[") and cls.endswith("]"):
            inner = cls[6:-1].strip()
            m = re.match(r'^(-?\d+(?:\.\d+)?)(px|rem|pt)?$', inner)
            if m:
                num = float(m.group(1))
                unit = m.group(2) or "px"
                if unit == "rem":
                    num *= 16.0
                out["fontSize"] = num
                matched = True
        # Text alignment
        elif cls in TEXT_ALIGN_MAP:
            out["textAlign"] = TEXT_ALIGN_MAP[cls]
            matched = True
        # Font weight
        elif cls in FONT_WEIGHT_MAP:
            out["fontWeight"] = FONT_WEIGHT_MAP[cls]
            matched = True
        # Leading keyword
        elif cls in LEADING_KEYWORD_MAP:
            out["leading"] = LEADING_KEYWORD_MAP[cls]
            matched = True
        # Leading numeric: leading-N (Tailwind scale where N×0.25rem)
        # or leading-[1.4] / leading-[24px]
        elif cls.startswith("leading-"):
            tail = cls[len("leading-"):]
            if tail.startswith("[") and tail.endswith("]"):
                inner = tail[1:-1].strip()
                m = re.match(r'^(-?\d+(?:\.\d+)?)(px|rem|pt)?$', inner)
                if m:
                    num = float(m.group(1))
                    unit = m.group(2)
                    if unit == "rem":
                        num *= 16.0
                    if unit in ("px", "pt"):
                        # absolute leading — caller divides by fontSize if needed
                        out["leading"] = num
                    else:
                        # bare number → ratio
                        out["leading"] = num
                    matched = True
            else:
                # bare integer: leading-3 → 0.75rem = 12px line-height. Tailwind
                # uses fixed multiples of 0.25rem. Skip for now — too ambiguous
                # without knowing fontSize.
                m = re.match(r'^(\d+(?:\.\d+)?)$', tail)
                if m:
                    out["leading"] = float(m.group(1))
                    matched = True
        # Tracking keyword
        elif cls in TRACKING_KEYWORD_MAP:
            out["tracking"] = TRACKING_KEYWORD_MAP[cls]
            matched = True
        # Tracking arbitrary: tracking-[N], tracking-[-0.5px]
        elif cls.startswith("tracking-[") and cls.endswith("]"):
            inner = cls[len("tracking-["):-1].strip()
            m = re.match(r'^(-?\d+(?:\.\d+)?)(px|em|rem)?$', inner)
            if m:
                num = float(m.group(1))
                unit = m.group(2) or "em"
                if unit == "rem":
                    num *= 16.0
                out["tracking"] = num
                matched = True
        # Text case modifiers
        elif cls in TEXT_CASE_CLASSES:
            out["textCase"] = None if cls == "normal-case" else cls
            matched = True
        # Italic
        elif cls == "italic":
            out["italic"] = True
            matched = True
        elif cls == "not-italic":
            out["italic"] = False
            matched = True

        if matched:
            out["classes"].append(cls)
    return out

by_text_normalized = {}
for raw, classes in text_buckets:
    norm = normalize_text(raw)
    if not norm:
        continue
    typ = resolve_typography(classes)
    # Skip entries that resolved zero typography classes — no useful signal.
    # Still keep if textAlign was set (sometimes alignment is the only hint).
    if not any(v is not None and v != [] and v is not False
               for k, v in typ.items() if k != "classes"):
        if not typ["classes"]:
            continue
    # Merge with existing: prefer first-seen for stability; track all classes
    if norm in by_text_normalized:
        prior = by_text_normalized[norm]
        for k, v in typ.items():
            if k == "classes":
                # union classes
                merged = list(dict.fromkeys((prior.get("classes") or []) + (v or [])))
                prior["classes"] = merged
            elif prior.get(k) is None and v is not None:
                prior[k] = v
    else:
        by_text_normalized[norm] = typ

output = {
    "schemaVersion": 1,
    "sourceFile": "design-context.md",
    "byTextNormalized": by_text_normalized,
}

tmp = out + ".tmp." + str(os.getpid())
with open(tmp, "w") as f:
    json.dump(output, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, out)

print(f"WROTE: {out}")
print(f"  segments resolved: {len(by_text_normalized)}")
sample = list(by_text_normalized.items())[:3]
for k, v in sample:
    print(f"    '{k}' → size={v['fontSize']} weight={v['fontWeight']} leading={v['leading']} tracking={v['tracking']}")
PY
RC=$?
exit $RC
