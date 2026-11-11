#!/bin/bash
# 8. Alarm IO
: "${ALARM_IN_PINS:=56 88}"        # ALARM_IN1, ALARM_IN2 (số GPIO trong debugfs)
: "${ALARM_OUT_GPIOS:=670 668}"    # ALARM_OUT1 = 670, ALARM_OUT2 = 668 (số trong sysfs)

CASES_ALARM_IO=(
  "8.1|Alarm IN|"
  "8.2|Alarm OUT|manual"
)

# 8.1: debugfs gpio: mỗi chân phải là INPUT và mức HIGH
case_8_1() {
  local out p line bad="" ok="" pat
  pat="$(printf 'gpio%s|' $ALARM_IN_PINS)"; pat="${pat%|}"
  out="$(dev_script -t 20 PAT="$pat" <<'EOF2'
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
grep -E "$PAT" /sys/kernel/debug/gpio
EOF2
)"
  save_artifact alarm_in_gpio.txt "$out"
  for p in $ALARM_IN_PINS; do
    line="$(printf '%s\n' "$out" | grep -E "gpio-?$p([^0-9]|\$)" | head -n 1 | sed 's/[[:space:]]\+/ /g')"
    if [ -z "$line" ]; then bad="$bad GPIO$p(không thấy trong debugfs);"; continue; fi
    if ! printf '%s' "$line" | grep -Eq '(:| )in( |$)'; then bad="$bad GPIO$p(không phải INPUT: $line);"; continue; fi
    if printf '%s' "$line" | grep -Eiq '( |:)(low|lo)( |$)'; then bad="$bad GPIO$p(mức LOW: $line);"; continue; fi
    if ! printf '%s' "$line" | grep -Eiq '( |:)(high|hi)( |$)'; then bad="$bad GPIO$p(không xác định được mức: $line);"; continue; fi
    ok="$ok GPIO$p=IN/HIGH"
  done
  if [ -z "$bad" ]; then tc_pass "${ok# }"; else tc_fail "$bad"; fi
}

# Đưa các ALARM_OUT về 0 và giải phóng GPIO (chạy cả khi test lỗi/Ctrl-C)
_alarm_out_off() {
  local g
  for g in $ALARM_OUT_GPIOS; do
    dev_sh "[ -d /sys/class/gpio/gpio$g ] && { echo 0 > /sys/class/gpio/gpio$g/value; echo $g > /sys/class/gpio/unexport; }" >/dev/null 2>&1
  done
}
_alarm_set() {   # <gpio> <0|1>: đặt và đọc lại, in giá trị đọc lại
  dev_val "echo $2 > /sys/class/gpio/gpio$1/value; cat /sys/class/gpio/gpio$1/value"
}

# 8.2: kiểm tra GPIO đã export chưa (chưa thì export), đặt direction=out, echo 0/1 liên tục ALARM_REPEAT lần,
# người test nghe tiếng rơ-le. Điện áp (0V/12V) chỉ in ra để gợi ý, không đánh giá.
: "${ALARM_REPEAT:=3}"
case_8_2() {
  local g n=0 i r bad="" answered=0 y
  on_cleanup _alarm_out_off
  say "  Gợi ý nếu có đồng hồ: echo 0 -> 0V, echo 1 -> 12V (không tính vào kết quả)"
  for g in $ALARM_OUT_GPIOS; do
    n=$((n + 1))
    if dev_exists "/sys/class/gpio/gpio$g"; then
      say "  ALARM_OUT$n: GPIO$g đã export"
    else
      say "  ALARM_OUT$n: GPIO$g chưa export -> export"
      dev_sh "echo $g > /sys/class/gpio/export" >/dev/null 2>&1; sleep 0.3
      dev_exists "/sys/class/gpio/gpio$g" || { bad="$bad ALARM_OUT$n(GPIO$g) không export được;"; continue; }
    fi
    dev_sh "echo out > /sys/class/gpio/gpio$g/direction" >/dev/null 2>&1 \
      || { bad="$bad ALARM_OUT$n(GPIO$g) không đặt được direction=out;"; continue; }

    say "  ALARM_OUT$n (GPIO$g): đang echo 0/1 ${ALARM_REPEAT} lần - LẮNG NGHE rơ-le..."
    for ((i = 1; i <= ALARM_REPEAT; i++)); do
      r="$(_alarm_set "$g" 0)"; [ "$r" = "0" ] || { bad="$bad ALARM_OUT$n(GPIO$g) không ghi được 0;"; break; }
      sleep 1
      r="$(_alarm_set "$g" 1)"; [ "$r" = "1" ] || { bad="$bad ALARM_OUT$n(GPIO$g) không ghi được 1;"; break; }
      say "    lần $i/$ALARM_REPEAT: echo 0 -> echo 1"
      sleep 1
    done
    _alarm_set "$g" 0 >/dev/null
    case "$bad" in *"ALARM_OUT$n("*) continue ;; esac
    ask_yn "ALARM_OUT$n: nghe thấy tiếng rơ-le 'tạch tạch' khi echo 0/1?"; y=$?
    [ $y -eq 1 ] && bad="$bad ALARM_OUT$n: không nghe tiếng rơ-le;"
    [ $y -eq 2 ] && answered=1
  done
  _alarm_out_off
  if [ -n "$bad" ]; then tc_fail "$bad"
  elif [ $answered -eq 1 ]; then tc_skip "Có bước chưa được người test xác nhận"
  else tc_pass "ALARM_OUT1/2 ($ALARM_OUT_GPIOS): đã export, echo 0/1 ${ALARM_REPEAT} lần, nghe tiếng rơ-le"; fi
}
