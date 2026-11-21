#!/bin/bash
# 5. RTC
: "${RTC_TOL_S:=5}"            # 5.3: lệch tối đa giữa giờ đặt và giờ đọc lại (giây)
: "${TIME_TOL_S:=60}"          # 5.4-5.6: lệch tối đa so với giờ mong đợi (giây)
: "${RTC_OFF_MIN_S:=20}"       # 5.4-5.5: thời gian tối thiểu mất nguồn (giây)
: "${RTC_SET_TIME:=2026-01-27 08:49:00}"   # 5.4-5.5: giờ (UTC) đặt cho RTC trước khi rút nguồn, giống giờ trong tài liệu test
: "${RTC_NTP_WAIT_S:=60}"      # 5.6: chờ tối đa để NTP kéo giờ hệ thống về đúng (giây)
: "${RTC_UNPLUG_S:=20}"        # 5.4-5.5: đếm lùi sau khi nhắc RÚT NGUỒN (giây, nên >= RTC_OFF_MIN_S)
: "${RTC_BOOT_WAIT_S:=30}"     # 5.5: đếm lùi chờ thiết bị khởi động xong rồi mới nhắc cắm lại Ethernet

CASES_RTC=(
  "5.1|Kiểm tra nhận diện RTC|"
  "5.2|Đọc thời gian từ RTC|"
  "5.3|Set thời gian cho RTC|"
  "5.4|Kiểm tra giữ time sau khi rút nguồn|manual"
  "5.5|Đồng bộ RTC (không internet)|manual"
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

# Đếm lùi N giây trên terminal (1 dòng cập nhật liên tục); không phải terminal thì chỉ chờ.
# $3 = skip: nhấn Enter/phím bất kỳ để kết thúc đếm lùi sớm.
_rtc_countdown() {
  local n="${1:-0}" label="$2" skip="${3:-}" end
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  [ -n "${LOG_FILE:-}" ] && echo "  $label: ${n}s" >> "$LOG_FILE"
  if [ ! -t 1 ]; then sleep "$n"; return 0; fi
  end=$((SECONDS + n))
  while [ "$SECONDS" -lt "$end" ]; do
    printf '\r  %s: %ds   ' "$label" "$((end - SECONDS))"
    if [ "$skip" = skip ] && [ -t 0 ]; then read -r -t 1 -n 1 _ && break; else sleep 1; fi
  done
  printf '\r%*s\r' 60 ''
}

# Đặt giờ hệ thống + RTC của thiết bị theo giờ PC (khôi phục sau các bài đổi giờ)
# và bật lại các dịch vụ đồng bộ giờ mà 5.4/5.5 đã tắt (danh sách nằm trong /etc/mmi_ntp_svcs trên thiết bị)
_rtc_restore_time() {
  local svc='if [ -f /etc/mmi_ntp_svcs ]; then for s in $(cat /etc/mmi_ntp_svcs); do systemctl enable "$s" >/dev/null 2>&1; systemctl start "$s" >/dev/null 2>&1; done; rm -f /etc/mmi_ntp_svcs; fi'
  dev_sh "date -u -s '$(date -u '+%Y-%m-%d %H:%M:%S')' >/dev/null 2>&1; hwclock -w; $svc; systemctl start systemd-timesyncd 2>/dev/null" >/dev/null 2>&1
}

# Đọc giờ hệ thống, RTC (sysfs, UTC), boot_id, uptime, dòng kernel nạp giờ từ RTC lúc boot
# -> RS_SYS, RS_RTC, RS_PC (epoch), RS_BOOT, RS_UP, RS_HCTO (epoch kernel nạp từ RTC, rỗng nếu dmesg không có)
_rtc_read_state() {
  local out d t
  out="$(dev_script -t 30 <<'EOF2'
echo "SYS=$(date -u +%s)"
echo "RTCDATE=$(cat /sys/class/rtc/rtc0/date 2>/dev/null)"
echo "RTCTIME=$(cat /sys/class/rtc/rtc0/time 2>/dev/null)"
echo "BOOT=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)"
echo "UP=$(cut -d. -f1 /proc/uptime 2>/dev/null)"
echo "HCTO=$(dmesg 2>/dev/null | grep -i 'setting system clock' | head -n 1)"
EOF2
)"
  RS_PC="$(date -u +%s)"
  RS_SYS="$(printf '%s\n' "$out" | sed -n 's/^SYS=//p' | tail -n 1)"
  d="$(printf '%s\n' "$out" | sed -n 's/^RTCDATE=//p' | tail -n 1)"
  t="$(printf '%s\n' "$out" | sed -n 's/^RTCTIME=//p' | tail -n 1)"
  RS_BOOT="$(printf '%s\n' "$out" | sed -n 's/^BOOT=//p' | tail -n 1)"
  RS_UP="$(printf '%s\n' "$out" | sed -n 's/^UP=//p' | tail -n 1)"
  RS_HCTO="$(printf '%s\n' "$out" | sed -n 's/^HCTO=//p' | tail -n 1 | grep -Eo '\([0-9]{9,}\)' | tr -dc '0-9')"
  RS_RTC=""
  [ -n "$d" ] && [ -n "$t" ] && RS_RTC="$(date -u -d "$d $t" +%s 2>/dev/null)"     # sysfs rỗng (RTC báo low voltage) thì KHÔNG tính (date -d " " = 0h hôm nay)
  RS_RTC_TXT="$d $t"
  [[ "$RS_SYS" =~ ^[0-9]+$ && "$RS_RTC" =~ ^[0-9]+$ ]]
}

