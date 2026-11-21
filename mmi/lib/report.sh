#!/bin/bash
# report.sh - thư mục báo cáo + tổng kết

# ---- Gom log thông tin thiết bị vào thư mục lần test của thiết bị -----------------------------------
# reports/.last_run ghi nhớ thư mục lần test gần nhất cùng Chip ID / MAC của thiết bị (MAC viết hoa, không dấu ':',
# có thể nhiều giá trị cách nhau bằng dấu cách vì ghi MAC sẽ đổi MAC). Read/Write Serial/Write MAC/Reboot nhận ra
# đúng thiết bị đó (Chip ID hoặc MAC trùng) và ghi log vào cùng thư mục; không thấy thì tạo thư mục *_DEVINFO,
# lần test sau của cùng thiết bị sẽ dùng lại và đổi tên thư mục này (xem make_html_report).
devlog_pointer_set() {   # <tên thư mục> <chip id> <mac>
  { echo "DIR=$1"; echo "CHIP=$2"; echo "MAC=$3"; } > "$REPORT_ROOT/.last_run" 2>/dev/null
  return 0
}
devlog_pointer_add_mac() {   # <mac>: thêm MAC mới vào thiết bị đang theo dõi (sau khi ghi MAC)
  local ptr="$REPORT_ROOT/.last_run" m cur
  m="${1//:/}"; m="${m^^}"
  [ -f "$ptr" ] && [[ "$m" =~ ^[0-9A-F]{12}$ ]] || return 0
  cur="$(sed -n 's/^MAC=//p' "$ptr" | head -n 1)"
  case " $cur " in *" $m "*) return 0 ;; esac
  sed -i "s/^MAC=.*/MAC=${cur:+$cur }$m/" "$ptr" 2>/dev/null
  return 0
}
devlog_match() {   # <chip id> <mac>: in ra đường dẫn thư mục của lần trước nếu cùng thiết bị
  local ptr="$REPORT_ROOT/.last_run" d c m
  [ -f "$ptr" ] || return 0
  d="$(sed -n 's/^DIR=//p' "$ptr" | head -n 1)"; c="$(sed -n 's/^CHIP=//p' "$ptr" | head -n 1)"; m="$(sed -n 's/^MAC=//p' "$ptr" | head -n 1)"
  [ -n "$d" ] && [ -d "$REPORT_ROOT/$d" ] || return 0
  if [ -n "$1" ] && [ "$1" = "$c" ]; then echo "$REPORT_ROOT/$d"; return 0; fi
  if [ -n "$2" ]; then case " $m " in *" $2 "*) echo "$REPORT_ROOT/$d" ;; esac; fi
  return 0
}
# Chọn LOG_DIR cho chế độ thông tin thiết bị (cần đã kết nối + detect_mac_iface)
devlog_resolve() {
  local chip mac ser id dir
  chip="$(dev_val 'getprop ro.chipid 2>/dev/null' | head -n 1 | tr -d '\r')"
  mac="$(dev_val "$SERIAL_CMD" | head -n 1 | tr -d '\r:' | tr 'a-f' 'A-F')"
  [[ "$mac" =~ ^[0-9A-F]{12}$ ]] || mac=""
  dir="$(devlog_match "$chip" "$mac")"
  if [ -z "$dir" ]; then
    ser="$(dev_val 'getprop ro.serialno 2>/dev/null' | head -n 1 | tr -d '\r')"
    id="${ser:-${mac:-unknown}}"; id="${id//[^A-Za-z0-9._-]/_}"
    dir="$REPORT_ROOT/${PRODUCT_CODE}_${id}_$(date +%Y%m%d-%H%M%S)_DEVINFO"
    mkdir -p "$dir" 2>/dev/null && devlog_pointer_set "$(basename "$dir")" "$chip" "$mac"
  fi
  LOG_DIR="$dir"; mkdir -p "$LOG_DIR" 2>/dev/null
  return 0
}

