# hog — thiết kế giai đoạn 1

> Trạng thái: **đã duyệt** (2026-10-26), cả 10 câu ở mục 12 đã chốt. **Giai đoạn 1 đã triển khai** (lõi, CLI, app thanh menu, skill trong hub).
> Chỗ thực tế khác thiết kế được sửa thẳng vào tài liệu và ghi ở mục 13 (user: *"sau khi triển khai xong thì có gì update sau"*).
> Đổi so với bản 1 (2026-10-15): viết bằng **Swift** thay vì Go, có **app trên thanh menu macOS** ngay giai đoạn 1, và
> thêm **tầng giải nghĩa số đo** (mục 5) — cả ba do chủ dự án chốt ngày 2026-10-26.
> Ngôn ngữ: tiếng Việt, vì người duyệt là chủ dự án; README và code của repo vẫn là tiếng Anh.
> Số đo trong tài liệu là **đo trên một máy macOS 16 GB** ngày 2026-10-15 hoặc 2026-10-26; chỗ chưa kiểm được ghi rõ.

## 1. Bài toán và phạm vi

Máy dev 16 GB bị chậm, mà thứ chiếm RAM thật thường **không mở cổng TCP nào** nên `lps` v0.1.0 (chỉ liệt kê
cổng LISTEN) không thấy: language server của VS Code, `watchman` không còn ai dùng, các phiên Claude bị bỏ quên, container
chết đi sống lại sau OrbStack. Muốn biết phải gõ tay hơn chục lệnh `ps`/`top`/`lsof` và đọc log. Còn mở Activity
Monitor thì thấy rất nhiều cột số (Memory, Real Mem, Compressed, Cached Files, Wired, Swap…) mà **không biết số nào
nói lên điều gì, nên không dựa vào đó để quyết định tắt cái nào được**.

`hog` trả lời bốn câu hỏi, theo thứ tự:

1. **Máy có đang thiếu tài nguyên không?** — một câu trả lời bằng lời, dựa trên áp lực bộ nhớ, RAM nén, swap, CPU.
2. **Cái gì đang ăn, và nó thuộc về ai?** — gom theo app, cửa sổ VS Code, dự án, phiên Claude, thay vì 600 tiến trình rời.
3. **Có nên tắt không, tắt thì mất gì?** — hog **đề xuất kèm bằng chứng**, người quyết định.
4. **Mỗi con số nghĩa là gì?** — mọi số hiển thị đều có giải nghĩa bằng lời thường, kèm tên tương ứng trong Activity Monitor.

Ngoài phạm vi giai đoạn 1: nút "Hỏi Claude" và "Lưu vào danh mục" trong app (giai đoạn 2), lịch sử RAM và thông báo
(giai đoạn 3), Linux/Windows, tự động dừng không có người xác nhận, bất kỳ lời gọi mạng nào của chính hog.

## 2. Kiến trúc

```text
                    ┌──────────────── HogCore (thư viện Swift) ────────────────┐
 máy ──► Tầng 1 Cảm biến (tất định) ──► snapshot
                    Tầng 2 Quy tắc + danh mục (dữ liệu) ──► findings (kết luận có bằng chứng)
                    Tầng giải nghĩa (dữ liệu) ──► câu trả lời một dòng + nghĩa của từng số
                    Hành động dừng + cổng an toàn (mục 8)
                    └──────────────────────────────────────────────────────────┘
          hai mặt dùng chung HogCore:   `hog` (CLI, `--json` cho Claude/hub)   ·   HogBar (app thanh menu)
 Tầng 3  Claude (ngoài hog): đọc `hog --json`, giải thích thứ lạ, ghi giải thích tốt vào danh mục
```

CLI và app **không có logic riêng**: mọi đo đạc, kết luận, giải nghĩa và cổng an toàn nằm ở `HogCore`, nên bấm "Dừng"
trong app và gõ `hog stop` đi qua đúng một đường.

Nguyên tắc xuyên suốt:

- **Đo, không suy.** Mỗi kết luận dẫn về các con số đo được; thứ chưa đo được mang giá trị `null`, không bao giờ
  được coi là "không có".
- **Nói bằng lời trước, số sau.** Người xem đọc câu kết luận trước; con số là bằng chứng, và con số nào cũng giải
  nghĩa được (mục 5).
- **Khôn dần bằng dữ liệu.** Gặp thứ lạ thì thêm một file vào danh mục, quy tắc hoặc bảng giải nghĩa — không thêm `case` vào code.
- **Chỉ đọc cho tới khi người xác nhận.** Cảm biến không được khởi động, đánh thức hay thay đổi bất cứ thứ gì (mục 3.2).
- **Claude không có đường tắt.** Claude đọc snapshot, đề xuất, còn việc dừng đi qua đúng các cổng an toàn như người.
- **hog không được là thứ ăn RAM.** App thường trú phải nhẹ và tự hiển thị nó đang dùng bao nhiêu (mục 9.2).

## 3. Tầng 1 — Cảm biến

### 3.1 Nguồn dữ kiện

Ưu tiên **API native của macOS** (nhanh, không phải phân tích văn bản); chỉ gọi lệnh ngoài cho thứ không có API
(`code --status`, `watchman`, `lsof`). ✔ = đã chạy thử được bằng Swift trên máy; ○ = chưa thử.

