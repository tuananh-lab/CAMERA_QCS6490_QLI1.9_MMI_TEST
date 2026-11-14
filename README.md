# HSP-117 Camera Bullet (QCS6490, QLI 1.9) - MMI TEST

Chạy trên **PC Ubuntu**, kết nối camera qua **adb IP** (mặc định) hoặc **ssh**.
12 nhóm, 46 mục (NVME 3.1-3.3, SD_CARD 6.1-6.3 và 10.2 WSA chỉ chạy khi test cụm hoặc `--case`, không chạy trong `--all`).

## 1. Chạy test (người vận hành)

1. Cấp nguồn camera, nối mạng LAN cùng lớp mạng với PC.
2. Mở tool: `python3 tool.py`, rồi chọn một trong hai cách:
   - Bấm **MMI Test 117**: chạy toàn bộ.
   - Ô **Test Cluster**: bấm mũi tên ▼ để chọn cụm, rồi nhấp đúp vào ô (hoặc Enter) để chạy.
     Các cụm khai báo trong `config.sh`:

     | Cụm          | Nội dung              |
     |--------------|-----------------------|
     | CARRIER-KIMQ | Mạch carrier + KIMQ   |
     | IMAGE-SENSOR | Mạch image sensor     |
     | LED          | LED driver + IR/Laser |

3. Trong terminal: nhập IP camera (gõ số cuối, ví dụ `28` = 192.168.1.28; Enter = IP lần trước),
   rồi quét/nhập **số tem HSPTek** (bắt buộc).
4. Làm theo hướng dẫn trên màn hình. Khi tool hiện khung **▶ CẦN NGƯỜI TEST ĐÁNH GIÁ**:
   nhìn/nghe rồi nhập **Y = ĐẠT** hoặc **N = KHÔNG ĐẠT** (không có phím bỏ qua).
5. Cuối lượt có banner **PASS** (xanh) / **FAIL** (đỏ). Báo cáo nằm trong thư mục `reports/`
   (nút **Open Reports Folder**).

Dòng lệnh:

    ./mmi/run_mmi.sh [--all | --cluster LED | --group RTC,TPM | --case 5.3,7.1 | --heavy | --list | --setup]

Tuỳ chọn thêm: `--transport ssh`, `--ip 28`, `--skip-setup`.
Máy PC mới: `bash setup_pc.sh` (tự kiểm tra/cài adb, iperf3, ffmpeg, vlc, python3-tk...).

## 2. Chuẩn bị trước khi test

| Nhóm       | Cần chuẩn bị                                                                 |
|------------|------------------------------------------------------------------------------|
| 2 ETHERNET | PC cùng mạng với camera (PC tự bật iperf3 server)                            |
| 3 NVME     | Chỉ chạy khi test cụm / `--case`. Lắp NVMe, không có thì mục FAIL            |
| 4 GPS      | Đặt ăng-ten ngoài trời, nhìn thấy bầu trời. Trong nhà 4.2-4.5 sẽ FAIL        |
| 5 RTC      | 5.4/5.5: tool dừng chờ bạn rút/cấp nguồn; 5.5 rút cáp Ethernet trước, cắm lại sau |
| 6 SD_CARD  | Chỉ chạy khi test cụm / `--case`. Cắm thẻ SD, không có thì mục FAIL          |
| 8 ALARM_IO | Đứng gần camera để nghe tiếng rơ-le "tạch tạch"                              |
| 9 CAMERA   | PC có màn hình (tool tự mở VLC xem RTSP). Đặt vật có chi tiết trước ống kính |
| 10 AUDIO   | Line In nối sẵn với cổng ra âm thanh PC (tool tự phát tone 1 kHz); Line Out cắm loa |
| 11 LENS    | Như CAMERA (xem hình qua RTSP). Mỗi lệnh set lens có trễ 1 giây (xem mục 6)  |

## 3. Quy tắc kết quả

- Mỗi mục chỉ **PASS** hoặc **FAIL**. Mục không thực hiện được (thiếu thiết bị/tool, chưa xác nhận,
  mất kết nối) đều tính **FAIL** kèm lý do "Không thực hiện được: ...".
