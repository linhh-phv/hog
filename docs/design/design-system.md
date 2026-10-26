# hog — design system

Nguồn sự thật cho giao diện của hog (app thanh menu `HogBar`). Hướng đã chọn: **B — Ô đo và thanh RAM** (chủ dự án chốt
2026-10-26). Bản mẫu: [menubar/main.html](menubar/main.html) (màn chính) · [menubar/states.html](menubar/states.html) (các trạng thái).
Nội dung (câu kết luận, giải nghĩa, quy tắc) theo [thiết kế giai đoạn 1](../architecture/design-vi.md), mục 5 và 9.2.

Brief: *"Gọn, như đồ Apple"* · độ dày *"Vừa: kết luận + 5 thứ nặng nhất + đề xuất"* · icon *"Hình heo đơn sắc, đổi màu theo áp lực"*.

## Nguyên tắc

1. **Lời trước, số sau.** Ô đầu tiên luôn là câu kết luận; số là bằng chứng.
2. **Thấy "ai ăn" bằng hình**: một thanh ngang chia RAM theo chủ sở hữu, luôn có chú thích bằng chữ cạnh màu.
3. **Không truyền nghĩa chỉ bằng màu**: verdict có chữ + hình (`● có thể tắt`, `◐ hỏi trước`, `○ để ý`); áp lực có chữ (`Ổn`,
   `Cảnh báo`, `Nghiêm trọng`) + hình.
4. **Mọi số có `?`** mở giải nghĩa (bảng thuật ngữ, mục 5.2 của thiết kế).
5. **Theo macOS**: chữ hệ thống, chế độ sáng/tối theo máy, không gradient, không emoji làm icon, một màu nhấn.

## Token

Giá trị dùng chung cho bản mẫu (CSS) và app (`Sources/HogBar/Theme.swift`). Đổi ở đây trước, rồi ở cả hai nơi.

### Màu

| Token | Vai trò | Sáng | Tối |
| --- | --- | --- | --- |
| `bg` | nền menu | `#F4F4F5` | `#2A2A2C` |
| `raised` | nền ô, thẻ, nút | `#FFFFFF` | `#3A3A3C` |
| `text` | chữ chính | `#1D1D1F` | `#F5F5F7` |
| `text2` | chữ phụ (≥ 4.5:1 trên `bg`) | `#5D5D62` | `#B0B0B5` |
| `sep` | đường kẻ, viền | `rgba(0,0,0,.10)` | `rgba(255,255,255,.12)` |
| `fill` | nền nhạt (chip, hover) | `rgba(0,0,0,.05)` | `rgba(255,255,255,.07)` |
| `accent` | chữ liên kết, màu nhấn | `#0062CC` | `#4DA3FF` |
| `accentBg` | nền nút chính (chữ trắng ≥ 4.5:1) | `#0062CC` | `#1F6FD6` |
| `ok` | áp lực ổn, cổng đạt | `#1A7F37` | `#4CD964` |
| `warn` | cảnh báo, "hỏi trước" | `#A14A00` | `#FFB340` |
| `red` | nghiêm trọng, "có thể tắt" (chữ) | `#C4001A` | `#FF6B6B` |
| `redBg` | nền nút "Dừng" | `#C4001A` | `#C8242F` |
| `bar1…bar4` | thanh RAM: chủ sở hữu 1–3, "còn lại" | `#0062CC` `#5E5CE6` `#A14A00` `#8E8E93` | `#4DA3FF` `#8D8BFF` `#FFB340` `#8E8E93` |

Ở chế độ tối, chữ trắng trên `#4DA3FF`/`#FF6B6B` chỉ đạt ~2.7–2.9:1, nên nút dùng `accentBg`/`redBg` riêng.

### Chữ (chữ hệ thống, SF)

| Kiểu | Cỡ / độ đậm | Dùng cho |
| --- | --- | --- |
| `title` | 15 / semibold | tiêu đề hộp thoại, tiêu đề trang con |
| `metric` | 14 / semibold, số tabular | số trong ô đo |
| `body` | 13 / regular | câu kết luận, dòng danh sách |
| `small` | 12 / regular | chú thích thanh RAM, lý do, chi tiết |
| `caption` | 11 / regular hoặc semibold | nhãn ô đo, verdict, chân menu |

Số luôn dùng **tabular** (cột thẳng). Số tiếng Việt dùng dấu phẩy thập phân (`1,3 GB`), tiếng Anh dùng dấu chấm (do `Format` của
HogCore lo).

### Khoảng cách, bo góc, bóng