init_report() {
  local id="$1"
  # REPORT_DIR = thư mục LÀM VIỆC tạm (artifacts, meta...), tự xoá khi thoát.
  # Kết quả cuối cùng chỉ gồm 3 file trong reports/<tên>/ (xem make_html_report).
  REPORT_DIR="$MMI_TMP/report"
  mkdir -p "$REPORT_DIR/artifacts"
  init_results
  START_EPOCH="$(date +%s)"
  {
    echo "===== HSPTEK MMI TEST REPORT ====="
    echo "Product      : $PRODUCT_NAME ($PRODUCT_CODE)"
    echo "HSPTEK ID    : ${HSP_ID:--}"
    echo "Device ID    : $id"
    echo "Connection   : $(tp_describe)"
    echo "Start time   : $(date '+%F %T')"
    echo "Host         : $(hostname)"
    echo "=================================="
  } >> "$LOG_FILE"
  {
    echo "Sản phẩm   : $PRODUCT_CODE - $PRODUCT_NAME"
    echo "Device ID  : $id"
    echo "Kết nối    : $(tp_describe)"
    echo "Thời gian  : $(date '+%F %T')"
    echo "PC         : $(hostname) ($(uname -sr))"
    echo "Kernel     : $(dev_val 'uname -r')"
    echo "Image      : $(dev_val '. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME $VERSION_ID"')"
  } > "$REPORT_DIR/device_info.txt"
  grep -E '^(Kernel|Image)' "$REPORT_DIR/device_info.txt" >> "$LOG_FILE"     # version image/kernel vào .log và .html để truy vết
}

finish_report() {
  local out="$REPORT_DIR/report.txt" verdict
  REPORT_DONE=1
  if [ "${ABORTED:-0}" = 1 ]; then verdict="INCOMPLETE (bị dừng giữa chừng, chưa chạy hết)"
  elif [ "$CNT_FAIL" -gt 0 ]; then verdict="FAIL"
  elif [ "$CNT_SKIP" -eq 0 ]; then verdict="PASS"
  else verdict="CHƯA ĐỦ (còn mục SKIP)"; fi
  {
    cat "$REPORT_DIR/device_info.txt"
    echo "------------------------------------------------------------------"
    if [ -s "$RESULT_TSV" ]; then
      if command -v column >/dev/null; then
        printf 'Mục\tNhóm\tTên\tKết quả\tChi tiết\n' | cat - "$RESULT_TSV" | column -t -s $'\t'
      else
        printf 'Mục\tNhóm\tTên\tKết quả\tChi tiết\n' | cat - "$RESULT_TSV"
      fi
    fi
    echo "------------------------------------------------------------------"
    echo "PASS=$CNT_PASS  FAIL=$CNT_FAIL  SKIP=$CNT_SKIP"
    echo "KẾT LUẬN: $verdict"
  } > "$out"

  say "\n${C_B}================ TỔNG KẾT ================${C_0}"
  say "${C_G}PASS=$CNT_PASS${C_0}  ${C_R}FAIL=$CNT_FAIL${C_0}  ${C_Y}SKIP=$CNT_SKIP${C_0}"
  if [ "$CNT_FAIL" -gt 0 ]; then
    say "Các mục FAIL:"
    awk -F'\t' '$4=="FAIL"{printf "  - [%s] %s: %s\n",$1,$3,$5}' "$RESULT_TSV" | tee -a "$LOG_FILE"
  fi
  local bg="" rs=""
  if [ -t 1 ]; then rs=$'\e[0m'; if [ "$verdict" = PASS ]; then bg=$'\e[42;30;1m'; else bg=$'\e[41;97;1m'; fi; fi
  say ""
  say "${bg}                                                          ${rs}"
  say "${bg}      KẾT LUẬN: $verdict      (PASS=$CNT_PASS  FAIL=$CNT_FAIL)      ${rs}"
  say "${bg}                                                          ${rs}"
  make_html_report "$verdict"
}

