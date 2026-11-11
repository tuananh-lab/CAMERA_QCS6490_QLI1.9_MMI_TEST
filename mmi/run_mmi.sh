#!/bin/bash
# =============================================================================
#  run_mmi.sh - điều phối bộ test MMI HSP-117 (chạy trên PC)
#
#    ./mmi/run_mmi.sh                    menu chọn nhóm
#    ./mmi/run_mmi.sh --all              chạy toàn bộ (bỏ qua mục nặng / rút nguồn)
#    ./mmi/run_mmi.sh --group RTC,TPM    chạy theo nhóm
#    ./mmi/run_mmi.sh --write-mac 74:25:84:C0:0F:06   ghi MAC vào thiết bị (xem mmi/lib/mac_write.sh)
#    ./mmi/run_mmi.sh --read-id          đọc Chip ID (ro.chipid), Serial (ro.serialno), MAC (xem mmi/lib/devinfo.sh)
#    ./mmi/run_mmi.sh --write-serial ABC12345   ghi Serial vào partition devinfo (cần reboot để áp dụng)
#    ./mmi/run_mmi.sh --reboot           reboot thiết bị, chờ lên lại, in lại Chip ID / Serial / MAC
#    ./mmi/run_mmi.sh --cluster LED      chạy theo cụm (CARRIER-KIMQ | IMAGE-SENSOR | LED, xem config.sh)
#    ./mmi/run_mmi.sh --case 5.3,7.1     chạy mục lẻ (kể cả mục nặng / rút nguồn)
#    ./mmi/run_mmi.sh --heavy --all      chạy luôn các mục nặng / rút nguồn
#    ./mmi/run_mmi.sh --list             liệt kê nhóm và mục
#    ./mmi/run_mmi.sh --setup            kiểm tra / cài tool trên PC (setup_pc.sh) rồi thoát
#    Tuỳ chọn: --ip <IP|số cuối>  --transport adb|ssh  --skip-setup
#    Biến môi trường: DEVICE_IP TRANSPORT SSH_PASS MMI_NONINTERACTIVE=1 MMI_PAUSE_END=1 CONNECT_TIMEOUT=10
# =============================================================================
MMI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL_DIR="$(cd "$MMI_DIR/.." && pwd)"

. "$TOOL_DIR/config.sh"
. "$MMI_DIR/lib/mmi_lib.sh"
. "$MMI_DIR/lib/report.sh"
. "$MMI_DIR/lib/mmi_rtsp.sh"
CONN_LOST=0

read -ra ALL_GROUPS <<< "$TEST_GROUPS_ALL"
MMI_TMP="$(mktemp -d /tmp/mmi.XXXXXX)"
# Thoát bình thường / Ctrl-C / lỗi: khôi phục thiết bị; nếu đang chạy dở thì vẫn xuất báo cáo (INCOMPLETE)
ABORTED=0; REPORT_READY=0; REPORT_DONE=0; PAUSED=0
on_exit() {
  run_cleanups
  if [ "$REPORT_READY" = 1 ] && [ "$REPORT_DONE" != 1 ]; then ABORTED=1; finish_report; fi
  command -v tp_close >/dev/null && tp_close
  rm -rf "$MMI_TMP"
  # Chạy từ tool.py (MMI_PAUSE_END=1): luôn chờ Enter để người vận hành đọc kết quả/lỗi trước khi terminal đóng
  if [ "${MMI_PAUSE_END:-0}" = 1 ] && [ "$PAUSED" != 1 ]; then
    PAUSED=1
    if (exec </dev/tty) 2>/dev/null; then echo; printf 'Nhấn Enter để đóng...'; read -r _ </dev/tty; fi
  fi
}
trap on_exit EXIT
trap 'echo; echo "Bị dừng (Ctrl-C/TERM) - đang khôi phục thiết bị và lưu báo cáo..."; exit 130' INT TERM

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,2\}//'; }

