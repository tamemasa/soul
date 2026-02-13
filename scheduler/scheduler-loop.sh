#!/usr/bin/env bash
set -euo pipefail

# Intervals
HEALTH_INTERVAL=30    # 30 seconds
EVAL_INTERVAL=21600   # 6 hours in seconds
CLEANUP_INTERVAL=86400 # 24 hours in seconds

last_eval=0
last_cleanup=0
last_personality_check=0

echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [scheduler] Scheduler loop started (health every 30s, eval every 6h, cleanup every 24h, personality at 12:30 JST)"

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

  # パーソナリティ改善トリガー（毎日12:30 JST = 03:30 UTC）
  current_hour_utc=$(date -u +%H)
  current_min_utc=$(date -u +%M)
  if [[ "${current_hour_utc}" == "03" && "${current_min_utc}" -ge 30 && "${current_min_utc}" -le 31 ]]; then
    today_key=$(date -u +%Y%m%d)
    if [[ "${last_personality_check}" != "${today_key}" ]]; then
      /scheduler/cron-tasks.sh personality_improvement || true
      last_personality_check="${today_key}"
    fi
  fi

  sleep ${HEALTH_INTERVAL}
done
