#!/bin/bash
# 11. Motor Lens. Dùng $LENS_BIN (precheck tự dò PATH rồi /lens_manage), bus $LENS_I2C.
# Mỗi bước phải rc=0; phần quan sát hình ảnh/lens do người test xác nhận
# Các bài Zoom/Focus/Iris/IR CUT/IR LED tự bật stream RTSP + mở cửa sổ xem (mmi_rtsp.sh) để người test quan sát hình ảnh.
# Tắt tự bật stream: LENS_NEED_STREAM=0. Độ phân giải stream: LENS_RTSP_W/H (config.sh).
: "${LENS_SET_DELAY:=1}"           # chờ TRƯỚC mỗi lệnh lens_manage (calib/set) để camera ổn định, người test nhìn rõ (giây)
: "${LENS_STEP_PAUSE:=2}"          # nghỉ SAU mỗi lệnh để quan sát kết quả (giây)
: "${LENS_CALIB_TIMEOUT:=180}"

CASES_LENS=(
  "11.1|Zoom|manual"
  "11.2|Focus|manual"
  "11.3|Iris|manual"
  "11.4|IR CUT|manual"
  "11.5|Nhiệt độ|"
  "11.6|Cảm biến ánh sáng|"
  "11.7|IR LED|manual"
)

_lens_ok() { [ -n "${LENS_BIN:-}" ] || { tc_skip "Chưa có lens_manage trên thiết bị"; return 1; }; }

# _lens_seq <nhãn> <câu hỏi xác nhận> <các bước cách nhau bằng '|'>
_lens_seq() {
  local label="$1" ask="$2" steps="$3" rc
  _lens_ok || return 0
  if [ "${LENS_NEED_STREAM:-1}" = 1 ]; then
    if ! rtsp_ensure_view "$LENS_RTSP_W" "$LENS_RTSP_H"; then
      tc_fail "$label: không có stream RTSP để quan sát ($RTSP_MSG) - xem mục 9.3"; return 0
    fi
    say "  Stream: $(rtsp_url) -> nhìn cửa sổ video (đặt vật có chi tiết trước camera để đánh giá nét/zoom)"
  fi
  say "  Quan sát lens/hình ảnh trong lúc chạy: $label"
  dev_script_live -t "$LENS_CALIB_TIMEOUT" LENS="$LENS_BIN $LENS_I2C" STEPS="$steps" PAUSE="$LENS_STEP_PAUSE" DELAY="$LENS_SET_DELAY" <<'EOF2'
rc=0
printf '%s\n' "$STEPS" | tr '|' '\n' > /tmp/mmi_lens_steps
while read -r s; do
  sleep "$DELAY"
  echo "\$ lens_manage $s"
  $LENS $s; r=$?
  echo "   rc=$r"
  [ $r -eq 0 ] || rc=1
  sleep "$PAUSE"
done < /tmp/mmi_lens_steps
rm -f /tmp/mmi_lens_steps
exit $rc
EOF2
  rc=$?
  if [ $rc -ne 0 ]; then tc_fail "$label: có lệnh lens_manage lỗi (rc=$rc), xem log"; return 0; fi
  tc_manual "$ask" "$label: lệnh chạy rc=0, người test xác nhận hoạt động đúng" "$label: người test xác nhận KHÔNG đúng"
}

case_11_1() { _lens_seq "Zoom"  "Trên stream, hình ảnh phóng to/thu nhỏ tương ứng với zoom 500 -> 100 -> 0?" "calib zoom|zoom-set 500|zoom-set 100|zoom-set 0"; }
case_11_2() { _lens_seq "Focus" "Trên stream, độ nét hình ảnh thay đổi tương ứng với focus 500 -> 0 -> 50?" "calib focus|focus-set 500|focus-set 0|focus-set 50"; }
case_11_3() { _lens_seq "Iris"  "Trên stream, iris đóng/mở tương ứng với giá trị 100 -> 50 -> 0 (hình ảnh sáng/tối thay đổi)?" "calib iris|iris-set 100|iris-set 50|iris-set 0"; }
case_11_4() { _lens_seq "IR CUT" "Trên stream, IR CUT đóng/mở đúng theo lệnh open -> close (nghe tiếng tách/hình đổi màu-đen trắng)?" "ircut open|ircut close"; rtsp_teardown; }   # hết IR CUT: đóng vlc + tắt RTSP
case_11_7() { LENS_NEED_STREAM=0 _lens_seq "IR LED" "IR LED bật/tắt đúng theo lệnh on -> off (hình sáng lên/tối đi trong môi trường tối)?" "irled on|irled off"; }   # IR LED: không cần stream

# 11.5, 11.6: đọc giá trị (rc=0 và có số)
_lens_read() {
  local what="$1" out rc num
  _lens_ok || return 1
  out="$(dev_sh_t 30 "$LENS_BIN $LENS_I2C $what 2>&1")"; rc=$?
  save_artifact "lens_$what.txt" "$out"
  say "  $what: $out"
  num="$(printf '%s\n' "$out" | grep -Eo -- '-?[0-9]+(\.[0-9]+)?' | head -n 1)"
  LENS_OUT="$out"; LENS_NUM="$num"
  [ $rc -eq 0 ] && [ -n "$num" ]
}

case_11_5() {
  _lens_ok || return 0
  if _lens_read temp && awk -v t="$LENS_NUM" 'BEGIN{exit !(t>=-40 && t<=125)}'; then
    tc_pass "Nhiệt độ lens: $(printf '%s' "$LENS_OUT" | tr '\n' ' ')"
  else
    tc_fail "Không đọc được nhiệt độ hợp lệ (-40..125): '$(printf '%s' "$LENS_OUT" | tr '\n' ' ')'"
  fi
}

case_11_6() {
  _lens_ok || return 0
  if _lens_read light; then tc_pass "Cảm biến ánh sáng: $(printf '%s' "$LENS_OUT" | tr '\n' ' ')"
  else tc_fail "Không đọc được giá trị ánh sáng: '$(printf '%s' "$LENS_OUT" | tr '\n' ' ')'"; fi
}

teardown_LENS() { rtsp_teardown; }