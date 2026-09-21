# Handoff: Sermiva — iOS (SwiftUI)

Trạng thái: **thiết kế đã chốt**. Tài liệu này mô tả phiên bản cuối của prototype để triển khai native bằng SwiftUI (Claude Code + Xcode).

## 1. Về gói bàn giao

- Các file `.dc.html` là **tham chiếu thiết kế viết bằng HTML** (prototype tương tác, dữ liệu mô phỏng). Không ship HTML; **tái tạo** giao diện và hành vi trong SwiftUI theo pattern của codebase.
- Độ hoàn thiện: **hi-fi**. Màu, chữ, khoảng cách, bo góc và trạng thái trong prototype là giá trị cuối; SwiftUI dùng SF Pro (system), SF Symbols và Dynamic Type tương ứng.
- Prototype **không gọi API thật**, không chứa khóa thật. Mọi thứ đánh dấu **[mô phỏng]** chỉ tồn tại trong prototype; **[thật]** cần triển khai và kiểm thử với Soniox.

## 2. Màn hình và luồng

```
Setup (chưa có khóa) ─► Conversation ◄─► Settings
                          │  ├ sheet: Kiểu hiển thị (5 thẻ)
                          │  ├ sheet: Cỡ chữ
                          │  ├ sheet: Kết thúc phiên (xác nhận)
                          │  └ alert: Quyền micro (lần đầu nhấn Bắt đầu)
                          └ Settings ► sheet: chọn ngôn ngữ (Bạn / Khách / Hiển thị cho Khách)
```

### 2.1 SetupView
Hiện khi Keychain chưa có khóa. Icon app, tiêu đề “Kết nối Soniox”, ô khóa dạng bảo mật (hiện/ẩn), nút “Dán khóa demo” **[mô phỏng]**, trạng thái kiểm tra, nút chính “Kiểm tra và tiếp tục”, nút phụ “Dùng thử bản demo (không nối Soniox)”. Khóa hợp lệ mô phỏng: `^sx_[A-Za-z0-9]{10,}$`.

### 2.2 ConversationView
- **TopBar**: cấu hình ngôn ngữ đang áp dụng (vd. “Tiếng Việt ↔ Tự nhận diện · English”), huy hiệu `DEMO` khi ở demo, dòng trạng thái kết nối có chấm màu + chữ, nút Settings (44 pt).
- **Banner** (tùy trạng thái): mất mạng (spinner, “nội dung được giữ”), lỗi xác thực (→ Mở Cài đặt), quyền micro bị từ chối (→ Mở Cài đặt iPhone), cấu hình ngôn ngữ chờ áp dụng (thông tin).
- **TranscriptView**: một trong 5 layout (mục 3), cùng đọc `SessionStore.segments`. Đổi layout không chạm mic, không xóa nội dung.
- **Bottom dock** (nổi trên nội dung, nền `bg` 88% + blur): TTS bar (khi đang đọc/chờ), dòng trạng thái mic (chấm + icon + chữ), hàng nút: `Aa Cỡ chữ` · `Hiển thị` · **nút chính** (Bắt đầu / Tạm dừng / Tiếp tục / Phiên mới, pill 50 pt, `accent`; xanh `ok` khi đang tạm dừng) · `Kết thúc` (đỏ `danger`, luôn qua sheet xác nhận).
- **Vùng cuộn**: đệm dưới = chiều cao đo thật của dock (+52 pt khi nút “Về trực tiếp” hiện) + home indicator. Tự cuộn chỉ khi người dùng ở mép live; kéo lên đọc lại thì **không** kéo xuống; hiện nút “Về trực tiếp · N” trong dải riêng trên dock, không phủ chữ (cả dọc/ngang, cỡ chữ tối đa).
- **Trạng thái rỗng**: “Sẵn sàng bắt đầu” (idle) / “Đang nghe…” (listening, chấm đỏ nhấp).

### 2.3 SettingsView (List grouped, thứ tự cố định)
1. **SONIOX API** — chưa có khóa: ô bảo mật + “Dán” + “Chưa nhập khóa”. Có khóa: hiện/ẩn, hàng “Kiểm tra kết nối” + trạng thái cùng hàng (Chưa kiểm tra / Đang kiểm tra… / Khóa hợp lệ / Khóa không hợp lệ / Lỗi mạng), hàng “Thay thế” · “Xóa”.
2. **NGÔN NGỮ** — một card, hai phần ngăn bằng separator thụt lề:
   - Ngôn ngữ giao diện: segmented Tiếng Việt / English.
   - Ngôn ngữ hội thoại (mục 4).