# ---- Nạp toàn bộ file test ------------------------------------------------------
for g in "${ALL_GROUPS[@]}"; do
  f="$MMI_DIR/tests/TEST_$g.sh"
  [ -f "$f" ] && . "$f" || echo "CẢNH BÁO: thiếu $f"
done

list_cases() {
  local g entry id name flags
  for g in "${ALL_GROUPS[@]}"; do
    declare -n arr="CASES_$g"
    echo "[$g]"
    for entry in "${arr[@]}"; do
      IFS='|' read -r id name flags <<< "$entry"
      printf '   %-5s %-55s %s\n' "$id" "$name" "${flags:+($flags)}"
    done
    unset -n arr
  done
}

prompt_ip() {
  local last="" ans
  [ -f "$LAST_IP_FILE" ] && last="$(cat "$LAST_IP_FILE" 2>/dev/null)"
  while true; do
    read -r -p "Nhập IP thiết bị (hoặc số cuối của ${IP_PREFIX}x)${last:+ [Enter = $last]}: " ans
    ans="${ans:-$last}"
    [[ "$ans" =~ ^[0-9]{1,3}$ ]] && ans="${IP_PREFIX}${ans}"
    [[ "$ans" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    echo "IP không hợp lệ."
  done
  DEVICE_IP="$ans"
}

# ---- Kiểm tra / cài tool trên PC (setup_pc.sh) --------------------------------------
pc_tools_check() {
  [ "${MMI_SKIP_PC_CHECK:-0}" = 1 ] && return 0
  TRANSPORT="$TRANSPORT" bash "$TOOL_DIR/setup_pc.sh" --check --quiet && return 0
  say "${C_Y}Thiếu tool bắt buộc trên PC (liệt kê ở trên).${C_0}"
  if [ "${MMI_NONINTERACTIVE:-0}" = 1 ]; then die "Chạy: bash $TOOL_DIR/setup_pc.sh --yes"; fi
  local a
  read -r -p "Cài đặt tự động ngay bằng apt (cần sudo)? [Y/n] " a </dev/tty
  case "${a:-y}" in n|N) die "Chưa đủ tool trên PC. Chạy: bash $TOOL_DIR/setup_pc.sh" ;; esac
  TRANSPORT="$TRANSPORT" bash "$TOOL_DIR/setup_pc.sh" --yes || die "Cài tool trên PC chưa thành công."
  TRANSPORT="$TRANSPORT" bash "$TOOL_DIR/setup_pc.sh" --check --quiet || die "Vẫn thiếu tool trên PC."
}

# ---- Kiểm tra kết nối còn sống trước mỗi mục (mất quá CONNECT_TIMEOUT giây => dừng và báo lỗi) ----
conn_guard() {
  tp_ready 5 && return 0
  say "${C_Y}  Thiết bị không trả lời, thử kết nối lại (tối đa ${CONNECT_TIMEOUT}s)...${C_0}"
  wait_device "$CONNECT_TIMEOUT"
}

# ---- Precheck: kiểm kê tool (không tính vào kết quả) ------------------------------
precheck() {
  say "${C_B}===== PRECHECK =====${C_0}"
  say "Thiết bị : $(tp_describe)   ID: $DEV_ID   uid=$(dev_val 'id -u')"
  local inv="$REPORT_DIR/tool_inventory.txt" t
  : > "$inv"
  for t in iperf3 fio lspci hwclock timedatectl i2cdetect tpm2_getcap tpm2_pcrread tpm2_hash \
           tpm2_selftest tpm2_getrandom tinymix agmplay agmcap aplay arecord see_workhorse \
           ssc_sensor_info gst-launch-1.0 gst-rtsp-server python3 sha1sum pgrep; do
    if dev_has "$t"; then echo "OK $t" >> "$inv"; else echo "MISSING $t" >> "$inv"; fi
  done
  # lens_manage: ưu tiên PATH (/usr/bin sau này), rồi /lens_manage
  LENS_BIN="$(dev_val 'command -v lens_manage || { [ -x /lens_manage ] && echo /lens_manage; }' | head -n 1)"
  if [ -n "$LENS_BIN" ]; then echo "OK lens_manage ($LENS_BIN)" >> "$inv"; else echo "MISSING lens_manage" >> "$inv"; fi

  say "Tool trên thiết bị:"
  while read -r s n; do
    [ "$s" = OK ] && say "  ${C_G}OK${C_0}       $n" || say "  ${C_Y}MISSING${C_0}  $n"
  done < "$inv"
  say "Tool trên PC:"
  local pc_tools="adb iperf3 ffmpeg ffprobe ffplay vlc"
  [ "$TRANSPORT" = ssh ] && pc_tools="$pc_tools ssh sshpass"
  for t in $pc_tools; do
    command -v "$t" >/dev/null && say "  ${C_G}OK${C_0}       $t" || say "  ${C_Y}MISSING${C_0}  $t"
  done
  say ""
}

# ---- Chạy một nhóm -----------------------------------------------------------------
want_case() {   # có chọn mục này không?
  [ ${#CASE_FILTER[@]} -eq 0 ] && return 0
  local c; for c in "${CASE_FILTER[@]}"; do [ "$c" = "$1" ] && return 0; done
  return 1
}

run_group() {
  local g="$1" entry id name flags fn before after shown=0
  CUR_GROUP="$g"
  declare -n arr="CASES_$g"
  for entry in "${arr[@]}"; do
    IFS='|' read -r id name flags <<< "$entry"
    want_case "$id" || continue
    # Mục cờ clusteronly: chỉ chạy khi chạy theo cụm hoặc chọn thẳng bằng --case (không chạy trong --all / --group)
    if [[ "$flags" == *clusteronly* ]] && [ "$CLUSTER_RUN" != 1 ] && [ ${#CASE_FILTER[@]} -eq 0 ]; then continue; fi
    if [ $shown -eq 0 ]; then say "\n${C_C}${C_B}########## NHÓM: $g ##########${C_0}"; shown=1; fi
    tc_begin "$id" "$name"

    # Mục nặng / cần rút nguồn: chỉ chạy khi chọn rõ bằng --case hoặc --heavy
    if [[ "$flags" == *heavy* || "$flags" == *power* ]] && [ "$RUN_HEAVY" != 1 ] && [ ${#CASE_FILTER[@]} -eq 0 ]; then
      tc_skip "Mục rút nguồn/nặng ($flags) không chạy trong --all, chạy bằng --heavy hoặc --case $id"
      continue
    fi
    if [[ "$flags" == *manual* ]] && [ "${MMI_NONINTERACTIVE:-0}" = 1 ]; then
      tc_skip "Cần người test xác nhận (MMI_NONINTERACTIVE=1)"
      continue
    fi

    if [ "${CONN_GUARD:-1}" = 1 ] && ! conn_guard; then
      CONN_LOST=1
      tc_fail "Mất kết nối $(tp_describe) quá ${CONNECT_TIMEOUT}s - dừng test"
      break
    fi

    # Mục dùng I2C (RTC, SHT, Lens, TPM): kiểm tra thiết bị trên bus I2C trước, thiếu thì FAIL luôn
    i2c_gate "$id" || continue

    fn="case_${id//./_}"
    before=$((CNT_PASS + CNT_FAIL + CNT_SKIP))
    if declare -F "$fn" >/dev/null; then "$fn"; else tc_todo "Chưa viết script"; fi
    after=$((CNT_PASS + CNT_FAIL + CNT_SKIP))
    [ "$after" -eq "$before" ] && tc_fail "Test case không trả kết quả (lỗi script)"
  done
  unset -n arr
  # Dọn riêng của nhóm (ví dụ tắt RTSP/viewer) - bỏ qua nếu đã mất kết nối
  if [ "$CONN_LOST" != 1 ] && declare -F "teardown_$g" >/dev/null; then "teardown_$g"; fi
}

# ---- Tham số -------------------------------------------------------------------------
CLUSTER_NAME=""; CLUSTER_RUN=0
# set_cluster <TÊN>: SELECTED = các nhóm thuộc cụm (CLUSTER_<TÊN> trong config.sh; "*" = phần còn lại)
set_cluster() {
  local name="$1" var list g c other="" cvar clist
  CLUSTER_RUN=1
  cvar="CLUSTER_${name//-/_}_CASES"; clist="${!cvar:-}"
  if [ -n "$clist" ]; then            # cụm khai báo theo danh sách mục (id), ví dụ "11.7"
    read -ra CASE_FILTER <<< "$clist"; SELECTED=("${ALL_GROUPS[@]}"); CLUSTER_NAME="$name"; return 0
  fi
  var="CLUSTER_${name//-/_}"; list="${!var:-}"
  [ -n "$list" ] || die "Cụm không hợp lệ: $name (có: $CLUSTERS)"
  if [ "$list" = "*" ]; then
    for c in $CLUSTERS; do
      [ "$c" = "$name" ] && continue
      var="CLUSTER_${c//-/_}"; other="$other ${!var:-}"
    done
    SELECTED=()
    for g in "${ALL_GROUPS[@]}"; do case " $other " in *" $g "*) ;; *) SELECTED+=("$g") ;; esac; done
  else
    read -ra SELECTED <<< "$list"
  fi
  CLUSTER_NAME="$name"
}

MODE=""; SELECTED=(); CASE_FILTER=(); RUN_HEAVY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --all)       MODE=run; SELECTED=("${ALL_GROUPS[@]}") ;;
    --group)     MODE=run; shift; IFS=',' read -ra SELECTED <<< "${1^^}" ;;
    --cluster)   MODE=run; shift; set_cluster "${1^^}" ;;
    --case)      MODE=run; shift; IFS=',' read -ra CASE_FILTER <<< "$1"; SELECTED=("${ALL_GROUPS[@]}") ;;
    --write-mac) MODE=writemac; shift; WRITE_MAC="$1" ;;
    --read-id)   MODE=readid ;;
    --write-serial) MODE=writeserial; shift; WRITE_SERIAL="${1:-}" ;;
    --reboot)    MODE=reboot ;;
    --heavy)     RUN_HEAVY=1 ;;
    --list)      MODE=list ;;
    --setup)     bash "$TOOL_DIR/setup_pc.sh"; rc=$?; PAUSED=1; exit $rc ;;
    --skip-setup) MMI_SKIP_PC_CHECK=1 ;;
    --ip)        shift; DEVICE_IP="$1"; [[ "$DEVICE_IP" =~ ^[0-9]{1,3}$ ]] && DEVICE_IP="${IP_PREFIX}${DEVICE_IP}" ;;
    --transport) shift; TRANSPORT="$1" ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Tham số không hợp lệ: $1"; usage; exit 1 ;;
  esac
  shift
