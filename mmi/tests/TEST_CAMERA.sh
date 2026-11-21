#!/bin/bash
# 9. Camera Image Sensor. 9.1/9.2: chụp/quay 5s trên thiết bị (/tmp), kéo về PC, kiểm tra bằng ffprobe,
# rồi mở ảnh/video cho người test xem. 9.3: bật RTSP (gst-rtsp-server), đo codec/độ phân giải/fps bằng ffmpeg
# rồi mở cửa sổ xem cho người test (không còn tải CPU 100%).
: "${CAM_RUN_S:=5}"                # thời gian chụp/quay (giây)
: "${CAM_BITRATE:=6000000}"

CASES_CAMERA=(
  "9.1|Chụp ảnh 1080p30 và 4K30|manual"
  "9.2|Quay video 1080p30 và 4K30|manual"
  "9.3|Stream RTSP|manual"
)

# _cam_run <pipeline> <mẫu file trên thiết bị> <file đích trên PC>
# Chạy gst-launch nền CAM_RUN_S giây rồi SIGINT (-e: kết thúc EOS đúng chuẩn), kéo file mới nhất về PC.
_cam_run() {
  local pipe="$1" pat="$2" dst="$3" out f
  out="$(dev_script -t $((CAM_RUN_S + 45)) SECS="$CAM_RUN_S" FOCUS="${LENS_BIN:+$LENS_BIN ${LENS_I2C:-/dev/i2c-1} focus-set ${CAM_FOCUS:-50}}" <<EOF2
rm -f $pat
$pipe 2>&1 &
p=\$!
sleep 2
if [ -n "\$FOCUS" ]; then o=\$(\$FOCUS 2>&1); r=\$?; echo "[lens] focus-set 50 (camera đã mở): rc=\$r \$o"; fi
sleep \$((SECS > 2 ? SECS - 2 : 0))
kill -INT \$p 2>/dev/null
i=0; while kill -0 \$p 2>/dev/null && [ \$i -lt 15 ]; do sleep 1; i=\$((i + 1)); done
kill -9 \$p 2>/dev/null
echo "LASTFILE=\$(ls -t $pat 2>/dev/null | head -n 1)"
EOF2
)"
  save_artifact "gst_$(basename "$dst").log" "$out"
  f="$(printf '%s\n' "$out" | sed -n 's/^LASTFILE=//p' | tail -n 1)"
  [ -n "$f" ] || { CAM_ERR="gst-launch không tạo file (xem artifacts/gst_$(basename "$dst").log)"; return 1; }
  dev_pull "$f" "$dst" 120 || { CAM_ERR="không kéo được $f về PC"; return 1; }
  dev_sh "rm -f $pat" >/dev/null 2>&1
  return 0
}

# ffprobe: in "key=value" của stream video đầu tiên
_probe() {
  ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_name,width,height,avg_frame_rate,pix_fmt -of default=noprint_wrappers=1 "$1" 2>&1
}
_kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }
_fps_ok() { awk -v f="$1" 'BEGIN{split(f,a,"/"); if (a[2]+0==0) exit 1; r=a[1]/a[2]; exit !(r>=29 && r<=31)}'; }

# Trước khi chạy camera: calib zoom, focus, iris rồi đặt focus 50 (nét nhất). Chỉ làm 1 lần cho mỗi lần chạy MMI
# (9.1/9.2/9.3 dùng chung). Lỗi/thiếu lens_manage chỉ cảnh báo, không làm hỏng bài.
_CAM_FOCUS_DONE=0
_cam_focus() {
  local c out rc log=""
  [ "$_CAM_FOCUS_DONE" = 1 ] && return 0
  _CAM_FOCUS_DONE=1
  [ -n "${LENS_BIN:-}" ] || return 0
  local list=("calib zoom" "calib focus" "calib iris" "focus-set ${CAM_FOCUS:-50}")
  [ "${CAM_CALIB:-1}" = 1 ] || list=("focus-set ${CAM_FOCUS:-50}")          # CAM_CALIB=0: bỏ calib, chỉ đặt focus
  for c in "${list[@]}"; do        # chạy ngầm: không in ra màn hình, kết quả vào artifacts/lens_focus_calib.txt
    out="$(dev_sh_t "${LENS_CALIB_TIMEOUT:-180}" "$LENS_BIN ${LENS_I2C:-/dev/i2c-1} $c 2>&1")"; rc=$?
    log="$log\$ lens_manage $c -> rc=$rc $out"$'\n'
  done
  save_artifact lens_focus_calib.txt "$log"
  sleep 1
}

