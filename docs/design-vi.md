# hog — thiết kế giai đoạn 1

> Trạng thái: **bản nháp chờ duyệt** (2026-10-15). Chưa có dòng code nào theo tài liệu này.
> Ngôn ngữ: tiếng Việt, vì người duyệt là chủ dự án; README và code của repo vẫn là tiếng Anh.
> Mọi số đo trong tài liệu là **đo trên một máy macOS 16 GB ngày 2026-10-15**; chỗ chưa kiểm được ghi rõ là chưa kiểm.

## 1. Bài toán và phạm vi

Máy dev 16 GB bị chậm, mà thứ chiếm RAM thật thường **không mở cổng TCP nào** nên `lps` v0.1.0 (chỉ liệt kê
cổng LISTEN) không thấy: language server của VS Code, `watchman` mồ côi, các phiên Claude bị bỏ quên, container
chết đi sống lại sau OrbStack. Muốn biết phải gõ tay hơn chục lệnh `ps`/`top`/`lsof` và đọc log.

`hog` trả lời ba câu hỏi, theo thứ tự:

1. **Máy đang hao vì cái gì?** — RAM (kể cả phần nén và swap), CPU, áp lực bộ nhớ.
2. **Ai/cái gì sở hữu nó?** — app, cửa sổ VS Code, dự án, phiên Claude.
3. **Có nên dừng không, và dừng thì mất gì?** — hog **đề xuất kèm bằng chứng**, người quyết định.

Ngoài phạm vi giai đoạn 1: giao diện đồ hoạ (giai đoạn 2), lịch sử RAM theo thời gian (giai đoạn 3), Linux/Windows,
tự động dừng không có người xác nhận, bất kỳ lời gọi mạng nào của chính hog.

## 2. Kiến trúc ba tầng

```text
 Tầng 1  Cảm biến (tất định)      máy  ──►  snapshot JSON  ──►  bảng cho người đọc
 Tầng 2  Quy tắc + danh mục       snapshot + dữ liệu (catalog/, rules/)  ──►  findings (kết luận có bằng chứng)
 Tầng 3  Claude (ngoài hog)       đọc `hog --json`, giải thích thứ lạ, ghi giải thích tốt vào danh mục
 Hành động dừng: luôn do hog làm, qua cổng an toàn (mục 7)
```

Nguyên tắc xuyên suốt:

- **Đo, không suy.** Mỗi kết luận dẫn về các con số đo được; thứ chưa đo được mang giá trị `null`, không bao giờ
  được coi là "không có".
- **Khôn dần bằng dữ liệu.** Gặp thứ lạ thì thêm một file vào danh mục hoặc một quy tắc — không thêm `case` vào code.
- **Chỉ đọc cho tới khi người xác nhận.** Cảm biến không được khởi động, đánh thức hay thay đổi bất cứ thứ gì
  (xem mục 3, bẫy "tự khởi động").
- **Claude không có đường tắt.** Claude đọc snapshot, đề xuất, còn việc dừng đi qua đúng các cổng an toàn như người.

## 3. Tầng 1 — Cảm biến

### 3.1 Nguồn dữ kiện: đã kiểm trên máy

Giai đoạn 1 **gọi công cụ hệ thống** (`ps`, `top`, `lsof`, `vm_stat`, `sysctl`, …) thay vì dùng API native: build
đơn giản, không cgo, và người dùng tái hiện được từng con số bằng tay. Mỗi cảm biến nằm sau một interface để
thay bằng bản native sau này mà không đụng tầng trên. Phần phân tích là **hàm thuần trên văn bản**, nên kiểm thử
bằng đầu ra đã ghi lại (mục 9).

