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

# >>>>>>>>>> TẠM THỜI: lỗi adbd của thiết bị (sau reboot ping được nhưng adb không connect được) >>>>>>>>>>
# Cách bỏ: đặt ADBD_FIX=0 (config.sh), hoặc comment khối này + 2 khối cùng cặp dấu >>>/<<< trong tp_wait.
: "${ADBD_FIX:=1}"
: "${ADBD_FIX_WAIT_S:=30}"      # sau khi restart adbd: thử adb connect lại tối đa số giây này
: "${ADBD_FIX_AFTER_S:=10}"     # ping được quá số giây này mà adb vẫn không kết nối => ssh vào restart adbd
_adbd_fix() {
  local o=(-p "${SSH_PORT:-22}" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR
           -o ConnectTimeout=8 -o ControlMaster=no -o ControlPath=none) rc
  say "  ${C_Y}Ping được nhưng adb chưa kết nối: ssh vào restart android-tools-adbd.service (fix tạm lỗi adbd)...${C_0}"
  if [ -n "${SSH_PASS:-}" ] && command -v sshpass >/dev/null; then
    SSHPASS="$SSH_PASS" timeout 30 sshpass -e ssh "${o[@]}" "${SSH_USER:-root}@$DEVICE_IP" 'systemctl restart android-tools-adbd.service' 2>&1
  else
    timeout 30 ssh -o BatchMode=yes "${o[@]}" "${SSH_USER:-root}@$DEVICE_IP" 'systemctl restart android-tools-adbd.service' 2>&1
  fi
  rc=$?
  [ $rc -eq 0 ] && say "  Đã restart adbd, kết nối adb lại..." || say "  ${C_Y}ssh restart adbd lỗi (rc=$rc): kiểm tra ssh/mật khẩu (SSH_USER, SSH_PASS)${C_0}"
  sleep 3
}
# <<<<<<<<<< hết khối tạm thời <<<<<<<<<<

# tp_wait [timeout_s]: kết nối (lại) cho tới khi shell trả lời. Giới hạn theo ĐỒNG HỒ THẬT:
# không bao giờ chạy quá timeout_s giây (kể cả khi adb connect bị treo).
tp_wait() {
  local to="${1:-60}" end left up=0 fixed=0
  end=$((SECONDS + to))
  while :; do
    left=$((end - SECONDS)); [ "$left" -gt 0 ] || break
    tp_connect "$left"
    left=$((end - SECONDS)); [ "$left" -gt 0 ] || break
    tp_ready $((left > 8 ? 8 : left)) && return 0
    timeout 3 "$ADB_BIN" disconnect "$ADB_SERIAL" >/dev/null 2>&1   # dọn kết nối offline
    # >>> TẠM THỜI (adbd lỗi): ping được >ADBD_FIX_AFTER_S giây mà adb vẫn không connect => ssh restart adbd (1 lần)
    if [ "${ADBD_FIX:-1}" = 1 ] && [ "$fixed" = 0 ]; then
      if ping -c 1 -W 1 "$DEVICE_IP" >/dev/null 2>&1; then
        [ "$up" = 0 ] && up=$SECONDS
        if [ $((SECONDS - up)) -ge "${ADBD_FIX_AFTER_S:-10}" ]; then fixed=1; _adbd_fix; fi
      else up=0; fi
    fi
    # <<< hết khối tạm thời
    sleep 1
  done
  # >>> TẠM THỜI (adbd lỗi): hết thời gian chờ (kể cả lần chờ ngắn CONNECT_TIMEOUT lúc mở tool / giữa các mục test)
  # mà ping vẫn được nhưng adb không connect => ssh restart adbd 1 lần rồi thử connect lại
  if [ "${ADBD_FIX:-1}" = 1 ] && [ "$fixed" = 0 ] && ping -c 1 -W 1 "$DEVICE_IP" >/dev/null 2>&1; then
    _adbd_fix
    end=$((SECONDS + ${ADBD_FIX_WAIT_S:-30}))      # adbd restart xong có thể cần vài chục giây mới nhận kết nối
    while [ "$SECONDS" -lt "$end" ]; do tp_connect 3; tp_ready 3 && return 0; sleep 1; done
  fi
  # <<< hết khối tạm thời
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
# tp_reboot <A|B>: reboot bằng cách mô phỏng đúng thao tác gõ tay: "adb shell" (shell TƯƠNG TÁC, có pty) rồi gõ lệnh.
# Máy này chạy "reboot -f" được khi gõ trong shell tương tác nhưng không được khi truyền lệnh thẳng "adb shell <lệnh>"
# (và "adb reboot" cũng không hỗ trợ), nên lệnh được đưa vào shell tương tác qua stdin với "shell -tt" (ép cấp pty).
# Thử lần lượt: 1) sync; reboot -f  2) reboot  3) sysrq 'b'; mức sau chỉ chạy khi thiết bị VẪN trả lời adb sau ~12s.
_adb_tty() { { printf '%s\n' "$1"; sleep 5; } | timeout 15 "${ADB_CMD[@]}" shell -tt 2>&1 | tr -d '\r'; }
tp_reboot() {
  local step i
  for step in 'sync; reboot -f' 'reboot' 'echo 1 > /proc/sys/kernel/sysrq; echo b > /proc/sysrq-trigger'; do
    echo "[adb shell -tt] $step"
    _adb_tty "$step" | tail -n 4
    for ((i = 0; i < 12; i++)); do
      tp_ready 2 || break 2                 # adb không trả lời nữa => thiết bị đã tắt, dừng
      sleep 1
    done
  done
  "$ADB_BIN" disconnect "$ADB_SERIAL" >/dev/null 2>&1
  return 0
}
tp_close() { :; }   # giữ kết nối adb để lần chạy sau nhanh hơn
tp_describe() { echo "adb $ADB_SERIAL"; }