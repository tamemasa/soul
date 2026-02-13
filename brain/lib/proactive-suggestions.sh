#!/usr/bin/env bash
# proactive-suggestions.sh - Proactive Suggestion Engine
#
# Monitors time-based and random-window triggers, generates suggestions,
# discovers trending content, and delivers to multiple destinations.
#
# Only triceratops runs this engine (as executor node).

PROACTIVE_DIR="${SHARED_DIR}/workspace/proactive-suggestions"
PROACTIVE_CONFIG="${PROACTIVE_DIR}/config.json"
PROACTIVE_STATE="${PROACTIVE_DIR}/state/engine.json"
PROACTIVE_DRYRUN_DIR="${PROACTIVE_DIR}/dryrun"
PROACTIVE_SUGGESTIONS_DIR="${PROACTIVE_DIR}/suggestions"
PROACTIVE_BROADCAST_DIR="${PROACTIVE_DIR}/broadcasts"

# Check interval: every 60 seconds (self-throttled within daemon's 10s loop)
PROACTIVE_CHECK_INTERVAL=60

# JST offset in seconds (+9 hours)
JST_OFFSET=32400

# ---- Initialization ----

_init_proactive_engine() {
  mkdir -p "${PROACTIVE_DIR}"/{dryrun,feedback,state,triggers,suggestions,broadcasts}

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
  "random_window_schedule": {},
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
    jq --arg d "${today}" '.daily_counts = {"date": $d, "info": 0, "suggestion": 0, "alert": 0, "total": 0} | .random_window_schedule = {}' \
      "${PROACTIVE_STATE}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_STATE}"
    log "Proactive engine: Daily counters and random schedules reset for ${today}"
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

# Check if a random_window trigger should fire
# Generates a random time on first check within window, then fires at that time
_should_fire_random_window_trigger() {
  local trigger_name="$1"
  local trigger_json="$2"

  local enabled
  enabled=$(echo "${trigger_json}" | jq -r '.enabled // false')
  if [[ "${enabled}" != "true" ]]; then
    return 1
  fi

  # Check if already fired today
  local today
  today=$(_get_jst_date)
  local last_fired
  last_fired=$(jq -r ".last_trigger_checks.\"${trigger_name}\" // \"\"" "${PROACTIVE_STATE}")
  if [[ "${last_fired}" == "${today}" ]]; then
    return 1
  fi

  local window_start window_end
  window_start=$(echo "${trigger_json}" | jq -r '.window_start_hour_jst // 12')
  window_end=$(echo "${trigger_json}" | jq -r '.window_end_hour_jst // 24')
  local window_start_min=$(( window_start * 60 ))
  local window_end_min=$(( window_end * 60 ))

  local current_min
  current_min=$(_get_jst_total_minutes)

  # Not yet in the window
  if [[ ${current_min} -lt ${window_start_min} ]]; then
    return 1
  fi

  # Check if we have a scheduled fire time for today
  local scheduled_min
  scheduled_min=$(jq -r ".random_window_schedule.\"${trigger_name}\" // \"\"" "${PROACTIVE_STATE}")

  if [[ -z "${scheduled_min}" || "${scheduled_min}" == "null" ]]; then
    # Generate random fire time within remaining window
    local remaining_start=${current_min}
    if [[ ${remaining_start} -lt ${window_start_min} ]]; then
      remaining_start=${window_start_min}
    fi
    local range=$(( window_end_min - remaining_start ))
    if [[ ${range} -le 0 ]]; then
      # Window has passed, skip for today
      return 1
    fi
    scheduled_min=$(( remaining_start + (RANDOM % range) ))
    # Save scheduled time to state
    local tmp
    tmp=$(mktemp)
    jq --arg name "${trigger_name}" --argjson min "${scheduled_min}" \
      '.random_window_schedule[$name] = $min' \
      "${PROACTIVE_STATE}" > "${tmp}" && mv "${tmp}" "${PROACTIVE_STATE}"
    local sched_h=$(( scheduled_min / 60 ))
    local sched_m=$(( scheduled_min % 60 ))
    log "Proactive engine: Scheduled ${trigger_name} for today at JST ${sched_h}:$(printf '%02d' ${sched_m})"
    # Update broadcast state for UI
    _update_broadcast_state "scheduled" "${scheduled_min}"
  fi

  # Check if current time has reached the scheduled time (within 2 min tolerance)
  local diff=$(( current_min - scheduled_min ))
  if [[ ${diff} -ge 0 && ${diff} -le 2 ]]; then
    return 0
  fi

  return 1
}

# Update broadcast state file for UI consumption
_update_broadcast_state() {
  local status="$1"
  local scheduled_min="${2:-}"
  local now_ts
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local today
  today=$(_get_jst_date)

  local state_file="${PROACTIVE_DIR}/state/broadcast.json"
  local broadcast_json
  if [[ -f "${state_file}" ]]; then
    broadcast_json=$(cat "${state_file}")
  else
    broadcast_json='{}'
  fi

  local tmp
  tmp=$(mktemp)
  if [[ "${status}" == "scheduled" && -n "${scheduled_min}" ]]; then
    # Count active chats when schedule is set (once per day)
    local trigger_cfg activity_window active_count
    trigger_cfg=$(jq '.triggers.trending_news' "${PROACTIVE_CONFIG}" 2>/dev/null)
    activity_window=$(echo "${trigger_cfg}" | jq -r '.activity_window_hours // 72' 2>/dev/null)
    local active_chats_json
    active_chats_json=$(_get_active_chats "${activity_window}" 2>/dev/null)
    active_count=$(echo "${active_chats_json}" | jq 'length' 2>/dev/null || echo 0)

    local sched_h=$(( scheduled_min / 60 ))
    local sched_m=$(( scheduled_min % 60 ))
    local sched_time="${today}T$(printf '%02d' ${sched_h}):$(printf '%02d' ${sched_m}):00+09:00"
    echo "${broadcast_json}" | jq \
      --arg s "${status}" --arg t "${sched_time}" --arg u "${now_ts}" --argjson ac "${active_count}" \
      '. + {status: $s, next_scheduled_at: $t, active_chats: $ac, updated_at: $u}' \
      > "${tmp}" && mv "${tmp}" "${state_file}"
  elif [[ "${status}" == "delivering" ]]; then
    echo "${broadcast_json}" | jq \
      --arg s "${status}" --arg u "${now_ts}" \
      '. + {status: $s, updated_at: $u}' \
      > "${tmp}" && mv "${tmp}" "${state_file}"
  elif [[ "${status}" == "completed" ]]; then
    echo "${broadcast_json}" | jq \
      --arg s "${status}" --arg u "${now_ts}" \
      '. + {status: $s, last_delivered_at: $u, next_scheduled_at: null, updated_at: $u}' \
      > "${tmp}" && mv "${tmp}" "${state_file}"
  else
    echo "${broadcast_json}" | jq \
      --arg s "${status}" --arg u "${now_ts}" \
      '. + {status: $s, updated_at: $u}' \
      > "${tmp}" && mv "${tmp}" "${state_file}"
  fi
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

# ---- Dynamic Query Generation ----

# Generate search queries dynamically from chat conversation context
# Returns newline-separated list of search queries (5-8 items)
_generate_dynamic_queries() {
  local chat_contexts="$1"
  local preferred_topics_hint="$2"

  if [[ -z "${chat_contexts}" ]]; then
    log "Proactive engine: No chat context available for dynamic query generation"
    echo ""
    return
  fi

  local prompt="あなたは検索クエリ生成エンジンです。以下のチャット会話のコンテキストから、今日検索すべきニュース・トレンドのトピックを5〜8件生成してください。

## チャットの会話コンテキスト
${chat_contexts}

## トピックのヒント
${preferred_topics_hint}

## ルール
- 会話で実際に話題になっている具体的なテーマから検索クエリを生成する
- 固定カテゴリに限定せず、会話の文脈から自由にトピックを選ぶ
- 各クエリは検索エンジンで使える具体的なキーワード（2〜5語程度）にする
- 日本語クエリと英語クエリを混ぜる
- 抽象的すぎるクエリ（例：「テクノロジー」だけ）は避ける

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

  # Extract JSON array from response
  local clean_response
  clean_response=$(echo "${response}" | sed -n '/^```\(json\)\?$/,/^```$/p' | sed '/^```\(json\)\?$/d;/^```$/d')
  if [[ -z "${clean_response}" ]]; then
    clean_response=$(echo "${response}" | sed '/^```\(json\)\?$/d;/^```$/d')
  fi

  local queries_json
  queries_json=$(echo "${clean_response}" | jq -c '.' 2>/dev/null)
  if [[ -z "${queries_json}" ]] || ! echo "${queries_json}" | jq '.[0]' > /dev/null 2>&1; then
    # Try extracting array portion
    local json_part
    json_part=$(echo "${clean_response}" | sed -n '/[[:space:]]*\[/,/[[:space:]]*\]/p')
    queries_json=$(echo "${json_part}" | jq -c '.' 2>/dev/null)
  fi

  if [[ -n "${queries_json}" ]] && echo "${queries_json}" | jq '.[0]' > /dev/null 2>&1; then
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
  local all_topics=""
  local i=0
  while [[ ${i} -lt ${active_count} ]]; do
    local chat session_key
    chat=$(echo "${active_chats}" | jq -c ".[${i}]")
    session_key=$(echo "${chat}" | jq -r '.session_key // ""')

    # Get chat profile for preferred_topics hint
    local profile
    profile=$(echo "${chat_profiles_json}" | jq -c --arg sk "${session_key}" '.[$sk] // null' 2>/dev/null)
    if [[ -z "${profile}" || "${profile}" == "null" ]]; then
      profile="${default_profile_json}"
    fi
    local profile_name profile_topics
    profile_name=$(echo "${profile}" | jq -r '.name // "不明"')
    profile_topics=$(echo "${profile}" | jq -r '.preferred_topics // [] | join(", ")')

    if [[ -n "${profile_topics}" ]]; then
      all_topics="${all_topics}, ${profile_topics}"
    fi

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

# ---- Trending Content Discovery ----

# Search for trending content using Brave Search API
# Now accepts optional dynamic_queries parameter
_discover_trending_content() {
  local trigger_json="$1"
  local dynamic_queries="${2:-}"

  local interests
  interests=$(echo "${trigger_json}" | jq -r '.fallback_categories // .interest_categories // [] | join(", ")')
  if [[ -z "${interests}" ]]; then
    interests="AI, テクノロジー, 投資, 暗号資産, ゲーム, プログラミング"
  fi

  local brave_key="${BRAVE_API_KEY:-}"
  if [[ -z "${brave_key}" ]]; then
    log "WARN: Proactive engine: BRAVE_API_KEY not set, using LLM knowledge only"
    _discover_trending_content_llm_only "${interests}"
    return
  fi

  local today
  today=$(_get_jst_date)

  # Build search queries: dynamic queries from chat context + fallback fixed queries
  local search_results=""
  local fallback_queries=(
    "最新ニュース AI テクノロジー ${today}"
    "crypto blockchain news today"
    "テック ニュース 投資 トレンド"
    "gaming industry news latest"
    "programming developer news"
    "trending topics site:x.com ${today}"
    "話題 トレンド site:x.com OR site:twitter.com"
  )

  local queries=()
  if [[ -n "${dynamic_queries}" ]] && echo "${dynamic_queries}" | jq '.[0]' > /dev/null 2>&1; then
    # Use dynamic queries (up to 5)
    local dq_count
    dq_count=$(echo "${dynamic_queries}" | jq 'length')
    local dq_max=$(( dq_count > 5 ? 5 : dq_count ))
    local dqi=0
    while [[ ${dqi} -lt ${dq_max} ]]; do
      local dq
      dq=$(echo "${dynamic_queries}" | jq -r ".[${dqi}]")
      queries+=("${dq}")
      dqi=$((dqi + 1))
    done
    log "Proactive engine: Using ${#queries[@]} dynamic queries from chat context"

    # Add 2 random fixed queries to avoid echo chamber
    local fb_count=${#fallback_queries[@]}
    local fb_idx1=$(( RANDOM % fb_count ))
    local fb_idx2=$(( (fb_idx1 + 1 + RANDOM % (fb_count - 1)) % fb_count ))
    queries+=("${fallback_queries[${fb_idx1}]}")
    queries+=("${fallback_queries[${fb_idx2}]}")
    log "Proactive engine: Added 2 random fallback queries for diversity"
  else
    # No dynamic queries available, use all fixed queries
    log "Proactive engine: No dynamic queries, using fixed queries"
    queries=("${fallback_queries[@]}")
  fi

  for query in "${queries[@]}"; do
    local encoded_query
    encoded_query=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${query}'))" 2>/dev/null || echo "${query}")

    local response
    response=$(curl -s --max-time 10 \
      -H "Accept: application/json" \
      -H "Accept-Language: ja,en" \
      -H "X-Subscription-Token: ${brave_key}" \
      "https://api.search.brave.com/res/v1/web/search?q=${encoded_query}&count=8&freshness=pd" 2>/dev/null)

    if [[ -n "${response}" ]] && echo "${response}" | jq '.web.results' > /dev/null 2>&1; then
      local results
      results=$(echo "${response}" | jq '[.web.results[]? | {title: .title, url: .url, description: .description, age: .age}]' 2>/dev/null)
      if [[ -n "${results}" && "${results}" != "[]" ]]; then
        if [[ -z "${search_results}" ]]; then
          search_results="${results}"
        else
          search_results=$(echo "${search_results}" "${results}" | jq -s 'add')
        fi
      fi
    fi
    # Brief delay to avoid rate limiting
    sleep 1
  done

  if [[ -z "${search_results}" || "${search_results}" == "[]" ]]; then
    log "WARN: Proactive engine: Brave Search returned no results, falling back to LLM"
    _discover_trending_content_llm_only "${interests}"
    return
  fi

  # Use LLM to curate and select the best items
  local prompt="あなたはニュースキュレーターです。以下の検索結果から、Masaru Tamegaiが最も興味を持ちそうな記事を8〜10件選んでください。

## Masaruの興味分野
${interests}

## 検索結果
${search_results}

## 選定基準
- 上記の興味分野に関連するもの
- 新鮮で話題性のあるもの
- X（旧Twitter）で話題のトピックも含めること
- 暴力的・過激な政治発言・個人攻撃・センセーショナルなゴシップは除外
- 実用的・教育的・インスピレーションを与える内容を優先
- 重複する話題は最も情報量の多いものを1つだけ選択

以下のJSON配列で回答してください（コードフェンスなし、JSONのみ）：
[
  {
    \"title\": \"記事タイトル\",
    \"url\": \"記事URL\",
    \"summary\": \"2〜3文の要約\",
    \"category\": \"該当カテゴリ（AI/テクノロジー/投資/暗号資産/ゲーム/プログラミング/Xトレンド）\",
    \"interest_score\": 8
  }
]"

  local response
  response=$(invoke_claude "${prompt}")

  # Strip markdown code fences
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

  # Validate JSON
  if echo "${response}" | jq '.[0]' > /dev/null 2>&1; then
    echo "${response}"
  else
    local json_part
    json_part=$(echo "${response}" | sed -n '/^[[:space:]]*\[/,/^[[:space:]]*\]/p')
    if [[ -n "${json_part}" ]] && echo "${json_part}" | jq '.[0]' > /dev/null 2>&1; then
      echo "${json_part}"
    else
      log "WARN: Proactive engine: Failed to parse curated content, falling back to LLM"
      _discover_trending_content_llm_only "${interests}"
    fi
  fi
}

# Fallback: generate trending content using LLM knowledge only
_discover_trending_content_llm_only() {
  local interests="$1"
  local today
  today=$(_get_jst_date)

  local prompt="あなたはニュースキュレーターです。${today}の最新トレンドとして、以下の興味分野から8〜10件のニューストピックを紹介してください。X（旧Twitter）で話題のトピックも含めてください。

## 興味分野
${interests}

## 条件
- あなたの知識に基づく最新の話題やトレンドを紹介
- Xで話題のトピックも含めること
- 暴力的・過激な政治発言・個人攻撃は除外
- 実用的・教育的な内容を優先
- URLは含めず、トピックの紹介に集中

以下のJSON配列で回答してください（コードフェンスなし、JSONのみ）：
[
  {
    \"title\": \"トピックタイトル\",
    \"url\": null,
    \"summary\": \"2〜3文の要約\",
    \"category\": \"該当カテゴリ\",
    \"interest_score\": 8
  }
]"

  local response
  response=$(invoke_claude "${prompt}")
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

  if echo "${response}" | jq '.[0]' > /dev/null 2>&1; then
    echo "${response}"
  else
    local json_part
    json_part=$(echo "${response}" | sed -n '/^[[:space:]]*\[/,/^[[:space:]]*\]/p')
    if [[ -n "${json_part}" ]] && echo "${json_part}" | jq '.[0]' > /dev/null 2>&1; then
      echo "${json_part}"
    else
      log "WARN: Proactive engine: LLM fallback also failed to produce valid JSON"
      echo '[{"title":"コンテンツ生成エラー","url":null,"summary":"トレンドコンテンツの生成に失敗しました","category":"info","interest_score":0}]'
    fi
  fi
}

# ---- Destination-Specific Content Formatting ----

# Format discovered content for a specific destination
# Now accepts chat_profile info for per-chat personality customization
_format_content_for_destination() {
  local content_json="$1"
  local dest_json="$2"
  local chat_profile_json="${3:-}"

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

  # Base personality: OpenClaw (Masaru) persona
  local personality_base="あなたは「Masaruくん」というキャラクターとして情報を配信する。以下のパーソナリティルールを厳守すること：
- 絵文字は使わない（絶対に使用禁止）
- 標準語ベース（約70%）に関西弁（約30%）を混ぜる
- 関西弁の語尾（〜やな、〜やで等）は1メッセージに1-2回まで。連続使用禁止
- 強い関西弁表現（めっちゃ、ほんま、あかん、ええやん、しゃーない）は1メッセージに1回まで
- 標準語の語尾を基本にする：〜だな、〜だわ、〜なんよな、〜だけど、〜だろ
- 友達に話しかけるようなカジュアルな口調。敬語は使わない
- 短めのメッセージを心がける。長い説明は避ける"

  local prompt="${personality_base}

## 配信先
- チャット名: ${profile_name:-${dest_type}}
- 対象: ${profile_audience:-一般}
- トーン指示: ${profile_tone:-カジュアル}

## 配信するニュース・トレンド情報
${content_json}

## フォーマット指示"

  case "${dest_type}" in
    discord)
      prompt="${prompt}
Discord向けにフォーマットしてください：
- 各ニュースは **太字タイトル** で始め、リンクがあれば含める
- 技術的な詳細も含めてOK（対象に合わせて調整）
- 全体を1つのメッセージにまとめる（2000文字以内）
- 自然な書き出しから始める（「おつ」「よう」等カジュアルに）

プレーンテキストで回答してください（JSONではなく、そのままDiscordに投稿できる形式）："
      ;;
    line)
      prompt="${prompt}
LINE向けにフォーマットしてください：
- 簡潔でカジュアルな文体
- 対象に合わせて技術用語を調整（家族向けなら分かりやすく言い換え）
- 全体を1つのメッセージにまとめる（1000文字以内）
- 自然な書き出しから始める
- URLは省略可（タイトルと要約で十分）

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

  local category now_ts trigger_type
  category=$(echo "${trigger_json}" | jq -r '.category // "info"')
  trigger_type=$(echo "${trigger_json}" | jq -r '.type // "time"')
  now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  jq -n \
    --arg id "${suggestion_id}" \
    --arg cat "${category}" \
    --arg trigger_name "${trigger_name}" \
    --arg trigger_type "${trigger_type}" \
    --arg detected_at "${now_ts}" \
    --arg created_at "${now_ts}" \
    --argjson content "${content_json}" \
    '{
      id: $id,
      category: $cat,
      title: $content.title,
      trigger: {
        type: $trigger_type,
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

# Send message to Discord channel via Bot API
_deliver_discord_bot() {
  local channel_id="$1"
  local message_text="$2"

  local bot_token="${DISCORD_BOT_TOKEN:-}"
  if [[ -z "${bot_token}" ]]; then
    log "WARN: Proactive engine: DISCORD_BOT_TOKEN not set, skipping Discord delivery"
    return 1
  fi

  # Truncate to Discord's 2000 char limit
  if [[ ${#message_text} -gt 2000 ]]; then
    message_text="${message_text:0:1997}..."
  fi

  local payload
  payload=$(jq -n --arg content "${message_text}" '{content: $content}')

  local http_code response_body
  response_body=$(mktemp)
  http_code=$(curl -s -o "${response_body}" -w "%{http_code}" \
    -H "Authorization: Bot ${bot_token}" \
    -H "Content-Type: application/json" \
    -d "${payload}" \
    "https://discord.com/api/v10/channels/${channel_id}/messages" 2>/dev/null) || {
    log "ERROR: Proactive engine: Discord Bot API request failed"
    rm -f "${response_body}"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Proactive engine: Discord message sent to channel ${channel_id} (HTTP ${http_code})"
    rm -f "${response_body}"
    return 0
  else
    log "ERROR: Proactive engine: Discord Bot API returned HTTP ${http_code}: $(cat "${response_body}")"
    rm -f "${response_body}"
    return 1
  fi
}

# Send message via LINE Push API
_deliver_line() {
  local target_id="$1"
  local message_text="$2"

  local line_token="${LINE_CHANNEL_ACCESS_TOKEN:-}"
  if [[ -z "${line_token}" ]]; then
    log "WARN: Proactive engine: LINE_CHANNEL_ACCESS_TOKEN not set, skipping LINE delivery"
    return 1
  fi

  # LINE message limit is 5000 chars
  if [[ ${#message_text} -gt 5000 ]]; then
    message_text="${message_text:0:4997}..."
  fi

  local payload
  payload=$(jq -n \
    --arg to "${target_id}" \
    --arg text "${message_text}" \
    '{
      to: $to,
      messages: [{
        type: "text",
        text: $text
      }]
    }')

  local http_code response_body
  response_body=$(mktemp)
  http_code=$(curl -s -o "${response_body}" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${line_token}" \
    -d "${payload}" \
    "https://api.line.me/v2/bot/message/push" 2>/dev/null) || {
    log "ERROR: Proactive engine: LINE Push API request failed"
    rm -f "${response_body}"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Proactive engine: LINE message sent to ${target_id} (HTTP ${http_code})"
    rm -f "${response_body}"
    return 0
  else
    log "ERROR: Proactive engine: LINE Push API returned HTTP ${http_code}: $(cat "${response_body}")"
    rm -f "${response_body}"
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

  # Get last 40 lines and extract user/assistant text content using jq
  # Execute jq inside the container to avoid pipe buffering issues with large JSON lines
  # Increased from 3 to 5 messages for better topic coverage
  local context
  context=$(docker exec soul-openclaw sh -c "tail -40 '${session_file}' | jq -r 'select(.type == \"message\") | select(.message.role == \"user\" or .message.role == \"assistant\") | .message.content | if type == \"array\" then map(select(.type == \"text\") | .text) | join(\" \") elif type == \"string\" then . else empty end' 2>/dev/null | tail -5 | cut -c1-200 | tr '\n' ' '" 2>/dev/null \
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
  default_profile_pre=$(echo "${trigger_json}" | jq -c '.default_profile // {"name":"一般","audience":"一般","preferred_topics":["AI","テクノロジー"],"tone":"カジュアル"}')

  local all_chat_contexts
  all_chat_contexts=$(_collect_all_chat_contexts "${activity_window_pre}" "${chat_profiles_pre}" "${default_profile_pre}")

  local dynamic_queries=""
  if [[ -n "${all_chat_contexts}" ]]; then
    # Gather preferred_topics as hints
    local topics_hint
    topics_hint=$(echo "${chat_profiles_pre}" | jq -r '[.[] | .preferred_topics // [] | .[]] | unique | join(", ")' 2>/dev/null)
    dynamic_queries=$(_generate_dynamic_queries "${all_chat_contexts}" "${topics_hint:-}")
  else
    log "Proactive engine: No chat context available, will use fixed queries only"
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
  default_profile=$(echo "${trigger_json}" | jq -c '.default_profile // {"name":"一般","audience":"一般","preferred_topics":["AI","テクノロジー"],"tone":"カジュアル"}')

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
    local dest session_key profile_name profile_audience profile_topics profile_tone
    dest=$(echo "${delivery_targets}" | jq -c ".[${i}]")
    session_key=$(echo "${dest}" | jq -r '.session_key // ""')
    profile_name=$(echo "${dest}" | jq -r '.chat_profile.name // "不明"')
    profile_audience=$(echo "${dest}" | jq -r '.chat_profile.audience // "一般"')
    profile_topics=$(echo "${dest}" | jq -r '.chat_profile.preferred_topics // [] | join(", ")')
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
- 好みのトピック: ${profile_topics}
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

  local assignment_prompt="あなたはニュース配信の最適化エンジンです。以下の候補記事リストから、各チャットに最適な3〜5件を選んでください。
チャットの属性（対象、好みのトピック、トーン、最近の会話）を考慮して、そのチャットで最も盛り上がりそうな記事を選んでください。

## 候補記事
${numbered_articles}

## チャット一覧
${chat_descriptions}

## ルール
- 各チャットに3〜5件の記事インデックス（数値）を割り当てる
- チャットごとに異なる記事セットになるよう最適化する（最近の会話コンテキストを最重視）
- 好みのトピックに合わない記事は割り当てない
- 全チャットで同じ記事セットにしないこと
- 最近の会話で話題になっているテーマに関連する記事を優先する

## 出力形式（厳守）
思考過程や説明文は一切出力しないこと。以下のJSON形式のみ出力すること。
キーはチャット番号（文字列）、値は記事インデックス（数値）の配列。

\`\`\`json
{
  \"assignments\": {
    \"0\": [0, 2, 4],
    \"1\": [1, 3, 5]
  }
}
\`\`\`"

  local assignment_response
  assignment_response=$(invoke_claude "${assignment_prompt}")

  if [[ -z "${assignment_response}" ]]; then
    log "ERROR: Proactive engine: invoke_claude returned empty response for article assignment"
  else
    log "Proactive engine: Assignment response length: ${#assignment_response}"
  fi

  # Robust JSON extraction: strip code fences, thinking text, etc.
  # Step 1: Extract ```json ... ``` block if present
  local clean_response
  clean_response=$(echo "${assignment_response}" | sed -n '/^```\(json\)\?$/,/^```$/p' | sed '/^```\(json\)\?$/d;/^```$/d')
  if [[ -z "${clean_response}" ]]; then
    # Step 2: Strip any code fences and try raw content
    clean_response=$(echo "${assignment_response}" | sed '/^```\(json\)\?$/d;/^```$/d')
  fi

  # Parse assignment JSON with multiple fallback strategies
  local assignments
  # Strategy 1: Direct parse
  assignments=$(echo "${clean_response}" | jq '.assignments // empty' 2>/dev/null)
  if [[ -z "${assignments}" || "${assignments}" == "null" ]]; then
    # Strategy 2: Extract JSON object block and parse
    local json_part
    json_part=$(echo "${clean_response}" | sed -n '/[[:space:]]*{/,/[[:space:]]*}/p' | head -50)
    assignments=$(echo "${json_part}" | jq '.assignments // empty' 2>/dev/null)
  fi
  if [[ -z "${assignments}" || "${assignments}" == "null" ]]; then
    # Strategy 3: Handle string keys with numeric values (e.g., "0": [...])
    assignments=$(echo "${clean_response}" | jq 'if .assignments then .assignments elif keys[0] | test("^[0-9]+$") then . else {} end' 2>/dev/null)
  fi
  if [[ -z "${assignments}" || "${assignments}" == "null" || "${assignments}" == "{}" ]]; then
    log "WARN: Proactive engine: Failed to parse article assignments. Raw response (first 500 chars): ${assignment_response:0:500}"
  else
    log "Proactive engine: Successfully parsed assignments for $(echo "${assignments}" | jq 'keys | length') chats"
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
        # Fallback: use all articles if assignment failed
        log "WARN: Proactive engine: No assignment for chat ${i} (session: ${session_key}), falling back to all articles. Assignment keys available: $(echo "${assignments}" | jq -c 'keys' 2>/dev/null)"
        assigned_indices=$(echo "${content_json}" | jq '[range(length)]')
      fi

      # Build per-chat content from assigned indices
      local chat_content
      chat_content=$(echo "${content_json}" | jq -c --argjson indices "${assigned_indices}" '[. as $all | $indices[] | $all[.] // empty]')

      log "Proactive engine: Formatting content for ${dest_type} (target: ${target_id}, articles: $(echo "${chat_content}" | jq 'length'))..."
      formatted_content=$(_format_content_for_destination "${chat_content}" "${dest}" "${chat_profile}")

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
      '. + [{destination: $type, target_id: $tid, session_key: $sk, status: $status, error: $error, content_length: ($chars | tonumber)}]')

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
    }')

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
      next_scheduled_at: null,
      updated_at: $delivered_at
    }' > "${tmp}" && mv "${tmp}" "${state_file}"

  log "Proactive engine: Broadcast ${broadcast_id} completed (${dest_count} destinations)"
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

  log "Proactive engine: Force trigger detected: ${trigger_type}"
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

  # Remove the file; if rm fails due to permissions (sticky bit + different owner),
  # try to truncate it or use docker exec to delete from the owning container
  if ! rm -f "${request_file}" 2>/dev/null; then
    if ! : > "${request_file}" 2>/dev/null; then
      docker exec soul-openclaw rm -f /suggestions/broadcast_request.json 2>/dev/null || true
    fi
  fi

  # Return the request JSON
  echo "${request_json}"
  return 0
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

  # Discover content
  local content_json
  content_json=$(_discover_trending_content "${trigger_json}")
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

  # Look up chat profile from request session_key or use default
  local session_key chat_profile
  session_key=$(echo "${request_json}" | jq -r '.chat.session_key // ""')
  local chat_profiles default_profile
  chat_profiles=$(echo "${trigger_json}" | jq -c '.chat_profiles // {}')
  default_profile=$(echo "${trigger_json}" | jq -c '.default_profile // {"name":"一般","audience":"一般","preferred_topics":["AI","テクノロジー"],"tone":"カジュアル"}')
  chat_profile=$(echo "${chat_profiles}" | jq -c --arg sk "${session_key}" '.[$sk] // null')
  if [[ "${chat_profile}" == "null" || -z "${chat_profile}" ]]; then
    chat_profile="${default_profile}"
  fi

  # Build single-target delivery
  local dest
  dest=$(echo "${dest_template}" | jq -c --arg tid "${target_id}" --arg t "${platform}" '. + {type: $t, target_id: $tid}')

  log "Proactive engine: Formatting content for ${platform}..."
  local formatted_content
  formatted_content=$(_format_content_for_destination "${content_json}" "${dest}" "${chat_profile}")

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
    --argjson content "${content_json}" --argjson deliveries "${delivery_results}" \
    '{id: $id, trigger: $trigger, mode: $mode, content: $content, deliveries: $deliveries, created_at: $created}')

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
    '{status: $status, last_broadcast_id: $last_id, last_delivered_at: $delivered_at, last_deliveries: $deliveries, next_scheduled_at: null, updated_at: $delivered_at}' \
    > "${tmp}" && mv "${tmp}" "${state_file}"

  log "Proactive engine: On-demand broadcast ${broadcast_id} completed"
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
        log "Proactive engine: Processing force trigger: ${force_trigger}"
        local trigger_json
        trigger_json=$(jq ".triggers.\"${force_trigger}\"" "${PROACTIVE_CONFIG}" 2>/dev/null)
        if [[ -n "${trigger_json}" && "${trigger_json}" != "null" ]]; then
          local trigger_type
          trigger_type=$(echo "${trigger_json}" | jq -r '.type // "unknown"')
          if [[ "${trigger_type}" == "random_window" ]]; then
            _execute_trending_broadcast "${force_trigger}" "${trigger_json}"
          fi
        fi
      fi
      # Also check for on-demand broadcast request during throttle
      local broadcast_request
      broadcast_request=$(_check_broadcast_request)
      if [[ -n "${broadcast_request}" ]]; then
        local category="info"
        if _check_rate_limit "${category}"; then
          local tn
          tn=$(jq '.triggers.trending_news' "${PROACTIVE_CONFIG}" 2>/dev/null)
          if [[ -n "${tn}" && "${tn}" != "null" ]]; then
            _execute_ondemand_broadcast "${broadcast_request}" "${tn}"
            _increment_daily_count "${category}"
          fi
        else
          log "Proactive engine: On-demand broadcast rate-limited"
        fi
      fi
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

  # Check for force trigger
  local force_trigger
  force_trigger=$(_check_force_trigger)
  if [[ -n "${force_trigger}" ]]; then
    log "Proactive engine: Processing force trigger: ${force_trigger}"
    local trigger_json
    trigger_json=$(jq ".triggers.\"${force_trigger}\"" "${PROACTIVE_CONFIG}" 2>/dev/null)
    if [[ -n "${trigger_json}" && "${trigger_json}" != "null" ]]; then
      local trigger_type
      trigger_type=$(echo "${trigger_json}" | jq -r '.type // "unknown"')
      if [[ "${trigger_type}" == "random_window" ]]; then
        _execute_trending_broadcast "${force_trigger}" "${trigger_json}"
        _increment_daily_count "info"
        _mark_trigger_fired "${force_trigger}"
        return 0
      fi
    fi
  fi

  # Check for on-demand broadcast request from OpenClaw
  local broadcast_request
  broadcast_request=$(_check_broadcast_request)
  if [[ -n "${broadcast_request}" ]]; then
    local category="info"
    if _check_rate_limit "${category}"; then
      local trending_trigger
      trending_trigger=$(jq '.triggers.trending_news' "${PROACTIVE_CONFIG}" 2>/dev/null)
      if [[ -n "${trending_trigger}" && "${trending_trigger}" != "null" ]]; then
        _execute_ondemand_broadcast "${broadcast_request}" "${trending_trigger}"
        _increment_daily_count "${category}"
        return 0
      fi
    else
      log "Proactive engine: On-demand broadcast rate-limited"
    fi
  fi

  # Iterate over configured triggers
  local trigger_names
  trigger_names=$(jq -r '.triggers | keys[]' "${PROACTIVE_CONFIG}" 2>/dev/null)

  for trigger_name in ${trigger_names}; do
    local trigger_json
    trigger_json=$(jq ".triggers.\"${trigger_name}\"" "${PROACTIVE_CONFIG}")

    local trigger_type
    trigger_type=$(echo "${trigger_json}" | jq -r '.type // "unknown"')

    case "${trigger_type}" in
      time)
        if _should_fire_time_trigger "${trigger_name}" "${trigger_json}"; then
          local category
          category=$(echo "${trigger_json}" | jq -r '.category // "info"')

          if ! _check_rate_limit "${category}"; then
            log "Proactive engine: Trigger ${trigger_name} rate-limited, skipping"
            _mark_trigger_fired "${trigger_name}"
            continue
          fi

          log "Proactive engine: Trigger fired: ${trigger_name}"
          set_activity "generating_suggestion" "\"trigger\":\"${trigger_name}\","

          local content_json
          content_json=$(_generate_suggestion_content "${trigger_name}" "${trigger_json}")

          local suggestion_id
          suggestion_id=$(_generate_suggestion_id)
          local suggestion_record
          suggestion_record=$(_build_suggestion_record "${suggestion_id}" "${trigger_name}" "${trigger_json}" "${content_json}")

          _deliver_suggestion "${suggestion_record}"
          _increment_daily_count "${category}"
          _mark_trigger_fired "${trigger_name}"

          set_activity "idle"
        fi
        ;;
      random_window)
        if _should_fire_random_window_trigger "${trigger_name}" "${trigger_json}"; then
          local category
          category=$(echo "${trigger_json}" | jq -r '.category // "info"')

          if ! _check_rate_limit "${category}"; then
            log "Proactive engine: Trigger ${trigger_name} rate-limited, skipping"
            _mark_trigger_fired "${trigger_name}"
            continue
          fi

          log "Proactive engine: Random window trigger fired: ${trigger_name}"
          _execute_trending_broadcast "${trigger_name}" "${trigger_json}"
          _increment_daily_count "${category}"
          _mark_trigger_fired "${trigger_name}"
        fi
        ;;
      *)
        continue
        ;;
    esac
  done

  return 0
}
