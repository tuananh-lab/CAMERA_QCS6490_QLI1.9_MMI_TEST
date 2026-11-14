#!/bin/bash
# =============================================================================
#  mmi_rtsp.sh - bật / kiểm tra / xem stream RTSP của camera (dùng cho 9.3 và Lens)
#    rtsp_start <w> <h>        bật gst-rtsp-server trên thiết bị, chờ mở cổng
#    rtsp_check <w> <h>        nhận stream bằng ffmpeg: codec, độ phân giải, fps
#    rtsp_view / rtsp_stop_viewer   mở / đóng cửa sổ xem (ffplay hoặc vlc) trên PC
#    rtsp_ensure_view <w> <h>  (cho Lens) bật + kiểm tra + mở cửa sổ xem, dùng lại nếu đã chạy
#    rtsp_stop / rtsp_teardown tắt server (và viewer)
#  Theo tài liệu QCS6490-CameraBullet-Stream: 2 tiến trình trên thiết bị
#    gst-rtsp-server -p 8900 -a <IP> -m /live "( udpsrc name=pay0 port=8554 ... )"   (server, nhận RTP qua UDP)
#    gst-launch-1.0 qtiqmmfsrc ... ! rtph264pay pt=96 ! udpsink host=<IP> port=8554  (nguồn camera)
#  Lỗi để lại trong $RTSP_MSG. Camera chỉ mở được bởi MỘT tiến trình: 9.1/9.2 phải tắt RTSP trước.
# =============================================================================
RTSP_ACTIVE=0; RTSP_RES=""; RTSP_VIEWER_PID=""; RTSP_HOOKED=0; RTSP_MSG=""; RTSP_INFO=""
: "${RTSP_VIEWER_WAIT_S:=3}"      # chờ cửa sổ xem (VLC/ffplay) mở xong, có đếm ngược (giây)
: "${RTSP_START_WAIT_S:=15}"      # đếm ngược hiện NGAY khi bắt đầu bật stream (tới lúc stream sẵn sàng), để người test biết VLC sắp mở

# Đếm lùi N giây trên terminal (1 dòng cập nhật liên tục); không phải terminal thì chỉ chờ
_rtsp_countdown() {
  local n="${1:-0}" label="$2"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  [ -n "${LOG_FILE:-}" ] && echo "  $label: ${n}s" >> "$LOG_FILE"
  if [ ! -t 1 ]; then sleep "$n"; return 0; fi
  while [ "$n" -gt 0 ]; do printf '\r  %s: còn %3ds   ' "$label" "$n"; sleep 1; n=$((n - 1)); done
  printf '\r  %s: xong.            \n' "$label"
}

rtsp_url() { echo "rtsp://$DEVICE_IP:$RTSP_PORT$RTSP_MOUNT"; }

# Đếm ngược chạy NỀN ngay khi bắt đầu bật stream (bật server + đo stream mất cả chục giây im lặng): tự tắt khi hết giờ
_RTSP_CD_PID=""
_rtsp_cd_start() {
  local t="${RTSP_START_WAIT_S:-15}"
  [ -n "${LOG_FILE:-}" ] && echo "  Đang bật stream RTSP, VLC sẽ tự mở sau khoảng ${t}s" >> "$LOG_FILE"
  [ -t 1 ] || return 0
  ( n=$t; while [ "$n" -gt 0 ]; do
      printf '\r  Đang bật stream, VLC sẽ tự mở sau khoảng %ds - vui lòng chờ: còn %2ds   ' "$t" "$n"; sleep 1; n=$((n - 1))
    done; printf '\r%*s\r' 90 '' ) &
  _RTSP_CD_PID=$!; disown "$_RTSP_CD_PID" 2>/dev/null
  return 0
}
_rtsp_cd_stop() {
  [ -n "$_RTSP_CD_PID" ] || return 0
  kill "$_RTSP_CD_PID" 2>/dev/null; _RTSP_CD_PID=""
  [ -t 1 ] && printf '\r%*s\r' 90 ''
  return 0
}

rtsp_stop_viewer() {
  [ -n "$RTSP_VIEWER_PID" ] && { kill -- "-$RTSP_VIEWER_PID" 2>/dev/null || kill "$RTSP_VIEWER_PID" 2>/dev/null; }
  pkill -f "rtsp://$DEVICE_IP:$RTSP_PORT" 2>/dev/null      # vlc/ffplay đang mở URL này
  RTSP_VIEWER_PID=""
  return 0
}

