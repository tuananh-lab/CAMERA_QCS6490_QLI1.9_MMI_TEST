#!/bin/bash
# =============================================================================
#  setup_pc.sh - kiểm tra / cài các tool cần có trên PC Ubuntu cho bộ test MMI
#
#    bash setup_pc.sh              kiểm tra, thiếu thì hỏi rồi cài (apt, cần sudo)
#    bash setup_pc.sh --yes        cài luôn, không hỏi
#    bash setup_pc.sh --check      chỉ kiểm tra (exit 1 nếu thiếu tool BẮT BUỘC)
#    bash setup_pc.sh --check --quiet   chỉ in các tool còn thiếu
#    Biến: TRANSPORT=ssh  => sshpass/ssh cũng là bắt buộc
# =============================================================================
: "${TRANSPORT:=adb}"
CHECK=0; YES=0; QUIET=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;; --yes|-y) YES=1 ;; --quiet|-q) QUIET=1 ;;
    -h|--help) sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,2\}//'; exit 0 ;;
  esac
done

if [ -t 1 ]; then G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; B=$'\e[1m'; N=$'\e[0m'; else G=""; R=""; Y=""; B=""; N=""; fi

# lệnh | gói apt (nhiều gói = thử lần lượt) | bắt buộc: 1=luôn, s=chỉ khi ssh, 0=tuỳ chọn | mô tả
TOOLS=(
  "adb|adb android-tools-adb|1|kết nối thiết bị qua adb"
  "python3|python3|1|chạy tool + báo cáo HTML"
  "tkinter|python3-tk|1|giao diện tool.py"
  "iperf3|iperf3|1|test Ethernet"
  "ffmpeg|ffmpeg|1|đo stream RTSP"
  "ffprobe|ffmpeg|1|kiểm tra ảnh/video"
  "ffplay|ffmpeg|1|xem stream RTSP, nghe audio"
  "vlc|vlc|1|xem stream RTSP (dự phòng)"
  "timeout|coreutils|1|giới hạn thời gian lệnh"
  "pgrep|procps|1|kiểm tra tiến trình"
  "ip|iproute2|1|dò IP của PC"
  "ssh|openssh-client|s|kết nối ssh"
  "sshpass|sshpass|s|ssh dùng mật khẩu"
  "xdg-open|xdg-utils|0|mở ảnh/thư mục báo cáo"
)

is_ok() { case "$1" in tkinter) python3 -c 'import tkinter' >/dev/null 2>&1 ;; *) command -v "$1" >/dev/null 2>&1 ;; esac; }

MISSING_REQ=(); MISSING_PKGS=()
scan() {
  MISSING_REQ=(); MISSING_PKGS=()
  local e cmd pkgs req desc need
  [ "$QUIET" = 1 ] || echo "${B}Kiểm tra tool trên PC:${N}"
  for e in "${TOOLS[@]}"; do
    IFS='|' read -r cmd pkgs req desc <<< "$e"
    need=0; [ "$req" = 1 ] && need=1; [ "$req" = s ] && [ "$TRANSPORT" = ssh ] && need=1
    if is_ok "$cmd"; then
      [ "$QUIET" = 1 ] || printf '  %sOK%s       %-10s %s\n' "$G" "$N" "$cmd" "$desc"
    else
      if [ "$need" = 1 ]; then printf '  %sMISSING%s  %-10s %s  (bắt buộc)\n' "$R" "$N" "$cmd" "$desc"; MISSING_REQ+=("$cmd")
      else printf '  %sMISSING%s  %-10s %s  (tuỳ chọn)\n' "$Y" "$N" "$cmd" "$desc"; fi
      MISSING_PKGS+=("$pkgs")
    fi
  done
}

scan
if [ "$CHECK" = 1 ]; then
  [ ${#MISSING_REQ[@]} -eq 0 ]; exit $?
fi

pause_end() { [ "${MMI_PAUSE_END:-0}" = 1 ] && { echo; read -r -p "Nhấn Enter để đóng..." _ </dev/tty; }; return 0; }

if [ ${#MISSING_PKGS[@]} -eq 0 ]; then echo "${G}Đã đủ tool trên PC.${N}"; pause_end; exit 0; fi

command -v apt-get >/dev/null || { echo "${R}Không có apt-get: hãy tự cài các tool còn thiếu.${N}"; pause_end; exit 1; }
if [ "$YES" != 1 ]; then
  read -r -p "Cài các gói còn thiếu bằng apt (cần sudo)? [Y/n] " ans </dev/tty
  case "${ans:-y}" in n|N) echo "Bỏ qua."; pause_end; exit 1 ;; esac
fi

SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"
echo "${B}apt-get update ...${N}"
$SUDO apt-get update || echo "${Y}apt-get update lỗi, vẫn thử cài tiếp${N}"

# Với mỗi mục chọn gói đầu tiên mà apt biết; bỏ trùng
PKG_LIST=()
for pk in "${MISSING_PKGS[@]}"; do
  for p in $pk; do
    if apt-cache show "$p" >/dev/null 2>&1; then
      case " ${PKG_LIST[*]} " in *" $p "*) ;; *) PKG_LIST+=("$p") ;; esac
      break
    fi
  done
done
echo "${B}Cài: ${PKG_LIST[*]}${N}"
# iperf3 hay hỏi "chạy như daemon?" -> trả lời trước để không bị treo
echo "iperf3 iperf3/start_daemon boolean false" | $SUDO debconf-set-selections 2>/dev/null
$SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y "${PKG_LIST[@]}"

echo
QUIET=0; scan
if [ ${#MISSING_REQ[@]} -eq 0 ]; then echo "${G}Xong: đã đủ tool bắt buộc.${N}"; pause_end; exit 0; fi
echo "${R}Vẫn thiếu: ${MISSING_REQ[*]} - hãy cài thủ công.${N}"; pause_end; exit 1
