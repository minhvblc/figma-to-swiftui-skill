# Designer Handoff Guide for Figma -> SwiftUI Skills

## 1. Mục tiêu tài liệu

Tài liệu này giúp Designer chuẩn bị file Figma sao cho hai skill sau có thể đọc và map ổn định hơn:

- `figma-to-swiftui`
- `figma-flow-to-swiftui-feature`

Mục tiêu không phải để ép Designer thiết kế theo code, mà để giảm ambiguity khi AI phải map:

- screen -> node
- action -> element
- state -> UI representation
- component -> reusable code

## 2. Hai skill này đọc gì từ Figma

### `figma-to-swiftui`

Skill này dùng Figma làm nguồn chính cho:

- layout structure
- spacing, padding, sizing
- typography
- colors
- component hierarchy
- assets
- visual states nếu được thể hiện rõ

Skill này mạnh nhất khi input là một screen node hoặc một component node rõ ràng.

### `figma-flow-to-swiftui-feature`

Skill này dùng Figma + flow doc làm nguồn chính cho:

- screen list
- navigation flow
- action mapping
- state handling
- feature completeness

Skill này mạnh nhất khi flow doc mô tả behavior rõ, còn Figma mô tả rõ từng màn và từng state.

## 3. Nguyên tắc quan trọng nhất

### 3.1 Một screen thật trong app nên tương ứng với một frame rõ ràng trong Figma

Không nên để nhiều màn hình khác nhau nằm lẫn trong cùng một frame lớn mà không có cấu trúc rõ.

Tốt:

- `Splash`
- `Intro Step 1`
- `Intro Step 2`
- `Intro Step 3`
- `Main Todo / Empty`
- `Main Todo / List`

Không tốt:

- `Frame 12`
- `Screen final final`
- một frame lớn chứa 5 màn nhưng không tách child frame rõ ràng

### 3.2 Screen state và component state phải được tách rõ

Quy tắc đề xuất:

- `screen state` -> dùng frame riêng
- `component state` -> dùng component variants

Ví dụ:

- `Main Todo / Empty`
- `Main Todo / List`
- `Main Todo / Loading`
- `Main Todo / Error`

Trong khi đó component item có thể là:

- `Todo Item / State=Default`
- `Todo Item / State=Done`

### 3.3 Tên phải có nghĩa

AI map tốt hơn rất nhiều nếu tên node phản ánh đúng vai trò.

Ưu tiên:

- tên screen có nghĩa
- tên component có nghĩa
- tên variant property có nghĩa
- tên action có nghĩa

Không dùng:

- `Variant 1`
- `Group 14`
- `Rectangle 233`
- `Frame copy 2`

## 4. Cấu trúc file Figma đề xuất

## 4.1 Theo page hoặc section

Mỗi flow nên được gom theo page hoặc section rõ ràng.

Ví dụ:

- `Auth Flow`
- `Onboarding Flow`
- `Home`
- `Todo Main`
- `Components`

Nếu một flow có nhiều màn, nên đặt chúng trong cùng một section.

## 4.2 Theo cấp node

Cấu trúc khuyến nghị:

- Page
- Section
- Screen Frames
- Component Instances / local layers

Ví dụ:

```text
Page: Onboarding
Section: First Launch Flow
- Splash
- Intro Step 1
- Intro Step 2
- Intro Step 3
- Main Todo / Empty
- Main Todo / List
```

## 4.3 Khi phải share link root node

Nếu Designer hoặc PM chỉ share root node như `0:1`, thì trong Figma nên có:

- top-level frames rõ tên
- section name rõ ràng
- screen ordering dễ nhận biết

Tốt nhất vẫn là share link đúng node của từng màn khi cần implement chính xác.

## 5. Quy tắc đặt tên

## 5.1 Tên screen

Nên dùng tên ổn định, không mơ hồ.

Ví dụ tốt:

- `Splash`
- `Intro Step 1`
- `Intro Step 2`
- `Intro Step 3`
- `Main Todo / Empty`
- `Main Todo / List`
- `Main Todo / Error`

