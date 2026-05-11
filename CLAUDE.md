# CLAUDE.md — figma-to-swiftui-skill

Đây là **repo nguồn của hai Agent Skills** (không phải app iOS, không phải dự án SwiftUI).

```
figma-to-swiftui/                  # Skill 1: dịch 1 màn / 1 component
figma-flow-to-swiftui-feature/     # Skill 2: orchestrate nhiều màn thành 1 feature
scripts/                           # Gates bash bắt buộc (C5/C6/C7, doctor, install)
docs/                              # Cách 2 skill ghép với nhau
```

Khi bạn được gọi trong thư mục này, công việc gần như luôn là **bảo trì / sửa skill**, không phải chạy skill. Để chạy skill thì người dùng phải `cd` sang project iOS đích.

> ⚠️ **Mỗi lần `Write/Edit` chạm vào `scripts/` — TRƯỚC khi commit phải verify `install.sh` + `doctor.sh` + reference doc đã đồng bộ.** Đây là root-cause của lớp bug latent đã có precedent (`ikxcodegen-wrap.sh` + `xcodeproj-add-files.sh` orphan vì install.sh không copy). Bảng checklist chi tiết: section ["Đồng bộ cross-file (BẮT BUỘC sau mỗi edit chạm vào `scripts/`)"](#đồng-bộ-cross-file-bắt-buộc-sau-mỗi-edit-chạm-vào-scripts). Chạy `bash scripts/doctor.sh` sau mỗi đợt edit — phải in `All N of N checks passed` mới commit.

---

## Nguồn chân lý — đọc trước khi sửa bất cứ thứ gì

| Khi sửa | Đọc trước |
|---|---|
| Workflow Phase A→B→C, gates, exit criteria | [figma-to-swiftui/SKILL.md](figma-to-swiftui/SKILL.md) |
| Orchestration nhiều màn, screen graph, integration | [figma-flow-to-swiftui-feature/SKILL.md](figma-flow-to-swiftui-feature/SKILL.md) |
| Pass 2 inventory, weasel-word detection, side-by-side | [figma-to-swiftui/references/verification-loop.md](figma-to-swiftui/references/verification-loop.md) |
| Quy tắc visual fidelity & inventory codes | [figma-to-swiftui/references/visual-fidelity.md](figma-to-swiftui/references/visual-fidelity.md) |
| Asset pipeline: tagged path / fallback / dedupe | [figma-to-swiftui/references/asset-handling.md](figma-to-swiftui/references/asset-handling.md) |
| Background image + gradient overlay fills (fills.json từ `figma_extract_fills`) | [figma-to-swiftui/references/fills-handling.md](figma-to-swiftui/references/fills-handling.md) |
| MCPFigma tool reference & troubleshooting | [figma-to-swiftui/references/mcpfigma-setup.md](figma-to-swiftui/references/mcpfigma-setup.md) |
| Anti-patterns / failure modes from real runs | [figma-to-swiftui/references/anti-patterns.md](figma-to-swiftui/references/anti-patterns.md) |
| **Coding-conventions enforcement (folder layout, naming, ViewModel pattern, function size)** | [figma-to-swiftui/references/project-structure.md](figma-to-swiftui/references/project-structure.md), [viewmodel-pattern.md](figma-to-swiftui/references/viewmodel-pattern.md), [swift-style.md](figma-to-swiftui/references/swift-style.md) |
| **IKNavigation / IKMacros bridges (conditional, project-detected)** | [figma-to-swiftui/references/iknavigation-bridge.md](figma-to-swiftui/references/iknavigation-bridge.md), [ikmacro-bridge.md](figma-to-swiftui/references/ikmacro-bridge.md) |
| **Convention probe (C1) — emits `c1-conventions.json` to drive C2/C3 routing** | [figma-to-swiftui/references/adaptation-workflow.md](figma-to-swiftui/references/adaptation-workflow.md) §0 |
| Cách 2 skill compose end-to-end | [docs/workflow.md](docs/workflow.md) |

Các SKILL.md là spec đang chạy thực tế. **Đừng paraphrase, đừng "tóm tắt lại cho gọn"** — sửa trực tiếp SKILL.md hoặc reference tương ứng.

---

## Nguyên tắc bất di bất dịch (KHÔNG được nới lỏng khi edit)

Bốn quy tắc dưới đây là lý do tồn tại của skill này. Việc nới lỏng bất kỳ quy tắc nào — ngay cả "chỉ trong trường hợp này" — phá vỡ toàn bộ ý nghĩa của skill. Khi sửa SKILL.md hoặc reference, **không được phép gỡ bỏ rule mà không thay bằng rule mới mạnh tương đương** (kèm gate enforcement).

### 1. Figma là chân lý duy nhất

Mọi giá trị nhìn thấy trong code SwiftUI sinh ra (color, font, spacing, radius, copy, icon, illustration) **phải truy vết được về một node Figma cụ thể, một token Figma, hoặc `data-node-id` trong `design-context.md`**. Không có node = đoán = bug.

- MCP `figma-desktop` cho spec + screenshot. MCP `figma-assets` (MCPFigma) cho registry + tokens + asset export. **Cả hai đều bắt buộc.** Thiếu một → STOP, không improvise.
- Banned substitute MCPs (`mcp__figma__get_figma_data`, `mcp__figma__download_figma_images`, bất kỳ `mcp__figma_*__*` nào không phải `figma-desktop`/`figma-assets`) — không được dùng làm fallback. Detect-and-STOP.
- Output của MCP figma-desktop là **spec, không phải code**. Nó trả React + Tailwind; skill parse value ra rồi build SwiftUI native — không port web code.

### 2. Tuyệt đối không dùng icon / image hệ thống thay cho asset Figma

- `Image(systemName:)` cho bất kỳ element nào tồn tại như Figma node → **CẤM**. Enforced bởi `scripts/c6-asset-completeness.sh`.
- Hand-drawn `Path` / `Shape` / `Rectangle()` / `Text("G")` đứng thay logo / icon → **CẤM**.
- "Simplified" version của illustration Figma → **CẤM**.
- Allow-list duy nhất cho `Image(systemName:)`: iOS system chrome người dùng chủ động yêu cầu giữ system-default (vd back chevron trong NavigationStack toolbar, share-sheet icon). Mọi exception khác phải có comment `// allow-systemName:` kèm lý do.
- Asset không fetch được (node mất, MCP error sau retry) → **STOP và báo user**. Không improvise.

### 3. Không bao giờ vẽ lại iOS system chrome

Status bar (giờ "9:41", signal/wifi/battery), Dynamic Island, home indicator (~134×5pt), system keyboard, system back chevron — **iOS render những thứ này**. Vẽ lại trong SwiftUI là bug — duplicate cái iOS đang show và vỡ trên thiết bị thật.

- Figma frame thường mockup chrome này. Phải **nhận ra và strip khỏi Visual Inventory** trước khi code.
- Enforced bởi `scripts/c7-no-system-chrome.sh`.

### 4. Tôn trọng flow — không bỏ qua bước, không tự assume

Workflow là **Phase A → Phase B → Phase C, theo đúng thứ tự, có gate ở cuối mỗi phase**. Phase C có 5 self-check passes + C5 build/screenshot/diff + C6 asset completeness + C7 no-system-chrome + C8 coding-conventions.

- **Mỗi gate phải in `GATE: PASS` mới được sang phase tiếp theo.** Không có pass nào "bỏ được nếu vội".
- Khi gặp ambiguity (root node mơ hồ, screen-vs-state khó phân biệt, action mapping confidence thấp) → **STOP và hỏi user**. Không tự đoán.
- Failure-mode tự kiểm: nếu bắt gặp mình đang nghĩ *"SF Symbol gần đúng rồi"*, *"user không để ý đâu"*, *"bỏ pipeline lần này thôi"*, *"third-party MCP cũng tương tự, dùng tạm"*, *"đánh dấu approximation trong summary là được"*, *"flex non-negotiable một chút"* — **DỪNG NGAY**. Đó chính xác là failure mode skill này tồn tại để chặn.
- **Disclose bypass trong final summary KHÔNG cứu được run.** Quy tắc là "STOP và surface TRƯỚC khi act", không phải "act rồi confess sau". Run ship kèm disclaimer "non-negotiables flexed" = run thất bại, không phải run thành công có footnote.
- Visual diff không được dùng từ "weasel" (`approximately`, `roughly`, `close enough`, `~`, `nearly`, ...) trong PASS rows. Enforced bởi `scripts/c5-weasel-detect.sh`.

---

## Coding-conventions layer (lớp bổ sung trên 4 nguyên tắc)

4 nguyên tắc trên về **Figma là chân lý** + **chống improvise**. Layer C8 là về **shape của code generated** — nó không thay thế 4 nguyên tắc, nó chồng lên.

C1 step **probe project conventions** rồi ghi `c1-conventions.json`. Mọi quyết định trong C2 (Implement) đọc file này để khớp với project hiện tại — folder layout, ViewModel pattern, có IKNavigation hay không, có IKMacros hay không, IKFont enum tên gì.

| Convention | Reference | Enforcement |
|---|---|---|
| Screens/<Name>Screen/<Name>Screen.swift, prefix subview | `figma-to-swiftui/references/project-structure.md` | `scripts/c8-conventions-gate.sh` |
| @MainActor + enum Action + send(_:) reducer + flat @Published | `figma-to-swiftui/references/viewmodel-pattern.md` | `scripts/c8-vm-pattern.sh` |
| Function ≤ 50 dòng (hard), subview ≤ 50 dòng | `figma-to-swiftui/references/swift-style.md` §2-3 | `scripts/c8-func-length.sh` |
| Golden path (guard early), modifier order, [weak self], custom Error enum | `figma-to-swiftui/references/swift-style.md` §4-9 | `scripts/c8-weak-self.sh` (warn) |
| IKNavigation thay cho NavigationStack (chỉ khi project đã dùng) | `figma-to-swiftui/references/iknavigation-bridge.md` | `scripts/c8-iknavigation.sh` (skip nếu off) |
| IKMacros (@APIProtocol, @JsonSerializable) cho DTO/service (chỉ khi project đã dùng) | `figma-to-swiftui/references/ikmacro-bridge.md` | (compile-time validated) |
| IKFont/AppFont enum thay cho .font(.system(size:)) raw (chỉ khi project có) | `figma-to-swiftui/references/swiftui-pro-bridge.md` §3 | `scripts/c8-ikfont.sh` (skip nếu off) |

**Detect-then-apply.** Nếu project iOS đích **không** có IKNavigation / IKMacros / IKFont → skill emit vanilla SwiftUI. Skill **không** import dependency mới mà user chưa có. Conventions tuyệt đối (folder layout, ViewModel pattern, function size) thì luôn áp dụng — không phụ thuộc project flag.

**Dual-layer enforcement** (giống C6/C7):
- **Write-time** (PostToolUse hook `scripts/hooks/figma-to-swiftui-c8-gate.sh`): chạy ngay sau mỗi `Write/Edit *.swift`, catch path/naming/ViewModel violations trên file vừa write. Block tiếp tục cho đến khi sửa.
- **Session-end** (Stop hook `scripts/hooks/figma-to-swiftui-stop-gate.sh`): chạy C8 toàn bộ tree cùng C5/C6/C7 — final safety net cho những thứ write-time không thấy (vd parent-view existence, cross-file consistency).

---

## Khi sửa skill: checklist

- [ ] Đã đọc SKILL.md liên quan **đầy đủ** trước khi sửa (không chỉ section đang đụng).
- [ ] Thay đổi không nới lỏng 4 nguyên tắc trên — hoặc nếu có gỡ rule cũ thì đã có rule mới + gate thay thế.
- [ ] Nếu thêm/đổi banned phrase, banned MCP, allow-list — đồng bộ giữa **cả hai** SKILL.md, các reference liên quan, và script bash trong `scripts/`.
- [ ] **Nếu thêm/đổi/xoá BẤT KỲ script nào trong `scripts/` (kể cả non-gate) — chạy "Đồng bộ cross-file" checklist trong section "Khi sửa script" phía dưới.** Bốn vị trí phải đồng bộ: `install.sh` glob, `doctor.sh` §7 hard-coded list (cả hai vị trí — `SCRIPTS_DIR` và `INSTALLED_SCRIPTS_DIR`), `doctor.sh` §9 drift glob, và reference doc tham chiếu (nếu script được skill gọi). Bỏ sót 1 trong 4 = bug latent (đã từng xảy ra với `ikxcodegen-wrap.sh` + `xcodeproj-add-files.sh`).
- [ ] Phrase trigger trong frontmatter `description:` của SKILL.md giữ cả tiếng Việt (`làm màn này`, `code màn iOS theo Figma`, ...) lẫn tiếng Anh (`implement Figma to SwiftUI`, ...).
- [ ] Không thêm `Image(systemName:)`, không thêm SF Symbol example trong reference trừ khi đang viết về allow-list.
- [ ] Không tạo file mới `.md` ngoài `SKILL.md` / `references/*.md` / `docs/*.md` trừ khi user yêu cầu rõ.

---

## Khi sửa script (`scripts/`)

**Driver scripts (Tier 1 speed wins):** ngoài các gate cũ (C5/C6/C7/C8), repo có driver scripts gộp công đoạn:

| Script | Thay thế việc agent gõ tay | Phase |
|---|---|---|
| `c1-probe.sh` | 11 grep/find của §0 conventions probe | C1 |
| `b0a-extract-copy.sh` | Parse design-context.md → Strings.swift | B0a |
| `b0b-tokens-codegen.sh` | Wrap colorset-codegen + emit Color+Tokens / AppFont / Spacing | B0b |
| `c5-capture.sh` | simctl screenshot + sips shrink (cmp pair) | C5.5 + C5.5b |
| `c3-static-checks.sh` | Pass 3 + 3b + Pass 4 Part A bash sweep | C3 |
| `c8-all.sh` | 6 c8-* gates chạy song song | C3 Pass 5 |
| `timing-report.sh` | Đọc manifest.timing và in bảng wall-time | regression check |
| `timed-run.sh` | Helper của `timing-report.sh` — wrap command, record wall-time vào manifest.timing | per-step instrumentation |
| `preflight-bundle-verify.sh` | Pull canonical bundle ID từ Info.plist + check sim cho prefix collision | Phase 0 |
| `preflight-smoke-test.sh` | Build + launch scaffold + screenshot baseline TRƯỚC Phase A | Phase 0 |
| `b0c-fonts-fetch.sh` | Download Inter / Playfair Display / ... từ curated mirror table | B0c |
| `b0d-info-plist-fonts.sh` | Idempotent inject `UIAppFonts` vào Info.plist | B0d |
| `b0a-tokens-from-design-context.sh` | Fallback path khi `figma_extract_tokens` 403 — parse hex từ design-context.md | B0a fallback |
| `sync-check.sh` | Verify mọi script trong scripts/ obeys 4-position cross-file sync rule | meta — anti-orphan |

Driver scripts **không đổi semantics** — chỉ gộp call. Bash blocks gốc trong SKILL.md vẫn còn nguyên làm fallback explicit form. Khi sửa logic 1 gate, sửa ở **cả** sub-script gốc lẫn driver.

- Mọi script gate (C5/C6/C7/C8) đều phải in `GATE: PASS`, `GATE: FAIL: <reason>`, hoặc `GATE: SKIP (<reason>)` ở cuối, exit code khớp.
- C8 conditional gates (`c8-iknavigation.sh`, `c8-ikfont.sh`) đọc `c1-conventions.json` để biết nên enforce hay skip — đừng bypass bằng cách hard-code skip.
- Không bypass gate bằng cách trả PASS sớm với edge case mơ hồ — báo FAIL và để user quyết.
- Awk script phải POSIX-compatible (BSD awk trên macOS): không dùng `match(str, regex, array)` 3-arg form (gawk-only). Dùng `match()` 2-arg + `RSTART`/`RLENGTH`, hoặc loop ký tự.
- `install.sh` idempotent, safe re-run. Phải copy gate scripts vào cả `~/.claude/hooks/` (cho hook entrypoints) và `~/.claude/scripts/` (để stop-gate fallback resolution tìm thấy).
- `doctor.sh` chỉ verify, không sửa. Phải verify cả `~/.claude/hooks/` lẫn `~/.claude/scripts/` chứa đầy đủ script.

### Đồng bộ cross-file (BẮT BUỘC sau mỗi edit chạm vào `scripts/`)

Đây là root cause của lớp bug latent đã có precedent trong repo này — `ikxcodegen-wrap.sh` + `xcodeproj-add-files.sh` add vào repo trong các commit Phase 7 nhưng **không** được `install.sh` copy → không tới `~/.claude/scripts/` → stop-gate fallback resolution không tìm thấy → user vô hình bị mất chức năng. `doctor.sh` drift check không catch vì chỉ compare SHA khi cả `src` lẫn `dst` cùng tồn tại. Bug ngủ yên cho tới khi ai đó manual `ls` mới thấy.

**Quy tắc bắt buộc**: mỗi khi `Write/Edit` chạm vào `scripts/`, ngay sau khi save file, chạy hết bảng dưới. Không có ngoại lệ "trivial change" — kể cả sửa docstring cũng phải verify drift gate vẫn pass (vì `doctor.sh` §9 hash-compare sẽ flag mismatch). Sót 1 dòng = commit broken.

| Loại thay đổi | Phải đồng bộ ở | Kiểm tra |
|---|---|---|
| **Add** script `scripts/<new>.sh` | (a) `install.sh`: block `for src in "$SCRIPTS_SRC"/b0a-*.sh ...` (tìm bằng `grep -n 'SCRIPTS_SRC.*b0a' install.sh`); (b) `doctor.sh` §7 first list (tìm bằng `grep -n '^for script in c5-crop' doctor.sh`); (c) `doctor.sh` §7 second list dưới `INSTALLED_SCRIPTS_DIR` (tìm bằng `grep -n 'for script in c5-coverage-check' doctor.sh`); (d) `doctor.sh` §9 drift glob (tìm bằng `grep -n 'SCRIPTS_REPO.*c1' doctor.sh`); (e) reference doc tham chiếu (SKILL.md hoặc `references/*.md`) nếu skill flow phải gọi script | `scripts/doctor.sh` in ra `<new>.sh present and executable` ở cả `$SCRIPTS_DIR` và `$INSTALLED_SCRIPTS_DIR`; `All N of N checks passed` |
| **Rename** `<old>.sh` → `<new>.sh` | Như trên + `grep -rln '<old>\.sh' .` thay từng chỗ + xoá `<old>.sh` ở `~/.claude/scripts/` thủ công | doctor §9 không còn flag `<old>.sh` drift; grep repo trả 0 hit cho `<old>` |
| **Delete** `<new>.sh` | Bỏ khỏi (a)-(d) trên + xoá ở `~/.claude/scripts/` thủ công + grep clean references | doctor pass clean |
| **Modify behavior** (đổi flag, đổi output format, đổi exit code) | `grep -rln '<name>\.sh' .` để tìm caller (SKILL.md / references / driver scripts) — cập nhật call-site doc nếu syntax đổi | Call-site trong SKILL.md không reference flag đã xoá / output format đã đổi |
| **Modify content** (sửa logic không đổi interface) | Re-deploy via `scripts/install.sh --yes` (token lấy từ `~/.claude.json`) HOẶC manual `cp` sang `~/.claude/scripts/` + `chmod +x` | `bash -n` clean; `doctor.sh` §9 in ra `no drift detected` |
| **Add hook** `scripts/hooks/<new>.sh` | (a) `install.sh`: Python `GATES = [` list (tìm bằng `grep -n 'GATES = \[' install.sh`) — chọn `PreToolUse` / `PostToolUse` / `Stop` + matcher; (b) `doctor.sh` §8 `EXPECTED_HOOKS=(...)` (tìm bằng `grep -n '^EXPECTED_HOOKS=' doctor.sh`); (c) re-deploy via `install.sh --yes` | doctor §8 in ra `<new>.sh registered (<event>)` |

**Verify command** (chạy NGAY sau Write/Edit + trước commit):
```bash
bash -n scripts/<changed>.sh           # syntax
scripts/doctor.sh                       # full check — phải pass All N of N
git diff --stat scripts/install.sh scripts/doctor.sh  # confirm 2 file cũng đụng nếu add script mới
```

Nếu chỉ đụng tới script nhưng `install.sh` / `doctor.sh` không changed trong `git diff` → 90% là sót đồng bộ. Re-check bảng trên.

**Reference doc requirement** (anti-orphan): mọi script trong `scripts/` (trừ `install.sh` / `doctor.sh` / `bootstrap.sh` — meta-scripts) PHẢI được tham chiếu từ ít nhất 1 trong:
- `figma-to-swiftui/SKILL.md` (skill flow gọi)
- `figma-to-swiftui/references/*.md` (giải thích usage)
- `figma-flow-to-swiftui-feature/SKILL.md` hoặc `references/*.md`
- Driver script khác (vd `c8-all.sh` orchestrates `c8-*.sh` subs)

Script không có call-site = orphan. Hoặc wire vào doc, hoặc xoá. Đừng để nằm chờ "biết đâu sau này dùng" — đó là cách orphan code accumulates.

---

## Tone khi viết tài liệu skill

- Chỉ thị (imperative): "STOP", "MUST", "BANNED", "Do NOT".
- Có failure-mode self-check ("Nếu bạn đang nghĩ X — DỪNG").
- Có script enforcement đi kèm cho mọi rule (rule không có gate = rule sẽ bị bỏ qua).
- Không pad bằng "however, in some cases", "it depends", "you may want to consider" — skill này thiên về tuyệt đối, không tương đối.

Đây là **skill cứng**, không phải skill khuyến nghị. Tone phải phản ánh điều đó.
