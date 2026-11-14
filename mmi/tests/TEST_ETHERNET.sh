#!/bin/bash
# 2. Ethernet - iperf3: PC chạy iperf3 server (tự bật/tắt), thiết bị chạy client.
# Output iperf3 (dạng text như chạy tay) được in ra terminal + log + artifacts/iperf3_*.txt
# Nhớ mở firewall PC cho cổng TCP $IPERF_PORT.
: "${IPERF_BIDIR_MIN_MBPS:=800}"     # --bidir: mỗi chiều phải > 800 Mbps

CASES_ETHERNET=(
  "2.1|Kiểm tra tốc độ nhận|"
  "2.2|Kiểm tra tốc độ truyền|"
  "2.3|Kiểm tra tốc độ truyền và nhận|"
)

# _eth_iperf <tên> <tùy chọn iperf3>: chạy client trên thiết bị, kết quả text vào $ETH_TEXT
_eth_iperf() {
  local name="$1" opt="$2" pc
  pc="$(pc_ip)"
  if [ -z "$pc" ]; then tc_fail "Không xác định được IP của PC cùng mạng với $DEVICE_IP"; return 1; fi
  if ! iperf_server_start; then
    tc_fail "PC không chạy được iperf3 server (cổng $IPERF_PORT): cài iperf3 hoặc cổng đang bị chiếm"; return 1
  fi
  say "  \$ iperf3 -c $pc -p $IPERF_PORT -t $IPERF_TIME $opt   (khoảng ${IPERF_TIME}s, chờ kết quả...)"
  ETH_TEXT="$(dev_sh_t $((IPERF_TIME + 40)) "iperf3 -c $pc -p $IPERF_PORT -t $IPERF_TIME $opt 2>&1")"
  printf '%s\n' "$ETH_TEXT" > "$(artifact "iperf3_${name}.txt")"
  printf '%s\n' "$ETH_TEXT" | tee -a "$LOG_FILE"
  return 0
}

# _recv_mbps [regex]: Mbps của dòng "receiver" cuối cùng khớp regex (rỗng = mọi dòng)
_recv_mbps() {
  printf '%s\n' "$ETH_TEXT" | grep -E "$1.*receiver[[:space:]]*\$" | tail -n 1 | awk '{
    for (i = 1; i <= NF; i++) if ($i ~ /bits\/sec$/) {
      v = $(i - 1); u = substr($i, 1, 1)
      if (u == "G") v *= 1000; else if (u == "K") v /= 1000; else if (u == "b") v /= 1000000
      printf "%.0f", v; exit } }'
}
_gt() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>b)}'; }
_eth_err() { printf '%s' "$ETH_TEXT" | tr '\n' ' ' | head -c 200; }

# 2.1: -R => thiết bị là bên nhận
case_2_1() {
  local m
  _eth_iperf rx "-R" || return 0
  m="$(_recv_mbps '')"
  if [ -z "$m" ]; then tc_fail "Không đọc được kết quả iperf3: $(_eth_err)"
  elif _gt "$m" "$IPERF_MIN_MBPS"; then tc_pass "Nhận: ${m} Mbps (> ${IPERF_MIN_MBPS})"
  else tc_fail "Nhận: ${m} Mbps (yêu cầu > ${IPERF_MIN_MBPS})"; fi
}

# 2.2: thiết bị gửi, PC nhận (số liệu phía nhận)
case_2_2() {
  local m
  _eth_iperf tx "" || return 0
  m="$(_recv_mbps '')"
  if [ -z "$m" ]; then tc_fail "Không đọc được kết quả iperf3: $(_eth_err)"
  elif _gt "$m" "$IPERF_MIN_MBPS"; then tc_pass "Truyền: ${m} Mbps (> ${IPERF_MIN_MBPS})"
  else tc_fail "Truyền: ${m} Mbps (yêu cầu > ${IPERF_MIN_MBPS})"; fi
}

# 2.3: --bidir, mỗi chiều > IPERF_BIDIR_MIN_MBPS (800)
case_2_3() {
  local tx rx
  _eth_iperf bidir "--bidir" || return 0
  tx="$(_recv_mbps '\[TX-C\]')"
  rx="$(_recv_mbps '\[RX-C\]')"
  if [ -z "$tx" ] || [ -z "$rx" ]; then
    tc_fail "Không đọc được kết quả --bidir (iperf3 cần >= 3.7): $(_eth_err)"
  elif _gt "$tx" "$IPERF_BIDIR_MIN_MBPS" && _gt "$rx" "$IPERF_BIDIR_MIN_MBPS"; then
    tc_pass "Truyền: ${tx} Mbps, nhận: ${rx} Mbps (mỗi chiều > ${IPERF_BIDIR_MIN_MBPS})"
  else
    tc_fail "Truyền: ${tx} Mbps, nhận: ${rx} Mbps (yêu cầu mỗi chiều > ${IPERF_BIDIR_MIN_MBPS})"
  fi
}