Nếu team dùng tiếng Việt thì vẫn được, nhưng phải nhất quán. Không nên trộn:

- `Màn intro 1`
- `Todo Main`
- `Frame 23`

trong cùng một flow.

## 5.2 Tên component

Ví dụ tốt:

- `Button / Primary`
- `Button / Secondary`
- `Todo Item`
- `Header / Simple`
- `Input / Todo`

## 5.3 Tên variant properties

Luôn dùng property có nghĩa, ví dụ:

- `State=Default|Disabled|Loading|Error|Done`
- `Size=Small|Medium|Large`
- `Type=Primary|Secondary|Tertiary`
- `Icon=On|Off`

Không dùng:

- `Property 1`
- `Style A`
- `Variant 2`

## 5.4 Tên action layer

Nếu có button hoặc control quan trọng, nên đặt tên layer hoặc instance đủ nghĩa để AI đọc được vai trò.

Ví dụ:

- `CTA / Next`
- `CTA / Skip`
- `Checkbox / Todo Done`
- `Action / Add Todo`

Điều này đặc biệt quan trọng khi màn có nhiều button giống nhau.

## 6. Quy tắc cho flow và điều hướng

## 6.1 Mỗi màn phải thể hiện rõ CTA chính và CTA phụ

Ví dụ:

- `Next` là primary CTA
- `Skip` là secondary CTA
- `Back` là navigation action

Nếu cả 2 CTA đều nhìn rất giống nhau, AI khó map action hơn.

## 6.2 Prototype connection là tốt, nhưng không đủ

Prototype links trong Figma rất hữu ích cho:

- hiểu flow
- hiểu transition
- hiểu screen order

Nhưng vẫn cần:

- tên screen rõ
- tên action rõ
- state rõ

Không nên chỉ dựa vào prototype mà node name vẫn mơ hồ.

## 6.3 Flow state phải thể hiện bằng frame hoặc note rõ ràng

Các state sau nếu có thì nên được thể hiện rõ:

- initial
- loading
- empty
- error
- success
- disabled

Nếu không thể thiết kế đủ tất cả state, ít nhất phải thể hiện:

- default
- empty hoặc populated
- disabled nếu có CTA phụ thuộc input

## 7. Quy tắc cho layout

## 7.1 Ưu tiên Auto Layout

Hai skill map tốt hơn khi Figma dùng:

- Auto Layout
- padding rõ
- gap rõ
- hug/fill đúng

Nên tránh lạm dụng:

- positioning tuyệt đối cho mọi thứ
- group lồng group không cần thiết
- frame không có Auto Layout dù UI rõ ràng là stack

## 7.2 Giữ text là text

Không convert text thành vector hoặc flatten nếu không thật sự cần.

AI cần đọc:

- title
- description
- button labels
- empty-state copy

## 7.3 Không flatten UI thành ảnh nếu nó là UI thật

Chỉ dùng image cho:

- illustration
- photo
- brand asset

Không nên flatten:

- button
- card
- list item
- input
- tab bar custom

## 7.4 System UI nên rõ là reference hay custom

Nếu Designer hiển thị:

- status bar
- home indicator
- keyboard
- native back button

thì nên xác định rõ đây là:

- reference only
- hay custom UI thật

Nếu không, AI có thể phải dừng để hỏi lại.

## 8. Quy tắc cho component và variants

## 8.1 Repeated UI phải thành component

Nếu một UI lặp nhiều lần, nên componentize.

Ví dụ:

- todo item
- primary button
- onboarding card
- header

Điều này giúp skill map về reusable code tốt hơn.

## 8.2 State của component nên là variants

Ví dụ với `Todo Item`:

- `State=Default`
- `State=Done`

Ví dụ với `Button`:

- `State=Default`
- `State=Disabled`
- `State=Loading`

## 8.3 Một component set không nên trộn nhiều ý nghĩa

Không nên để cùng một component set vừa là:

- button
- chip
- card

vì AI sẽ khó suy ra abstraction đúng.

## 9. Quy tắc cho asset

## 9.1 Asset phải là node riêng và có tên

Ví dụ:

