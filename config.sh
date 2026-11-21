#!/bin/bash
# =============================================================================
#  CONFIG - HSP-117 Camera Bullet (QCS6490, QLI 1.9)
#  Mọi biến có thể override bằng biến môi trường, ví dụ:
#      TRANSPORT=ssh DEVICE_IP=192.168.1.249 ./mmi/run_mmi.sh --all
# =============================================================================
CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PRODUCT_NAME="Camera Bullet QCS6490 QLI1.9"
PRODUCT_CODE="HSP-117"

# ---- Kiểu kết nối: adb (mặc định) hoặc ssh -----------------------------------
: "${TRANSPORT:=adb}"
: "${DEVICE_IP:=192.168.1.53}"    # IP tĩnh của thiết bị: đổi ở đây
IP_PREFIX="192.168.1."             # Cho phép gõ tắt: nhập "249" => 192.168.1.249
LAST_IP_FILE="$CFG_DIR/.last_ip"
: "${CONNECT_TIMEOUT:=10}"          # Quá số giây này mà không kết nối được thiết bị => báo lỗi (adb/ssh)
: "${REBOOT_WAIT:=90}"            # Chờ tối đa khi thiết bị khởi động lại (giây)

# adb
: "${ADB_BIN:=}"                   # Để trống = tìm adb trong PATH
: "${ADB_PORT:=5555}"
# ssh
: "${SSH_PORT:=22}"
: "${SSH_USER:=root}"
: "${SSH_PASS=oelinux123}"         # Mật khẩu mặc định theo tài liệu test. Đặt rỗng nếu dùng key

# ---- Thư mục trên thiết bị (push/pull ở /tmp: tmpfs, không cần remount) -------
REMOTE_TMP="/tmp"

# ---- Định danh thiết bị ----------------------------------------------------------------------
# Device ID của báo cáo = SERIAL (getprop ro.serialno). Quy trình: Read Chip ID -> Write Serial -> Write MAC -> Reboot Device
# -> kiểm tra Serial/MAC hiện "OK - matches" -> mới chạy test.
# Chưa có serial hợp lệ => Device ID = MAC ethernet (không dấu ":"). Chỉ khi cũng không đọc được MAC mới xét DEVID_REQUIRED:
# DEVID_REQUIRED=1: KHÔNG chạy test (0 = cho chạy, Device ID = unknown).
: "${DEVID_REQUIRED:=0}"
# MAC_IFACE chỉ dùng để ĐỌC/GHI MAC (không còn là Device ID). Để trống = tự dò trên thiết bị (thử lần lượt MAC_IFACE_CANDIDATES).
# Đặt cứng khi cần:  MAC_IFACE=enu1u1 ./mmi/run_mmi.sh --write-mac <MAC>
: "${MAC_IFACE:=}"
: "${MAC_IFACE_CANDIDATES:=enu1u1 eth0}"

# ---- Báo cáo -------------------------------------------------------------------
REPORT_ROOT="$CFG_DIR/reports"                 # mỗi lần test = 1 thư mục con reports/<tên>/
# LOG_DIR = thư mục chứa log thông tin thiết bị (deviceinfo.log, devinfo_log.csv, mac_write_log.csv, gui_last_run.log).
# Khi Read/Write Serial/Write MAC/Reboot chạy, run_mmi.sh tự đặt LOG_DIR = thư mục lần test của CHÍNH thiết bị đó
# (reports/<tên lần test>/), nên mỗi thiết bị chỉ có 1 thư mục. Giá trị dưới đây chỉ là mặc định.
LOG_DIR="$REPORT_ROOT"

# ---- Thứ tự nhóm test (theo tài liệu test 117) ---------------------------------
TEST_GROUPS_ALL="COM ETHERNET NVME GPS RTC SD_CARD TPM ALARM_IO CAMERA AUDIO LENS SENSOR"