done

[ "$MODE" = list ] && { list_cases; exit 0; }

# Thông tin thiết bị (đọc Chip ID / ghi Serial / ghi MAC / reboot): mọi thứ hiện trên màn hình + output thô của thiết bị
# được ghi nối tiếp vào reports/log/deviceinfo.log (say() ghi vào $LOG_FILE). Quá 2 MB thì đổi tên thành deviceinfo.log.old
if [[ "$MODE" =~ ^(writemac|readid|writeserial|reboot)$ ]]; then
  mkdir -p "$LOG_DIR" 2>/dev/null
  LOG_FILE="$LOG_DIR/deviceinfo.log"
  [ "$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)" -gt 2097152 ] && mv -f "$LOG_FILE" "$LOG_FILE.old"
  printf '\n================ %s  %s %s%s ================\n' "$(date '+%F %T')" "$MODE" "${WRITE_SERIAL:-}" "${WRITE_MAC:-}" >> "$LOG_FILE"
fi

if [ -z "$MODE" ]; then
  echo "Chọn nhóm (nhiều nhóm cách nhau bằng dấu cách, Enter = tất cả):"
  i=1; for g in "${ALL_GROUPS[@]}"; do printf '  %2d) %s\n' "$i" "$g"; i=$((i + 1)); done
  read -r -p "> " picks
  if [ -z "$picks" ]; then SELECTED=("${ALL_GROUPS[@]}")
  else
    for p in $picks; do
      [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le "${#ALL_GROUPS[@]}" ] || die "Lựa chọn không hợp lệ: $p (chọn 1-${#ALL_GROUPS[@]})"
      SELECTED+=("${ALL_GROUPS[$((p - 1))]}")
    done
  fi