- `Splash Logo`
- `Intro1 Illustration`
- `Main Empty Illustration`

## 9.2 Icon chuẩn nên dùng nhất quán

Nếu icon là icon phổ biến:

- arrow
- plus
- check
- close

hãy dùng hệ icon nhất quán trong design system. Skill có thể ưu tiên map sang SF Symbols nếu phù hợp.

## 9.3 Asset export nên rõ ràng

Các asset custom quan trọng nên:

- dễ tìm
- không bị lẫn trong frame sâu quá
- có tên semantic

## 9.4 Convention bắt buộc cho asset cần export tự động: `eIC*` / `eImage*`

Skill `figma-to-swiftui` dùng MCPFigma server (`figma-assets`) để batch-export icon và image trực tiếp vào `Assets.xcassets`. Để skill nhận diện được, asset cần được đặt tên trên Figma theo prefix:

| Prefix Figma | Loại | Sẽ thành |
|---|---|---|
| `eIC<Name>` | Icon (1 màu hoặc nhiều màu) | `icAI<Name>` trong `Assets.xcassets` |
| `eImage<Name>` | Image / illustration / brand | `imageAI<Name>` trong `Assets.xcassets` |

**Quy tắc validate:**
- Ký tự đầu sau prefix phải là chữ cái ASCII viết hoa: `eICHome` ✅, `eIChome` ❌
- Phần còn lại chỉ cho `[A-Za-z0-9_]`: `eICHome_2` ✅, `eICHome-2` ❌, `eICHomé` ❌
- Tên không hợp lệ → MCPFigma sẽ skip và emit warning trong output, asset đó rơi về fallback path (`get_screenshot`)

**Khi nào dùng prefix:**
- Mỗi icon atomic (close, chevron, home, search, …) → `eIC<Name>`
- Mỗi image / illustration / hero artwork đứng độc lập → `eImage<Name>`
- KHÔNG cần prefix cho:
  - Region cần FLATTEN (skill sẽ tự render qua `get_screenshot`)
  - Decorative shape vẽ được bằng SwiftUI (`Circle`, `Rectangle`, gradient)
  - Photo người dùng / dynamic content load qua URL

**Tại sao quan trọng:**
- Asset có prefix → skill chạy fast path: 1 batch call, đúng scale `@2x`/`@3x`, đúng tên iOS, tự import vào xcassets — không cần thao tác tay.
- Asset không có prefix → skill rơi về fallback path (`get_screenshot` từng node) — vẫn chạy, nhưng chậm hơn và phải đặt tên thủ công.

**Best practice:**
- Tag mọi asset reusable (icon + brand image) với prefix.
- Đặt cùng tên trên Figma cho asset dùng nhiều nơi (skill tự dedupe theo nodeId, không cần copy).
- Nếu một asset có biến thể light/dark, đặt 2 nodes riêng: `eICLogo` + `eICLogoDark` — skill sẽ export thành 2 imageset riêng. App tự pick theo `colorScheme`.

**Ví dụ tổ chức tốt:**

```text
Page: Home
Section: Top Bar
- eICMenu          (icon hamburger)
- eICSearch        (icon search)
- eICNotifications (icon chuông)
Section: Hero
- eImageHomeBanner (illustration full-width)
Section: Footer
- eICHome
- eICExplore
- eICProfile
```

## 9.5 Convention cho slot animation Lottie: `eAnim*`

Nếu màn có animation chạy bằng Lottie (loading spinner, success checkmark, onboarding hero animation, …), Designer **không** đặt là `eImage*` — đặt riêng prefix `eAnim<Name>`:

| Prefix Figma | Loại | Skill xử lý |
|---|---|---|
| `eAnim<Name>` | Slot animation Lottie | Skill sinh `LottieView(animation: .named("placeholder_animation"))` ở đúng vị trí + frame size, không tải PNG |

**Quy tắc validate:** giống `eIC*`/`eImage*` — UpperCamel sau prefix, ký tự `[A-Za-z0-9_]`.

