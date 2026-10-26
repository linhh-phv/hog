# hog — thiết kế giai đoạn 2: hỏi Claude ở ngoài app, danh mục khôn dần trong repo

> Trạng thái: **chủ dự án review sau khi triển khai** (*"vậy chạy tiếp luôn, xong thì mình review sau"*, 2026-10-26).
> Nền: [thiết kế giai đoạn 1](design-vi.md). Chỗ triển khai khác tài liệu này ghi ở mục 7.

## 1. Đổi so với kế hoạch ban đầu

Kế hoạch gốc (giai đoạn 1, mục 12): nút **"Hỏi Claude"** trong app (`claude -p` kèm ảnh chụp) và **"Lưu vào danh mục"**.

Chủ dự án đổi hướng ngày 2026-10-26, nguyên văn: *"thay vì để bạn tự chạy claude thì mỗi lần thấy gì mới mình sẽ tự chụp rồi hỏi bạn
ở hub này rồi chúng ta update lại hog"* — và *"mình không muốn lộ hay mất thêm gì cả"*. Lý do: máy có thể đang đăng nhập Claude bằng
tài khoản của tổ chức, còn hog là dự án cá nhân; app tự gọi Claude thì tốn hạn mức (có thể cả tiền, nếu tổ chức bật trả thêm) và đưa
dữ liệu máy đi qua tài khoản đó mà người dùng không kiểm soát từng lần.

Hệ quả:

- **hog không bao giờ gọi Claude, không gửi gì ra khỏi máy.** Không có nút "Hỏi Claude", không đọc tài khoản Claude.
- Tầng 3 giữ đúng như sơ đồ gốc: **Claude ở ngoài hog** (khung chat của hub, skill `hog`). Người dùng chủ động dán thông tin vào chat.
- **Danh mục khôn dần trong repo**, không ở `~/.config/hog/catalog.d/` của một máy: mục mới qua test, qua review, có lịch sử commit, mọi
  máy cài hog đều có.
- Phần còn lại của giai đoạn 2 là làm cho việc hỏi **dễ và sạch**: chép thông tin đã làm sạch, chỉ ra thứ chưa biết, giao diện đầy đủ hơn.

Đã thử trước khi đổi (để ghi lại số đo): một lần `claude -p --tools "" --no-session-persistence --output-format json --json-schema …`
trả lời trong ~3–6 s, ~8 000 token đầu vào (phần lớn là phần khởi động cố định của Claude Code); `--bare` chỉ nhận API key.

## 2. Luồng

```text
 app: "Chưa rõ là gì" / trang item ─► [Chép thông tin] ─► clipboard (hog.share/1, đã làm sạch)
 CLI: hog explain <item> --share  ─► in đúng nội dung đó
          │
          ▼ người dùng dán (hoặc chụp màn hình) vào khung chat của hub
 skill hog: Claude giải thích ─► người dùng đồng ý ─► task của hub thêm catalog/<id>.json vào repo hog ─► swift test ─► commit
          ─► người dùng chạy scripts/install.sh ─► lần sau hog tự biết
```

## 3. Thông tin chép ra (`hog.share/1`)

Chỉ **một** item, dựng từ lần quét gần nhất. Văn bản gồm một câu hỏi mở đầu (theo ngôn ngữ của app) và một khối JSON:

```json
{
  "schema": "hog.share/1",
  "hog_version": "0.2.0",
  "item": { "kind": "process", "exe": "node", "args": "node server.js --port 3000", "catalog_id": null },
  "facts": { "age_s": 7200, "cpu.avg_pct": 0.1, "footprint_bytes": 412000000, "net.listen_count": 1, "orphan": true },
  "owner_kind": "none",
  "parents": ["zsh", "login", "Terminal"],
  "listen_ports": [3000]
}
```

- **Không chép:** nhãn item (có thể chứa tên dự án, tiêu đề cửa sổ), `cwd`, `project`, nhãn chủ sở hữu, tên người dùng, thư mục, biến
  môi trường. Tham số qua `Privacy.scrubArgs` (che mật khẩu, token…), rồi mọi tham số chứa `/` chỉ giữ phần sau dấu `/` cuối cùng
  (`~/work/acme/server.js` → `server.js`, `--dir=/x/y` → `--dir=y`).
