#!/bin/bash
# 3. NVMe. Chưa lắp thiết bị: 3.1 FAIL, 3.2/3.3 SKIP.
. "$MMI_DIR/tests/_common_storage.sh"
: "${NVME_DEV:=/dev/nvme0n1}"
: "${NVME_MIN_WRITE_MBPS:=}"       # chưa chốt ngưỡng: để trống = chỉ báo số đo, Pass nếu không lỗi
: "${NVME_MIN_READ_MBPS:=}"
: "${NVME_FIO_SIZE:=2G}"

CASES_NVME=(
  "3.1|Kiểm tra NVME|clusteronly"
  "3.2|Kiểm tra tốc độ ghi của NVME|clusteronly"
  "3.3|Kiểm tra tốc độ đọc của NVME|clusteronly"
)

case_3_1() {
  local pci node line
  pci="$(dev_sh "lspci -km 2>&1")"
  save_artifact nvme_lspci.txt "$pci"
  dev_exists "$NVME_DEV" && node="có $NVME_DEV" || node=""
  line="$(printf '%s\n' "$pci" | grep -iE 'non-volatile|nvm express|nvme' | head -n 1)"
  if [ -n "$line" ] && [ -n "$node" ]; then tc_pass "lspci: $line; $node"
  elif [ -n "$line" ]; then tc_fail "lspci thấy NVMe nhưng không có $NVME_DEV (driver chưa nhận): $line"
  else tc_fail "Không thấy thiết bị NVMe (lspci chỉ có: $(printf '%s\n' "$pci" | grep -c '^[0-9a-f]') thiết bị PCI)"; fi
}

case_3_2() {
  dev_exists "$NVME_DEV" || { tc_skip "Không thấy $NVME_DEV (xem 3.1)"; return 0; }
  _stor_case write "$NVME_DEV" "$NVME_FIO_SIZE" nvme-write "$NVME_MIN_WRITE_MBPS" "Ghi NVMe"
}

case_3_3() {
  dev_exists "$NVME_DEV" || { tc_skip "Không thấy $NVME_DEV (xem 3.1)"; return 0; }
  _stor_case read "$NVME_DEV" "$NVME_FIO_SIZE" nvme-read "$NVME_MIN_READ_MBPS" "Đọc NVMe"
}