**Khác biệt quan trọng so với `eIC*` / `eImage*`:**
- MCPFigma **bỏ qua** `eAnim*` khi quét — không tải PNG, không vào xcassets.
- Children của node `eAnim*` cũng bị bỏ qua (children chỉ là preview keyframes cho Designer xem; skill không inventory chúng).
- Skill không tự đặt tên Lottie thật — sinh placeholder constant `"placeholder_animation"` để dev thay sau khi Designer cung cấp file `.json`.

**Best practice cho Designer:**
- Frame chứa node `eAnim*` quy định **kích thước animation** trên app. Dev sẽ set `.frame(width:, height:)` đúng theo bounding box.
- KHÔNG đặt UI tương tác (button, input) bên trong slot `eAnim*` — slot chỉ chứa animation, mọi thứ khác Designer đặt cạnh hoặc chồng `ZStack` ở ngoài.
- Một animation = một node `eAnim*`. Cùng animation chạy ở nhiều màn → mỗi màn đặt 1 node riêng, dev sẽ wire chung 1 file Lottie sau.
- Cùng với file `.json` Lottie, Designer nên cung cấp tên file (vd. `loading_spinner.json`) để dev biết thay vào chỗ `"placeholder_animation"`.

**Ví dụ cấu trúc:**

```text
Section: Loading State
- eAnimLoading        (frame 120×120, child là 1 illustration preview)
Section: Success State
- eAnimSuccess        (frame 80×80)
- Text "Done!"
```

## 10. PM / Designer nên bàn giao thêm gì ngoài Figma

Figma tốt chưa đủ cho flow phức tạp. Bộ handoff tối thiểu nên có:

- screen list
- flow navigation
- primary action per screen
- secondary action per screen
- state chính
- empty/error/loading nếu có
- edge cases quan trọng

Nếu doc không map chính xác action vào vị trí, skill vẫn có thể map, nhưng sẽ phải dùng confidence và đôi khi dừng để hỏi lại.

## 11. Template handoff tối thiểu cho mỗi màn

Designer hoặc PM có thể bàn giao theo format ngắn sau:

```text
Screen: Intro Step 1
Purpose: giới thiệu app
Primary CTA: Next
Secondary CTA: Skip
Next screen: Intro Step 2
Important states: default
Notes: Skip đi thẳng Main và set onboarding completed
```

Nếu là màn có input:

```text
Screen: Main Todo
Purpose: thêm và quản lý todo
Primary CTA: Add
Actions:
- type text
- tap Add
- tap checkbox
States:
- empty
- list
- disabled add when input invalid
```

## 12. Ví dụ cấu trúc tốt cho app To-Do mẫu

```text
Page: Todo App

Section: Onboarding Flow
- Splash
- Intro Step 1
- Intro Step 2
- Intro Step 3

Section: Main Flow
- Main Todo / Empty
- Main Todo / List

Page: Components
- Button / Type=Primary / State=Default
- Button / Type=Primary / State=Disabled
- Todo Item / State=Default
- Todo Item / State=Done
```

## 13. Checklist trước khi bàn giao cho AI / Dev

Trước khi share link Figma, Designer nên check:

- Mỗi screen là một frame rõ ràng
- Tên screen có nghĩa
- Tên component có nghĩa
- Variant properties có nghĩa
- CTA chính/phụ dễ phân biệt
- Text còn là text, không bị flatten
- Repeated UI đã được componentize
- Các screen state chính đã được tách rõ
- Asset custom có tên semantic
- Nếu share root node, top-level frames được đặt tên rõ
- Nếu flow phức tạp, có doc ngắn mô tả navigation và actions

## 14. Mức kỳ vọng thực tế

Nếu Figma được tổ chức theo tài liệu này:

- `figma-to-swiftui` sẽ map layout và component chính xác hơn
- `figma-flow-to-swiftui-feature` sẽ map flow, action, state ổn định hơn
- giảm số lần AI phải hỏi lại
- giảm nguy cơ map sai button, sai screen, hoặc sai state

Nếu Figma không theo cấu trúc này, skill vẫn có thể chạy, nhưng:

- confidence thấp hơn
- dễ phải dừng để xác nhận
- dễ phát sinh mapping ambiguity