- `exe`, `parents`: chỉ tên file thực thi, không đường dẫn. `parents`: tối đa 4 tổ tiên, từ gần tới xa, dừng ở `launchd`.
- `facts`: chỉ số và bool đo được (bỏ `null`), cộng `owner.kind`, `catalog.family`. Container: `item.image` thay cho `exe`/`args`.
- Người dùng thấy đúng nội dung này trong clipboard / terminal trước khi dán: không có gì gửi đi ngầm.

## 4. Danh mục khôn dần (skill `hog` trong hub)

Khi người dùng dán `hog.share/1` hay ảnh chụp:

1. Claude giải thích từ dữ liệu (nói rõ đâu là suy luận), đề xuất một mục danh mục.
2. Người dùng đồng ý → mở/tiếp một task của hub cho repo hog, thêm `Sources/HogCore/Resources/catalog/<id>.json`:
   - `match` dựng từ dữ liệu đo: `exe`; trình thông dịch (`node`, `python*`, `ruby`, `java`, `bun`, `deno`, `perl`, `php`) thì thêm
     `args_contains` = tên script (một mục chỉ `exe: node` sẽ khớp mọi chương trình node);
   - `stop.strategy` chỉ trong tập có sẵn; không bao giờ nhúng lệnh;
   - `provenance`: `source: "claude"`, `verified: true` chỉ khi đã thấy trên máy thật (dữ liệu dán vào là từ máy thật), ngược lại `false`;
   - thêm một dòng vào bảng danh mục khởi đầu của thiết kế khi cần, `swift test` xanh (test dữ liệu đi kèm kiểm mọi file).
3. Người dùng chạy `scripts/install.sh` để có bản mới.

`~/.config/hog/catalog.d/` vẫn dùng được để thử nhanh một mục trước khi đưa vào repo.

## 5. Giao diện (trong design system đã duyệt)

1. **"Chưa rõ là gì"** — mục mới trên trang chính, sau Đề xuất: tối đa 3 item lớn nhất (≥ 100 MB footprint) chưa có trong danh mục, không
   bị bảo vệ `hard`. Mỗi dòng: tên file thực thi, RAM; bấm → trang item.
2. **Trang item** (mở rộng trang "Vì sao?" của giai đoạn 1, dùng cho mọi item): là gì (mô tả danh mục, hoặc "hog chưa biết thứ này"),
   vì sao (nếu có đề xuất), số đo có "?", tắt thì sao, nút **"Chép thông tin"** (chép `hog.share/1`, báo "Đã chép — dán vào Claude để
   hỏi"), và nút Dừng… khi có đề xuất.
3. **Mọi đề xuất** — "+ N đề xuất khác" mở trang liệt kê đủ (giai đoạn 1 chỉ bảo dùng terminal).
4. Cài đặt: dòng "hog không gửi dữ liệu đi đâu" giữ nguyên — nay đúng cả với giai đoạn 2.

## 6. Kiểm thử

- `hog.share/1`: không chứa cwd, tên dự án, nhãn item, nhãn chủ sở hữu, home, tên người dùng, thư mục; tham số bí mật bị che; chỉ fact đo
  được; container không có tham số.
- "Chưa rõ là gì": chọn đúng (chưa có danh mục, ≥ 100 MB, không `hard`, lớn nhất trước, tối đa 3).
- CLI: `hog explain <item> --share` in đúng `hog.share/1`; `--share` với thuật ngữ → lỗi dùng sai.
- App: ảnh `--render` của trang chính (có "Chưa rõ là gì"), trang item, trang mọi đề xuất.
- Không có code nào gọi `claude` (`git grep` trong `Sources/`).

## 7. Chỗ triển khai khác thiết kế

| Ngày | Chỗ | Thực tế | Vì sao |
| --- | --- | --- | --- |
