#!/bin/bash
# 4. GPS: đọc bản tin NMEA từ $GPS_TTY. 4.3-4.5 cần ăng-ten nhìn thấy trời (trong nhà sẽ FAIL).
: "${GPS_CAPTURE_S:=15}"           # thời gian thu NMEA (giây)
: "${GPS_NEED_SENTENCES:=GNGGA GPGSA GLGSA GPGSV GLGSV GNRMC GNVTG}"
: "${GPS_MIN_REPEAT:=2}"           # mỗi bản tin phải xuất hiện ít nhất N lần ("liên tục")

CASES_GPS=(
  "4.1|Kiểm tra nhận dữ liệu|"
  "4.2|Kiểm tra bắt vệ tinh|"
  "4.3|Kiểm tra GNSS Fix|"
  "4.4|Kiểm tra tọa độ|"
  "4.5|Kiểm tra trạng thái Navigation|"
)

# Thu NMEA một lần cho mỗi lần chạy (các mục 4.1-4.5 dùng chung), kết quả trong $GPS_DATA
_gps_capture() {
  [ "${GPS_CAP_RUN:-}" = "$REPORT_DIR" ] && return 0
  say "${C_Y}  ⚠ LƯU Ý GPS: ăng-ten GPS phải đặt NGOÀI TRỜI, nhìn thấy bầu trời (không che chắn).${C_0}"
  say "${C_Y}    Trong nhà hoặc ăng-ten chưa cắm: 4.2 - 4.5 sẽ FAIL (không bắt được vệ tinh/không Fix).${C_0}"
  say "  Thu bản tin NMEA từ $GPS_TTY trong ${GPS_CAPTURE_S}s ..."
  GPS_DATA="$(dev_script -t $((GPS_CAPTURE_S + 25)) TTY="$GPS_TTY" SECS="$GPS_CAPTURE_S" <<'EOF2'
cat "$TTY" > /tmp/mmi_gps.txt 2>/dev/null &
p=$!
sleep "$SECS"
kill $p 2>/dev/null; sleep 1; kill -9 $p 2>/dev/null
cat /tmp/mmi_gps.txt 2>/dev/null; rm -f /tmp/mmi_gps.txt
EOF2
)"
  GPS_DATA="$(printf '%s\n' "$GPS_DATA" | tr -d '\r')"
  save_artifact gps_nmea.txt "$GPS_DATA"
  GPS_CAP_RUN="$REPORT_DIR"
}

# Dòng hoàn chỉnh (có *checksum) cuối cùng của bản tin $1 (vd GNGGA)
_nmea_last() {
  printf '%s\n' "$GPS_DATA" | awk -F, -v t="\$$1" '$1==t && $0 ~ /\*[0-9A-Fa-f][0-9A-Fa-f]/ {l=$0} END{print l}'
}
_nmea_count() { printf '%s\n' "$GPS_DATA" | awk -F, -v t="\$$1" '$1==t{c++} END{print c+0}'; }
# Số vệ tinh nhìn thấy lớn nhất trong các bản tin GSV (trường 4)
_gsv_total() { printf '%s\n' "$GPS_DATA" | awk -F, -v t="\$$1" '$1==t && $4+0>m {m=$4+0} END{print m+0}'; }
# ddmm.mmmm + N/S/E/W -> độ thập phân (rỗng nếu không hợp lệ)
_nmea_deg() {
  awk -v v="$1" -v h="$2" 'BEGIN{
    if (v !~ /^[0-9]+\.?[0-9]*$/ || h !~ /^[NSEW]$/) exit
    d = int(v / 100); m = v - d * 100
    if (m >= 60) exit
    r = d + m / 60; if (h == "S" || h == "W") r = -r
    printf "%.6f", r }'
}

case_4_1() {
  local s c miss="" counts=""
  _gps_capture
  if [ -z "$(printf '%s' "$GPS_DATA" | tr -d '[:space:]')" ]; then
    tc_fail "Không nhận được dữ liệu từ $GPS_TTY trong ${GPS_CAPTURE_S}s"; return 0
  fi
  for s in $GPS_NEED_SENTENCES; do
    c="$(_nmea_count "$s")"; counts="$counts $s=$c"
    [ "$c" -ge "$GPS_MIN_REPEAT" ] || miss="$miss $s"
  done
  if [ -z "$miss" ]; then tc_pass "Đủ bản tin (mỗi loại >= ${GPS_MIN_REPEAT} lần/${GPS_CAPTURE_S}s):$counts"
  else tc_fail "Thiếu/ít bản tin:$miss (đếm:$counts)"; fi
}

