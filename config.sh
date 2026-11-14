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
: "${DEVICE_IP:=192.168.1.249}"    # IP tĩnh của thiết bị: đổi ở đây
IP_PREFIX="192.168.1."             # Cho phép gõ tắt: nhập "249" => 192.168.1.249
LAST_IP_FILE="$CFG_DIR/.last_ip"
: "${CONNECT_TIMEOUT:=10}"          # Quá số giây này mà không kết nối được thiết bị => báo lỗi (adb/ssh)
: "${REBOOT_WAIT:=180}"            # Chờ tối đa khi thiết bị khởi động lại (giây)

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
: "${RTSP_BITRATE:=6000000}"
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