3. **HIỂN THỊ** — Kiểu hiển thị (hàng mở cùng sheet 5 thẻ của màn hội thoại) · “Phóng to câu mới nhất” (chỉ hiện khi kiểu = Phụ đề) · Giao diện (Hệ thống / Sáng / Tối) · Cỡ chữ (slider 6 mức + bản xem trước song ngữ).
4. **GIỌNG NÓI** — “Đọc bản dịch thành tiếng” (mặc định tắt) · “Phân biệt người nói” (mặc định bật). Footer: “Chỉ đọc câu đã dịch xong, chờ khi có người đang nói.”

## 3. Năm kiểu hiển thị (chung dữ liệu, chung phiên)

| Kiểu | Bố cục | Ghi chú |
|---|---|---|
| **Phụ đề** (mặc định) | Tất cả căn trái. Câu hiện tại trên surface + vạch nhấn trái 3 pt (`accent`), nguyên văn 16 pt×fs, bản dịch 24 pt×fs semibold. Lịch sử: 14 / 17 pt×fs, ngăn bằng separator. | Ở 2 mức chữ lớn nhất câu hiện tại dùng cỡ cơ sở (không nhân thêm). Công tắc “Phóng to câu mới nhất”. |
| **Bong bóng** | Trái/phải **theo nhãn người nói** (A trái, B phải, Chưa xác định giữa, full-width). Nguyên văn 14, bản dịch 18 pt×fs semibold. | Tắt diarization → bố cục trung tính, không nhãn. Cỡ chữ lớn: rộng 96%, padding 8/12, bo 14. |
| **Sân khấu** | Đọc từ xa. Nguyên văn 22, bản dịch 40 pt×fs semibold. Điều khiển thu gọn được; mic luôn thấy; nút ✕ thoát về kiểu trước. | Không karaoke từng từ. |
| **Đối diện** (biến thể Sân khấu) | Hai vùng đọc; vùng trên `rotationEffect(180°)`. Mỗi vùng hiện câu mới nhất bằng ngôn ngữ của người đọc bên đó (dòng lớn 30 pt×fs), dòng nhỏ là ngôn ngữ kia. Dải giữa cố định: mic · Tạm dừng · Đổi bên · ✕. | Safe area đặt trên wrapper không xoay (trên 54 pt, dưới 34 pt dọc / 22 pt ngang). Câu ngắn căn giữa dọc; câu dài cuộn. ✕ chỉ thoát Sân khấu, không kết thúc phiên. |
| **Kịch bản** | Danh sách theo thời gian: cột mốc `m:ss` 44 pt · nhãn người nói (nếu có) · ngôn ngữ · nguyên văn 14 · bản dịch 16 pt×fs. | Tắt diarization → giữ mốc & ngôn ngữ, bỏ A/B. |

Sheet chọn kiểu: 5 thẻ xem trước dạng lưới 2 cột, thẻ đang chọn viền `accent` + dấu ✓. Settings và sheet dùng chung `displayStyle`.

## 4. Cấu hình ngôn ngữ (cuối cùng)

Ba giá trị **độc lập**, lưu bằng `@AppStorage("languageConfig")` (prototype: `localStorage["sermiva.langcfg"]`):

| Khóa | Ý nghĩa | Giá trị | Mặc định |
|---|---|---|---|
| `me` | Ngôn ngữ Bạn nói | ngôn ngữ cụ thể | `vi` |
| `guest` | Ngôn ngữ Khách nói | `auto` hoặc cụ thể | `auto` |
| `target` | Ngôn ngữ hiển thị cho Khách | ngôn ngữ cụ thể | `en` |

Ràng buộc: `me ≠ target`, `guest ≠ me`. `target` **không** tự đổi theo `guest`.

Bố cục trong Settings:
```
Ngôn ngữ hội thoại
[ Bạn            ⌄ ] [ Khách           ⌄ ]
Ngôn ngữ hiển thị cho Khách
[ Tiếng Anh                          ⌄ ]
Dịch lời bạn sang ngôn ngữ này.
```
Mỗi ô mở một sheet chọn: tìm kiếm (không phân biệt dấu), danh sách cuộn, dấu ✓; ô Khách có thêm mục “Tự nhận diện · Nhận diện ngôn ngữ theo từng câu”. Mục trùng bị mờ, ghi “Đang dùng cho <ô>”. Không có tab chế độ, không có nút hoán đổi.

