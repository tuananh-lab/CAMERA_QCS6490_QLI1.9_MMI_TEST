#!/bin/bash
# =============================================================================
#  devinfo.sh - đọc Chip ID / Serial, ghi Serial, reboot thiết bị
#    run_mmi.sh --read-id              getprop ro.chipid, getprop ro.serialno (+ MAC)
#    run_mmi.sh --write-serial <S>     echo SERIAL=<S> > $DEVINFO_DEV, đọc lại kiểm tra (serial mới chỉ hiện ở
#                                      getprop ro.serialno SAU KHI REBOOT)
#    run_mmi.sh --reboot               reboot, chờ thiết bị tắt rồi lên lại (kiểm tra boot_id đổi), in lại Chip ID / Serial / MAC
#  Mọi thao tác ghi thêm dòng vào reports/log/devinfo_log.csv (tóm tắt) và reports/log/deviceinfo.log (log đầy đủ, gồm output thô
#  của thiết bị: getprop, boot_id, hexdump partition devinfo). Return: 0 = OK, 1 = lỗi.
#  Thiết bị dùng IP tĩnh nên sau reboot IP không đổi (nếu dùng DHCP: tìm IP mới rồi chạy lại --read-id).
# =============================================================================
: "${DEVINFO_DEV:=/dev/disk/by-partlabel/devinfo}"
: "${SERIAL_MAXLEN:=32}"
: "${DEVINFO_REBOOT_AFTER:=0}"      # 1 = tự reboot ngay sau khi ghi Serial (mặc định: dùng nút Reboot riêng)
: "${REBOOT_SETTLE:=5}"            # chờ dịch vụ lên đủ sau khi thiết bị trả lời (giây)
: "${REBOOT_DOWN_WAIT:=10}"         # chờ thiết bị THỰC SỰ tắt sau mỗi lần gửi lệnh reboot (giây)

_di_log() {   # _di_log <hành động> <chip id> <serial cũ> <serial mới> <kết quả>
  mkdir -p "$LOG_DIR" 2>/dev/null
  [ -s "$LOG_DIR/devinfo_log.csv" ] || printf '\xef\xbb\xbf%s\n' 'Thời gian,PC,Kết nối,Hành động,Chip ID,Serial cũ,Serial mới,Kết quả' > "$LOG_DIR/devinfo_log.csv"
  printf '%s,%s,%s,%s,%s,%s,%s,%s\n' "$(date '+%F %T')" "$(hostname)" "$(tp_describe)" "$1" "$2" "$3" "$4" "$5" >> "$LOG_DIR/devinfo_log.csv"
  dilog "KẾT QUẢ: $1  chip=$2  serial cũ='$3'  serial mới='$4'  =>  $5"
}

_di_banner() {   # _di_banner <OK|FAIL|WARN> <nội dung>
  local bg="" rs=""
  if [ -t 1 ]; then rs=$'\e[0m'; case "$1" in OK) bg=$'\e[42;30;1m' ;; WARN) bg=$'\e[43;30;1m' ;; *) bg=$'\e[41;97;1m' ;; esac; fi
  say ""; say "${bg}                                                          ${rs}"
  say "${bg}   $2   ${rs}"; say "${bg}                                                          ${rs}"
}

_di_prop() { dev_val "getprop $1 2>/dev/null" | head -n 1 | tr -d '\r'; }
_di_mac()  { dev_val "$SERIAL_CMD" | head -n 1 | tr 'a-f' 'A-F' | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1:\2:\3:\4:\5:\6/'; }
_di_boot_id() { dev_val 'cat /proc/sys/kernel/random/boot_id 2>/dev/null' | head -n 1 | tr -d '\r'; }

# Chỉ ghi log: OS đang lấy serial/chip từ đâu (getprop, cmdline), boot_id, uptime
_di_diag() {   # _di_diag <nhãn>
  dilog "--- $1: nguồn serial/chip của OS ---"
  dilog "$(dev_script -t 20 <<'EOF2'
echo "[getprop]"; getprop 2>/dev/null | grep -iE 'serial|chip'
echo "[cmdline]"; tr ' ' '\n' < /proc/cmdline 2>/dev/null | grep -iE 'serial'
echo "[boot_id] $(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
echo "[uptime ] $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
EOF2
)"
}

