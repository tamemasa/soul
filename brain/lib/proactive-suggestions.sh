#!/usr/bin/env bash
# proactive-suggestions.sh - Proactive Suggestion Engine (Phase 1)
#
# Monitors time-based triggers and generates suggestions automatically.
# Phase 1: Time-based triggers only, dry-run mode (log output, no delivery).
#
# Only triceratops runs this engine (as executor node).

PROACTIVE_DIR="${SHARED_DIR}/workspace/proactive-suggestions"
PROACTIVE_CONFIG="${PROACTIVE_DIR}/config.json"
PROACTIVE_STATE="${PROACTIVE_DIR}/state/engine.json"
PROACTIVE_DRYRUN_DIR="${PROACTIVE_DIR}/dryrun"
PROACTIVE_SUGGESTIONS_DIR="${PROACTIVE_DIR}/suggestions"

# Check interval: every 60 seconds (self-throttled within daemon's 10s loop)
PROACTIVE_CHECK_INTERVAL=60

# JST offset in seconds (+9 hours)
JST_OFFSET=32400

# ---- Initialization ----

_init_proactive_engine() {
  mkdir -p "${PROACTIVE_DIR}"/{dryrun,feedback,state,triggers,suggestions}

  if [[ ! -f "${PROACTIVE_CONFIG}" ]]; then
    log "Proactive engine: No config found, creating default"
    cat > "${PROACTIVE_CONFIG}" <<'CFGEOF'
{
  "mode": "dryrun",
  "discord_webhook_url": "",
  "triggers": {
    "daily_asset_summary": {
      "enabled": true,
      "type": "time",
      "schedule_hour_jst": 9,
      "schedule_minute": 0,
      "category": "info",
      "title_template": "日次資産サマリー",
      "description": "ポートフォリオ概況、前日比、注目銘柄"
    },
    "weekly_report": {
      "enabled": true,
      "type": "time",
      "schedule_day_of_week": 1,
      "schedule_hour_jst": 9,
      "schedule_minute": 0,
      "category": "info",
      "title_template": "週次レポート",
      "description": "週間パフォーマンス、トレンド分析、来週の注目イベント"
    }
  },
  "rate_limits": {
    "info": 3,
    "suggestion": 2,
    "alert": -1,
    "daily_total_excluding_alert": 10
  },
  "dryrun_started_at": null
}
CFGEOF
  fi

  if [[ ! -f "${PROACTIVE_STATE}" ]]; then
    log "Proactive engine: Initializing state"
    local now_ts
    now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    cat > "${PROACTIVE_STATE}" <<EOF
{
  "status": "initialized",
  "mode": "dryrun",
  "last_check_at": null,
  "last_trigger_checks": {},
  "daily_counts": {
    "date": null,
    "info": 0,
    "suggestion": 0,
    "alert": 0,
    "total": 0
  },
  "started_at": "${now_ts}",
  "total_suggestions_generated": 0
}
EOF
  fi
}

# ---- Time Utilities ----

# Get current JST hour (0-23)
_get_jst_hour() {
  local utc_epoch
  utc_epoch=$(date +%s)
  local jst_epoch=$((utc_epoch + JST_OFFSET))
  date -u -d "@${jst_epoch}" +%H | sed 's/^0//'
}

# Get current JST minute (0-59)
_get_jst_minute() {
  local utc_epoch
  utc_epoch=$(date +%s)
  local jst_epoch=$((utc_epoch + JST_OFFSET))
  date -u -d "@${jst_epoch}" +%M | sed 's/^0//'
}

# Get current JST day of week (1=Monday, 7=Sunday)
_get_jst_dow() {
  local utc_epoch
  utc_epoch=$(date +%s)
  local jst_epoch=$((utc_epoch + JST_OFFSET))
  date -u -d "@${jst_epoch}" +%u
}

# Get current JST date string (YYYY-MM-DD)
_get_jst_date() {
  local utc_epoch
  utc_epoch=$(date +%s)
  local jst_epoch=$((utc_epoch + JST_OFFSET))
  date -u -d "@${jst_epoch}" +%Y-%m-%d
}

# ---- Rate Limiting ----

