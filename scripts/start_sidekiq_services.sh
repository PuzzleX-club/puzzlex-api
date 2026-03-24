#!/usr/bin/env bash
#
# 清理并启动生产环境 Sidekiq

set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="${APP_ROOT}/log"
PID_DIR="${APP_ROOT}/shared/pid"
PID_FILE="${PID_DIR}/sidekiq.pid"
LOG_FILE="${LOG_DIR}/sidekiq.log"
SIDEKIQ_CMD="bundle exec sidekiq -e production -C config/sidekiq.yml"

mkdir -p "${LOG_DIR}" "${PID_DIR}"

stop_sidekiq() {
  echo "🔍 检查已有的 Sidekiq 进程..."
  local pids
  pids=$(pgrep -f "${SIDEKIQ_CMD}" || true)

  if [[ -z "${pids}" ]]; then
    echo "✅ 没有正在运行的 Sidekiq"
    return
  fi

  echo "🛑 停止 Sidekiq (PID: ${pids})"
  kill -TERM ${pids} || true

  # 等待最多30秒让 Sidekiq 优雅退出
  for _ in $(seq 1 30); do
    sleep 1
    if ! pgrep -f "${SIDEKIQ_CMD}" >/dev/null 2>&1; then
      echo "✅ Sidekiq 已停止"
      rm -f "${PID_FILE}"
      return
    fi
  done

  echo "⚠️  Sidekiq 未在 30 秒内退出，执行强制终止"
  kill -KILL ${pids} || true
  rm -f "${PID_FILE}"
}

start_sidekiq() {
  cd "${APP_ROOT}"
  echo "🚀 启动 Sidekiq..."
  echo "📜 日志文件: ${LOG_FILE}"

  # 保留历史日志，但确保文件存在
  touch "${LOG_FILE}"

  nohup ${SIDEKIQ_CMD} >> "${LOG_FILE}" 2>&1 &
  local new_pid=$!
  echo "${new_pid}" > "${PID_FILE}"

  echo "✅ Sidekiq 已启动 (PID: ${new_pid})"
  echo "📝 查看日志：tail -f ${LOG_FILE}"
}

stop_sidekiq
start_sidekiq
