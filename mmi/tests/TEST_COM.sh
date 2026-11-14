#!/bin/bash
# 1. COM: kiểm tra CPU / RAM / storage của module COM (QCS6490)
: "${COM_CPU_CORES:=8}"               # số core yêu cầu
: "${COM_RAM_TOTAL_MIN_GIB:=7.2}"     # tổng RAM tối thiểu (GiB, làm tròn 1 số lẻ như 'free -h')
: "${COM_RAM_FREE_MIN_GIB:=5}"        # RAM trống tối thiểu (GiB)
: "${COM_RAM_FREE_FIELD:=free}"       # cột dùng để so sánh: free (theo tài liệu) | available
: "${COM_DISK_DEV:=sda}"              # thiết bị lưu trữ
: "${COM_DISK_MIN_GIB:=115}"          # dung lượng tối thiểu của đĩa (GiB)

CASES_COM=(
  "1.1|Kiểm tra số core của CPU|"
  "1.2|Kiểm tra RAM|"
  "1.3|Kiểm tra storage|"
)

# 1.1: grep -c '^processor' /proc/cpuinfo == COM_CPU_CORES
case_1_1() {
  local out n
  out="$(dev_sh "grep -c ^processor /proc/cpuinfo" 2>&1 | tr -d '\r')"
  save_artifact com_cpu.txt "$out"
  n="$(printf '%s\n' "$out" | tail -n 1 | tr -dc '0-9')"
  say "  \$ grep -c '^processor' /proc/cpuinfo -> ${n:-?}"
  if [ "$n" = "$COM_CPU_CORES" ]; then tc_pass "CPU: $n core"
  else tc_fail "CPU: ${n:-không đọc được} core (cần $COM_CPU_CORES)"; fi
}

# 1.2: free -h: tổng RAM >= COM_RAM_TOTAL_MIN_GIB và RAM trống > COM_RAM_FREE_MIN_GIB
case_1_2() {
  local out line total free avail use tg fg
  out="$(dev_sh "free -h; echo ---; free -k" 2>&1 | tr -d '\r')"
  save_artifact com_ram.txt "$out"
  printf '%s\n' "$out" | sed -n '1,2p' | while IFS= read -r line; do say "    $line"; done
  read -r total free avail <<< "$(printf '%s\n' "$out" | awk '/^---/{k=1;next} k&&/^Mem:/{print $2,$4,$7}')"
  if [ -z "$total" ]; then tc_fail "Không đọc được kết quả 'free'"; return 0; fi
  use="$free"; [ "$COM_RAM_FREE_FIELD" = "available" ] && use="$avail"
  tg="$(awk -v t="$total" 'BEGIN{printf "%.1f", t/1048576}')"
  fg="$(awk -v t="$use" 'BEGIN{printf "%.1f", t/1048576}')"
  if awk -v a="$tg" -v b="$COM_RAM_TOTAL_MIN_GIB" -v c="$use" -v d="$COM_RAM_FREE_MIN_GIB" \
       'BEGIN{exit !(a>=b && c/1048576>d)}'; then
    tc_pass "RAM tổng ${tg}G (>= ${COM_RAM_TOTAL_MIN_GIB}G), $COM_RAM_FREE_FIELD ${fg}G (> ${COM_RAM_FREE_MIN_GIB}G)"
  else
    tc_fail "RAM tổng ${tg}G (cần >= ${COM_RAM_TOTAL_MIN_GIB}G), $COM_RAM_FREE_FIELD ${fg}G (cần > ${COM_RAM_FREE_MIN_GIB}G)"
  fi
}

# 1.3: lsblk | grep sda: dung lượng đĩa >= COM_DISK_MIN_GIB
case_1_3() {
  local out part bytes g
  out="$(dev_sh "lsblk | grep $COM_DISK_DEV; echo ---; lsblk -b -d -n -o SIZE /dev/$COM_DISK_DEV 2>&1" 2>&1 | tr -d '\r')"
  save_artifact com_storage.txt "$out"
  part="$(printf '%s\n' "$out" | sed '/^---/,$d')"
  printf '%s\n' "$part" | while IFS= read -r line; do say "    $line"; done
  bytes="$(printf '%s\n' "$out" | sed '1,/^---/d' | head -n 1 | tr -dc '0-9')"
  if [ -z "$part" ] || [ -z "$bytes" ]; then tc_fail "Không thấy /dev/$COM_DISK_DEV (lsblk | grep $COM_DISK_DEV rỗng)"; return 0; fi
  g="$(awk -v b="$bytes" 'BEGIN{printf "%.1f", b/1073741824}')"
  if awk -v g="$g" -v m="$COM_DISK_MIN_GIB" 'BEGIN{exit !(g>=m)}'; then
    tc_pass "$COM_DISK_DEV: ${g}G (>= ${COM_DISK_MIN_GIB}G)"
  else
    tc_fail "$COM_DISK_DEV: ${g}G (cần >= ${COM_DISK_MIN_GIB}G)"
  fi
}