| Dữ kiện | Nguồn | Thời gian đo | Điều đã kiểm / bẫy |
| --- | --- | --- | --- |
| RAM toàn máy, RAM nén, swap | `vm_stat`, `sysctl vm.swapusage`, `sysctl hw.memsize` | < 0,1 s | Kích thước trang 16384 B. "Pages occupied by compressor" × trang = 2879 MB, **khớp** dòng `compressor` của `top`. "Pages stored in compressor" (dữ liệu logic đã nén) là con số **khác**, lớn hơn ~2 lần (≈ 5,9 GiB so với 2,8 GiB) — hog xuất **cả hai**, đặt tên rõ ràng (mục 4). `vm.swapusage` có `total` thay đổi theo thời điểm. |
| Áp lực bộ nhớ | `sysctl -n kern.memorystatus_vm_pressure_level` | < 0,1 s | 1 = bình thường, 2 = cảnh báo, 4 = nghiêm trọng (theo tài liệu XNU; trên máy này mới thấy giá trị 1). Đây là chỉ báo chính thức; `memory_pressure` in "free 65%" trong khi `top` báo 136 MB trống — không dùng số phần trăm đó làm áp lực. |
| RAM thật của từng tiến trình | `top -l 2 -s 1 -stats pid,mem,cmprs,cpu` (**lấy mẫu thứ hai**) | 1,85 s | `mem` **gồm cả phần nén**: một tiến trình `ps` báo RSS 62 MB thì `top` báo `mem` 542 MB, trong đó `cmprs` 516 MB. **Chỉ dùng RSS thì bỏ sót đúng thứ cần bắt.** Tên lệnh bị `top` cắt ở 16 ký tự → ghép với `ps` theo PID. Mẫu thứ nhất có `%CPU` = 0,0 ở mọi dòng đã xem (không dùng được); mẫu thứ hai có số thật (4,6 / 12,5 / 3,9…). Giá trị có hậu tố đơn vị `K/M/G` **và** hậu tố `+`/`-` báo đang tăng/giảm (đã thấy: `733M-`, `542M+`, kể cả ở `cmprs`: `197M+`) — parser phải bỏ hậu tố này. |
| Danh sách tiến trình, cha–con, tuổi | `ps -axww -o pid=,ppid=,uid=,rss=,etime=,lstart=,command=` | 0,06 s | `lstart` luôn 5 từ (`Thu Oct  1 08:31:17 2026`); `etime` dạng `[[dd-]hh:]mm:ss`. `lstart` là phần **danh tính** của tiến trình (mục 7, G3). |
| Cổng LISTEN, số kết nối | `lsof -nP -iTCP -sTCP:LISTEN`, `lsof -nP -iTCP -sTCP:ESTABLISHED` | < 0,2 s | Cùng cách `lps` đang dùng. |
| cwd của tiến trình | `lsof -a -d cwd -nP -Fpn` (một lần cho mọi tiến trình) | 0,15 s | Một lần cho tất cả, không gọi từng PID như `lps` v0.1.0. |
| Cây tiến trình theo cửa sổ VS Code | `code --status` | 1,73 s | Cho `window [N] (tiêu đề)`, `extension-host [N]`, `file-watcher [N]` cùng số `N` và PID. **Cột `Mem MB` của lệnh này in số rác** (hàng chục tỷ MB) → **không dùng**. Cây tiến trình từ `ps` (ppid) đã đủ để quy một tiến trình về `extension-host [N]`; `code --status` chỉ cần để biết `N` ↔ tiêu đề cửa sổ ↔ PID. |
| Phiên Claude | `~/.claude/sessions/<pid>.json` | < 0,01 s | Có `pid`, `sessionId`, `cwd`, `startedAt`, `kind`, `entrypoint`, `status` (`idle`/`busy`), `statusUpdatedAt`, `updatedAt`. Đo hôm nay: 7 phiên `idle` từ 178 đến 331 phút, 1 phiên `busy` cách đây 3 phút (chính phiên đang chạy hog). Đây là **bằng chứng đo trực tiếp** về "bỏ quên". File này là định dạng nội bộ của Claude Code, **không có tài liệu cam kết** → đọc dung sai (mục 3.3). Không đọc `*.key` cùng thư mục. |
| Lần hoạt động cuối (dự phòng) | mtime của `~/.claude/projects/<thư-mục-cwd>/<sessionId>.jsonl` | < 0,01 s | Chỉ dùng khi thiếu `sessions/<pid>.json`. **Không giải mã tên thư mục** (`/` và `-` đều thành `-`, mơ hồ); lấy cwd từ khoá `cwd` trong file phiên. |
| watchman | `watchman --no-spawn --no-local watch-list`, `… debug-get-subscriptions <root>` | 0,19 s | Theo `watchman --help`, mặc định nó **thử khởi động service nếu chưa có** (`--no-spawn`: "Don't try to start the service if it is not available") → luôn truyền `--no-spawn --no-local` (đã chạy được với server đang sống; **chưa thử khi server tắt** vì không nên tắt server của máy để thử). `debug-get-subscriptions` trả `subscriptions: []` khi không ai đăng ký — bằng chứng "không ai dùng". Hôm nay: server mồ côi (ppid = 1) chạy 5 giờ, 4 root. |
| Docker / OrbStack | Docker Engine API qua unix socket (không gọi CLI `docker`) | chưa đo (engine đang tắt) | Khi OrbStack **đang chạy nhưng engine tắt**, `~/.orbstack/run/docker.sock` không tồn tại (đã kiểm). Cảm biến `stat` socket trước; không có → trạng thái `unavailable`, **không phải lỗi**, và tuyệt đối không thử "đánh thức" engine. Không dùng CLI `docker` vì shim có thể khởi động engine (chưa kiểm — nên tránh). Từ `/containers/json` và `/containers/<id>/json` lấy `State.Status`, `State.StartedAt`, `RestartCount`, `HostConfig.RestartPolicy`, các cổng đã publish; **chưa kiểm trên máy này** vì engine tắt. **`RestartCount` cộng dồn từ lúc tạo container**, nên "restart liên tục" phải xét cùng trạng thái hiện tại (`restarting`) hoặc thời gian chạy ngắn, không chỉ con số. **Docker API không cho số kết nối**: `container.connections` = số kết nối ESTABLISHED tới các **cổng đã publish** của container (lấy từ `lsof` phía máy chủ); kết nối giữa các container trong mạng nội bộ không thấy được. Container không publish cổng nào → `null` (chưa đo), **không phải 0**. |

Tổng thời gian nếu chạy các cảm biến song song: ≈ **2 s** (do `top` và `code --status`). Mục tiêu: `hog` < 3 s,
`hog --fast` (bỏ mẫu `top` thứ hai và `code --status`) < 1 s.

### 3.2 Bẫy "tự khởi động" — quy tắc cứng cho mọi cảm biến

Một lệnh chỉ-đọc mà vô tình **bật** một dịch vụ là lỗi nặng hơn không đo. Do đó:

- Trước khi nói chuyện với một dịch vụ: kiểm sự tồn tại (socket, tiến trình). Không có → `unavailable`.
- Cờ chống tự khởi động bắt buộc (`watchman --no-spawn --no-local`). Cảm biến nào chưa chứng minh được là không
  khởi động gì thì **không được thêm**.