- **5.4/5.5 (rút nguồn)** chạy cùng `--all`; tool dừng chờ người test rút/cấp nguồn rồi nhấn Enter
  (5.5: rút cáp Ethernet trước khi rút nguồn, cắm lại sau khi cấp nguồn). Chạy không có người
  (`MMI_NONINTERACTIVE=1`) thì hai mục này FAIL vì không thực hiện được.
- Bị dừng giữa chừng (Ctrl-C, tắt terminal): tool khôi phục thiết bị và vẫn xuất báo cáo,
  kết luận **INCOMPLETE** (không bao giờ là PASS).
- Mất kết nối quá `CONNECT_TIMEOUT` (10s): mục đang chạy ghi FAIL, dừng test, vẫn xuất báo cáo.
- **Kiểm tra I2C trước**: mục dùng I2C (RTC, SHT4x, Lens, TPM) trước hết dò thiết bị trên bus
  bằng `i2cdetect`. Không thấy thiết bị thì mục FAIL ngay, không chạy tiếp.

| Thiết bị | Bus I2C | Địa chỉ | Các mục     |
|----------|---------|---------|-------------|
| RTC      | i2c-1   | 0x51    | 5.1 - 5.6   |
| SHT4x    | i2c-1   | 0x44    | 12.4, 12.5  |
| Lens     | i2c-1   | 0x1c    | 11.1 - 11.7 |
| TPM      | i2c-13  | 0x2e    | 7.1, 7.2    |

- **Device ID** của báo cáo = Serial (`getprop ro.serialno`). Chưa có Serial thì dùng **MAC ethernet**
  (không dấu `:`, viết hoa). Chip ID / Serial trống không phải lỗi khi đọc thông tin thiết bị.

### Tiêu chí PASS nhóm Sensor (12)

Mỗi sensor có kiểu dữ liệu riêng, tool kiểm tra dữ liệu **khác 0**:

| Mục  | Dữ liệu                | Điều kiện PASS                                                                              |
|------|------------------------|---------------------------------------------------------------------------------------------|
| 12.1 | ssc_sensor_info        | Có đủ từ khóa trong SENSOR_EXPECT (tạm thời)                                                |
| 12.2 | accel, gyro: [x, y, z] | Đủ mẫu (SENSOR_MIN_EVENTS_IMU), đủ 3 giá trị, mẫu khác 0 >= 90%, mỗi trục có giá trị khác 0 |
| 12.3 | mag: [x, y, z]         | Như 12.2, số mẫu tối thiểu SENSOR_MIN_EVENTS_MAG                                            |
| 12.4 | SHT4x: nhiệt độ, độ ẩm | Trong dải (-40..125 °C, 0..110 %RH) và cả hai khác 0                                        |
| 12.5 | SHT4x đọc 3 lần        | Cả 3/3 lần đều hợp lệ như 12.4                                                              |

## 4. Tra lỗi

Mỗi thiết bị chỉ có **một thư mục** `reports/<tên>/`
(`<tên>` = `HSP-117_<tem>_<DEVICE ID>_<giờ>[_<CỤM>]_<PASS|FAIL|INCOMPLETE>`). Lần test tạo 3 file cùng tên:

- `<tên>.html`: báo cáo gửi đi/lưu trữ (kết quả theo thứ tự thực thi + log chi tiết).
- `<tên>.log`: log đầy đủ (gồm câu trả lời Y/N của người test). Cuối file có **PHỤ LỤC** dữ liệu thô
  từng mục, tìm theo `### artifacts/<tên file>`; ảnh/video/wav không lưu.
- `<tên>.csv`: bảng kết quả từng mục (UTF-8, mở được bằng Excel).

Sau đó Read Chip ID, Write Serial, Write MAC, Reboot ghi log **vào cùng thư mục** (tool nhận ra đúng thiết bị
bằng Chip ID hoặc MAC):