| Dữ kiện | Nguồn | Thời gian | | Điều đã kiểm / bẫy |
| --- | --- | --- | --- | --- |
| Danh sách tiến trình | `proc_listallpids` | — | ✔ | 587 tiến trình (2026-10-26). |
| RAM thật của tiến trình | `proc_pid_rusage` → `ri_phys_footprint` | **1 ms cho 587 tiến trình** | ✔ | **Khớp cột MEM của `top`**: watchman 1316M/1316M, Discord 499M/499M. `top` mất 1,85 s cho cùng việc. Tiến trình của root (WindowServer, launchd…) trả lỗi quyền (EPERM) → 387/587 đọc được; phần còn lại xem mục 3.5. |
| Phần còn nằm trong RAM | `ri_resident_size` | (cùng lời gọi) | ✔ | Tỉ lệ `resident / footprint` cho biết tiến trình **có đang được đụng tới không**: watchman 6M/1316M (gần như toàn bộ đã bị nén hoặc đẩy ra swap), phiên Claude đang chạy 191M/225M. Tỉ lệ có thể > 1 vì resident tính cả bộ nhớ dùng chung → kẹp về 1. |
| Phần bị nén của từng tiến trình | **không có API native** cho tiến trình khác | — | ✔ (đã thử) | `footprint − resident` **không** thay được: đúng với watchman (1310 so với `top` 1313) nhưng sai với phiên Claude (34 so với 134). Nên `compressed_bytes` của tiến trình là `null` ở lần quét nhanh; khi người xem mở chi tiết một thứ, gọi `top -l 2 -s 1 -stats pid,cmprs -pid <pid>` (≈ 1,85 s) để lấy số thật. |
| Cha–con, uid, giờ khởi chạy | `proc_pidinfo(PROC_PIDTBSDINFO)` → `pbi_ppid`, `pbi_uid`, `pbi_start_tvsec`; **dự phòng** `sysctl KERN_PROC_PID` (`kinfo_proc`) | < 1 ms | ✔ | Giờ khởi chạy là phần **danh tính** của tiến trình (mục 8, G3). **Giới hạn (qa đo):** `PROC_PIDTBSDINFO` trả EPERM cho tiến trình không phải của user (200/563, cả khi chạy từ job launchd — là hành vi của macOS, không phải sandbox), làm đứt chuỗi tổ tiên ở tiến trình root như `login` dưới Terminal.app (ảnh hưởng G1) và cho `own` = `null`. `kinfo_proc` đọc được 535/536, gồm cả các PID đó → dùng làm dự phòng; vẫn không đọc được thì chuỗi tổ tiên dừng ở đó và **G1 coi phần còn thiếu là tổ tiên có thể của hog** (chặn, không cho qua). |
| Đường dẫn thực thi | `proc_pidpath`, dự phòng `KERN_PROCARGS2` | < 1 ms | ✔ | Tên đầy đủ, không bị cắt 16 ký tự như `top`. **Bẫy (qa đo):** file thực thi đã bị xoá/thay (app được cập nhật trong lúc tiến trình cũ còn chạy) thì `proc_pidpath` trả rỗng (errno 2), còn `KERN_PROCARGS2` vẫn có đường dẫn lúc khởi chạy — nhưng đó là đường dẫn **đúng như truyền vào `execve`**, chưa resolve (reviewer thử: chạy `./mysleep` thì ra `./mysleep`), nên chỉ nhận khi là **đường dẫn tuyệt đối**. Không có đường dẫn tuyệt đối nào → `exe_path` = `null`, kéo theo `orphan` = `null`. |
| Tham số dòng lệnh | `sysctl KERN_PROCARGS2` | — | ✔ (qa) | Cần để nhận diện (vd `--resume`, `typesMap.json`). Dự phòng: `ps -o command=` (0,06 s, đã kiểm). |
| cwd | `proc_pidinfo(PROC_PIDVNODEPATHINFO)` | < 1 ms | ✔ | Thay cho gọi `lsof -d cwd` từng tiến trình như `lps` v0.1.0. |
| CPU của tiến trình | `ri_user_time + ri_system_time`, hai mẫu cách nhau | — | ✔ | Đổi đơn vị bằng `mach_timebase_info`. CLI lấy hai mẫu cách 1 s. App lấy mẫu thứ nhất lúc mở menu và mẫu thứ hai lúc quét đầy đủ xong (~2 s) — **không** dùng mẫu của lần mở menu trước (có thể cách hàng giờ, ra trung bình nhiều giờ). CPU trung bình cả đời = tổng thời gian CPU / tuổi. |
| Áp lực bộ nhớ | `sysctlbyname("kern.memorystatus_vm_pressure_level")` | < 1 ms | ✔ | 1 = bình thường, 2 = cảnh báo, 4 = nghiêm trọng (theo tài liệu XNU; trên máy mới thấy giá trị 1). Đây là chỉ báo chính thức; **không** dùng "free %" của `memory_pressure`. |
| Swap | `sysctlbyname("vm.swapusage")` | < 1 ms | ✔ | `total` thay đổi theo thời điểm (5120M ngày 15, 4096M ngày 26). |
| RAM toàn máy, RAM nén | `host_statistics64(HOST_VM_INFO64)` | < 1 ms | ✔ | Chạy được, khớp `vm_stat` (qa đo: occupied 5,25 GiB, stored 10,75 GiB). Phép thử đầu tiên của Claude trả toàn số 0 là do lỗi trong phép thử, không phải do API. "Pages occupied by compressor" (RAM vật lý bộ nén chiếm, khớp `top`) và "Pages stored in compressor" (dữ liệu logic đã nén) là **hai con số khác nhau**, gấp nhau ~2 lần (ngày 26: 5,4 GB và 10,6 GB) — hog xuất cả hai, tên khác nhau. |
| Job của launchd | `launchctl list` (PID ↔ label); `launchctl print gui/<uid>/<label>`, không thấy thì `user/<uid>/<label>` (qa: 28/155 job đang chạy chỉ có ở domain `user/`) — đọc **cấu hình đang nạp**, không đọc plist trên đĩa | 0,03 s mỗi lệnh | ✔ | Ngày 26: 290 tiến trình của user có cha là PID 1, **172** trong số đó là job launchd có label. watchman là job `com.github.facebook.watchman` với LaunchAgent do **chính watchman tạo** khi tự khởi động: `RunAtLoad = true`, `KeepAlive = { Crashed = true }` — launchd **chỉ** bật lại khi nó crash (`man launchd.plist`, mục Crashed), **không** bật lại khi tắt bình thường. Widget (`.appex`) có cha là PID 1 nhưng **không** có trong `launchctl list`. Fact `launchd.restarts_after_stop` lấy từ **`launchctl print`**, không từ plist: qa thử ghi đè plist mà không reload thì job vẫn chạy theo cấu hình cũ, đọc plist sẽ ra sai; và job không có plist (`launchctl submit`) vẫn có thể được giữ sống. Ánh xạ (qa thử từng dạng bằng job riêng): dòng `properties` có `keepalive` (`KeepAlive = true`, kể cả job submit không plist) → `true`; `semaphores` chỉ có `after crash => 1` (`Crashed = true`, như watchman) → `false`; `after crash => 0` (`Crashed = false`: bật lại khi thoát **bình thường**, tức đúng lúc hog dừng nó) → `true`; `successful exit => 0` (`SuccessfulExit = false`: SIGTERM bị bật lại) → `true`; semaphore khác (`PathState`… chưa thử) → `null`. Không có `keepalive` lẫn semaphore (7 job `application.*` do runningboardd submit; job không có `KeepAlive`) → `false`. **Không phải job** (`launchd.label` = null) → `false`. Job có label mà `print` lỗi ở cả hai domain → `null`. **Đã thử (qa, job launchd riêng cùng cấu hình `KeepAlive = { Crashed = true }`):** SIGTERM và SIGKILL không bị bật lại (theo dõi 18–24 s), SIGSEGV bị bật lại sau ~9 s. Log của watchman thật: sau một lần SIGTERM nó nằm yên 17 phút tới khi có client gọi; sau `shutdown-server` ngày 15 nằm yên 21 phút. |
| Cổng LISTEN, số kết nối | `lsof -nP -iTCP -sTCP:LISTEN` và `…:ESTABLISHED` | < 0,2 s | ✔ | Cách `lps` đang dùng. Bản native (`proc_pidfdinfo` cho socket) để sau. |
| Cửa sổ VS Code | `code --status` | 2,7–2,8 s (ngày 15 đo được 1,73 s) | ✔ | Cho `window [N] (tiêu đề)`, `extension-host [N]`, `file-watcher [N]` cùng số `N` và PID. **Cột `Mem MB` của lệnh này in số rác** (hàng chục tỷ MB) → không dùng. Cây cha–con đã đủ quy một tiến trình về `extension-host [N]`; `code --status` chỉ cần để biết `N` ↔ tiêu đề cửa sổ. |
| Phiên Claude | `~/.claude/sessions/<pid>.json` | < 0,01 s | ✔ | Có `pid`, `sessionId`, `cwd`, `startedAt`, `procStart`, `kind`, `entrypoint`, `status` (`idle`/`busy`), `statusUpdatedAt`. `procStart` là chuỗi kiểu `ps lstart` nhưng ở **giờ UTC** (`"Mon Oct 26 03:31:30 2026"`), độ phân giải giây — qa đo trên máy +07: so với `ps lstart` lệch đúng 25200 s ở 11/11 phiên, so với `pbi_start_tvsec` (coi chuỗi là UTC) lệch 0 s ở 11/11. Ngày 15: 7 phiên `idle` từ 178 đến 331 phút, 1 phiên `busy` cách 3 phút. Là định dạng nội bộ của Claude Code, **không có cam kết ổn định** → đọc dung sai (mục 3.3). Không đọc `*.key` cùng thư mục. |
| Lần hoạt động cuối (dự phòng) | mtime của `~/.claude/projects/<thư-mục>/<sessionId>.jsonl` | < 0,01 s | ✔ | Chỉ dùng khi thiếu `sessions/<pid>.json`. **Không giải mã tên thư mục** (`/` và `-` đều thành `-`, mơ hồ). |
| watchman | `watchman --no-spawn --no-local watch-list`, `… debug-get-subscriptions <root>` | 0,19 s | ✔ | Theo `watchman --help`, mặc định nó **thử khởi động service nếu chưa có** → luôn có `--no-spawn --no-local` (qa đã thử với socket không tồn tại: rc=1, không in gì, không sinh tiến trình, không tạo LaunchAgent → quy ước **rc=1 + rỗng = `unavailable`**). `subscriptions: []` = không ai đăng ký. Ngày 26: server chạy từ ngày 15 (cha là PID 1, cwd `/` — là daemon nên **không** khớp định nghĩa "mồ côi" ở mục 3.4), footprint 1316M, resident 6M. |
| Docker / OrbStack | Docker Engine API qua unix socket (không gọi CLI `docker`) | — | ○ | OrbStack đang chạy nhưng engine tắt thì `~/.orbstack/run/docker.sock` **không tồn tại** (đã kiểm) → `unavailable`, không phải lỗi, không bao giờ đánh thức engine. Lấy `State.Status`, `State.StartedAt`, `RestartCount`, `HostConfig.RestartPolicy`, cổng publish. `RestartCount` **cộng dồn từ lúc tạo** → phải xét cùng trạng thái/thời gian chạy. Docker API **không cho số kết nối**: `container.connections` = kết nối ESTABLISHED tới cổng publish (từ `lsof`); không publish cổng → `null`, không phải 0. |

**Thời gian (qa đo lại ngày 26):** `code --status` 2,7–2,8 s ở cả load 2 lẫn load 8–20 (lần đo đầu ngày 15 ra 1,73 s — nguyên nhân lệch chưa rõ, không phải do tải);
`watchman debug-get-subscriptions` ~0,17 s **mỗi root** (12 root ≈ 2 s). Quét tuần tự mất 5,0–6,0 s, **song song 2,75–3,33 s**; đường `--fast` 0,04–0,05 s. Do đó:
- Các cảm biến **chạy song song**; câu hỏi watchman cho từng root cũng chạy song song, tối đa 64 root. **Quá trần thì `watchman.subscriptions` = `null`** (không phải 0 trên số root đã hỏi), nên `watchman-no-subscribers`
  không kích hoạt — log watchman thật từng có 63 root (ngày 15) và 348 root (ngày 26); hỏi một phần rồi kết luận "không ai dùng" là suy.
  12 root song song mất 0,35 s (qa).
- Mục tiêu: `hog` < **4 s**; `hog --fast` (bỏ `code --status`, watchman **và mẫu CPU thứ hai** — `cpu.now_pct` = `null`, chỉ còn CPU trung bình cả đời) < **0,5 s**; lần quét nhẹ của app
  (API native) < 0,1 s.

### 3.1b Tìm lệnh ngoài khi chạy dưới dạng app

App mở từ Finder hay khi đăng nhập **không thừa hưởng `PATH` của shell** (trên máy: `launchctl getenv PATH` rỗng), mà `code` nằm
ở `~/.local/bin` và `watchman` ở `/opt/homebrew/bin`. Nên `HogCore` **không gọi lệnh theo tên trần**: mỗi lệnh ngoài có danh sách
đường dẫn tuyệt đối để dò (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, shim `code` bên trong
`Visual Studio Code.app/Contents/Resources/app/bin/`), ghi đè được trong `~/.config/hog/config.json`; không tìm thấy → cảm biến
`unavailable` với ghi chú "không tìm thấy lệnh X", không phải "không có X". **Chưa kiểm bằng app thật** — kiểm ngay ở bản chạy đầu tiên.

### 3.2 Bẫy "tự khởi động" — quy tắc cứng cho mọi cảm biến

Một lệnh chỉ-đọc mà vô tình **bật** một dịch vụ là lỗi nặng hơn không đo. Do đó:

(Ngoại lệ duy nhất cho "chỉ đọc", thêm sau qa 2026-10-26: `code --status` hết giờ thì hog dọn đúng tiến trình `Code --status` và file
`code-stdout-*` mà chính lần gọi đó để lại, rồi ghi bộ ngắt — xem mục 13.)


- Trước khi nói chuyện với một dịch vụ: kiểm sự tồn tại (socket, tiến trình). Không có → `unavailable`.
- Cờ chống tự khởi động bắt buộc (`watchman --no-spawn --no-local`). Cảm biến nào chưa chứng minh được là không
  khởi động gì thì **không được thêm**.
- Gọi `code --status` chỉ khi đã thấy tiến trình chính của VS Code, và có timeout (5 s).
- Mọi lệnh con có timeout; hết giờ → cảm biến `error`, phần còn lại vẫn hiển thị.

### 3.3 Độ bền khi nguồn thay đổi

Mỗi cảm biến trả `status` ∈ {`ok`, `unavailable`, `skipped`, `error`} kèm `took_ms` và `note` (trong `sensors[]` của
snapshot). Trường không lấy được là `null`. Đọc JSON của Claude Code bỏ qua khoá lạ, thiếu khoá → `null`; **định dạng
đổi thì phần "phiên Claude" tụt về `unavailable` kèm ghi chú**, phần còn lại vẫn chạy.

### 3.4 Quy chiếu "ai sở hữu"

Một tiến trình có thể có nhiều thuộc tính sở hữu: `app`, `window`, `project`, `session`. Theo thứ tự:

1. Đi ngược chuỗi cha tới `launchd` (PID 1), ghi mọi tổ tiên.
2. **Phiên Claude**: PID khớp một `sessions/<pid>.json` **và** `procStart` trong file (đọc như **UTC**) khớp `pbi_start_tvsec` của tiến trình, sai lệch ≤ 1 s (chống file cũ /
   PID tái sử dụng; thiếu `procStart` thì so `startedAt` với dung sai 5 s) → `session = claude:<pid>`, `project` từ `cwd`.
