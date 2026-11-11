#!/bin/bash
# 6. SD card. Chưa cắm thẻ: 6.1 FAIL, 6.2/6.3 SKIP.
. "$MMI_DIR/tests/_common_storage.sh"
: "${SD_DEV:=}"                    # để trống = tự tìm /dev/mmcblk[0-9] đầu tiên (tài liệu ghi mmcblk1)
: "${SD_FIO_SIZE:=128M}"
: "${SD_MIN_WRITE_MBPS:=}"
: "${SD_MIN_READ_MBPS:=}"

CASES_SD_CARD=(
  "6.1|Kiểm tra nhận SDCARD|"
  "6.2|Kiểm tra ghi|"
  "6.3|Kiểm tra đọc|"
)

# In đường dẫn thiết bị SD (rỗng nếu không có)
_sd_dev() {
  if [ -n "$SD_DEV" ]; then dev_exists "$SD_DEV" && echo "$SD_DEV"; return 0; fi
  dev_val "ls /dev/mmcblk[0-9] 2>/dev/null | head -n 1"
}

case_6_1() {
  local d size
  d="$(_sd_dev)"
  save_artifact sd_ls_dev.txt "$(dev_sh "ls /dev/mmcblk* 2>&1")"
  if [ -n "$d" ]; then
    size="$(dev_val "lsblk -dn -o SIZE $d 2>/dev/null")"
    tc_pass "Thấy $d${size:+ ($size)}"
  else
    tc_fail "Không thấy /dev/mmcblk* (chưa cắm thẻ SD?)"
  fi
}

case_6_2() {
  local d; d="$(_sd_dev)"
  [ -n "$d" ] || { tc_skip "Không có SD card (xem 6.1)"; return 0; }
  _stor_case write "$d" "$SD_FIO_SIZE" mmc-write "$SD_MIN_WRITE_MBPS" "Ghi SD"
}

case_6_3() {
  local d; d="$(_sd_dev)"
  [ -n "$d" ] || { tc_skip "Không có SD card (xem 6.1)"; return 0; }
  _stor_case read "$d" "$SD_FIO_SIZE" mmc-read "$SD_MIN_READ_MBPS" "Đọc SD"
}