fi

# ---- Kiểm tra lựa chọn (nhóm/mục sai hoặc rỗng => dừng, không bao giờ ra PASS với 0 mục) -------------
validate_selection() {
  local g id found entry
  [ ${#SELECTED[@]} -gt 0 ] || die "Chưa chọn nhóm nào (nhóm hợp lệ: $TEST_GROUPS_ALL)"
  for g in "${SELECTED[@]}"; do
    declare -p "CASES_$g" >/dev/null 2>&1 || die "Không có nhóm: $g (nhóm hợp lệ: $TEST_GROUPS_ALL)"
  done
  for id in "${CASE_FILTER[@]}"; do
    found=0
    for g in "${ALL_GROUPS[@]}"; do
      declare -n arr="CASES_$g"
      for entry in "${arr[@]}"; do [ "${entry%%|*}" = "$id" ] && found=1; done
      unset -n arr
    done
    [ "$found" = 1 ] || die "Không có mục: $id (xem: ./mmi/run_mmi.sh --list)"
  done
}
if [[ ! "$MODE" =~ ^(writemac|readid|writeserial|reboot)$ ]]; then
  validate_selection
  # Chạy một phần (--group/--case/menu chọn bớt): đánh dấu PARTIAL trong tên báo cáo để không nhầm với lượt chạy đủ
  if [ -z "$CLUSTER_NAME" ] && { [ ${#CASE_FILTER[@]} -gt 0 ] || [ ${#SELECTED[@]} -lt ${#ALL_GROUPS[@]} ]; }; then CLUSTER_NAME="PARTIAL"; fi
fi

# ---- Tool trên PC ---------------------------------------------------------------------------
pc_tools_check

# ---- Kết nối ----------------------------------------------------------------------------
case "$TRANSPORT" in
  adb|ssh) . "$MMI_DIR/lib/transport_$TRANSPORT.sh" ;;
  *) die "TRANSPORT không hợp lệ: $TRANSPORT (adb|ssh)" ;;
esac

[ -n "$DEVICE_IP" ] || prompt_ip
tp_init
echo "Kết nối: $(tp_describe) (timeout ${CONNECT_TIMEOUT}s) ..."
if ! wait_device "$CONNECT_TIMEOUT"; then
  die "Không kết nối được $(tp_describe) sau ${CONNECT_TIMEOUT}s. Kiểm tra: nguồn/cáp mạng, IP (ping $DEVICE_IP), adbd (adb) hoặc sshd (ssh)."
fi
echo "$DEVICE_IP" > "$LAST_IP_FILE"
detect_mac_iface
dilog "PC: $(hostname)  Kết nối: $(tp_describe)  MAC_IFACE: $MAC_IFACE"

# Chế độ ghi MAC: không chạy test, ghi MAC rồi thoát
if [ "$MODE" = writemac ]; then
  . "$MMI_DIR/lib/mac_write.sh"
  write_mac_flow "$WRITE_MAC"; rc=$?
  exit $rc
fi

# Chế độ thông tin thiết bị: đọc Chip ID/Serial, ghi Serial, reboot (không chạy test)
case "$MODE" in
  readid|writeserial|reboot)
    . "$MMI_DIR/lib/devinfo.sh"
    case "$MODE" in
      readid)      devinfo_read_flow ;;
      writeserial) devinfo_write_serial_flow "$WRITE_SERIAL" ;;
      reboot)      devinfo_reboot_flow ;;
    esac
    exit $? ;;