3. **Cửa sổ VS Code**: tổ tiên là `extension-host [N]` (hoặc `window [N]`) → `window = vscode:N`, nhãn là tiêu đề cửa sổ.
4. **App**: đường dẫn thực thi nằm trong `<tên>.app` → `app = <tên>`.
5. **Dự án**: từ cwd đi lên tìm `.git`, `package.json#name`, `go.mod`, `Package.swift`…, hoặc từ tiêu đề cửa sổ.
6. **Mồ côi** (`orphan: true`) khi **đủ cả**: cha là PID 1; **không** phải job của launchd (`launchctl list`); file thực thi **không**
   nằm trong `.appex`/`.xpc` (widget, dịch vụ XPC); **không** dưới `/System`; cwd trong thư mục người dùng.
   - Vì sao không giữ định nghĩa của `lps` (cha PID 1 + cwd trong thư mục người dùng): qa đo ngày 26 có 108 tiến trình như vậy,
     toàn widget/extension của macOS — bị coi nhầm là mồ côi.
   - **Đã thử định nghĩa mới** trên máy (hai lần, Claude và qa): bắt đúng python3 và node server mồ côi do test tạo; loại đúng job
     launchd có cwd trong home và tiến trình có cwd `/`. Lần đo của qa có **2 bắt nhầm** — widget Word/Excel mà file thực thi đã bị
     thay khi app cập nhật, `proc_pidpath` trả rỗng nên lọt bộ lọc `.appex`; dùng `KERN_PROCARGS2` thì 0 bắt nhầm (đã sửa ở mục 3.1).
   - **Giới hạn đã biết:** daemon mà người dùng **cố ý** tách khỏi shell (tmux, screen, Gradle daemon) khớp định nghĩa mồ côi. Chúng
     được loại bằng danh mục: mục danh mục có `"detached_by_design": true`, và fact `catalog.detached` = true; `orphan-quiet` đòi
     `catalog.detached` = false. Fact này là `false` khi không khớp mục nào (khớp danh mục là phép tất định, không phải thiếu số đo),
     nên daemon lạ chưa có trong danh mục **vẫn có thể** bị đề xuất — quy tắc `soft` của G2 không che được ca này. Đã thử với
     `screen` (qa); tmux, Gradle chưa thử vì máy không có. Không được loại `.app/` hay `.framework/`: `/usr/bin/python3` thật ra chạy file nằm
     trong `Xcode.app/…/Python3.framework/…/Python.app` — loại hai thứ đó là bỏ sót dev server viết bằng Python.
   - Daemon (watchman, cwd `/`, là job launchd) **không** là mồ côi; quy tắc cho chúng không dựa vào `orphan` (mục 6.2).

Không quy được thì `null`, không đoán. Mỗi owner cộng dồn RAM/CPU cả cây con (`total_*`) và riêng nó (`self_*`).

### 3.5 Tiến trình không đọc được (của hệ thống)

Không có quyền đọc RAM của tiến trình root (đã kiểm: EPERM), mà hog không bao giờ dùng `sudo`. Đã chốt (2026-10-26):

- Lần quét thường gộp chúng thành một dòng **"macOS và dịch vụ hệ thống — {n} tiến trình chưa đo"**, **không có con số**.
  Lý do bỏ phép trừ "RAM toàn máy − tổng đã đo": `footprint` tính cả phần đã nén và đã swap theo kích thước gốc, nên tổng
  footprint có thể **vượt** RAM vật lý — đo ngày 2026-10-26: tổng MEM của `top` cho 361 tiến trình của user là 19,05 GiB, trong
  khi RAM vật lý đang dùng (theo `vm_stat`) là 15,33 GiB, phép trừ ra số âm. Thay vào đó, phần tổng quan hiện trực tiếp các số đo
  được của hệ thống: `wired` và RAM bộ nén chiếm.
- Mở chi tiết dòng đó (nút "Đo chi tiết" trong app, `hog explain system` trong CLI) → gọi
  `top -l 2 -s 1 -stats pid,command,mem,cmprs,cpu` **một lần** (≈ 1,85 s; `top` đọc được cả tiến trình root, đã kiểm) để hiện
  từng tiến trình hệ thống, ghép tên đầy đủ qua `proc_pidpath`. Có giải nghĩa từng tiến trình hệ thống thường gặp (WindowServer,
  kernel_task, mds…) trong danh mục.
- Không có nút dừng nào cho các tiến trình này (cổng G6).

## 4. Định dạng snapshot JSON (`hog --json`)

Đây là **hợp đồng** giữa hog, Claude, hub và app. Quy ước:

- `schema` = `hog.snapshot/1`. Trong cùng số major chỉ **thêm** trường; người đọc bỏ qua trường lạ. Đổi nghĩa hoặc
  xoá trường → tăng major.
- Dung lượng là số nguyên **byte** (`_bytes`), phần trăm là số thực (`_pct`), tỉ lệ 0..1 (`_ratio`), thời gian RFC 3339
  UTC (`_at`), khoảng thời gian là giây (`_s`). Chưa đo được là `null`.
- **Riêng tư:** thư mục home thay bằng `~`; **không có biến môi trường**; `args` cắt 200 ký tự và che giá trị của cờ có
  tên chứa `token|key|secret|password|auth`. hog không tự gửi snapshot ra mạng (xem dòng "Riêng tư, nói rõ" bên dưới).
- ≤ 100 KB: `processes` chỉ gồm tiến trình đáng kể (RAM ≥ 50 MB, CPU ≥ 5 %, đang nghe cổng, hoặc thuộc một item / tổ
  tiên của chúng); phần còn lại gộp vào `other`. `--full` để lấy hết.
- Có sẵn **lời giải nghĩa** (`headline`, `glossary_ids`) để Claude và app nói cùng một giọng (mục 5).
- **Một ngôn ngữ mỗi snapshot**: trường `lang` (`vi`/`en`, theo `--lang` hoặc ngôn ngữ máy); mọi chuỗi lời (`headline.text`,
  `reason`, `effect`, `label` lấy từ danh mục) đã ở ngôn ngữ đó. Khoá máy đọc (`verdict`, `id`…) không dịch.
- **Riêng tư, nói rõ:** hog không tự gửi snapshot đi đâu. Nhưng khi **bạn** hỏi Claude bằng skill trong hub, chính snapshot — gồm tiêu
  đề cửa sổ, tên dự án, cwd — được đưa cho Claude. Giai đoạn 2 không có nút "Hỏi Claude"; "Chép thông tin" chép một item đã làm sạch
  ([thiết kế giai đoạn 2](phase-2-vi.md) mục 3).

Ví dụ rút gọn (dữ liệu giả):

```json
{
  "schema": "hog.snapshot/1",
  "lang": "vi",
  "taken_at": "2026-10-26T03:44:55Z",
  "hog": { "version": "0.2.0", "pid": 4242, "ancestors": [4100, 3990, 3801], "self_footprint_bytes": 31000000 },
  "host": { "os": "darwin", "arch": "arm64", "ncpu": 8, "mem_total_bytes": 17179869184, "uptime_s": 1255000 },
  "memory": {
    "free_bytes": 65000000,
    "compressor_bytes": 5720000000,
    "compressed_stored_bytes": 11130000000,
    "swap_used_bytes": 3292000000,
    "swap_total_bytes": 4294967296,
    "pressure": "normal",
    "wired_bytes": 2731000000,
    "unreadable_process_count": 200,
    "system_detail": null
  },
  "cpu": { "user_pct": 8.5, "sys_pct": 13.1, "idle_pct": 78.4, "load": [1.6, 2.2, 2.7] },
  "headline": {
    "level": "ok",
    "text": "Máy chưa thiếu RAM (áp lực: bình thường), nhưng đã nén 10,4 GB dữ liệu (chiếm 5,3 GB RAM) và đẩy 3,1 GB ra ổ đĩa. Có 1 thứ có thể tắt: watchman (giữ 1,3 GB, 11 ngày không ai dùng).",
    "glossary_ids": ["memory-pressure", "compressed-stored", "compressor-occupied", "swap-used"]
  },
  "sensors": [
    { "name": "native-proc", "status": "ok", "took_ms": 2 },
    { "name": "docker", "status": "unavailable", "took_ms": 0, "note": "engine socket missing (engine stopped)" }
  ],
  "owners": [
    { "id": "app:vscode", "kind": "app", "label": "Visual Studio Code", "parent": null,
      "self_footprint_bytes": 1500000000, "total_footprint_bytes": 5200000000, "total_cpu_pct": 6.0 },
    { "id": "vscode:7", "kind": "vscode-window", "label": "web-app (Workspace)", "parent": "app:vscode",
      "project": "web-app", "total_footprint_bytes": 2100000000, "total_cpu_pct": 1.2 }
  ],
  "processes": [
    { "pid": 74939, "ppid": 1, "own": true, "exe": "watchman",
      "started_at": "2026-10-15T08:08:52Z", "age_s": 934563,
      "footprint_bytes": 1380000000, "resident_bytes": 6300000, "resident_ratio": 0.005, "compressed_bytes": null,
      "cpu": { "now_pct": 0.0, "avg_pct": 0.0 },
      "cwd": "/", "project": null, "orphan": false,
      "net": { "listen": [], "established": 0 },
      "catalog_id": "watchman", "owner_id": null, "item_id": "proc:74939:1792051732" }
  ],
  "items": [
    { "id": "proc:74939:1792051732", "kind": "process", "label": "Watchman", "catalog_id": "watchman",
      "pids": [74939], "owner_id": null,
      "footprint_bytes": 1380000000, "resident_ratio": 0.005,
      "protection": null,
      "facts": { "orphan": false, "age_s": 934563, "cpu.avg_pct": 0.0, "footprint_bytes": 1380000000, "resident_ratio": 0.005,
                 "net.established": 0, "owner.kind": "none", "owner.busy": false, "watchman.subscriptions": 0,
                 "launchd.label": "com.github.facebook.watchman", "launchd.restarts_after_stop": false } }
  ],
  "findings": [
    { "item_id": "proc:74939:1792051732", "verdict": "may-stop", "confidence": "high",
      "rules": ["watchman-no-subscribers", "dormant-large"],
      "reason": "Watchman chạy 11 ngày, không công cụ nào đăng ký theo dõi, giữ 1,3 GB nhưng chỉ 6 MB còn nằm trong RAM — tức là lâu rồi không ai đụng tới.",
      "evidence": { "watchman.subscriptions": 0, "resident_ratio": 0.005, "age_s": 934563, "footprint_bytes": 1380000000 },
      "unmeasured": [],
      "stop": { "strategy": "watchman-shutdown", "respawns": "on-demand",
                "effect": "Tắt không mất dữ liệu: lần sau Metro/Jest cần thì nó được bật lại và quét lại thư mục một lần. launchd chỉ bật lại nó khi crash, không khi tắt bình thường." },
      "blocked_by": [] }
  ],
  "warnings": []
}
```