| File              | Nội dung                                                                 |
|-------------------|--------------------------------------------------------------------------|
| deviceinfo.log    | Log đầy đủ, nối tiếp, có giờ (getprop, boot_id, hexdump devinfo, EEPROM) |
| devinfo_log.csv   | Tóm tắt Read / Write Serial / Reboot dạng bảng                           |
| mac_write_log.csv | Tóm tắt mỗi lần ghi MAC                                                  |
| gui_last_run.log  | Output thô của lần Read / Reboot gần nhất trên giao diện (tool.py)       |

Quy trình sản xuất: test cụm/full → Write Serial, Write MAC → Read lại → Reboot: tất cả nằm trong một thư mục.
Đọc/ghi thông tin trước khi test: tool tạo thư mục `*_DEVINFO`, lần test sau của thiết bị đó dùng lại và đổi tên
theo kết quả. Tool chỉ nhớ thiết bị test gần nhất (`reports/.last_run`), nên làm trọn một thiết bị rồi mới sang
thiết bị khác. Không kết nối được thiết bị thì không có log nào được ghi (lỗi hiện trên màn hình).

Khi ghi serial/MAC không ăn, gửi file `deviceinfo.log` để tra nguyên nhân.

## 5. An toàn dữ liệu / thiết bị

- Các thay đổi trên thiết bị (giờ hệ thống + RTC, GPIO alarm, pipewire, RTSP, iperf3 server)
  đều được khôi phục khi kết thúc hoặc Ctrl-C. Riêng 5.4/5.5 tạm tắt dịch vụ đồng bộ giờ
  (timesyncd/chronyd/ntpd, danh sách ghi ở `/etc/mmi_ntp_svcs`) và bật lại sau khi đọc xong;
  nếu bị ngắt giữa chừng, lần chạy RTC kế tiếp tự bật lại.
- **NVMe/SD (3.2, 3.3, 6.2, 6.3):** nếu phân vùng đang mount thì đo bằng file tạm (an toàn).
  Nếu **không mount** thì **ghi/đọc thô trực tiếp thiết bị** (ghi thô sẽ xoá dữ liệu/bảng phân vùng
  ở đầu đĩa). Chỉ dùng với ổ trắng/ổ test.
- Lens: `lens_manage calib` làm ống kính chạy hết hành trình, bình thường.

## 6. Cấu hình

Tất cả trong `config.sh`. Các nhóm biến chính:

- Cụm test: `CLUSTERS`, `CLUSTER_*`. Thứ tự nhóm: `TEST_GROUPS_ALL`. Kết nối: `IP_PREFIX`, `CONNECT_TIMEOUT`.
- Ngưỡng: iperf, COM, RTC, GPS (`IPERF_*`, `RTC_*`, `GPS_*`...).
- Báo cáo: `REPORT_ROOT` (thư mục test), `LOG_DIR` (log thông tin thiết bị).
- Kiểm tra I2C: bảng `I2C_GATES` (tên | bus | địa chỉ | các mục).
- Sensor: `SENSOR_EXPECT`, `SENSOR_MIN_EVENTS_IMU`, `SENSOR_MIN_EVENTS_MAG`, `SENSOR_NONZERO_PCT`.
- Xem stream RTSP: `RTSP_*`. Trình xem `RTSP_VIEWER` = vlc (mặc định) | ffplay | auto | none.
  VLC dùng cache `RTSP_VLC_CACHE_MS` (mặc định 100 ms). VLC lỗi hoặc thoát ngay thì tự chuyển sang
  ffplay (`RTSP_VLC_FALLBACK=1`). VLC bị đơ giữa chừng: đặt `RTSP_VIEWER=ffplay`.
- Lens: `LENS_*`. `LENS_SET_DELAY` (mặc định 1 s) chờ trước mỗi lệnh lens_manage;
  `LENS_STEP_PAUSE` (mặc định 2 s) nghỉ sau mỗi lệnh để quan sát.

Biến môi trường:

| Biến                 | Tác dụng                           |
|----------------------|------------------------------------|
| HSP_ID               | Bỏ qua bước hỏi số tem             |
| HSP_ID_REQUIRED=0    | Cho Enter bỏ qua số tem            |
| MMI_NONINTERACTIVE=1 | Mục cần người test → FAIL          |
| CONN_GUARD=0         | Tắt kiểm tra kết nối trước mỗi mục |
| LENS_NEED_STREAM=0   | Bài Lens không tự bật RTSP         |

