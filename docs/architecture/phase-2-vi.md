# hog — thiết kế giai đoạn 2: hỏi Claude ở ngoài app, danh mục khôn dần trong repo

> Trạng thái: **chủ dự án review sau khi triển khai** (*"vậy chạy tiếp luôn, xong thì mình review sau"*, 2026-10-26).
> Nền: [thiết kế giai đoạn 1](design-vi.md). Chỗ triển khai khác tài liệu này ghi ở mục 7.

## 1. Đổi so với kế hoạch ban đầu

Kế hoạch gốc (giai đoạn 1, mục 12): nút **"Hỏi Claude"** trong app (`claude -p` kèm ảnh chụp) và **"Lưu vào danh mục"**.

Chủ dự án đổi hướng ngày 2026-10-26, nguyên văn: *"thay vì để bạn tự chạy claude thì mỗi lần thấy gì mới mình sẽ tự chụp rồi hỏi bạn
ở hub này rồi chúng ta update lại hog"* — và *"mình không muốn lộ hay mất thêm gì cả"*. Lý do: app tự gọi Claude thì tốn hạn mức của
tài khoản đang đăng nhập (có thể cả tiền, tuỳ gói) và đưa dữ liệu máy đi qua tài khoản đó mà người dùng không kiểm soát từng lần;
tài khoản đó có thể không phải của riêng người dùng.

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

Chỉ **một** item, dựng từ lần quét gần nhất. Văn bản gồm một câu hỏi mở đầu (theo ngôn ngữ của app; nói hog đã nhận ra thứ này là
mục danh mục nào, hay chưa biết) và một khối JSON:

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

- **Không chép:** nhãn item (có thể chứa tên dự án, tiêu đề cửa sổ), `cwd`, `project`, nhãn chủ sở hữu, biến môi trường.
- **Tham số — lớp 1, theo cấu trúc** (`ShareInfo.shareArgs`), sau khi `Privacy.scrubArgList` che mật khẩu/token theo tên cờ (và
  `curl -u`). Tham số đầu là tên chương trình (chỉ tên file, như `exe`). Đường dẫn tuyệt đối — kể cả `--cờ=/đường dẫn` — là **một khối** dù
  có dấu cách (`/Applications/Visual Studio Code.app/…`); tham số khác có khoảng trắng (`sh -c "cd … && npm run dev"`, `-H "X-Api-Key: v"`)
  được xử lý từng từ. **Tên cờ giữ nguyên** (chúng nói chương trình làm gì); chỉ giá trị bị rút gọn. Với mỗi giá trị:
  - có `://` → chỉ giữ scheme: `postgres://…` (không host, user, mật khẩu, đường dẫn, query);
  - đi qua thư mục gói công khai (`extensions`, `node_modules`, `site-packages`, `dist-packages`, `gems`) → giữ tên gói và tên file cuối:
    `…/extensions/markdown-language-features/dist/serverWorkerMain` → `extensions/markdown-language-features/…/serverWorkerMain`; scope npm
    bị che: `node_modules/@…/tool/…/cli.js`. Đây là manh mối chính (đo trên máy: một tiến trình extension của VS Code chỉ còn
    `serverWorkerMain` nếu cắt hết);
  - có `@` → `…` (`user@host`, `token@host`, `git@host:org/repo`);
  - có `/` hoặc bắt đầu bằng `~` → tên file cuối **nếu là tên file** (có đuôi ngắn: `server.js`), ngược lại `…` (một thư mục — thường
    chính là tên dự án: `pnpm --dir ~/work/acme dev` → `pnpm --dir … dev`);
  - UUID hoặc chuỗi ngẫu nhiên dài (≥ 20 ký tự, có cả chữ và số) → `…` (id trình duyệt, token phiên);
  - `TÊN=giá-trị` (biến môi trường: `-e DB_PASSWORD=x`, `--env=TOKEN=x`, trong `sh -c`) mà `TÊN` chứa từ bí mật → `TÊN=***`;
  - header có tên chứa từ bí mật (`X-Api-Key:`, `--header=X-Auth:`) → giá trị theo sau là `***`;
  - `-u`/`--user` theo sau là `user:mật-khẩu` (có `:`) → `***`, với mọi chương trình; `-u root` giữ nguyên.