Ghi chú:

- `compressor_bytes` = RAM vật lý bộ nén đang chiếm; `compressed_stored_bytes` = lượng dữ liệu đã bị nén vào đó. Hai số
  cùng được gọi là "RAM nén" ngoài đời nhưng khác nhau, nên tên khác nhau và cả hai đều có giải nghĩa.
- `item_id`: `proc:<pid>:<giờ khởi chạy epoch>`, `claude:<pid>`, `ctr:<id 12 ký tự>`. **Danh tính gồm giờ khởi chạy**
  để PID bị tái sử dụng không bị nhầm (mục 8, G3).
- `facts` là **toàn bộ** thứ quy tắc được phép đọc (mục 6); mỗi fact là số đo hoặc `null`.

### Item và hành động

| `kind` | Là gì | Dừng được bằng hog? |
| --- | --- | --- |
| `process` | một tiến trình (kèm con trực tiếp cùng nhóm) | có — chiến lược `signal` hoặc chiến lược riêng của danh mục |
| `claude-session` | một tiến trình `claude` có `sessions/<pid>.json` | giai đoạn 1: chỉ `manual` (đóng tab); nhắm thẳng SIGTERM vẫn phải qua G2 |
| `container` | một container Docker/OrbStack | có — chiến lược `docker-container` (mục 8, G5) |
| cửa sổ / app (là *owner*, không phải item) | — | **không**: hog chỉ nói "đóng cửa sổ X trong VS Code" |

## 5. Tầng giải nghĩa — trả lời "số này nghĩa là gì?"

Đây là phần thay Activity Monitor cho người không đọc được số. Ba thành phần, đều là **dữ liệu**.

**Song ngữ Việt + Anh** (đã chốt 2026-10-26): mọi chuỗi người đọc thấy — câu một dòng, bảng thuật ngữ, `summary`/`stop_effect` của
danh mục, `reason` của quy tắc, nhãn giao diện — có cả `vi` và `en`. Ngôn ngữ theo ngôn ngữ của máy, đổi được bằng tuỳ chọn
(`hog --lang vi|en`, cài đặt trong app). Thiếu bản dịch của một mục → dùng ngôn ngữ còn lại và báo trong `warnings`;
`hog catalog check` báo mục thiếu bản dịch. JSON giữ khoá máy đọc (`verdict`, `id`…) không dịch; chỉ phần lời được dịch.

### 5.1 Câu trả lời một dòng (`headline`)

Dòng đầu tiên của CLI và của app luôn là **một câu bằng lời**, rồi mới tới số. Câu được ghép từ các mẫu trong
`explain/headline.json` theo mức áp lực và các finding, ví dụ:

| Tình huống | Câu (mẫu) |
| --- | --- |
| áp lực bình thường, không có đề xuất | "Máy đang đủ RAM. Nặng nhất: {owner} ({size})." |
| áp lực bình thường, có đề xuất | "Máy chưa thiếu RAM, nhưng có {n} thứ có thể tắt: {list}." (không hứa "rảnh X GB": thứ ngủ đông như watchman giữ 1,3 GB nhưng chỉ 6 MB còn trong RAM, tắt đi trả lại RAM thật ít hơn nhiều) |
| áp lực cảnh báo | "Máy đang thiếu RAM: đã nén {compressed_stored} dữ liệu và đẩy {swap} ra ổ đĩa, nên chậm. Ăn nhiều nhất: {top3}." |
| áp lực nghiêm trọng | "Máy đang thiếu RAM nặng. Nên đóng bớt: {list theo mức an toàn}." |

Quy tắc viết (cả `vi` và `en`): lời thường, số làm tròn kiểu người đọc (`1,3 GB`, `11 ngày`), **không thuật ngữ nếu không kèm giải
nghĩa**, không kết luận nào thiếu số đo đứng sau.

### 5.2 Bảng thuật ngữ (`explain/glossary/<id>.json`)

Mỗi con số mà hog hiển thị gắn với **một mục giải nghĩa**; trong app có dấu `?` cạnh số, trong CLI có `hog explain <thuật ngữ>`.
Test bắt buộc: mọi số hiển thị đều có mục trong bảng (mục 10).

```json
{
  "id": "resident-ratio",
  "activity_monitor": null,
  "name": { "vi": "Phần còn nằm trong RAM", "en": "Share still in RAM" },
  "plain": {
    "vi": "Trong số RAM một chương trình đang giữ, bao nhiêu phần thật sự còn nằm trong RAM. Phần còn lại đã bị macOS nén hoặc đẩy ra ổ đĩa vì lâu không ai đụng tới.",
    "en": "Of the memory a program holds, how much is actually still in RAM. The rest has been compressed or swapped out by macOS because nobody touched it for a while."
  },
  "how_to_read": {
    "vi": "Gần 100%: chương trình đang được dùng. Dưới 10%: lâu rồi không ai đụng tới — dấu hiệu mạnh rằng tắt đi cũng không ai để ý.",
    "en": "Near 100%: in use. Below 10%: untouched for a long time — a strong sign nobody would notice if it stopped."
  },
  "act": {
    "vi": "Thấp + chiếm nhiều + mồ côi → ứng viên tắt. Thấp mà thuộc app bạn đang mở thì chỉ là app đó đang nghỉ.",
    "en": "Low + large + orphaned → candidate to stop. Low but part of an app you have open just means that app is idle."
  },
  "provenance": { "source": "measured", "verified": true }
}
```

Bộ khởi đầu, kèm tên tương ứng trong Activity Monitor để bạn đối chiếu được. Cột "Activity Monitor" là theo tài liệu
của Apple và hiểu biết chung, **chưa đối chiếu bằng mắt trên máy** → `verified: false` cho tới khi đối chiếu ở giai đoạn 1:

| id | Tên trong hog | Activity Monitor | Ý chính (rút gọn) |
| --- | --- | --- | --- |
| `memory-pressure` | Áp lực bộ nhớ | Memory Pressure (biểu đồ xanh/vàng/đỏ) | **Số duy nhất cho biết máy có thiếu RAM không.** Xanh là ổn, kể cả khi "RAM đã dùng" gần đầy. |
| `memory-used` | RAM đang dùng | Memory Used | macOS cố ý dùng gần hết RAM để chạy nhanh; con số này cao **không** có nghĩa là thiếu. |
| `footprint` | RAM của chương trình | cột Memory | RAM một chương trình thật sự chiếm, **tính cả phần đã bị nén**. Đây là số để so ai ăn nhiều. |
| `resident-ratio` | Phần còn nằm trong RAM | (không có) | Xem ví dụ trên. |
| `compressed-stored` | Dữ liệu đã nén | (chưa rõ — xem dưới) | Lượng dữ liệu của các chương trình mà macOS đã nén lại thay vì ghi ra ổ đĩa ("Pages stored in compressor"). Nhiều = máy đang chật, đang phải xoay xở. |
| `compressor-occupied` | RAM bộ nén chiếm | (chưa rõ — xem dưới) | RAM thật mà phần dữ liệu đã nén đang chiếm ("Pages occupied by compressor", khớp `top`), thường bằng khoảng một nửa số trên. |
| `swap-used` | Đẩy ra ổ đĩa | Swap Used | Phần RAM bị chuyển ra SSD. Cao + áp lực vàng/đỏ = nguyên nhân máy ì. |
| `cached-files` | Bộ đệm file | Cached Files | RAM tạm giữ nội dung file để mở lại nhanh; macOS **tự trả lại ngay** khi cần. Không phải vấn đề. |
| `wired` | Bộ nhớ hệ thống cố định | Wired Memory | Của nhân macOS, không nén được, không tắt được. Không cần quan tâm. |
| `app-memory` | RAM của các app | App Memory | Tổng RAM các chương trình dùng. |
| `cpu-pct` | CPU | % CPU | 100% = một nhân chạy hết sức; máy 8 nhân tối đa 800%. |
| `cpu-avg` | CPU trung bình từ lúc chạy | (không có; gần với CPU Time / tuổi) | Thấp suốt nhiều giờ = chương trình gần như không làm gì. |
| `orphan` | Mồ côi | (không có) | Chương trình mà thứ đã mở nó (terminal, editor) đã tắt, nhưng nó vẫn chạy — hay là dev server bị bỏ quên. |
| `idle-session` | Phiên Claude rảnh | (không có) | Phiên không làm gì từ {time}. Phiên rảnh lâu vẫn giữ RAM. |
| `real-private-shared` | — | Real Mem, Private Mem, Shared Mem, Purgeable | Các cột chi tiết của Activity Monitor; hog **không dùng** để quyết định và giải thích vì sao dùng `footprint` thay vào. |

Cột **Compressed** của Activity Monitor ứng với số nào trong hai số nén ở trên thì **chưa biết**; đối chiếu bằng mắt ở bản chạy
đầu tiên rồi ghi vào cột "Activity Monitor". Tới lúc đó hog luôn hiện **cả hai số cạnh nhau** (`10,4 → 5,3 GB`) để không bao giờ
có một con số lệch Activity Monitor mà không giải thích được.

### 5.3 Mô tả theo danh mục và quy tắc

Lời giải thích của một finding ghép từ `reason` của quy tắc (dẫn số đo, mục 6) + `summary` / `stop_effect` của mục danh mục
(mục 7). Nhờ vậy câu trả lời luôn có đủ ba ý: **nó là gì · vì sao hog nghĩ có thể tắt · tắt thì mất gì**.

## 6. Tầng 2 — Quy tắc

Quy tắc là **dữ liệu** (`rules/<id>.json`). Ngôn ngữ cố ý nhỏ: không biểu thức tự do, không lệnh, chỉ so trường với hằng.