Quy tắc điều phối **[mô phỏng]**: đoạn có language-ID = `me` → dịch sang `target`; đoạn khác → dịch sang `me`; `guest` cụ thể chỉ thu hẹp nhận diện. TTS đọc theo đích tương ứng.

Áp dụng: khi không có phiên → ngay. Khi phiên đang chạy (listening/paused/connecting/reconnecting) → lưu vào `pendingConfig`, hiện chú thích “Thay đổi áp dụng từ phiên tiếp theo.” trong Settings và banner trên màn hội thoại; áp dụng khi Kết thúc hoặc Bắt đầu phiên kế tiếp. Không đổi cấu hình giữa phiên.

Header hội thoại: `{me} ↔ {guest|Tự nhận diện}` + ` · {target}` khi `target ≠ guest`. Đoạn chưa có language-ID hiện “Đang nhận diện ngôn ngữ”.

**[thật]** “Bạn / Khách” là nhãn cấu hình trải nghiệm. **Không suy ra danh tính người nói từ ngôn ngữ**; nhãn A/B/Chưa xác định luôn từ diarization. Việc gán người nói và định tuyến dịch theo language-ID từng đoạn thuộc lớp tích hợp Soniox; không giả định một cấu hình two-way làm được toàn bộ. Danh sách ngôn ngữ thật lấy từ khả năng của model; prototype dùng 12 ngôn ngữ mẫu.

## 5. Máy trạng thái phiên

```
idle → requestingMic → connecting → listening ⇄ paused → ended
                 ↘ micDenied            ↘ reconnecting (giữ segments, mic giữ quyền)
                                        ↘ authError (dừng stream, banner → Settings)
```
- Nút chính ánh xạ từ trạng thái: idle → Bắt đầu · listening/reconnecting → Tạm dừng · paused → Tiếp tục · connecting → spinner, disabled · ended → Phiên mới.
- Xin quyền micro **đúng lúc** nhấn Bắt đầu lần đầu (alert hệ thống). Bị từ chối → banner + `UIApplication.openSettingsURLString`.
- Kết thúc luôn qua sheet xác nhận (tiêu đề, mô tả, tóm tắt “N đoạn · m:ss”, nút đỏ “Kết thúc phiên”, Hủy).
- Trạng thái mic trên dock **chỉ** là: Mic tắt / Đang mở mic… / Đang nghe / Đã tạm dừng / Mic giữ, chờ mạng / Chưa có quyền mic. “Đang nhận dạng” và “Đang dịch…” nằm **trên đoạn**.

## 6. Streaming & segment

```swift
struct Segment { id; speaker: String?; lang: String?; source; target; isFinal; startedAt }
```
- Partial cập nhật tại chỗ theo `id`; final khóa `source`, sau đó điền `target`. Không tô mờ partial; dùng nhãn “Đang nhận dạng” + caret nhấp (`accent`). Không karaoke từng từ.
- Placeholder “Đang dịch…” là nhãn nhỏ cố định (12–15 pt) + spinner, **không nhân** cỡ chữ; bản dịch xuất hiện mới dùng cỡ người dùng chọn. Không hard-code chiều cao → không nhảy bố cục.
- `speaker == nil` → “Chưa xác định”. Không tự gán A/B. Không ràng buộc A = Việt.
- Nhãn “Nói chồng” chỉ hiện khi API có tín hiệu (prototype: công tắc mô phỏng); mặc định chỉ thấy các partial cạnh nhau.
- Mic tiếp tục nghe trong khi đoạn trước đang dịch **[mô phỏng: dịch trễ 1,4 s]**.
- Mất mạng: giữ segments, banner, retry backoff; resume dedupe theo `id`.
- **[thật]** Đổi cấu hình cần khởi động lại kết nối (ngôn ngữ, diarization): áp dụng khi idle/ended; đang chạy → “Áp dụng từ phiên tiếp theo”. Khóa API mới: đóng/mở lại stream sau câu hiện tại.

## 7. TTS (Đọc bản dịch)

Hàng đợi tuần tự, chỉ nhận `target` của segment final; không đọc lại khi partial sửa; chờ khi còn segment chưa final; TTS bar hiện “Đang đọc bản dịch · “…”” hoặc “Chờ người nói xong rồi đọc” + nút **Ngắt** (xóa hàng đợi). Ngôn ngữ giọng = ngôn ngữ đích của đoạn.
**[thật]** Chống thu lại tiếng loa vào mic: `AVAudioSession` `.voiceChat`/echo cancellation, giảm độ nhạy khi phát hoặc đánh dấu khoảng phát để bỏ nhận dạng. Kiểm thử trên thiết bị thật, cả loa ngoài.

