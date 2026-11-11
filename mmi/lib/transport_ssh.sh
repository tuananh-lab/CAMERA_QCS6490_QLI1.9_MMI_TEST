#!/bin/bash
# Transport ssh. Cùng giao diện với transport_adb.sh
REMOTE_ENV='export PATH=$PATH:/sbin:/usr/sbin:/usr/local/bin'

tp_init() {
  command -v ssh >/dev/null || die "Chưa cài ssh client (sudo apt install openssh-client)"
  SSH_TARGET="$SSH_USER@$DEVICE_IP"
  SSH_OPTS=(-p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
            -o LogLevel=ERROR -o ConnectTimeout="$CONNECT_TIMEOUT"
            -o ServerAliveInterval=5 -o ServerAliveCountMax=3
            -o ControlMaster=auto -o ControlPath="/tmp/mmi_ssh_%C" -o ControlPersist=120)
  if [ -n "$SSH_PASS" ]; then
    command -v sshpass >/dev/null || die "Cần sshpass (sudo apt install sshpass) hoặc đặt SSH_PASS rỗng và dùng ssh-copy-id"
    export SSHPASS="$SSH_PASS"
    SSH_CMD=(sshpass -e ssh "${SSH_OPTS[@]}")
  else
    SSH_CMD=(ssh -o BatchMode=yes "${SSH_OPTS[@]}")
  fi
}

tp_ready() { timeout "${1:-8}" "${SSH_CMD[@]}" -n "$SSH_TARGET" true >/dev/null 2>&1; }

# tp_wait [timeout_s]: giới hạn theo đồng hồ thật, không chạy quá timeout_s giây
tp_wait() {
  local to="${1:-60}" end left
  end=$((SECONDS + to))
  timeout 3 "${SSH_CMD[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1
  while :; do
    left=$((end - SECONDS)); [ "$left" -gt 0 ] || break
    tp_ready $((left > 8 ? 8 : left)) && return 0
    sleep 1
  done
  return 1
}

tp_exec() { timeout "$1" "${SSH_CMD[@]}" -n "$SSH_TARGET" "$REMOTE_ENV; $2"; }

tp_exec_live() {
  timeout "$1" "${SSH_CMD[@]}" -n "$SSH_TARGET" "$REMOTE_ENV; $2" 2>&1 | sed -u 's/\r//g'
  printf '%s' "${PIPESTATUS[0]}" > "$MMI_TMP/last_rc"
}

tp_pull() { timeout "${3:-120}" "${SSH_CMD[@]}" -n "$SSH_TARGET" "cat '$1'" > "$2" 2>/dev/null && [ -s "$2" ]; }
tp_push() { timeout "${3:-120}" "${SSH_CMD[@]}" "$SSH_TARGET" "cat > '$2'" < "$1" >/dev/null 2>&1; }
# tp_reboot <A|B>: gửi lệnh reboot qua ssh (cùng giao diện với transport_adb.sh)
tp_reboot() {
  local cmd
  case "${1:-A}" in
    A) cmd='sync; (sleep 1; reboot) >/dev/null 2>&1 &' ;;
    *) cmd='sync; reboot' ;;
  esac
  timeout 15 "${SSH_CMD[@]}" -n "$SSH_TARGET" "$REMOTE_ENV; $cmd" 2>&1 | tr -d '\r'
  return "${PIPESTATUS[0]}"
}
tp_close() { "${SSH_CMD[@]}" -O exit "$SSH_TARGET" >/dev/null 2>&1 || true; }
tp_describe() { echo "ssh $SSH_TARGET"; }