esac

# Device ID = SERIAL (getprop ro.serialno). Serial được ghi bằng nút "Write Serial" và chỉ có hiệu lực SAU KHI REBOOT.
# Đọc lỗi / chưa ghi serial thì KHÔNG dùng chuỗi lỗi làm tên báo cáo:
#   mặc định (DEVID_REQUIRED=1) -> dừng, yêu cầu ghi serial + reboot trước; DEVID_REQUIRED=0 -> chạy tiếp với ID = unknown.
DEV_ID="$(dev_val 'getprop ro.serialno 2>/dev/null' | head -n 1 | tr -d '\r')"
if ! [[ "$DEV_ID" =~ ^[A-Za-z0-9_-]{1,32}$ ]] || [ "$DEV_ID" = unknown ]; then
  # Chưa có Serial hợp lệ -> dùng MAC ethernet (không dấu ':', viết hoa) làm Device ID
  DEV_MAC="$(dev_val "$SERIAL_CMD" | head -n 1 | tr -d '\r:' | tr 'a-f' 'A-F')"
  if [[ "$DEV_MAC" =~ ^[0-9A-F]{12}$ ]]; then
    say "${C_Y}Chưa có Serial (ro.serialno = '${DEV_ID:0:40}') -> dùng MAC $MAC_IFACE làm Device ID: $DEV_MAC${C_0}"
    DEV_ID="$DEV_MAC"
  elif [ "${DEVID_REQUIRED:-1}" = 1 ]; then
    die "Thiết bị chưa có Serial hợp lệ (ro.serialno = '${DEV_ID:0:40}'). Dùng tool: Write Serial -> Reboot Device -> kiểm tra Serial hiện đúng, rồi chạy lại test. (Bỏ qua kiểm tra này: DEVID_REQUIRED=0)"
  else
    say "${C_Y}CẢNH BÁO: không đọc được Serial (ro.serialno = '${DEV_ID:0:40}') và MAC -> Device ID = unknown${C_0}"
    DEV_ID=unknown
  fi