# ---- Tham số / ngưỡng (chốt dần theo từng test case) ---------------------------
: "${IPERF_PORT:=5201}"
: "${IPERF_TIME:=10}"                      # giây mỗi lần đo iperf3
: "${IPERF_MIN_MBPS:=900}"                 # yêu cầu: Bitrate > 900 Mbps
: "${TPM_I2C_BUS:=13}"
: "${SHT4X_HWMON_GLOB:=/sys/bus/i2c/devices/1-0044/hwmon/hwmon*}"
: "${SENSOR_EXPECT:=accel gyro mag}"       # TẠM THỜI: từ khóa phải có trong ssc_sensor_info (chỉnh theo output thật)
: "${SENSOR_MIN_EVENTS_IMU:=250}"          # accel/gyro 50Hz x 10s = 500 mẫu danh định: cần tối thiểu số mẫu "data" này
: "${SENSOR_MIN_EVENTS_MAG:=50}"           # mag 10Hz x 10s = 100 mẫu danh định: cần tối thiểu số mẫu này
: "${SENSOR_NONZERO_PCT:=90}"             # % mẫu phải có ít nhất 1 giá trị khác 0 (và mỗi trục phải có giá trị khác 0 ít nhất 1 lần)
: "${EXPECT_PLAYBACK_DEVS:=2}"             # aplay -l  (quan sát trên thiết bị)
: "${EXPECT_CAPTURE_DEVS:=3}"              # arecord -l
: "${GPS_TTY:=/dev/ttyHS1}"
: "${LENS_I2C:=/dev/i2c-1}"

# ---- Kiểm tra I2C TRƯỚC khi test (i2cdetect -y -r <bus> <addr> <addr>): "UU" hoặc địa chỉ hiện ra = có, "--" = không có => mục FAIL ----
# Định dạng: "TÊN|bus|địa_chỉ_hex|các mục cần thiết bị này". Thiếu thiết bị trên I2C thì các mục liệt kê không chạy mà ghi FAIL ngay.
I2C_GATES=(
  "RTC|1|51|5.1 5.2 5.3 5.4 5.5 5.6"
  "SHT4x|1|44|12.4 12.5"
  "LENS|1|1c|11.1 11.2 11.3 11.4 11.5 11.6 11.7"
  "TPM|13|2e|7.1 7.2"
)

# ---- RTSP (dùng cho 9.3 và các bài Lens cần xem hình) --------------------------
: "${RTSP_PORT:=8900}"                  # cổng RTSP (gst-rtsp-server -p)
: "${RTSP_UDP_PORT:=8554}"              # cổng UDP nội bộ: gst-launch (udpsink) -> gst-rtsp-server (udpsrc)
: "${RTSP_MOUNT:=/live}"                 # URL: rtsp://<IP>:<RTSP_PORT><RTSP_MOUNT>
: "${RTSP_BITRATE:=6000000}"                # (không còn dùng cho stream: xem RTSP_STREAM_BITRATE bên dưới)
: "${RTSP_TEST_RES:=1920x1080 3840x2160}"  # 9.3: các độ phân giải cần kiểm tra
: "${RTSP_PROBE_S:=6}"                   # 9.3: thời gian nhận stream để đếm frame (giây)
: "${RTSP_MIN_FPS:=25}"                  # 9.3: fps tối thiểu đo được (stream 30fps)
: "${RTSP_START_TIMEOUT:=20}"            # chờ gst-rtsp-server mở cổng (giây)
: "${RTSP_VIEWER:=vlc}"                  # vlc (mặc định) | ffplay | auto | none  (VLC đơ/lỗi: đặt ffplay)
: "${RTSP_VLC_CACHE_MS:=100}"           # VLC network/live caching (ms): 100 = 0,1s (mặc định VLC 1000)
: "${RTSP_VLC_FALLBACK:=1}"             # 1 = VLC không mở được / thoát ngay => tự dùng ffplay
: "${LENS_RTSP_W:=1920}"                 # Lens: độ phân giải stream dùng để quan sát
: "${LENS_RTSP_H:=1080}"
: "${LENS_NEED_STREAM:=1}"               # 1 = bài Lens tự bật RTSP + cửa sổ xem

# ---- CỤM test theo "Quy trình test cụm mạch Bullet Camera" (tool.py: chọn cụm rồi chạy => run_mmi.sh --cluster <TÊN>) ----
# Nhóm A (Power) test riêng bằng đồng hồ, KHÔNG nằm trong MMI. MMI chỉ chạy cụm B, C, D lắp vào bộ golden.
# Tên cụm viết hoa, dấu '-' => '_' khi đặt biến. Hai cách khai báo:
#   CLUSTER_<TÊN>="NHÓM1 NHÓM2"        : chạy cả nhóm (tên nhóm trong TEST_GROUPS_ALL)
#   CLUSTER_<TÊN>_CASES="9.1 11.7"     : chạy đúng các mục này (dùng khi một nhóm bị chia cho 2 cụm)
CLUSTERS="CARRIER-KIMQ IMAGE-SENSOR LED"