# Gom dữ liệu thô dạng text (artifacts) vào cuối log để không phải giữ file lẻ; bỏ file nhị phân (ảnh/video/wav)
append_artifacts_to_log() {
  local dir="$REPORT_DIR/artifacts" f n total
  [ -d "$dir" ] || return 0
  {
    echo; echo "===== PHỤ LỤC: DỮ LIỆU THÔ CỦA CÁC MỤC ====="
    for f in "$dir"/*; do
      [ -f "$f" ] || continue
      n="$(basename "$f")"
      case "$n" in iperf3_*|fio_*) continue ;; esac     # đã có sẵn trong log chính
      grep -Iq . "$f" 2>/dev/null || continue
      echo; echo "### artifacts/$n"
      total="$(wc -l < "$f")"
      if [ "$total" -gt 400 ]; then head -n 200 "$f"; echo "... (cắt bớt, tổng $total dòng) ..."; tail -n 100 "$f"; else cat "$f"; fi
    done
  } | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# Mỗi lần chạy = 1 thư mục reports/<tên>/ chứa đúng 3 file: <tên>.html, <tên>.log, <tên>.csv
# <tên> = <PRODUCT>_<HSPID>_<SERIAL>_<giờ>[_<CỤM>]_<KẾT QUẢ>
make_html_report() {
  local verdict="$1" vtag stamp base final now pre
  case "$verdict" in PASS) vtag=PASS ;; FAIL) vtag=FAIL ;; *) vtag=INCOMPLETE ;; esac
  now="$(date +%s)"
  stamp="$(date -d "@${START_EPOCH:-$now}" +%Y%m%d-%H%M%S)"
  append_artifacts_to_log
  {
    echo "PRODUCT_CODE=$PRODUCT_CODE"
    echo "PRODUCT_NAME=$PRODUCT_NAME"
    echo "DEV_ID=$DEV_ID"
    echo "MAC_IFACE=${MAC_IFACE:-}"
    echo "HSP_ID=${HSP_ID:--}"
    echo "CLUSTER=${CLUSTER_NAME:-}"
    echo "CPU=${DEV_CPU:-?}"
    echo "CONNECTION=$(tp_describe)"
    echo "HOST=$(hostname)"
    echo "START_TEXT=$(date -d "@${START_EPOCH:-$now}" '+%F %T')"
    echo "DURATION_S=$((now - ${START_EPOCH:-$now}))"
    echo "VERDICT=$vtag"
    echo "PASS=$CNT_PASS"; echo "FAIL=$CNT_FAIL"; echo "SKIP=$CNT_SKIP"
  } > "$REPORT_DIR/meta.env"
  base="${PRODUCT_CODE}_${HSP_ID:--}_${DEV_ID//[^A-Za-z0-9._-]/_}_${stamp}${CLUSTER_NAME:+_$CLUSTER_NAME}_${vtag}"
  final="$REPORT_ROOT/$base"
  # Thiết bị này đã có thư mục *_DEVINFO (đọc/ghi thông tin trước khi test): dùng lại, đổi tên theo kết quả test
  pre="$(devlog_match "${DEV_CHIP:-}" "${DEV_MAC:-}")"
  case "$pre" in *_DEVINFO) [ -e "$final" ] || mv "$pre" "$final" 2>/dev/null ;; esac
  mkdir -p "$final" || { say "${C_R}Không tạo được thư mục báo cáo $final${C_0}"; return 0; }
  cp "$LOG_FILE" "$final/$base.log"
  cp "$RESULT_CSV" "$final/$base.csv"
  # KEEP_ARTIFACTS=1 (config.sh): giữ cả thư mục artifacts/ (log thô từng mục) trong thư mục báo cáo để tra lỗi
  if [ "${KEEP_ARTIFACTS:-0}" = 1 ] && [ -d "$REPORT_DIR/artifacts" ]; then cp -r "$REPORT_DIR/artifacts" "$final/artifacts" 2>/dev/null; fi
  if command -v python3 >/dev/null; then
    python3 "$MMI_DIR/lib/html_report.py" "$REPORT_DIR" "$final/$base.html" >/dev/null \
      || say "${C_Y}Không tạo được báo cáo HTML${C_0}"
  else
    say "${C_Y}Thiếu python3, bỏ qua báo cáo HTML${C_0}"
  fi
  devlog_pointer_set "$base" "${DEV_CHIP:-}" "${DEV_MAC:-}"
  say "Báo cáo: $final"
  ls -1 "$final" | while IFS= read -r f; do say "   $f"; done
  # Xong bài: mở luôn trang kết quả HTML (tắt: MMI_OPEN_REPORT=0)
  if [ "${MMI_OPEN_REPORT:-1}" = 1 ] && [ "${MMI_NONINTERACTIVE:-0}" != 1 ] && [ -s "$final/$base.html" ] \
     && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null; then
    setsid xdg-open "$final/$base.html" >/dev/null 2>&1 </dev/null &
  fi
}
