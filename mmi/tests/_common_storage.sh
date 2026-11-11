#!/bin/bash
# Hàm dùng chung cho NVMe / SD card (fio). Được source từ TEST_NVME.sh và TEST_SD_CARD.sh.
[ -n "${_STOR_COMMON_LOADED:-}" ] && return 0
_STOR_COMMON_LOADED=1

# Điểm mount của một partition thuộc <dev> (rỗng nếu không có partition nào đang mount)
_stor_mount() { dev_val "grep -E '^$1(p?[0-9]+)? ' /proc/mounts | awk '{print \$2}' | head -n 1"; }

# Băng thông MB/s từ dòng tổng của fio: "WRITE: bw=45.2MiB/s (47.4MB/s), ..."
_stor_bw() {
  printf '%s\n' "$1" | awk '/^ *(READ|WRITE): bw=/{
    if (match($0, /\([0-9.]+[kMG]B\/s\)/)) {
      s = substr($0, RSTART + 1, RLENGTH - 2); v = s; sub(/[kMG]B\/s/, "", v)
      u = substr(s, length(v) + 1, 1)
      if (u == "k") v = v / 1000; else if (u == "G") v = v * 1000
      printf "%.1f", v; exit } }'
}
_stor_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a>=b)}'; }

# _stor_case <write|read> <dev> <size> <job> <ngưỡng MB/s hoặc rỗng> <nhãn>
# - Nếu có partition đang mount: đo bằng FILE trên phân vùng đó (an toàn, không phá dữ liệu).
# - Nếu không mount: ghi/đọc THÔ trực tiếp thiết bị đúng như tài liệu (chỉ cho phép nvme* / mmcblk*).
_stor_case() {
  local mode="$1" dev="$2" size="$3" job="$4" min="$5" label="$6"
  local mp target raw note out rc bw
  case "$dev" in
    /dev/nvme[0-9]*n[0-9]*|/dev/mmcblk[0-9]*) ;;
    *) tc_fail "Từ chối thao tác trên $dev (chỉ cho phép nvme*, mmcblk*)"; return 0 ;;
  esac
  mp="$(_stor_mount "$dev")"
  if [ -n "$mp" ]; then target="$mp/.mmi_fio_test"; raw=0; note="file trên $mp"
  else target="$dev"; raw=1; note="thô $dev"; fi
  say "  fio $mode $size, $note"

  out="$(dev_script -t 900 TARGET="$target" SIZE="$size" JOB="$job" MODE="$mode" RAW="$raw" <<'EOF2'
if [ "$MODE" = read ] && [ "$RAW" = 0 ] && [ ! -f "$TARGET" ]; then
  fio --name=prep --filename="$TARGET" --rw=write --bs=128k --direct=1 --size="$SIZE" >/dev/null 2>&1
fi
fio --name="$JOB" --filename="$TARGET" --rw="$MODE" --bs=128k --direct=1 --size="$SIZE" --group_reporting 2>&1
echo "FIO_RC=$?"
[ "$RAW" = 0 ] && rm -f "$TARGET"
exit 0
EOF2
)"
  printf '%s\n' "$out" > "$(artifact "fio_${job}.txt")"
  printf '%s\n' "$out" | tee -a "$LOG_FILE"
  rc="$(printf '%s\n' "$out" | sed -n 's/^FIO_RC=//p' | tail -n 1)"
  bw="$(_stor_bw "$out")"

  if [ "$rc" != "0" ] || printf '%s\n' "$out" | grep -qiE 'error|failed'; then
    tc_fail "$label: fio báo lỗi (rc=${rc:-?}) - xem artifacts/fio_${job}.txt"
  elif [ -z "$bw" ]; then
    tc_fail "$label: không đọc được băng thông từ output fio"
  elif [ -n "$min" ] && ! _stor_ge "$bw" "$min"; then
    tc_fail "$label: ${bw} MB/s < yêu cầu ${min} MB/s ($note)"
  else
    tc_pass "$label: ${bw} MB/s, không lỗi ($note)${min:+, yêu cầu >= ${min} MB/s}${min:-, chưa đặt ngưỡng MB/s}"
  fi
}
