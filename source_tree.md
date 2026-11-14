# HSP-117 MMI TEST - Cấu trúc source và chức năng từng file

Bộ test MMI cho **Camera Bullet QCS6490 (QLI 1.9)**, chạy trên **PC Ubuntu**, điều khiển camera qua
**adb IP** (hoặc ssh), ghi kết quả ra báo cáo HTML/log/csv.

Tài liệu này cho người vận hành và người bảo trì: mỗi file làm gì, dữ liệu đi qua đâu, muốn sửa X thì sửa file nào.
Cách dùng nhanh nằm trong `README.md`; danh sách mục test mới nhất: `./mmi/run_mmi.sh --list`.

## 1. Luồng chạy một lần test

    tool.py (giao diện) --mở terminal--> mmi/run_mmi.sh

    1. Đọc config.sh, nạp mmi/lib/*.sh và mmi/tests/TEST_*.sh
    2. Chọn nhóm/mục: --all | --group | --cluster | --case
    3. setup_pc.sh --check (thiếu tool trên PC thì hỏi cài)
    4. Kết nối thiết bị (transport_adb.sh / transport_ssh.sh), tối đa CONNECT_TIMEOUT = 10s
    5. Đọc Device ID = Serial (getprop ro.serialno; chưa có serial thì dùng MAC ethernet),
       rồi nhập/quét số tem HSPTek
    6. Precheck (kiểm kê tool trên thiết bị/PC), sau đó chạy từng nhóm, từng mục (case_<id>):
         - Mục dùng I2C (RTC, SHT4x, Lens, TPM): i2c_gate dò thiết bị trên bus trước
           (bảng I2C_GATES trong config.sh), thiếu thì FAIL, không chạy mục đó
         - Mỗi mục gọi dev_* (làm việc với thiết bị) rồi đúng một tc_pass/tc_fail
         - Mục cần người đánh giá: ask_yn (Y = ĐẠT / N = KHÔNG ĐẠT)
    7. finish_report: tổng kết, banner PASS/FAIL, ghi reports/<tên>/ (html + log + csv)
    8. Thoát (kể cả Ctrl-C): on_exit khôi phục thiết bị; nếu chạy dở vẫn lưu báo cáo INCOMPLETE

Ghi MAC là luồng riêng: `tool.py` → `run_mmi.sh --write-mac <MAC>` → `mmi/lib/mac_write.sh`.

## 2. Cây thư mục và chức năng từng file

```text
HSP117_MMI_TEST/
├── tool.py                   Giao diện (tkinter): chạy full, chạy theo cụm, ghi MAC/Serial, cài tool PC, mở thư mục báo cáo
├── config.sh                 CẤU HÌNH DUY NHẤT: sản phẩm, ngưỡng pass/fail, cụm test, I2C, RTSP, MAC, timeout...
├── setup_pc.sh               Kiểm tra / cài tool trên PC Ubuntu (adb, iperf3, ffmpeg, vlc, python3-tk...)
├── README.md                 Hướng dẫn vận hành nhanh
├── source_tree.md            (file này)
├── .gitignore                Loại reports/, .last_ip, __pycache__ khỏi git
├── .last_ip                  IP thiết bị lần chạy trước (tự sinh, không đưa vào gói bàn giao)
├── reports/                  Kết quả (tự sinh, không đưa vào gói bàn giao)
│   ├── .last_run             Thiết bị/thư mục test gần nhất (tự sinh): để log Serial/MAC vào đúng thư mục
│   └── <tên lần test>/       Mỗi thiết bị 1 thư mục: .html .log .csv + deviceinfo.log devinfo_log.csv mac_write_log.csv gui_last_run.log
└── mmi/
    ├── run_mmi.sh            Điều phối: tham số, chọn nhóm/cụm/mục, kết nối, chạy test, tổng kết
    ├── lib/
    │   ├── mmi_lib.sh        Lõi: làm việc với thiết bị (dev_*), ghi kết quả (tc_*), hỏi người test, i2c_gate, dọn dẹp
    │   ├── devinfo.sh        Đọc Chip ID / Serial / MAC, ghi Serial, reboot thiết bị
    │   ├── report.sh         Tạo báo cáo: tổng kết, banner PASS/FAIL, gom log, ghi 3 file reports/<tên>/
    │   ├── html_report.py    Dựng file HTML từ dữ liệu kết quả + log
    │   ├── report.css        Giao diện (CSS) của báo cáo HTML
    │   ├── transport_adb.sh  Kết nối adb qua IP (kết nối lại, timeout 10s, exec/pull/push)
    │   ├── transport_ssh.sh  Kết nối ssh, cùng giao diện hàm với transport_adb.sh
    │   ├── mmi_rtsp.sh       Bật/kiểm tra/xem stream RTSP (9.3 Stream và các bài Lens); xem bằng VLC, lỗi thì ffplay
    │   ├── mac_write.sh      Luồng ghi MAC: tạo bin → push → ethtool -E → đọc lại → reboot → kiểm tra
    │   └── mac_bin.py        Tạo file MAC bin 254 byte từ file mẫu (thay MAC, tự dò kiểu lưu), có chế độ verify
    ├── mac/
    │   ├── template.bin      File MẪU 254 byte đang dùng được (phải có trước khi ghi MAC)
    │   └── README.txt        Hướng dẫn đặt file mẫu
    └── tests/                Mỗi nhóm test một file (xem mục 3)
```

## 3. Các nhóm test (mmi/tests)

Mỗi file `TEST_<NHÓM>.sh` khai báo danh sách `CASES_<NHÓM>=( "id|tên|cờ" )` và các hàm `case_<id>`
(dấu chấm → gạch dưới, ví dụ `case_5_3`).

| Nhóm         | File               | Các mục   | Nội dung chính                                                                             |
|--------------|--------------------|-----------|--------------------------------------------------------------------------------------------|
| COM          | TEST_COM.sh        | 1.1-1.3   | Số core CPU, RAM (tổng/trống), dung lượng storage `sda`                                    |
| ETHERNET     | TEST_ETHERNET.sh   | 2.1-2.3   | Tốc độ iperf3 nhận / truyền / hai chiều (PC tự bật iperf3 server)                          |
| NVME         | TEST_NVME.sh       | 3.1-3.3   | Nhận NVMe; đo tốc độ ghi / đọc bằng fio (clusteronly: không chạy trong `--all`)             |
| GPS          | TEST_GPS.sh        | 4.1-4.5   | Bản tin NMEA, số vệ tinh, GNSS Fix, tọa độ, trạng thái Navigation (cần ăng-ten ngoài trời) |
| RTC          | TEST_RTC.sh        | 5.1-5.6   | Nhận RTC, đọc, set giờ, giữ giờ sau rút nguồn (5.4, 5.5), đồng bộ không/có internet        |
| SD_CARD      | TEST_SD_CARD.sh    | 6.1-6.3   | Nhận thẻ SD; ghi / đọc bằng fio (clusteronly: không chạy trong `--all`)                     |
| TPM          | TEST_TPM.sh        | 7.1-7.2   | Nhận TPM; chạy các lệnh tpm2                                                               |
| ALARM_IO     | TEST_ALARM_IO.sh   | 8.1-8.2   | Alarm IN (đọc GPIO); Alarm OUT (echo 0/1 3 lần, người test nghe tiếng rơ-le)               |
| CAMERA       | TEST_CAMERA.sh     | 9.1-9.3   | Chụp ảnh, quay video 1080p/4K, stream RTSP (người test đánh giá hình)                      |
| AUDIO        | TEST_AUDIO.sh      | 10.1-10.4 | Sound card, loa trong (WSA, clusteronly), Line In (AMIC3: PC phát tone 1 kHz, thu, nghe lại), Line Out |
| LENS         | TEST_LENS.sh       | 11.1-11.7 | Zoom, Focus, Iris, IR CUT (xem qua RTSP), nhiệt độ lens, cảm biến sáng, IR LED             |
| SENSOR       | TEST_SENSOR.sh     | 12.1-12.5 | Accel/Gyro/Mag (dữ liệu khác 0), nhiệt độ-độ ẩm SHT4x                                      |
| (dùng chung) | _common_storage.sh | -         | Hàm chung cho NVMe/SD: tìm thiết bị, mount hay thô, chạy fio                               |

Cờ trong danh sách mục:

| Cờ            | Ý nghĩa                                                    |
|---------------|------------------------------------------------------------|
| manual        | Cần người đánh giá                                         |
| heavy / power | Mục nặng / rút nguồn, chỉ chạy khi `--heavy` hoặc `--case` |
| clusteronly   | Chỉ chạy trong test cụm hoặc `--case`                      |

## 4. Quy tắc kết quả

- Mỗi mục chỉ **PASS** hoặc **FAIL**. Mục không thực hiện được (thiếu thiết bị/tool, chưa xác nhận,
  mất kết nối, không chạy được trong `--all`) đều **FAIL** kèm lý do.
- Kết luận chỉ **PASS** khi mọi mục chạy đều PASS. Dừng giữa chừng → **INCOMPLETE**, không bao giờ PASS.
- Người test chỉ phải trả lời **Y/N** ở các mục `manual`.

## 5. Chạy theo CỤM (config.sh)

- `CLUSTERS="..."` liệt kê tên cụm hiển thị trong `tool.py`.
- `CLUSTER_<TÊN>="NHÓM1 NHÓM2"`: cụm gồm các nhóm; giá trị `*` = mọi nhóm chưa thuộc cụm khác.
  `CLUSTER_<TÊN>_CASES="id id"`: cụm gồm một số mục cụ thể.
- Cụm khai báo bằng `_CASES` chỉ chạy đúng các mục liệt kê (ví dụ chỉ mức "nhận": 3.1, 6.1, không fio).
  Chạy **full** (`--all`, nút MMI Test 117) không bị ảnh hưởng.
- Cờ **`clusteronly`** (trong `CASES_<NHÓM>`): mục chi tiết chỉ dành cho test cụm, **không chạy**
  trong `--all`/`--group`; chạy khi chọn cụm chứa mục đó hoặc `--case <id>`.
- Thêm bài test cụm chi tiết:
  1. Khai báo mục trong `CASES_<NHÓM>` kèm cờ `clusteronly`.
  2. Viết hàm `case_<N>_<M>`.
  3. Thêm id vào `CLUSTER_<TÊN>_CASES` trong config.sh.
- Tên cụm xuất hiện trong tên thư mục báo cáo.

## 6. Dữ liệu sinh ra

Mỗi thiết bị đúng **một** thư mục `reports/<PRODUCT>_<tem>_<DEVICE ID>_<giờ>[_<CỤM>]_<PASS|FAIL|INCOMPLETE>/`:

- Lần test tạo 3 file cùng tên: `.html` (báo cáo + log), `.log` (log đầy đủ + phụ lục dữ liệu thô),
  `.csv` (bảng kết quả, mở được bằng Excel).
- Read Chip ID / Write Serial / Write MAC / Reboot ghi thêm vào **cùng thư mục**:
  - `deviceinfo.log`: log đầy đủ (có output thô của thiết bị), nối tiếp.
  - `devinfo_log.csv`: tóm tắt Read / Write Serial / Reboot.
  - `mac_write_log.csv`: mỗi lần ghi MAC một dòng.
  - `gui_last_run.log`: output thô của lần Read / Reboot gần nhất trên giao diện.

Cơ chế (report.sh: `devlog_resolve`, `devlog_match`, `devlog_pointer_*`): `reports/.last_run` ghi thư mục + Chip ID +
MAC của thiết bị test gần nhất. Thao tác thông tin thiết bị đặt `LOG_DIR` = thư mục đó nếu Chip ID hoặc MAC trùng
(ghi MAC xong thì MAC mới được thêm vào danh sách). Chưa có thì tạo `*_DEVINFO`; lần test sau của thiết bị đó dùng
lại thư mục này và đổi tên theo kết quả. Chỉ nhớ thiết bị gần nhất.

Mọi file tạm (ảnh/video/wav, meta...) nằm trong `/tmp/mmi.*` và bị xoá khi thoát.

## 7. Thư viện lõi - hàm chính (mmi/lib)

**mmi_lib.sh**

- Thiết bị: `dev_sh "lệnh"`, `dev_script <<'EOF' … EOF` (nhiều dòng), `dev_script_live` (in output ngay,
  ẩn log nhiễu), `dev_val`, `dev_has <tool>`, `dev_push`, `dev_pull`, `wait_device`.
- Kết quả: `tc_begin`, `tc_pass`, `tc_fail`, `tc_skip`/`tc_todo` (đều ghi FAIL), `tc_need <tool>`,
  `tc_manual "câu hỏi?"`.
- I2C: `i2c_gate <id mục>` kiểm tra thiết bị trên bus (theo `I2C_GATES`), thiếu thì ghi FAIL.
- Người test: `ask_yn` (khung Y/N, không có phím bỏ qua), `pause_enter`.
- Dọn dẹp: `on_cleanup '<lệnh>'` đăng ký khôi phục trạng thái thiết bị (chạy khi thoát/Ctrl-C),
  `save_artifact`.

**report.sh**: `init_report` (header + thư mục làm việc tạm), `finish_report` (tổng kết + banner),
`make_html_report` (gom log, ghi 3 file).

**transport_*.sh**: cùng giao diện `tp_init tp_ready tp_wait tp_exec tp_exec_live tp_pull tp_push tp_close`;
đổi adb ↔ ssh bằng `TRANSPORT`.

**mmi_rtsp.sh**: `rtsp_start`, `rtsp_check`, `rtsp_view`, `rtsp_ensure_view`, `rtsp_stop`, `rtsp_teardown`.

## 8. Muốn sửa X thì sửa file nào

| Việc                                                             | File                                                                         |
|------------------------------------------------------------------|------------------------------------------------------------------------------|
| Đổi ngưỡng pass/fail, IP, timeout, cụm, thông số RTSP/MAC/Sensor | `config.sh`                                                                  |
| Thêm/sửa thiết bị kiểm tra I2C trước khi test                    | `config.sh` (`I2C_GATES`)                                                    |
| Thêm/sửa một bài test                                            | `mmi/tests/TEST_<NHÓM>.sh`                                                   |
| Thêm nhóm test mới                                               | Tạo `TEST_<NHÓM>.sh` + thêm tên vào `TEST_GROUPS_ALL` trong `config.sh`      |
| Đổi cách hỏi người test / giao diện terminal                     | `mmi/lib/mmi_lib.sh` (`ask_yn`)                                              |
| Đổi nội dung / bố cục báo cáo                                    | `mmi/lib/html_report.py`, `mmi/lib/report.css`, `mmi/lib/report.sh`          |
| Đổi tên thư mục/file báo cáo                                     | `mmi/lib/report.sh` (`make_html_report`)                                     |
| Đổi nơi lưu log thiết bị                                         | `mmi/lib/report.sh` (`devlog_resolve`), `config.sh` (`LOG_DIR`)              |
| Đổi giao diện tool                                               | `tool.py`                                                                    |
| Đổi luồng ghi MAC                                                | `mmi/lib/mac_write.sh`, `mmi/lib/mac_bin.py`, biến `MAC_*` trong `config.sh` |
| Đổi cách xem stream (VLC/ffplay, cache)                          | `mmi/lib/mmi_rtsp.sh`, biến `RTSP_*` trong `config.sh`                       |
| Thêm tool PC cần cài                                             | `setup_pc.sh` (danh sách `TOOLS`)                                            |