# hog — design system

Nguồn sự thật cho giao diện của hog (app thanh menu `HogBar`). Bố cục: **B — Kết luận trước, bản 2** (chủ dự án chọn và duyệt
2026-10-27) · bản mẫu bố cục: [compact/screens.html](compact/screens.html) · ảnh app thật: [compact/app/](compact/app/).
Thay cho hướng "Ô đo và thanh RAM" của giai đoạn 1 (2026-10-26).

Brief của chủ dự án, nguyên văn: *"nhìn vào thì sẽ xem được cái gì đang chạy và tiêu tốn tài nguyên máy như thế nào … sau đó có kết
luận và gợi ý tắt những tiến trình nặng hoặc idle, giao diện phải tối ưu UI/UX thay vì hiển thị nhiều chữ lên màn hình, khi nào action
vào thì mới show thông tin ra"* · *"mở hog sẽ biết được cái gì đang chạy (có thể nói rõ dự án nào đang chạy) … hog vẫn liệt kê đầy đủ
các tiến trình"* · *"có thể làm UI giống với macos luôn được không"*.

## Nguyên tắc

1. **Kết luận trước, chi tiết khi bấm.** Màn chính chỉ có: trạng thái máy, 3 số, việc nên dọn, cái gì đang chạy. Lý do, giải nghĩa, từng
   tiến trình chỉ hiện khi bấm.
2. **Theo dự án.** "Đang chạy" gom theo dự án người dùng đang làm (mọi tiến trình của dự án đó), rồi tới app, rồi "Khác".
3. **Lời thường.** Không thuật ngữ ở màn chính ("Tràn ra ổ đĩa", không "swap"; "CPU đang bận"); thuật ngữ và tên trong Activity Monitor nằm
   trong phần giải nghĩa.
4. **Giao diện gốc macOS.** Thành phần của hệ thống, không tự vẽ: vật liệu mờ của `MenuBarExtra`, SF Symbols, `Gauge`, `Toggle(.checkbox)`,
   `Button` (`.borderedProminent`, `.link`, `.borderless`), popover, icon thật của app (`NSWorkspace`). Màu ngữ nghĩa của hệ thống theo màu
   nhấn, sáng/tối và "Tăng tương phản" của máy.
5. **Không truyền nghĩa chỉ bằng màu.** Trạng thái có chữ (+ biểu tượng ⚠ khi không ổn); lý do dọn có chữ; cổng an toàn có biểu tượng
   ✓ / ? / ✕ + chữ.
6. **Đầy đủ nhưng không ồn.** Mọi tiến trình đọc được đều có trong "Tất cả" (tìm được); cùng tên trong một nhóm gộp một dòng `×N`; app
   nhỏ gộp vào "Khác".

## Token (`Sources/HogBar/Theme.swift`)

| Token | Giá trị | Dùng cho |
| --- | --- | --- |
| Khoảng cách | 4 · 8 · 12 · 16 | lề trong, khoảng giữa khối |
| `rModule` | 10, góc liên tục | khối kiểu Control Center (`.module()`: nền `.quaternary` mờ) |
| Rộng menu | 340 pt | |
| Màu trạng thái | `.green` ổn · `.orange` hơi nặng / nóng · `.red` nặng | vòng RAM (theo **áp lực bộ nhớ**, không theo %), tiêu đề trạng thái, số đáng lo |
| Lý do dọn | `.orange` rảnh · `.red` ăn nhiều / lỗi | nhãn tròn trong "Nên dọn" |
| Chữ | `.title3.semibold` tiêu đề · `.headline` đầu mục · `.callout` thân · `.caption` phụ; số `monospacedDigit` | |
| Dự án | `.tint` (màu nhấn của máy): biểu tượng `folder.fill`, nhãn "dự án" | |
| Chưa rõ | `questionmark.circle` `.orange` | thứ không có trong danh mục, không thuộc app, không phải công cụ macOS, từ 20 MB |

## Component (`Sources/HogBar/Components.swift`, `Pages.swift`)