- Gọi `code --status` chỉ khi `ps` thấy tiến trình chính của VS Code, và có timeout (5 s).
- Mọi lệnh con có timeout; hết giờ → cảm biến `error`, hog vẫn in phần còn lại.

### 3.3 Độ bền khi nguồn thay đổi

Cảm biến hỏng không được làm hog hỏng: mỗi cảm biến trả `status` ∈ {`ok`, `unavailable`, `skipped`, `error`} kèm
`took_ms` và `note`, nằm trong `sensors[]` của snapshot. Trường mà cảm biến không lấy được là `null`. Đọc JSON của
Claude Code (`sessions/<pid>.json`) bỏ qua khoá lạ, thiếu khoá → `null`, không panic; **định dạng đổi thì phần
"phiên Claude" tụt về `unavailable` kèm ghi chú**, còn bảng RAM vẫn chạy.

### 3.4 Quy chiếu "ai sở hữu"

Một tiến trình có thể có nhiều thuộc tính sở hữu cùng lúc: `app`, `window`, `project`, `session`. Thuật toán, theo
thứ tự:

1. Đi ngược chuỗi ppid tới `launchd` (PID 1), ghi mọi tổ tiên.
2. **Phiên Claude**: PID khớp một `sessions/<pid>.json` → `session = claude:<pid>`, `project` từ `cwd`.
3. **Cửa sổ VS Code**: tổ tiên là `extension-host [N]` (hoặc `window [N]`) theo `code --status` →
   `window = vscode:N`, nhãn là tiêu đề cửa sổ.
4. **App**: đường dẫn thực thi nằm trong `<tên>.app` → `app = <tên>`.
5. **Dự án**: từ cwd đi lên tìm `.git`, `package.json#name`, `go.mod`, … (cách `lps` v0.1.0 đã dùng), hoặc từ tiêu đề cửa sổ.
6. Ppid = 1 và cwd trong thư mục người dùng → `orphan: true` (định nghĩa của `lps` giữ nguyên: ppid = 1, cwd dưới
   thư mục người dùng, không trong `Library/Containers` hay `.Trash`).

Chỗ nào không quy được thì để `null`, không đoán. Mỗi owner cộng dồn RAM/CPU của cả cây con (`total_*`) và riêng nó
(`self_*`), để trả lời được "cửa sổ này tổng cộng ngốn bao nhiêu".

## 4. Định dạng snapshot JSON (`hog --json`)

Đây là **hợp đồng** giữa hog, Claude và hub. Quy ước:

- Trường `schema` = `hog.snapshot/1`. Trong cùng số major chỉ **thêm** trường; người đọc phải bỏ qua trường lạ.
  Đổi nghĩa hoặc xoá trường → tăng major.
- Dung lượng là số nguyên **byte** (hậu tố `_bytes`), phần trăm là số thực (`_pct`), thời gian RFC 3339 UTC
  (`_at`), khoảng thời gian là giây (`_s`). Thứ chưa đo được là `null`.
- **Riêng tư:** thư mục home thay bằng `~`; **không có biến môi trường**; `args` bị cắt 200 ký tự và che giá trị
  của cờ có tên chứa `token|key|secret|password|auth`. Snapshot **chỉ nằm trên máy**; hog không gửi nó đi đâu.
- Kích thước mục tiêu ≤ 100 KB: `processes` chỉ gồm tiến trình đáng kể (RAM ≥ 50 MB, CPU ≥ 5 %, đang nghe cổng,
  hoặc thuộc một item/tổ tiên của chúng); phần còn lại gộp vào `other`. `--full` để lấy hết.

Ví dụ rút gọn (dữ liệu giả):

```json
{
  "schema": "hog.snapshot/1",
  "taken_at": "2026-10-15T13:44:55Z",
  "hog": { "version": "0.2.0", "pid": 4242, "ancestors": [4100, 3990, 3801] },
  "host": { "os": "darwin", "arch": "arm64", "ncpu": 8, "mem_total_bytes": 17179869184, "uptime_s": 1255000 },
  "memory": {
    "free_bytes": 123731968,
    "compressor_bytes": 3019000000,
    "compressed_stored_bytes": 6320000000,
    "swap_used_bytes": 3651000000,
    "swap_total_bytes": 5368709120,
    "pressure": "normal"
  },
  "cpu": { "user_pct": 8.5, "sys_pct": 13.1, "idle_pct": 78.4, "load": [1.6, 2.2, 2.7] },
  "sensors": [
    { "name": "top", "status": "ok", "took_ms": 1850 },
    { "name": "docker", "status": "unavailable", "took_ms": 1, "note": "engine socket missing (engine stopped)" }
  ],
  "owners": [
    { "id": "app:vscode", "kind": "app", "label": "Visual Studio Code", "parent": null,
      "self_footprint_bytes": 1500000000, "total_footprint_bytes": 5200000000, "total_cpu_pct": 6.0 },
    { "id": "vscode:7", "kind": "vscode-window", "label": "web-app (Workspace)", "parent": "app:vscode",
      "project": "web-app", "total_footprint_bytes": 2100000000, "total_cpu_pct": 1.2 },
    { "id": "claude:72513", "kind": "claude-session", "label": "claude session", "parent": "vscode:7",
      "project": "web-app", "total_footprint_bytes": 178000000, "total_cpu_pct": 0.0 }
  ],
  "processes": [
    { "pid": 21145, "ppid": 67480, "own": true, "exe": "Code Helper (Plugin)",
      "started_at": "2026-10-15T08:42:00Z", "age_s": 18119,
      "footprint_bytes": 568000000, "compressed_bytes": 540000000, "rss_bytes": 65000000,
      "cpu": { "now_pct": 0.0, "avg_pct": 0.1 },
      "cwd": "~/work/web-app", "project": "web-app", "orphan": false,
      "net": { "listen": [], "established": 0 },
      "catalog_id": "tsserver", "owner_id": "vscode:7", "item_id": "proc:21145:1792052931" }
  ],
  "items": [
    { "id": "proc:21145:1792052931", "kind": "process", "label": "tsserver", "catalog_id": "tsserver",
      "pids": [21145, 21244], "owner_id": "vscode:7",
      "footprint_bytes": 568000000, "compressed_bytes": 540000000,
      "protection": { "level": "soft", "rules": ["protect-busy-owner"] },
      "facts": { "orphan": false, "age_s": 18119, "cpu.avg_pct": 0.1, "net.established": 0,
                 "owner.kind": "vscode-window", "owner.busy": null, "owner.idle_s": null,
                 "siblings.same_catalog_other_windows": 1 } }
  ],
  "findings": [
    { "item_id": "proc:21145:1792052931", "verdict": "info", "confidence": "low",
      "rules": ["duplicate-language-server"],
      "reason": "tsserver cũng đang chạy ở 1 cửa sổ VS Code khác.",
      "evidence": { "siblings.same_catalog_other_windows": 1 },
      "unmeasured": [],
      "stop": { "strategy": "manual", "respawns": "by-parent",
                "effect": "VS Code tự khởi động lại; muốn giảm RAM thì đóng cửa sổ không dùng." },
      "blocked_by": [] }
  ],
  "warnings": []
}
```