```json
{
  "id": "orphan-quiet",
  "applies_to": ["process"],
  "class": "advice",
  "verdict": "may-stop",
  "when": { "all": [
    { "fact": "orphan",           "eq": true },
    { "fact": "net.established",  "eq": 0 },
    { "fact": "age_s",            "gte": 3600 },
    { "fact": "cpu.avg_pct",      "lt": 1.0 },
    { "fact": "catalog.detached", "eq": false }
  ] },
  "reason": {
    "vi": "Tiến trình mồ côi (cha đã thoát), không ai đang kết nối, gần như không dùng CPU suốt {age_s}.",
    "en": "Orphaned process (its parent exited), no open connections, almost no CPU for {age_s}."
  }
}
```

- `when`: `all` / `any` / `not` lồng nhau; toán tử `eq, ne, gt, gte, lt, lte, in, exists`.
- `fact`: một khoá trong `items[].facts`. Fact giai đoạn 1: `orphan`, `age_s`, `cpu.now_pct`, `cpu.avg_pct`, `footprint_bytes`,
  `resident_ratio`, `net.established`, `net.listen_count`, `owner.busy`, `owner.idle_s`, `owner.kind`, `catalog.family`,
  `siblings.same_catalog_other_windows`, `container.restart_count`, `container.restart_policy`, `container.state`,
  `container.uptime_s`, `container.connections`, `watchman.subscriptions`, `catalog.detached`, `launchd.label`, `launchd.restarts_after_stop`,
  `session.busy`, `session.idle_s`, `self.ancestor`, `own` (uid của tiến trình = uid của
  người chạy hog), `exe.name` (tên file thực thi), `exe.macos` (dưới `/System` hoặc `/Library/Apple`: chính macOS), `exe.system` (đường dẫn thực thi dưới `/System`, `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin`, `/usr/libexec`,
  `/usr/lib`, `/usr/share`, `/Library/Apple`; **không** gồm `/usr/local` — nơi công cụ của user như `/usr/local/go/bin/go` hay Node cài
  bằng pkg nằm).
  Thêm fact = thêm code cảm biến; thêm quy tắc = thêm file.
- `reason` là mẫu có `{fact}`; câu giải thích **phải dẫn ra con số đã đo**, viết theo luật của mục 5.1.

### 6.1 Ngữ nghĩa ba giá trị (chỗ thực thi luật "đo, không suy")

Mỗi điều kiện cho `true`, `false` hoặc **`unknown`** (fact là `null`). Hai lớp quy tắc:

| Lớp | Tạo ra | Điều kiện `unknown` thì… | Vì sao |
| --- | --- | --- | --- |
| `advice` | một **finding**, verdict `may-stop`, `watch` hoặc `info` | **không kích hoạt**; fact thiếu ghi vào `unmeasured` | thiếu số đo thì không được kết luận "không dùng" |
| `protect` | một **bảo vệ** gắn vào item (`item.protection`) | **kích hoạt** (coi như có thể đang dùng) | không biết ai đang dùng thì phải bảo vệ |

Mức bảo vệ (`level`):

- `hard` — hog **không dừng được** (cổng G1, G6). `may-stop` của item bị hạ thành `info` kèm lý do.
- `soft` — dừng được nhưng **phải có người xác nhận, thấy tên chủ sở hữu** (G2). `may-stop` hiển thị thành `ask`:
  "có dấu hiệu không dùng nhưng thuộc phiên/cửa sổ khác — hỏi chủ trước". Đây là nhãn "đừng đụng".

Kết hợp theo logic ba giá trị Kleene: `all` = false nếu có một false, ngược lại unknown nếu có một unknown; `any` đối xứng;
`not unknown` = unknown. Quyết định `unknown` → kích hoạt hay không chỉ áp dụng **ở kết quả cuối** của `when`, không ở từng lá —
nên `not` không thể lật một số đo thiếu thành bằng chứng.

Thứ tự hiển thị: `may-stop` / `ask` > `watch` > `info`. **Mọi** quy tắc đã kích hoạt đều được liệt kê. `confidence` = số
**phép đo độc lập** ủng hộ kết luận (1 → `low`, 2 → `medium`, ≥ 3 → `high`).

### 6.2 Bộ quy tắc khởi đầu

| Quy tắc | Lớp / verdict | Điều kiện (rút gọn) |
| --- | --- | --- |
| `protect-self` | protect, `hard` | item là hog, hoặc tổ tiên của hog (shell, phiên Claude đang gọi hog, cửa sổ chứa nó) |
| `protect-foreign` | protect, `hard` | `own` = false **hoặc** `exe.macos` = true **hoặc** `exe.name` ∈ {`launchd`, `WindowServer`, `kernel_task`} **hoặc** (`exe.system` = true **và** là job launchd). Tiến trình của macOS chạy bằng uid của user (Dock, cfprefsd… dưới `/System`) được bảo vệ nhờ `exe.macos`. Công cụ dưới `/usr/bin`, `/bin` mà user tự chạy từ shell (tunnel `ssh -N -L`, `python3 -m http.server`) **không** bị chặn cứng — khi chạy thật, bản đầu chặn cả `/bin/sleep` do user chạy, nên không dừng được đúng loại mồ côi cần bắt |
| `protect-busy-owner` | protect, `soft` | (`applies_to`: `process`, `container`) có owner (`owner.kind` ≠ `none`) và (`owner.busy` là true **hoặc unknown**, hoặc `owner.idle_s` < 600). Mồ côi không owner → `owner.busy` = false. Cửa sổ VS Code chưa có số đo bận/rảnh → `unknown` → tiến trình con được bảo vệ mức `soft` |
| `orphan-quiet` | advice, `may-stop` | mồ côi + **không** phải daemon cố ý tách (`catalog.detached` = false) + 0 kết nối + tuổi ≥ 1 giờ + CPU trung bình < 1 % |
| `dormant-large` | advice, `watch` | `footprint_bytes` ≥ 500 MB và `resident_ratio` < 0,1 — "chiếm nhiều mà gần như không ai đụng tới" (bằng chứng độc lập, cộng thêm vào `confidence` của các đề xuất khác) |
| `claude-session-abandoned` | advice, `may-stop` | `claude-session`, `session.busy` = false, `session.idle_s` ≥ 7200, RAM ≥ 100 MB — chiến lược `manual` (đóng tab). Item `claude-session` **không** chịu `protect-busy-owner` (`applies_to` của quy tắc đó là `process`, `container`) mà chịu `protect-busy-session` bên dưới: cửa sổ VS Code chứa phiên luôn `unknown`, nếu xét thì mọi phiên đều bị bảo vệ (qa: 11 phiên trên máy là con của ba extension-host — 6, 4 và 1 phiên) |
| `protect-busy-session` | protect, `soft` | `claude-session` và (`session.busy` là true **hoặc unknown**, hoặc `session.idle_s` < 600) |
| `container-crash-loop` | advice, `may-stop` | `restart_count` ≥ 10 **và** (`state` = `restarting` **hoặc** `uptime_s` < 600) **và** `connections` = 0 |
| `container-restart-high` | advice, `watch` | `restart_count` ≥ 10 — luôn hiện để người xem log, kể cả khi `connections` là `null` |
| `container-no-clients` | advice, `watch` | đang chạy, `connections` = 0 (chưa đủ để kết luận khi chưa có lịch sử) |
| `watchman-no-subscribers` | advice, `may-stop` | catalog `watchman`, `watchman.subscriptions` = 0, tuổi ≥ 1 giờ. **Không** đòi `orphan`: watchman là daemon, cha luôn là PID 1 và cwd `/` |
| `launchd-restarts` | advice, `info` | `launchd.restarts_after_stop` = true, `footprint_bytes` ≥ 100 MB, `exe.system` = false (Finder, ControlCenter… không bao giờ bị dừng, dòng này với chúng là nhiễu) — "launchd sẽ bật lại nó nếu chỉ dừng". Việc **không gửi tín hiệu** cho job như vậy nằm trong code dựng kế hoạch dừng (mục 8), không trong quy tắc: kế hoạch tụt về hướng dẫn (ví dụ `launchctl bootout gui/<uid>/<label>`). Giai đoạn 1 hog **không** gỡ job launchd |
| `duplicate-language-server` | advice, `info` | `catalog.family` = `language-server` và `siblings.same_catalog_other_windows` ≥ 1 |
| `memory-heavy` | advice, `watch` | `footprint_bytes` ≥ 1 GiB |

Ngưỡng 2 giờ của `claude-session-abandoned` là **đề xuất** (phiên bị bỏ quên đo được rảnh 178–331 phút, phiên đang làm việc
cách 3 phút). Ngưỡng 0,1 của `dormant-large` cũng là đề xuất, từ một điểm đo (watchman 0,005, phiên Claude đang chạy 0,85).

**Giới hạn của giai đoạn 1:** chưa có lịch sử nên "im lâu" đo bằng thế thay: tuổi, CPU trung bình cả đời, kết nối hiện tại,
`resident_ratio`, `idle_s` của phiên Claude. `confidence` phản ánh đúng số phép đo; kết luận mạnh hơn chờ giai đoạn 3.

### 6.3 Ghi đè cục bộ

`~/.config/hog/rules.d/*.json` nạp sau bộ có sẵn; **cùng `id` thì bản cục bộ thắng** — chỗ Claude thêm/chỉnh quy tắc theo ca
thực tế mà không cần bản mới. Mọi file qua kiểm tra nghiêm ngặt (`hog rules check`): khoá lạ, toán tử lạ, `fact` không
tồn tại → **bỏ qua file đó**, báo trong `warnings` kèm đường dẫn + lý do; không bao giờ làm hog dừng chạy. Quy tắc cục bộ
**không được hạ** hay tắt một bảo vệ `hard`.

## 7. Tầng 2 — Danh mục

Một mục = một file `catalog/<id>.json`: "đây là cái gì, tắt thì sao" thành dữ liệu cho người và Claude đọc.

```json
{
  "id": "watchman",
  "name": "Watchman",
  "family": "file-watcher",
  "summary": {
    "vi": "Dịch vụ theo dõi thay đổi file của Meta; Metro/Jest dùng nó để biết file nào vừa sửa. Giao tiếp qua unix socket nên không có cổng TCP.",
    "en": "Meta's file-watching service; Metro/Jest use it to learn which files changed. Talks over a unix socket, so it has no TCP port."
  },
  "stop_effect": {
    "vi": "Tắt không mất dữ liệu: lần sau có công cụ cần, nó được bật lại và quét lại thư mục một lần. Trên macOS nó thường chạy như job launchd do chính nó tạo, chỉ được bật lại khi crash (đã đọc cấu hình và thử bằng job cùng cấu hình).",
    "en": "Stopping loses no data: the next tool that needs it starts it again and re-crawls once. On macOS it usually runs as a launchd job it created itself, restarted only after a crash (config read and tested with an identical job)."
  },
  "respawns": "on-demand",
  "stop": { "strategy": "watchman-shutdown" },
  "match": [ { "exe": "watchman" } ],
  "provenance": { "added": "2026-10-15", "source": "measured", "verified": true }
}
```

