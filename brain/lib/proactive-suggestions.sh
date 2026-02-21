#!/usr/bin/env bash
# proactive-suggestions.sh - Proactive Suggestion Engine
#
# Discovers trending content and delivers to multiple destinations.
# Manual trigger (dashboard force_trigger) and on-demand (OpenClaw broadcast_request) only.
#
# Only triceratops runs this engine (as executor node).

PROACTIVE_DIR="${SHARED_DIR}/workspace/proactive-suggestions"
PROACTIVE_CONFIG="${PROACTIVE_DIR}/config.json"
PROACTIVE_STATE="${PROACTIVE_DIR}/state/engine.json"
PROACTIVE_BROADCAST_DIR="${PROACTIVE_DIR}/broadcasts"

# Alert notification state
ALERT_NOTIFY_STATE="${PROACTIVE_DIR}/alert_notify_state.json"
ALERTS_DIR="${SHARED_DIR}/alerts"

# Check interval: every 60 seconds (self-throttled within daemon's 10s loop)
PROACTIVE_CHECK_INTERVAL=60

# JST offset in seconds (+9 hours)
JST_OFFSET=32400

# ---- Alert Notification Functions ----

_send_discord_alert_embed() {
  local alert_json="$1"
  local channel_id="${DISCORD_ALERT_CHANNEL_ID:-}"
  local bot_token="${DISCORD_BOT_TOKEN:-}"

  if [[ -z "${channel_id}" || -z "${bot_token}" ]]; then
    return 1
  fi

  local severity description category alert_id created_at alert_type
  severity=$(echo "${alert_json}" | jq -r '.severity // "medium"')
  description=$(echo "${alert_json}" | jq -r '.description // "No description"')
  category=$(echo "${alert_json}" | jq -r '.category // "unknown"')
  alert_id=$(echo "${alert_json}" | jq -r '.id // "unknown"')
  created_at=$(echo "${alert_json}" | jq -r '.created_at // ""')
  alert_type=$(echo "${alert_json}" | jq -r '.type // "unknown"')

  # Severity color mapping
  local color
  case "${severity}" in
    critical) color=2829099 ;;   # dark red
    high)     color=15548997 ;;  # red
    medium)   color=16776960 ;;  # yellow
    *)        color=8421504 ;;   # gray
  esac

  # Severity emoji
  local severity_label
  case "${severity}" in
    critical) severity_label="CRITICAL" ;;
    high)     severity_label="HIGH" ;;
    medium)   severity_label="MEDIUM" ;;
    *)        severity_label="${severity}" ;;
  esac

  # Truncate description for embed
  if [[ ${#description} -gt 1024 ]]; then
    description="${description:0:1021}..."
  fi

  local payload
  payload=$(jq -n \
    --argjson color "${color}" \
    --arg title "[${severity_label}] ${alert_type}" \
    --arg desc "${description}" \
    --arg cat "${category}" \
    --arg sev "${severity_label}" \
    --arg footer "Soul Unified Monitor" \
    --arg ts "${created_at}" \
    --arg aid "${alert_id}" \
    '{
      embeds: [{
        title: $title,
        description: $desc,
        color: $color,
        fields: [
          { name: "Category", value: $cat, inline: true },
          { name: "Severity", value: $sev, inline: true }
        ],
        footer: { text: ("\($footer) | \($aid)") },
        timestamp: $ts
      }]
    }')

  local http_code response_body
  response_body=$(mktemp)
  http_code=$(curl -s -o "${response_body}" -w "%{http_code}" \
    -H "Authorization: Bot ${bot_token}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "https://discord.com/api/v10/channels/${channel_id}/messages" 2>/dev/null) || {
    rm -f "${response_body}"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Proactive engine: Alert embed sent to Discord (${alert_id}, severity=${severity})"
    rm -f "${response_body}"
    return 0
  else
    log "ERROR: Proactive engine: Discord alert embed failed (HTTP ${http_code})"
    rm -f "${response_body}"
    return 1
  fi
}

_send_discord_resolved_embed() {
  local alert_json="$1"
  local channel_id="${DISCORD_ALERT_CHANNEL_ID:-}"
  local bot_token="${DISCORD_BOT_TOKEN:-}"

  if [[ -z "${channel_id}" || -z "${bot_token}" ]]; then
    return 1
  fi

  local alert_id alert_type description resolved_at
  alert_id=$(echo "${alert_json}" | jq -r '.id // "unknown"')
  alert_type=$(echo "${alert_json}" | jq -r '.type // "unknown"')
  description=$(echo "${alert_json}" | jq -r '.description // ""')
  resolved_at=$(echo "${alert_json}" | jq -r '.resolved_at // ""')

  if [[ ${#description} -gt 512 ]]; then
    description="${description:0:509}..."
  fi

  local payload
  payload=$(jq -n \
    --arg title "[RESOLVED] ${alert_type}" \
    --arg desc "${description}" \
    --arg footer "Soul Unified Monitor | ${alert_id}" \
    --arg ts "${resolved_at}" \
    '{
      embeds: [{
        title: $title,
        description: $desc,
        color: 5763719,
        footer: { text: $footer },
        timestamp: $ts
      }]
    }')

  local http_code response_body
  response_body=$(mktemp)
  http_code=$(curl -s -o "${response_body}" -w "%{http_code}" \
    -H "Authorization: Bot ${bot_token}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "https://discord.com/api/v10/channels/${channel_id}/messages" 2>/dev/null) || {
    rm -f "${response_body}"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Proactive engine: Resolved embed sent to Discord (${alert_id})"
    rm -f "${response_body}"
    return 0
  else
    log "ERROR: Proactive engine: Discord resolved embed failed (HTTP ${http_code})"
    rm -f "${response_body}"
    return 1
  fi
}

_check_alert_notifications() {
  local channel_id="${DISCORD_ALERT_CHANNEL_ID:-}"
  local bot_token="${DISCORD_BOT_TOKEN:-}"

  # Skip if not configured
  if [[ -z "${channel_id}" || -z "${bot_token}" ]]; then
    return 0
  fi

  # Initialize state file — on first run, mark all existing alerts as already notified
  # to avoid flooding Discord with historical alerts
  if [[ ! -f "${ALERT_NOTIFY_STATE}" ]]; then
    local existing_ids
    existing_ids=$(ls -t "${ALERTS_DIR}"/unified_alert_*.json 2>/dev/null | head -100 | while read -r f; do
      jq -r '.id // empty' "$f" 2>/dev/null
    done | jq -R . | jq -s .)
    jq -n --argjson ids "${existing_ids:-[]}" '{"notified_ids": $ids, "resolved_ids": []}' > "${ALERT_NOTIFY_STATE}"
    log "Proactive engine: Alert notify state initialized with $(echo "${existing_ids}" | jq 'length') existing alerts"
    return 0
  fi

  local notified_ids resolved_ids
  notified_ids=$(jq -r '.notified_ids // []' "${ALERT_NOTIFY_STATE}")
  resolved_ids=$(jq -r '.resolved_ids // []' "${ALERT_NOTIFY_STATE}")

  # Scan recent alert files (newest 20)
  local alert_files
  alert_files=$(ls -t "${ALERTS_DIR}"/unified_alert_*.json 2>/dev/null | head -20)

  if [[ -z "${alert_files}" ]]; then
    return 0
  fi

  local new_notified_ids=()
  local new_resolved_ids=()

  while IFS= read -r alert_file; do
    [[ -f "${alert_file}" ]] || continue

    local alert_json alert_id severity resolved
    alert_json=$(cat "${alert_file}" 2>/dev/null) || continue
    alert_id=$(echo "${alert_json}" | jq -r '.id // ""')
    severity=$(echo "${alert_json}" | jq -r '.severity // "low"')
    resolved=$(echo "${alert_json}" | jq -r '.resolved // false')

    [[ -n "${alert_id}" ]] || continue

    # Check if already notified
    local is_notified
    is_notified=$(echo "${notified_ids}" | jq --arg id "${alert_id}" 'any(. == $id)')

    if [[ "${is_notified}" != "true" ]]; then
      # New alert: notify if medium or above
      case "${severity}" in
        critical|high|medium)
          if _send_discord_alert_embed "${alert_json}"; then
            new_notified_ids+=("${alert_id}")
          fi
          # Rate limit: small delay between sends
          sleep 0.5
          ;;
      esac
    else
      # Already notified: check if resolved
      local is_resolved_notified
      is_resolved_notified=$(echo "${resolved_ids}" | jq --arg id "${alert_id}" 'any(. == $id)')

      if [[ "${resolved}" == "true" && "${is_resolved_notified}" != "true" ]]; then
        if _send_discord_resolved_embed "${alert_json}"; then
          new_resolved_ids+=("${alert_id}")
        fi
        sleep 0.5
      fi
    fi
  done <<< "${alert_files}"

  # Update state file with new IDs (keep latest 100)
  if [[ ${#new_notified_ids[@]} -gt 0 || ${#new_resolved_ids[@]} -gt 0 ]]; then
    local add_notified add_resolved
    add_notified=$(printf '%s\n' "${new_notified_ids[@]}" | jq -R . | jq -s .)
    add_resolved=$(printf '%s\n' "${new_resolved_ids[@]}" | jq -R . | jq -s .)

    local tmp
    tmp=$(mktemp)
    jq --argjson nn "${add_notified:-[]}" --argjson nr "${add_resolved:-[]}" '
      .notified_ids = ((.notified_ids + $nn) | .[-100:]) |
      .resolved_ids = ((.resolved_ids + $nr) | .[-100:])
    ' "${ALERT_NOTIFY_STATE}" > "${tmp}" && mv "${tmp}" "${ALERT_NOTIFY_STATE}"

    log "Proactive engine: Alert notifications sent (new=${#new_notified_ids[@]}, resolved=${#new_resolved_ids[@]})"
  fi
}

# ---- Initialization ----

_init_proactive_engine() {
  mkdir -p "${PROACTIVE_DIR}"/{dryrun,feedback,state,triggers,suggestions,broadcasts}

  if [[ ! -f "${PROACTIVE_CONFIG}" ]]; then
    log "Proactive engine: No config found, creating default"
    cat > "${PROACTIVE_CONFIG}" <<'CFGEOF'
{
  "mode": "dryrun",
  "discord_webhook_url": "",
  "triggers": {},
  "rate_limits": {
    "info": 3,
    "suggestion": 2,
    "alert": -1,
    "daily_total_excluding_alert": 10
  }
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
  "daily_counts": {
    "date": null,
    "info": 0,
    "suggestion": 0,
    "alert": 0,
    "total": 0
  },
  "last_broadcast": null,
  "started_at": "${now_ts}",
  "total_suggestions_generated": 0
}
EOF
  fi

  # Load credentials from secrets file
  _load_credentials
}

# Load API credentials from secrets.env
_load_credentials() {
  local secrets_file
  secrets_file=$(jq -r '.credentials_file // ""' "${PROACTIVE_CONFIG}" 2>/dev/null)
  if [[ -z "${secrets_file}" ]]; then
    secrets_file="${PROACTIVE_DIR}/secrets.env"
  fi
  if [[ -f "${secrets_file}" ]]; then
    while IFS='=' read -r key value; do
      [[ -z "${key}" || "${key}" == \#* ]] && continue
      export "${key}=${value}"
    done < "${secrets_file}"
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

# Get current JST total minutes from midnight (0-1439)
_get_jst_total_minutes() {
  local h m
  h=$(_get_jst_hour)
  m=$(_get_jst_minute)
  echo $(( h * 60 + m ))
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

# Update broadcast state file for UI consumption
_update_broadcast_state() {
  local status="$1"
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local state_file="${PROACTIVE_DIR}/state/broadcast.json"
  local broadcast_json
  if [[ -f "${state_file}" ]]; then
    broadcast_json=$(cat "${state_file}")
  else
    broadcast_json='{}'
  fi

  local tmp
  tmp=$(mktemp)
  if [[ "${status}" == "completed" ]]; then
    echo "${broadcast_json}" | jq \
      --arg s "${status}" --arg u "${now_ts}" \
      '. + {status: $s, last_delivered_at: $u, updated_at: $u}' \
      > "${tmp}" && mv "${tmp}" "${state_file}"
  else
    echo "${broadcast_json}" | jq \
      --arg s "${status}" --arg u "${now_ts}" \
      '. + {status: $s, updated_at: $u}' \
      > "${tmp}" && mv "${tmp}" "${state_file}"
  fi
}

# ---- Dynamic Query Generation ----

# Generate search queries dynamically from chat conversation context
# Returns newline-separated list of search queries (5-8 items)
_generate_dynamic_queries() {
  local chat_contexts="$1"

  if [[ -z "${chat_contexts}" ]]; then
    log "Proactive engine: No chat context available for dynamic query generation"
    echo ""
    return
  fi

  local prompt="あなたは検索クエリ生成エンジンです。以下の複数チャットの会話コンテキストを分析し、**各チャットに固有の**検索クエリを生成してください。

## チャットの会話コンテキスト
${chat_contexts}

## ルール
- **各チャットの会話内容をそれぞれ独立に分析し、そのチャット固有のトピックからクエリを生成する**
- チャットごとに最低2件の固有クエリを含めること（合計7〜12件）
- カテゴリに一切制限なし。会話の文脈から自由にトピックを選ぶ
- 各クエリは検索エンジンで使える具体的なキーワード（2〜5語程度）にする
- 全て日本語でクエリを生成すること（英語クエリは使わない）
- 抽象的すぎるクエリ（例：「テクノロジー」だけ）は避ける
- **異なるチャットで同じテーマが話されていない限り、クエリが重複しないようにする**
- テクノロジー・ゲームなどの特定ジャンルに偏らず、各チャットの会話内容を忠実に反映すること

## 出力形式（厳守）
思考過程や説明文は一切出力しないこと。以下のJSON配列のみ出力すること。

\`\`\`json
[\"クエリ1\", \"クエリ2\", \"クエリ3\", \"クエリ4\", \"クエリ5\"]
\`\`\`"

  local response
  response=$(invoke_claude "${prompt}")

  if [[ -z "${response}" ]]; then
    log "WARN: Proactive engine: Dynamic query generation returned empty response"
    echo ""
    return
  fi

  # Extract JSON array from response using common parser
  local queries_json
  queries_json=$(_extract_json_array "${response}")

  if [[ -n "${queries_json}" ]]; then
    local count
    count=$(echo "${queries_json}" | jq 'length')
    log "Proactive engine: Generated ${count} dynamic search queries from chat context"
    echo "${queries_json}"
  else
    log "WARN: Proactive engine: Failed to parse dynamic queries from LLM response"
    echo ""
  fi
}

# Collect conversation contexts from all active chats for dynamic query generation
_collect_all_chat_contexts() {
  local activity_window_hours="${1:-72}"
  local chat_profiles_json="${2:-{}}"
  local default_profile_json="${3:-{}}"

  local active_chats
  active_chats=$(_get_active_chats "${activity_window_hours}")
  local active_count
  active_count=$(echo "${active_chats}" | jq 'length' 2>/dev/null || echo 0)

  if [[ ${active_count} -eq 0 ]]; then
    echo ""
    return
  fi

  local all_contexts=""
  local i=0
  while [[ ${i} -lt ${active_count} ]]; do
    local chat session_key
    chat=$(echo "${active_chats}" | jq -c ".[${i}]")
    session_key=$(echo "${chat}" | jq -r '.session_key // ""')

    # Get chat profile for name
    local profile
    profile=$(echo "${chat_profiles_json}" | jq -c --arg sk "${session_key}" '.[$sk] // null' 2>/dev/null)
    if [[ -z "${profile}" || "${profile}" == "null" ]]; then
      profile="${default_profile_json}"
    fi
    local profile_name
    profile_name=$(echo "${profile}" | jq -r '.name // "不明"')

    # Get recent conversation context
    if [[ -n "${session_key}" ]]; then
      local context
      context=$(_get_recent_chat_context "${session_key}")
      if [[ -n "${context}" ]]; then
        all_contexts="${all_contexts}
### ${profile_name} (${session_key})
${context}
"
      fi
    fi

    i=$((i + 1))
  done

  # Output context and topics as two lines
  if [[ -n "${all_contexts}" ]]; then
    echo "${all_contexts}"
  fi
}

# ---- Google Trends ----

# Fetch Google Trends trending searches for Japan
# Returns a JSON string: {"keyword": "...", "description": "..."} or empty string on failure
_fetch_google_trends() {
  log "Proactive engine: Fetching Google Trends RSS for Japan..."
  local rss_content
  rss_content=$(curl -s --max-time 10 "https://trends.google.com/trending/rss?geo=JP" 2>/dev/null)

  if [[ -z "${rss_content}" ]]; then
    log "WARN: Proactive engine: Google Trends RSS fetch failed"
    echo ""
    return
  fi

  # Extract <title> tags from RSS items (skip the first one which is the feed title)
  local titles
  titles=$(echo "${rss_content}" | grep -oP '<title>\K[^<]+' | tail -n +2 | head -5)

  if [[ -z "${titles}" ]]; then
    log "WARN: Proactive engine: No trending keywords found in Google Trends RSS"
    echo ""
    return
  fi

  local count
  count=$(echo "${titles}" | wc -l)
  log "Proactive engine: Found ${count} Google Trends keywords"

  # Pick one at random
  local total_lines
  total_lines=$(echo "${titles}" | wc -l)
  local random_line=$(( (RANDOM % total_lines) + 1 ))
  local selected_keyword
  selected_keyword=$(echo "${titles}" | sed -n "${random_line}p")

  log "Proactive engine: Selected Google Trends keyword: ${selected_keyword}"

  # Try to get a brief description via Brave Search or LLM
  local brave_key="${BRAVE_API_KEY:-}"
  local description=""

  if [[ -n "${brave_key}" ]]; then
    local encoded_kw
    encoded_kw=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${selected_keyword}'))" 2>/dev/null || echo "${selected_keyword}")
    local search_resp
    search_resp=$(curl -s --max-time 8 \
      -H "Accept: application/json" \
      -H "X-Subscription-Token: ${brave_key}" \
      "https://api.search.brave.com/res/v1/web/search?q=${encoded_kw}&count=1&freshness=pd&country=JP&search_lang=ja" 2>/dev/null)

    if [[ -n "${search_resp}" ]]; then
      local first_result
      first_result=$(echo "${search_resp}" | jq -r '.web.results[0] // empty' 2>/dev/null)
      if [[ -n "${first_result}" ]]; then
        local title url desc
        title=$(echo "${first_result}" | jq -r '.title // ""')
        url=$(echo "${first_result}" | jq -r '.url // ""')
        desc=$(echo "${first_result}" | jq -r '.description // ""')
        description="${title} - ${desc}"
        if [[ -n "${url}" ]]; then
          description="${description} (${url})"
        fi
      fi
    fi
  fi

  # If no search result, generate a brief description via LLM
  if [[ -z "${description}" ]]; then
    description=$(invoke_claude "「${selected_keyword}」について、1-2文で簡潔に説明してください。何が話題になっているかだけ述べてください。説明以外の出力は不要です。" 2>/dev/null)
    description="${description:-${selected_keyword}が日本でトレンド入り}"
  fi

  # Return as JSON
  jq -n --arg kw "${selected_keyword}" --arg desc "${description}" \
    '{keyword: $kw, description: $desc}'
}

# ---- JSON Array Extraction (common utility) ----

# Extract a JSON array from LLM response text with 3-stage fallback:
#   1. Direct jq parse
#   2. sed: extract [ ... ] block
#   3. tr + grep -oP: inline JSON array extraction
# Usage: result=$(_extract_json_array "$response")
_extract_json_array() {
  local input="$1"

  if [[ -z "${input}" ]]; then
    echo ""
    return
  fi

  # Strip markdown code fences first
  local clean
  clean=$(echo "${input}" | sed '/^```\(json\)\?$/d')

  # Stage 1: Direct jq parse
  local parsed
  parsed=$(echo "${clean}" | jq -c '.' 2>/dev/null)
  if [[ -n "${parsed}" ]] && echo "${parsed}" | jq '.[0]' > /dev/null 2>&1; then
    echo "${parsed}"
    return
  fi

  # Stage 2: sed extract [ ... ] block
  local json_part
  json_part=$(echo "${clean}" | sed -n '/^[[:space:]]*\[/,/^[[:space:]]*\]/p')
  if [[ -n "${json_part}" ]]; then
    parsed=$(echo "${json_part}" | jq -c '.' 2>/dev/null)
    if [[ -n "${parsed}" ]] && echo "${parsed}" | jq '.[0]' > /dev/null 2>&1; then
      echo "${parsed}"
      return
    fi
  fi

  # Stage 3: tr + grep -oP for inline JSON array
  local inline
  inline=$(echo "${clean}" | tr '\n' ' ' | grep -oP '\[[^\[]*?\]' | head -1)
  if [[ -n "${inline}" ]]; then
    parsed=$(echo "${inline}" | jq -c '.' 2>/dev/null)
    if [[ -n "${parsed}" ]] && echo "${parsed}" | jq '.[0]' > /dev/null 2>&1; then
      echo "${parsed}"
      return
    fi
  fi

  # All stages failed
  echo ""
}

# ---- Trending Content Discovery ----

# Search Brave API for dynamic queries to expand content pool with chat-context-specific articles
_search_brave_for_queries() {
  local queries_json="$1"
  local brave_key="${BRAVE_API_KEY:-}"

  if [[ -z "${brave_key}" || -z "${queries_json}" || "${queries_json}" == "[]" ]]; then
    echo "[]"
    return
  fi

  local count
  count=$(echo "${queries_json}" | jq 'length' 2>/dev/null || echo 0)
  if [[ ${count} -eq 0 ]]; then
    echo "[]"
    return
  fi

  local all_results="[]"

  for ((i=0; i<count; i++)); do
    local query
    query=$(echo "${queries_json}" | jq -r ".[$i]" 2>/dev/null)
    [[ -z "${query}" || "${query}" == "null" ]] && continue

    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))" "${query}" 2>/dev/null || continue)

    local search_resp
    search_resp=$(curl -s --max-time 8 \
      -H "Accept: application/json" \
      -H "X-Subscription-Token: ${brave_key}" \
      "https://api.search.brave.com/res/v1/web/search?q=${encoded_query}&count=3&freshness=pw&country=JP&search_lang=ja" 2>/dev/null)

    if [[ -n "${search_resp}" ]]; then
      local results
      results=$(echo "${search_resp}" | jq -c --arg q "${query}" \
        '[.web.results[]? | {title: .title, url: .url, category: "context", pubDate: "", source_query: $q}]' 2>/dev/null)

      if [[ -n "${results}" && "${results}" != "[]" ]]; then
        all_results=$(echo "${all_results}" "${results}" | jq -s 'add' 2>/dev/null)
      fi
    fi

    sleep 0.3
  done

  local total
  total=$(echo "${all_results}" | jq 'length' 2>/dev/null || echo 0)
  log "Proactive engine: Brave Search returned ${total} items for ${count} dynamic queries"

  echo "${all_results}"
}

# Discover trending content: Yahoo News RSS (primary) + Brave dynamic queries with LLM curation
_discover_trending_content() {
  local trigger_json="$1"
  local dynamic_queries="${2:-}"

  # Primary: Yahoo News RSS + optional Brave dynamic queries
  _discover_trending_content_rss "${dynamic_queries}"
}

# Discover trending content via Yahoo News RSS + Brave dynamic queries
_discover_trending_content_rss() {
  local dynamic_queries="${1:-}"
  local categories=("top-picks" "domestic" "world" "business" "entertainment" "sports" "it" "science")
  local all_items=""

  for cat in "${categories[@]}"; do
    local rss_url="https://news.yahoo.co.jp/rss/topics/${cat}.xml"
    local xml
    xml=$(curl -s --max-time 10 "${rss_url}" 2>/dev/null)
    if [[ -z "${xml}" ]]; then
      continue
    fi

    local items
    items=$(echo "${xml}" | python3 -c "
import sys, json, xml.etree.ElementTree as ET
xml = sys.stdin.read()
try:
    root = ET.fromstring(xml)
    items = []
    for item in root.findall('.//item'):
        title = item.find('title')
        link = item.find('link')
        pub = item.find('pubDate')
        if title is not None and link is not None:
            url = link.text.split('?')[0] if link.text else ''
            items.append({'title': title.text or '', 'url': url, 'category': '${cat}', 'pubDate': pub.text if pub is not None else ''})
    print(json.dumps(items, ensure_ascii=False))
except:
    print('[]')
" 2>/dev/null)

    if [[ -n "${items}" && "${items}" != "[]" ]]; then
      if [[ -z "${all_items}" ]]; then
        all_items="${items}"
      else
        all_items=$(echo "${all_items}" "${items}" | jq -s 'add' 2>/dev/null)
      fi
    fi
    sleep 0.5
  done

  local total_count
  total_count=$(echo "${all_items}" | jq 'length' 2>/dev/null || echo 0)

  if [[ ${total_count} -lt 5 ]]; then
    log "WARN: Proactive engine: Yahoo News RSS returned only ${total_count} items, falling back to LLM only"
    _discover_trending_content_llm_only
    return
  fi

  log "Proactive engine: Yahoo News RSS collected ${total_count} items across ${#categories[@]} categories"

  # Merge Brave Search results from dynamic queries (chat-context-specific articles)
  local has_dynamic=false
  if [[ -n "${dynamic_queries}" && "${dynamic_queries}" != "[]" ]]; then
    local dq_count
    dq_count=$(echo "${dynamic_queries}" | jq 'length' 2>/dev/null || echo 0)
    if [[ ${dq_count} -gt 0 ]]; then
      log "Proactive engine: Searching Brave for ${dq_count} dynamic queries to expand content pool..."
      local brave_items
      brave_items=$(_search_brave_for_queries "${dynamic_queries}")
      if [[ -n "${brave_items}" && "${brave_items}" != "[]" ]]; then
        all_items=$(echo "${all_items}" "${brave_items}" | jq -s 'add' 2>/dev/null)
        local brave_count
        brave_count=$(echo "${brave_items}" | jq 'length' 2>/dev/null || echo 0)
        log "Proactive engine: Merged ${brave_count} Brave Search results into content pool"
        has_dynamic=true
      fi
    fi
  fi

  # Deduplicate by title (normalize whitespace for comparison)
  all_items=$(echo "${all_items}" | jq '[group_by(.title)[] | first]' 2>/dev/null)

  local deduped_count
  deduped_count=$(echo "${all_items}" | jq 'length' 2>/dev/null || echo 0)
  log "Proactive engine: Content pool after dedup: ${deduped_count} items"

  # Select more items when dynamic queries expanded the pool (more options for per-chat differentiation)
  local select_count=10
  if [[ "${has_dynamic}" == "true" ]]; then
    select_count=15
  fi

  # Use LLM to curate and add summaries
  local prompt="あなたはニュースキュレーターです。以下の記事一覧から、最も興味深く価値のある記事を**必ず${select_count}件**選んでください。${select_count}件に満たない場合でもできるだけ多く選んでください（最低8件）。

## 記事一覧
${all_items}

## 選定基準
- カテゴリは記事の内容から自由に判定すること。特定のジャンルに偏らないこと
- 新鮮で話題性のあるもの
- 暴力的・過激な政治発言・個人攻撃・センセーショナルなゴシップは除外
- 実用的・教育的・インスピレーションを与える内容を優先
- 重複する話題は最も情報量の多いものを1つだけ選択
- **多様なジャンルの記事を幅広く選定すること**
- 異なるカテゴリ（例：経済、健康、文化、スポーツ、科学、政治、エンタメ等）から満遍なく選ぶこと
- category が \"context\" の記事はチャットの会話コンテキストから検索されたものなので、積極的に含めること

## 重要
- **urlフィールドは記事一覧に含まれるURLをそのまま使用すること（絶対に変更・省略しない）**
- summaryはタイトルから推測して2〜3文で作成すること

以下のJSON配列で回答してください（コードフェンスなし、JSONのみ）：
[
  {
    \"title\": \"記事タイトル\",
    \"url\": \"記事一覧のurlをそのまま使用\",
    \"summary\": \"タイトルから推測した2〜3文の要約\",
    \"category\": \"記事の内容に最も適したカテゴリ名（自由記述）\",
    \"interest_score\": 8
  }
]"

  local response
  response=$(invoke_claude "${prompt}")

  local parsed
  parsed=$(_extract_json_array "${response}")

  if [[ -n "${parsed}" ]]; then
    echo "${parsed}"
  else
    log "WARN: Proactive engine: RSS curation failed, falling back to LLM only"
    _discover_trending_content_llm_only
  fi
}

# Supplement null URLs in content array via Brave Search API
_supplement_urls_via_brave() {
  local content_json="$1"
  local brave_key="${BRAVE_API_KEY:-}"

  if [[ -z "${brave_key}" ]]; then
    echo "${content_json}"
    return
  fi

  local count
  count=$(echo "${content_json}" | jq 'length' 2>/dev/null || echo 0)

  local result="${content_json}"
  local supplemented=0

  for ((i=0; i<count; i++)); do
    local url title
    url=$(echo "${result}" | jq -r ".[$i].url // \"null\"")
    [[ "${url}" != "null" && -n "${url}" ]] && continue

    title=$(echo "${result}" | jq -r ".[$i].title // \"\"")
    [[ -z "${title}" ]] && continue

    local encoded_title
    encoded_title=$(python3 -c "import urllib.parse; print(urllib.parse.quote('''${title}'''))" 2>/dev/null || continue)

    local search_resp
    search_resp=$(curl -s --max-time 5 \
      -H "Accept: application/json" \
      -H "X-Subscription-Token: ${brave_key}" \
      "https://api.search.brave.com/res/v1/web/search?q=${encoded_title}&count=1&freshness=pw&country=JP&search_lang=ja" 2>/dev/null)

    if [[ -n "${search_resp}" ]]; then
      local found_url
      found_url=$(echo "${search_resp}" | jq -r '.web.results[0].url // empty' 2>/dev/null)
      if [[ -n "${found_url}" ]]; then
        result=$(echo "${result}" | jq --arg url "${found_url}" --argjson i "$i" '.[$i].url = $url')
        supplemented=$((supplemented + 1))
      fi
    fi

    sleep 0.3
  done

  if [[ ${supplemented} -gt 0 ]]; then
    log "Proactive engine: Brave Search supplemented ${supplemented}/${count} URLs"
  fi

  echo "${result}"
}

# Fallback: generate trending content using LLM knowledge only
_discover_trending_content_llm_only() {
  local today
  today=$(_get_jst_date)

  local prompt="あなたはニュースキュレーターです。${today}の最新トレンドとして、多様なジャンルから8〜10件のニューストピックを紹介してください。X（旧Twitter）で話題のトピックも含めてください。

## 条件
- あなたの知識に基づく最新の話題やトレンドを紹介
- Xで話題のトピックも含めること
- 暴力的・過激な政治発言・個人攻撃は除外
- 実用的・教育的な内容を優先
- URLは含めず、トピックの紹介に集中
- カテゴリは特定のジャンルに限定せず、記事内容に最も適したカテゴリ名を自由に付与すること
- テクノロジー・ゲームなどの特定ジャンルに偏らず、幅広いジャンルから選定すること

以下のJSON配列で回答してください（コードフェンスなし、JSONのみ）：
[
  {
    \"title\": \"トピックタイトル\",
    \"url\": null,
    \"summary\": \"2〜3文の要約\",
    \"category\": \"記事の内容に最も適したカテゴリ名（自由記述）\",
    \"interest_score\": 8
  }
]"

  local response
  response=$(invoke_claude "${prompt}")

  local parsed
  parsed=$(_extract_json_array "${response}")

  if [[ -n "${parsed}" ]]; then
    # Supplement URLs via Brave Search if available
    parsed=$(_supplement_urls_via_brave "${parsed}")
    echo "${parsed}"
  else
    log "WARN: Proactive engine: LLM fallback also failed to produce valid JSON"
    echo '[{"title":"コンテンツ生成エラー","url":null,"summary":"トレンドコンテンツの生成に失敗しました","category":"info","interest_score":0}]'
  fi
}

# ---- Destination-Specific Content Formatting ----

# Format discovered content for a specific destination
# Now accepts chat_profile info for per-chat personality customization
_format_content_for_destination() {
  local content_json="$1"
  local dest_json="$2"
  local chat_profile_json="${3:-}"
  local google_trends_json="${4:-}"

  local dest_type
  dest_type=$(echo "${dest_json}" | jq -r '.type')

  # Extract chat profile attributes (if provided)
  local profile_name profile_audience profile_tone
  if [[ -n "${chat_profile_json}" && "${chat_profile_json}" != "null" ]]; then
    profile_name=$(echo "${chat_profile_json}" | jq -r '.name // ""')
    profile_audience=$(echo "${chat_profile_json}" | jq -r '.audience // ""')
    profile_tone=$(echo "${chat_profile_json}" | jq -r '.tone // ""')
  else
    profile_name=""
    profile_audience=""
    profile_tone=""
  fi

  local today
  today=$(_get_jst_date)

  # Build Google Trends section if available
  local trends_section=""
  if [[ -n "${google_trends_json}" && "${google_trends_json}" != "null" ]]; then
    local trends_kw trends_desc
    trends_kw=$(echo "${google_trends_json}" | jq -r '.keyword // ""' 2>/dev/null)
    trends_desc=$(echo "${google_trends_json}" | jq -r '.description // ""' 2>/dev/null)
    if [[ -n "${trends_kw}" ]]; then
      trends_section="
## いま話題（Google Trends）
キーワード: ${trends_kw}
${trends_desc}"
    fi
  fi

  # Base personality: OpenClaw (Masaru) persona
  local personality_base="あなたは「Masaruくん」というキャラクターとして情報を配信する。以下のパーソナリティルールを厳守すること：
- 絵文字は使わない（絶対に使用禁止）
- 標準語ベース（約70%）に関西弁（約30%）を混ぜる
- 関西弁の語尾（〜やな、〜やで等）は1メッセージに1-2回まで。連続使用禁止
- 強い関西弁表現（めっちゃ、ほんま、あかん、ええやん、しゃーない）は1メッセージに1回まで
- 標準語の語尾を基本にする：〜だな、〜だわ、〜なんよな、〜だけど、〜だろ
- 友達に話しかけるようなカジュアルな口調。敬語は使わない
- 短めのメッセージを心がける。長い説明は避ける
- これは一方向の情報配信であり、対話ではない。以下のフレーズは絶対に含めないこと：「処理中」「まだ集めてる」「システムが情報を…」「待つか」「もうちょい待つ」「他のこと聞いて」「何か聞いてくれる？」等の対話的・未完了を示す表現"

  local prompt="${personality_base}

## 配信先
- チャット名: ${profile_name:-${dest_type}}
- 対象: ${profile_audience:-一般}
- トーン指示: ${profile_tone:-カジュアル}

## 配信するニュース・トレンド情報（3件）
${content_json}
${trends_section}

注意: ニュース記事とGoogle Trendsトピックが同じ話題の場合、Trendsセクションでは別の切り口や補足情報を紹介すること。完全な重複は避ける。

## フォーマット指示"

  case "${dest_type}" in
    discord)
      prompt="${prompt}
Discord向けにフォーマットしてください：
- 各ニュースは **太字タイトル** で始め、リンクがあれば含める
- 技術的な詳細も含めてOK（対象に合わせて調整）
- 全体を1つのメッセージにまとめる（2000文字以内）
- 自然な書き出しから始める（「おつ」「よう」等カジュアルに）"
      if [[ -n "${trends_section}" ]]; then
        prompt="${prompt}
- 「いま話題」セクションをメッセージの最後に追加し、Google Trendsのキーワードを紹介する"
      fi
      prompt="${prompt}

プレーンテキストで回答してください（JSONではなく、そのままDiscordに投稿できる形式）："
      ;;
    line)
      prompt="${prompt}
LINE向けにフォーマットしてください：
- 簡潔でカジュアルな文体
- 対象に合わせて技術用語を調整（家族向けなら分かりやすく言い換え）
- 全体を1つのメッセージにまとめる（1000文字以内）
- 自然な書き出しから始める
- 各ニュースにソースURLが提供されている場合は末尾に記載する（短い行で「→ URL」の形式）。URLがnullの場合はURL行を省略する"
      if [[ -n "${trends_section}" ]]; then
        prompt="${prompt}
- 「いま話題」セクションをメッセージの最後に追加し、Google Trendsのキーワードを紹介する"
      fi
      prompt="${prompt}

プレーンテキストで回答してください（JSONではなく、そのままLINEに送信できる形式）："
      ;;
    *)
      prompt="${prompt}
プレーンテキストでニュースサマリーを作成してください："
      ;;
  esac

  local response
  response=$(invoke_claude "${prompt}")

  # Clean up any potential JSON wrapping
  response=$(echo "${response}" | sed '/^```/d')
  echo "${response}"
}

# ---- Suggestion Generation ----

# Generate a suggestion ID
_generate_suggestion_id() {
  local ts rand
  ts=$(date +%s)
  rand=$((RANDOM % 9000 + 1000))
  echo "suggestion_${ts}_${rand}"
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

# Write Discord push file (picked up by OpenClaw command-watcher for delivery via openclaw message send)
_deliver_discord_bot() {
  local channel_id="$1"
  local message_text="$2"

  # Truncate to Discord's 2000 char limit
  if [[ ${#message_text} -gt 2000 ]]; then
    message_text="${message_text:0:1997}..."
  fi

  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local ts rand
  ts=$(date +%s)
  rand=$((RANDOM % 9000 + 1000))

  local push_file="/shared/bot_commands/discord_push_${channel_id}_${ts}_${rand}.json"
  local tmp
  tmp=$(mktemp)

  jq -n \
    --arg channel_id "${channel_id}" \
    --arg text "${message_text}" \
    --arg source "proactive_news" \
    --arg created_at "${now_ts}" \
    '{channel_id: $channel_id, text: $text, source: $source, created_at: $created_at}' \
    > "${tmp}" && chmod 666 "${tmp}" && mv "${tmp}" "${push_file}"

  log "Proactive engine: Discord push file written for channel ${channel_id} (${push_file})"
  return 0
}

# Write pending LINE message to file (picked up by OpenClaw on next user message)
_deliver_line() {
  local target_id="$1"
  local message_text="$2"

  # LINE message limit is 5000 chars
  if [[ ${#message_text} -gt 5000 ]]; then
    message_text="${message_text:0:4997}..."
  fi

  local pending_file="/shared/bot_commands/line_pending_${target_id}.json"
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local msg_id="msg_$(date +%s)_${RANDOM}"

  local new_msg
  new_msg=$(jq -n \
    --arg id "${msg_id}" \
    --arg text "${message_text}" \
    --arg source "proactive_news" \
    --arg created_at "${now_ts}" \
    '{id: $id, text: $text, source: $source, created_at: $created_at}')

  local tmp
  tmp=$(mktemp)

  if [[ -f "${pending_file}" ]]; then
    # Append to existing pending_messages array
    jq --argjson new_msg "${new_msg}" --arg ts "${now_ts}" \
      '.pending_messages += [$new_msg] | .updated_at = $ts' \
      "${pending_file}" > "${tmp}" && chmod 666 "${tmp}" && mv "${tmp}" "${pending_file}"
  else
    # Create new pending file
    jq -n \
      --arg target_id "${target_id}" \
      --argjson new_msg "${new_msg}" \
      --arg ts "${now_ts}" \
      '{target_id: $target_id, pending_messages: [$new_msg], updated_at: $ts}' \
      > "${tmp}" && chmod 666 "${tmp}" && mv "${tmp}" "${pending_file}"
  fi

  log "Proactive engine: LINE pending message written for ${target_id} (${msg_id})"
  return 0
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

# ---- Active Chat Discovery (72h Filter) ----

# Get active chats from OpenClaw sessions.json filtered by activity window
# Returns JSON array of {type, target_id, session_key} objects
_get_active_chats() {
  local activity_window_hours="${1:-72}"

  local sessions_json
  sessions_json=$(docker exec soul-openclaw cat /home/openclaw/.openclaw/agents/main/sessions/sessions.json 2>/dev/null)
  if [[ -z "${sessions_json}" ]]; then
    log "WARN: Proactive engine: Could not read sessions.json from OpenClaw"
    echo "[]"
    return
  fi

  local now_ms
  now_ms=$(($(date +%s) * 1000))
  local window_ms=$(( activity_window_hours * 3600 * 1000 ))

  # Parse sessions and filter by activity window, then extract target info
  echo "${sessions_json}" | jq --argjson now "${now_ms}" --argjson window "${window_ms}" '
    to_entries
    | map(select(
        .value.updatedAt != null
        and ($now - .value.updatedAt) < $window
      ))
    | map(
        if (.key | test("^agent:main:discord:channel:"))
        then {
          type: "discord",
          target_id: (.key | split(":") | last),
          session_key: .key
        }
        elif (.key | test("^agent:main:line:group:group:"))
        then {
          type: "line",
          target_id: (.value.deliveryContext.to | split(":") | last),
          session_key: .key
        }
        elif (.key == "agent:main:main" and (.value.deliveryContext.channel == "line"))
        then {
          type: "line",
          target_id: (.value.deliveryContext.to | split(":") | last),
          session_key: .key
        }
        else empty
        end
      )
  ' 2>/dev/null || echo "[]"
}

# ---- Broadcast Memory for OpenClaw ----

# Save broadcast content summary to OpenClaw's memory so the bot can reference
# what was delivered when users ask about "さっきのニュース" etc.
# Writes a Markdown file to OpenClaw's workspace/memory/ directory via docker exec.
# Also cleans up broadcast memory files older than 7 days.
_save_broadcast_to_openclaw_memory() {
  local content_json="$1"
  local broadcast_id="$2"
  local trigger_type="$3"  # "scheduled" or "ondemand"

  # Check if OpenClaw container is running
  if ! docker ps --filter "name=soul-openclaw" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q "soul-openclaw"; then
    log "WARN: Proactive engine: OpenClaw not running, skipping memory save"
    return
  fi

  local today
  today=$(date -u +%Y-%m-%d)
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local memory_file="broadcast-${today}.md"
  local memory_dir="/home/openclaw/.openclaw/workspace/memory"

  # Build markdown content from the broadcast articles
  local md_content=""
  local article_count
  article_count=$(echo "${content_json}" | jq 'length' 2>/dev/null || echo 0)

  if [[ ${article_count} -eq 0 ]]; then
    log "WARN: Proactive engine: No articles to save to memory"
    return
  fi

  # Build header for this broadcast entry
  md_content="## ニュース配信 (${now_ts}) [${trigger_type}]
broadcast_id: ${broadcast_id}
"

  # Add each article's title and summary
  local idx=0
  while [[ ${idx} -lt ${article_count} ]]; do
    local title summary category
    title=$(echo "${content_json}" | jq -r ".[${idx}].title // \"\"" 2>/dev/null)
    summary=$(echo "${content_json}" | jq -r ".[${idx}].summary // \"\"" 2>/dev/null)
    category=$(echo "${content_json}" | jq -r ".[${idx}].category // \"\"" 2>/dev/null)

    if [[ -n "${title}" ]]; then
      md_content="${md_content}
### ${title}"
      [[ -n "${category}" ]] && md_content="${md_content}
カテゴリ: ${category}"
      [[ -n "${summary}" ]] && md_content="${md_content}
${summary}"
      md_content="${md_content}
"
    fi
    idx=$((idx + 1))
  done

  # Check if today's broadcast memory file already exists; if so, append
  local existing=""
  existing=$(docker exec soul-openclaw cat "${memory_dir}/${memory_file}" 2>/dev/null || echo "")

  local full_content
  if [[ -n "${existing}" ]]; then
    full_content="${existing}

${md_content}"
  else
    full_content="# ${today} ニュース配信記録

${md_content}"
  fi

  # Write via docker exec with stdin pipe (safe for special characters)
  if printf '%s' "${full_content}" | docker exec -i soul-openclaw tee "${memory_dir}/${memory_file}" > /dev/null 2>&1; then
    # Fix ownership to match other memory files
    docker exec soul-openclaw chown openclaw:openclaw "${memory_dir}/${memory_file}" 2>/dev/null || true
    log "Proactive engine: Saved broadcast summary to OpenClaw memory: ${memory_file}"
  else
    log "WARN: Proactive engine: Failed to write broadcast memory to OpenClaw"
    return
  fi

  # Cleanup: remove broadcast memory files older than 7 days
  local cutoff_date
  cutoff_date=$(date -u -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -u -v-7d +%Y-%m-%d 2>/dev/null || echo "")
  if [[ -n "${cutoff_date}" ]]; then
    local old_files
    old_files=$(docker exec soul-openclaw ls "${memory_dir}/" 2>/dev/null | grep '^broadcast-' || echo "")
    while IFS= read -r fname; do
      [[ -z "${fname}" ]] && continue
      # Extract date from filename: broadcast-YYYY-MM-DD.md
      local fdate
      fdate=$(echo "${fname}" | sed -n 's/^broadcast-\([0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}\)\.md$/\1/p')
      if [[ -n "${fdate}" && "${fdate}" < "${cutoff_date}" ]]; then
        docker exec soul-openclaw rm -f "${memory_dir}/${fname}" 2>/dev/null
        log "Proactive engine: Cleaned up old broadcast memory: ${fname}"
      fi
    done <<< "${old_files}"
  fi

  # Also write to MCP server-memory's memory.jsonl for Knowledge Graph access
  local memory_jsonl="/home/openclaw/.openclaw/memory/memory.jsonl"
  local entity_name="broadcast_${now_ts//[:T-]/_}"
  entity_name="${entity_name//./_}"  # sanitize dots

  # Build observations array: each article as an observation
  local observations="[]"
  idx=0
  while [[ ${idx} -lt ${article_count} ]]; do
    local obs_title obs_summary obs_category obs_text
    obs_title=$(echo "${content_json}" | jq -r ".[${idx}].title // \"\"" 2>/dev/null)
    obs_summary=$(echo "${content_json}" | jq -r ".[${idx}].summary // \"\"" 2>/dev/null)
    obs_category=$(echo "${content_json}" | jq -r ".[${idx}].category // \"\"" 2>/dev/null)
    obs_text="${obs_title}"
    [[ -n "${obs_category}" ]] && obs_text="${obs_text} [${obs_category}]"
    [[ -n "${obs_summary}" ]] && obs_text="${obs_text}: ${obs_summary}"
    observations=$(echo "${observations}" | jq --arg o "${obs_text}" '. + [$o]')
    idx=$((idx + 1))
  done

  local entity_json
  entity_json=$(jq -c -n \
    --arg name "${entity_name}" \
    --arg type "news_broadcast" \
    --argjson obs "${observations}" \
    '{type: "entity", name: $name, entityType: $type, observations: $obs}')

  if printf '%s\n' "${entity_json}" | docker exec -i soul-openclaw tee -a "${memory_jsonl}" > /dev/null 2>&1; then
    docker exec soul-openclaw chown openclaw:openclaw "${memory_jsonl}" 2>/dev/null || true
    log "Proactive engine: Saved broadcast entity to memory.jsonl: ${entity_name}"
  else
    log "WARN: Proactive engine: Failed to write broadcast entity to memory.jsonl"
  fi

  # Cleanup: remove old news_broadcast entities from memory.jsonl (older than 7 days)
  if [[ -n "${cutoff_date}" ]]; then
    local cutoff_ts="${cutoff_date}T00:00:00Z"
    cutoff_ts="${cutoff_ts//[:T-]/_}"
    cutoff_ts="${cutoff_ts//./_}"
    # Filter out old broadcast entities by comparing entity names
    local cleanup_script="import sys, json
lines = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        obj = json.loads(line)
        if obj.get('entityType') == 'news_broadcast':
            name = obj.get('name', '')
            if name.startswith('broadcast_') and name < 'broadcast_${cutoff_ts}':
                continue
        lines.append(line)
    except:
        lines.append(line)
print('\\n'.join(lines))"
    local cleaned
    cleaned=$(docker exec soul-openclaw cat "${memory_jsonl}" 2>/dev/null | python3 -c "${cleanup_script}" 2>/dev/null)
    if [[ -n "${cleaned}" ]]; then
      printf '%s\n' "${cleaned}" | docker exec -i soul-openclaw tee "${memory_jsonl}" > /dev/null 2>&1
      docker exec soul-openclaw chown openclaw:openclaw "${memory_jsonl}" 2>/dev/null || true
    fi
  fi
}

# ---- Trending News Broadcast ----

# Get recent conversation topic hints from a session file (last few messages)
# Returns user and assistant text content for topic analysis
_get_recent_chat_context() {
  local session_key="$1"

  # Check if OpenClaw container is running
  if ! docker ps --filter "name=soul-openclaw" --filter "status=running" --format '{{.Names}}' 2>/dev/null | grep -q "soul-openclaw"; then
    log "WARN: Proactive engine: OpenClaw container is not running, skipping context for ${session_key}"
    echo ""
    return
  fi

  # Get session ID from sessions.json
  local session_id
  session_id=$(docker exec soul-openclaw cat /home/openclaw/.openclaw/agents/main/sessions/sessions.json 2>/dev/null \
    | jq -r --arg key "${session_key}" '.[$key].sessionId // ""' 2>/dev/null)

  if [[ -z "${session_id}" || "${session_id}" == "null" ]]; then
    log "WARN: Proactive engine: No sessionId found for ${session_key}"
    echo ""
    return
  fi

  local session_file="/home/openclaw/.openclaw/agents/main/sessions/${session_id}.jsonl"

  # Check if session file exists
  if ! docker exec soul-openclaw test -f "${session_file}" 2>/dev/null; then
    log "WARN: Proactive engine: Session file not found for ${session_key}: ${session_file}"
    echo ""
    return
  fi

  # Get last 40 lines and extract ONLY user text content using jq
  # Bot/assistant messages are excluded to prevent echo chamber effect
  # (previous broadcast content would otherwise influence next broadcast's topic analysis)
  local context
  context=$(docker exec soul-openclaw sh -c "tail -40 '${session_file}' | jq -r 'select(.type == \"message\") | select(.message.role == \"user\") | .message.content | if type == \"array\" then map(select(.type == \"text\") | .text) | join(\" \") elif type == \"string\" then . else empty end' 2>/dev/null | tail -5 | cut -c1-200 | tr '\n' ' '" 2>/dev/null \
    | sed 's/  */ /g')

  if [[ -n "${context}" ]]; then
    echo "${context}"
  else
    echo ""
  fi
}

# Main broadcast flow for trending_news trigger
_execute_trending_broadcast() {
  local trigger_name="$1"
  local trigger_json="$2"

  log "Proactive engine: Starting trending news broadcast"
  _update_broadcast_state "delivering"
  set_activity "broadcasting_news" "\"trigger\":\"${trigger_name}\","

  # Step 0: Collect chat contexts and generate dynamic search queries
  log "Proactive engine: Collecting chat contexts for dynamic query generation..."
  local activity_window_pre
  activity_window_pre=$(echo "${trigger_json}" | jq -r '.activity_window_hours // 72')
  local chat_profiles_pre default_profile_pre
  chat_profiles_pre=$(echo "${trigger_json}" | jq -c '.chat_profiles // {}')
  default_profile_pre=$(echo "${trigger_json}" | jq -c '.default_profile // {"name":"一般","audience":"一般","tone":"カジュアル"}')

  local all_chat_contexts
  all_chat_contexts=$(_collect_all_chat_contexts "${activity_window_pre}" "${chat_profiles_pre}" "${default_profile_pre}")

  local dynamic_queries=""
  if [[ -n "${all_chat_contexts}" ]]; then
    dynamic_queries=$(_generate_dynamic_queries "${all_chat_contexts}")
  else
    log "Proactive engine: No chat context available, will use fixed queries only"
  fi

  # Step 0.5: Fetch Google Trends trending keyword
  log "Proactive engine: Fetching Google Trends..."
  local google_trends_json
  google_trends_json=$(_fetch_google_trends)
  if [[ -n "${google_trends_json}" ]]; then
    log "Proactive engine: Google Trends topic: $(echo "${google_trends_json}" | jq -r '.keyword' 2>/dev/null)"

    # Also add the trends keyword to dynamic queries for search diversity
    local trends_kw
    trends_kw=$(echo "${google_trends_json}" | jq -r '.keyword // ""' 2>/dev/null)
    if [[ -n "${trends_kw}" && -n "${dynamic_queries}" ]]; then
      dynamic_queries=$(echo "${dynamic_queries}" | jq --arg kw "${trends_kw}" '. + [$kw]' 2>/dev/null)
    elif [[ -n "${trends_kw}" ]]; then
      dynamic_queries="[\"${trends_kw}\"]"
    fi
  else
    log "Proactive engine: Google Trends unavailable, continuing without"
  fi

  # Step 1: Discover trending content (single fetch, 8-10 items)
  log "Proactive engine: Discovering trending content via Brave Search..."
  local content_json
  content_json=$(_discover_trending_content "${trigger_json}" "${dynamic_queries}")

  if [[ -z "${content_json}" || "${content_json}" == "[]" ]]; then
    log "ERROR: Proactive engine: No trending content discovered"
    _update_broadcast_state "error"
    set_activity "idle"
    return 1
  fi

  local item_count
  item_count=$(echo "${content_json}" | jq 'length' 2>/dev/null || echo 0)
  log "Proactive engine: Discovered ${item_count} trending items"

  # Step 2: Get mode
  local mode
  mode=$(jq -r '.mode // "dryrun"' "${PROACTIVE_CONFIG}")

  # Step 3: Build delivery targets (dynamic or static)
  local is_dynamic activity_window
  is_dynamic=$(echo "${trigger_json}" | jq -r '.dynamic // false')
  activity_window=$(echo "${trigger_json}" | jq -r '.activity_window_hours // 72')

  # Get destination style/context templates and chat profiles from config
  local dest_templates chat_profiles default_profile
  dest_templates=$(echo "${trigger_json}" | jq -c '.destinations // []')
  chat_profiles=$(echo "${trigger_json}" | jq -c '.chat_profiles // {}')
  default_profile=$(echo "${trigger_json}" | jq -c '.default_profile // {"name":"一般","audience":"一般","tone":"カジュアル"}')

  # Build actual delivery targets
  local delivery_targets="[]"
  if [[ "${is_dynamic}" == "true" ]]; then
    log "Proactive engine: Dynamic mode - discovering active chats (${activity_window}h window)..."
    local active_chats
    active_chats=$(_get_active_chats "${activity_window}")
    local active_count
    active_count=$(echo "${active_chats}" | jq 'length' 2>/dev/null || echo 0)
    log "Proactive engine: Found ${active_count} active chats"

    if [[ ${active_count} -eq 0 ]]; then
      log "WARN: Proactive engine: No active chats found, skipping broadcast"
      _update_broadcast_state "completed"
      set_activity "idle"
      return 0
    fi

    # For each active chat, merge with matching destination template and chat profile
    delivery_targets=$(echo "${active_chats}" | jq -c --argjson templates "${dest_templates}" --argjson profiles "${chat_profiles}" --argjson defprofile "${default_profile}" '
      [.[] | . as $chat |
        ($templates | map(select(.type == $chat.type)) | .[0]) as $tmpl |
        ($profiles[$chat.session_key] // $defprofile) as $profile |
        if $tmpl then
          $chat + {style: $tmpl.style, context: $tmpl.context, chat_profile: $profile}
        else
          $chat + {style: "default", context: "", chat_profile: $profile}
        end
      ]
    ')
  else
    # Static mode: use destinations from config directly
    delivery_targets="${dest_templates}"
  fi

  local dest_count
  dest_count=$(echo "${delivery_targets}" | jq 'length')

  # Step 4: Use single LLM call to assign optimal articles to each chat
  log "Proactive engine: Assigning articles to chats via LLM..."

  # Build chat description list for LLM
  local chat_descriptions=""
  local i=0
  while [[ ${i} -lt ${dest_count} ]]; do
    local dest session_key profile_name profile_audience profile_tone
    dest=$(echo "${delivery_targets}" | jq -c ".[${i}]")
    session_key=$(echo "${dest}" | jq -r '.session_key // ""')
    profile_name=$(echo "${dest}" | jq -r '.chat_profile.name // "不明"')
    profile_audience=$(echo "${dest}" | jq -r '.chat_profile.audience // "一般"')
    profile_tone=$(echo "${dest}" | jq -r '.chat_profile.tone // "カジュアル"')

    # Get recent conversation context if available
    local recent_context=""
    if [[ -n "${session_key}" ]]; then
      recent_context=$(_get_recent_chat_context "${session_key}")
    fi

    chat_descriptions="${chat_descriptions}
### チャット${i}: ${profile_name}
- session_key: ${session_key}
- 対象: ${profile_audience}
- トーン: ${profile_tone}"
    if [[ -n "${recent_context}" ]]; then
      chat_descriptions="${chat_descriptions}
- 最近の会話: ${recent_context}"
    fi

    i=$((i + 1))
  done

  # Number articles for reference
  local numbered_articles
  numbered_articles=$(echo "${content_json}" | jq '[to_entries[] | {index: .key, title: .value.title, category: .value.category, summary: .value.summary}]')

  # Build Google Trends hint for diversity pick
  local trends_hint=""
  if [[ -n "${google_trends_json}" ]]; then
    trends_hint=$(echo "${google_trends_json}" | jq -r '.keyword // ""' 2>/dev/null)
  fi

  local assignment_prompt="あなたはニュース配信の最適化エンジンです。各チャットの会話コンテキストと属性を分析し、それぞれに最適な記事を正確に3件選んでください。

## 候補記事
${numbered_articles}

## チャット一覧
${chat_descriptions}

## Google Trends急上昇ワード（多様性確保の参考）
${trends_hint:-なし}

## 割り当てルール（最重要・厳守）
各チャットに正確に **3件** の記事を割り当てること。3件の内訳は以下の通り：

1. **コンテキスト記事2件**: そのチャットの「最近の会話」の内容に **直接関連する** 記事を2件選ぶ。
   - 「最近の会話」に具体的なトピック（例：ゲーム、株、料理、AI等）があればそのトピックに合致する記事を選ぶ
   - 会話コンテキストがない場合はaudienceとトーンに基づいて選ぶ
   - **重要**: 各チャットの会話内容が異なる場合、必ず異なる記事を選ぶこと
2. **多様性確保記事1件**: 上記2件とは異なるジャンルの記事を1件選ぶ。Google Trends急上昇ワードと同じ話題の記事は避けること（Trendsセクションで別途紹介するため）。候補記事の中からコンテキスト記事とは最も異なるジャンルの記事を選ぶ

## 差別化ルール（最重要）
- **各チャットの「最近の会話」が異なるトピックを含んでいる場合、コンテキスト記事2件は必ずチャット間で異なる記事にすること**
- 例：チャットAで「ゲーム」、チャットBで「投資」が話されていた場合、Aにはゲーム関連を、Bには投資関連を割り当てる
- 記事数が足りず完全な差別化が困難な場合でも、少なくとも1件は各チャット固有の記事にする
- 家族向けチャットに専門的すぎる記事は割り当てない
- 会話の内容から自由にトピックを判定し、カテゴリに制限なく最適な記事を選択すること

## 出力形式（厳守）
思考過程や説明文は一切出力しないこと。以下のJSON形式のみ出力すること。
キーはチャット番号（文字列）、値は記事インデックス（数値）の配列（正確に3件）。

{
  \"assignments\": {
    \"0\": [0, 2, 7],
    \"1\": [1, 3, 5]
  }
}"

  log "Proactive engine: Sending assignment prompt to LLM (${#assignment_prompt} chars)..."
  local assignment_response
  assignment_response=$(invoke_claude "${assignment_prompt}")

  if [[ -z "${assignment_response}" ]]; then
    log "ERROR: Proactive engine: invoke_claude returned empty response for article assignment"
    log "ERROR: Proactive engine: Will use round-robin fallback for all chats"
  else
    log "Proactive engine: Assignment response received (${#assignment_response} chars)"
    log "Proactive engine: Assignment raw (first 300 chars): ${assignment_response:0:300}"
  fi

  # Robust JSON extraction with 3-stage fallback
  local assignments=""

  if [[ -n "${assignment_response}" ]]; then
    # Stage 1: Extract ```json ... ``` code block
    local clean_response
    clean_response=$(echo "${assignment_response}" | sed -n '/^```\(json\)\?$/,/^```$/p' | sed '/^```\(json\)\?$/d;/^```$/d')

    if [[ -n "${clean_response}" ]]; then
      assignments=$(echo "${clean_response}" | jq '.assignments // empty' 2>/dev/null)
      [[ -n "${assignments}" && "${assignments}" != "null" ]] && \
        log "Proactive engine: JSON parsed via Stage 1 (code fence extraction)"
    fi

    # Stage 2: Extract from first { to last }
    if [[ -z "${assignments}" || "${assignments}" == "null" ]]; then
      local json_block
      json_block=$(echo "${assignment_response}" | sed -n '/[{]/,/[}]/p' | sed '/^```/d')
      if [[ -n "${json_block}" ]]; then
        assignments=$(echo "${json_block}" | jq '.assignments // empty' 2>/dev/null)
        if [[ -z "${assignments}" || "${assignments}" == "null" ]]; then
          # Try: top-level keys are numeric strings ("0": [...])
          assignments=$(echo "${json_block}" | jq 'if (keys[0] // "" | test("^[0-9]+$")) then . else empty end' 2>/dev/null)
        fi
        [[ -n "${assignments}" && "${assignments}" != "null" ]] && \
          log "Proactive engine: JSON parsed via Stage 2 (brace extraction)"
      fi
    fi

    # Stage 3: Try jq fromjson on the entire response (handles escaped JSON strings)
    if [[ -z "${assignments}" || "${assignments}" == "null" ]]; then
      local stripped
      stripped=$(echo "${assignment_response}" | sed '/^```/d' | tr -d '\n')
      assignments=$(echo "${stripped}" | jq -r 'if type == "string" then fromjson else . end | .assignments // empty' 2>/dev/null)
      [[ -n "${assignments}" && "${assignments}" != "null" ]] && \
        log "Proactive engine: JSON parsed via Stage 3 (fromjson)"
    fi
  fi

  # Final validation
  if [[ -z "${assignments}" || "${assignments}" == "null" || "${assignments}" == "{}" ]]; then
    log "WARN: Proactive engine: All 3 JSON parse stages failed. Raw response (first 500 chars): ${assignment_response:0:500}"
    log "WARN: Proactive engine: Using round-robin fallback assignment (3 articles per chat)"
    # Round-robin fallback: distribute articles evenly across chats
    assignments="{"
    local rr_total
    rr_total=$(echo "${content_json}" | jq 'length' 2>/dev/null || echo 0)
    local rr_i=0
    while [[ ${rr_i} -lt ${dest_count} ]]; do
      local rr_start=$(( (rr_i * 3) % rr_total ))
      local rr_a1=$(( rr_start % rr_total ))
      local rr_a2=$(( (rr_start + 1) % rr_total ))
      local rr_a3=$(( (rr_start + 2) % rr_total ))
      [[ ${rr_i} -gt 0 ]] && assignments="${assignments},"
      assignments="${assignments}\"${rr_i}\":[${rr_a1},${rr_a2},${rr_a3}]"
      rr_i=$((rr_i + 1))
    done
    assignments="${assignments}}"
    log "Proactive engine: Round-robin fallback assignments: ${assignments}"
    assignments=$(echo "${assignments}" | jq '.' 2>/dev/null)
  else
    log "Proactive engine: Successfully parsed assignments: $(echo "${assignments}" | jq -c '.' 2>/dev/null)"
    # Validate: check if all chats got identical assignments
    local unique_sets
    unique_sets=$(echo "${assignments}" | jq '[.[] | sort | tostring] | unique | length' 2>/dev/null || echo 0)
    local total_sets
    total_sets=$(echo "${assignments}" | jq 'keys | length' 2>/dev/null || echo 0)
    if [[ "${unique_sets}" -eq 1 && "${total_sets}" -gt 1 ]]; then
      log "WARN: Proactive engine: All ${total_sets} chats received identical assignments - applying round-robin offset"
      # Force differentiation by offsetting articles for each chat
      local rr_total_fix
      rr_total_fix=$(echo "${content_json}" | jq 'length' 2>/dev/null || echo 0)
      if [[ ${rr_total_fix} -ge 4 ]]; then
        local fixed_assignments="{"
        local rr_fi=0
        while [[ ${rr_fi} -lt ${total_sets} ]]; do
          local rr_base
          rr_base=$(echo "${assignments}" | jq -r --arg idx "${rr_fi}" '.[$idx] // .["0"] | .[0]' 2>/dev/null || echo 0)
          local rr_off=$(( rr_fi % (rr_total_fix - 2) ))
          local rr_f1=$(( (rr_base + rr_off) % rr_total_fix ))
          local rr_f2=$(( (rr_base + rr_off + 1) % rr_total_fix ))
          local rr_f3=$(( (rr_base + rr_off + 2) % rr_total_fix ))
          [[ ${rr_fi} -gt 0 ]] && fixed_assignments="${fixed_assignments},"
          fixed_assignments="${fixed_assignments}\"${rr_fi}\":[${rr_f1},${rr_f2},${rr_f3}]"
          rr_fi=$((rr_fi + 1))
        done
        fixed_assignments="${fixed_assignments}}"
        assignments=$(echo "${fixed_assignments}" | jq '.' 2>/dev/null)
        log "Proactive engine: Applied round-robin offset to differentiate: $(echo "${assignments}" | jq -c '.' 2>/dev/null)"
      else
        log "WARN: Proactive engine: Not enough articles (${rr_total_fix}) to differentiate, keeping identical assignments"
      fi
    else
      log "Proactive engine: ${unique_sets} unique assignment sets for ${total_sets} chats"
    fi
  fi
  # Ensure assignments is at least an empty object
  assignments="${assignments:-{}}"

  local broadcast_id now_ts
  broadcast_id=$(_generate_suggestion_id)
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local delivery_results="[]"

  # Step 5: Format and deliver to each chat (with error isolation)
  i=0
  while [[ ${i} -lt ${dest_count} ]]; do
    local dest dest_type target_id session_key chat_profile
    dest=$(echo "${delivery_targets}" | jq -c ".[${i}]")
    dest_type=$(echo "${dest}" | jq -r '.type')
    target_id=$(echo "${dest}" | jq -r '.target_id // ""')
    session_key=$(echo "${dest}" | jq -r '.session_key // ""')
    chat_profile=$(echo "${dest}" | jq -c '.chat_profile // null')

    local delivery_status="success"
    local delivery_error=""
    local formatted_content=""

    # Error isolation: wrap each chat's processing in a subshell-like pattern
    if true; then
      # Get assigned article indices for this chat
      local assigned_indices
      # Try both string and numeric key for the chat index
      assigned_indices=$(echo "${assignments}" | jq -c --arg idx "${i}" --argjson idxn "${i}" '.[$idx] // .[$idxn | tostring] // []' 2>/dev/null)
      if [[ -z "${assigned_indices}" || "${assigned_indices}" == "null" || "${assigned_indices}" == "[]" ]]; then
        # Fallback: use first 3 articles (no category-based filtering)
        log "WARN: Proactive engine: No assignment for chat ${i} (session: ${session_key}). Assignment keys: $(echo "${assignments}" | jq -c 'keys' 2>/dev/null)"
        assigned_indices=$(echo "${content_json}" | jq '[range([length, 3] | min)]')
        log "WARN: Proactive engine: Using first 3 articles as fallback for chat ${i}"
      else
        log "Proactive engine: Chat ${i} (${session_key}) assigned articles: ${assigned_indices}"
      fi

      # Build per-chat content from assigned indices
      local chat_content
      chat_content=$(echo "${content_json}" | jq -c --argjson indices "${assigned_indices}" '[. as $all | $indices[] | $all[.] // empty]')

      log "Proactive engine: Formatting content for ${dest_type} (target: ${target_id}, articles: $(echo "${chat_content}" | jq 'length'))..."
      formatted_content=$(_format_content_for_destination "${chat_content}" "${dest}" "${chat_profile}" "${google_trends_json}")

      if [[ "${mode}" == "dryrun" ]]; then
        log "Proactive engine [DRYRUN]: Would deliver to ${dest_type}:${target_id}: ${#formatted_content} chars"
        delivery_status="dryrun"
      else
        case "${dest_type}" in
          discord)
            local channel_id="${target_id}"
            if [[ -z "${channel_id}" ]]; then
              channel_id=$(echo "${dest}" | jq -r '.channel_id // ""')
            fi
            if [[ -n "${channel_id}" ]]; then
              if ! _deliver_discord_bot "${channel_id}" "${formatted_content}"; then
                delivery_status="failed"
                delivery_error="Discord delivery failed"
              fi
            else
              delivery_status="failed"
              delivery_error="No channel_id configured"
            fi
            ;;
          line)
            if [[ -z "${target_id}" ]]; then
              target_id=$(echo "${dest}" | jq -r '.target_id // ""')
            fi
            if [[ -n "${target_id}" ]]; then
              if ! _deliver_line "${target_id}" "${formatted_content}"; then
                delivery_status="failed"
                delivery_error="LINE delivery failed"
              fi
            else
              delivery_status="failed"
              delivery_error="No target_id configured"
            fi
            ;;
          *)
            delivery_status="skipped"
            delivery_error="Unknown destination type: ${dest_type}"
            ;;
        esac
      fi
    fi

    # Always record result, even if chat processing had errors
    delivery_results=$(echo "${delivery_results}" | jq \
      --arg type "${dest_type}" \
      --arg tid "${target_id}" \
      --arg sk "${session_key}" \
      --arg status "${delivery_status}" \
      --arg error "${delivery_error}" \
      --arg chars "${#formatted_content}" \
      --argjson articles "${assigned_indices:-[]}" \
      '. + [{destination: $type, target_id: $tid, session_key: $sk, status: $status, error: $error, content_length: ($chars | tonumber), assigned_articles: $articles}]')

    i=$((i + 1))
  done

  # Step 6: Save broadcast record
  local broadcast_record
  broadcast_record=$(jq -n \
    --arg id "${broadcast_id}" \
    --arg trigger "${trigger_name}" \
    --arg mode "${mode}" \
    --arg created "${now_ts}" \
    --argjson content "${content_json}" \
    --argjson deliveries "${delivery_results}" \
    '{
      id: $id,
      trigger: $trigger,
      mode: $mode,
      content: $content,
      deliveries: $deliveries,
      created_at: $created
    }' 2>/dev/null)

  # Guard against empty/invalid broadcast record
  if [[ -z "${broadcast_record}" ]] || ! echo "${broadcast_record}" | jq '.id' > /dev/null 2>&1; then
    log "WARN: Proactive engine: broadcast_record was empty or invalid, creating error record"
    broadcast_record=$(jq -n \
      --arg id "${broadcast_id}" --arg trigger "${trigger_name}" \
      --arg mode "${mode}" --arg created "${now_ts}" \
      --argjson deliveries "${delivery_results}" \
      '{id: $id, trigger: $trigger, mode: $mode, content: [], deliveries: $deliveries, created_at: $created, error: "broadcast_record_generation_failed"}')
  fi

  local broadcast_file="${PROACTIVE_BROADCAST_DIR}/${broadcast_id}.json"
  local tmp
  tmp=$(mktemp)
  echo "${broadcast_record}" > "${tmp}" && mv "${tmp}" "${broadcast_file}"

  # Update broadcast state for UI
  local state_file="${PROACTIVE_DIR}/state/broadcast.json"
  tmp=$(mktemp)
  jq -n \
    --arg status "completed" \
    --arg last_id "${broadcast_id}" \
    --arg delivered_at "${now_ts}" \
    --argjson deliveries "${delivery_results}" \
    --argjson active_chats "${dest_count}" \
    '{
      status: $status,
      last_broadcast_id: $last_id,
      last_delivered_at: $delivered_at,
      last_deliveries: $deliveries,
      active_chats: $active_chats,
      updated_at: $delivered_at
    }' > "${tmp}" && mv "${tmp}" "${state_file}"

  log "Proactive engine: Broadcast ${broadcast_id} completed (${dest_count} destinations)"

  # Save broadcast content to OpenClaw memory for later reference
  _save_broadcast_to_openclaw_memory "${content_json}" "${broadcast_id}" "manual"

  set_activity "idle"
  return 0
}

# ---- Force Trigger ----

# Check for manual force trigger from UI
_check_force_trigger() {
  local force_file="${PROACTIVE_DIR}/force_trigger.json"
  if [[ ! -f "${force_file}" ]]; then
    return 1
  fi

  local trigger_type
  trigger_type=$(jq -r '.trigger // ""' "${force_file}" 2>/dev/null)
  if [[ -z "${trigger_type}" ]]; then
    rm -f "${force_file}"
    return 1
  fi

  local triggered_by
  triggered_by=$(jq -r '.triggered_by // "unknown"' "${force_file}" 2>/dev/null)
  log "Proactive engine: Manual force trigger detected: ${trigger_type} (triggered_by: ${triggered_by})"
  rm -f "${force_file}"

  # Return the trigger name to fire
  echo "${trigger_type}"
  return 0
}

# ---- On-Demand Broadcast Request ----

# Check for broadcast request from OpenClaw
_check_broadcast_request() {
  local request_file="/openclaw-suggestions/broadcast_request.json"
  if [[ ! -f "${request_file}" ]]; then
    return 1
  fi

  local request_json
  request_json=$(cat "${request_file}" 2>/dev/null)
  if [[ -z "${request_json}" ]]; then
    rm -f "${request_file}"
    return 1
  fi

  log "Proactive engine: Broadcast request detected from OpenClaw"

  # Remove the file to prevent re-processing
  rm -f "${request_file}" 2>/dev/null || true

  # Return the request JSON
  echo "${request_json}"
  return 0
}

# Check ondemand cooldown per target_id - returns 0 if allowed, 1 if in cooldown
_check_ondemand_cooldown() {
  local target_id="${1:-}"
  local cooldown_secs
  cooldown_secs=$(jq -r '.ondemand_cooldown_seconds // 1800' "${PROACTIVE_CONFIG}")

  local last_ondemand
  if [[ -n "${target_id}" ]]; then
    # Per-target cooldown check
    last_ondemand=$(jq -r --arg tid "${target_id}" '.ondemand_cooldowns[$tid] // ""' "${PROACTIVE_STATE}" 2>/dev/null)
  else
    # Legacy global check
    last_ondemand=$(jq -r '.last_ondemand_at // ""' "${PROACTIVE_STATE}")
  fi

  if [[ -z "${last_ondemand}" || "${last_ondemand}" == "null" ]]; then
    return 0
  fi

  local last_epoch now_epoch elapsed
  last_epoch=$(date -d "${last_ondemand}" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)
  elapsed=$((now_epoch - last_epoch))

  if [[ ${elapsed} -lt ${cooldown_secs} ]]; then
    local remaining=$((cooldown_secs - elapsed))
    log "Proactive engine: On-demand cooldown active for ${target_id:-global} (${remaining}s remaining)"
    return 1
  fi

  return 0
}

# Record ondemand broadcast timestamp per target_id
_record_ondemand_broadcast() {
  local target_id="${1:-}"
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local tmp
  tmp=$(mktemp)

  if [[ -n "${target_id}" ]]; then
    jq --arg ts "${now_ts}" --arg tid "${target_id}" \
      '.ondemand_cooldowns[$tid] = $ts | .last_ondemand_at = $ts' \
      "${PROACTIVE_STATE}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_STATE}"
  else
    jq --arg ts "${now_ts}" '.last_ondemand_at = $ts' \
      "${PROACTIVE_STATE}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_STATE}"
  fi
}

# Notify user that ondemand cooldown is active (safety net for Brain-side cooldown)
_notify_ondemand_cooldown() {
  local target_id="$1"
  local platform="$2"

  local mode
  mode=$(jq -r '.mode // "dryrun"' "${PROACTIVE_CONFIG}")

  local cooldown_secs remaining_secs
  cooldown_secs=$(jq -r '.ondemand_cooldown_seconds // 1800' "${PROACTIVE_CONFIG}")
  local last_ondemand
  last_ondemand=$(jq -r --arg tid "${target_id}" '.ondemand_cooldowns[$tid] // ""' "${PROACTIVE_STATE}" 2>/dev/null)
  if [[ -n "${last_ondemand}" && "${last_ondemand}" != "null" ]]; then
    local last_epoch now_epoch
    last_epoch=$(date -d "${last_ondemand}" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    remaining_secs=$(( cooldown_secs - (now_epoch - last_epoch) ))
    if [[ ${remaining_secs} -lt 0 ]]; then remaining_secs=0; fi
  else
    remaining_secs=0
  fi

  local remaining_min=$(( (remaining_secs + 59) / 60 ))
  local message="さっきニュース送ったばかりだぜ。あと${remaining_min}分くらい待ってくれ！"

  if [[ "${mode}" == "dryrun" ]]; then
    log "Proactive engine [DRYRUN]: Would send cooldown notification to ${platform}:${target_id}: ${message}"
    return 0
  fi

  case "${platform}" in
    line)
      _deliver_line "${target_id}" "${message}"
      ;;
    discord)
      _deliver_discord_bot "${target_id}" "${message}"
      ;;
  esac
}

# Execute on-demand broadcast for a specific chat (from OpenClaw request)
_execute_ondemand_broadcast() {
  local request_json="$1"
  local trigger_json="$2"

  local platform chat_type target_id
  platform=$(echo "${request_json}" | jq -r '.chat.platform // ""')
  chat_type=$(echo "${request_json}" | jq -r '.chat.chat_type // ""')
  target_id=$(echo "${request_json}" | jq -r '.chat.target_id // ""')

  if [[ -z "${platform}" || -z "${target_id}" ]]; then
    log "WARN: Proactive engine: Invalid broadcast request - missing platform or target_id"
    return 1
  fi

  log "Proactive engine: On-demand broadcast for ${platform}:${target_id}"
  _update_broadcast_state "delivering"
  set_activity "broadcasting_news" "\"trigger\":\"ondemand\",\"platform\":\"${platform}\","

  # Extract session_key and chat profile early (needed for context-aware search)
  local session_key
  session_key=$(echo "${request_json}" | jq -r '.chat.session_key // ""')
  local chat_profiles_cfg default_profile chat_profile
  chat_profiles_cfg=$(echo "${trigger_json}" | jq -c '.chat_profiles // {}')
  default_profile=$(echo "${trigger_json}" | jq -c '.default_profile // {"name":"一般","audience":"一般","tone":"カジュアル"}')
  chat_profile=$(echo "${chat_profiles_cfg}" | jq -c --arg sk "${session_key}" '.[$sk] // null')
  if [[ "${chat_profile}" == "null" || -z "${chat_profile}" ]]; then
    chat_profile="${default_profile}"
  fi

  # Collect chat context for this specific chat to generate context-aware search queries
  local dynamic_queries=""
  if [[ -n "${session_key}" ]]; then
    local chat_context
    chat_context=$(_get_recent_chat_context "${session_key}")
    if [[ -n "${chat_context}" ]]; then
      local chat_profile_name
      chat_profile_name=$(echo "${chat_profile}" | jq -r '.name // "不明"')
      local context_text="### ${chat_profile_name} (${session_key})
${chat_context}"
      dynamic_queries=$(_generate_dynamic_queries "${context_text}")
      log "Proactive engine: Generated dynamic queries from chat context for on-demand broadcast"
    fi
  fi

  # Fetch Google Trends for additional query diversity
  local google_trends_json=""
  google_trends_json=$(_fetch_google_trends)
  if [[ -n "${google_trends_json}" ]]; then
    local trends_kw
    trends_kw=$(echo "${google_trends_json}" | jq -r '.keyword // ""' 2>/dev/null)
    if [[ -n "${trends_kw}" && -n "${dynamic_queries}" ]]; then
      dynamic_queries=$(echo "${dynamic_queries}" | jq --arg kw "${trends_kw}" '. + [$kw]' 2>/dev/null)
    elif [[ -n "${trends_kw}" ]]; then
      dynamic_queries="[\"${trends_kw}\"]"
    fi
    log "Proactive engine: Added Google Trends keyword to on-demand queries"
  fi

  # Ensure minimum query diversity: if dynamic queries < 3, add generic fallback queries
  local dq_count=0
  if [[ -n "${dynamic_queries}" ]]; then
    dq_count=$(echo "${dynamic_queries}" | jq 'length' 2>/dev/null || echo 0)
  fi
  if [[ ${dq_count} -lt 3 ]]; then
    local today_fallback
    today_fallback=$(_get_jst_date)
    local fallback_items='["最新ニュース 話題 '"${today_fallback}"'","今日の注目ニュース 日本 '"${today_fallback}"'","いま話題のニュース '"${today_fallback}"'"]'
    if [[ -n "${dynamic_queries}" && "${dynamic_queries}" != "[]" ]]; then
      dynamic_queries=$(echo "${dynamic_queries}" | jq --argjson fb "${fallback_items}" '. + $fb' 2>/dev/null)
    else
      dynamic_queries="${fallback_items}"
    fi
    log "Proactive engine: Dynamic queries were ${dq_count}, added fallback queries for minimum diversity"
  fi

  # Discover content using chat-context-aware queries
  local content_json
  content_json=$(_discover_trending_content "${trigger_json}" "${dynamic_queries}")
  if [[ -z "${content_json}" || "${content_json}" == "[]" ]]; then
    log "ERROR: Proactive engine: No trending content for on-demand broadcast"
    _update_broadcast_state "error"
    set_activity "idle"
    return 1
  fi

  local mode
  mode=$(jq -r '.mode // "dryrun"' "${PROACTIVE_CONFIG}")

  # Get the matching destination template and chat profile
  local dest_templates
  dest_templates=$(echo "${trigger_json}" | jq -c '.destinations // []')
  local dest_template
  dest_template=$(echo "${dest_templates}" | jq -c --arg t "${platform}" '(map(select(.type == $t)) | .[0]) // {style: "default", context: ""}')

  # session_key and chat_profile already extracted earlier

  # Build single-target delivery
  local dest
  dest=$(echo "${dest_template}" | jq -c --arg tid "${target_id}" --arg t "${platform}" '. + {type: $t, target_id: $tid}')

  # Select 3 articles from the pool based on chat context
  local item_count
  item_count=$(echo "${content_json}" | jq 'length' 2>/dev/null || echo 0)

  local selected_content="${content_json}"
  if [[ ${item_count} -gt 3 ]]; then
    log "Proactive engine: Selecting 3 articles from ${item_count} candidates for on-demand..."

    # Get chat context for article selection
    local recent_context=""
    if [[ -n "${session_key}" ]]; then
      recent_context=$(_get_recent_chat_context "${session_key}")
    fi

    local profile_name profile_audience profile_tone
    profile_name=$(echo "${chat_profile}" | jq -r '.name // "不明"')
    profile_audience=$(echo "${chat_profile}" | jq -r '.audience // "一般"')
    profile_tone=$(echo "${chat_profile}" | jq -r '.tone // "カジュアル"')

    local numbered_articles
    numbered_articles=$(echo "${content_json}" | jq '[to_entries[] | {index: .key, title: .value.title, category: .value.category, summary: .value.summary}]')

    local trends_hint=""
    if [[ -n "${google_trends_json}" ]]; then
      trends_hint=$(echo "${google_trends_json}" | jq -r '.keyword // ""' 2>/dev/null)
    fi

    local select_prompt="以下の候補記事からこのチャットに最適な3件を選んでください。

## 候補記事
${numbered_articles}

## チャット情報
- チャット名: ${profile_name}
- 対象: ${profile_audience}
- トーン: ${profile_tone}"
    if [[ -n "${recent_context}" ]]; then
      select_prompt="${select_prompt}
- 最近の会話: ${recent_context}"
    fi

    select_prompt="${select_prompt}

## Google Trends急上昇ワード
${trends_hint:-なし}

## 選択ルール
1. コンテキスト記事2件: 会話の内容に最も関連する記事を2件選ぶ。会話コンテキストがない場合はaudienceに基づいて最適な記事を選ぶ
2. 多様性確保記事1件: 上記2件とは異なるジャンルの記事を1件。Google Trends急上昇ワードと同じ話題の記事は避けること（Trendsセクションで別途紹介するため）
- カテゴリに制限なく、会話の内容から自由にトピックを判定すること

## 出力形式（厳守）
思考過程や説明文は一切出力しないこと。記事インデックスの配列のみ出力。
[0, 3, 7]"

    local select_response
    select_response=$(invoke_claude "${select_prompt}")

    # Parse the response - try to extract a JSON array
    local selected_indices=""
    if [[ -n "${select_response}" ]]; then
      selected_indices=$(echo "${select_response}" | sed '/^```/d' | jq -c '.' 2>/dev/null)
      if [[ -z "${selected_indices}" ]] || ! echo "${selected_indices}" | jq '.[0]' > /dev/null 2>&1; then
        # Try extracting array from text
        selected_indices=$(echo "${select_response}" | grep -oP '\[[\d,\s]+\]' | head -1 | jq -c '.' 2>/dev/null)
      fi
    fi

    if [[ -n "${selected_indices}" ]] && echo "${selected_indices}" | jq '.[0]' > /dev/null 2>&1; then
      selected_content=$(echo "${content_json}" | jq -c --argjson indices "${selected_indices}" '. as $all | [. as $all | $indices[] | $all[.] // empty] | if length == 0 then $all[:3] else . end')
      log "Proactive engine: Selected articles: ${selected_indices}"
    else
      log "WARN: Proactive engine: Article selection failed, using first 3"
      selected_content=$(echo "${content_json}" | jq -c '.[0:3]')
    fi
  fi

  log "Proactive engine: Formatting content for ${platform}..."
  local formatted_content
  formatted_content=$(_format_content_for_destination "${selected_content}" "${dest}" "${chat_profile}" "${google_trends_json}")

  local delivery_status="success"
  local delivery_error=""
  local broadcast_id now_ts
  broadcast_id=$(_generate_suggestion_id)
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ "${mode}" == "dryrun" ]]; then
    log "Proactive engine [DRYRUN]: On-demand would deliver to ${platform}:${target_id}: ${#formatted_content} chars"
    delivery_status="dryrun"
  else
    case "${platform}" in
      discord)
        if ! _deliver_discord_bot "${target_id}" "${formatted_content}"; then
          delivery_status="failed"
          delivery_error="Discord delivery failed"
        fi
        ;;
      line)
        if ! _deliver_line "${target_id}" "${formatted_content}"; then
          delivery_status="failed"
          delivery_error="LINE delivery failed"
        fi
        ;;
    esac
  fi

  # Save broadcast record
  local delivery_results
  delivery_results=$(jq -n \
    --arg type "${platform}" --arg tid "${target_id}" \
    --arg status "${delivery_status}" --arg error "${delivery_error}" \
    --arg chars "${#formatted_content}" \
    '[{destination: $type, target_id: $tid, status: $status, error: $error, content_length: ($chars | tonumber)}]')

  local broadcast_record
  broadcast_record=$(jq -n \
    --arg id "${broadcast_id}" --arg trigger "ondemand" \
    --arg mode "${mode}" --arg created "${now_ts}" \
    --argjson content "${selected_content}" --argjson deliveries "${delivery_results}" \
    '{id: $id, trigger: $trigger, mode: $mode, content: $content, deliveries: $deliveries, created_at: $created}' 2>/dev/null)

  # Guard against empty/invalid broadcast record
  if [[ -z "${broadcast_record}" ]] || ! echo "${broadcast_record}" | jq '.id' > /dev/null 2>&1; then
    log "WARN: Proactive engine: broadcast_record was empty or invalid, creating error record"
    broadcast_record=$(jq -n \
      --arg id "${broadcast_id}" --arg trigger "ondemand" \
      --arg mode "${mode}" --arg created "${now_ts}" \
      --argjson deliveries "${delivery_results}" \
      '{id: $id, trigger: $trigger, mode: $mode, content: [], deliveries: $deliveries, created_at: $created, error: "broadcast_record_generation_failed"}')
  fi

  local broadcast_file="${PROACTIVE_BROADCAST_DIR}/${broadcast_id}.json"
  local tmp
  tmp=$(mktemp)
  echo "${broadcast_record}" > "${tmp}" && mv "${tmp}" "${broadcast_file}"

  # Update broadcast state
  local state_file="${PROACTIVE_DIR}/state/broadcast.json"
  tmp=$(mktemp)
  jq -n \
    --arg status "completed" --arg last_id "${broadcast_id}" \
    --arg delivered_at "${now_ts}" --argjson deliveries "${delivery_results}" \
    '{status: $status, last_broadcast_id: $last_id, last_delivered_at: $delivered_at, last_deliveries: $deliveries, updated_at: $delivered_at}' \
    > "${tmp}" && mv "${tmp}" "${state_file}"

  log "Proactive engine: On-demand broadcast ${broadcast_id} completed"

  # Save broadcast content to OpenClaw memory for later reference
  _save_broadcast_to_openclaw_memory "${selected_content}" "${broadcast_id}" "ondemand"

  # Write marker so OpenClaw knows a broadcast was recently served
  # Write per-target marker so OpenClaw knows when each target was last served
  local marker_file="/openclaw-suggestions/broadcast_last_served.json"
  local marker_tmp
  marker_tmp=$(mktemp)
  local existing_markers="{}"
  if [[ -f "${marker_file}" ]]; then
    existing_markers=$(cat "${marker_file}" 2>/dev/null || echo "{}")
    if ! echo "${existing_markers}" | jq '.' > /dev/null 2>&1; then
      existing_markers="{}"
    fi
    # Migrate old single-record format if detected
    if echo "${existing_markers}" | jq -e '.served_at' > /dev/null 2>&1; then
      local old_tid old_ts old_id
      old_tid=$(echo "${existing_markers}" | jq -r '.target_id // ""')
      old_ts=$(echo "${existing_markers}" | jq -r '.served_at // ""')
      old_id=$(echo "${existing_markers}" | jq -r '.broadcast_id // ""')
      if [[ -n "${old_tid}" ]]; then
        existing_markers=$(jq -n --arg tid "${old_tid}" --arg ts "${old_ts}" --arg id "${old_id}" \
          '{($tid): {served_at: $ts, broadcast_id: $id}}')
      else
        existing_markers="{}"
      fi
    fi
  fi
  echo "${existing_markers}" | jq \
    --arg tid "${target_id}" --arg ts "${now_ts}" --arg id "${broadcast_id}" \
    '.[$tid] = {served_at: $ts, broadcast_id: $id}' \
    > "${marker_tmp}" && chmod 644 "${marker_tmp}" && mv "${marker_tmp}" "${marker_file}" 2>/dev/null || true

  set_activity "idle"
  return 0
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
      # Even during throttle, check for force trigger
      local force_trigger
      force_trigger=$(_check_force_trigger)
      if [[ -n "${force_trigger}" ]]; then
        log "Proactive engine: Processing manual force trigger: ${force_trigger}"
        local trigger_json
        trigger_json=$(jq ".triggers.\"${force_trigger}\"" "${PROACTIVE_CONFIG}" 2>/dev/null)
        if [[ -n "${trigger_json}" && "${trigger_json}" != "null" ]]; then
          _execute_trending_broadcast "${force_trigger}" "${trigger_json}"
        fi
      fi
      # Also check for on-demand broadcast request during throttle
      local broadcast_request
      broadcast_request=$(_check_broadcast_request)
      if [[ -n "${broadcast_request}" ]]; then
        local req_target_id req_platform
        req_target_id=$(echo "${broadcast_request}" | jq -r '.chat.target_id // ""')
        req_platform=$(echo "${broadcast_request}" | jq -r '.chat.platform // ""')

        if _check_ondemand_cooldown "${req_target_id}"; then
          local category="info"
          if _check_rate_limit "${category}"; then
            local tn
            tn=$(jq '.triggers.trending_news' "${PROACTIVE_CONFIG}" 2>/dev/null)
            if [[ -n "${tn}" && "${tn}" != "null" ]]; then
              _execute_ondemand_broadcast "${broadcast_request}" "${tn}"
              _increment_daily_count "${category}"
              _record_ondemand_broadcast "${req_target_id}"
            fi
          else
            log "Proactive engine: On-demand broadcast rate-limited"
          fi
        else
          log "Proactive engine: On-demand cooldown active for ${req_target_id}, sending notification"
          _notify_ondemand_cooldown "${req_target_id}" "${req_platform}"
        fi
      fi
      # Check alert notifications even during throttle
      _check_alert_notifications
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

  # Check for force trigger
  local force_trigger
  force_trigger=$(_check_force_trigger)
  if [[ -n "${force_trigger}" ]]; then
    log "Proactive engine: Processing force trigger: ${force_trigger}"
    local trigger_json
    trigger_json=$(jq ".triggers.\"${force_trigger}\"" "${PROACTIVE_CONFIG}" 2>/dev/null)
    if [[ -n "${trigger_json}" && "${trigger_json}" != "null" ]]; then
      _execute_trending_broadcast "${force_trigger}" "${trigger_json}"
      _increment_daily_count "info"
      return 0
    fi
  fi

  # Check for on-demand broadcast request from OpenClaw
  local broadcast_request
  broadcast_request=$(_check_broadcast_request)
  if [[ -n "${broadcast_request}" ]]; then
    local req_target_id req_platform
    req_target_id=$(echo "${broadcast_request}" | jq -r '.chat.target_id // ""')
    req_platform=$(echo "${broadcast_request}" | jq -r '.chat.platform // ""')

    if _check_ondemand_cooldown "${req_target_id}"; then
      local category="info"
      if _check_rate_limit "${category}"; then
        local trending_trigger
        trending_trigger=$(jq '.triggers.trending_news' "${PROACTIVE_CONFIG}" 2>/dev/null)
        if [[ -n "${trending_trigger}" && "${trending_trigger}" != "null" ]]; then
          _execute_ondemand_broadcast "${broadcast_request}" "${trending_trigger}"
          _increment_daily_count "${category}"
          _record_ondemand_broadcast "${req_target_id}"
          return 0
        fi
      else
        log "Proactive engine: On-demand broadcast rate-limited"
      fi
    else
      log "Proactive engine: On-demand cooldown active for ${req_target_id}, sending notification"
      _notify_ondemand_cooldown "${req_target_id}" "${req_platform}"
    fi
  fi

  # Check alert notifications
  _check_alert_notifications

  return 0
}
