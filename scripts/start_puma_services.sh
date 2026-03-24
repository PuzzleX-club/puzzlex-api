#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOCKET_DIR="${APP_ROOT}/shared/sockets"
PID_DIR="${APP_ROOT}/shared/pid"

mkdir -p "${SOCKET_DIR}" "${PID_DIR}"
rm -f "${SOCKET_DIR}/puma.sock" \
      "${SOCKET_DIR}/puma_cable.sock" \
      "${PID_DIR}/puma.pid" \
      "${PID_DIR}/puma.state" \
      "${PID_DIR}/puma_cable.pid" \
      "${PID_DIR}/puma_cable.state"

start_with_screen() {
  local session="$1"
  local command="$2"

  if screen -list | grep -q "\.${session}\s"; then
    echo "Stopping existing screen session ${session}..."
    screen -S "${session}" -X quit || true
  fi

  echo "Starting ${session}..."
  screen -S "${session}" -d -m bash -lc "cd ${APP_ROOT} && ${command}"
}

start_with_screen "rails_web" "rvmsudo env RAILS_ENV=production bundle exec puma -C config/puma.rb"
start_with_screen "rails_cable" "rvmsudo env RAILS_ENV=production bundle exec puma -C config/puma.cable.rb cable/config.ru"

echo "Web & Cable Puma processes launched in screen sessions (rails_web / rails_cable)."