# 5.4 / 5.5: đặt giờ hệ thống + RTC = RTC_SET_TIME (UTC), hướng dẫn rút nguồn, chờ thiết bị lên lại, đọc trạng thái.
#   $1 = noeth: thêm bước rút / cắm lại cáp Ethernet (5.5: thiết bị khởi động khi không có mạng).
# Return 0: đã đọc xong, RS_EXP = giờ mong đợi hiện tại (RTC_SET_TIME + thời gian đã trôi theo đồng hồ PC), RS_OFF = số giây mất nguồn ước tính.
# Return 1: đã ghi kết quả FAIL. Cuối cùng luôn trả giờ thiết bị về giờ PC và bật lại NTP.
_rtc_power_cycle() {
  local noeth="${1:-}" out w exp0 t0 boot0 e diag ok=0 i
  if [ "${MMI_NONINTERACTIVE:-0}" = "1" ]; then tc_skip "Cần thao tác rút nguồn (MMI_NONINTERACTIVE=1)"; return 1; fi
  exp0="$(date -u -d "$RTC_SET_TIME" +%s 2>/dev/null)"
  [[ "$exp0" =~ ^[0-9]+$ ]] || { tc_fail "RTC_SET_TIME không hợp lệ: '$RTC_SET_TIME'"; return 1; }
  on_cleanup _rtc_restore_time
  out="$(dev_script -t 30 SET="$RTC_SET_TIME" <<'EOF2'
# tắt các dịch vụ đồng bộ giờ (kể cả sau khi khởi động lại) để cắm lại Ethernet có Internet cũng không bị NTP chỉnh giờ trước khi đọc.
# Danh sách dịch vụ đang bật ghi vào /etc/mmi_ntp_svcs để _rtc_restore_time bật lại.
[ -f /etc/mmi_ntp_svcs ] || : > /etc/mmi_ntp_svcs
for s in systemd-timesyncd chronyd ntpd; do
  systemctl is-enabled "$s" >/dev/null 2>&1 && echo "$s" >> /etc/mmi_ntp_svcs
  systemctl disable --now "$s" >/dev/null 2>&1
done
echo "NTP_EN=$(systemctl is-enabled systemd-timesyncd 2>&1 | head -n 1)"
date -u -s "$SET" >/dev/null
hwclock -w; echo "W_RC=$?"
EOF2
)"
  t0="$(date -u +%s)"
  save_artifact rtc_power_set.txt "$out"
  w="$(printf '%s\n' "$out" | sed -n 's/^W_RC=//p' | tail -n 1)"
  if [ "$w" != "0" ]; then tc_fail "Không đặt được giờ RTC trước khi rút nguồn (hwclock -w rc=${w:-?})"; return 1; fi
  if ! _rtc_read_state || [ "$(_abs "$(( RS_RTC - exp0 - (RS_PC - t0) ))")" -gt "$RTC_TOL_S" ]; then
    tc_fail "RTC không nhận giờ đặt ($RTC_SET_TIME UTC), đọc lại: ${RS_RTC_TXT:-?}"; return 1
  fi
  boot0="$RS_BOOT"
  say "  Đã đặt giờ hệ thống và RTC = $RTC_SET_TIME UTC."
  if [ "$(printf '%s\n' "$out" | sed -n 's/^NTP_EN=//p' | tail -n 1)" = "enabled" ]; then
    say "  ${C_Y}CẢNH BÁO: không tắt được dịch vụ đồng bộ giờ (rootfs chỉ đọc?). Nếu cắm lại Ethernet có Internet, NTP có thể chỉnh giờ trước khi tool đọc.${C_0}"
  fi
  if [ "$noeth" = noeth ]; then
    say "  ➜ RÚT CÁP ETHERNET rồi RÚT NGUỒN thiết bị"
  else
    say "  ➜ RÚT NGUỒN thiết bị"
  fi
  _rtc_countdown "$RTC_UNPLUG_S" "Mất nguồn"
  if [ "$noeth" = noeth ]; then
    say "  ➜ CẤP NGUỒN lại (chưa cắm Ethernet)"
    _rtc_countdown "$RTC_BOOT_WAIT_S" "Chờ boot" skip      # Enter: bỏ qua đếm lùi nếu thiết bị đã lên sớm
    say "  ➜ CẮM LẠI Ethernet"                              # chỉ hiện SAU khi đã chờ thiết bị boot; cắm xong tool tự kết nối, không cần nhấn Enter
  else
    say "  ➜ CẤP NGUỒN lại"
  fi
  say "  Chờ thiết bị kết nối lại..."
  if ! wait_device "$REBOOT_WAIT"; then tc_fail "Thiết bị không kết nối lại sau ${REBOOT_WAIT}s"; return 1; fi
  for i in $(seq 1 15); do                            # RTC/dịch vụ có thể chưa sẵn sàng ngay sau khi adb lên: đọc ngay, lỗi thì thử lại mỗi 1s (tối đa 15 lần)
    if _rtc_read_state; then ok=1; break; fi
    sleep 1
  done
  if [ "$ok" != 1 ]; then
    diag="$(dev_sh "hwclock -r 2>&1; dmesg | grep -i rtc | tail -n 3" | tr '\n' ' ')"   # đọc TRƯỚC khi khôi phục giờ (hwclock -w sẽ ghi lại RTC)
    save_artifact rtc_after_diag.txt "$diag"
    _rtc_restore_time
    tc_fail "Không đọc được RTC sau khi mất nguồn ~$((RS_PC - t0))s (sysfs rtc0 rỗng sau 15 lần thử). hwclock/dmesg: ${diag:0:200}"
    return 1
  fi
  _rtc_restore_time                                   # trả giờ thiết bị về giờ PC + bật lại NTP (giá trị cần dùng đã đọc xong ở trên)
  save_artifact rtc_power_after.txt "RTC=$RS_RTC_TXT SYS=$RS_SYS PC=$RS_PC BOOT=$RS_BOOT UP=$RS_UP HCTO=$RS_HCTO"
  RS_EXP=$(( exp0 + RS_PC - t0 )); e=$(( RS_PC - t0 )); RS_OFF="?"
  if [ -n "$boot0" ] && [ "$RS_BOOT" = "$boot0" ]; then tc_fail "Thiết bị chưa khởi động lại (boot_id không đổi): chưa rút nguồn?"; return 1; fi
  if [[ "$RS_UP" =~ ^[0-9]+$ ]]; then
    RS_OFF=$(( e - RS_UP ))      # từ lúc đặt giờ đến lúc kernel khởi động = thời gian rút nguồn + chờ
    if [ "$RS_OFF" -lt "$RTC_OFF_MIN_S" ]; then tc_fail "Mất nguồn khoảng ${RS_OFF}s < ${RTC_OFF_MIN_S}s (rút nguồn chưa đủ lâu hoặc chưa rút nguồn thật)"; return 1; fi
  fi
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

