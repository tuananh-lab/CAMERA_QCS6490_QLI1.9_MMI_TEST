#!/bin/bash
# =============================================================================
#  mmi_lib.sh - lớp dùng chung cho test case (không phụ thuộc adb/ssh)
#    dev_*      : thao tác trên thiết bị (xây trên tp_* của transport)
#    tc_*       : ghi kết quả
#    on_cleanup : đăng ký việc dọn dẹp, chạy khi kết thúc/Ctrl-C
# =============================================================================

if [ -t 1 ]; then
  C_G=$'\e[32m'; C_R=$'\e[31m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_B=$'\e[1m'; C_0=$'\e[0m'
else
  C_G=""; C_R=""; C_Y=""; C_C=""; C_B=""; C_0=""
fi

say() {
  printf '%b\n' "$*"
  [ -n "${LOG_FILE:-}" ] && printf '%b\n' "$*" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
  return 0
}
die() { say "${C_R}LỖI: $*${C_0}"; exit 1; }
# dilog <text>: CHỈ ghi vào log thông tin thiết bị (reports/log/deviceinfo.log), không in ra màn hình.
# Dùng để lưu output thô của thiết bị (hexdump partition/EEPROM, getprop, boot_id...) phục vụ tìm lỗi.
dilog() {
  [ -n "${LOG_FILE:-}" ] || return 0
  printf '%s\n' "$*" | sed 's/\x1b\[[0-9;]*m//g;s/\r//g' | while IFS= read -r l; do printf '%s  | %s\n' "$(date '+%T')" "$l"; done >> "$LOG_FILE"
  return 0
}

# ============================== DỌN DẸP ======================================
CLEANUPS=()
on_cleanup() { CLEANUPS+=("$*"); }
run_cleanups() {
  local i
  for ((i = ${#CLEANUPS[@]} - 1; i >= 0; i--)); do eval "${CLEANUPS[$i]}" >/dev/null 2>&1; done
  CLEANUPS=()
}

# ============================== THIẾT BỊ =====================================
# dev_sh_t <timeout_s> <lệnh>   |   dev_sh <lệnh> (timeout mặc định DEV_TIMEOUT=30s)
dev_sh_t() { local t="$1"; shift; tp_exec "$t" "$*"; }
dev_sh()   { dev_sh_t "${DEV_TIMEOUT:-30}" "$@"; }
# dev_val: in giá trị đã cắt khoảng trắng đầu/cuối
dev_val()  { dev_sh "$@" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
dev_exists() { dev_sh_t 10 "[ -e '$1' ]" >/dev/null 2>&1; }
dev_has()  { dev_sh_t 10 "command -v $1" >/dev/null 2>&1; }

dev_pull() { tp_pull "$@"; }       # dev_pull <file_thiết_bị> <file_PC> [timeout]
dev_push() { tp_push "$@"; }       # dev_push <file_PC> <file_thiết_bị> [timeout]
wait_device() { tp_wait "$@"; }    # chờ thiết bị trả lời (sau reboot / rớt mạng)

# Chuẩn bị script từ stdin: dev_script [-t giây] [VAR=giá_trị ...] <<'EOF' ... EOF
# Script được push xuống $REMOTE_TMP rồi chạy (không phải escape \$ như heredoc truyền thẳng).
_dev_script_prepare() {
  DS_T="${DEV_TIMEOUT:-60}"
  if [ "${1:-}" = "-t" ]; then DS_T="$2"; shift 2; fi
  local f="$MMI_TMP/ds_$RANDOM.sh" a
  DS_RF="$REMOTE_TMP/mmi_$RANDOM.sh"
  { for a in "$@"; do printf 'export %q\n' "$a"; done; cat; } > "$f"
  tp_push "$f" "$DS_RF" || return 1
  # Không dùng lệnh timeout (QLI 1.9 không có; bản có cũng chỉ giết tiến trình cha): tự giết cả cây tiến trình
  read -r -d '' DS_CMD <<EOT
(
  kt() { for c in \$(pgrep -P \$1 2>/dev/null); do kt \$c; done; kill -9 \$1 2>/dev/null; }
  sh $DS_RF 2>&1 &
  p=\$!
  ( sleep $DS_T; kt \$p ) &
  w=\$!
  wait \$p; rc=\$?
  kt \$w
  [ \$rc -eq 137 ] && rc=124
  exit \$rc
) 2>/dev/null
rc=\$?
rm -f $DS_RF; exit \$rc
EOT
  return 0   # read -d '' trả 1 khi gặp EOF
}
dev_script() {
  _dev_script_prepare "$@" || return 255
  tp_exec $((DS_T + 10)) "$DS_CMD"
}
# Dòng log nhiễu của thiết bị (audio/pipewire...) chỉ ghi vào run.log, không in ra màn hình
: "${MMI_NOISE:=^(diag:|pcm_plug_open|Stopping .pipewire|pipewire-manager|PCM format|Valid format|Backend |Instance key|Playing sample|Capturing sample|Captured [0-9]+ frames|agmplay rc=)}"
# Giống dev_script nhưng in output ngay khi có (cho thao tác cần người test quan sát)
dev_script_live() {
  _dev_script_prepare "$@" || return 255
  tp_exec_live $((DS_T + 10)) "$DS_CMD" | tee -a "${LOG_FILE:-/dev/null}" | grep --line-buffered -Ev "$MMI_NOISE"
  return "$(cat "$MMI_TMP/last_rc" 2>/dev/null || echo 255)"
}

# detect_mac_iface: xác định interface Ethernet TRÊN THIẾT BỊ (MAC_IFACE đặt sẵn thì giữ nguyên), dựng SERIAL_CMD
detect_mac_iface() {
  if [ -z "${MAC_IFACE:-}" ]; then
    MAC_IFACE="$(dev_val "for i in $MAC_IFACE_CANDIDATES; do [ -r /sys/class/net/\$i/address ] && { echo \$i; break; }; done" | head -n 1)"
  fi
  if [ -z "$MAC_IFACE" ]; then
    MAC_IFACE="${MAC_IFACE_CANDIDATES%% *}"
    say "${C_Y}CẢNH BÁO: không thấy interface nào trong [$MAC_IFACE_CANDIDATES] trên thiết bị. Kiểm tra: ls /sys/class/net${C_0}"
  fi
  SERIAL_CMD="cat /sys/class/net/$MAC_IFACE/address | tr -d ':\\r\\n'"
}

# json_get <file> <a.b.c>: in giá trị trong JSON (return 1 nếu không có)
json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    for k in sys.argv[2].split('.'):
        d = d[k]
    print(d)
except Exception:
    sys.exit(1)
PY
}

# ============================== PC ===========================================
pc_ip() { ip -4 route get "$DEVICE_IP" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n 1; }

iperf_server_start() {
  command -v iperf3 >/dev/null || return 1
  pgrep -x iperf3 >/dev/null && return 0
  iperf3 -s -p "$IPERF_PORT" >/dev/null 2>&1 &
  IPERF_PID=$!
  on_cleanup "kill $IPERF_PID"
  sleep 1
  kill -0 "$IPERF_PID" 2>/dev/null
}

# ============================== KẾT QUẢ ======================================
CNT_PASS=0; CNT_FAIL=0; CNT_SKIP=0

init_results() {
  RESULT_CSV="$REPORT_DIR/results.csv"
  RESULT_TSV="$REPORT_DIR/results.tsv"
  LOG_FILE="$REPORT_DIR/run.log"
  : > "$LOG_FILE"
  printf '\xef\xbb\xbf%s\n' 'Mục,Nhóm,Tên,Kết quả,Chi tiết,Bắt đầu,Thời gian (s)' > "$RESULT_CSV"   # BOM để Excel đọc đúng tiếng Việt
  : > "$RESULT_TSV"
}

tc_begin() { TC_ID="$1"; TC_NAME="$2"; TC_T0=$(date +%s); TC_START=$(date +%H:%M:%S); say "\n${C_B}[$TC_ID] $TC_NAME${C_0}"; }

tc_end() {
  local res="$1" detail="${2:-}" col dur
  dur=$(( $(date +%s) - ${TC_T0:-$(date +%s)} ))
  detail="${detail//$'\r'/}"; detail="${detail//$'\n'/ | }"; detail="${detail//\"/\'}"
  printf '%s,%s,"%s","%s","%s",%s,%s\n' "$TC_ID" "${CUR_GROUP:-}" "$TC_NAME" "$res" "$detail" "${TC_START:-}" "$dur" >> "$RESULT_CSV"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$TC_ID" "${CUR_GROUP:-}" "$TC_NAME" "$res" "${detail//$'\t'/ }" "${TC_START:-}" "$dur" >> "$RESULT_TSV"
  case "$res" in
    PASS) CNT_PASS=$((CNT_PASS + 1)); col="$C_G" ;;
    FAIL) CNT_FAIL=$((CNT_FAIL + 1)); col="$C_R" ;;
    SKIP) CNT_SKIP=$((CNT_SKIP + 1)); col="$C_Y" ;;
    *)    CNT_FAIL=$((CNT_FAIL + 1)); col="$C_R" ;;
  esac
  say "  → ${col}${res}${C_0}  ${detail}"
  return 0
}
tc_pass() { tc_end PASS "$1"; }
tc_fail() { tc_end FAIL "$1"; }
# Chính sách: chỉ có PASS và FAIL. Mục không thực hiện được / chưa xác nhận / chưa viết script => FAIL
tc_skip() { tc_end FAIL "Không thực hiện được: $1"; }
tc_todo() { tc_end FAIL "Không thực hiện được: ${1:-Chưa viết script}"; }

# i2c_gate <id mục>: mục thuộc I2C_GATES (config.sh) thì kiểm tra thiết bị có trên bus I2C chưa.
# Return 0 = đạt hoặc mục không cần I2C; 1 = thiếu thiết bị (đã ghi FAIL, không chạy mục đó).
i2c_gate() {
  local g name bus addr ids out cell row col
  for g in "${I2C_GATES[@]}"; do
    IFS='|' read -r name bus addr ids <<< "$g"
    case " $ids " in *" $1 "*) ;; *) continue ;; esac
    if ! dev_has i2cdetect; then tc_skip "Thiếu i2cdetect trên thiết bị, không kiểm tra được I2C $name"; return 1; fi
    out="$(dev_sh "i2cdetect -y -r $bus 0x$addr 0x$addr 2>&1")"
    row="$(printf '%02x' $(( (16#$addr >> 4) << 4 )))"; col=$((16#$addr & 15))
    # Mỗi ô rộng 3 ký tự sau tiền tố "XX:"; chỉ đọc đúng ô của địa chỉ (không phụ thuộc số ô in ra)
    cell="$(printf '%s\n' "$out" | awk -v r="$row" -v c="$col" 'tolower(substr($0,1,3))==r":"{print substr($0,5+3*c,2); exit}')"
    case "$cell" in
      ""|--) tc_fail "I2C: không thấy $name tại i2c-$bus địa chỉ 0x$addr ($(printf '%s\n' "$out" | grep -i -m1 'error' || echo 'ô = --, không phản hồi'))"; return 1 ;;
      *)     say "  I2C OK: $name i2c-$bus 0x$addr ($cell$([ "$cell" = UU ] && echo ' = driver đang giữ'))" ;;
    esac
  done
  return 0
}

