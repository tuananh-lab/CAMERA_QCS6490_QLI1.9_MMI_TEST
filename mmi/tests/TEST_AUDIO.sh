#!/bin/bash
# 10. Audio. 10.2-10.4: tạo file tone 1 kHz trên PC, đẩy vào /tmp thiết bị, người test nghe.
# Có thể dùng file riêng: AUDIO_WAV=/đường/dẫn/file.wav (48 kHz, 16-bit, stereo)
: "${AUDIO_WAV:=}"
: "${AUDIO_REC_S:=5}"              # thời gian thu âm (giây)
: "${AUDIO_MIN_RMS:=20}"           # file thu có tín hiệu: RMS >= ngưỡng (thang 16-bit)

CASES_AUDIO=(
  "10.1|Kiểm tra nhận diện Sound Card|"
  "10.2|WSA - Loa trong|manual"
  "10.3|WCD - Line In|manual"
  "10.4|WCD - Line Out|manual"
)

case_10_1() {
  local p c
  dev_sh "aplay -l"   > "$(artifact aplay_l.txt)"
  dev_sh "arecord -l" > "$(artifact arecord_l.txt)"
  p="$(grep -c '^card ' "$(artifact aplay_l.txt)")"
  c="$(grep -c '^card ' "$(artifact arecord_l.txt)")"
  if [ "$p" -ge "$EXPECT_PLAYBACK_DEVS" ] && [ "$c" -ge "$EXPECT_CAPTURE_DEVS" ]; then
    tc_pass "Phát: $p thiết bị, thu: $c thiết bị"
  else
    tc_fail "Thiếu thiết bị: phát $p/$EXPECT_PLAYBACK_DEVS, thu $c/$EXPECT_CAPTURE_DEVS"
  fi
}

# ---- Tiện ích --------------------------------------------------------------------
_audio_restore() { dev_sh "systemctl start pipewire.service wireplumber.service" >/dev/null 2>&1; }

# Tạo/đẩy file phát vào /tmp/mmi_tone.wav
_audio_tone() {
  local f="${AUDIO_WAV:-$MMI_TMP/tone.wav}"
  if [ -z "$AUDIO_WAV" ]; then
    python3 - "$f" <<'PY' || return 1
import math, struct, sys, wave
w = wave.open(sys.argv[1], 'wb'); w.setnchannels(2); w.setsampwidth(2); w.setframerate(48000)
n = 48000 * 5
w.writeframes(b''.join(struct.pack('<hh', int(12000 * math.sin(2 * math.pi * 1000 * i / 48000)),
                                  int(12000 * math.sin(2 * math.pi * 1000 * i / 48000))) for i in range(n)))
w.close()
PY
  fi
  [ -s "$f" ] && dev_push "$f" /tmp/mmi_tone.wav
}

# Phân tích WAV 16-bit mono: in "<bytes> <giây> <rms> <peak>"
_wav_stats() {
  python3 - "$1" <<'PY'
import array, math, sys
d = open(sys.argv[1], 'rb').read()
i = d.find(b'data'); off = i + 8 if i >= 0 else 44
pcm = d[off:]; n = len(pcm) // 2
a = array.array('h'); a.frombytes(pcm[:n * 2])
rms = math.sqrt(sum(x * x for x in a) / n) if n else 0
print(len(d), "%.1f" % (n / 48000.0), "%.0f" % rms, max((abs(x) for x in a), default=0))
PY
}

# Phát file qua loa. $1 = nhãn; script tinymix + agmplay đọc từ stdin (heredoc của hàm gọi)
_audio_play_case() {
  local label="$1" ask="$2" rc script
  script="$(cat)"        # đọc script từ stdin TRƯỚC: lệnh adb shell bên dưới sẽ nuốt stdin nếu còn dữ liệu
  tc_need tinymix agmplay || return 0
  _audio_tone || { tc_fail "Không tạo/đẩy được file wav lên thiết bị"; return 0; }
  on_cleanup _audio_restore
  say "  Đang phát tone 1 kHz (5s) - $label ..."
  dev_script_live -t 60 <<< "$script"
  rc=$?
  if [ $rc -ne 0 ]; then tc_fail "$label: lệnh phát lỗi (rc=$rc), xem log"; return 0; fi
  tc_manual "$ask" "$label: có âm thanh rõ, không rè/nhiễu" "$label: không có âm thanh hoặc rè/nhiễu"
}

# 10.2: WSA - loa trong
case_10_2() {
  _audio_play_case "Loa trong (WSA)" "Có âm thanh phát ra từ LOA TRONG, rõ, không rè/nhiễu?" <<'EOF2'
fail=0
tm() { tinymix set "$@" >/dev/null 2>&1 || { echo "tinymix lỗi: $*"; fail=1; }; }
systemctl stop pipewire.service; systemctl stop wireplumber.service
tm 'SpkrLeft PA Volume' 20
tm 'WSA RX0 MUX' AIF1_PB
tm 'WSA RX1 MUX' AIF1_PB
tm 'WSA_RX0 INP0' RX0
tm 'WSA_RX1 INP0' RX1
tm 'WSA_COMP1 Switch' 1
tm 'WSA_COMP2 Switch' 1
tm 'SpkrLeft WSA MODE' 0
tm 'SpkrLeft COMP Switch' 1
tm 'SpkrLeft BOOST Switch' 1
tm 'SpkrLeft DAC Switch' 1
tm 'SpkrLeft VISENSE Switch' 1
tm 'WSA_RX1 Digital Volume' 100
tm 'WSA_RX0 Digital Volume' 100
[ $fail -eq 0 ] || exit 2
agmplay /tmp/mmi_tone.wav -D 100 -d 100 -i CODEC_DMA-LPAIF_WSA-RX-0 -c 0
rc=$?; echo "agmplay rc=$rc"; exit $rc
EOF2
}