# 5.4: đặt RTC = RTC_SET_TIME -> rút nguồn ~30s -> cấp lại -> RTC phải vẫn đúng giờ (giờ đặt + thời gian đã trôi)
case_5_4() {
  local d
  tc_need hwclock || return 0
  _rtc_power_cycle || return 0
  d=$(( RS_RTC - RS_EXP ))
  if [ "$(_abs "$d")" -le "$TIME_TOL_S" ]; then tc_pass "RTC giữ giờ sau khi mất nguồn ~${RS_OFF}s: $RS_RTC_TXT UTC (lệch ${d}s so với giờ mong đợi)"
  else tc_fail "RTC sai giờ sau khi mất nguồn ~${RS_OFF}s: $RS_RTC_TXT UTC (lệch ${d}s so với giờ mong đợi, cho phép ${TIME_TOL_S}s)"; fi
}

# 5.5: như 5.4 nhưng thiết bị khởi động khi KHÔNG có Ethernet/Internet: giờ hệ thống VÀ RTC đều phải khớp giờ đã đặt.
# Giờ hệ thống: đạt nếu giờ hiện tại đúng, hoặc (khi mạng được cắm lại và NTP đã chỉnh giờ) kernel đã nạp đúng giờ từ RTC lúc boot (dmesg).
case_5_5() {
  local dr ds dh sys_ok=0 note=""
  tc_need hwclock || return 0
  _rtc_power_cycle noeth || return 0
  dr=$(( RS_RTC - RS_EXP )); ds=$(( RS_SYS - RS_EXP ))
  if [ "$(_abs "$ds")" -le "$TIME_TOL_S" ]; then
    sys_ok=1
  elif [[ "$RS_HCTO" =~ ^[0-9]+$ ]]; then
    dh=$(( RS_HCTO - (RS_EXP - ${RS_UP:-0}) ))      # giờ kernel nạp từ RTC lúc boot so với giờ mong đợi tại thời điểm boot
    if [ "$(_abs "$dh")" -le "$TIME_TOL_S" ]; then sys_ok=1; note=" (giờ hiện tại đã bị chỉnh sau khi cắm mạng, nhưng lúc boot kernel nạp đúng giờ từ RTC: lệch ${dh}s)"; fi
  fi
  if [ "$(_abs "$dr")" -le "$TIME_TOL_S" ] && [ "$sys_ok" = 1 ]; then
    tc_pass "Mất nguồn ~${RS_OFF}s không mạng: RTC lệch ${dr}s, hệ thống lệch ${ds}s so với giờ đã đặt (<= ${TIME_TOL_S}s)$note"
  else
    tc_fail "Mất nguồn ~${RS_OFF}s không mạng: RTC lệch ${dr}s, hệ thống lệch ${ds}s so với giờ đã đặt (cho phép ${TIME_TOL_S}s); kernel nạp lúc boot: ${RS_HCTO:-không có trong dmesg}"
  fi
}

