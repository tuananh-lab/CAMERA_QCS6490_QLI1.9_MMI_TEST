#!/bin/bash
# =============================================================================
#  mac_write.sh - ghi MAC vào EEPROM của $MAC_IFACE (eth0/enu1u1, tự dò) (chạy bằng: run_mmi.sh --write-mac <MAC>)
#   1. Tạo file bin (MAC_EEPROM_LEN byte) từ file mẫu MAC_TEMPLATE (mmi/lib/mac_bin.py)
#   2. Push lên thiết bị ($MAC_DEV_DIR/<MAC>), chạy: ethtool -E $MAC_IFACE magic 0x78A5 offset 0 length 254 < file
#   3. Đọc lại EEPROM so sánh (sha1sum)
#   4. Reboot (MAC_REBOOT_AFTER=1), chờ thiết bị lên lại, kiểm tra MAC của $MAC_IFACE đã đổi
#  Kết quả được ghi thêm vào mac_write_log.csv (tóm tắt) và deviceinfo.log (log đầy đủ) trong thư mục lần test của thiết bị (LOG_DIR). Return: 0 = OK, 1 = lỗi, 2 = đã ghi nhưng chưa kiểm tra được.
# =============================================================================
: "${MAC_IFACE:=eth0}"
: "${MAC_EEPROM_MAGIC:=0x78A5}"
: "${MAC_EEPROM_LEN:=254}"
: "${MAC_DEV_DIR:=/data}"
: "${MAC_TEMPLATE:=$MMI_DIR/mac/template.bin}"
: "${MAC_TEMPLATE_MAC:=742584C00F06}"
: "${MAC_REBOOT_AFTER:=1}"
: "${MAC_ADDR_FILE:=/sys/class/net/$MAC_IFACE/address}"

_mac_log() {   # _mac_log <MAC cũ> <MAC mới> <kết quả>
  mkdir -p "$LOG_DIR" 2>/dev/null
  [ -s "$LOG_DIR/mac_write_log.csv" ] || printf '\xef\xbb\xbf%s\n' 'Thời gian,PC,Kết nối,MAC cũ,MAC mới,Kết quả' > "$LOG_DIR/mac_write_log.csv"
  printf '%s,%s,%s,%s,%s,%s\n' "$(date '+%F %T')" "$(hostname)" "$(tp_describe)" "$1" "$2" "$3" >> "$LOG_DIR/mac_write_log.csv"
  case "$3" in OK*|WRITTEN*) devlog_pointer_add_mac "$2" ;; esac     # MAC đã đổi: vẫn nhận ra thiết bị ở lần Read/Reboot sau
  dilog "KẾT QUẢ: WRITE_MAC  MAC cũ=$1  MAC mới=$2  =>  $3"
}

# Chỉ ghi log: driver, MAC đang chạy, 16 byte đầu EEPROM của $MAC_IFACE (byte đầu = 0xA5 là EEPROM hợp lệ, tiếp theo là MAC)
_mac_diag() {   # _mac_diag <nhãn>
  dilog "--- EEPROM/MAC $MAC_IFACE ($1) ---"
  dilog "$(dev_script -t 20 IFACE="$MAC_IFACE" <<'EOF2'
echo "driver : $(ethtool -i "$IFACE" 2>&1 | grep -E 'driver|version|bus-info' | tr '\n' ' ')"
echo "mac chạy: $(cat /sys/class/net/$IFACE/address 2>&1)"
echo "eeprom[0:16]: $(ethtool -e "$IFACE" raw on offset 0 length 16 2>&1 | od -An -tx1 | tr -s ' \n' ' ')"
EOF2
)"
}

_mac_banner() {   # _mac_banner <OK|FAIL|WARN> <nội dung>
  local bg="" rs=""
  if [ -t 1 ]; then rs=$'\e[0m'; case "$1" in OK) bg=$'\e[42;30;1m' ;; WARN) bg=$'\e[43;30;1m' ;; *) bg=$'\e[41;97;1m' ;; esac; fi
  say ""; say "${bg}                                                          ${rs}"
  say "${bg}   $2   ${rs}"; say "${bg}                                                          ${rs}"
}