# Chỉ ghi log: file nào trên OS nhắc tới serial/devinfo (để biết ro.serialno được dựng từ đâu)
_di_src() {
  dilog "--- file trên OS nhắc tới serialno/devinfo ---"
  dilog "$(dev_script -t 25 <<'EOF2'
grep -rIlE 'ro\.serialno|by-partlabel/devinfo|SERIAL=' /etc /usr/bin /usr/sbin /usr/lib/systemd /lib/systemd 2>/dev/null | head -n 15
echo "[getprop ro.serialno] $(getprop ro.serialno 2>&1)"
EOF2
)"
}

# Chỉ ghi log: dump 64 byte đầu của partition devinfo
_di_part() {   # _di_part <nhãn>
  dilog "--- partition devinfo ($1) ---"
  dilog "$(dev_script -t 20 DEV="$DEVINFO_DEV" <<'EOF2'
echo "dev: $DEV -> $(readlink -f "$DEV" 2>/dev/null)"
dd if="$DEV" bs=64 count=1 2>/dev/null | od -An -c | head -n 6
EOF2
)"
}

# Đọc và in Chip ID / Serial / MAC. Gán DI_CHIP, DI_SERIAL, DI_MAC. Return 1 nếu không đọc được Chip ID.
devinfo_show() {
  if ! dev_has getprop; then _di_banner FAIL "THIẾT BỊ KHÔNG CÓ LỆNH getprop"; return 1; fi
  DI_CHIP="$(_di_prop ro.chipid)"; DI_SERIAL="$(_di_prop ro.serialno)"; DI_MAC="$(_di_mac)"
  say ""
  say "  Chip ID (ro.chipid)    : ${C_B}${DI_CHIP:-<chưa có>}${C_0}"
  say "  Serial  (ro.serialno)  : ${C_B}${DI_SERIAL:-<trống>}${C_0}"
  say "  MAC     ($MAC_IFACE)  : ${C_B}${DI_MAC:-<không đọc được>}${C_0}"
  # tool.py (MMI_MACHINE=1) đọc 3 dòng này để hiển thị trong cửa sổ, không cần terminal
  if [ "${MMI_MACHINE:-0}" = 1 ]; then printf '@@CHIPID=%s\n@@SERIAL=%s\n@@MAC=%s\n' "$DI_CHIP" "$DI_SERIAL" "$DI_MAC"; fi
  # Chip ID / Serial chưa ghi thì để trống, KHÔNG coi là lỗi (đã kết nối adb và có getprop là đọc được)
  return 0
}

devinfo_read_flow() {
  devinfo_show || return 1
  _di_diag "ĐỌC"; _di_log READ "$DI_CHIP" "$DI_SERIAL" "" "OK"; return 0
}

devinfo_write_serial_flow() {
  local s="$1" old chip out chk
  if ! [[ "$s" =~ ^[A-Za-z0-9_-]+$ ]] || [ "${#s}" -gt "$SERIAL_MAXLEN" ]; then
    _di_banner FAIL "SERIAL KHÔNG HỢP LỆ (chỉ A-Z a-z 0-9 _ -, tối đa $SERIAL_MAXLEN ký tự)"; return 1
  fi
  dev_has getprop && { old="$(_di_prop ro.serialno)"; chip="$(_di_prop ro.chipid)"; }
  say "Chip ID: ${chip:-?}   Serial hiện tại: ${old:-<trống>}   ->   Serial mới: ${C_B}$s${C_0}"
#   _di_diag "TRƯỚC khi ghi serial"
#   _di_src
#   _di_part "TRƯỚC khi ghi"
  out="$(dev_script -t 30 DEV="$DEVINFO_DEV" SER="$s" <<'EOF2'
[ -e "$DEV" ] || { echo "NODEV"; exit 2; }
echo "SERIAL=$SER" > "$DEV" && sync && echo "WRITE_OK"
EOF2
)"
  dilog "lệnh ghi (echo SERIAL=$s > $DEVINFO_DEV) trả về: '$out'"
  if printf '%s' "$out" | grep -q NODEV; then
    _di_banner FAIL "KHÔNG THẤY $DEVINFO_DEV TRÊN THIẾT BỊ"; _di_log WRITE_SERIAL "$chip" "$old" "$s" "FAIL(no devinfo)"; return 1
  fi
  if ! printf '%s' "$out" | grep -q WRITE_OK; then
    _di_banner FAIL "GHI SERIAL THẤT BẠI: $(printf '%s' "$out" | head -c 120)"; _di_log WRITE_SERIAL "$chip" "$old" "$s" "FAIL(write)"; return 1
  fi
  # Đọc lại thẳng từ partition (ro.serialno chưa đổi cho tới khi reboot)
  chk="$(dev_script -t 30 DEV="$DEVINFO_DEV" <<'EOF2'