# 5.6: có Internet: làm lệch giờ hệ thống, bật NTP, chờ tối đa RTC_NTP_WAIT_S giây cho NTP kéo về đúng;
# rồi giờ hệ thống và RTC đều phải khớp giờ chuẩn (dùng giờ PC làm mốc, PC cần đồng bộ NTP)
case_5_6() {
  local net dsys drtc w=0 w0=$SECONDS
  net="$(dev_sh_t 20 "ping -c 2 -W 3 8.8.8.8 2>&1" | grep -Eo '[0-9]+% packet loss')"
  if [ -z "$net" ] || [ "$net" = "100% packet loss" ]; then tc_skip "Thiết bị không có Internet (ping 8.8.8.8 lỗi)"; return 0; fi
  on_cleanup _rtc_restore_time
  dev_sh_t 30 "date -u -s '$RTC_SET_TIME' >/dev/null; systemctl restart systemd-timesyncd 2>/dev/null" >/dev/null 2>&1
  say "  Chờ NTP đồng bộ giờ..."
  while :; do
    if _rtc_read_state && [ "$(_abs "$(( RS_SYS - RS_PC ))")" -le "$TIME_TOL_S" ]; then break; fi
    [ "$w" -ge "$RTC_NTP_WAIT_S" ] && break
    [ -t 1 ] && printf '\r  Chờ NTP: %ds   ' "$(( RTC_NTP_WAIT_S - w ))"
    sleep 1; w=$((SECONDS - w0))
  done
  [ -t 1 ] && printf '\r%*s\r' 60 ''
  _rtc_restore_time                                   # trả giờ thiết bị về giờ PC (giá trị cần dùng đã đọc xong)
  if [ -z "$RS_RTC" ] || [ -z "$RS_SYS" ]; then tc_fail "Không đọc được RTC (/sys/class/rtc/rtc0) hoặc giờ hệ thống"; return 0; fi
  dsys=$(( RS_SYS - RS_PC )); drtc=$(( RS_RTC - RS_PC ))
  if [ "$(_abs "$dsys")" -le "$TIME_TOL_S" ] && [ "$(_abs "$drtc")" -le "$TIME_TOL_S" ]; then
    tc_pass "NTP kéo giờ hệ thống về đúng sau ~${w}s: hệ thống lệch ${dsys}s, RTC lệch ${drtc}s so với giờ chuẩn (<= ${TIME_TOL_S}s); RTC=$RS_RTC_TXT UTC"
  else
    tc_fail "Sau ${w}s: hệ thống lệch ${dsys}s, RTC lệch ${drtc}s so với giờ chuẩn (cho phép ${TIME_TOL_S}s) - NTP không đồng bộ hoặc RTC sai"
  fi
}
