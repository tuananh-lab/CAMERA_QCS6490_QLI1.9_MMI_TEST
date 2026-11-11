#!/bin/bash
# 7. TPM
CASES_TPM=(
  "7.1|Kiểm tra nhận TPM|"
  "7.2|Kiểm tra chức năng TPM|"
)

# 7.1: driver (dmesg) + I2C có thiết bị + /dev/tpm*
case_7_1() {
  local dm i2c devs n found why=""
  dm="$(dev_sh "dmesg | grep -i tpm" 2>&1)"
  i2c="$(dev_sh "i2cdetect -y -r $TPM_I2C_BUS 2>&1")"
  devs="$(dev_sh "ls -l /dev/tpm* 2>&1")"
  save_artifact tpm_dmesg.txt "$dm"
  save_artifact tpm_i2cdetect.txt "$i2c"
  save_artifact tpm_dev.txt "$devs"

  # Đếm ô khác "--" trong các dòng dữ liệu (00: .. 70:); "UU" = địa chỉ đã có driver
  n="$(printf '%s\n' "$i2c" | awk '/^[0-9a-f][0-9a-f]:/{for(i=2;i<=NF;i++) if($i!="--") c++} END{print c+0}')"
  found="$(printf '%s\n' "$i2c" | awk '/^[0-9a-f][0-9a-f]:/{for(i=2;i<=NF;i++) if($i!="--") printf "%s ", $i}')"

  [ -n "$dm" ] || why="$why dmesg không có dòng tpm;"
  [ "$n" -gt 0 ] || why="$why i2c-$TPM_I2C_BUS không thấy thiết bị;"
  printf '%s' "$devs" | grep -q '/dev/tpm[0-9]' || why="$why không có /dev/tpm*;"

  if [ -z "$why" ]; then
    tc_pass "dmesg có TPM; i2c-$TPM_I2C_BUS: ${found% }; $(printf '%s' "$devs" | grep -o '/dev/tpm[a-z0-9]*' | tr '\n' ' ' | sed 's/ $//')"
  else
    tc_fail "$why"
  fi
}


# 7.2: các lệnh cơ bản TPM2 đều phải rc=0 (chạy ở /tmp).
# LƯU Ý: tpm2_getrandom --hex và tpm2_hash in KHÔNG xuống dòng, nên marker RESULT luôn đặt ở dòng mới.
case_7_2() {
  local out res name rc fails="" cnt rnd
  out="$(dev_script -t 90 <<'EOF2'
cd /tmp || exit 1
run() { n="$1"; shift; echo "### $n: $*"; "$@" 2>&1; rc=$?; printf '\nRESULT %s %s\n' "$n" "$rc"; }
run getcap_fixed    tpm2_getcap properties-fixed
run getcap_variable tpm2_getcap properties-variable
run pcrread         tpm2_pcrread sha256:0,1,2,3
run getrandom       tpm2_getrandom 32 --hex
run hash            sh -c 'echo test | tpm2_hash'
run selftest        tpm2_selftest
EOF2
)"
  save_artifact tpm_functions.txt "$out"
  res="$(printf '%s\n' "$out" | grep -o 'RESULT [A-Za-z_0-9]* [0-9]*' | sed 's/^RESULT //')"
  cnt="$(printf '%s\n' "$res" | grep -c .)"
  while read -r name rc; do
    [ -n "$name" ] && [ "$rc" != "0" ] && fails="$fails $name(rc=$rc)"
  done <<< "$res"
  # Chuỗi ngẫu nhiên 32 byte = 64 ký tự hex (chỉ xét phần output của getrandom)
  rnd="$(printf '%s\n' "$out" | sed -n '/^### getrandom/,/RESULT getrandom/p' | grep -E '^[0-9a-f]{64}')"
  [ -n "$rnd" ] || fails="$fails getrandom(không có chuỗi 64 hex)"
  if [ "$cnt" -lt 6 ]; then
    tc_fail "Script bị ngắt: chỉ có $cnt/6 lệnh chạy xong (xem artifacts/tpm_functions.txt)"
  elif [ -z "$fails" ]; then
    tc_pass "6/6 lệnh TPM2 thành công (getcap x2, pcrread, getrandom, hash, selftest); random=${rnd:0:16}..."
  else
    tc_fail "Lệnh lỗi:$fails"
  fi
}
