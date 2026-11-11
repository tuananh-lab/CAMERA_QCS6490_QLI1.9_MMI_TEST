#!/bin/bash
# 5. RTC
: "${RTC_TOL_S:=5}"            # 5.3: lệch tối đa giữa giờ đặt và giờ đọc lại (giây)
: "${TIME_TOL_S:=60}"          # 5.4-5.6: lệch tối đa so với giờ PC (giây)
: "${RTC_OFF_MIN_S:=60}"       # 5.4-5.5: thời gian tối thiểu rút nguồn (giây)

CASES_RTC=(
  "5.1|Kiểm tra nhận diện RTC|"
  "5.2|Đọc thời gian từ RTC|"
  "5.3|Set thời gian cho RTC|"
  "5.4|Kiểm tra giữ time sau khi rút nguồn|power,manual"
  "5.5|Đồng bộ RTC (không internet)|power,manual"
  "5.6|Đồng bộ RTC (có internet)|"
)

# ---- Tiện ích ------------------------------------------------------------------
# "2026-01-27 08:49:01.123+00:00" (hoặc định dạng date thường) -> epoch (coi như UTC)
_rtc_epoch() {
  local t
  t="$(printf '%s' "$1" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}' | head -n 1)"
  if [ -n "$t" ]; then date -u -d "$t" +%s 2>/dev/null; else date -u -d "$1" +%s 2>/dev/null; fi
}
_abs() { local v=$(( $1 )); [ "$v" -lt 0 ] && v=$(( -v )); echo "$v"; }

# Đặt giờ hệ thống + RTC của thiết bị theo giờ PC (khôi phục sau các bài đổi giờ)
_rtc_restore_time() {
  dev_sh "date -u -s '$(date -u '+%Y-%m-%d %H:%M:%S')' >/dev/null 2>&1; hwclock -w; systemctl start systemd-timesyncd 2>/dev/null" >/dev/null 2>&1
}

# Đọc giờ hệ thống và RTC (sysfs, UTC) -> RS_SYS, RS_RTC, RS_PC (epoch)
_rtc_read_state() {
  local out d t
  out="$(dev_script -t 30 <<'EOF2'
echo "SYS=$(date -u +%s)"
echo "RTCDATE=$(cat /sys/class/rtc/rtc0/date 2>/dev/null)"
echo "RTCTIME=$(cat /sys/class/rtc/rtc0/time 2>/dev/null)"
EOF2
)"
  RS_PC="$(date -u +%s)"
  RS_SYS="$(printf '%s\n' "$out" | sed -n 's/^SYS=//p' | tail -n 1)"
  d="$(printf '%s\n' "$out" | sed -n 's/^RTCDATE=//p' | tail -n 1)"
  t="$(printf '%s\n' "$out" | sed -n 's/^RTCTIME=//p' | tail -n 1)"
  RS_RTC="$(date -u -d "$d $t" +%s 2>/dev/null)"
  RS_RTC_TXT="$d $t"
  [[ "$RS_SYS" =~ ^[0-9]+$ && "$RS_RTC" =~ ^[0-9]+$ ]]
}

# Đặt giờ = giờ PC, hướng dẫn rút nguồn, chờ thiết bị lên lại. Return 1 nếu đã ghi kết quả.
_rtc_power_cycle() {
  if [ "${MMI_NONINTERACTIVE:-0}" = "1" ]; then tc_skip "Cần thao tác rút nguồn (MMI_NONINTERACTIVE=1)"; return 1; fi
  _rtc_restore_time
  say "  Đã đặt giờ hệ thống và RTC theo giờ PC ($(date -u '+%F %T') UTC)."
  say "  ➜ RÚT NGUỒN thiết bị, chờ ít nhất ${RTC_OFF_MIN_S}s, rồi CẤP NGUỒN lại."
  pause_enter "Cấp nguồn xong thì nhấn Enter..."
  say "  Chờ thiết bị khởi động lại (tối đa ${REBOOT_WAIT}s)..."
  if ! wait_device "$REBOOT_WAIT"; then tc_fail "Thiết bị không kết nối lại sau ${REBOOT_WAIT}s"; return 1; fi
  sleep 3
  return 0
}

# ---- Test case ---------------------------------------------------------------------
case_5_1() {
  local out
  out="$(dev_sh "dmesg | grep -i rtc")"
  save_artifact rtc_dmesg.txt "$out"
  if [ -n "$out" ]; then tc_pass "$(printf '%s\n' "$out" | head -n 1)"
  else tc_fail "dmesg không có thông tin RTC"; fi
}

case_5_2() {
  local out rc
  tc_need hwclock || return 0
  out="$(dev_sh "hwclock -r 2>&1")"; rc=$?
  if [ $rc -eq 0 ] && printf '%s' "$out" | grep -Eq '(19|20)[0-9]{2}'; then tc_pass "RTC: $out"
  else tc_fail "rc=$rc: $out"; fi
}