Ghi chú về tên trường:

- `compressor_bytes` = RAM vật lý mà bộ nén đang chiếm (khớp `top`); `compressed_stored_bytes` = lượng dữ liệu logic
  đã nén. Đặt tên khác nhau vì hai con số cùng được gọi là "RAM nén" trong đời thường và chúng khác nhau.
- `item_id` có dạng `proc:<pid>:<giờ khởi chạy epoch>`, `claude:<pid>`, `ctr:<id 12 ký tự>`. **Danh tính tiến trình
  gồm cả giờ khởi chạy** để PID bị tái sử dụng không bị nhầm (mục 7, G3).
- `facts` là **toàn bộ** thứ quy tắc được phép đọc (mục 5); mỗi fact là số đo hoặc `null`.

### Item và hành động

| `kind` | Là gì | Dừng được bằng hog? |
| --- | --- | --- |
| `process` | một tiến trình (kèm con trực tiếp cùng nhóm) | có — chiến lược `signal` hoặc chiến lược riêng của danh mục |
| `claude-session` | một tiến trình `claude` có `sessions/<pid>.json` | giai đoạn 1: chỉ `manual` (đóng tab trong VS Code); SIGTERM nhắm thẳng vào nó vẫn phải qua G2 |
| `container` | một container Docker/OrbStack | có — chiến lược `docker-container` (mục 7, G5) |
| cửa sổ / app (là *owner*, không phải item) | — | **không**: hog chỉ nói "đóng cửa sổ X trong VS Code" |

## 5. Tầng 2 — Quy tắc