# Check and reset daily counters if date changed
_reset_daily_counts_if_needed() {
  local today
  today=$(_get_jst_date)
  local state_date
  state_date=$(jq -r '.daily_counts.date // ""' "${PROACTIVE_STATE}")

  if [[ "${state_date}" != "${today}" ]]; then
    local tmp
    tmp=$(mktemp)
    jq --arg d "${today}" '.daily_counts = {"date": $d, "info": 0, "suggestion": 0, "alert": 0, "total": 0}' \
      "${PROACTIVE_STATE}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_STATE}"
    log "Proactive engine: Daily counters reset for ${today}"
  fi
}

# Check if we're within rate limits for a given category
# Returns 0 if allowed, 1 if rate-limited
_check_rate_limit() {
  local category="$1"

  _reset_daily_counts_if_needed

  local limit
  limit=$(jq -r ".rate_limits.${category} // -1" "${PROACTIVE_CONFIG}")

  # -1 means unlimited
  if [[ "${limit}" == "-1" ]]; then
    return 0
  fi

  local current_count
  current_count=$(jq -r ".daily_counts.${category} // 0" "${PROACTIVE_STATE}")

  if [[ ${current_count} -ge ${limit} ]]; then
    log "Proactive engine: Rate limit reached for ${category} (${current_count}/${limit})"
    return 1
  fi

  # Also check total daily limit (excluding alerts)
  if [[ "${category}" != "alert" ]]; then
    local total_limit total_count
    total_limit=$(jq -r '.rate_limits.daily_total_excluding_alert // 10' "${PROACTIVE_CONFIG}")
    total_count=$(jq -r '.daily_counts.total // 0' "${PROACTIVE_STATE}")
    if [[ ${total_count} -ge ${total_limit} ]]; then
      log "Proactive engine: Daily total limit reached (${total_count}/${total_limit})"
      return 1
    fi
  fi

  return 0
}

# Increment daily counter after generating a suggestion
_increment_daily_count() {
  local category="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg cat "${category}" \
    '.daily_counts[($cat)] += 1 | .daily_counts.total += 1 | .total_suggestions_generated += 1' \
    "${PROACTIVE_STATE}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_STATE}"
}

# ---- Trigger Evaluation ----

# Check if a time-based trigger should fire right now
# Returns 0 if trigger should fire, 1 otherwise
_should_fire_time_trigger() {
  local trigger_name="$1"
  local trigger_json="$2"

  local enabled
  enabled=$(echo "${trigger_json}" | jq -r '.enabled // false')
  if [[ "${enabled}" != "true" ]]; then
    return 1
  fi

  local schedule_hour schedule_minute
  schedule_hour=$(echo "${trigger_json}" | jq -r '.schedule_hour_jst // -1')
  schedule_minute=$(echo "${trigger_json}" | jq -r '.schedule_minute // 0')

  local current_hour current_minute
  current_hour=$(_get_jst_hour)
  current_minute=$(_get_jst_minute)

  # Check hour and minute match (within a 5-minute window to handle polling gaps)
  if [[ ${current_hour} -ne ${schedule_hour} ]]; then
    return 1
  fi

  local minute_diff=$(( current_minute - schedule_minute ))
  if [[ ${minute_diff} -lt 0 ]]; then
    minute_diff=$(( -minute_diff ))
  fi
  if [[ ${minute_diff} -gt 5 ]]; then
    return 1
  fi

  # For weekly triggers, check day of week
  local dow_filter
  dow_filter=$(echo "${trigger_json}" | jq -r '.schedule_day_of_week // null')
  if [[ "${dow_filter}" != "null" ]]; then
    local current_dow
    current_dow=$(_get_jst_dow)
    if [[ ${current_dow} -ne ${dow_filter} ]]; then
      return 1
    fi
  fi

  # Check if we already fired this trigger today (prevent duplicate fires)
  local today
  today=$(_get_jst_date)
  local last_fired
  last_fired=$(jq -r ".last_trigger_checks.\"${trigger_name}\" // \"\"" "${PROACTIVE_STATE}")

  if [[ "${last_fired}" == "${today}" ]]; then
    return 1
  fi

  return 0
}

# Mark a trigger as fired today
_mark_trigger_fired() {
  local trigger_name="$1"
  local today
  today=$(_get_jst_date)
  local tmp
  tmp=$(mktemp)
  jq --arg name "${trigger_name}" --arg date "${today}" \
    '.last_trigger_checks[$name] = $date' \
    "${PROACTIVE_STATE}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_STATE}"
}

# ---- Suggestion Generation ----