# 5.3: date -s "2026-01-27 08:49:00"; hwclock -w; hwclock -r (lệch <= RTC_TOL_S). Luôn khôi phục giờ PC sau đó.
case_5_3() {
  local out w rtc got exp diff
  tc_need hwclock || return 0
  on_cleanup _rtc_restore_time
  out="$(dev_script -t 30 <<'EOF2'
systemctl stop systemd-timesyncd 2>/dev/null     # tránh NTP kéo giờ về ngay sau khi date -s
date -s "2026-01-27 08:49:00" >/dev/null
hwclock -w; echo "W_RC=$?"
hwclock -r; echo "R_RC=$?"
EOF2
)"
  save_artifact rtc_set.txt "$out"
  _rtc_restore_time
  w="$(printf '%s\n' "$out" | sed -n 's/^W_RC=//p' | tail -n 1)"
  rtc="$(printf '%s\n' "$out" | awk '/^R_RC=/{print prev} {prev=$0}')"
  exp="$(date -u -d '2026-01-27 08:49:00' +%s)"
  got="$(_rtc_epoch "$rtc")"
  if [ "$w" != "0" ]; then tc_fail "hwclock -w lỗi (rc=${w:-?})"; return 0; fi
  if [ -z "$got" ]; then tc_fail "Không đọc được giờ RTC sau khi ghi: '$rtc'"; return 0; fi
  diff=$(( got - exp ))
  if [ "$(_abs "$diff")" -le "$RTC_TOL_S" ]; then tc_pass "Đặt 2026-01-27 08:49:00, đọc lại: $rtc (lệch ${diff}s <= ${RTC_TOL_S}s); đã khôi phục giờ PC"
  else tc_fail "Đặt 2026-01-27 08:49:00, đọc lại: $rtc (lệch ${diff}s > ${RTC_TOL_S}s)"; fi
}

# 5.4: đặt RTC = giờ PC -> rút nguồn -> cấp lại -> RTC phải vẫn đúng giờ (không về mốc mặc định)
case_5_4() {
  local d
  tc_need hwclock || return 0
  _rtc_power_cycle || return 0
  if ! _rtc_read_state; then tc_fail "Không đọc được RTC/giờ hệ thống sau khi cấp nguồn lại"; return 0; fi
  d=$(( RS_RTC - RS_PC ))
  if [ "$(_abs "$d")" -le "$TIME_TOL_S" ]; then tc_pass "RTC giữ giờ sau rút nguồn: $RS_RTC_TXT UTC (lệch ${d}s so với PC)"
  else tc_fail "RTC sai giờ sau rút nguồn: $RS_RTC_TXT UTC (lệch ${d}s so với PC, cho phép ${TIME_TOL_S}s)"; fi
}

# 5.5: sau rút nguồn, giờ hệ thống và RTC phải khớp nhau và khớp giờ đã đặt.
# (Thiết bị vẫn nối mạng vì adb đi qua Ethernet nên chưa kiểm tra riêng trường hợp mất Internet.)
case_5_5() {
  local dr ds
  tc_need hwclock || return 0
  _rtc_power_cycle || return 0
  if ! _rtc_read_state; then tc_fail "Không đọc được RTC/giờ hệ thống sau khi cấp nguồn lại"; return 0; fi
  dr=$(( RS_RTC - RS_PC )); ds=$(( RS_SYS - RS_RTC ))
  if [ "$(_abs "$dr")" -le "$TIME_TOL_S" ] && [ "$(_abs "$ds")" -le "$TIME_TOL_S" ]; then
    tc_pass "RTC lệch PC ${dr}s, hệ thống lệch RTC ${ds}s (<= ${TIME_TOL_S}s)"
  else
    tc_fail "RTC lệch PC ${dr}s, hệ thống lệch RTC ${ds}s (cho phép ${TIME_TOL_S}s)"
  fi
}

# 5.6: có Internet: giờ hệ thống và RTC phải khớp giờ chuẩn (dùng giờ PC làm mốc, PC cần đồng bộ NTP)
case_5_6() {
  local net dsys drtc
  net="$(dev_sh_t 20 "ping -c 2 -W 3 8.8.8.8 2>&1" | grep -Eo '[0-9]+% packet loss')"
  if [ -z "$net" ] || [ "$net" = "100% packet loss" ]; then tc_skip "Thiết bị không có Internet (ping 8.8.8.8 lỗi)"; return 0; fi
  if ! _rtc_read_state; then tc_fail "Không đọc được RTC (/sys/class/rtc/rtc0) hoặc giờ hệ thống"; return 0; fi
  dsys=$(( RS_SYS - RS_PC )); drtc=$(( RS_RTC - RS_PC ))
  if [ "$(_abs "$dsys")" -le "$TIME_TOL_S" ] && [ "$(_abs "$drtc")" -le "$TIME_TOL_S" ]; then
    tc_pass "Hệ thống lệch ${dsys}s, RTC lệch ${drtc}s so với giờ chuẩn (<= ${TIME_TOL_S}s); RTC=$RS_RTC_TXT UTC"
  else
    tc_fail "Hệ thống lệch ${dsys}s, RTC lệch ${drtc}s so với giờ chuẩn (cho phép ${TIME_TOL_S}s)"
  fi
}