# Đặt lại focus 50 NGAY SAU KHI camera đã mở (qtiqmmfsrc mở camera có thể đưa lens về 0, nên focus đặt trước đó bị mất).
# Dùng cho 9.3 (RTSP); 9.1/9.2 làm việc này ngay trong _cam_run.
_cam_focus_set() {
  local out rc
  [ -n "${LENS_BIN:-}" ] || return 0
  out="$(dev_sh_t 30 "$LENS_BIN ${LENS_I2C:-/dev/i2c-1} focus-set ${CAM_FOCUS:-50} 2>&1")"; rc=$?      # chạy ngầm, kết quả vào artifacts
  save_artifact lens_focus_after_open.txt "\$ lens_manage focus-set ${CAM_FOCUS:-50} -> rc=$rc $out"
}

_cam_need() {
  tc_need gst-launch-1.0 || return 1
  rtsp_teardown                      # camera chỉ mở được bởi 1 tiến trình: tắt RTSP nếu đang chạy
  command -v ffprobe >/dev/null || { tc_skip "PC thiếu ffprobe (sudo apt install ffmpeg)"; return 1; }
  _cam_focus
  return 0
}

# Mở ảnh/video cho người test xem
_view() {
  if [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
    case "$1" in
      *.jpg) xdg-open "$1" >/dev/null 2>&1 & ;;
      *.mp4) command -v ffplay >/dev/null && timeout $((CAM_RUN_S + 10)) ffplay -autoexit -loglevel quiet "$1" >/dev/null 2>&1 ;;
    esac
  else
    say "  (Không có màn hình) Xem file: $1"
  fi
}

# 9.1: ảnh JPEG 1080p30 và 4K30
case_9_1() {
  local res w h name f info bad="" detail="" files=""
  _cam_need || return 0
  for res in "1920 1080 1080p" "3840 2160 4k"; do
    read -r w h name <<< "$res"
    f="$(artifact "cam_${name}.jpg")"
    say "  Chụp $name (${w}x${h}) ..."
    if ! _cam_run "gst-launch-1.0 -e qtiqmmfsrc camera=0 name=camsrc ! image/jpeg,width=$w,height=$h,framerate=30/1 ! multifilesink location=/tmp/mmi_cam_${name}_%d.jpg sync=true async=false max-files=1" \
                  "/tmp/mmi_cam_${name}_*.jpg" "$f"; then
      bad="$bad $name($CAM_ERR);"; continue
    fi
    info="$(_probe "$f")"
    if [ "$(_kv "$info" width)" = "$w" ] && [ "$(_kv "$info" height)" = "$h" ]; then
      detail="$detail $name: $(_kv "$info" width)x$(_kv "$info" height), $(stat -c %s "$f") byte;"; files="$files $f"
    else
      bad="$bad $name(kích thước $(_kv "$info" width)x$(_kv "$info" height), cần ${w}x${h});"
    fi
  done
  if [ -n "$bad" ]; then tc_fail "$bad"; return 0; fi
  for f in $files; do _view "$f"; done
  tc_manual "Ảnh 1080p và 4K rõ nét, màu/độ sáng bình thường, không méo/sọc/mất góc?" \
            "Ảnh đúng kích thước:$detail người test xác nhận chất lượng" "Người test xác nhận ảnh KHÔNG đạt:$detail"
}