# Generate a suggestion ID
_generate_suggestion_id() {
  local ts rand
  ts=$(date +%s)
  rand=$((RANDOM % 9000 + 1000))
  echo "suggestion_${ts}_${rand}"
}

# Generate a suggestion using Claude
_generate_suggestion_content() {
  local trigger_name="$1"
  local trigger_json="$2"

  local title_template description category
  title_template=$(echo "${trigger_json}" | jq -r '.title_template // "提言"')
  description=$(echo "${trigger_json}" | jq -r '.description // ""')
  category=$(echo "${trigger_json}" | jq -r '.category // "info"')

  local today
  today=$(_get_jst_date)
  local dow_name
  case $(_get_jst_dow) in
    1) dow_name="月曜日" ;; 2) dow_name="火曜日" ;; 3) dow_name="水曜日" ;;
    4) dow_name="木曜日" ;; 5) dow_name="金曜日" ;; 6) dow_name="土曜日" ;; 7) dow_name="日曜日" ;;
  esac

  local prompt="あなたはSoul Systemの提言エンジンです。ミッション「Masaru Tamegaiとその家族の幸福化、および資産拡大」に基づき、以下のトリガーに対応する提言を生成してください。

## トリガー情報
- トリガー名: ${trigger_name}
- タイトル: ${title_template}
- 説明: ${description}
- カテゴリ: ${category}
- 日付: ${today} (${dow_name})

## 指示
現在は**Phase 1ドライランモード**です。実際のデータソースにはまだ接続されていません。
トリガーの種類に応じた**サンプル提言**を生成してください。実際のデータがない部分は、リアルな仮想データで埋めてください。

以下のJSON形式で回答してください（コードフェンスなし、JSONのみ）：
{
  \"title\": \"${title_template} (${today})\",
  \"rationale\": \"この提言の根拠データと分析\",
  \"risk_assessment\": {
    \"level\": \"low\",
    \"description\": \"リスクの説明\"
  },
  \"expected_impact\": \"期待される効果\",
  \"recommended_action\": \"推奨アクション\",
  \"data_sources\": [\"使用したデータソース\"]
}"

  local response
  response=$(invoke_claude "${prompt}")

  # Strip markdown code fences
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

  # Validate JSON
  if echo "${response}" | jq . > /dev/null 2>&1; then
    echo "${response}"
  else
    # Try to extract JSON from response
    local json_part
    json_part=$(echo "${response}" | sed -n '/^[[:space:]]*{/,/^[[:space:]]*}/p')
    if [[ -n "${json_part}" ]] && echo "${json_part}" | jq . > /dev/null 2>&1; then
      echo "${json_part}"
    else
      log "WARN: Proactive engine: Failed to parse suggestion content as JSON"
      echo '{"title": "'"${title_template} (${today})"'", "rationale": "生成エラー", "risk_assessment": {"level": "low", "description": "N/A"}, "expected_impact": "N/A", "recommended_action": "再試行してください", "data_sources": []}'
    fi
  fi
}

# Build a full suggestion record
_build_suggestion_record() {
  local suggestion_id="$1"
  local trigger_name="$2"
  local trigger_json="$3"
  local content_json="$4"

  local category now_ts
  category=$(echo "${trigger_json}" | jq -r '.category // "info"')
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq -n \
    --arg id "${suggestion_id}" \
    --arg cat "${category}" \
    --arg trigger_name "${trigger_name}" \
    --arg detected_at "${now_ts}" \
    --arg created_at "${now_ts}" \
    --argjson content "${content_json}" \
    '{
      id: $id,
      category: $cat,
      title: $content.title,
      trigger: {
        type: "time",
        source: $trigger_name,
        detected_at: $detected_at
      },
      rationale: $content.rationale,
      risk_assessment: $content.risk_assessment,
      expected_impact: $content.expected_impact,
      recommended_action: $content.recommended_action,
      data_sources: ($content.data_sources // []),
      created_at: $created_at
    }'
}

# ---- Delivery ----