| Component | Là gì | Bấm |
| --- | --- | --- |
| `StatusHeader` | `Gauge(.accessoryCircularCapacity)` "73% RAM" + "Máy ổn / hơi nặng / nặng / nóng" + một dòng | vòng → giải nghĩa RAM (kèm phần đã nén) |
| `MetricChip` ×3 | CPU đang bận · Tràn ra ổ đĩa · Nhiệt | → popover giải nghĩa (thay các nút `?` cũ) |
| Khối "Nên dọn" | `CleanupRow`: ô chọn · tên · dự án · `ReasonTag` · RAM; nút "Dọn N thứ" | lý do → popover lý do + tắt thì sao; "Dọn N thứ" → `BatchSheet` |
| `GroupRow` | mũi tên · icon (app thật / `folder.fill` / hệ thống) · tên · tóm tắt · RAM · CPU | mở/gập từng thứ (`EntryRow`) |
| `EntryRow` | tên · `?` nếu chưa rõ · cổng · `×N` · RAM · CPU | → `EntryPage` |
| `EntryPage` | số đo, lý do (nếu có đề xuất), "Chép thông tin" (nút chính khi chưa rõ), "Dừng…"/"Cách đóng" (không có ở dòng `×N`) | |
| `AllPage` | ô tìm + mọi nhóm, mọi thứ; "macOS và hệ thống" → Đo chi tiết | |
| `BatchSheet` / `StopSheet` | hộp xác nhận trên nền tối mờ, vật liệu `.regularMaterial`; tiêu đề có RAM lấy lại; từng thứ: an toàn / hỏi trước (kèm lý do của cổng) / bị chặn | |
| `Footer` | giờ quét · RAM của hog · `arrow.clockwise` · `gearshape` | |

## Luật dùng

- Menu đóng: icon heo chỉ đổi màu theo mức xấu hơn giữa áp lực và nhiệt (đọc mỗi 10 s; nhiệt còn theo thông báo của macOS). Mở menu:
  hiện lần quét gần nhất ngay, quét lại nền (vòng quay nhỏ ở chân).
- Trạng thái: nặng = áp lực đỏ hoặc nhiệt rất nóng; hơi nặng = áp lực vàng; nóng = nhiệt nóng; "ổn, CPU bận" = CPU cả máy ≥ 80 %.
  Dòng phụ: lý do khi không ổn; khi ổn là việc nên làm ("2 thứ nên dọn · lấy lại 683 MB") hoặc "Không có gì cần dọn".
- "Nên dọn": có thể tắt (chọn sẵn), hỏi trước và ăn nhiều (chưa chọn); thứ chỉ đóng tay (phiên Claude) có "Cách đóng" thay ô chọn.
  Lý do tối đa 3 chữ ("rảnh 3 giờ", "22 % CPU", "hay bị sập").
  Không có gì → không có khối. Chỉ có thứ đóng tay → không có nút "Dọn".
- "Dọn N thứ": một hộp xác nhận cho cả nhóm; mỗi thứ vẫn qua đủ cổng an toàn; thứ bị chặn được liệt kê nhưng không chạy; buộc tắt
  (SIGKILL) không bao giờ nằm trong nhóm — phải mở riêng.
- "Đang chạy" ở màn chính: tối đa 5 nhóm (dự án và app, không gồm "Khác"/hệ thống), rồi "Tất cả N tiến trình".
- Dòng trong nhóm app bỏ tên app ở đầu ("Helper (Renderer)" dưới "Google Chrome"); tên dài cắt ở cuối dòng. Ô tìm khớp cả
  tên nhóm + tên dòng ("chrome helper" vẫn ra).
- CPU ở mọi dòng là **% của cả máy**, đỏ từ 50 % (cộng lại ra "CPU đang bận"), không phải % một nhân như Activity Monitor.
- "Chưa đo được" (Docker tắt, VS Code không trả lời…) nằm trong Cài đặt, không ở màn chính của app; CLI in một dòng ở cuối.
- Chuỗi hiển thị lấy từ HogCore (`Overview`, đã theo `vi`/`en`); nhãn của app có đủ hai ngôn ngữ.
