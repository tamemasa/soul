#!/usr/bin/env bash
set -euo pipefail

# Intervals
HEALTH_INTERVAL=30    # 30 seconds
EVAL_INTERVAL=21600   # 6 hours in seconds
CLEANUP_INTERVAL=3600  # 1 hour in seconds

last_eval=0
last_cleanup=0

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [scheduler] Scheduler loop started (health every 30s, eval every 6h, cleanup every 1h)"

while true; do
  now=$(date +%s)

  # ヘルスチェック（毎回 = 30秒ごと）
  /scheduler/cron-tasks.sh healthcheck || true

  if (( now - last_eval >= EVAL_INTERVAL )); then
    /scheduler/cron-tasks.sh evaluation || true
    last_eval=$now
  fi

  if (( now - last_cleanup >= CLEANUP_INTERVAL )); then
    /scheduler/cron-tasks.sh cleanup || true
    last_cleanup=$now
  fi

  sleep ${HEALTH_INTERVAL}
done