- `match`: **một** phần tử khớp là đủ; trong một phần tử **mọi** điều kiện phải đúng. Điều kiện: `exe` (so tên file từ đường dẫn thực thi đã resolve — `proc_pidpath`, không phải `argv[0]`: qa thấy `screen` có
  `argv[0]` = `/usr/bin/SCREEN` còn `proc_pidpath` = `/usr/bin/screen`), `exe_path_contains`,
  `args_contains`, `parent_catalog`, `listens_port`, `container_image` (`""` = mọi container), `vscode_role` (vai trò trong `code --status`:
  file watcher, pty host và shared process của VS Code có **tham số giống hệt nhau**, chỉ phân biệt được bằng vai trò). Nhiều mục cùng khớp → mục nhiều điều kiện hơn thắng.
- `detached_by_design` (bool, mặc định `false`): thứ người dùng **cố ý** để chạy nền tách khỏi shell (tmux, screen, Gradle daemon). Cho
  fact `catalog.detached` = true, nên `orphan-quiet` không đề xuất dừng nó dù khớp định nghĩa mồ côi (mục 3.4).
- `respawns`: `never` · `by-parent` · `on-demand` · `supervisor`. Dừng thứ `by-parent` là vô ích → hog gợi ý đóng cửa sổ.
- `stop.strategy` **chỉ chọn trong tập có sẵn trong code**: `signal`, `watchman-shutdown`, `docker-container`, `manual`.
  **Danh mục không được chứa lệnh tuỳ ý** — file do Claude hay người viết không bao giờ thành thứ thực thi được.
- `provenance.verified: false` → hog hiện "⚠ chưa kiểm" cạnh mô tả. Danh mục **không được giả vờ chắc chắn**.

Ghi đè cục bộ: `~/.config/hog/catalog.d/*.json`, cùng quy tắc như mục 6.3 (`hog catalog check`). Mục ổn định thì đưa vào repo.

### Danh mục khởi đầu (22 mục)

✔ = đã thấy trên máy; ○ = kiến thức chung, chưa thấy → `verified: false` tới khi gặp thật.

| # | id | Là gì | | # | id | Là gì | |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | `vscode-renderer` | vẽ một cửa sổ VS Code | ✔ | 11 | `orbstack-app` | ứng dụng OrbStack (engine tắt riêng được) | ✔ |
| 2 | `vscode-extension-host` | chạy mọi extension của một cửa sổ | ✔ | 12 | `docker-container` | container Docker/OrbStack (mục chung) | ○ |
| 3 | `vscode-file-watcher` | theo dõi file của một cửa sổ | ✔ | 13 | `metro` | bundler React Native | ○ |
| 4 | `vscode-gpu` | tiến trình GPU dùng chung | ✔ | 14 | `next-dev` | `next dev` | ○ |
| 5 | `vscode-pty-host` | giữ các terminal tích hợp | ✔ | 15 | `vite-dev` | dev server Vite | ○ |
| 6 | `tsserver` | language server TypeScript | ✔ | 16 | `adb-server` | cầu nối Android Debug Bridge | ○ |
| 7 | `typings-installer` | tải type cho tsserver | ✔ | 17 | `spotlight-mdworker` | lập chỉ mục Spotlight | ✔ |
| 8 | `pylance` | language server Python | ○ | 18 | `gradle-daemon` | daemon build Gradle, `detached_by_design` | ○ |
| 9 | `claude-code-session` | một phiên Claude Code | ✔ | 19 | `ios-simulator` | CoreSimulator | ○ |
| 10 | `watchman` | theo dõi file, unix socket | ✔ | 20 | `android-emulator` | emulator Android (qemu) | ○ |
| 21 | `tmux-server` | máy chủ tmux, `detached_by_design` | ○ | 22 | `screen` | GNU screen, `detached_by_design` | ✔ (qa) |

Pylance chưa có ✔ vì lúc đo nó không chạy (số đo "2 GB + 1,3 GB" là từ lần máy nặng trước).

## 8. Hành động dừng — luật an toàn cứng

Dừng **luôn do hog làm** — nút "Dừng" trong app hoặc `hog stop`. Claude không `kill`/`docker stop` trực tiếp. Các cổng dưới đây
nằm trong `HogCore`, **không có cờ hay nút nào tắt được** (`--yes` chỉ thay câu hỏi xác nhận, không thay cổng).

**Job launchd sẽ bật lại** (`launchd.restarts_after_stop` = true, hoặc `null` — chỉ xảy ra với job mà `launchctl print` lỗi hoặc có semaphore chưa phân loại, xem mục 3.1; tiến trình thường và app GUI là `false`): kế hoạch dừng không gửi tín hiệu mà chỉ hướng dẫn —
dừng thứ sẽ tự bật lại là vô ích, còn gỡ job là thay đổi cấu hình máy, chưa làm ở giai đoạn 1.

**Tắt ≠ xoá.** Không có đường nào thực hiện `rm`, `docker rm`, `volume prune`, `orbctl reset` hay thao tác mất dữ liệu nào.

| Cổng | Điều nó đảm bảo | Khi không đạt |
| --- | --- | --- |
| **G1 — không tự hại** | Đích không là hog, không là tổ tiên của hog (shell, phiên Claude đang gọi hog, cửa sổ chứa nó). | `block` (exit 4) |
| **G2 — thuộc phiên khác thì hỏi** | Đích hoặc tổ tiên thuộc một phiên Claude/cửa sổ/terminal không phải của người gọi, hoặc `owner.busy` ≠ false, hoặc hoạt động trong 10 phút qua → người xác nhận **có thấy tên chủ sở hữu**. | phải xác nhận; CLI không TTY → exit 3 |
| **G3 — danh tính tiến trình** | Danh tính = `(pid, giờ khởi chạy)`. Ngay trước khi gửi tín hiệu, đọc lại và so với cái người xem đã thấy. Lệch → **huỷ**. | `block` (exit 4) |
| **G4 — dừng nhẹ, không tự SIGKILL** | SIGTERM, chờ tối đa 10 s. Còn sống thì **hỏi lại** trước khi SIGKILL (khác `lps` v0.1.0 tự SIGKILL sau 1 s). | xác nhận lần hai |
| **G5 — container có restart policy** | `always`/`unless-stopped`/`on-failure`: đặt `no` **trước**, đọc lại để **xác nhận** là `no`, rồi mới `stop`. Thất bại ở bước nào → **không stop**. Ghi chính sách cũ để khôi phục. | `block` (exit 4) |
| **G6 — chỉ thứ của mình** | Không dừng tiến trình của user khác/hệ thống; không bao giờ `sudo`. | `block` (exit 4) |
| **G7 — bằng chứng** | Luôn hiện **kế hoạch** trước: đích, chủ sở hữu, số đo, quy tắc đã kích hoạt, `stop_effect`, việc sẽ làm. Chỉ nhãn "không dùng" khi có bằng chứng đo; dừng thứ chưa có đề xuất vẫn được nhưng hiện dòng "chưa có số đo cho: …". | hiện kế hoạch rồi hỏi |
| **G8 — nhật ký** | Mỗi lần dừng ghi một dòng JSON vào `~/.local/state/hog/actions.jsonl` (thời điểm, danh tính, kế hoạch, số đo, kết quả cổng, chính sách restart cũ). | không ghi được thì không dừng |

Luồng:

```text
App: bấm "Dừng…" ─┐                 CLI: hog stop <pid | cổng | item-id | container>
                  └─► HogCore: phân giải đích → dựng kế hoạch (chưa làm gì)
                        → G1, G6 (chặn?) → G2, G3, G7 (cần xác nhận?) → hiện kế hoạch
                          ├─ App: hộp thoại xác nhận (G2 ghi rõ tên chủ sở hữu)
                          ├─ CLI có TTY: hỏi [y/N]
                          └─ CLI không TTY (Claude gọi qua Bash): exit 3 + kế hoạch + plan_id
                               → user đồng ý trong chat → `hog stop --yes --plan <plan_id>`
                                 chỉ chạy nếu trạng thái hiện tại vẫn khớp kế hoạch (G3)
                        → thực thi → G4/G5 → đọc lại để xác nhận kết quả → G8
```

`plan_id` = băm của **(danh tính đích, hành động)** — không gồm số đo, vì tuổi, CPU, RAM đổi từng giây. Kế hoạch đầy đủ (kèm số đo
lúc hiển thị) được **lưu** ở `~/.local/state/hog/plans/<plan_id>.json`, **hết hạn sau 10 phút**. `--yes --plan` chỉ chạy khi kế hoạch
còn hạn, danh tính vẫn khớp (G3) và các cổng chạy lại vẫn cho qua; nhờ vậy sự đồng ý gắn với **đúng thứ người đã thấy**.

**Leo thang SIGKILL (G4) luôn là một kế hoạch mới**: SIGTERM không đủ → hog dừng lại, trả `exit 3` với `plan_id` **mới** cho hành động
SIGKILL. `--yes` của kế hoạch SIGTERM **không bao giờ** bao luôn SIGKILL — người phải đồng ý lần nữa, đúng câu chốt 3.
Mã thoát CLI: `0` xong · `1` lỗi · `2` dùng sai · `3` cần người xác nhận · `4` bị cổng an toàn chặn.

## 9. Giao diện

### 9.1 CLI `hog`

| Lệnh | Việc |
| --- | --- |
| `hog` / `hog status` | câu trả lời một dòng · dòng tổng quan (áp lực, RAM, nén, swap, CPU) · các owner nặng nhất · các đề xuất. Màu tắt khi không phải TTY hoặc có `NO_COLOR`. |
| `hog --json` | snapshot đầy đủ (mục 4). `--fast` bỏ `code --status`, watchman và mẫu CPU thứ hai (mục 3.1); `--full` không lọc tiến trình. |
| `hog explain <đích \| thuật ngữ>` | một item: mọi fact, quy tắc nào kích hoạt và vì sao, mục danh mục, cổng nào sẽ chặn. Một thuật ngữ: mục giải nghĩa (mục 5.2). |
| `hog ports` · `hog orphans` | giữ tính năng của `lps` v0.1.0: cổng LISTEN gom theo dự án, đánh dấu `[orphan]`. |
| `hog stop <đích>` | mục 8. Thay `lps kill` (không giữ `kill` làm bí danh vì nó mặc định SIGKILL sau 1 s). |
| `hog catalog list\|show\|check` · `hog rules check` | xem, kiểm tra dữ liệu (kể cả bản cục bộ). |
| `hog version` · `hog help` | — |