dd if="$DEV" bs=64 count=1 2>/dev/null | tr -d '\000' | grep -a -o 'SERIAL=[^[:space:]]*' | head -n 1
EOF2
)"
  chk="$(printf '%s' "$chk" | tr -d '\r' | head -n 1)"
#   _di_part "SAU khi ghi"
  if [ "$chk" != "SERIAL=$s" ]; then
    _di_banner FAIL "ĐỌC LẠI KHÔNG KHỚP (đọc được: '${chk:-trống}', cần SERIAL=$s)"; _di_log WRITE_SERIAL "$chip" "$old" "$s" "FAIL(readback)"; return 1
  fi
  say "${C_G}Đọc lại partition: KHỚP (SERIAL=$s)${C_0}"
  if [ "$DEVINFO_REBOOT_AFTER" = 1 ]; then
    _di_log WRITE_SERIAL "$chip" "$old" "$s" "OK(reboot)"
    devinfo_reboot_flow; return $?
  fi
  _di_banner WARN "ĐÃ GHI SERIAL $s - BẤM REBOOT ĐỂ ÁP DỤNG"
  _di_log WRITE_SERIAL "$chip" "$old" "$s" "WRITTEN(no reboot)"
  return 0
}

devinfo_reboot_flow() {
  local t0 dt b0 b1 i m out rc down=0 ok=0
  b0="$(_di_boot_id)"
  say "Reboot thiết bị ...   (boot_id hiện tại: ${b0:-không đọc được})"
  t0=$SECONDS

  # Bước 1: Gửi lệnh reboot và nhanh chóng kiểm tra thiết bị mất kết nối (tối đa 8s)
  for m in A B; do
    out="$(tp_reboot "$m")"; rc=$?
    dilog "lệnh reboot cách $m: rc=$rc  output='$out'"
    say "  Đã gửi lệnh reboot, chờ thiết bị ngắt kết nối..."
    for ((i = 0; i < 8; i++)); do
      tp_ready 3 || { down=1; break; }
      sleep 1
    done
    [ "$down" = 1 ] && break
  done

  # Bước 2: Chờ thiết bị khởi động lại (giảm tổng thời gian chờ lên lại)
  say "  Chờ thiết bị khởi động lại..."
  if ! wait_device 60; then
    _di_banner FAIL "KHÔNG KẾT NỐI LẠI SAU REBOOT"; _di_log REBOOT "" "" "" "FAIL(no reconnect)"; return 1
  fi
  dt=$((SECONDS - t0)); sleep "$REBOOT_SETTLE"

  # Bước 3: Xác thực boot_id đã thay đổi để chắc chắn thiết bị đã reboot thật
  b1="$(_di_boot_id)"
  dilog "boot_id trước='$b0'  sau='$b1'"
  if [ -n "$b0" ] && [ -n "$b1" ] && [ "$b0" = "$b1" ]; then
    _di_banner FAIL "LỆNH REBOOT KHÔNG CÓ TÁC DỤNG - boot_id không đổi"
    _di_log REBOOT "" "" "" "FAIL(no reboot)"; return 1
  fi

  # Bước 4: Đọc lại thông tin ngay khi dịch vụ sẵn sàng
  for i in 1 2; do devinfo_show && { ok=1; break; }; sleep 2; done
  if [ "$ok" != 1 ]; then
    _di_banner FAIL "KHÔNG ĐỌC ĐƯỢC CHIP ID SAU REBOOT"; _di_log REBOOT "" "" "" "FAIL(read after reboot)"; return 1
  fi

  _di_banner OK "THIẾT BỊ ĐÃ KHỞI ĐỘNG LẠI SAU ${dt}s"
  _di_log REBOOT "${DI_CHIP:-}" "${DI_SERIAL:-}" "" "OK(${dt}s)"
  return 0
}