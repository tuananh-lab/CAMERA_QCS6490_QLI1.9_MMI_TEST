#!/bin/bash
# 12. Sensor
# Tiêu chí PASS theo DỮ LIỆU của từng sensor (khác 0): accel/gyro/mag = mẫu "data": [x, y, z]; SHT4x = nhiệt độ + độ ẩm.
# 12.1 (từ khóa trong ssc_sensor_info) còn TẠM THỜI: chỉnh SENSOR_EXPECT theo output thật. Ngưỡng: SENSOR_MIN_EVENTS_*, SENSOR_NONZERO_PCT (config.sh).
CASES_SENSOR=(
  "12.1|Kiểm tra các Sensor|"
  "12.2|Kiểm tra gia tốc và Gyro|"
  "12.3|Kiểm tra từ trường|"
  "12.4|Kiểm tra đọc nhiệt độ và độ ẩm|"
  "12.5|Kiểm tra nhiệt độ, độ ẩm liên tục|"
)

# 12.1: ssc_sensor_info chạy được và có đủ từ khóa trong SENSOR_EXPECT
case_12_1() {
  local out t miss="" n
  tc_need ssc_sensor_info || return 0
  out="$(dev_script -t 40 <<'EOF2'
ssc_sensor_info 2>&1
echo "RC=$?"
EOF2
)"
  save_artifact ssc_sensor_info.txt "$out"
  n="$(printf '%s\n' "$out" | grep -c .)"
  for t in $SENSOR_EXPECT; do printf '%s' "$out" | grep -qi "$t" || miss="$miss $t"; done
  if [ "$n" -lt 3 ]; then tc_fail "Không có thông tin sensor (output $n dòng): $(printf '%s' "$out" | head -c 150)"
  elif [ -n "$miss" ]; then tc_fail "Thiếu sensor:$miss (xem artifacts/ssc_sensor_info.txt)"
  else tc_pass "Thấy đủ sensor: $SENSOR_EXPECT ($n dòng output)"; fi
}

# _see_parse <file> <sensor> <min_mẫu> <số giá trị/mẫu> <% mẫu khác 0>: in "OK<TAB>diễn giải" hoặc "FAIL<TAB>lý do"
# Mẫu dữ liệu của see_workhorse -display_events=1 là các khối  "data" : [ x, y, z ]  (accel m/s2, gyro rad/s, mag uT).
# Khối cấu hình (sample_rate, range, bias, comp_matrix...) không có key "data" nên không bị tính nhầm.
_see_parse() {
  python3 - "$@" <<'PY'
import re, sys
path, sensor, min_ev, dim, pct = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), float(sys.argv[5])
text = open(path, encoding="utf-8", errors="replace").read()
num = re.compile(r"-?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?")
ev = [[float(x) for x in num.findall(m.group(1))] for m in re.finditer(r'"data"\s*:\s*\[([^\]]*)\]', text)]
ev = [v for v in ev if v]
def out(ok, msg): print(("OK" if ok else "FAIL") + "\t" + msg); sys.exit(0)
if not ev:
    keys = sorted(set(re.findall(r'"(\w+)"\s*:', text)))[:12]
    out(False, "%s: không có mẫu dữ liệu nào (không thấy \"data\": [...]); key trong output: %s (xem artifacts/see_%s.txt)" % (sensor, " ".join(keys) or "-", sensor))
n = len(ev)
if n < min_ev: out(False, "%s: chỉ %d mẫu trong 10s (cần >= %d)" % (sensor, n, min_ev))
good = [v for v in ev if len(v) == dim]
if len(good) * 10 < n * 9: out(False, "%s: mẫu có %d giá trị, cần %d giá trị (x y z)" % (sensor, len(ev[0]), dim))
nz = sum(1 for v in good if any(x != 0.0 for x in v)) * 100.0 / len(good)
if nz < pct: out(False, "%s: chỉ %.0f%% mẫu có giá trị khác 0 (cần >= %.0f%%)" % (sensor, nz, pct))
names, dead, rng = "xyz", [], []
for i in range(dim):
    col = [v[i] for v in good]
    if all(x == 0.0 for x in col): dead.append(names[i] if i < 3 else str(i))
    rng.append("%s[%.3f..%.3f]" % (names[i] if i < 3 else i, min(col), max(col)))
if dead: out(False, "%s: trục %s luôn = 0 (%d mẫu)" % (sensor, ",".join(dead), n))
out(True, "%s: %d mẫu/10s, %.0f%% khác 0, %s" % (sensor, n, nz, " ".join(rng)))
PY
}