case_4_2() {
  local gp gl
  _gps_capture
  gp="$(_gsv_total GPGSV)"; gl="$(_gsv_total GLGSV)"
  if [ $((gp + gl)) -gt 0 ]; then tc_pass "Nhìn thấy vệ tinh: GPS=$gp, GLONASS=$gl"
  else tc_fail "Số vệ tinh nhìn thấy = 0 (GPS=$gp, GLONASS=$gl)"; fi
}

case_4_3() {
  local l fix sats
  _gps_capture
  l="$(_nmea_last GNGGA)"
  if [ -z "$l" ]; then tc_fail "Không có bản tin GNGGA hoàn chỉnh"; return 0; fi
  fix="$(printf '%s' "$l" | awk -F, '{print $7}')"; sats="$(printf '%s' "$l" | awk -F, '{print $8}')"
  if [[ "$fix" =~ ^[0-9]+$ && "$sats" =~ ^[0-9]+$ ]] && [ "$fix" -gt 0 ] && [ "$sats" -gt 0 ]; then
    tc_pass "Fix quality=$fix, số vệ tinh dùng=$sats"
  else
    tc_fail "Chưa Fix: fix quality='${fix:-?}', số vệ tinh dùng='${sats:-?}' (cần đặt ăng-ten nhìn trời)"
  fi
}

case_4_4() {
  local l lat lon
  _gps_capture
  l="$(_nmea_last GNGGA)"
  if [ -z "$l" ]; then l="$(_nmea_last GNRMC)"; lat="$(printf '%s' "$l" | awk -F, '{print $4 "," $5}')"; lon="$(printf '%s' "$l" | awk -F, '{print $6 "," $7}')"
  else lat="$(printf '%s' "$l" | awk -F, '{print $3 "," $4}')"; lon="$(printf '%s' "$l" | awk -F, '{print $5 "," $6}')"; fi
  if [ -z "$l" ]; then tc_fail "Không có bản tin GNGGA/GNRMC hoàn chỉnh"; return 0; fi
  lat="$(_nmea_deg "${lat%%,*}" "${lat##*,}")"; lon="$(_nmea_deg "${lon%%,*}" "${lon##*,}")"
  if [ -n "$lat" ] && [ -n "$lon" ]; then tc_pass "Tọa độ hợp lệ: lat=$lat, lon=$lon"
  else tc_fail "Chưa có tọa độ hợp lệ (trường vị trí trống hoặc sai định dạng): $l"; fi
}

case_4_5() {
  local l st tm dt lat lon
  _gps_capture
  l="$(_nmea_last GNRMC)"
  if [ -z "$l" ]; then tc_fail "Không có bản tin GNRMC hoàn chỉnh"; return 0; fi
  st="$(printf '%s' "$l" | awk -F, '{print $3}')"
  tm="$(printf '%s' "$l" | awk -F, '{print $2}')"; dt="$(printf '%s' "$l" | awk -F, '{print $10}')"
  lat="$(_nmea_deg "$(printf '%s' "$l" | awk -F, '{print $4}')" "$(printf '%s' "$l" | awk -F, '{print $5}')")"
  lon="$(_nmea_deg "$(printf '%s' "$l" | awk -F, '{print $6}')" "$(printf '%s' "$l" | awk -F, '{print $7}')")"
  if [ "$st" = "A" ] && [[ "$tm" =~ ^[0-9]{6} ]] && [[ "$dt" =~ ^[0-9]{6}$ ]] && [ -n "$lat" ] && [ -n "$lon" ]; then
    tc_pass "Status=A, giờ=$tm, ngày=$dt, vị trí=$lat,$lon"
  else
    tc_fail "Status='${st:-?}' (cần A), giờ='$tm', ngày='$dt', vị trí='${lat:-}${lat:+,}${lon:-}'"
  fi
}