- Thang khoảng cách: **4 · 8 · 12 · 16**. Lề trong menu 12; giữa các ô 8.
- Bo góc: menu **12** · ô, thẻ, câu kết luận **10** · nút **6** · thanh RAM **5** (nửa chiều cao 10).
- Viền mảnh 0.5 pt `sep` thay cho bóng; chỉ menu và hộp thoại có bóng (của hệ thống).
- Chiều rộng menu **340**; nút cao **24** trong menu, **28** trong hộp thoại (macOS dùng con trỏ: HIG cho phép điều khiển nhỏ hơn 44 pt của
  màn cảm ứng; vùng bấm vẫn ≥ 24 pt).

## Component

| Component | Mô tả | Trạng thái |
| --- | --- | --- |
| `MenuBarIcon` | mặt heo đơn sắc 18×16 (hai tai, mõm hai lỗ mũi), màu theo thanh menu | thường · `warn` khi áp lực cảnh báo · `red` khi nghiêm trọng |
| `HeadlineCard` | ô `raised` chứa câu kết luận một dòng (`headline.text`) | — |
| `MetricTile` ×3 | nhãn `caption` + `?` · số `metric` | Áp lực (chữ + hình + màu) · Đã nén · Ra ổ đĩa |
| `RAMBar` + `Legend` | thanh chia theo chủ sở hữu (tối đa 3 + "còn lại"), chú thích chữ + số | dòng có chủ con bấm được (`›`/`⌄`) để mở theo cửa sổ VS Code; "Còn lại + hệ thống · Đo chi tiết" |
| `SuggestionCard` | verdict (chữ + hình + màu) · tên · số · lý do · một nút | nút "Dừng…" (chiến lược tự làm) hoặc "Cách đóng" (`manual`) · "Vì sao?" |
| `StopSheet` | tiêu đề "Dừng X?", chủ sở hữu + PID, Vì sao / Tắt thì sao / hog sẽ, danh sách cổng (✓ đạt, ? cần đồng ý) | nút "Dừng" khi chỉ cần xác nhận; "Vẫn dừng" khi có cổng `?`; không có nút khi bị chặn (chỉ lý do) |
| `GlossaryPopover` | tên · tên trong Activity Monitor (ghi "chưa đối chiếu" khi chưa kiểm) · nghĩa · đọc thế nào · nên làm gì | — |
| `DetailPage` | trang con có "‹ Quay lại": trang item, "Mọi đề xuất", "Đo chi tiết", "Cài đặt" | — |
| `ItemPage` (giai đoạn 2) | tên · là gì (danh mục, hoặc "hog chưa biết thứ này") · vì sao + độ tin · số đo có `?` (nhãn trái, số phải) · tắt thì sao · khu "Chép thông tin" | nút "✓ Đã chép" sau khi chép (tới lần mở menu sau) · "Dừng…"/"Cách đóng" khi có đề xuất |
| `UnknownRow` (giai đoạn 2) | tên · RAM · `›`, chữ `small` | cả dòng bấm được → `ItemPage` |
| `ScanBanner` | vòng quay nhỏ + "Đang quét… hiện bản lúc HH:MM" | chỉ khi đang quét |
| `ResultToast` | "✓ Đã dừng X (323 MB). Ghi ở nhật ký." trên đầu menu | biến mất ở lần mở sau |
| `Footer` | "Cập nhật HH:MM · hog dùng N MB" · Làm mới · Cài đặt | — |

## Luật dùng

- Menu đóng: icon chỉ đổi màu theo áp lực (đọc mỗi 10 s). Mở menu: hiện bản quét gần nhất ngay + `ScanBanner`, quét đầy đủ rồi thay.
- Đề xuất xếp `may-stop` → `ask` → `watch`; tối đa 3 thẻ, còn lại "+ N đề xuất khác" (bấm → trang "Mọi đề xuất"). `info` không
  hiện trong menu (có trong `hog --json`).
- "Chưa rõ là gì" (giai đoạn 2): tối đa 3 `UnknownRow` sau Đề xuất — item ≥ 100 MB chưa có trong danh mục, không thuộc một app, không bị
  bảo vệ `hard`; không có thì ẩn cả mục. Câu chú thích nói rõ để làm gì (chép thông tin hỏi Claude).
- hog không gửi gì đi: "Chép thông tin" chỉ ghi vào clipboard; câu cạnh nút nói rõ điều đó.
- Không có gì cần tắt: giữ mục "Đề xuất" với câu "Không có gì cần tắt. hog sẽ báo khi có." (không ẩn mục, để người dùng biết hog đã xem).
- Cảm biến `unavailable`/`error`: mục "Chưa đo được" với lý do bằng lời ("Docker — engine đang tắt (không phải lỗi)").
- Nút "Dừng…" luôn mở `StopSheet`; app không bao giờ dừng gì mà không qua hộp thoại này (cổng an toàn, mục 8 của thiết kế).
- Tiến trình hệ thống: không có nút dừng ở bất cứ đâu.
- Chuỗi hiển thị lấy từ HogCore (đã theo `vi`/`en`); nhãn giao diện của app cũng có đủ hai ngôn ngữ.
