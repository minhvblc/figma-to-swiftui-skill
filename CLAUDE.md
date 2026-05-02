# CLAUDE.md — figma-to-swiftui-skill

Đây là **repo nguồn của hai Agent Skills** (không phải app iOS, không phải dự án SwiftUI).

```
figma-to-swiftui/                  # Skill 1: dịch 1 màn / 1 component
figma-flow-to-swiftui-feature/     # Skill 2: orchestrate nhiều màn thành 1 feature
scripts/                           # Gates bash bắt buộc (C5/C6/C7, doctor, install)
docs/                              # Cách 2 skill ghép với nhau
```

Khi bạn được gọi trong thư mục này, công việc gần như luôn là **bảo trì / sửa skill**, không phải chạy skill. Để chạy skill thì người dùng phải `cd` sang project iOS đích.

---

## Nguồn chân lý — đọc trước khi sửa bất cứ thứ gì

| Khi sửa | Đọc trước |
|---|---|
| Workflow Phase A→B→C, gates, exit criteria | [figma-to-swiftui/SKILL.md](figma-to-swiftui/SKILL.md) |
| Orchestration nhiều màn, screen graph, integration | [figma-flow-to-swiftui-feature/SKILL.md](figma-flow-to-swiftui-feature/SKILL.md) |
| Pass 2 inventory, weasel-word detection, side-by-side | [figma-to-swiftui/references/verification-loop.md](figma-to-swiftui/references/verification-loop.md) |
| Quy tắc visual fidelity & inventory codes | [figma-to-swiftui/references/visual-fidelity.md](figma-to-swiftui/references/visual-fidelity.md) |
| Asset pipeline: tagged path / fallback / dedupe | [figma-to-swiftui/references/asset-handling.md](figma-to-swiftui/references/asset-handling.md) |
| MCPFigma tool reference & troubleshooting | [figma-to-swiftui/references/mcpfigma-setup.md](figma-to-swiftui/references/mcpfigma-setup.md) |
| Anti-patterns / failure modes from real runs | [figma-to-swiftui/references/anti-patterns.md](figma-to-swiftui/references/anti-patterns.md) |
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

Workflow là **Phase A → Phase B → Phase C, theo đúng thứ tự, có gate ở cuối mỗi phase**. Phase C có 4 self-check passes + C5 build/screenshot/diff + C6 asset completeness + C7 no-system-chrome.

- **Mỗi gate phải in `GATE: PASS` mới được sang phase tiếp theo.** Không có pass nào "bỏ được nếu vội".
- Khi gặp ambiguity (root node mơ hồ, screen-vs-state khó phân biệt, action mapping confidence thấp) → **STOP và hỏi user**. Không tự đoán.
- Failure-mode tự kiểm: nếu bắt gặp mình đang nghĩ *"SF Symbol gần đúng rồi"*, *"user không để ý đâu"*, *"bỏ pipeline lần này thôi"*, *"third-party MCP cũng tương tự, dùng tạm"*, *"đánh dấu approximation trong summary là được"*, *"flex non-negotiable một chút"* — **DỪNG NGAY**. Đó chính xác là failure mode skill này tồn tại để chặn.
- **Disclose bypass trong final summary KHÔNG cứu được run.** Quy tắc là "STOP và surface TRƯỚC khi act", không phải "act rồi confess sau". Run ship kèm disclaimer "non-negotiables flexed" = run thất bại, không phải run thành công có footnote.
- Visual diff không được dùng từ "weasel" (`approximately`, `roughly`, `close enough`, `~`, `nearly`, ...) trong PASS rows. Enforced bởi `scripts/c5-weasel-detect.sh`.

---

## Khi sửa skill: checklist

- [ ] Đã đọc SKILL.md liên quan **đầy đủ** trước khi sửa (không chỉ section đang đụng).
- [ ] Thay đổi không nới lỏng 4 nguyên tắc trên — hoặc nếu có gỡ rule cũ thì đã có rule mới + gate thay thế.
- [ ] Nếu thêm/đổi banned phrase, banned MCP, allow-list — đồng bộ giữa **cả hai** SKILL.md, các reference liên quan, và script bash trong `scripts/`.
- [ ] Nếu thêm script gate mới — cập nhật cả `scripts/install.sh` (nếu cần auto-install hook) và `scripts/doctor.sh` (verify registration).
- [ ] Phrase trigger trong frontmatter `description:` của SKILL.md giữ cả tiếng Việt (`làm màn này`, `code màn iOS theo Figma`, ...) lẫn tiếng Anh (`implement Figma to SwiftUI`, ...).
- [ ] Không thêm `Image(systemName:)`, không thêm SF Symbol example trong reference trừ khi đang viết về allow-list.
- [ ] Không tạo file mới `.md` ngoài `SKILL.md` / `references/*.md` / `docs/*.md` trừ khi user yêu cầu rõ.

---

## Khi sửa script (`scripts/`)

- Mọi script gate (C5/C6/C7) đều phải in `GATE: PASS` hoặc `GATE: FAIL: <reason>` ở cuối, exit code khớp.
- Không bypass gate bằng cách trả PASS sớm với edge case mơ hồ — báo FAIL và để user quyết.
- `install.sh` idempotent, safe re-run. `doctor.sh` chỉ verify, không sửa.

---

## Tone khi viết tài liệu skill

- Chỉ thị (imperative): "STOP", "MUST", "BANNED", "Do NOT".
- Có failure-mode self-check ("Nếu bạn đang nghĩ X — DỪNG").
- Có script enforcement đi kèm cho mọi rule (rule không có gate = rule sẽ bị bỏ qua).
- Không pad bằng "however, in some cases", "it depends", "you may want to consider" — skill này thiên về tuyệt đối, không tương đối.

Đây là **skill cứng**, không phải skill khuyến nghị. Tone phải phản ánh điều đó.
