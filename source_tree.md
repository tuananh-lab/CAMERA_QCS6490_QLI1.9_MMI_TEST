# HSP-117 MMI TEST - Cấu trúc source và chức năng từng file

Bộ test MMI cho **Camera Bullet QCS6490 (QLI 1.9)**, chạy trên **PC Ubuntu**, điều khiển camera qua
**adb IP** (hoặc ssh), ghi kết quả ra báo cáo HTML/log/csv.

Tài liệu này cho người vận hành và người bảo trì: mỗi file làm gì, dữ liệu đi qua đâu, từng mục test kiểm tra
cái gì và PASS khi nào, muốn sửa X thì sửa file nào.
Cách dùng nhanh nằm trong `README.md`; danh sách mục test mới nhất: `./mmi/run_mmi.sh --list`.

## 1. Luồng chạy một lần test

    tool.py (giao diện) --mở terminal--> mmi/run_mmi.sh

    1. Đọc config.sh, nạp mmi/lib/*.sh và mmi/tests/TEST_*.sh
       (config.sh nạp TRƯỚC nên giá trị trong config.sh đè mặc định `: "${BIEN:=giá_trị}"` trong các file test/lib)
    2. Chọn nhóm/mục: --all | --group | --cluster | --case
    3. setup_pc.sh --check (thiếu tool trên PC thì hỏi cài)
    4. Kết nối thiết bị (transport_adb.sh / transport_ssh.sh), tối đa CONNECT_TIMEOUT = 10s.
       Nếu ping được mà adb không connect: fix tạm ssh vào restart adbd rồi connect lại (mục 10)
    5. Đọc Device ID = Serial (getprop ro.serialno; chưa có serial thì dùng MAC ethernet),
       rồi nhập/quét số tem HSPTek
    6. Precheck (kiểm kê tool trên thiết bị/PC), sau đó chạy từng nhóm, từng mục (case_<id>):
         - Mục dùng I2C (RTC, SHT4x, Lens, TPM): i2c_gate dò thiết bị trên bus trước
           (bảng I2C_GATES trong config.sh), thiếu thì FAIL, không chạy mục đó
         - Mỗi mục gọi dev_* (làm việc với thiết bị) rồi đúng một tc_pass/tc_fail
         - Mục cần người đánh giá: ask_yn (Y = ĐẠT / N = KHÔNG ĐẠT)
    7. finish_report: tổng kết, banner PASS/FAIL, ghi reports/<tên>/ (html + log + csv),
       rồi tự mở trang HTML kết quả (MMI_OPEN_REPORT=0 để tắt)
    8. Thoát (kể cả Ctrl-C): on_exit khôi phục thiết bị; nếu chạy dở vẫn lưu báo cáo INCOMPLETE

Ghi MAC là luồng riêng: `tool.py` → `run_mmi.sh --write-mac <MAC>` → `mmi/lib/mac_write.sh`.
Read Chip ID / Write Serial / Reboot: `tool.py` → `run_mmi.sh --read-id | --write-serial | --reboot` → `mmi/lib/devinfo.sh`.

## 2. Cây thư mục và chức năng từng file

```text
HSP117_MMI_TEST/
├── tool.py                   Giao diện (tkinter): chạy full, chạy theo cụm (danh sách cụm nằm trong cửa sổ, bấm 1 lần để chạy),
│                             ghi MAC/Serial, Read Chip ID, Reboot, cài tool PC, mở thư mục báo cáo
├── config.sh                 CẤU HÌNH DUY NHẤT: sản phẩm, ngưỡng pass/fail, cụm test, I2C, RTSP, MAC, timeout, gỡ lỗi...
├── setup_pc.sh               Kiểm tra / cài tool trên PC Ubuntu (adb, iperf3, ffmpeg, vlc, python3-tk...)
├── README.md                 Hướng dẫn vận hành nhanh
├── source_tree.md            (file này)
├── .gitignore                Loại reports/, .last_ip, __pycache__ khỏi git
├── .last_ip                  IP thiết bị lần chạy trước (tự sinh, không đưa vào gói bàn giao)
├── reports/                  Kết quả (tự sinh, không đưa vào gói bàn giao)
│   ├── .last_run             Thiết bị/thư mục test gần nhất (tự sinh): để log Serial/MAC vào đúng thư mục
│   └── <tên lần test>/       Mỗi thiết bị 1 thư mục: .html .log .csv + deviceinfo.log devinfo_log.csv mac_write_log.csv gui_last_run.log
│                             (+ artifacts/ nếu KEEP_ARTIFACTS=1)
└── mmi/
    ├── run_mmi.sh            Điều phối: tham số, chọn nhóm/cụm/mục, kết nối, chạy test, tổng kết
    ├── lib/
    │   ├── mmi_lib.sh        Lõi: làm việc với thiết bị (dev_*), ghi kết quả (tc_*), hỏi người test, i2c_gate, dọn dẹp
    │   ├── devinfo.sh        Đọc Chip ID / Serial / MAC, ghi Serial, reboot thiết bị (chờ ping mất rồi chờ kết nối lại)
    │   ├── report.sh         Tạo báo cáo: tổng kết, banner PASS/FAIL, gom log, ghi 3 file reports/<tên>/, mở HTML, giữ artifacts
    │   ├── html_report.py    Dựng file HTML từ dữ liệu kết quả + log
    │   ├── report.css        Giao diện (CSS) của báo cáo HTML
    │   ├── transport_adb.sh  Kết nối adb qua IP: connect/ready/wait (timeout 10s), exec/pull/push, reboot, fix tạm adbd
    │   ├── transport_ssh.sh  Kết nối ssh, cùng giao diện hàm với transport_adb.sh
    │   ├── mmi_rtsp.sh       Bật/kiểm tra/xem stream RTSP (9.3 Stream và các bài Lens); xem bằng VLC, lỗi thì ffplay
    │   ├── mac_write.sh      Luồng ghi MAC: tạo bin → push → ethtool -E → đọc lại → reboot → kiểm tra
    │   └── mac_bin.py        Tạo file MAC bin 254 byte từ file mẫu (thay MAC, tự dò kiểu lưu), có chế độ verify
    ├── mac/
    │   ├── template.bin      File MẪU 254 byte đang dùng được (phải có trước khi ghi MAC)
    │   └── README.txt        Hướng dẫn đặt file mẫu
    └── tests/                Mỗi nhóm test một file (xem mục 3 và mục 9)
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
- `KEEP_ARTIFACTS=1` (config.sh): giữ thêm thư mục `artifacts/` (log thô từng mục, kể cả ảnh/video/wav và
  `rtsp_viewer.log`) trong thư mục báo cáo. Mặc định 0: chỉ text của artifacts nằm trong phụ lục cuối file `.log`.
- Read Chip ID / Write Serial / Write MAC / Reboot ghi thêm vào **cùng thư mục**:
  - `deviceinfo.log`: log đầy đủ (có output thô của thiết bị), nối tiếp.
  - `devinfo_log.csv`: tóm tắt Read / Write Serial / Reboot.
  - `mac_write_log.csv`: mỗi lần ghi MAC một dòng.
  - `gui_last_run.log`: output thô của lần Read / Reboot gần nhất trên giao diện.

Cơ chế (report.sh: `devlog_resolve`, `devlog_match`, `devlog_pointer_*`): `reports/.last_run` ghi thư mục + Chip ID +
MAC của thiết bị test gần nhất. Thao tác thông tin thiết bị đặt `LOG_DIR` = thư mục đó nếu Chip ID hoặc MAC trùng
(ghi MAC xong thì MAC mới được thêm vào danh sách). Chưa có thì tạo `*_DEVINFO`; lần test sau của thiết bị đó dùng
lại thư mục này và đổi tên theo kết quả. Chỉ nhớ thiết bị gần nhất.

Mọi file tạm (ảnh/video/wav, meta...) nằm trong `/tmp/mmi.*` và bị xoá khi thoát (trừ khi `KEEP_ARTIFACTS=1`).

## 7. Thư viện lõi - hàm chính (mmi/lib)

**mmi_lib.sh**

- Thiết bị: `dev_sh "lệnh"`, `dev_sh_t <giây> "lệnh"` (có timeout), `dev_script <<'EOF' … EOF` (nhiều dòng,
  truyền biến `VAR=giá_trị`), `dev_script_live` (in output ngay, ẩn log nhiễu), `dev_val`, `dev_has <tool>`,
  `dev_push`, `dev_pull`, `wait_device`.
- Kết quả: `tc_begin`, `tc_pass`, `tc_fail`, `tc_skip`/`tc_todo` (đều ghi FAIL), `tc_need <tool>`,
  `tc_manual "câu hỏi?"`.
- I2C: `i2c_gate <id mục>` kiểm tra thiết bị trên bus (theo `I2C_GATES`), thiếu thì ghi FAIL.
- Người test: `ask_yn` (khung Y/N, không có phím bỏ qua), `pause_enter`.
- Dọn dẹp: `on_cleanup '<lệnh>'` đăng ký khôi phục trạng thái thiết bị (chạy khi thoát/Ctrl-C),
  `save_artifact`.

**report.sh**: `init_report` (header + thư mục làm việc tạm), `finish_report` (tổng kết + banner),
`make_html_report` (gom log, ghi 3 file, giữ artifacts nếu bật, mở HTML).

**transport_*.sh**: cùng giao diện `tp_init tp_ready tp_wait tp_exec tp_exec_live tp_pull tp_push tp_reboot tp_close`;
đổi adb ↔ ssh bằng `TRANSPORT`. `tp_wait` = connect lại cho tới khi shell trả lời (giới hạn theo đồng hồ thật).

**mmi_rtsp.sh**: `rtsp_start`, `rtsp_check`, `rtsp_view`, `rtsp_ensure_view`, `rtsp_stop`, `rtsp_teardown`.

**devinfo.sh**: đọc `ro.chipid`, `ro.serialno`, MAC; ghi Serial vào phân vùng devinfo; luồng Reboot (mục 10).

## 8. Muốn sửa X thì sửa file nào

| Việc                                                             | File                                                                         |
|------------------------------------------------------------------|------------------------------------------------------------------------------|
| Đổi ngưỡng pass/fail, IP, timeout, cụm, thời gian chờ/đếm ngược  | `config.sh` (mục "THAM SỐ THƯỜNG CHỈNH": đè mặc định trong file test)        |
| Thêm/sửa thiết bị kiểm tra I2C trước khi test                    | `config.sh` (`I2C_GATES`)                                                    |
| Thêm/sửa một bài test                                            | `mmi/tests/TEST_<NHÓM>.sh`                                                   |
| Thêm nhóm test mới                                               | Tạo `TEST_<NHÓM>.sh` + thêm tên vào `TEST_GROUPS_ALL` trong `config.sh`      |
| Đổi cách hỏi người test / giao diện terminal                     | `mmi/lib/mmi_lib.sh` (`ask_yn`)                                              |
| Đổi nội dung / bố cục báo cáo                                    | `mmi/lib/html_report.py`, `mmi/lib/report.css`, `mmi/lib/report.sh`          |
| Đổi tên thư mục/file báo cáo                                     | `mmi/lib/report.sh` (`make_html_report`)                                     |
| Bật/tắt giữ artifacts, tự mở HTML                                | `config.sh` (`KEEP_ARTIFACTS`, `MMI_OPEN_REPORT`)                            |
| Đổi nơi lưu log thiết bị                                         | `mmi/lib/report.sh` (`devlog_resolve`), `config.sh` (`LOG_DIR`)              |
| Đổi giao diện tool                                               | `tool.py`                                                                    |
| Đổi luồng ghi MAC                                                | `mmi/lib/mac_write.sh`, `mmi/lib/mac_bin.py`, biến `MAC_*` trong `config.sh` |
| Đổi lệnh stream / cách xem stream (VLC/ffplay, cache)            | `mmi/lib/mmi_rtsp.sh`, biến `RTSP_*` trong `config.sh`                       |
| Đổi cách reboot qua adb, fix lỗi adbd                            | `mmi/lib/transport_adb.sh` (`tp_reboot`, `_adbd_fix`), `ADBD_FIX*` trong `config.sh` |
| Đổi giá trị focus / calib lens trước khi chạy camera             | `config.sh` (`CAM_FOCUS`, `CAM_CALIB`), `mmi/tests/TEST_CAMERA.sh`           |
| Thêm tool PC cần cài                                             | `setup_pc.sh` (danh sách `TOOLS`)                                            |

## 9. Logic từng mục test (ngắn gọn)

Quy ước: ngưỡng/tham số in **đậm** là biến trong `config.sh`. "Người test" = có khung Y/N (ask_yn).

### 1. COM (TEST_COM.sh)

- **1.1** `grep -c ^processor /proc/cpuinfo` = **COM_CPU_CORES** (8).
- **1.2** `free -h`: tổng RAM ≥ **COM_RAM_TOTAL_MIN_GIB** và RAM trống > **COM_RAM_FREE_MIN_GIB** (cột `free` hoặc `available` theo **COM_RAM_FREE_FIELD**).
- **1.3** `lsblk`: đĩa **COM_DISK_DEV** (`sda`) có dung lượng ≥ **COM_DISK_MIN_GIB**.

### 2. ETHERNET (TEST_ETHERNET.sh)

PC tự bật `iperf3 -s` (cổng **IPERF_PORT**), thiết bị chạy client `iperf3 -c <IP PC> -t <IPERF_TIME>`; PC cần mở firewall cổng này.
Mbps lấy từ dòng `receiver` của output iperf3.

- **2.1** `-R`: thiết bị là bên nhận, tốc độ nhận > **IPERF_MIN_MBPS** (900).
- **2.2** thiết bị gửi, lấy số phía nhận (PC), > **IPERF_MIN_MBPS**.
- **2.3** `--bidir` (iperf3 ≥ 3.7): **mỗi chiều** > **IPERF_BIDIR_MIN_MBPS** (850).

### 3. NVME / 6. SD_CARD (TEST_NVME.sh, TEST_SD_CARD.sh, _common_storage.sh)

Chỉ chạy khi test cụm hoặc `--case` (cờ clusteronly).

- **3.1 / 6.1** có thiết bị: NVMe (`lspci` + **NVME_DEV**), thẻ SD (**SD_DEV** hoặc `/dev/mmcblk*` đầu tiên). Không có → FAIL; 3.2/3.3 và 6.2/6.3 ghi SKIP.
- **3.2, 3.3, 6.2, 6.3** đo bằng `fio` (`bs=128k direct=1`, kích thước **NVME_FIO_SIZE** / **SD_FIO_SIZE**):
  nếu có phân vùng đang mount thì đo bằng file `.mmi_fio_test` trên phân vùng đó (an toàn); nếu không mount thì ghi/đọc **thô trực tiếp thiết bị**
  (chỉ cho phép `nvme*` / `mmcblk*`; ghi thô xoá bảng phân vùng ở đầu đĩa). PASS khi đọc được băng thông và ≥ ngưỡng
  **NVME_MIN_WRITE/READ_MBPS**, **SD_MIN_WRITE/READ_MBPS** (để trống = chỉ báo số đo, PASS nếu fio không lỗi).

### 4. GPS (TEST_GPS.sh)

Thu NMEA từ **GPS_TTY** trong **GPS_CAPTURE_S** giây **một lần**, 4.1-4.5 dùng chung dữ liệu đó. 4.2-4.5 cần ăng-ten nhìn thấy trời.

- **4.1** có dữ liệu và mỗi bản tin trong **GPS_NEED_SENTENCES** (GNGGA, GPGSA, GLGSA, GPGSV, GLGSV, GNRMC, GNVTG) xuất hiện ≥ **GPS_MIN_REPEAT** lần.
- **4.2** tổng số vệ tinh nhìn thấy (GSV GPS + GLONASS) > 0.
- **4.3** GNGGA có fix quality > 0 và số vệ tinh dùng > 0.
- **4.4** tọa độ hợp lệ (đổi ddmm.mmmm → độ thập phân) từ GNGGA (hoặc GNRMC).
- **4.5** GNRMC: status = `A`, có giờ, ngày và vị trí.

### 5. RTC (TEST_RTC.sh) - dùng NTP ra sao

Thiết bị: RTC PCF8563 trên i2c-1 0x51; sysfs `/sys/class/rtc/rtc0/{date,time}` (UTC). Mục RTC chạy sau `i2c_gate` (không thấy RTC trên bus → FAIL).
Hai hàm dùng chung: `_rtc_read_state` (đọc giờ hệ thống, RTC, boot_id, uptime, dòng dmesg "setting system clock") và
`_rtc_restore_time` (trả giờ thiết bị về giờ PC bằng `date -u -s` + `hwclock -w`, bật lại các dịch vụ NTP đã tắt, `systemctl start systemd-timesyncd`).

- **5.1** `dmesg | grep -i rtc` có dòng (driver đã nhận RTC).
- **5.2** `hwclock -r` rc=0 và có năm hợp lệ.
- **5.3** tắt `systemd-timesyncd` (tránh NTP kéo giờ ngay), `date -s "2026-01-27 08:49:00"`, `hwclock -w`, `hwclock -r`; PASS nếu lệch ≤ **RTC_TOL_S** (5s). Luôn khôi phục giờ PC sau đó.
- **5.4 Giữ giờ sau rút nguồn (có Ethernet)**:
  1. Tắt các dịch vụ NTP (`systemd-timesyncd`, `chronyd`, `ntpd`: `disable --now`; danh sách đang bật ghi vào `/etc/mmi_ntp_svcs` để bật lại sau) - để NTP **không** chỉnh giờ trước khi tool đọc.
  2. Đặt giờ hệ thống + RTC = **RTC_SET_TIME** (UTC) bằng `date -u -s` + `hwclock -w`, đọc lại xác nhận RTC nhận giờ.
  3. Tool nhắc **rút nguồn**, đếm lùi **RTC_UNPLUG_S** giây (≥ **RTC_OFF_MIN_S**), nhắc **cấp nguồn**; tool tự kết nối lại ngay khi thiết bị lên (`wait_device`, tối đa **REBOOT_WAIT**).
  4. Đọc RTC. PASS khi `boot_id` đã đổi, thời gian mất nguồn đo được ≥ **RTC_OFF_MIN_S**, và RTC = RTC_SET_TIME + thời gian đã trôi (theo đồng hồ PC) ± **TIME_TOL_S**.
  5. Trả giờ PC + bật lại NTP.
- **5.5 Đồng bộ RTC không internet**: như 5.4 nhưng nhắc **rút cáp Ethernet trước khi rút nguồn**, cấp nguồn khi chưa có mạng, đếm lùi **RTC_BOOT_WAIT_S** giây cho thiết bị boot rồi nhắc **cắm lại Ethernet** (Enter để bỏ qua đếm lùi). PASS khi RTC đúng và giờ hệ thống đúng
  (hoặc `dmesg` "setting system clock" cho thấy kernel đã nạp đúng giờ từ RTC lúc boot, dù sau đó mạng/NTP có chỉnh giờ).
- **5.6 Đồng bộ RTC có internet**: thiết bị phải ping được `8.8.8.8` (không có → không chạy được). Làm lệch giờ hệ thống (`date -u -s RTC_SET_TIME`),
  `systemctl restart systemd-timesyncd` (bật NTP), rồi mỗi giây đọc lại, chờ tối đa **RTC_NTP_WAIT_S**; khi giờ hệ thống về gần giờ PC (≤ **TIME_TOL_S**) thì kiểm tra tiếp:
  **cả giờ hệ thống và RTC** phải khớp giờ chuẩn (lấy giờ PC làm mốc, nên PC cần đồng bộ NTP). Cuối cùng trả giờ PC.

Tóm tắt vai trò NTP: 5.4/5.5 **tắt** NTP để chứng minh RTC tự giữ giờ; 5.6 **bật** NTP để chứng minh đồng bộ giờ chạy.

### 7. TPM (TEST_TPM.sh)

- **7.1** `dmesg | grep -i tpm` có dòng, `i2cdetect -y -r <TPM_I2C_BUS>` thấy thiết bị, và có `/dev/tpm*`.
- **7.2** chạy các lệnh `tpm2_getcap properties-fixed|properties-variable`, `tpm2_pcrread sha256:0,1,2,3`, `tpm2_getrandom 32 --hex`,
  `echo test | tpm2_hash`, `tpm2_selftest`: tất cả rc=0 (chạy ở /tmp).

### 8. ALARM_IO (TEST_ALARM_IO.sh)

- **8.1** mount debugfs, đọc `/sys/kernel/debug/gpio`: mỗi chân **ALARM_IN_PINS** phải là `in` và mức `high`.
- **8.2** (người test) export các GPIO **ALARM_OUT_GPIOS** (nếu chưa), `direction=out`, `echo 0/1` liên tục **ALARM_REPEAT** lần; người test nghe rơ-le "tạch tạch" và trả lời Y/N.
  Xong đưa các ngõ ra về 0 (khôi phục cả khi lỗi/Ctrl-C).

### 9. CAMERA (TEST_CAMERA.sh)

Trước khi chạy (một lần mỗi lần chạy MMI, **chạy ngầm**, kết quả vào `artifacts/lens_focus_calib.txt`): `lens_manage calib zoom`, `calib focus`, `calib iris`
(tắt bằng **CAM_CALIB**=0) rồi `focus-set` **CAM_FOCUS** (50). Vì camera mở có thể đưa lens về 0, focus được đặt **lại sau khi camera đã mở**
(9.1/9.2: sau 2s đầu của pipeline; 9.3: ngay sau khi bật RTSP). Camera chỉ mở được bởi một tiến trình nên RTSP được tắt trước 9.1/9.2.

- **9.1** `gst-launch qtiqmmfsrc ! image/jpeg ! multifilesink` chụp 1080p và 4K (**CAM_RUN_S**), kéo ảnh về PC, `ffprobe` kiểm tra đúng kích thước, mở ảnh cho người test xem (Y/N).
- **9.2** quay H.264 (`v4l2h264enc`, bitrate **CAM_BITRATE**) 1080p30 và 4K30 trong **CAM_VIDEO_RUN_S** giây, `ffprobe` kiểm tra codec h264, kích thước, fps 29-31; mở video cho người test (Y/N).
- **9.3** với mỗi độ phân giải trong **RTSP_TEST_RES**: `rtsp_start` (bật stream, xem mục 10), `rtsp_check` (ffmpeg nhận **RTSP_PROBE_S** giây: codec h264, đúng độ phân giải, fps ≥ **RTSP_MIN_FPS**),
  mở VLC (lỗi → ffplay), hỏi người test (Y/N) khi cửa sổ đang mở, rồi tắt viewer + stream.

### 10. AUDIO (TEST_AUDIO.sh)

- **10.1** `aplay -l` / `arecord -l`: số card phát ≥ **EXPECT_PLAYBACK_DEVS** (2), thu ≥ **EXPECT_CAPTURE_DEVS** (3).
- **10.2** (clusteronly, người test) loa trong WSA: tạo tone 1 kHz trên PC, đẩy `/tmp/mmi_tone.wav`, dừng pipewire, `tinymix` route WSA, `agmplay`; người nghe Y/N.
- **10.3** Line In (AMIC3): PC phát tone 1 kHz (biên độ **AUDIO_LINEIN_AMP**) ra cổng nối sẵn với Line In bằng `ffplay`, thiết bị thu **AUDIO_REC_S** giây bằng `agmcap`.
  PASS khi RMS ≥ **AUDIO_MIN_RMS**, không bị cắt (peak < 32700) và tỷ lệ năng lượng tại 1 kHz ≥ **AUDIO_TONE_MIN_RATIO**; sau đó phát lại bản thu trên PC cho người test (Y/N). **AUDIO_LINEIN_SKIP**=1 để tạm bỏ.
- **10.4** (người test) Line Out: cắm loa, route `tinymix` RX_MACRO/HPH, `agmplay` tone; người nghe Y/N.
- Cả 10.2-10.4 khôi phục pipewire/wireplumber khi kết thúc.

### 11. LENS (TEST_LENS.sh)

Dùng `lens_manage` (`$LENS_BIN`) trên bus **LENS_I2C**. 11.1-11.4 tự bật RTSP + cửa sổ xem (`rtsp_ensure_view`, độ phân giải **LENS_RTSP_W/H**; tắt bằng **LENS_NEED_STREAM**=0).
Mỗi lệnh rc=0, có trễ **LENS_SET_DELAY** trước và nghỉ **LENS_STEP_PAUSE** sau để quan sát; người test xác nhận hình (Y/N).

- **11.1** `calib zoom` → `zoom-set 500 / 100 / 0`. **11.2** `calib focus` → `focus-set 500 / 50 / 0`. **11.3** `calib iris` → `iris-set 100 / 50 / 0`.
- **11.4** `ircut open` → `ircut close` (hết bài tắt RTSP). **11.7** `irled on` → `irled off` (không cần stream).
- **11.5** `lens_manage temp` rc=0 và số trong khoảng -40..125. **11.6** `lens_manage light` rc=0 và có số.

### 12. SENSOR (TEST_SENSOR.sh)

- **12.1** `ssc_sensor_info` chạy được và output có đủ từ khóa trong **SENSOR_EXPECT** (tiêu chí TẠM THỜI).
- **12.2** accel + gyro: `see_workhorse -sensor=<s> -sample_rate=50 -duration=10 -display_events=1`; đủ mẫu `"data": [x, y, z]` (≥ **SENSOR_MIN_EVENTS_IMU**), đủ 3 giá trị, mẫu khác 0 ≥ **SENSOR_NONZERO_PCT**%, mỗi trục có giá trị khác 0.
- **12.3** mag: như 12.2 với 10 Hz, tối thiểu **SENSOR_MIN_EVENTS_MAG** mẫu.
- **12.4** SHT4x đọc qua hwmon sysfs (**SHT4X_HWMON_GLOB**): nhiệt độ -40..125 °C, độ ẩm trong dải 0..110 %RH và cả hai khác 0. **12.5** đọc 3 lần cách nhau 2s, cả 3/3 lần hợp lệ.

## 10. Các cơ chế đặc biệt cần biết

**Stream RTSP (mmi_rtsp.sh)** theo tài liệu QCS6490-CameraBullet-Stream, 2 tiến trình trên thiết bị:
`gst-rtsp-server -p <RTSP_PORT> -a <IP> -m /live "( udpsrc port=8554 ... )"` (server) và
`gst-launch-1.0 -e qtiqmmfsrc ... ! v4l2h264enc (video_bitrate=**RTSP_STREAM_BITRATE**, video_gop_size=**RTSP_GOP**) ! rtph264pay pt=96 ! udpsink host=<IP> port=8554 buffer-size=4194304 sync=false` (nguồn camera).
Trên màn hình, ngay khi bật stream có đếm ngược `VLC mở sau: Ns` (**RTSP_START_WAIT_S**, chỉ để hiển thị, tự tắt khi stream sẵn sàng). Trình xem **RTSP_VIEWER** (vlc mặc định);
VLC lỗi → tự dùng ffplay (**RTSP_VLC_FALLBACK**). Khi không mở được cửa sổ xem, tool lưu `artifacts/rtsp_viewer.log` (user chạy tool, DISPLAY/WAYLAND, vlc/ffplay có cài không, lỗi của player);
**RTSP_VIEWER_DEBUG**=1 để log chi tiết cả khi mở được.

**Reboot thiết bị qua adb (transport_adb.sh `tp_reboot`, gọi từ devinfo.sh)**: thiết bị chỉ reboot được khi gõ lệnh trong shell tương tác, nên tool mở `adb shell -tt` và đưa lệnh vào stdin.
Thử lần lượt `sync; reboot -f` → `reboot` → sysrq `b`; mức sau chỉ chạy khi thiết bị vẫn trả lời adb sau **ADB_REBOOT_STEP_S** giây. Sau đó `devinfo.sh` chờ ping mất (thiết bị thật sự tắt)
rồi `wait_device` (tối đa **REBOOT_WAIT**) và so `boot_id` để chắc chắn thiết bị đã khởi động lại.

**Fix tạm lỗi adbd (transport_adb.sh `_adbd_fix`, trong `tp_wait`)**: nếu thiết bị ping được mà adb không connect (quá **ADBD_FIX_AFTER_S** giây, hoặc hết thời gian chờ), tool ssh vào
(**SSH_USER**/**SSH_PASS**, cần `sshpass`) chạy `systemctl restart android-tools-adbd.service` một lần rồi thử connect lại tối đa **ADBD_FIX_WAIT_S** giây.
Đây là fix tạm: tắt bằng `ADBD_FIX=0`, gỡ hẳn bằng cách xoá các khối nằm giữa `>>> TẠM THỜI` và `<<< hết khối tạm thời`.

**Đếm lùi / thời gian chờ có thể chỉnh**: RTC (**RTC_UNPLUG_S**, **RTC_BOOT_WAIT_S**, **RTC_NTP_WAIT_S**), RTSP (**RTSP_START_WAIT_S**, **RTSP_VIEWER_WAIT_S**), kết nối (**CONNECT_TIMEOUT**, **REBOOT_WAIT**).

**Tham số ghi đè trong config.sh**: config.sh được nạp trước các file test nên giá trị trong mục "THAM SỐ THƯỜNG CHỈNH" luôn thắng mặc định trong file test.
Vẫn có thể đè tạm bằng biến môi trường khi chạy, ví dụ `KEEP_ARTIFACTS=1 ./mmi/run_mmi.sh --all`.