Quy tắc là **dữ liệu** (`rules/<id>.json`), nạp lúc chạy. Ngôn ngữ cố ý nhỏ: không có biểu thức tự do, không có
lệnh, chỉ so sánh trường với hằng.

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
    { "fact": "cpu.avg_pct",      "lt": 1.0 }
  ] },
  "reason": "Tiến trình mồ côi (cha đã chết), không ai đang kết nối, gần như không dùng CPU suốt {age_s} giây."
}
```

- `when`: `all` / `any` / `not` lồng nhau; toán tử `eq, ne, gt, gte, lt, lte, in, exists`.
- `fact`: một khoá trong `items[].facts`. Danh sách fact giai đoạn 1: `orphan`, `age_s`, `cpu.now_pct`, `cpu.avg_pct`,
  `footprint_bytes`, `compressed_bytes`, `net.established`, `net.listen_count`, `owner.busy`,
  `owner.idle_s`, `owner.kind`, `catalog.family`, `siblings.same_catalog_other_windows`,
  `container.restart_count`, `container.restart_policy`, `container.state`, `container.uptime_s`, `container.connections`,
  `watchman.subscriptions`,
  `self.ancestor`, `own`. Thêm fact = thêm code cảm biến; thêm quy tắc = thêm file.
- `reason` là mẫu có `{fact}`; câu giải thích **phải dẫn ra con số đã đo**.

### 5.1 Ngữ nghĩa ba giá trị (đây là chỗ thực thi luật "đo, không suy")

Mỗi điều kiện cho `true`, `false` hoặc **`unknown`** (khi fact là `null`: chưa đo được). Có hai lớp quy tắc:

| Lớp | Tạo ra | Điều kiện `unknown` thì… | Vì sao |
| --- | --- | --- | --- |
| `advice` | một **finding** với verdict `may-stop`, `watch` hoặc `info` | **không kích hoạt**; fact thiếu được liệt kê trong `unmeasured` | thiếu số đo thì không được kết luận "không dùng" |
| `protect` | một **bảo vệ** gắn vào item (`item.protection`), không phải finding | **kích hoạt** (coi như có thể đang dùng) | không biết ai đang dùng thì phải bảo vệ |

Bảo vệ có hai mức, đặt bằng `level` của quy tắc `protect`:

- `hard` — hog **không dừng được** (cổng G1, G6). Mọi `may-stop` của item bị hạ thành `info` kèm lý do.
- `soft` — dừng được nhưng **phải có người xác nhận, thấy tên chủ sở hữu** (cổng G2). Verdict `may-stop` hiển thị là
  `ask`: "có dấu hiệu không dùng nhưng thuộc phiên/cửa sổ khác — hỏi chủ trước". Đây là nhãn "đừng đụng" cho thứ thuộc phiên đang chạy.

Thứ tự hiển thị của verdict: `may-stop` / `ask` > `watch` > `info`. **Mọi** quy tắc đã kích hoạt đều được liệt kê trong
`rules` của finding để giải thích được. `confidence` = số **phép đo độc lập** ủng hộ kết luận (1 → `low`, 2 → `medium`,
≥ 3 → `high`).

### 5.2 Bộ quy tắc khởi đầu

| Quy tắc | Lớp / verdict | Điều kiện (rút gọn) |
| --- | --- | --- |
| `protect-self` | protect, `hard` | item là hog, hoặc tổ tiên của hog (shell, phiên Claude đang gọi hog, cửa sổ chứa nó) |
| `protect-foreign` | protect, `hard` | không thuộc user hiện tại, hoặc đường dẫn thực thi dưới `/System`, `/usr`, hoặc là `launchd`/`WindowServer`/`kernel_task` |
| `protect-busy-owner` | protect, `soft` | có owner (`owner.kind` ≠ `none`) và (`owner.busy` là true **hoặc unknown**, hoặc `owner.idle_s` < 600). Tiến trình mồ côi không có owner thì `owner.busy` = false → không bị bảo vệ. Cửa sổ VS Code chưa có số đo bận/rảnh → `unknown` → các tiến trình con của nó được bảo vệ mức `soft` |
| `orphan-quiet` | advice, `may-stop` | mồ côi + 0 kết nối + tuổi ≥ 1 giờ + CPU trung bình < 1 % (ví dụ ở trên) |
| `claude-session-abandoned` | advice, `may-stop` | `claude-session`, `owner.busy` = false, `owner.idle_s` ≥ 7200, RAM ≥ 100 MB — chiến lược dừng: `manual` (đóng tab) |
| `container-crash-loop` | advice, `may-stop` | `container.restart_count` ≥ 10 **và** (`container.state` = `restarting` **hoặc** `container.uptime_s` < 600) **và** `container.connections` = 0 |
| `container-restart-high` | advice, `watch` | `container.restart_count` ≥ 10 — luôn hiện để người xem log, kể cả khi `container.connections` là `null` |
| `container-no-clients` | advice, `watch` | đang chạy, `container.connections` = 0 (chưa đủ để kết luận khi chưa có lịch sử — giai đoạn 3) |
| `watchman-no-subscribers` | advice, `may-stop` | catalog `watchman`, `watchman.subscriptions` = 0, mồ côi |
| `duplicate-language-server` | advice, `info` | `catalog.family` = `language-server` và `siblings.same_catalog_other_windows` ≥ 1 |
| `memory-heavy` | advice, `watch` | `footprint_bytes` ≥ 1 GiB |

Ngưỡng `7200 s` (2 giờ) của `claude-session-abandoned` là **đề xuất**: các phiên bị bỏ quên đo hôm nay `idle` 178–331
phút, phiên đang làm việc cách 3 phút. Cần user chốt (mục 11).

**Giới hạn đã biết của giai đoạn 1:** chưa có lịch sử nên "im lâu" chỉ đo được bằng thế thay: tuổi, CPU trung bình
cả đời, số kết nối **hiện tại**, `idle_s` của phiên Claude. Vì vậy `confidence` phản ánh đúng số phép đo, và
`container-no-clients` chỉ là `watch`. Kết luận "không dùng" mạnh hơn phải chờ giai đoạn 3.

### 5.3 Ghi đè cục bộ

`~/.config/hog/rules.d/*.json` được nạp sau bộ nhúng sẵn; **cùng `id` thì bản cục bộ thắng**. Đây là chỗ Claude thêm/chỉnh
quy tắc theo ca thực tế mà không cần phát hành bản mới.
Mọi file qua kiểm tra nghiêm ngặt (`hog rules check`): khoá lạ, toán tử lạ, `fact` không tồn tại, `class` sai →
**bỏ qua file đó** và ghi vào `warnings` kèm đường dẫn + lý do; không bao giờ làm hog dừng chạy.
Quy tắc cục bộ **không được hạ** hay tắt một bảo vệ `hard` đã có (`protect-self`, `protect-foreign`).

## 6. Tầng 2 — Danh mục

Một mục = một file `catalog/<id>.json`: hiểu "đây là cái gì, tắt thì sao" thành dữ liệu để người và Claude đọc.

```json
{
  "id": "watchman",
  "name": "Watchman",
  "family": "file-watcher",
  "summary": "Dịch vụ theo dõi thay đổi file của Meta, Metro/Jest dùng để biết file nào vừa sửa. Giao tiếp qua unix socket nên không có cổng TCP.",
  "stop_effect": "Tắt an toàn: server tự khởi động lại khi có công cụ cần tới. Lần chạy kế tiếp phải quét lại thư mục, chậm hơn một lần.",
  "respawns": "on-demand",
  "stop": { "strategy": "watchman-shutdown" },
  "match": [ { "exe": "watchman" } ],
  "provenance": { "added": "2026-10-15", "source": "measured", "verified": true }
}
```

- `match` là danh sách; **một** phần tử khớp là đủ (hoặc), trong một phần tử **mọi** điều kiện phải đúng (và). Điều kiện:
  `exe` (tên file thực thi), `exe_path_contains`, `args_contains`, `parent_catalog` (id danh mục của tiến trình cha),
  `listens_port`, `container_image`. Nhiều mục cùng khớp → mục có nhiều điều kiện hơn thắng.
- `respawns`: `never` · `by-parent` (cha khởi động lại ngay) · `on-demand` (khởi động khi có công cụ cần) ·
  `supervisor` (launchd/Docker restart policy). Giá trị này quyết định lời khuyên: dừng thứ `by-parent` là vô ích,
  nên hog gợi ý đóng cửa sổ thay vì dừng.
- `stop.strategy` **chỉ được chọn trong tập có sẵn trong code**: `signal` (SIGTERM), `watchman-shutdown`,
  `docker-container`, `manual` (chỉ in hướng dẫn, không làm gì). **Danh mục không được chứa lệnh tuỳ ý** — một
  file danh mục do Claude hay người viết không bao giờ biến thành thứ thực thi được.
- `provenance`: `source` ∈ {`measured` (đã thấy trên máy), `user`, `claude`, `docs`}; `verified: false` thì hog in thêm
  `⚠ chưa kiểm` cạnh mô tả. Danh mục **không được giả vờ chắc chắn**.

Ghi đè cục bộ: `~/.config/hog/catalog.d/*.json`, cùng `id` thì bản cục bộ thắng; qua `hog catalog check`; file hỏng bị bỏ qua và
báo trong `warnings`. Mục ổn định thì đưa lên repo (`catalog/`) để cả bản phát hành có.

### Danh mục khởi đầu (20 mục)

✔ = đã thấy tiến trình này trên máy ngày 2026-10-15. ○ = từ kiến thức chung, **chưa thấy trên máy** → `verified: false`
cho tới khi gặp thật. Cách nhận diện chính xác sẽ chốt khi viết code, bằng đầu ra đã ghi lại.

| # | id | Là gì | | # | id | Là gì |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `vscode-renderer` | tiến trình vẽ một cửa sổ VS Code | ✔ | 11 | `orbstack-app` | ứng dụng OrbStack (engine có thể tắt riêng) | ✔ |
| 2 | `vscode-extension-host` | nơi chạy mọi extension của một cửa sổ | ✔ | 12 | `docker-container` | container Docker/OrbStack (mục chung) | ○ |
| 3 | `vscode-file-watcher` | theo dõi file của một cửa sổ | ✔ | 13 | `metro` | bundler React Native | ○ |
| 4 | `vscode-gpu` | tiến trình GPU dùng chung | ✔ | 14 | `next-dev` | `next dev` | ○ |
| 5 | `vscode-pty-host` | giữ các terminal tích hợp | ✔ | 15 | `vite-dev` | dev server Vite | ○ |
| 6 | `tsserver` | language server TypeScript | ✔ | 16 | `adb-server` | cầu nối Android Debug Bridge | ○ |
| 7 | `typings-installer` | tải type định nghĩa cho tsserver | ✔ | 17 | `spotlight-mdworker` | lập chỉ mục Spotlight | ✔ |
| 8 | `pylance` | language server Python | ○ | 18 | `gradle-daemon` | daemon build Gradle | ○ |
| 9 | `claude-code-session` | một phiên Claude Code (VS Code hoặc terminal) | ✔ | 19 | `ios-simulator` | CoreSimulator | ○ |
| 10 | `watchman` | theo dõi file, unix socket | ✔ | 20 | `android-emulator` | emulator Android (qemu) | ○ |

Pylance chưa có mục ✔ vì lúc đo nó không chạy (số đo "2 GB + 1,3 GB" của chủ dự án là từ lần máy nặng trước).

## 7. Hành động dừng — luật an toàn cứng

Dừng **luôn do hog làm**, qua `hog stop <đích>`. Claude không `kill`/`docker stop` trực tiếp. Các cổng dưới đây
nằm trong code, **không có cờ nào tắt được chúng** (`--yes` chỉ thay cho câu hỏi xác nhận, không thay cho cổng).

**Tắt ≠ xoá.** Không có đường nào trong hog thực hiện `rm`, `docker rm`, `volume prune`, `orbctl reset` hay bất kỳ
thao tác mất dữ liệu nào. Dừng chỉ là dừng.

| Cổng | Điều nó đảm bảo | Kết quả khi không đạt |
| --- | --- | --- |
| **G1 — không tự hại** | Đích **không** là hog, không là tổ tiên của hog (shell, phiên Claude đang gọi hog, cửa sổ VS Code chứa nó). Danh sách tổ tiên lấy từ chính snapshot (`hog.ancestors`). | `block` (exit 4), không có cách vượt |
| **G2 — thuộc phiên khác thì hỏi** | Nếu đích hoặc tổ tiên của nó thuộc một phiên Claude/cửa sổ/terminal **không phải** của người gọi, hoặc `owner.busy` ≠ false, hoặc hoạt động trong 10 phút qua → cần người xác nhận **có đọc tên chủ sở hữu**. | `confirm` bắt buộc; không có TTY → exit 3 |
| **G3 — danh tính tiến trình** | Danh tính là `(pid, giờ khởi chạy)`. Ngay trước khi gửi tín hiệu, đọc lại và so với cái đã hiển thị cho người xem. Lệch (PID bị tái sử dụng) → **huỷ**. | `block` (exit 4) |
| **G4 — dừng nhẹ trước, không tự SIGKILL** | Gửi SIGTERM, chờ tối đa 10 s. Còn sống thì **hỏi lại** trước khi SIGKILL (khác `lps` v0.1.0 tự SIGKILL sau 1 s). | `confirm` lần hai; SIGKILL cần xác nhận riêng |
| **G5 — container có restart policy** | Chính sách ∈ {`always`, `unless-stopped`, `on-failure`}: gọi `update` đặt `no` **trước**, đọc lại để **xác nhận** đã là `no`, rồi mới `stop`. Nếu `update` thất bại hoặc đọc lại không phải `no` → **không stop**. Ghi chính sách cũ vào nhật ký để khôi phục. | `block` (exit 4) |
| **G6 — chỉ thứ của mình** | Không dừng tiến trình của user khác/hệ thống; không bao giờ dùng `sudo`. | `block` (exit 4) |
| **G7 — bằng chứng** | `hog stop` luôn in **kế hoạch**: đích, chủ sở hữu, số đo, quy tắc đã kích hoạt, `stop_effect`, các lệnh sẽ chạy. Hog **chỉ nhãn "không dùng"** khi finding có bằng chứng đo (mục 5.1); người vẫn có thể chủ động dừng thứ chưa có finding, nhưng sẽ thấy dòng "chưa có số đo cho: …". | in kế hoạch rồi hỏi |
| **G8 — nhật ký** | Mỗi lần dừng ghi một dòng JSON vào `~/.local/state/hog/actions.jsonl`: thời điểm, danh tính, kế hoạch, số đo, kết quả cổng, chính sách restart cũ. | không ghi được thì không dừng |

Luồng:

```text
hog stop <pid | cổng | item-id | tên container>
  └─ phân giải đích → dựng kế hoạch (không làm gì)
     └─ chạy G1, G6 (block?) → G2, G3, G7 (cần xác nhận?) → in kế hoạch
        ├─ TTY: hỏi [y/N]  (G2 hiện tên chủ sở hữu)
        └─ không TTY (ví dụ Claude gọi qua Bash): exit 3, in kế hoạch + plan_id
              → người đồng ý trong chat → `hog stop --yes --plan <plan_id>` chỉ chạy được
                nếu trạng thái hiện tại **vẫn khớp** kế hoạch (G3 kiểm lại)
     └─ thực thi theo chiến lược → G4/G5 → đọc lại để xác nhận kết quả → G8 ghi nhật ký
```

`plan_id` là băm của (danh tính, kế hoạch, số đo hiển thị). Nhờ đó "người đồng ý trong chat" gắn với **đúng thứ họ đã
thấy**, không phải thứ vừa thay đổi sau đó.

Mã thoát: `0` xong · `1` lỗi · `2` dùng sai · `3` cần người xác nhận · `4` bị cổng an toàn chặn.

## 8. Giao diện dòng lệnh

| Lệnh | Việc |
| --- | --- |
| `hog` / `hog status` | bảng cho người: dòng tổng quan (RAM, nén, swap, áp lực, CPU, tải) · các owner nặng nhất kèm tổng · các finding. Màu tắt khi không phải TTY hoặc có `NO_COLOR`. |
| `hog --json` | snapshot đầy đủ (mục 4). `--fast` bỏ mẫu `top` thứ hai và `code --status`; `--full` không lọc tiến trình; `--top N`. |
| `hog explain <đích>` | mọi fact của một item, quy tắc nào kích hoạt/không và vì sao, mục danh mục, cổng nào sẽ chặn. Dành cho người và cho Claude. |
| `hog ports` · `hog orphans` | giữ tính năng của `lps` v0.1.0: liệt kê cổng LISTEN gom theo dự án, đánh dấu `[orphan]`. |
| `hog stop <đích>` | mục 7. Thay `lps kill`. |
| `hog catalog list\|show\|check` · `hog rules check` | xem và kiểm tra dữ liệu (kể cả bản cục bộ). |
| `hog version` · `hog help` | — |

`lps kill` bị thay bởi `hog stop` (cùng ý nghĩa "dừng theo cổng/PID" nhưng đi qua cổng an toàn); không giữ `kill` làm bí danh vì nó
mặc định SIGKILL sau 1 giây — hành vi mà luật ở mục 7 cấm.

## 9. Kiểm thử và cách xác nhận "xong"

Vì cảm biến gọi lệnh hệ thống, phần dễ vỡ nhất là phân tích đầu ra. Do đó:

1. **Fixture đầu ra thật đã làm sạch.** Ghi đầu ra của `top`, `ps`, `lsof`, `code --status`, `vm_stat`, `watchman`, `sessions/*.json`
   từ máy thật, chạy qua một script thay tên/đường dẫn thật bằng tên giả, **commit vào `testdata/`**. Parser là hàm thuần
   nên test bằng fixture; có cả các ca xấu đã gặp: cột `Mem MB` rác của `code --status`, tên bị `top` cắt, hậu tố `+`.
2. **Engine quy tắc**: test từng toán tử, ngữ nghĩa ba giá trị (`unknown` không kích hoạt `advice`, có kích hoạt
   `protect`), thứ tự ưu tiên verdict, file quy tắc hỏng bị bỏ qua mà không dừng chương trình.
3. **Cổng an toàn** — test bằng tiến trình thật do test tự sinh (`sleep`), **không bao giờ nhắm vào tiến trình có sẵn của
   máy**: G1 (đích là tổ tiên: dựng chuỗi cha–con), G3 (đổi giờ khởi chạy giữa lúc hiển thị và lúc gửi → huỷ), G4 (không tự
   SIGKILL), G6.
4. **Docker**: máy chủ HTTP giả trên unix socket; kiểm `update --restart=no` rồi đọc lại rồi mới stop, ca `update` thất bại
   không stop, ca socket không tồn tại → `unavailable`.
5. **Hợp đồng JSON**: golden file cho snapshot từ fixture; một test `--json` kiểm schema (số nguyên byte, thời gian UTC,
   không có đường dẫn home tuyệt đối, không có biến môi trường).
6. **`hog ports`**: kết quả khớp `lps` v0.1.0 trên cùng fixture.
7. **Trên máy thật** (người chạy): `hog` < 3 s; nhận ra cửa sổ VS Code nào sở hữu tsserver/extension host; ghi
   `owner.idle_s` cho từng phiên Claude; gắn cờ `watchman` mồ côi nếu có; docker `unavailable` khi engine tắt. Ca container
   restart liên tục chỉ kiểm được bằng Docker giả vì engine hiện tắt.

**Xong giai đoạn 1** khi mục 1–6 xanh trong CI, mục 7 đạt, user duyệt, và đã có skill trong hub (mục 10).

## 10. Cấu trúc repo, phát hành, skill trong hub

```text
cmd/hog/           main
internal/sense/    cảm biến: mem, cpu, proc (ps+top), net (lsof), vscode, claude, watchman, docker
internal/model/    kiểu snapshot + JSON
internal/own/      quy chiếu chủ sở hữu
internal/rules/    nạp + chạy quy tắc        internal/catalog/   nạp + khớp danh mục
internal/stop/     kế hoạch, cổng, chiến lược, nhật ký
internal/render/   bảng cho người
catalog/ rules/    dữ liệu nhúng sẵn (go:embed)
testdata/          fixture đã làm sạch
docs/design-vi.md  tài liệu này
```

- Go (cùng đời với claude-acc), **chỉ thư viện chuẩn** — cảm biến gọi lệnh hệ thống nên không cần phụ thuộc ngoài.
- macOS arm64 + amd64. README hiện tuyên bố hỗ trợ Linux; cảm biến mới dùng `top -stats`, `vm_stat`, `code --status`
  nên **giai đoạn 1 chỉ macOS** (xem mục 11).
- **Phát hành bằng file nhị phân đính kèm GitHub Release**, formula tap trỏ vào file đó + `sha256` trong `SHA256SUMS`.
  Lý do rút từ chính dự án này: formula hiện tại ghim `sha256` của *tarball mã nguồn của tag*, mà tarball đó thay đổi mỗi
  khi dời tag **hoặc đổi tên repo** — chuyện đã xảy ra hai lần trong ngày 2026-10-15. Asset của Release không phụ thuộc cả hai.
- Tap: thêm `Formula/hog.rb`, rồi gỡ `Formula/lps.rb` — kèm việc gỡ đoạn formula tự xoá bản `lps` không-brew ở các thư mục
  người dùng (hành vi xoá file ngoài quyền của một formula).
- Mã bash `lps`/`install.sh`: giữ trong `legacy/` tới khi `hog ports` khớp (mục 9.6), rồi xoá. README, `CLAUDE.md` của repo và
  ví dụ output (đang chứa tên dự án thật) viết lại cùng giai đoạn 1.
- **Skill trong hub** (`.claude/skills/`, sửa thẳng trên `main` của hub): khi user hỏi "máy nặng vì gì", Claude chạy `hog --json`,
  đọc `findings`, trả lời theo thứ tự tổng quan → ai đang hao → đề xuất kèm bằng chứng → thứ **đừng đụng** và vì sao.
  Skill không dừng gì; muốn dừng thì in kế hoạch của `hog stop` cho user, và chỉ chạy `--yes --plan` sau khi user đồng ý rõ.
  Giải thích tốt thì ghi vào `~/.config/hog/catalog.d/<id>.json` (cộng `hog catalog check`).

## 11. Điều cần user chốt trước khi code

| # | Câu hỏi | Đề xuất của mình |
| --- | --- | --- |
| 1 | Gọi lệnh hệ thống (`top`, `ps`, `lsof`, …) hay đọc API native? | Gọi lệnh ở giai đoạn 1 (đơn giản, tái hiện bằng tay); thay dần nếu `top` 1,85 s thành điểm nghẽn |
| 2 | Danh mục/quy tắc dạng JSON, một file/mục, ghi đè ở `~/.config/hog/`, **cấm nhúng lệnh** | Đồng ý? (YAML cần thư viện ngoài; JSON dùng thư viện chuẩn) |
| 3 | Đọc `~/.claude/sessions/<pid>.json` (nội bộ Claude Code, không cam kết ổn định)? | Có, đọc dung sai, tụt về `unavailable` khi đổi |
| 4 | Không bao giờ tự SIGKILL (khác `lps kill`)? | Đồng ý — luật G4 |
| 5 | Claude gọi `hog stop` qua `--yes --plan <plan_id>` sau khi user đồng ý trong chat? | Đồng ý — vẫn qua G1/G3/G5 |
| 6 | Ngưỡng "phiên Claude bị bỏ quên": 2 giờ `idle` | Bắt đầu 2 giờ, chỉnh theo thực tế |
| 7 | Giai đoạn 1 chỉ macOS (bỏ lời hứa Linux của README cũ)? | Đồng ý |
| 8 | Tài liệu thiết kế tiếng Việt trong repo công khai? | Giữ tiếng Việt; README + code tiếng Anh |
| 9 | Phát hành bằng asset của Release thay vì tarball mã nguồn? | Đồng ý (mục 10) |