### 9.2 App thanh menu `HogBar` (giai đoạn 1: tối thiểu)

```text
 [icon heo — màu theo áp lực: thường / vàng / đỏ]
 ┌────────────────────────────────────────────────────────────┐
 │ Máy chưa thiếu RAM, nhưng có 1 thứ có thể tắt: watchman…   │  ← câu trả lời một dòng
 │ Áp lực ●bình thường ?  Nén 10,4→5,3 GB ?  Ổ đĩa 3,1 GB ?  │  ← mỗi số có "?" → giải nghĩa
 │ ─ Đang ăn nhiều nhất ───────────────────────────────────── │
 │ ▸ Visual Studio Code            5,2 GB                     │  ← mở ra: từng cửa sổ, language server, phiên Claude
 │ ▸ Google Chrome                 1,9 GB                     │
 │ ▸ macOS và dịch vụ hệ thống · 200 chưa đo  [Đo chi tiết]   │
 │ ─ Đề xuất ──────────────────────────────────────────────── │
 │ ● watchman · 1,3 GB · 11 ngày không ai dùng [Vì sao?] [Dừng…] │
 │ ◐ 5 phiên Claude rảnh > 2 giờ · 1,0 GB   [Vì sao?] [Cách đóng] │
 │ ─────────────────────────────────────────────────────────── │
 │ Cập nhật 10:31 · hog đang dùng 31 MB     [Làm mới] [Thoát] │
 └────────────────────────────────────────────────────────────┘
```

- **Lấy mẫu:** khi menu đóng, mỗi 10 s chỉ đọc mức áp lực (một `sysctl`) để đổi màu icon. Mở menu → hiện ngay bản quét gần
  nhất, đồng thời quét đầy đủ (~3 s, mục 3.1) rồi cập nhật. Không quét nền nặng.
- **Tự đo mình:** dòng cuối luôn hiện RAM của chính hog. Mục tiêu ≤ 50 MB (chưa đo — đo ngay khi có bản chạy đầu tiên).
- **"Dừng…"** mở hộp thoại kế hoạch của mục 8 (đích, chủ sở hữu, bằng chứng, tắt thì mất gì) → xác nhận. Thứ có `manual` thì nút là
  "Cách đóng" (chỉ hướng dẫn).
- **"Vì sao?"** mở lời giải thích của finding (mục 5.3).
- Mở cùng máy (`SMAppService`): tuỳ chọn, mặc định tắt.
- Chưa có ở giai đoạn 1: "Hỏi Claude", "Lưu vào danh mục", thông báo, biểu đồ theo thời gian.

## 10. Kiểm thử và cách xác nhận "xong"

1. **Cảm biến native** — test bằng tiến trình do test tự sinh: đọc đúng cha–con, giờ khởi chạy, cwd; footprint tăng sau khi tiến
   trình con cấp phát bộ nhớ; tiến trình root trả `null` chứ không làm hỏng lần quét.
2. **Parser văn bản** (`lsof`, `code --status`, `watchman`, `vm_stat`, `sessions/*.json`) — fixture đầu ra thật **đã làm sạch** (script
   thay tên/đường dẫn thật bằng tên giả) trong `testdata/`, gồm các ca xấu đã gặp (cột `Mem MB` rác).
3. **Engine quy tắc** — từng toán tử, ngữ nghĩa ba giá trị, mức bảo vệ, file hỏng bị bỏ qua mà không dừng chương trình.
4. **Giải nghĩa** — mọi số mà CLI/app hiển thị đều có mục trong bảng thuật ngữ (test liệt kê); câu một dòng cho từng mức áp lực
   khớp golden; không câu nào chứa thuật ngữ thiếu giải nghĩa.
5. **Cổng an toàn** — chỉ nhắm vào tiến trình do test sinh, **không bao giờ nhắm vào tiến trình có sẵn của máy**: G1 (dựng chuỗi
   cha–con), G3 (đổi tiến trình giữa lúc hiện và lúc gửi → huỷ), G4, G6.
6. **Docker** — máy chủ HTTP giả trên unix socket: đặt `no` → đọc lại → stop; `update` lỗi thì không stop; không có socket →
   `unavailable`.
7. **Hành vi mới từ hai vòng review** — ánh xạ đầu ra `launchctl print` → `launchd.restarts_after_stop` (`keepalive`,
   `after crash => 1/0`, `successful exit => 0`, không gì, lỗi ở cả hai domain); chuỗi tổ tiên đứt ở tiến trình không đọc được → G1 chặn; kế hoạch dừng tụt về hướng dẫn khi job sẽ bị bật lại (mục 8); `catalog.detached` chặn
   `orphan-quiet`; `procStart` đọc như UTC — test này **chạy với `TZ` khác UTC** (runner CI thường là UTC, sẽ không bắt được lỗi
   đọc nhầm giờ địa phương); đường dẫn `KERN_PROCARGS2` tương đối → `null`.
8. **Hợp đồng JSON** — golden file; kiểm số nguyên byte, thời gian UTC, không có đường dẫn home tuyệt đối, không có biến môi trường.
9. **`hog ports`** — PID, cổng, lệnh, dự án khớp `lps` v0.1.0: đã so trực tiếp trên máy thật (15/15 dòng, 2026-10-26) trước khi xoá
   `legacy/`; nay unit test giữ các luật đặt tên dự án của `lps` (`PortsReportTests`). Cột CWD (`~`) và `[orphan]` (mục 3.4) cố ý khác.
10. **Trên máy thật** (bạn chạy, chụp màn hình gửi lại): CLI < 4 s; app mở menu < 0,5 s với bản quét gần nhất; app ≤ 50 MB; nhận
   ra cửa sổ VS Code sở hữu tsserver; `idle_s` cho từng phiên Claude; watchman không ai đăng ký được đề xuất; docker `unavailable` khi engine
   tắt; cột "Activity Monitor" của bảng thuật ngữ được đối chiếu bằng mắt.

**Xong giai đoạn 1** khi 1–9 xanh trong CI, 10 đạt, bạn duyệt, và đã có skill trong hub (mục 11).

## 11. Cấu trúc repo, cài đặt, skill trong hub

```text
Package.swift                       Swift package, không phụ thuộc ngoài
Sources/HogCore/                    Sensors/ · Model/ · Data/ (catalog, rules, glossary) · Stop/ · Analyzer · Ownership · Reports · MenuSummary
Sources/HogCore/Resources/          catalog/ · rules/ · explain/ (glossary/, headline.json) — đóng gói cùng HogCore
Sources/hog/                        CLI (tự phân tích tham số)
Sources/HogBar/                     app thanh menu (SwiftUI MenuBarExtra), Theme theo design system
Tests/HogCoreTests/                 Swift Testing; Fixtures/ = đầu ra định dạng thật, dữ liệu giả; golden/
Tests/hogTests/                     phân tích tham số của CLI
scripts/                            build-app.sh (dist/Hog.app, LSUIElement, ký ad-hoc) · install.sh
docs/architecture/design-vi.md      tài liệu này · docs/design/ giao diện
```

- Swift 6 (máy có Swift 6.4), macOS 14 trở lên (`MenuBarExtra` cần 13), arm64. **Không phụ thuộc thư viện ngoài.**
- Build bằng SwiftPM, không có project Xcode để duy trì; `scripts/build-app.sh` tự đóng gói `.app`.
- **Cài đặt giai đoạn 1: build từ nguồn** — `scripts/install.sh` đặt CLI vào `~/.local/bin/hog` và app `Hog.app` vào thư mục Applications của người dùng.
  Build tại máy nên không bị Gatekeeper chặn như app tải về chưa notarize. Phát hành qua Release/tap để sau, khi đã ổn định.
- Tap: khi hog có bản đầu, **gỡ `Formula/lps.rb`** (kèm đoạn formula tự xoá bản `lps` không-brew ở thư mục người dùng — hành vi xoá
  file ngoài quyền của một formula). Nếu sau này phát hành qua tap: dùng file đính kèm Release + `SHA256SUMS`, **không** dùng tarball
  mã nguồn của tag — sha256 của tarball đã đổi hai lần ngày 2026-10-15 (dời tag, đổi tên repo).
- Mã bash `lps`/`install.sh` cũ: giữ ở `legacy/` tới khi `hog ports` khớp (mục 10.9), rồi xoá. README, `CLAUDE.md` của repo và ví dụ
  output (đang chứa tên dự án thật) viết lại cùng giai đoạn 1.
- **Skill trong hub** (`.claude/skills/`, sửa thẳng trên `main` của hub): khi user hỏi "máy nặng vì gì", Claude chạy `hog --json`, đọc
  `headline` + `findings`, trả lời theo thứ tự câu kết luận → ai đang ăn → đề xuất kèm bằng chứng → thứ **đừng đụng** và vì sao, dùng
  đúng lời giải nghĩa trong bảng thuật ngữ. Skill không dừng gì; muốn dừng thì đưa kế hoạch `hog stop` cho user, và chỉ chạy
  `--yes --plan` khi user đồng ý rõ. Giải thích tốt và user đồng ý thì thêm mục vào `Sources/HogCore/Resources/catalog/` qua một task của
  hub (giai đoạn 2, [thiết kế giai đoạn 2](phase-2-vi.md) mục 4); `~/.config/hog/catalog.d/` chỉ để thử nhanh.

## 12. Giai đoạn và điều cần chốt

**Giai đoạn** (dùng thật rồi mới làm tiếp):

1. **Lõi + CLI + app thanh menu tối thiểu + giải nghĩa + skill trong hub** — tài liệu này.
2. ~~Claude trong app: nút "Hỏi Claude" và "Lưu vào danh mục"~~ — đổi ngày 2026-10-26: hog không gọi Claude; người dùng chép thông tin
   đã làm sạch, hỏi Claude ở hub, danh mục khôn dần trong repo; giao diện phong phú hơn. Xem [thiết kế giai đoạn 2](phase-2-vi.md).
3. **Lịch sử**: app đã thường trú nên ghi mẫu RAM theo thời gian (`~/.local/state/hog/`), bắt thứ phình dần, thông báo trước khi máy nặng;
   khi đó "im lâu" đo được thật thay vì thế thay.