# Test CỤM (mạch rời, chưa lắp mockup): chỉ mức "nhận", theo tài liệu test cụm
CLUSTER_CARRIER_KIMQ_CASES="1.1 1.2 1.3 2.1 2.2 3.1 4.1 5.1 5.2 5.3 6.1 7.1 8.1 8.2 10.1 10.2 10.3 10.4 12.1 12.2 12.3 12.4 12.5"
CLUSTER_IMAGE_SENSOR_CASES="9.1 9.3 11.1 11.2 11.3 11.4 11.5 11.6"
CLUSTER_LED_CASES="11.7"                                                             # D: LED driver + IR/Laser

# ---- Ghi MAC (run_mmi.sh --write-mac <MAC>, xem mmi/lib/mac_write.sh) ----------------------
# Interface dùng để ghi/đọc MAC lấy từ MAC_IFACE (tự dò ở trên)
: "${MAC_EEPROM_MAGIC:=0x78A5}"          # ethtool -E ... magic <giá trị>
: "${MAC_EEPROM_LEN:=254}"               # độ dài file bin (byte)
: "${MAC_DEV_DIR:=/tmp}"                 # thư mục trên thiết bị để push file bin
: "${MAC_TEMPLATE_MAC:=742584C00F06}"    # MAC nằm trong file mẫu mmi/mac/template.bin
: "${MAC_REBOOT_AFTER:=0}"               # 1 = reboot sau khi ghi rồi kiểm tra lại MAC


# =============================================================================
#  THAM SỐ THƯỜNG CHỈNH - giá trị ở đây GHI ĐÈ giá trị mặc định nằm trong các file test/lib
#  (config.sh được nạp TRƯỚC các file đó, nên chỉ cần sửa số ở đây, không phải sửa file test).
#  Vẫn có thể đè tạm bằng biến môi trường khi chạy:  KEEP_ARTIFACTS=1 ./mmi/run_mmi.sh --all
#  Các dòng bắt đầu bằng "# :" là tham số tham khảo (đang dùng mặc định trong file test): bỏ dấu "# " đầu dòng để ghi đè.
# =============================================================================

# ---- Gỡ lỗi / báo cáo --------------------------------------------------------------------------
: "${KEEP_ARTIFACTS:=0}"             # 1 = GIỮ thư mục artifacts/ (log thô từng mục: gst, rtsp, ffmpeg, lens, rtsp_viewer.log...) trong reports/<tên>/artifacts
: "${RTSP_VIEWER_DEBUG:=0}"          # 1 = VLC/ffplay ghi log chi tiết vào artifacts/rtsp_viewer.log (kể cả khi mở được); khi mở LỖI luôn có log này
: "${MMI_OPEN_REPORT:=1}"            # 1 = chạy xong tự mở trang HTML kết quả

# ---- Kết nối adb / reboot ------------------------------------------------------------------------
# (REBOOT_WAIT, CONNECT_TIMEOUT: xem phần đầu file)
: "${ADB_REBOOT_STEP_S:=12}"         # reboot qua adb: mỗi mức lệnh (sync;reboot -f -> reboot -> sysrq) chờ tối đa số giây này xem thiết bị đã tắt chưa
: "${ADBD_FIX:=1}"                   # 1 = FIX TẠM lỗi adbd: ping được mà adb không connect => ssh restart android-tools-adbd.service. 0 = tắt
: "${ADBD_FIX_AFTER_S:=10}"          # ping được quá số giây này mà adb vẫn không connect => chạy fix
: "${ADBD_FIX_WAIT_S:=30}"           # sau khi restart adbd: thử adb connect lại tối đa số giây này

# ---- 2. Ethernet -------------------------------------------------------------------------------------
: "${IPERF_BIDIR_MIN_MBPS:=800}"     # 2.3 --bidir: mỗi chiều phải > số Mbps này