## 8. Design tokens

### Màu (light / dark)
| Token | Light | Dark | Dùng |
|---|---|---|---|
| `bg` | `#F2F2F7` | `#000000` | nền màn |
| `surface` | `#FFFFFF` | `#1C1C1E` | card, bong bóng, sheet control |
| `surface2` | `#E5E5EA` | `#2C2C2E` | segmented track, ô chọn, banner |
| `text` | `#000000` | `#FFFFFF` | bản dịch, tiêu đề |
| `text2` | `rgba(60,60,67,.78)` | `rgba(235,235,245,.78)` | nguyên văn, mô tả |
| `text3` | `rgba(60,60,67,.55)` | `rgba(235,235,245,.55)` | nhãn nhóm, meta |
| `sep` | `rgba(60,60,67,.24)` | `rgba(84,84,88,.6)` | separator 0.5 pt |
| `accent` | `#007AFF` | `#0A84FF` | nút chính, vạch nhấn, caret |
| `onAccent` | `#FFFFFF` | `#FFFFFF` | chữ trên accent |
| `speakerA` | `#0E7C6B` | `#5FD2BF` | nhãn Người nói A (luôn kèm chữ) |
| `speakerB` | `#5352C9` | `#9D9BFF` | nhãn Người nói B |
| `ok` | `#248A3D` | `#30D158` | đã kết nối, Tiếp tục, toggle on |
| `warn` | `#C93400` | `#FF9F0A` | đang kết nối, nói chồng, DEMO, pending |
| `danger` | `#D70015` | `#FF453A` | lỗi, Kết thúc, Xóa |
| `live` | `#FF3B30` | `#FF453A` | chấm mic đang thu |
| `scrim` | `rgba(0,0,0,.32)` | `rgba(0,0,0,.55)` | nền sheet/alert |

Theme: Hệ thống (theo `colorScheme`) / Sáng / Tối.

### Typography (SF Pro, system)
- Cỡ chữ người dùng `fs` ∈ {0.85, 1, 1.2, 1.45, 1.75, 2.1} — tên: Nhỏ · Mặc định · Lớn · Rất lớn · Cực lớn · Tối đa. Native: `@ScaledMetric` + Dynamic Type tới AX5. Nhân vào **cả** nguyên văn và bản dịch, giữ phân cấp; **không** tự thu chữ để ép vừa.
- Nội dung (×fs): Phụ đề hiện tại 16 / 24 semibold (1.35 / 1.25); lịch sử 14 / 17 medium; Bong bóng 14 / 18 semibold; Kịch bản 14 / 16; Sân khấu 22 / 40 semibold (−0.015 em); Đối diện 15 / 30 semibold.
- Chrome (không nhân fs): tiêu đề 17 semibold; hàng Settings 17; nhãn nhóm 13 uppercase 0.02 em; meta đoạn 12–13 semibold uppercase; chú thích 13; nhãn nút dock 11 medium; trạng thái mic 12.5 semibold; tiêu đề sheet 20 bold; nút chính 17 semibold.
- `text-wrap: pretty`, `overflow-wrap: anywhere` cho nội dung; không cắt tên ngôn ngữ bằng “…”.

### Spacing & shape
- Lề ngang màn 16–20 pt; padding card 12/16; gap hàng meta 8 pt (wrap); gap giữa đoạn Phụ đề 18, Bong bóng 10.
- Bo góc: card/sheet-control 14; bong bóng 18 (14 khi chữ lớn); nút tròn 22–25 (pill); segmented 10 (item 8); ô chọn 10; sheet 22 (trên); alert 14.
- Vùng chạm ≥ 44 pt. Bottom sheet `max-height = 100% − 72 pt` (border-box), cuộn bên trong.
- Bóng: chỉ nút nổi “Về trực tiếp” (`0 4 14 rgba(0,0,0,.18)`) và knob toggle. Không gradient, không glass dày.
- Chuyển động: 200 ms ease (sheet slide-up 280 ms cubic-bezier(.2,.8,.2,1)); pulse 1.2 s; theo `accessibilityReduceMotion` → 0.