# Deliver suggestion (dryrun: log only, live: Discord/inbox)
_deliver_suggestion() {
  local suggestion_json="$1"
  local mode
  mode=$(jq -r '.mode // "dryrun"' "${PROACTIVE_CONFIG}")

  local suggestion_id category title
  suggestion_id=$(echo "${suggestion_json}" | jq -r '.id')
  category=$(echo "${suggestion_json}" | jq -r '.category')
  title=$(echo "${suggestion_json}" | jq -r '.title')

  if [[ "${mode}" == "dryrun" ]]; then
    # Save to dryrun directory
    local dryrun_file="${PROACTIVE_DRYRUN_DIR}/${suggestion_id}.json"
    local tmp
    tmp=$(mktemp)
    echo "${suggestion_json}" | jq '. + {"delivery_mode": "dryrun"}' > "${tmp}" && mv "${tmp}" "${dryrun_file}"
    log "Proactive engine [DRYRUN]: Generated suggestion ${suggestion_id}: ${title} (category: ${category})"
  else
    # Live mode delivery based on category
    case "${category}" in
      info)
        _deliver_discord "${suggestion_json}"
        ;;
      suggestion)
        _deliver_to_inbox "${suggestion_json}"
        ;;
      alert)
        _deliver_discord "${suggestion_json}"
        ;;
    esac

    # Also save to suggestions archive
    local archive_file="${PROACTIVE_SUGGESTIONS_DIR}/${suggestion_id}.json"
    local tmp
    tmp=$(mktemp)
    echo "${suggestion_json}" | jq '. + {"delivery_mode": "live", "delivered_at": "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' > "${tmp}" && mv "${tmp}" "${archive_file}"
    log "Proactive engine [LIVE]: Delivered suggestion ${suggestion_id}: ${title} (category: ${category})"
  fi
}

# Send suggestion to Discord via webhook
_deliver_discord() {
  local suggestion_json="$1"
  local webhook_url
  webhook_url=$(jq -r '.discord_webhook_url // ""' "${PROACTIVE_CONFIG}")

  if [[ -z "${webhook_url}" ]]; then
    log "WARN: Proactive engine: Discord webhook URL not configured, skipping delivery"
    return 1
  fi

  local title category rationale recommended_action risk_level
  title=$(echo "${suggestion_json}" | jq -r '.title')
  category=$(echo "${suggestion_json}" | jq -r '.category')
  rationale=$(echo "${suggestion_json}" | jq -r '.rationale')
  recommended_action=$(echo "${suggestion_json}" | jq -r '.recommended_action')
  risk_level=$(echo "${suggestion_json}" | jq -r '.risk_assessment.level // "low"')

  # Category emoji
  local emoji
  case "${category}" in
    info) emoji="ℹ️" ;;
    suggestion) emoji="💡" ;;
    alert) emoji="🚨" ;;
    *) emoji="📋" ;;
  esac

  # Risk color
  local color
  case "${risk_level}" in
    low) color=3066993 ;;      # Green
    medium) color=16776960 ;;  # Yellow
    high) color=15158332 ;;    # Red
    *) color=9807270 ;;        # Gray
  esac

  # Build Discord embed payload
  local payload
  payload=$(jq -n \
    --arg title "${emoji} ${title}" \
    --arg desc "${rationale}" \
    --arg action "**推奨アクション**: ${recommended_action}" \
    --arg risk "リスク: ${risk_level}" \
    --arg cat "カテゴリ: ${category}" \
    --argjson color "${color}" \
    '{
      embeds: [{
        title: $title,
        description: $desc,
        color: $color,
        fields: [
          { name: "推奨アクション", value: $action, inline: false },
          { name: "リスクレベル", value: $risk, inline: true },
          { name: "カテゴリ", value: $cat, inline: true }
        ],
        footer: { text: "Soul System - Proactive Suggestion Engine" },
        timestamp: (now | todate)
      }]
    }')

  # Send to Discord webhook
  local http_code
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "${webhook_url}" 2>/dev/null) || {
    log "ERROR: Proactive engine: Discord webhook request failed"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Proactive engine: Discord notification sent (HTTP ${http_code})"
    return 0
  else
    log "ERROR: Proactive engine: Discord webhook returned HTTP ${http_code}"
    return 1
  fi
}