# ---- 5. RTC ----------------------------------------------------------------------------------------------
: "${RTC_TOL_S:=5}"                  # 5.3: lệch tối đa giữa giờ đặt và giờ đọc lại (giây)
: "${TIME_TOL_S:=60}"                # 5.4-5.6: lệch tối đa so với giờ mong đợi (giây)
: "${RTC_OFF_MIN_S:=20}"             # 5.4-5.5: thời gian mất nguồn tối thiểu (giây; tool đo = đếm lùi + ~6s)
: "${RTC_UNPLUG_S:=20}"              # 5.4-5.5: đếm lùi sau khi nhắc RÚT NGUỒN (nên >= RTC_OFF_MIN_S)
: "${RTC_BOOT_WAIT_S:=30}"           # 5.5: đếm lùi chờ thiết bị boot rồi mới nhắc cắm lại Ethernet
: "${RTC_NTP_WAIT_S:=60}"            # 5.6: chờ tối đa NTP kéo giờ về đúng (giây)
: "${RTC_SET_TIME:=2026-01-27 08:49:00}"   # 5.4-5.5: giờ (UTC) đặt cho RTC trước khi rút nguồn

# ---- 9. Camera / RTSP --------------------------------------------------------------------------------
: "${CAM_RUN_S:=5}"                  # 9.1: thời gian chụp (giây)
: "${CAM_VIDEO_RUN_S:=10}"           # 9.2: thời gian quay video (giây)
: "${CAM_BITRATE:=6000000}"          # 9.2: bitrate quay video
: "${CAM_FOCUS:=50}"                 # giá trị focus đặt trước và sau khi mở camera (lens_manage focus-set <giá trị>)
: "${CAM_CALIB:=1}"                  # 1 = calib zoom, focus, iris (1 lần/lần chạy) rồi mới đặt focus; 0 = chỉ đặt focus
: "${LENS_CALIB_TIMEOUT:=180}"       # timeout mỗi lệnh lens_manage calib (giây)
: "${RTSP_STREAM_BITRATE:=4000000}"  # 9.3: video_bitrate của stream RTSP
: "${RTSP_GOP:=30}"                  # 9.3: video_gop_size
: "${RTSP_START_WAIT_S:=15}"         # 9.3: số giây đếm ngược "VLC mở sau" (chỉ để hiển thị)
: "${RTSP_VIEWER_WAIT_S:=2}"         # 9.3: chờ ngầm sau khi mở VLC/ffplay để biết có chạy được không (giây)

# ---- 10. Audio ---------------------------------------------------------------------------------------------
: "${AUDIO_REC_S:=5}"                # thời gian thu âm (giây)
: "${AUDIO_MIN_RMS:=20}"             # RMS tối thiểu của file thu (thang 16-bit)
: "${AUDIO_TONE_MIN_RATIO:=0.3}"     # 10.3: tỷ lệ năng lượng tại 1 kHz / tổng (1.0 = tone sạch)
: "${AUDIO_LINEIN_AMP:=3000}"        # 10.3: biên độ tone PC phát vào Line In (tối đa 32767; nhỏ hơn = đỡ to)
: "${AUDIO_LINEIN_SKIP:=0}"          # 1 = tạm bỏ test Line In (10.3 ghi SKIP)
# : "${AUDIO_WAV:=}"                 # dùng file wav riêng thay cho tone tự tạo (48 kHz, 16-bit, stereo)

# ---- Tham khảo: tham số của các test khác (hiện dùng mặc định trong file test; bỏ "# " để ghi đè) ----
# : "${COM_CPU_CORES:=8}"
# : "${COM_RAM_TOTAL_MIN_GIB:=7.2}"
# : "${COM_RAM_FREE_MIN_GIB:=5}"
# : "${COM_DISK_DEV:=sda}"
# : "${COM_DISK_MIN_GIB:=115}"
# : "${GPS_CAPTURE_S:=15}"
# : "${GPS_MIN_REPEAT:=2}"
# : "${ALARM_IN_PINS:=56 88}"
# : "${ALARM_OUT_GPIOS:=670 668}"
# : "${ALARM_REPEAT:=3}"
# : "${NVME_DEV:=/dev/nvme0n1}"
# : "${NVME_FIO_SIZE:=2G}"
# : "${NVME_MIN_WRITE_MBPS:=}"
# : "${NVME_MIN_READ_MBPS:=}"
# : "${SD_FIO_SIZE:=128M}"
# : "${SD_MIN_WRITE_MBPS:=}"
# : "${SD_MIN_READ_MBPS:=}"
# : "${LENS_SET_DELAY:=1}"
# : "${LENS_STEP_PAUSE:=2}"
# : "${SERIAL_MAXLEN:=32}"
# : "${DEVINFO_REBOOT_AFTER:=0}"