- **Lớp 2, theo tên riêng hog đã thấy** (`Redactor`, chỉ áp lên giá trị và tên chương trình, không áp lên tên cờ): mọi tên dự án
  (`package.json#name`, thư mục có `.git`…), mọi thành phần thư mục làm việc trong home của mọi tiến trình và phiên Claude (trừ
  `~/Library` — nơi app để dữ liệu, `Application Support/discord` là tên app chứ không phải tên riêng — và thư mục ẩn), các phần một từ của tiêu đề cửa sổ VS Code, tên người dùng, tên máy (`gethostname`,
  không tra DNS) → thay bằng `…` ở `exe`, `args`, `parents`, `image`, không phân biệt hoa thường, theo ranh giới từ. Tên < 3 ký tự và tên
  thư mục chung (`src`, `dist`, `app`, `work`…) không tính. Bắt được chỗ lớp 1 để lọt: tham số tương đối `code acme-billing`, binary đặt
  theo tên dự án.
- Container: chỉ tên image, bỏ registry/namespace; tên dạng `<dự-án>-<service>` (Compose tự đặt) chỉ còn `…-<service>`.
- Còn lại có thể lộ (chấp nhận, người dùng thấy nội dung trước khi dán): một từ đơn lẻ không phải đường dẫn mà hog chưa từng thấy là tên
  riêng (vd `--filter acme` khi không có tiến trình nào chạy trong thư mục `acme`); tên host không kèm `://` hay `@`.
- `exe`, `parents`: chỉ tên file thực thi, không đường dẫn (qua lớp 2). `parents`: tối đa 4 tổ tiên, từ gần tới xa, dừng ở `launchd`.
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
   bị bảo vệ `hard`, không thuộc một app (`owner.kind` ≠ `app`: "Google Chrome Helper" đã được app của nó giải thích), không phải phiên
   Claude, chưa hiện thành thẻ đề xuất. Mỗi dòng: tên file thực thi, RAM; bấm → trang item.
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
| 2026-10-26 | Ảnh `--render` | Chụp bằng `NSHostingView` trong cửa sổ AppKit ngoài màn hình thay cho `ImageRenderer` | `ImageRenderer` không vẽ nội dung `ScrollView`: trang item và "Mọi đề xuất" ra trắng (trang "Vì sao?" của giai đoạn 1 chưa từng được chụp vì vậy) |
| 2026-10-26 | `hog explain` | Luôn phân tích đầy đủ (không giới hạn kích thước như `--json`) | id lấy từ `hog --json --full` không tra được — lỗi có từ giai đoạn 1 |
| 2026-10-26 | Trang item | "Độ tin" dịch sang tiếng Việt (cao/vừa/thấp), cả ở CLI | trước đó in nguyên `high` |
| 2026-10-26 | Ghi chú "Chưa đo được" | VS Code bị bộ ngắt `code --status` → câu riêng ("không trả lời lần trước; hog chờ VS Code khởi động lại") | trước đó báo nhầm "không tìm thấy lệnh `code`" |
| 2026-10-26 | Làm sạch (reviewer chốt) | Từ "giữ phần sau `/` cuối" sang hai lớp (mục 3): thư mục → `…`, URL chỉ còn scheme, `@` → `…`, id ngẫu nhiên → `…`, rồi thay mọi tên riêng hog đã thấy | Reviewer chạy được các đường lọt: `--dir ~/work/acme` → `acme`, `redis://:pw@host`, `token@github.com`, `AWS_SECRET…=` trong `sh -c`, host registry nội bộ, `--metrics-client-id` |
| 2026-10-26 | Giới hạn kích thước snapshot | Ứng viên "Chưa rõ là gì" luôn được giữ qua bước cắt (như item có đề xuất) | Item chưa rõ 100–149 MB bị cắt trước khi app kịp thấy |
| 2026-10-26 | App | Kết quả dừng (xong, bị chặn, lỗi) đưa về trang chính để hiện; "‹ Quay lại" từ trang item về "Mọi đề xuất" nếu mở từ đó | Bấm Dừng ở trang mới thì không thấy kết quả |
| 2026-10-26 | Làm sạch (qa chốt) | Thêm: biến môi trường bí mật, header bí mật, `-u user:pw`; đường dẫn có dấu cách là một khối; tên cờ không bị lớp 2 thay; lớp 2 bỏ `~/Library` và thư mục ẩn; câu mở đầu theo việc hog đã biết thứ này hay chưa; trang item nói rõ khi thứ đó đã thoát | qa tạo tiến trình thử: `-e DB_PASSWORD=…`, `X-Api-Key: …`, `-u admin:pw` lọt; chạy thật: bản đầu của lớp 2 cắt vụn `Visual Studio Code.app`, thay chữ `data` trong `--user-data-dir`, coi "Discord" là tên riêng |