# Submit suggestion as Soul System task (for 'suggestion' category)
_deliver_to_inbox() {
  local suggestion_json="$1"

  local title rationale recommended_action suggestion_id now_ts
  title=$(echo "${suggestion_json}" | jq -r '.title')
  rationale=$(echo "${suggestion_json}" | jq -r '.rationale')
  recommended_action=$(echo "${suggestion_json}" | jq -r '.recommended_action')
  suggestion_id=$(echo "${suggestion_json}" | jq -r '.id')
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local ts rand task_id
  ts=$(date +%s)
  rand=$((RANDOM % 9000 + 1000))
  task_id="task_${ts}_${rand}"

  local task_json
  task_json=$(jq -n \
    --arg id "${task_id}" \
    --arg title "[提言] ${title}" \
    --arg desc "## 提言内容\n${rationale}\n\n## 推奨アクション\n${recommended_action}\n\n---\n提言ID: ${suggestion_id}" \
    --arg created "${now_ts}" \
    '{
      id: $id,
      type: "task",
      title: $title,
      description: $desc,
      priority: "low",
      source: "proactive-engine",
      created_at: $created,
      status: "pending"
    }')

  local inbox_file="${SHARED_DIR}/inbox/${task_id}.json"
  local tmp
  tmp=$(mktemp)
  echo "${task_json}" > "${tmp}" && mv "${tmp}" "${inbox_file}"

  log "Proactive engine: Submitted suggestion as task ${task_id}: ${title}"
}

# ---- Main Check Function ----

# Check all triggers and generate suggestions as needed
# Called from the daemon main loop
check_proactive_suggestions() {
  # Only triceratops runs the proactive engine
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  _init_proactive_engine

  # Self-throttle: check every PROACTIVE_CHECK_INTERVAL seconds
  local last_check_at
  last_check_at=$(jq -r '.last_check_at // ""' "${PROACTIVE_STATE}")

  if [[ -n "${last_check_at}" && "${last_check_at}" != "null" ]]; then
    local last_epoch current_epoch elapsed
    last_epoch=$(date -d "${last_check_at}" +%s 2>/dev/null || echo 0)
    current_epoch=$(date +%s)
    elapsed=$((current_epoch - last_epoch))
    if [[ ${elapsed} -lt ${PROACTIVE_CHECK_INTERVAL} ]]; then
      return 0
    fi
  fi

  # Update last check time
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp
  tmp=$(mktemp)
  jq --arg ts "${now_ts}" '.last_check_at = $ts | .status = "running"' \
    "${PROACTIVE_STATE}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_STATE}"

  # Ensure dryrun_started_at is set on first run
  local dryrun_started
  dryrun_started=$(jq -r '.dryrun_started_at // null' "${PROACTIVE_CONFIG}")
  if [[ "${dryrun_started}" == "null" ]]; then
    tmp=$(mktemp)
    jq --arg ts "${now_ts}" '.dryrun_started_at = $ts' \
      "${PROACTIVE_CONFIG}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_CONFIG}"
    log "Proactive engine: Dry-run mode started at ${now_ts}"
  fi

  # Iterate over configured triggers
  local trigger_names
  trigger_names=$(jq -r '.triggers | keys[]' "${PROACTIVE_CONFIG}" 2>/dev/null)

  for trigger_name in ${trigger_names}; do
    local trigger_json
    trigger_json=$(jq ".triggers.\"${trigger_name}\"" "${PROACTIVE_CONFIG}")

    local trigger_type
    trigger_type=$(echo "${trigger_json}" | jq -r '.type // "unknown"')

    # Phase 1: Only handle time-based triggers
    if [[ "${trigger_type}" != "time" ]]; then
      continue
    fi

    if _should_fire_time_trigger "${trigger_name}" "${trigger_json}"; then
      local category
      category=$(echo "${trigger_json}" | jq -r '.category // "info"')

      # Check rate limit
      if ! _check_rate_limit "${category}"; then
        log "Proactive engine: Trigger ${trigger_name} rate-limited, skipping"
        _mark_trigger_fired "${trigger_name}"
        continue
      fi

      log "Proactive engine: Trigger fired: ${trigger_name}"
      set_activity "generating_suggestion" "\"trigger\":\"${trigger_name}\","

      # Generate suggestion content via LLM
      local content_json
      content_json=$(_generate_suggestion_content "${trigger_name}" "${trigger_json}")

      # Build full suggestion record
      local suggestion_id
      suggestion_id=$(_generate_suggestion_id)
      local suggestion_record
      suggestion_record=$(_build_suggestion_record "${suggestion_id}" "${trigger_name}" "${trigger_json}" "${content_json}")

      # Deliver (dryrun or live)
      _deliver_suggestion "${suggestion_record}"

      # Update counters
      _increment_daily_count "${category}"
      _mark_trigger_fired "${trigger_name}"

      set_activity "idle"
    fi
  done

  return 0
}