### Icon (SF Symbols tương ứng)
`gearshape` Settings · `mic.fill` / `mic.slash` · `play.fill` / `pause.fill` / `stop.fill` · `textformat.size` (Aa) · `rectangle.3.group` Hiển thị · `arrow.down` Về trực tiếp · `xmark` · `chevron.down` / `chevron.right` / `chevron.left` · `arrow.up.arrow.down` Đổi bên · `eye` / `eye.slash` · `checkmark` · `exclamationmark.triangle` · `info.circle` · `speaker.wave.2` TTS · `magnifyingglass`.

## 9. Component

`SegmentHeader` (nhãn người nói · ngôn ngữ · Nói chồng · Đang nhận dạng / Đang dịch / Hoàn tất; wrap) · `SegmentText` (nguyên văn + bản dịch theo fs) · `TranslatingLabel` (nhỏ, spinner) · `StatusDot` · `MicIndicator` · `PrimaryPill` · `LabeledRoundButton` (icon 44 + nhãn 11) · `SegmentedControl` · `Toggle` · `GroupedSection` · `PickerField` (ô ⌄) · `LanguagePickerSheet` · `DisplayStylePicker` · `FontSizeSheet` · `EndSessionSheet` · `Banner` (net / warn / info) · `BackToLiveButton` · `FacingPane` (rotated) · `BottomDock` (đo chiều cao).

## 10. Accessibility

Icon-button đều có `accessibilityLabel`; vùng partial `.updatesFrequently`; trạng thái không chỉ bằng màu (luôn icon + chữ); nhãn người nói luôn kèm chữ; contrast ≥ 4.5:1; giảm chuyển động; Dynamic Type; safe area & home indicator ở mọi kiểu, kể cả vùng xoay 180°.

## 11. Dữ liệu demo

Xem `demo-data.json`: kịch bản **quán cà phê Việt–Anh** (16 đoạn: câu dài nhiều dòng, người nói đổi ngôn ngữ, partial được sửa, đoạn chưa xác định, nói chồng) và kịch bản **Khách nói tiếng Nhật** (6 đoạn; có bản dịch Anh và Nhật cho lời của Bạn). Khóa demo: `sx_demo_7f3aK9qL2mZ8` **[giả]**.

## 12. Tiêu chí nghiệm thu

1. Đổi 5 kiểu hiển thị không mất nội dung, không khởi động lại mic.
2. Đổi ngôn ngữ giao diện không đổi chiều dịch; mọi nút/nhãn/lỗi đổi ngôn ngữ.
3. Tắt “Phân biệt người nói” → không còn nhãn A/B giả; Bong bóng về bố cục trung tính.
4. Cỡ chữ Tối đa: không nút nào bị chữ che; câu cuối hiện trọn trên dock; dọc và ngang.
5. Kéo lên đọc lại khi đang stream → không bị kéo xuống; “Về trực tiếp · N” hiện trong dải riêng, không phủ chữ.
6. Đối diện: hai vùng trong safe area, câu dài cuộn hết, dải giữa không bị đè; ✕ chỉ thoát kiểu.
7. Dark mode đọc tốt (contrast ≥ 4.5:1).
8. Soniox API luôn là nhóm đầu Settings; không có khóa thật trong mã, URL, log.
9. Bắt đầu → xin quyền mic đúng lúc; từ chối → banner mở Cài đặt iPhone.
10. Mất mạng giữ nội dung, tự kết nối lại; lỗi xác thực dừng stream và dẫn tới Settings.
11. Kết thúc luôn qua xác nhận; “Phiên mới” không mất cấu hình.
12. Cấu hình ngôn ngữ: lưu qua lần mở sau; đổi khi đang chạy → chỉ áp dụng phiên kế tiếp và có thông báo.
13. `speaker == nil` hiện “Chưa xác định”; không suy danh tính từ ngôn ngữ.
14. **[thật]** Nói chồng, language-ID theo đoạn, điều phối dịch me/guest/target, chống thu lại tiếng loa: kiểm thử với API Soniox thật trên thiết bị.

## 13. File

- `Sermiva.dc.html` — prototype nguồn (mở trong môi trường Design Components; cần `support.js`, `ios-frame.jsx`).
- `Sermiva.standalone.html` — bản đóng gói tự chạy, mở trực tiếp bằng trình duyệt.
- `ios-frame.jsx`, `support.js` — runtime của prototype (không dùng trong app).
- `demo-data.json` — dữ liệu mô phỏng.
- `HANDOFF.md` — tài liệu này.