rtsp_stop() {
  [ "${CONN_LOST:-0}" = 1 ] && { RTSP_ACTIVE=0; return 0; }
  dev_script -t 20 <<'EOF2' >/dev/null 2>&1
[ -f /tmp/mmi_rtsp_src.pid ] && kill -INT $(cat /tmp/mmi_rtsp_src.pid) 2>/dev/null
pkill -INT gst-rtsp-server 2>/dev/null
sleep 2
[ -f /tmp/mmi_rtsp_src.pid ] && kill -9 $(cat /tmp/mmi_rtsp_src.pid) 2>/dev/null
pkill -9 gst-rtsp-server 2>/dev/null
rm -f /tmp/mmi_rtsp.pid /tmp/mmi_rtsp_src.pid
exit 0
EOF2
  RTSP_ACTIVE=0; RTSP_RES=""
  return 0
}

rtsp_teardown() { rtsp_stop_viewer; [ "$RTSP_HOOKED" = 1 ] && rtsp_stop; return 0; }

rtsp_alive() {
  dev_sh_t 10 'p=$(cat /tmp/mmi_rtsp.pid 2>/dev/null); q=$(cat /tmp/mmi_rtsp_src.pid 2>/dev/null); [ -n "$p" ] && [ -n "$q" ] && kill -0 $p && kill -0 $q' >/dev/null 2>&1
}

_rtsp_start_impl() {
  local w="$1" h="$2" out rc i up=0
  RTSP_MSG=""
  rtsp_stop_viewer
  rtsp_stop                                   # dọn server cũ (nếu có) để nhả camera
  [ "$RTSP_HOOKED" = 1 ] || { on_cleanup rtsp_teardown; RTSP_HOOKED=1; }
  tc_need_rtsp_tools || return 1

  # Theo tài liệu QCS6490-CameraBullet-Stream (server udpsrc + nguồn camera udpsink)
  out="$(dev_script -t 30 W="$w" H="$h" PORT="$RTSP_PORT" UDP="$RTSP_UDP_PORT" IP="$DEVICE_IP" MOUNT="$RTSP_MOUNT" BR="$RTSP_BITRATE" <<'EOF2'
rm -f /tmp/mmi_rtsp.log /tmp/mmi_rtsp_src.log
nohup gst-rtsp-server -p $PORT -a $IP -m $MOUNT "( udpsrc name=pay0 port=$UDP caps=\"application/x-rtp,media=video,clock-rate=90000,encoding-name=H264,payload=96\" )" >/tmp/mmi_rtsp.log 2>&1 </dev/null &
echo $! > /tmp/mmi_rtsp.pid
sleep 1
nohup gst-launch-1.0 -e qtiqmmfsrc name=camsrc ! video/x-raw,format=NV12,width=$W,height=$H,framerate=30/1,interlace-mode=progressive,colorimetry=bt601 ! queue ! v4l2h264enc capture-io-mode=4 output-io-mode=5 extra-controls=\"controls,video_bitrate=$BR,force_key_frame=1,video_gop_size=10,video_bitrate_mode=1,intra_refresh_period=29\" ! queue ! h264parse config-interval=-1 ! rtph264pay pt=96 ! udpsink host=$IP port=$UDP >/tmp/mmi_rtsp_src.log 2>&1 </dev/null &
echo $! > /tmp/mmi_rtsp_src.pid
sleep 3
if kill -0 "$(cat /tmp/mmi_rtsp.pid)" 2>/dev/null && kill -0 "$(cat /tmp/mmi_rtsp_src.pid)" 2>/dev/null; then echo RTSP_PID_OK
else echo RTSP_DIED; echo "--- server ---"; cat /tmp/mmi_rtsp.log; echo "--- camera ---"; cat /tmp/mmi_rtsp_src.log; exit 1; fi
EOF2
)"; rc=$?
  save_artifact "rtsp_start_${w}x${h}.log" "$out"
  if [ $rc -ne 0 ] || ! printf '%s\n' "$out" | grep -q RTSP_PID_OK; then
    RTSP_MSG="gst-rtsp-server không chạy được: $(printf '%s\n' "$out" | grep -v '^RTSP_' | tail -n 1)"
    return 1
  fi
  for ((i = 0; i < RTSP_START_TIMEOUT; i++)); do
    if timeout 2 bash -c ">/dev/tcp/$DEVICE_IP/$RTSP_PORT" 2>/dev/null; then up=1; break; fi
    if [ $((i % 3)) -eq 2 ]; then      # server có thể listen cổng khác RTSP_PORT: dò cổng thật
      p="$(rtsp_listen_port)"
      if [ -n "$p" ] && [ "$p" != "$RTSP_PORT" ]; then say "  gst-rtsp-server đang listen cổng $p (không phải $RTSP_PORT) -> dùng cổng $p"; RTSP_PORT="$p"; fi
    fi
    sleep 1
  done
  if [ $up -ne 1 ]; then
    dev_sh "echo '--- listen ---'; ss -ltnp 2>&1 || netstat -ltnp 2>&1; echo '--- log ---'; tail -n 40 /tmp/mmi_rtsp.log; echo '--- camera ---'; tail -n 40 /tmp/mmi_rtsp_src.log" > "$(artifact "rtsp_device_${w}x${h}.log")" 2>&1
    RTSP_MSG="cổng RTSP $RTSP_PORT không mở sau ${RTSP_START_TIMEOUT}s (xem artifacts/rtsp_device_${w}x${h}.log)"
    return 1
  fi
  RTSP_ACTIVE=1; RTSP_RES="${w}x${h}"
  return 0
}