# tc_need <tool...>: thiếu tool trên thiết bị => ghi SKIP và return 1
tc_need() {
  local t miss=""
  for t in "$@"; do dev_has "$t" || miss="$miss $t"; done
  if [ -n "$miss" ]; then tc_skip "Thiếu tool trên thiết bị:$miss"; return 1; fi
  return 0
}

artifact() { mkdir -p "$REPORT_DIR/artifacts"; echo "$REPORT_DIR/artifacts/$1"; }
save_artifact() { printf '%s\n' "$2" > "$(artifact "$1")"; }

# ============================== NGƯỜI TEST ===================================
# ask_yn "câu hỏi" => 0 Đạt, 1 Không đạt, 2 Không trả lời được (không có bàn phím/chế độ tự động) => tính FAIL
ask_yn() {
  [ "${MMI_NONINTERACTIVE:-0}" = "1" ] && return 2
  local a line="════════════════════════════════════════════════════════════════"
  while read -r -t 0.05 -n 1 _ </dev/tty 2>/dev/null; do :; done      # xả phím gõ thừa trước đó
  printf '\a'
  say ""
  say "${C_Y}${line}${C_0}"
  say "${C_B}▶ CẦN NGƯỜI TEST ĐÁNH GIÁ  [${TC_ID:-?}] ${TC_NAME:-}${C_0}"
  say "   $1"
  say "${C_Y}${line}${C_0}"
  while true; do
    read -r -p "   Nhập  Y = ĐẠT   |   N = KHÔNG ĐẠT : " a </dev/tty || return 2
    case "$a" in
      y|Y) printf '   -> Nguoi test chon: DAT\n' >> "${LOG_FILE:-/dev/null}"; return 0 ;;
      n|N) printf '   -> Nguoi test chon: KHONG DAT\n' >> "${LOG_FILE:-/dev/null}"; return 1 ;;
    esac
  done
}
# tc_manual <câu hỏi> [msg đạt] [msg không đạt]
tc_manual() {
  ask_yn "$1"
  case $? in
    0) tc_pass "${2:-Người test xác nhận đạt}" ;;
    1) tc_fail "${3:-Người test xác nhận không đạt}" ;;
    *) tc_skip "Chưa được người test xác nhận (không có bàn phím/chế độ tự động)" ;;
  esac
}
pause_enter() { [ "${MMI_NONINTERACTIVE:-0}" = "1" ] || read -r -p "  ⏎ $1 " _ </dev/tty; }