fi
DEV_CPU="$(dev_val nproc | head -n 1)"
if [ -z "${HSP_ID:-}" ] && [ "${MMI_NONINTERACTIVE:-0}" != "1" ]; then
  # Sản xuất: bắt buộc nhập/quét số tem để truy vết (HSP_ID_REQUIRED=0 cho phép Enter bỏ qua)
  while true; do
    read -r -p "Nhập/quét số tem HSPTek$([ "${HSP_ID_REQUIRED:-1}" = 1 ] && echo ' (bắt buộc)' || echo ' (Enter = bỏ qua)'): " HSP_ID </dev/tty || break
    HSP_ID="${HSP_ID//[^A-Za-z0-9_-]/}"
    [ -n "$HSP_ID" ] && break
    [ "${HSP_ID_REQUIRED:-1}" = 1 ] || break
    echo "  Chưa nhập số tem, vui lòng nhập lại."
  done
fi
HSP_ID="${HSP_ID//[^A-Za-z0-9_-]/}"; HSP_ID="${HSP_ID:--}"
init_report "$DEV_ID"
REPORT_READY=1
precheck

for g in "${SELECTED[@]}"; do
  declare -p "CASES_$g" >/dev/null 2>&1 || { say "${C_R}Không có nhóm: $g${C_0}"; continue; }
  run_group "$g"
  [ "$CONN_LOST" = 1 ] && { say "${C_R}Dừng test: mất kết nối thiết bị. Các nhóm còn lại chưa chạy.${C_0}"; break; }
done

finish_report