rtsp_start() { _rtsp_cd_start; _rtsp_start_impl "$@" || { _rtsp_cd_stop; return 1; }; return 0; }

# In cổng TCP mà gst-rtsp-server (pid trong /tmp/mmi_rtsp.pid) đang listen (rỗng nếu chưa có)
rtsp_listen_port() {
  dev_sh_t 10 'p=$(cat /tmp/mmi_rtsp.pid 2>/dev/null); (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null) | grep -E "pid=$p[,)]|[ /]$p/" | head -n 1' 2>/dev/null \
    | grep -Eo '[0-9a-fA-F.:*]+:[0-9]+ ' | head -n 1 | sed 's/.*://; s/ //g'
}

tc_need_rtsp_tools() {
  dev_has gst-rtsp-server || { RTSP_MSG="thiết bị thiếu gst-rtsp-server"; return 1; }
  command -v ffmpeg >/dev/null || { RTSP_MSG="PC thiếu ffmpeg (chạy: bash setup_pc.sh)"; return 1; }
  return 0
}

# Nhận stream RTSP_PROBE_S giây, kiểm tra codec h264, đúng độ phân giải, fps >= RTSP_MIN_FPS
_rtsp_check_impl() {
  local w="$1" h="$2" out codec res frames fps
  RTSP_MSG=""; RTSP_INFO=""
  out="$(timeout $((RTSP_PROBE_S + 25)) ffmpeg -hide_banner -nostdin -rtsp_transport tcp -i "$(rtsp_url)" \
         -t "$RTSP_PROBE_S" -an -f null - 2>&1 | tr '\r' '\n')"
  save_artifact "rtsp_ffmpeg_${w}x${h}.log" "$out"
  codec="$(printf '%s\n' "$out" | grep -Eo 'Video: [A-Za-z0-9_]+' | head -n 1 | sed 's/Video: //')"
  res="$(printf '%s\n' "$out" | grep -Eo ', [0-9]{3,4}x[0-9]{3,4}' | head -n 1 | tr -d ', ')"
  frames="$(printf '%s\n' "$out" | grep -Eo 'frame= *[0-9]+' | tail -n 1 | grep -Eo '[0-9]+$')"
  if [ -z "$frames" ] || [ "$frames" -eq 0 ]; then
    dev_sh "tail -n 30 /tmp/mmi_rtsp.log; echo '--- camera ---'; tail -n 30 /tmp/mmi_rtsp_src.log" > "$(artifact "rtsp_device_${w}x${h}.log")" 2>&1
    RTSP_MSG="không nhận được frame nào từ $(rtsp_url) (xem artifacts/rtsp_ffmpeg_${w}x${h}.log, rtsp_device_${w}x${h}.log)"
    return 1
  fi
  fps="$(awk -v f="$frames" -v s="$RTSP_PROBE_S" 'BEGIN{printf "%.1f", f/s}')"
  RTSP_INFO="${codec:-?} ${res:-?} ${fps}fps"
  if [ "$codec" != "h264" ]; then RTSP_MSG="codec=$codec (cần h264)"; return 1; fi
  if [ "$res" != "${w}x${h}" ]; then RTSP_MSG="độ phân giải=$res (cần ${w}x${h})"; return 1; fi
  if ! awk -v a="$fps" -v b="$RTSP_MIN_FPS" 'BEGIN{exit !(a>=b)}'; then RTSP_MSG="fps=$fps < $RTSP_MIN_FPS"; return 1; fi
  sleep 1      # để server nhả phiên của ffmpeg trước khi viewer kết nối
  return 0
}

