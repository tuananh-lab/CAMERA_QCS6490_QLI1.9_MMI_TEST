#!/bin/bash
# Transport adb qua IP. Giao diện chung: tp_init tp_ready tp_wait tp_exec tp_exec_live tp_pull tp_push tp_close
REMOTE_ENV='export PATH=$PATH:/sbin:/usr/sbin:/usr/local/bin'

tp_init() {
  ADB_BIN="${ADB_BIN:-$(command -v adb)}"
  [ -n "$ADB_BIN" ] || die "Không tìm thấy adb (sudo apt install adb)"
  ADB_SERIAL="$DEVICE_IP:$ADB_PORT"
  ADB_CMD=("$ADB_BIN" -s "$ADB_SERIAL")
}

# Mọi thao tác kết nối đều bị chặn bởi timeout (mặc định CONNECT_TIMEOUT=10s)
tp_connect() { timeout "${1:-$CONNECT_TIMEOUT}" "$ADB_BIN" connect "$ADB_SERIAL" >/dev/null 2>&1; }

# tp_ready [timeout_s]: shell trên thiết bị có trả lời không
tp_ready() {
  local o
  o="$(timeout "${1:-8}" "${ADB_CMD[@]}" shell 'echo __ok__' 2>/dev/null | tr -d '\r')"
  [ "$o" = "__ok__" ]
}

# tp_wait [timeout_s]: kết nối (lại) cho tới khi shell trả lời. Giới hạn theo ĐỒNG HỒ THẬT:
# không bao giờ chạy quá timeout_s giây (kể cả khi adb connect bị treo).
tp_wait() {
  local to="${1:-60}" end left
  end=$((SECONDS + to))
  while :; do
    left=$((end - SECONDS)); [ "$left" -gt 0 ] || break
    tp_connect "$left"
    left=$((end - SECONDS)); [ "$left" -gt 0 ] || break
    tp_ready $((left > 8 ? 8 : left)) && return 0
    timeout 3 "$ADB_BIN" disconnect "$ADB_SERIAL" >/dev/null 2>&1   # dọn kết nối offline
    sleep 1
  done
  return 1
}

# adbd bản cũ không trả exit code -> thêm marker __MMI_RC=
_adb_wrap() { printf '( %s; %s\n); printf '"'"'\n__MMI_RC=%%s\n'"'"' $?' "$REMOTE_ENV" "$1"; }

# tp_exec <timeout> <lệnh>: in output (đã bỏ \r), trả về exit code (124 = timeout)
tp_exec() {
  local t="$1" f trc rc
  f="$(mktemp -p "$MMI_TMP")"
  timeout "$t" "${ADB_CMD[@]}" shell "$(_adb_wrap "$2")" > "$f" 2>&1
  trc=$?
  sed -i 's/\r//g' "$f"
  rc="$(sed -n 's/^__MMI_RC=//p' "$f" | tail -n 1)"
  sed '/^__MMI_RC=/d' "$f"
  rm -f "$f"
  [ "$trc" -eq 124 ] && return 124
  return "${rc:-255}"
}

# tp_exec_live <timeout> <lệnh>: stream output ra ngay; exit code ghi vào $MMI_TMP/last_rc
tp_exec_live() {
  local t="$1" f trc rc
  f="$(mktemp -p "$MMI_TMP")"
  timeout "$t" "${ADB_CMD[@]}" shell "$(_adb_wrap "$2")" 2>&1 | sed -u 's/\r//g' | tee "$f" | grep --line-buffered -v '^__MMI_RC='
  trc="${PIPESTATUS[0]}"
  rc="$(sed -n 's/^__MMI_RC=//p' "$f" | tail -n 1)"
  [ "$trc" -eq 124 ] && rc=124
  printf '%s' "${rc:-255}" > "$MMI_TMP/last_rc"
  rm -f "$f"
}

tp_pull() { timeout "${3:-120}" "${ADB_CMD[@]}" pull "$1" "$2" >/dev/null 2>&1 && [ -s "$2" ]; }
tp_push() { timeout "${3:-120}" "${ADB_CMD[@]}" push "$1" "$2" >/dev/null 2>&1; }
# tp_reboot <A|B>: gửi lệnh reboot bằng "adb shell <lệnh>" (KHÔNG dùng "adb reboot": thiết bị không hỗ trợ).
# Gọi adb trực tiếp, không qua _adb_wrap (không thêm export PATH / subshell). In output + trả về mã lỗi của adb.
#   A = sync; (sleep 1; reboot) chạy nền      B = sync; reboot chạy trực tiếp (adb tự ngắt khi thiết bị tắt, timeout là bình thường)
tp_reboot() {
  local cmd
  case "${1:-A}" in
    A) cmd='sync; (sleep 1; reboot) >/dev/null 2>&1 &' ;;
    *) cmd='sync; reboot' ;;
  esac
  timeout 15 "${ADB_CMD[@]}" shell "$cmd" 2>&1 | tr -d '\r'
  return "${PIPESTATUS[0]}"
}
tp_close() { :; }   # giữ kết nối adb để lần chạy sau nhanh hơn
tp_describe() { echo "adb $ADB_SERIAL"; }