write_mac_flow() {
  local hex mac first bin devbin cur now out rc sums h1 h2 a ans
  hex="$(printf '%s' "$1" | tr -d ':-' | tr 'a-f' 'A-F')"
  [[ "$hex" =~ ^[0-9A-F]{12}$ ]] || { say "${C_R}LỖI: MAC không hợp lệ: '$1' (cần 12 ký tự hex, ví dụ 74:25:84:C0:0F:06)${C_0}"; return 1; }
  first=$((16#${hex:0:2}))
  [ $((first & 1)) -eq 0 ] || { say "${C_R}LỖI: MAC $hex là địa chỉ multicast (bit thấp của byte đầu = 1)${C_0}"; return 1; }
  [ "$hex" != "000000000000" ] || { say "${C_R}LỖI: MAC toàn số 0${C_0}"; return 1; }
  mac="${hex:0:2}:${hex:2:2}:${hex:4:2}:${hex:6:2}:${hex:8:2}:${hex:10:2}"

  say "${C_B}===== GHI MAC =====${C_0}"
  dev_has ethtool || { say "${C_R}LỖI: thiết bị không có ethtool${C_0}"; return 1; }
  [ -f "$MAC_TEMPLATE" ] || { say "${C_R}LỖI: thiếu file mẫu $MAC_TEMPLATE (xem mmi/mac/README.txt)${C_0}"; return 1; }

  bin="$MMI_TMP/$hex"
  python3 "$MMI_DIR/lib/mac_bin.py" make "$MAC_TEMPLATE" "$MAC_TEMPLATE_MAC" "$hex" "$bin" "$MAC_EEPROM_LEN" || return 1

  dilog "file bin cục bộ $bin: $(od -An -tx1 -N16 "$bin" | tr -s ' \n' ' ') ... sha1=$(sha1sum < "$bin" | cut -d' ' -f1)"
  cur="$(dev_val "cat $MAC_ADDR_FILE")"
  say "MAC hiện tại của $MAC_IFACE : ${cur:-?}"
  say "MAC sẽ ghi                : $mac"
  if [ "${MMI_NONINTERACTIVE:-0}" = 1 ]; then say "${C_R}LỖI: ghi MAC cần xác nhận trên bàn phím${C_0}"; return 1; fi
  read -r -p "Ghi MAC mới vào EEPROM của thiết bị? (y/N): " ans </dev/tty || return 1
  case "$ans" in y|Y) ;; *) say "Đã hủy, không ghi gì."; return 1 ;; esac

  devbin="$MAC_DEV_DIR/$hex"
  _mac_diag "TRƯỚC khi ghi"
  say "Push $hex -> $devbin ..."
  dev_push "$bin" "$devbin" >/dev/null 2>&1 || { say "${C_R}LỖI: push file lên thiết bị thất bại${C_0}"; _mac_log "$cur" "$mac" "FAIL(push)"; return 1; }

  say "ethtool -E $MAC_IFACE magic $MAC_EEPROM_MAGIC offset 0 length $MAC_EEPROM_LEN < $devbin"
  out="$(dev_sh "ethtool -E $MAC_IFACE magic $MAC_EEPROM_MAGIC offset 0 length $MAC_EEPROM_LEN < $devbin 2>&1; echo RC=\$?" 2>&1 | tr -d '\r')"
  rc="$(printf '%s\n' "$out" | sed -n 's/^RC=//p' | tail -n 1)"
  dilog "ethtool -E trả về: rc=${rc:-?}  output='$(printf '%s' "$out" | grep -v '^RC=' | tr '\n' ' ')'"
  [ -n "$out" ] && printf '%s\n' "$out" | grep -v '^RC=' | while IFS= read -r l; do say "  $l"; done
  if [ "$rc" != "0" ]; then
    _mac_banner FAIL "GHI MAC THẤT BẠI (ethtool rc=${rc:-?})"; _mac_log "$cur" "$mac" "FAIL(ethtool rc=${rc:-?})"; return 1
  fi

  # Đọc lại EEPROM so sánh với file vừa ghi
  sums="$(dev_sh "sha1sum < $devbin; ethtool -e $MAC_IFACE raw on offset 0 length $MAC_EEPROM_LEN 2>/dev/null | sha1sum" 2>/dev/null | tr -d '\r')"
  h1="$(printf '%s\n' "$sums" | sed -n 1p | awk '{print $1}')"; h2="$(printf '%s\n' "$sums" | sed -n 2p | awk '{print $1}')"
  dilog "sha1 file đã push='$h1'  sha1 EEPROM đọc lại='$h2'"
  _mac_diag "SAU khi ghi"
  if [ -n "$h1" ] && [ "$h1" = "$h2" ]; then say "${C_G}Đọc lại EEPROM: KHỚP file đã ghi${C_0}"
  elif [ "$h2" = "da39a3ee5e6b4b0d3255bfef95601890afd80709" ] || [ -z "$h2" ]; then say "${C_Y}Không đọc lại được EEPROM (ethtool -e) để so sánh${C_0}"
  else _mac_banner FAIL "ĐỌC LẠI EEPROM KHÔNG KHỚP - GHI LỖI"; _mac_log "$cur" "$mac" "FAIL(readback)"; return 1; fi

  now="$(dev_val "cat $MAC_ADDR_FILE")"
  say "MAC đang chạy ngay sau khi ghi (trước reboot): ${now:-?}"

  if [ "$MAC_REBOOT_AFTER" != 1 ]; then
    _mac_banner WARN "ĐÃ GHI MAC $mac - CẦN REBOOT/CẤP NGUỒN LẠI ĐỂ ÁP DỤNG"; _mac_log "$cur" "$mac" "WRITTEN(no reboot)"; return 2
  fi
  say "Reboot thiết bị để áp dụng MAC mới ..."
  tp_reboot A >/dev/null 2>&1
  sleep 8
  if ! wait_device "$REBOOT_WAIT"; then
    _mac_banner WARN "ĐÃ GHI MAC $mac - KHÔNG KẾT NỐI LẠI ĐƯỢC SAU REBOOT"
    say "Đổi MAC có thể làm đổi IP (DHCP). Tìm IP mới của thiết bị rồi kiểm tra: cat $MAC_ADDR_FILE"
    _mac_log "$cur" "$mac" "WRITTEN(not verified)"; return 2
  fi
  now="$(dev_val "cat $MAC_ADDR_FILE")"
  if [ "$(printf '%s' "$now" | tr 'a-f' 'A-F')" = "$mac" ]; then
    _mac_banner OK "GHI MAC THÀNH CÔNG: $now"; _mac_log "$cur" "$mac" "OK"; return 0
  fi
  _mac_banner FAIL "SAU REBOOT MAC VẪN LÀ ${now:-?} (cần $mac)"; _mac_log "$cur" "$mac" "FAIL(after reboot: ${now:-?})"; return 1
}