rtsp_check() { _rtsp_check_impl "$@"; local rc=$?; _rtsp_cd_stop; return $rc; }

# _rtsp_launch <vlc|ffplay> <url>: mở player nền, đặt RTSP_VIEWER_PID. Return 1 nếu PC thiếu player.
_rtsp_launch() {
  case "$1" in
    ffplay) command -v ffplay >/dev/null || return 1
            ffplay -nostdin -loglevel quiet -fflags nobuffer -flags low_delay -framedrop -rtsp_transport tcp \
                   -window_title "HSP-117 RTSP" -x 960 "$2" >/dev/null 2>&1 </dev/null & ;;
    vlc)    command -v vlc >/dev/null || return 1
            setsid vlc --quiet --network-caching="$RTSP_VLC_CACHE_MS" --live-caching="$RTSP_VLC_CACHE_MS" \
                   --rtsp-tcp "$2" >/dev/null 2>&1 </dev/null & ;;
    *) return 1 ;;
  esac
  RTSP_VIEWER_PID=$!
  disown "$RTSP_VIEWER_PID" 2>/dev/null
  return 0
}

# Mở cửa sổ xem stream (nền). Return 1 nếu không mở được (không có màn hình / không có player)
# VLC thiếu hoặc thoát ngay sau khi mở (RTSP_VLC_FALLBACK=1) => tự chuyển sang ffplay.
rtsp_view() {
  local v="$RTSP_VIEWER" url; url="$(rtsp_url)"
  [ "$v" = none ] && return 1
  if [ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then say "  (Không có màn hình) Xem stream bằng VLC: $url"; return 1; fi
  if [ -n "$RTSP_VIEWER_PID" ] && kill -0 "$RTSP_VIEWER_PID" 2>/dev/null; then return 0; fi
  if [ "$v" = auto ]; then if command -v ffplay >/dev/null; then v=ffplay; else v=vlc; fi; fi
  case "$v" in ffplay|vlc) ;; *) return 1 ;; esac
  if _rtsp_launch "$v" "$url"; then _rtsp_countdown "$RTSP_VIEWER_WAIT_S" "Đang mở $v, vui lòng chờ cửa sổ hiện hình"; else RTSP_VIEWER_PID=""; fi
  if { [ -z "$RTSP_VIEWER_PID" ] || ! kill -0 "$RTSP_VIEWER_PID" 2>/dev/null; } \
     && [ "$v" = vlc ] && [ "${RTSP_VLC_FALLBACK:-1}" = 1 ]; then
    say "  VLC không mở được -> dùng ffplay"
    if _rtsp_launch ffplay "$url"; then sleep 2; else RTSP_VIEWER_PID=""; fi
  fi
  if [ -z "$RTSP_VIEWER_PID" ] || ! kill -0 "$RTSP_VIEWER_PID" 2>/dev/null; then
    say "  Không mở được cửa sổ xem. Xem stream bằng VLC/ffplay: $url"; RTSP_VIEWER_PID=""; return 1
  fi
  return 0
}

# Cho Lens: đảm bảo stream đang chạy + có cửa sổ xem. Return 1 (RTSP_MSG) nếu không có stream.
rtsp_ensure_view() {
  local w="$1" h="$2"
  if [ "$RTSP_ACTIVE" = 1 ] && [ "$RTSP_RES" = "${w}x${h}" ] && rtsp_alive; then
    rtsp_view; return 0
  fi
  say "  Bật RTSP ${w}x${h} để quan sát: $(rtsp_url)"
  rtsp_start "$w" "$h" || return 1
  rtsp_check "$w" "$h" || return 1
  say "  Stream OK: $RTSP_INFO"
  rtsp_view
  return 0
}