Tiêu chí 12.1 (ssc_sensor_info) là **TẠM THỜI**, chỉnh theo output thật bằng `SENSOR_EXPECT`.

## 7. Cấu trúc & viết thêm test

    config.sh            cấu hình duy nhất
    tool.py              giao diện (tkinter)
    setup_pc.sh          kiểm tra/cài tool trên PC
    mmi/run_mmi.sh       điều phối
    mmi/lib/             mmi_lib.sh (dev_*, tc_*, ask_yn, i2c_gate), report.sh, html_report.py,
                         transport_adb.sh / transport_ssh.sh, mmi_rtsp.sh
    mmi/tests/           TEST_<NHÓM>.sh, mỗi nhóm một file
    reports/             kết quả (không đưa vào gói bàn giao)

Mỗi file nhóm có `CASES_<NHÓM>=( "id|tên|cờ" )` và hàm `case_<id>` (dấu chấm → gạch dưới), ví dụ:

    case_5_2() {
      tc_need hwclock || return 0
      local out rc; out="$(dev_sh "hwclock -r 2>&1")"; rc=$?
      [ $rc -eq 0 ] && tc_pass "RTC: $out" || tc_fail "rc=$rc: $out"
    }

- Mỗi hàm gọi đúng một `tc_pass/tc_fail` (`tc_skip`/`tc_todo` cũng ghi FAIL).
  Không gọi adb/ssh trực tiếp, chỉ dùng `dev_*`.
- Nhiều dòng lệnh: `dev_script [-t giây] [VAR=giá_trị] <<'EOF' ... EOF`.
  Cần người đánh giá: `tc_manual "câu hỏi?"`.
- Thay đổi hệ thống phải đăng ký khôi phục: `on_cleanup '...'`. Dọn theo nhóm: hàm `teardown_<NHÓM>()`.
- Cờ: `manual` (cần người), `heavy`/`power` (chỉ chạy khi `--case` hoặc `--heavy`).
- Mục dùng I2C: thêm id vào dòng tương ứng trong `I2C_GATES` (config.sh).
- Đổi adb ↔ ssh: biến `TRANSPORT`; driver cùng giao diện
  `tp_init tp_ready tp_wait tp_exec tp_exec_live tp_pull tp_push tp_close`.

## 8. Ghi MAC

Nhập MAC (ví dụ `74:25:84:C0:0F:06`) vào ô **MAC** → **Write MAC** → xác nhận.
Hoặc: `./mmi/run_mmi.sh --write-mac 74:25:84:C0:0F:06`.

Luồng (`mmi/lib/mac_write.sh`):

1. Tạo file bin 254 byte từ **file mẫu** `mmi/mac/template.bin` (thay MAC, tự dò kiểu lưu).
2. Push vào `/data/<MAC>`.
3. `ethtool -E eth0 magic 0x78A5 offset 0 length 254 < /data/<MAC>`.
4. Đọc lại EEPROM để so sánh.
5. **Reboot** rồi kiểm tra `eth0` đã đúng MAC mới.

Ghi chú:

- Kết quả mỗi lần ghi nằm trong `mac_write_log.csv` trong thư mục của thiết bị (mục 4).
- Cần có `mmi/mac/template.bin` (file MAC 254 byte đang dùng được) và `MAC_TEMPLATE_MAC` trong
  `config.sh` = MAC nằm trong file đó.
- Kiểm tra "chỉ cần thay MAC" bằng 2 file thật:
  `python3 mmi/lib/mac_bin.py verify mmi/mac/template.bin <MAC mẫu> <file khác.bin> <MAC file khác>`.
- Đổi MAC có thể làm đổi IP (DHCP): nếu sau reboot không kết nối lại được, tool báo
  "đã ghi, chưa kiểm tra được"; tìm IP mới rồi kiểm tra `cat /sys/class/net/eth0/address`.
- Không reboot tự động: `MAC_REBOOT_AFTER=0`.
- Log đọc/ghi thông tin thiết bị xem mục 4.