**Đã chốt ngày 2026-10-26** (user trả lời từng câu):

| # | Câu hỏi | Chốt |
| --- | --- | --- |
| 1 | Danh mục / quy tắc / giải nghĩa dạng JSON, một file mỗi mục, ghi đè ở `~/.config/hog/`, cấm nhúng lệnh | Đồng ý |
| 2 | Đọc `~/.claude/sessions/<pid>.json` | Có, đọc dung sai |
| 3 | Không bao giờ tự SIGKILL | Đồng ý — G4 |
| 4 | Claude chỉ dừng qua `--yes --plan <plan_id>` sau khi user đồng ý trong chat | Đồng ý |
| 5 | Ngưỡng: phiên Claude rảnh ≥ 2 giờ · `resident_ratio` < 0,1 | Đồng ý, chỉnh sau theo thực tế |
| 6 | Nền tảng | macOS 14+, Apple Silicon |
| 7 | Ngôn ngữ giao diện, câu kết luận, giải nghĩa | **Việt + Anh** (mục 5), theo ngôn ngữ máy, đổi được |
| 8 | Cài đặt giai đoạn 1 | Build từ nguồn; gỡ `lps.rb` khỏi tap khi hog có bản đầu |
| 9 | Tiến trình hệ thống không đọc được | **Gộp một dòng + nút "Đo chi tiết" chạy `top` một lần** (mục 3.5). Dòng gộp không ghi số ước tính: phép trừ ra số âm — reviewer phát hiện ở mốc chốt 2026-10-26 |
| 10 | App lấy mẫu | Icon mỗi 10 s chỉ đọc mức áp lực; quét đầy khi mở menu |

## 13. Chỗ triển khai khác thiết kế

Ghi khi code giai đoạn 1 (task `hog/phase-1`), theo lời user *"sau khi triển khai xong thì có gì update sau"*.

| Ngày | Chỗ | Thực tế | Vì sao |
| --- | --- | --- | --- |
| 2026-10-26 | Danh mục, mục 7 | Thêm điều kiện khớp `vscode_role`; `container_image: ""` = mọi container | File watcher, pty host, shared process của VS Code có tham số giống hệt nhau (đo trên máy); `"x".contains("")` của Swift là false |
| 2026-10-26 | Fact, mục 6 | Thêm `catalog.id`, `exe.macos` | Quy tắc watchman cần nhận ra mục danh mục; tách "chính macOS" khỏi "công cụ hệ thống user tự chạy" |
| 2026-10-26 | `protect-foreign`, mục 6.2 | Không chặn cứng mọi thứ dưới `/usr/bin`, `/bin` | Chạy thật: chặn luôn `/bin/sleep` do user chạy, tức chặn đúng loại mồ côi cần bắt |
| 2026-10-26 | Cảm biến launchd, mục 3.1 | `launchctl print` chỉ gọi cho ứng viên `may-stop`/`ask`, song song | Gọi cho mọi job lớn tốn 0,3 s (mỗi lần là một tiến trình); không ảnh hưởng kết luận vì fact này chỉ quyết định cách dừng |
| 2026-10-26 | Thời gian, mục 3.1 | Đo bản release trên máy: `hog` ~3 s, `--fast` 0,28–0,30 s | Đạt mục tiêu 4 s và 0,5 s |
| 2026-10-26 | Dữ liệu đi kèm | 22 mục danh mục, 14 quy tắc, 26 mục thuật ngữ | Bảng ở mục 5.2, 6.2, 7 |
| 2026-10-26 | `hog ports`, mục 10 | So với `lps` v0.1.0 trên máy thật: khớp 15/15 dòng (PID, cổng, lệnh, dự án); sau đó xoá `legacy/` (đúng kế hoạch mục 11), test đối chiếu trực tiếp thay bằng unit test các luật đặt tên dự án của `lps` | Bản bash không còn dùng; giữ lại chỉ để chạy test là thứ thừa |
| 2026-10-26 | Câu kết luận, mục 5.1 | Mẫu "có đề xuất" chỉ đếm ("Có N thứ có thể tắt."), không liệt kê | App đã hiện đề xuất thành thẻ ngay dưới; liệt kê làm câu dài gấp đôi (đúng bản mẫu đã duyệt) |
| 2026-10-26 | Snapshot, mục 4 | Thêm `memory.measured_footprint_bytes` | Nền của thanh RAM trong app; là tổng footprint (có thể vượt RAM), không bao giờ đem trừ |
| 2026-10-26 | Cổng dừng, mục 8 (reviewer chốt) | Đích không phải item (tiến trình nhỏ) vẫn được dựng fact + bảo vệ (`Analyzer.item(forPid:)`); không dựng được → G6 chặn | Trước đó tiến trình nhỏ của macOS (vd `cfprefsd`) chỉ cần xác nhận là dừng được |
| 2026-10-26 | Fact, mục 6 | Thêm `launchd.job` (`null` khi cảm biến launchd hỏng) và `self.window` (cùng cửa sổ VS Code với hog) | `exists` biến thiếu số đo thành "không" — trái 6.1; G1 phải gồm "cửa sổ chứa nó" |
| 2026-10-26 | G5 | Không đọc được restart policy → chặn | Dừng mà không hạ policy thì Docker bật lại ngay |
| 2026-10-26 | Snapshot, mục 4 | `--json` gọn mặc định (`--pretty` để đọc); không `--full` thì giữ item có đề xuất + 20 item lớn nhất, process của item có đề xuất + 15 lớn nhất, owner ≥ 50 MB hoặc được tham chiếu | Đo trên máy: 219 KB → 58 KB (mục tiêu ≤ 100 KB) |
| 2026-10-26 | Riêng tư, mục 4 | Che thêm mật khẩu trong URL, `Authorization`/`Bearer`, `-p`/`-a` của client CSDL, tham số query bí mật; thay home chỉ ở ranh giới thư mục | reviewer tìm ra các chuỗi lọt qua cách che theo tên cờ |
| 2026-10-26 | Câu kết luận, mục 5.1 | Thêm mẫu "nghiêm trọng, chưa có gì chắc chắn tắt được" | Trước đó ra câu có danh sách rỗng |
| 2026-10-26 | Lệnh ngoài, mục 3.1/3.2 (qa chốt) | Lệnh chạy trong nhóm tiến trình riêng, hết giờ tắt cả nhóm; `code --status` hết giờ → dọn đúng tiến trình `Code --status` + file `code-stdout-*` hog vừa gây ra, rồi **ngừng gọi tới khi VS Code khởi động lại** (`~/.local/state/hog/vscode-status-timeout`); không có `code --status` thì nhận cửa sổ qua extension host (`--inspect-port=0`), tên theo dự án phổ biến nhất | `code` nhờ LaunchServices (`open -n`) mở `Code --status` không phải con của hog; khi VS Code không trả lời, mỗi lần quét để lại 2 tiến trình mồ côi (qa dọn ~25 cặp) |
| 2026-10-26 | Snapshot, mục 4 | Thêm `--brief` (~21–25 KB: không `processes`, chỉ item có đề xuất, chủ sở hữu lớn; mọi đề xuất `may-stop`/`ask`, tối đa 5 `watch` + 3 `info`) cho Claude | `--json` 58 KB vẫn vượt giới hạn đầu ra của công cụ Bash; qa lần 2: ~19 đề xuất đã chạm 30 000 ký tự |
| 2026-10-26 | Sở hữu, mục 3.4 | Tiến trình mồ côi có `owner.kind = none` dù file thực thi nằm trong `.app` | `python3 -m http.server` (Python.app) bị hạ từ `may-stop` xuống `ask` |
| 2026-10-26 | Fact | `catalog.id`/`catalog.family` = `""` khi không khớp danh mục (không phải `null`) | Khớp danh mục là phép tất định; `null` làm G7 báo "chưa đo" sai |
| 2026-10-26 | App | `Info.plist` có lời giải thích cho quyền Desktop/Documents/Downloads; app quét một lần lúc khởi động | macOS hỏi quyền khi đọc `package.json` trong Desktop; lần mở menu đầu chưa có số |
| 2026-10-26 | `~/.config/hog/config.json` | Đã nạp `commands` (mục 3.1b) | Trước đó chỉ có trong chú thích |
| 2026-10-26 | Giải nghĩa (qa lần 2) | Mọi fact đo được có mục thuật ngữ (`MenuSummary.factGlossary`, test bắt buộc); `hog explain <item>` in `? hog explain <thuật ngữ>` cạnh từng số; fact cấu trúc (tên, đường dẫn) không cần | Trang "Vì sao?" và `hog explain` in số chưa có giải nghĩa (`age_s`, `net.*`, `watchman.subscriptions`…) |
| 2026-10-26 | Lệnh ngoài, mục 3.2 (qa lần 2) | Mỗi luồng đầu ra tối đa 16 MB; vượt thì tắt cả nhóm, mã thoát khác 0. Đầu ra đọc dần vào bộ đệm, nên tiến trình cháu tách nhóm mà giữ pipe không làm mất phần đã đọc | `yes` làm hog đọc 5,9 GB vào RAM |
| 2026-10-26 | Riêng tư, mục 4 (qa lần 2) | Che thêm cờ chứa `passwd`, `pwd`, `pass`, `credential`, `bearer`, `cookie`. Cờ ngắn `-k` **không** che | `-k` của `curl` là cờ không có giá trị; che thì mất tham số kế tiếp. Che thừa (vd `--passthrough x`) chấp nhận được, vì lệch về phía an toàn |
| 2026-10-26 | Sở hữu, mục 3.4 (qa lần 3) | File thực thi chính của app đã cài (`/Applications/X.app/Contents/MacOS/X`, cả trong thư mục Applications của user) không bao giờ là mồ côi; `Python.app` nằm trong framework hoặc trong app khác vẫn có thể | App GUI chạy từ terminal rồi đóng terminal có ppid 1 — trước đó mất chủ sở hữu |
| 2026-10-26 | Lệnh ngoài, mục 3.2 (qa lần 3) | Luồng đọc dùng `poll` và dừng theo lệnh; fd chỉ đóng sau khi luồng đọc đã dừng | Đóng fd khi luồng đọc còn chặn trong `read` thì số fd bị dùng lại có thể làm nó đọc nhầm pipe của lệnh sau |
| 2026-10-26 | Riêng tư, mục 4 (qa lần 3) | Che giá trị header `Cookie:`/`Set-Cookie:` như `Authorization:` | `curl -H "Cookie: sid=…"` lọt |