# 10.4: WCD - Line Out
case_10_4() {
  pause_enter "Cắm JACK LOA vào cổng Line Out rồi nhấn Enter..."
  _audio_play_case "Line Out (WCD)" "Có âm thanh phát ra từ LINE OUT, rõ, không rè/nhiễu?" <<'EOF2'
fail=0
tm() { tinymix set "$@" >/dev/null 2>&1 || { echo "tinymix lỗi: $*"; fail=1; }; }
systemctl stop pipewire.service; systemctl stop wireplumber.service
tm "RX_MACRO RX0 MUX" "AIF1_PB"
tm "RX_MACRO RX1 MUX" "AIF1_PB"
tm "RX INT0_1 MIX1 INP0" "RX0"
tm "RX INT1_1 MIX1 INP0" "RX1"
tm "RX INT0 DEM MUX" "CLSH_DSM_OUT"
tm "RX INT1 DEM MUX" "CLSH_DSM_OUT"
tm "RX_HPH PWR Mode" "ULP"
tm "RX HPH Mode" "CLS_AB"
tm "RX_RX0 Digital Volume" 60
tm "RX_RX1 Digital Volume" 60
tm "RX_COMP1 Switch" 1
tm "RX_COMP2 Switch" 1
tm "HPHL_RDAC Switch" 1
tm "HPHR_RDAC Switch" 1
tm "HPHL Switch" 1
tm "HPHR Switch" 1
tm "HPHL Volume" 10
tm "HPHR Volume" 10
tm "HPHL_COMP Switch" 1
tm "HPHR_COMP Switch" 1
[ $fail -eq 0 ] || exit 2
agmplay /tmp/mmi_tone.wav -D 100 -d 100 -i CODEC_DMA-LPAIF_RXTX-RX-0
rc=$?; echo "agmplay rc=$rc"; exit $rc
EOF2
}

# Thu âm một đường: _audio_rec <tên: mic_3|mic_1> (đọc script tinymix từ stdin)
_audio_rec() {
  local name="$1" f="/tmp/mmi_$1.wav" local_f rc
  local_f="$(artifact "$name.wav")"
  dev_script -t $((AUDIO_REC_S + 40)) SECS="$AUDIO_REC_S" OUT="$f" > "$MMI_TMP/rec_$name.log"
  rc=$?
  cat "$MMI_TMP/rec_$name.log" | tee -a "$LOG_FILE"
  [ $rc -eq 0 ] || return 1
  dev_pull "$f" "$local_f" 60 || return 2
  dev_sh "rm -f $f" >/dev/null 2>&1
  return 0
}

# 10.3: WCD - Line In (chỉ AMIC3)
case_10_3() {
  local n st bytes secs rms peak bad="" info="" r
  tc_need tinymix agmcap || return 0
  on_cleanup _audio_restore
  pause_enter "Cắm JACK MIC vào cổng Line In, chuẩn bị nói/gây tiếng động trong ${AUDIO_REC_S}s, nhấn Enter..."

  say "  Thu AMIC3 (${AUDIO_REC_S}s) ..."
  _audio_rec mic_3 <<'EOF2'
fail=0
tm() { tinymix set "$@" >/dev/null 2>&1 || { echo "tinymix lỗi: $*"; fail=1; }; }
systemctl stop pipewire.service; systemctl stop wireplumber.service
tm "ADC2 MUX" "INP3"
tm "ADC2 Switch" 1
tm "ADC2_MIXER Switch" 1
tm "ADC2 Volume" 12
tm "TX SMIC MUX0" "ADC1"
tm "TX DEC0 MUX" "SWR_MIC"
tm "TX_DEC0 Volume" 84
tm "TX_AIF1_CAP Mixer DEC0" 1
[ $fail -eq 0 ] || exit 2
agmcap "$OUT" -D 100 -d 101 -c 1 -r 48000 -b 16 -i CODEC_DMA-LPAIF_RXTX-TX-3 &
p=$!; sleep "$SECS"; kill -INT $p 2>/dev/null
i=0; while kill -0 $p 2>/dev/null && [ $i -lt 8 ]; do sleep 1; i=$((i + 1)); done
kill -9 $p 2>/dev/null; exit 0
EOF2
  r=$?; [ $r -eq 0 ] || bad="$bad AMIC3(thu âm lỗi, bước $r);"

  for n in mic_3; do
    [ -s "$(artifact "$n.wav")" ] || continue
    read -r bytes secs rms peak <<< "$(_wav_stats "$(artifact "$n.wav")")"
    info="$info $n: ${secs}s RMS=$rms peak=$peak;"
    [ "${rms:-0}" -ge "$AUDIO_MIN_RMS" ] || bad="$bad $n(RMS=$rms < $AUDIO_MIN_RMS: gần như im lặng);"
  done
  say "  Kết quả phân tích:$info"
  if [ -n "$bad" ]; then tc_fail "$bad"; return 0; fi

  if command -v ffplay >/dev/null; then
    for n in mic_3; do
      say "  Phát lại $n trên PC..."
      timeout $((AUDIO_REC_S + 5)) ffplay -nodisp -autoexit -loglevel quiet "$(artifact "$n.wav")" >/dev/null 2>&1
    done
  else
    say "  (PC không có ffplay) Nghe file trong: $REPORT_DIR/artifacts/mic_3.wav"
  fi
  tc_manual "File thu AMIC3 (Line In) có tiếng rõ, không rè/nhiễu quá nhiều?" \
            "AMIC3 có tiếng, rõ:$info" "Người test: file thu AMIC3 bị rè/nhiễu/mất tiếng:$info"
}