# 9.2: video H.264 1080p30 và 4K30
case_9_2() {
  local CAM_RUN_S="${CAM_VIDEO_RUN_S:-10}"      # 9.2: thời gian quay (cấu hình CAM_VIDEO_RUN_S trong config.sh)
  local res w h name f info bad="" detail="" files="" fps
  _cam_need || return 0
  for res in "1920 1080 1080p" "3840 2160 4k"; do
    read -r w h name <<< "$res"
    f="$(artifact "cam_${name}.mp4")"
    say "  Quay $name (${w}x${h}) ${CAM_RUN_S}s ..."
    if ! _cam_run "gst-launch-1.0 -e qtiqmmfsrc name=camsrc camera=0 ! video/x-raw,format=NV12,width=$w,height=$h,framerate=30/1,interlace-mode=progressive,colorimetry=bt601 ! v4l2h264enc capture-io-mode=4 output-io-mode=5 extra-controls=\"controls,video_bitrate=$CAM_BITRATE,video_bitrate_mode=0;\" ! h264parse ! mp4mux ! filesink location=/tmp/mmi_cam_${name}.mp4" \
                  "/tmp/mmi_cam_${name}.mp4" "$f"; then
      bad="$bad $name($CAM_ERR);"; continue
    fi
    info="$(_probe "$f")"; fps="$(_kv "$info" avg_frame_rate)"
    if [ "$(_kv "$info" codec_name)" = "h264" ] && [ "$(_kv "$info" width)" = "$w" ] && [ "$(_kv "$info" height)" = "$h" ] && _fps_ok "$fps"; then
      detail="$detail $name: h264 ${w}x${h} $(awk -F/ '{printf "%.1f", $1/$2}' <<< "$fps") fps, $(stat -c %s "$f") byte;"; files="$files $f"
    else
      bad="$bad $name(codec=$(_kv "$info" codec_name) $(_kv "$info" width)x$(_kv "$info" height) fps=$fps; cần h264 ${w}x${h} 30fps);"
    fi
  done
  if [ -n "$bad" ]; then tc_fail "$bad"; return 0; fi
  for f in $files; do _view "$f"; done
  tc_manual "Video 1080p và 4K phát mượt, không nháy/sọc/mất góc, hình đúng chất lượng?" \
            "Video đúng định dạng:$detail người test xác nhận chất lượng" "Người test xác nhận video KHÔNG đạt:$detail"
}

# 9.3: Stream RTSP. Mỗi độ phân giải trong RTSP_TEST_RES: bật server, ffmpeg đo (h264, đúng kích thước, fps),
# mở VLC và HỎI NGƯỜI TEST NGAY KHI VLC ĐANG MỞ; trả lời xong mới đóng VLC.
case_9_3() {
  local res w h detail="" bad="" unans=0 y
  tc_need gst-rtsp-server || return 0
  command -v ffmpeg >/dev/null || { tc_skip "PC thiếu ffmpeg (chạy: bash setup_pc.sh)"; return 0; }
  _cam_focus
  for res in $RTSP_TEST_RES; do
    w="${res%x*}"; h="${res#*x}"
    say "  Bật RTSP ${w}x${h}: $(rtsp_url)"
    if ! rtsp_start "$w" "$h"; then bad="$bad ${w}x${h}($RTSP_MSG);"; continue; fi
    _cam_focus_set
    if ! rtsp_check "$w" "$h"; then bad="$bad ${w}x${h}($RTSP_MSG);"; rtsp_stop; continue; fi
    detail="$detail ${w}x${h}: $RTSP_INFO;"
    say "  Stream OK: $RTSP_INFO"
    rtsp_view
    ask_yn "Stream RTSP ${w}x${h} (cửa sổ VLC đang mở, URL $(rtsp_url)) hiển thị liên tục, không giật/đứng hình/vỡ hình?"; y=$?
    rtsp_stop_viewer
    [ $y -eq 1 ] && bad="$bad ${w}x${h}(người test: stream không đạt);"
    [ $y -eq 2 ] && unans=1
    rtsp_stop
  done
  rtsp_teardown
  if [ -n "$bad" ]; then tc_fail "RTSP lỗi:$bad"
  elif [ $unans -eq 1 ]; then tc_skip "Chưa được người test xác nhận stream"
  else tc_pass "RTSP đạt:$detail người test xác nhận hình ảnh"; fi
}

teardown_CAMERA() { rtsp_teardown; }