# _see_check <sensor> <rate> <min_mẫu> [số giá trị/mẫu=3]: return 0 nếu đạt, SEE_MSG = diễn giải
_see_check() {
  local s="$1" rate="$2" min="$3" dim="${4:-3}" out rc res
  out="$(dev_script -t 45 <<EOF2
see_workhorse -sensor=$s -sample_rate=$rate -duration=10 -display_events=1 2>&1
echo "RC=\$?"
EOF2
)"
  save_artifact "see_$s.txt" "$out"
  rc="$(printf '%s\n' "$out" | sed -n 's/^RC=//p' | tail -n 1)"
  if printf '%s\n' "$out" | grep -q 'FAIL'; then SEE_MSG="$s: output có FAILED"; return 1; fi
  res="$(_see_parse "$(artifact "see_$s.txt")" "$s" "$min" "$dim" "$SENSOR_NONZERO_PCT" 2>&1)"
  SEE_MSG="${res#*$'\t'} (rc=${rc:-?})"
  [ "${res%%$'\t'*}" = OK ]
}

case_12_2() {
  local m1 m2 ok=0
  tc_need see_workhorse || return 0
  _see_check accel 50 "$SENSOR_MIN_EVENTS_IMU" 3 || ok=1; m1="$SEE_MSG"
  _see_check gyro  50 "$SENSOR_MIN_EVENTS_IMU" 3 || ok=1; m2="$SEE_MSG"
  if [ $ok -eq 0 ]; then tc_pass "$m1 | $m2"
  else tc_fail "$m1 | $m2"; fi
}

case_12_3() {
  tc_need see_workhorse || return 0
  if _see_check mag 10 "$SENSOR_MIN_EVENTS_MAG" 3; then tc_pass "$SEE_MSG"; else tc_fail "$SEE_MSG"; fi
}

# _sht_sample <số lần> <giãn cách giây>: in các dòng "READ <temp_raw> <hum_raw>"
_sht_sample() {
  dev_script -t $(( $1 * ($2 + 5) + 15 )) COUNT="$1" DELAY="$2" GLOB_="$SHT4X_HWMON_GLOB" <<'EOF2'
d=""
for x in $GLOB_; do [ -r "$x/temp1_input" ] && d="$x" && break; done
[ -n "$d" ] || { echo "NODEV"; exit 2; }
i=0
while [ "$i" -lt "$COUNT" ]; do
  t=$(cat "$d/temp1_input" 2>/dev/null); h=$(cat "$d/humidity1_input" 2>/dev/null)
  echo "READ $t $h"
  i=$((i + 1)); [ "$i" -lt "$COUNT" ] && sleep "$DELAY"
done
EOF2
}
# SHT4x: nhiệt độ -40..125 °C, độ ẩm 0..100 %RH (giá trị sysfs = đơn vị x1000)
_sht_valid() {
  [[ "$1" =~ ^-?[0-9]+$ && "$2" =~ ^-?[0-9]+$ ]] || return 1
  [ "$1" -ne 0 ] && [ "$2" -ne 0 ] || return 1          # 0 = chưa đọc được (nhiệt độ và độ ẩm đều phải khác 0)
  [ "$1" -ge -40000 ] && [ "$1" -le 125000 ] && [ "$2" -ge 0 ] && [ "$2" -le 110000 ]
}
_sht_fmt() { awk -v t="$1" -v h="$2" 'BEGIN{printf "T=%.2f°C H=%.1f%%", t/1000, h/1000}'; }

case_12_4() {
  local out t h
  out="$(_sht_sample 1 0)"
  save_artifact sht4x_once.txt "$out"
  read -r _ t h <<< "$(printf '%s\n' "$out" | grep '^READ' | head -n 1)"
  if printf '%s' "$out" | grep -q NODEV; then tc_fail "Không thấy hwmon SHT4x ($SHT4X_HWMON_GLOB)"
  elif _sht_valid "$t" "$h"; then tc_pass "$(_sht_fmt "$t" "$h") (raw: $t / $h)"
  else tc_fail "Không đọc được, bằng 0 hoặc ngoài dải: temp='$t' humidity='$h'"; fi
}

# Thay cho vòng lặp python vô hạn: đọc 3 lần cách nhau 2 giây
case_12_5() {
  local out line t h ok=0 vals="" first="" changed=0
  out="$(_sht_sample 3 2)"
  save_artifact sht4x_loop.txt "$out"
  while read -r _ t h; do
    if _sht_valid "$t" "$h"; then
      ok=$((ok + 1)); vals="$vals [$(_sht_fmt "$t" "$h")]"
      [ -z "$first" ] && first="$t/$h" || { [ "$first" != "$t/$h" ] && changed=1; }
    fi
  done <<< "$(printf '%s\n' "$out" | grep '^READ')"
  if [ "$ok" -eq 3 ]; then tc_pass "3/3 lần đọc hợp lệ:$vals$([ $changed -eq 1 ] && echo ' (giá trị có thay đổi)')"
  else tc_fail "Chỉ $ok/3 lần đọc hợp lệ:$vals"; fi
}
