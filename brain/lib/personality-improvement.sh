#!/usr/bin/env bash
# personality-improvement.sh - Personality improvement engine for Soul System
# Triceratops-only: generates questions, processes answers, updates personality files
#
# Flow:
#   1. Scheduler/manual trigger creates /shared/personality_improvement/trigger.json
#   2. Brain analyzes SOUL.md/AGENTS.md, generates 5 questions
#   3. Questions sent to Masaru via LINE (through bot_commands)
#   4. Answers collected in /shared/personality_improvement/answers_{ts}.json
#   5. Brain processes answers and updates personality files
#   6. OpenClaw container rebuilt with updated personality

PI_DIR="${SHARED_DIR}/personality_improvement"
PI_HISTORY_DIR="${PI_DIR}/history"
PI_QUESTION_HISTORY="${PI_DIR}/question_history.jsonl"
PI_OPENCLAW_CONTAINER="soul-openclaw"
PI_OWNER_LINE_ID="Ua78c97ab5f7b6090fc17656bc12f5c99"

# Security marker comments in SOUL.md (sections to never modify)
PI_SECURITY_START_MARKER="## セキュリティ境界（不可侵）"
PI_SECURITY_END_MARKER="## コアアイデンティティ"
PI_SPEECH_BALANCE_MARKER="標準語ベースが約7割、関西弁語尾入りが約3割"

# AGENTS.md security markers
PI_AGENTS_SECURITY_START="## セキュリティルール（不可侵）"
PI_AGENTS_SECURITY_END_MARKER="EOF_AGENTS"  # until end of file

# ============================================================
# Main check function - called from daemon loop
# ============================================================

check_personality_improvement() {
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  local trigger_file="${PI_DIR}/trigger.json"
  [[ -f "${trigger_file}" ]] || return 0

  local status
  status=$(jq -r '.status // ""' "${trigger_file}" 2>/dev/null)

  case "${status}" in
    pending)
      _pi_generate_questions
      ;;
    questions_sent)
      _pi_check_for_answers
      ;;
    answers_received)
      _pi_process_answers
      ;;
    *)
      # completed, failed, or unknown - skip
      return 0
      ;;
  esac
}

# ============================================================
# Step 1: Generate personality analysis questions
# ============================================================

_pi_generate_questions() {
  log "Personality improvement: Starting question generation"
  set_activity "personality_improvement" "\"task\":\"generating_questions\","

  mkdir -p "${PI_DIR}" "${PI_HISTORY_DIR}"

  # Read current personality files
  local soul_md agents_md
  soul_md=$(cat /soul/worker/openclaw/personality/SOUL.md 2>/dev/null || echo "")
  agents_md=$(cat /soul/worker/openclaw/personality/AGENTS.md 2>/dev/null || echo "")

  if [[ -z "${soul_md}" ]]; then
    log "ERROR: Personality improvement: SOUL.md not found"
    _pi_update_trigger "failed" "SOUL.md not found"
    set_activity "idle"
    return 1
  fi

  # Read question history to avoid duplicates
  local past_questions=""
  if [[ -f "${PI_QUESTION_HISTORY}" ]]; then
    past_questions=$(tail -50 "${PI_QUESTION_HISTORY}" 2>/dev/null || echo "")
  fi

  # Generate questions via Claude
  local prompt
  prompt="あなたはSoul Systemのパーソナリティ分析エンジンです。
Masaru Tamegaiのバディボット（Masaru-kun）のパーソナリティファイルを分析し、
より「Masaruらしさ」を再現するために不足している情報を特定してください。

## 現在のSOUL.md（人格定義）:
${soul_md}

## 現在のAGENTS.md（エージェント設定 - 性格・知識関連部分のみ参照）:
${agents_md}

## 過去に聞いた質問（重複を避けること）:
${past_questions}

## タスク:
1. 現在のパーソナリティ定義を分析し、不足している情報領域を特定する
2. Masaruに対して5つの質問を生成する

## 質問生成ルール:
- Masaruの性格、好み、価値観、行動パターンをより正確に再現するための質問であること
- 過去に聞いた質問と重複しないこと
- カジュアルで答えやすい形式にすること（Masaruは友人に聞かれる形式が好み）
- **セキュリティ関連情報（パスワード、トークン、API鍵、サーバー構成、IPアドレス等）を引き出す質問は絶対に生成しない**
- **個人情報（住所、電話番号、マイナンバー等）を引き出す質問は生成しない**
- 答えが一言で済むものと、少し詳しく答えるものをバランスよく混ぜる

## 出力フォーマット（JSON）:
{
  \"analysis\": \"現在のパーソナリティ定義の分析（不足領域の説明）\",
  \"questions\": [
    {\"id\": 1, \"category\": \"カテゴリ名\", \"question\": \"質問文\", \"purpose\": \"この質問の目的\"},
    {\"id\": 2, \"category\": \"カテゴリ名\", \"question\": \"質問文\", \"purpose\": \"この質問の目的\"},
    {\"id\": 3, \"category\": \"カテゴリ名\", \"question\": \"質問文\", \"purpose\": \"この質問の目的\"},
    {\"id\": 4, \"category\": \"カテゴリ名\", \"question\": \"質問文\", \"purpose\": \"この質問の目的\"},
    {\"id\": 5, \"category\": \"カテゴリ名\", \"question\": \"質問文\", \"purpose\": \"この質問の目的\"}
  ]
}

JSONのみ出力してください。余計な説明は不要です。"

  local result
  result=$(invoke_claude "${prompt}")

  if [[ $? -ne 0 || -z "${result}" ]]; then
    log "ERROR: Personality improvement: Claude invocation failed"
    _pi_update_trigger "failed" "Question generation failed"
    set_activity "idle"
    return 1
  fi

  # Extract JSON from result (handle markdown code blocks)
  local json_result
  # Try: ```json ... ``` block first (most common Claude response format)
  json_result=$(echo "${result}" | sed -n '/```json/,/```/{/```/d;p}')
  if [[ -z "${json_result}" ]] || ! echo "${json_result}" | jq empty 2>/dev/null; then
    # Fallback: extract from first { to last }
    json_result=$(echo "${result}" | awk '/^\{/{found=1} found{buf=buf $0 "\n"} /^\}/{if(found){printf "%s",buf; exit}}')
  fi
  if [[ -z "${json_result}" ]]; then
    json_result="${result}"
  fi

  # Validate JSON
  if ! echo "${json_result}" | jq -e '.questions | length == 5' >/dev/null 2>&1; then
    log "ERROR: Personality improvement: Invalid question JSON"
    log "DEBUG: Result was: ${result:0:500}"
    _pi_update_trigger "failed" "Invalid question format"
    set_activity "idle"
    return 1
  fi

  local timestamp
  timestamp=$(date -u +%Y%m%d_%H%M%S)

  # Save questions to pending file
  local pending_file="${PI_DIR}/pending_${timestamp}.json"
  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg status "questions_generated" \
    --argjson questions "${json_result}" \
    '{
      timestamp: $ts,
      status: $status,
      analysis: $questions.analysis,
      questions: $questions.questions
    }' > "${tmp}" && mv "${tmp}" "${pending_file}"

  # Send questions directly via LINE Push API (same pattern as broadcast delivery)
  local message
  message="パーソナリティ改善の質問です！
おれのことをもっと正確に再現するために、以下の質問に答えてくれ。番号付きで回答してくれると助かる（例: 1. 回答内容）

"
  local i=0
  while true; do
    local q
    q=$(echo "${json_result}" | jq -r ".questions[${i}].question // empty" 2>/dev/null)
    [[ -z "${q}" ]] && break
    local qnum=$((i + 1))
    message="${message}${qnum}. ${q}
"
    ((i++))
  done

  message="${message}
※回答は番号付きでお願いします
※全問じゃなくても答えられる分だけでOK
※48時間以内に回答してください"

  _pi_send_line_message "${message}"

  # Record questions in history
  echo "${json_result}" | jq -c '.questions[]' >> "${PI_QUESTION_HISTORY}" 2>/dev/null

  # Update trigger status
  _pi_update_trigger "questions_sent" "" "${timestamp}"

  log "Personality improvement: 5 questions generated and sent via LINE (pending_${timestamp}.json)"
  set_activity "idle"
}

# ============================================================
# Step 2: Check for answers from Masaru
# ============================================================

_pi_check_for_answers() {
  # First check if an answer file was already prepared
  for answer_file in "${PI_DIR}"/answers_*.json; do
    [[ -f "${answer_file}" ]] || continue

    local answer_status
    answer_status=$(jq -r '.status // ""' "${answer_file}" 2>/dev/null)
    [[ "${answer_status}" == "collected" ]] || continue

    log "Personality improvement: Answers found in ${answer_file}"
    _pi_update_trigger "answers_received" "" "" "$(basename "${answer_file}")"
    return 0
  done

  # Try to extract answers from OpenClaw session history
  local trigger_file="${PI_DIR}/trigger.json"
  local sent_at
  sent_at=$(jq -r '.questions_sent_at // ""' "${trigger_file}" 2>/dev/null)
  [[ -n "${sent_at}" ]] || return 0

  local sent_epoch now_epoch
  sent_epoch=$(date -d "${sent_at}" +%s 2>/dev/null || echo 0)
  now_epoch=$(date +%s)

  # Check timeout (48 hours)
  if (( now_epoch - sent_epoch > 172800 )); then
    log "Personality improvement: Answer timeout (48h). Resetting trigger."
    _pi_update_trigger "completed" "Timeout - no answers received within 48h"
    return 0
  fi

  # Only check every 5 minutes to avoid excessive docker exec calls
  local last_answer_check_file="${PI_DIR}/.last_answer_check"
  if [[ -f "${last_answer_check_file}" ]]; then
    local last_check
    last_check=$(cat "${last_answer_check_file}" 2>/dev/null || echo 0)
    if (( now_epoch - last_check < 300 )); then
      return 0
    fi
  fi
  echo "${now_epoch}" > "${last_answer_check_file}"

  # Find the LINE DM session file
  local session_file
  session_file=$(docker exec soul-openclaw cat /home/openclaw/.openclaw/agents/main/sessions/sessions.json 2>/dev/null | \
    jq -r 'to_entries[] | select(.key == "agent:main:main") | .value.sessionFile // empty' 2>/dev/null)

  [[ -n "${session_file}" ]] || return 0

  # Get user messages from the LINE DM session after the questions were sent
  local user_messages
  user_messages=$(docker exec soul-openclaw cat "${session_file}" 2>/dev/null | \
    jq -c "select(.type == \"message\" and .message.role == \"user\" and .timestamp > \"${sent_at}\") | {timestamp: .timestamp, text: (.message.content | if type == \"array\" then (map(select(.type == \"text\") | .text) | join(\" \")) elif type == \"string\" then . else \"\" end)}" 2>/dev/null)

  [[ -n "${user_messages}" ]] || return 0

  # Look for messages containing numbered answers (1. xxx, 2. xxx, etc.)
  local answer_text=""
  while IFS= read -r msg; do
    local text
    text=$(echo "${msg}" | jq -r '.text // ""' 2>/dev/null)
    # Check if message contains numbered answers
    if echo "${text}" | grep -qE "^[1-5][.．、)）]|[1-5][.．、)）]" 2>/dev/null; then
      answer_text="${answer_text}${text}
"
    fi
  done <<< "${user_messages}"

  [[ -n "${answer_text}" ]] || return 0

  # Check that we have at least 1 numbered answer
  local answer_count
  answer_count=$(echo "${answer_text}" | grep -cE "^[1-5][.．、)）]|[[:space:]][1-5][.．、)）]" 2>/dev/null || echo 0)

  if [[ ${answer_count} -lt 1 ]]; then
    return 0
  fi

  log "Personality improvement: Found ${answer_count} answer(s) from Masaru"

  # Get the pending file reference
  local pending_ref
  pending_ref=$(jq -r '.pending_file // ""' "${trigger_file}" 2>/dev/null)

  # Get original questions for context
  local questions=""
  if [[ -n "${pending_ref}" && -f "${PI_DIR}/${pending_ref}" ]]; then
    questions=$(jq -r '.questions' "${PI_DIR}/${pending_ref}" 2>/dev/null)
  fi

  # Use Claude to parse the raw answers into structured format
  local parse_prompt="以下はパーソナリティ改善の質問に対するMasaruの回答です。各質問と回答を構造化してください。

## 質問:
${questions}

## Masaruの回答テキスト:
${answer_text}

## 出力フォーマット（JSON）:
{
  \"answers\": [
    {\"question_id\": 1, \"question\": \"質問文\", \"answer\": \"回答内容\"},
    ...
  ]
}

回答がない質問はスキップしてください。JSONのみ出力してください。"

  local parsed
  parsed=$(invoke_claude "${parse_prompt}")
  if [[ $? -ne 0 || -z "${parsed}" ]]; then
    log "WARN: Personality improvement: Failed to parse answers, using raw text"
    parsed="{\"answers\": [{\"question_id\": 0, \"answer\": \"$(echo "${answer_text}" | jq -Rs '.')\"}]}"
  fi

  # Extract JSON
  local json_parsed
  json_parsed=$(echo "${parsed}" | sed -n '/```json/,/```/{/```/d;p}')
  if [[ -z "${json_parsed}" ]] || ! echo "${json_parsed}" | jq empty 2>/dev/null; then
    json_parsed=$(echo "${parsed}" | awk '/^\{/{found=1} found{buf=buf $0 "\n"} /^\}/{if(found){printf "%s",buf; exit}}')
  fi
  if [[ -z "${json_parsed}" ]]; then
    json_parsed="${parsed}"
  fi

  # Save answer file
  local answer_timestamp
  answer_timestamp=$(date -u +%Y%m%d_%H%M%S)
  local answer_file="${PI_DIR}/answers_${answer_timestamp}.json"
  local ans_tmp
  ans_tmp=$(mktemp)
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg status "collected" \
    --arg pending_file "${pending_ref}" \
    --arg raw_text "${answer_text}" \
    --argjson parsed "${json_parsed}" \
    '{
      timestamp: $ts,
      status: $status,
      pending_file: $pending_file,
      raw_answers: $raw_text,
      parsed_answers: $parsed.answers,
      questions: ($parsed.answers | length)
    }' > "${ans_tmp}" && mv "${ans_tmp}" "${answer_file}" 2>/dev/null

  if [[ $? -eq 0 ]]; then
    log "Personality improvement: Answers collected and saved to ${answer_file}"
    _pi_update_trigger "answers_received" "" "" "answers_${answer_timestamp}.json"
  else
    log "ERROR: Personality improvement: Failed to save answer file"
  fi

  # Clean up check timestamp file
  rm -f "${last_answer_check_file}"
}

# ============================================================
# Step 3: Process answers and update personality
# ============================================================

_pi_process_answers() {
  log "Personality improvement: Processing answers"
  set_activity "personality_improvement" "\"task\":\"processing_answers\","

  local trigger_file="${PI_DIR}/trigger.json"
  local answer_filename
  answer_filename=$(jq -r '.answer_file // ""' "${trigger_file}" 2>/dev/null)

  local answer_file="${PI_DIR}/${answer_filename}"
  if [[ ! -f "${answer_file}" ]]; then
    # Find any collected answer file
    for f in "${PI_DIR}"/answers_*.json; do
      [[ -f "${f}" ]] || continue
      local s
      s=$(jq -r '.status // ""' "${f}" 2>/dev/null)
      if [[ "${s}" == "collected" ]]; then
        answer_file="${f}"
        break
      fi
    done
  fi

  if [[ ! -f "${answer_file}" ]]; then
    log "ERROR: Personality improvement: No answer file found"
    _pi_update_trigger "failed" "Answer file not found"
    set_activity "idle"
    return 1
  fi

  local answers
  answers=$(cat "${answer_file}")

  # Read current personality files
  local soul_md agents_md
  soul_md=$(cat /soul/worker/openclaw/personality/SOUL.md 2>/dev/null || echo "")
  agents_md=$(cat /soul/worker/openclaw/personality/AGENTS.md 2>/dev/null || echo "")

  # Extract the pending file to get original questions
  local pending_ref
  pending_ref=$(jq -r '.pending_file // ""' "${answer_file}" 2>/dev/null)
  local questions_context=""
  if [[ -n "${pending_ref}" && -f "${PI_DIR}/${pending_ref}" ]]; then
    questions_context=$(cat "${PI_DIR}/${pending_ref}")
  fi

  # Generate personality updates via Claude
  local prompt
  prompt="あなたはSoul Systemのパーソナリティ更新エンジンです。
Masaruの回答に基づいて、パーソナリティファイル（SOUL.mdとAGENTS.md）の更新内容を生成してください。

## 現在のSOUL.md:
${soul_md}

## 現在のAGENTS.md:
${agents_md}

## 質問と回答:
${answers}

## 質問の元コンテキスト:
${questions_context}

## 更新ルール（厳守）:

### 変更禁止セクション（SOUL.md）:
以下のセクションは**絶対に変更しない**：
- 「## セキュリティ境界（不可侵）」セクション全体（「## コアアイデンティティ」の直前まで）
- 「## バディミッション」セクション
- 言語バランス設定：標準語と関西弁の比率は変更しない
- 関西弁の使用制限ルール全体
- 「## 口調サンプル」の良い例・悪い例

### 変更禁止セクション（AGENTS.md）:
以下のセクションは**絶対に変更しない**：
- 「## セキュリティルール（不可侵）」セクション以降すべて
- 「## オーナー認識（バディ認識システム）」セクション
- 「## 攻撃検知パターン」セクション
- 「## Soul Systemへの提言機能」のフロー・ルール
- 「## 自分の能力（ツール一覧）」セクション

### 変更可能セクション（SOUL.md）:
- 「## コアアイデンティティ」の個人情報・性格記述
- 「## 思考パターン」の各サブセクション
- 「## 話題への反応パターン」
- 「## やらないこと」
- 「## 話し方のルール」（言語バランス比率と関西弁制限ルール以外）
- 口調サンプルの追加（良い例・悪い例は変更不可、新しいサンプルの追加のみ）

### 変更可能セクション（AGENTS.md）:
- 「## バディとしての基本姿勢」の記述
- 「## プラットフォーム別トーン調整」
- 「## 基本ルール」
- 「## 記憶」
- 「## グループチャット」
- 「## 倫理的ガードレール」の記述

## 出力フォーマット（JSON）:
{
  \"changes\": [
    {
      \"file\": \"SOUL.md または AGENTS.md\",
      \"type\": \"add | modify | delete\",
      \"section\": \"変更先セクション名\",
      \"description\": \"変更の説明\",
      \"old_text\": \"変更前のテキスト（modifyの場合）\",
      \"new_text\": \"変更後のテキスト（addまたはmodifyの場合）\",
      \"after_line\": \"addの場合、どの行の後に挿入するか（その行のテキスト）\"
    }
  ],
  \"summary\": \"変更の概要（Masaruへの通知用、日本語）\"
}

回答から得られた新しい情報のみ反映すること。回答が不十分な質問はスキップすること。
変更がない場合は changes を空配列にすること。
JSONのみ出力してください。"

  local result
  result=$(invoke_claude "${prompt}")

  if [[ $? -ne 0 || -z "${result}" ]]; then
    log "ERROR: Personality improvement: Claude analysis failed"
    _pi_update_trigger "failed" "Answer analysis failed"
    set_activity "idle"
    return 1
  fi

  # Extract JSON
  local json_result
  json_result=$(echo "${result}" | sed -n '/```json/,/```/{/```/d;p}')
  if [[ -z "${json_result}" ]] || ! echo "${json_result}" | jq empty 2>/dev/null; then
    json_result=$(echo "${result}" | awk '/^\{/{found=1} found{buf=buf $0 "\n"} /^\}/{if(found){printf "%s",buf; exit}}')
  fi
  if [[ -z "${json_result}" ]]; then
    json_result="${result}"
  fi

  # Validate JSON
  if ! echo "${json_result}" | jq -e '.changes' >/dev/null 2>&1; then
    log "ERROR: Personality improvement: Invalid change JSON"
    _pi_update_trigger "failed" "Invalid change format"
    set_activity "idle"
    return 1
  fi

  local changes_count
  changes_count=$(echo "${json_result}" | jq '.changes | length')

  if [[ "${changes_count}" -eq 0 ]]; then
    log "Personality improvement: No changes needed based on answers"
    _pi_update_trigger "completed" "No changes needed"
    # Mark answer file as processed
    local tmp
    tmp=$(mktemp)
    jq '.status = "processed" | .processed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' "${answer_file}" > "${tmp}" && mv "${tmp}" "${answer_file}"
    set_activity "idle"
    return 0
  fi

  # Security validation: check that no changes touch forbidden sections
  if ! _pi_validate_security "${json_result}"; then
    log "ALERT: Personality improvement: Security validation FAILED - changes touch forbidden sections"
    _pi_update_trigger "failed" "Security validation failed - forbidden sections targeted"
    set_activity "idle"
    return 1
  fi

  # Apply changes
  if _pi_apply_changes "${json_result}"; then
    local timestamp
    timestamp=$(date -u +%Y%m%d_%H%M%S)
    local summary
    summary=$(echo "${json_result}" | jq -r '.summary // "パーソナリティが更新されました"')

    # Save history
    local history_file="${PI_HISTORY_DIR}/${timestamp}.json"
    local hist_tmp
    hist_tmp=$(mktemp)
    jq -n \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson changes "${json_result}" \
      --arg soul_before "$(md5sum /soul/worker/openclaw/personality/SOUL.md.bak 2>/dev/null | awk '{print $1}')" \
      --arg agents_before "$(md5sum /soul/worker/openclaw/personality/AGENTS.md.bak 2>/dev/null | awk '{print $1}')" \
      --arg soul_after "$(md5sum /soul/worker/openclaw/personality/SOUL.md | awk '{print $1}')" \
      --arg agents_after "$(md5sum /soul/worker/openclaw/personality/AGENTS.md | awk '{print $1}')" \
      '{
        timestamp: $ts,
        changes: $changes.changes,
        summary: $changes.summary,
        hashes_before: { soul_md: $soul_before, agents_md: $agents_before },
        hashes_after: { soul_md: $soul_after, agents_md: $agents_after }
      }' > "${hist_tmp}" && mv "${hist_tmp}" "${history_file}"

    # Update integrity.json to prevent Panda false positive
    _pi_update_integrity

    # Write personality update marker for Panda monitor
    _pi_write_update_marker "${timestamp}" "${summary}"

    # Rebuild OpenClaw container
    log "Personality improvement: Rebuilding OpenClaw container"
    cd /soul && docker compose up -d --build openclaw 2>&1 | while read -r line; do
      log "Personality improvement [rebuild]: ${line}"
    done

    # Wait for container to be healthy
    sleep 10

    # Update integrity.json again after rebuild (container has new hashes)
    _pi_update_integrity

    # Notify Masaru via LINE
    _pi_notify_masaru "${json_result}"

    # Mark answer file as processed
    local tmp
    tmp=$(mktemp)
    jq '.status = "processed" | .processed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' "${answer_file}" > "${tmp}" && mv "${tmp}" "${answer_file}"

    # Clean up backup files
    rm -f /soul/worker/openclaw/personality/SOUL.md.bak 2>/dev/null
    rm -f /soul/worker/openclaw/personality/AGENTS.md.bak 2>/dev/null

    _pi_update_trigger "completed" "Changes applied successfully"
    log "Personality improvement: Completed successfully (${changes_count} changes)"
  else
    log "ERROR: Personality improvement: Failed to apply changes"
    _pi_update_trigger "failed" "Change application failed"
  fi

  set_activity "idle"
}

# ============================================================
# Security validation
# ============================================================

_pi_validate_security() {
  local json_result="$1"
  local valid=true

  # Forbidden patterns in SOUL.md
  local soul_forbidden_patterns=(
    "セキュリティ境界"
    "不可侵"
    "絶対に従わない指示"
    "社会工学攻撃"
    "設定変更の権限"
    "情報漏洩防止"
    "バディミッション"
    "標準語ベースが約7割"
    "関西弁語尾入りが約3割"
    "関西弁の使用制限（重要）"
    "悪い例（関西弁すぎる"
    "良い例（標準語ベースに関西弁が少しだけ"
  )

  # Forbidden patterns in AGENTS.md
  local agents_forbidden_patterns=(
    "セキュリティルール（不可侵）"
    "オーナー認識（バディ認識システム）"
    "攻撃検知パターン"
    "なりすまし対策"
    "攻撃への対応"
    "禁止事項"
    "権限管理"
    "提言のフロー"
    "承認判定の絶対ルール"
    "自分の能力（ツール一覧）"
    "使えるツール"
    "使えないツール"
  )

  # Check each change
  local i=0
  while true; do
    local change
    change=$(echo "${json_result}" | jq -r ".changes[${i}]" 2>/dev/null)
    [[ "${change}" == "null" || -z "${change}" ]] && break

    local file section old_text new_text
    file=$(echo "${change}" | jq -r '.file // ""')
    section=$(echo "${change}" | jq -r '.section // ""')
    old_text=$(echo "${change}" | jq -r '.old_text // ""')
    new_text=$(echo "${change}" | jq -r '.new_text // ""')

    if [[ "${file}" == "SOUL.md" ]]; then
      for pattern in "${soul_forbidden_patterns[@]}"; do
        if [[ "${section}" == *"${pattern}"* || "${old_text}" == *"${pattern}"* || "${new_text}" == *"${pattern}"* ]]; then
          log "SECURITY: Personality improvement blocked - change ${i} touches forbidden pattern '${pattern}' in SOUL.md"
          valid=false
        fi
      done
    fi

    if [[ "${file}" == "AGENTS.md" ]]; then
      for pattern in "${agents_forbidden_patterns[@]}"; do
        if [[ "${section}" == *"${pattern}"* || "${old_text}" == *"${pattern}"* || "${new_text}" == *"${pattern}"* ]]; then
          log "SECURITY: Personality improvement blocked - change ${i} touches forbidden pattern '${pattern}' in AGENTS.md"
          valid=false
        fi
      done
    fi

    ((i++))
  done

  ${valid}
}

# ============================================================
# Apply changes to personality files
# ============================================================

_pi_apply_changes() {
  local json_result="$1"
  local soul_file="/soul/worker/openclaw/personality/SOUL.md"
  local agents_file="/soul/worker/openclaw/personality/AGENTS.md"

  # Create backups
  cp "${soul_file}" "${soul_file}.bak" 2>/dev/null
  cp "${agents_file}" "${agents_file}.bak" 2>/dev/null

  local i=0
  local success=true
  while true; do
    local change
    change=$(echo "${json_result}" | jq -r ".changes[${i}]" 2>/dev/null)
    [[ "${change}" == "null" || -z "${change}" ]] && break

    local file type
    file=$(echo "${change}" | jq -r '.file // ""')
    type=$(echo "${change}" | jq -r '.type // ""')

    local target_file
    if [[ "${file}" == "SOUL.md" ]]; then
      target_file="${soul_file}"
    elif [[ "${file}" == "AGENTS.md" ]]; then
      target_file="${agents_file}"
    else
      log "WARN: Personality improvement: Unknown file ${file}, skipping change ${i}"
      ((i++))
      continue
    fi

    # Write old_text, new_text, after_line to temp files for safe Python processing
    local old_tmp new_tmp after_tmp
    old_tmp=$(mktemp)
    new_tmp=$(mktemp)
    after_tmp=$(mktemp)

    echo "${change}" | jq -r '.old_text // ""' > "${old_tmp}"
    echo "${change}" | jq -r '.new_text // ""' > "${new_tmp}"
    echo "${change}" | jq -r '.after_line // ""' > "${after_tmp}"

    case "${type}" in
      modify)
        python3 -c "
import sys
with open(sys.argv[1], 'r') as f: content = f.read()
with open(sys.argv[2], 'r') as f: old = f.read().rstrip('\n')
with open(sys.argv[3], 'r') as f: new = f.read().rstrip('\n')
if not old:
    sys.exit(1)
if old in content:
    content = content.replace(old, new, 1)
    with open(sys.argv[1], 'w') as f: f.write(content)
    sys.exit(0)
else:
    print('Old text not found', file=sys.stderr)
    sys.exit(1)
" "${target_file}" "${old_tmp}" "${new_tmp}" 2>/dev/null
        if [[ $? -ne 0 ]]; then
          log "WARN: Personality improvement: modify change ${i} failed (old text not found in ${file})"
        else
          log "Personality improvement: Applied modify change ${i} to ${file}"
        fi
        ;;
      add)
        python3 -c "
import sys
with open(sys.argv[1], 'r') as f: content = f.read()
with open(sys.argv[2], 'r') as f: after = f.read().rstrip('\n')
with open(sys.argv[3], 'r') as f: new = f.read().rstrip('\n')
if not new:
    sys.exit(0)
if after and after in content:
    content = content.replace(after, after + '\n' + new, 1)
    with open(sys.argv[1], 'w') as f: f.write(content)
else:
    with open(sys.argv[1], 'a') as f: f.write('\n' + new + '\n')
sys.exit(0)
" "${target_file}" "${after_tmp}" "${new_tmp}" 2>/dev/null
        log "Personality improvement: Applied add change ${i} to ${file}"
        ;;
      delete)
        python3 -c "
import sys
with open(sys.argv[1], 'r') as f: content = f.read()
with open(sys.argv[2], 'r') as f: old = f.read().rstrip('\n')
if not old:
    sys.exit(1)
if old in content:
    content = content.replace(old, '', 1)
    while '\n\n\n' in content: content = content.replace('\n\n\n', '\n\n')
    with open(sys.argv[1], 'w') as f: f.write(content)
    sys.exit(0)
else:
    print('Text to delete not found', file=sys.stderr)
    sys.exit(1)
" "${target_file}" "${old_tmp}" 2>/dev/null
        if [[ $? -ne 0 ]]; then
          log "WARN: Personality improvement: delete change ${i} failed (text not found in ${file})"
        else
          log "Personality improvement: Applied delete change ${i} to ${file}"
        fi
        ;;
    esac

    rm -f "${old_tmp}" "${new_tmp}" "${after_tmp}"
    ((i++))
  done

  # Final security check - verify forbidden sections are intact
  if ! _pi_verify_post_change; then
    log "ALERT: Personality improvement: Post-change security verification FAILED - restoring backups"
    cp "${soul_file}.bak" "${soul_file}" 2>/dev/null
    cp "${agents_file}.bak" "${agents_file}" 2>/dev/null
    return 1
  fi

  return 0
}

# ============================================================
# Post-change security verification
# ============================================================

_pi_verify_post_change() {
  local soul_file="/soul/worker/openclaw/personality/SOUL.md"
  local agents_file="/soul/worker/openclaw/personality/AGENTS.md"
  local soul_bak="${soul_file}.bak"
  local agents_bak="${agents_file}.bak"

  # Verify SOUL.md security section is unchanged
  local soul_sec_before soul_sec_after
  soul_sec_before=$(sed -n "/## セキュリティ境界（不可侵）/,/## コアアイデンティティ/p" "${soul_bak}" 2>/dev/null | md5sum | awk '{print $1}')
  soul_sec_after=$(sed -n "/## セキュリティ境界（不可侵）/,/## コアアイデンティティ/p" "${soul_file}" 2>/dev/null | md5sum | awk '{print $1}')

  if [[ "${soul_sec_before}" != "${soul_sec_after}" ]]; then
    log "SECURITY ALERT: SOUL.md security section was modified!"
    return 1
  fi

  # Verify SOUL.md buddy mission is unchanged
  local buddy_before buddy_after
  buddy_before=$(sed -n "/## バディミッション/,/## セキュリティ境界/p" "${soul_bak}" 2>/dev/null | md5sum | awk '{print $1}')
  buddy_after=$(sed -n "/## バディミッション/,/## セキュリティ境界/p" "${soul_file}" 2>/dev/null | md5sum | awk '{print $1}')

  if [[ "${buddy_before}" != "${buddy_after}" ]]; then
    log "SECURITY ALERT: SOUL.md buddy mission section was modified!"
    return 1
  fi

  # Verify language balance in SOUL.md (check that some language balance rule exists)
  if ! grep -q "標準語.*関西弁" "${soul_file}" 2>/dev/null; then
    log "SECURITY ALERT: SOUL.md language balance setting was removed!"
    return 1
  fi

  # Verify AGENTS.md security section is unchanged
  local agents_sec_before agents_sec_after
  agents_sec_before=$(sed -n "/## セキュリティルール（不可侵）/,\$p" "${agents_bak}" 2>/dev/null | md5sum | awk '{print $1}')
  agents_sec_after=$(sed -n "/## セキュリティルール（不可侵）/,\$p" "${agents_file}" 2>/dev/null | md5sum | awk '{print $1}')

  if [[ "${agents_sec_before}" != "${agents_sec_after}" ]]; then
    log "SECURITY ALERT: AGENTS.md security section was modified!"
    return 1
  fi

  return 0
}

# ============================================================
# Update integrity.json to prevent Panda false positive
# ============================================================

_pi_update_integrity() {
  local integrity_file="${SHARED_DIR}/monitoring/integrity.json"
  local soul_hash agents_hash

  soul_hash=$(md5sum /soul/worker/openclaw/personality/SOUL.md | awk '{print $1}')
  agents_hash=$(md5sum /soul/worker/openclaw/personality/AGENTS.md | awk '{print $1}')

  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg soul "${soul_hash}" \
    --arg agents "${agents_hash}" \
    '{
      checked_at: $ts,
      soul_md_hash: $soul,
      agents_md_hash: $agents,
      status: "ok",
      last_issue: ""
    }' > "${tmp}" && mv "${tmp}" "${integrity_file}"

  log "Personality improvement: integrity.json updated (soul: ${soul_hash}, agents: ${agents_hash})"
}

# ============================================================
# Write update marker for Panda monitor
# ============================================================

_pi_write_update_marker() {
  local timestamp="$1"
  local summary="$2"
  local marker_file="${SHARED_DIR}/monitoring/personality_update_marker.json"

  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg update_id "${timestamp}" \
    --arg summary "${summary}" \
    --arg source "personality_improvement" \
    '{
      updated_at: $ts,
      update_id: $update_id,
      summary: $summary,
      source: $source,
      legitimate: true
    }' > "${tmp}" && mv "${tmp}" "${marker_file}"
}

# ============================================================
# Notify Masaru via LINE
# ============================================================

_pi_notify_masaru() {
  local json_result="$1"
  local line_token="${LINE_CHANNEL_ACCESS_TOKEN:-}"
  local owner_line_id="Ua78c97ab5f7b6090fc17656bc12f5c99"

  if [[ -z "${line_token}" ]]; then
    log "WARN: Personality improvement: LINE_CHANNEL_ACCESS_TOKEN not set, skipping notification"
    return 0
  fi

  # Build notification message
  local summary
  summary=$(echo "${json_result}" | jq -r '.summary // "パーソナリティが更新されました"')

  local changes_detail=""
  local i=0
  while true; do
    local change
    change=$(echo "${json_result}" | jq -r ".changes[${i}]" 2>/dev/null)
    [[ "${change}" == "null" || -z "${change}" ]] && break

    local type desc file
    type=$(echo "${change}" | jq -r '.type // ""')
    desc=$(echo "${change}" | jq -r '.description // ""')
    file=$(echo "${change}" | jq -r '.file // ""')

    local type_label
    case "${type}" in
      add) type_label="【追加】" ;;
      modify) type_label="【修正】" ;;
      delete) type_label="【削除】" ;;
      *) type_label="【変更】" ;;
    esac

    changes_detail="${changes_detail}
${type_label} ${desc} (${file})"
    ((i++))
  done

  local message="パーソナリティ更新完了

${summary}

変更内容:${changes_detail}

※「パーソナリティ戻して」と送ると直前の変更を元に戻せます"

  # Send via LINE Push API
  local payload
  payload=$(jq -n \
    --arg to "${owner_line_id}" \
    --arg text "${message}" \
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
    log "ERROR: Personality improvement: LINE notification failed"
    rm -f "${response_body}"
    return 1
  }

  if [[ "${http_code}" -ge 200 && "${http_code}" -lt 300 ]]; then
    log "Personality improvement: LINE notification sent to Masaru"
  else
    log "ERROR: Personality improvement: LINE API returned HTTP ${http_code}: $(cat "${response_body}")"
  fi
  rm -f "${response_body}"
}

# ============================================================
# Rollback last personality change
# ============================================================

_pi_rollback_last_change() {
  log "Personality improvement: Rollback requested"
  set_activity "personality_improvement" "\"task\":\"rollback\","

  # Find latest history file
  local latest_history=""
  for f in "${PI_HISTORY_DIR}"/*.json; do
    [[ -f "${f}" ]] || continue
    latest_history="${f}"
  done

  if [[ -z "${latest_history}" ]]; then
    log "ERROR: Personality improvement: No history found for rollback"
    # Notify via LINE
    _pi_send_line_message "ロールバック失敗: 変更履歴がありません"
    set_activity "idle"
    return 1
  fi

  local history_data
  history_data=$(cat "${latest_history}")

  # Get changes and reverse them
  local changes
  changes=$(echo "${history_data}" | jq '.changes')

  local soul_file="/soul/worker/openclaw/personality/SOUL.md"
  local agents_file="/soul/worker/openclaw/personality/AGENTS.md"

  # Apply changes in reverse
  local total_changes
  total_changes=$(echo "${changes}" | jq 'length')
  local i=$((total_changes - 1))

  while [[ ${i} -ge 0 ]]; do
    local change
    change=$(echo "${changes}" | jq -r ".[${i}]")

    local file type
    file=$(echo "${change}" | jq -r '.file // ""')
    type=$(echo "${change}" | jq -r '.type // ""')

    local target_file
    if [[ "${file}" == "SOUL.md" ]]; then
      target_file="${soul_file}"
    elif [[ "${file}" == "AGENTS.md" ]]; then
      target_file="${agents_file}"
    else
      ((i--))
      continue
    fi

    # Write texts to temp files for safe Python processing
    local old_tmp new_tmp section_tmp
    old_tmp=$(mktemp)
    new_tmp=$(mktemp)
    section_tmp=$(mktemp)
    echo "${change}" | jq -r '.old_text // ""' > "${old_tmp}"
    echo "${change}" | jq -r '.new_text // ""' > "${new_tmp}"
    echo "${change}" | jq -r '.section // ""' > "${section_tmp}"

    case "${type}" in
      modify)
        # Reverse: replace new_text with old_text
        python3 -c "
import sys
with open(sys.argv[1], 'r') as f: content = f.read()
with open(sys.argv[2], 'r') as f: new = f.read().rstrip('\n')
with open(sys.argv[3], 'r') as f: old = f.read().rstrip('\n')
if new and new in content:
    content = content.replace(new, old, 1)
    with open(sys.argv[1], 'w') as f: f.write(content)
" "${target_file}" "${new_tmp}" "${old_tmp}" 2>/dev/null
        ;;
      add)
        # Reverse: remove the added text
        python3 -c "
import sys
with open(sys.argv[1], 'r') as f: content = f.read()
with open(sys.argv[2], 'r') as f: new = f.read().rstrip('\n')
if new:
    content = content.replace(new, '', 1)
    while '\n\n\n' in content: content = content.replace('\n\n\n', '\n\n')
    with open(sys.argv[1], 'w') as f: f.write(content)
" "${target_file}" "${new_tmp}" 2>/dev/null
        ;;
      delete)
        # Reverse: re-add the deleted text
        python3 -c "
import sys
with open(sys.argv[1], 'r') as f: content = f.read()
with open(sys.argv[2], 'r') as f: old = f.read().rstrip('\n')
with open(sys.argv[3], 'r') as f: section = f.read().rstrip('\n')
if old:
    if section and section in content:
        idx = content.index(section) + len(section)
        nl = content.index('\n', idx)
        content = content[:nl+1] + old + '\n' + content[nl+1:]
    else:
        content += '\n' + old + '\n'
    with open(sys.argv[1], 'w') as f: f.write(content)
" "${target_file}" "${old_tmp}" "${section_tmp}" 2>/dev/null
        ;;
    esac

    rm -f "${old_tmp}" "${new_tmp}" "${section_tmp}"
    ((i--))
  done

  # Update integrity.json
  _pi_update_integrity

  # Write update marker
  _pi_write_update_marker "$(date -u +%Y%m%d_%H%M%S)" "ロールバック実行"

  # Rebuild OpenClaw
  log "Personality improvement: Rebuilding OpenClaw after rollback"
  cd /soul && docker compose up -d --build openclaw 2>&1 | while read -r line; do
    log "Personality improvement [rollback-rebuild]: ${line}"
  done

  sleep 10
  _pi_update_integrity

  # Remove the history file (it's been rolled back)
  local rolled_back_file="${latest_history%.json}_rolledback.json"
  mv "${latest_history}" "${rolled_back_file}"

  # Notify Masaru
  _pi_send_line_message "パーソナリティを直前の状態に戻しました。変更内容が元に戻っています。"

  log "Personality improvement: Rollback completed"
  set_activity "idle"
}

# ============================================================
# Helper: send LINE message to Masaru
# ============================================================

_pi_send_line_message() {
  local message="$1"
  local line_token="${LINE_CHANNEL_ACCESS_TOKEN:-}"
  local owner_line_id="Ua78c97ab5f7b6090fc17656bc12f5c99"

  if [[ -z "${line_token}" ]]; then
    log "WARN: Personality improvement: LINE_CHANNEL_ACCESS_TOKEN not set"
    return 1
  fi

  local payload
  payload=$(jq -n \
    --arg to "${owner_line_id}" \
    --arg text "${message}" \
    '{
      to: $to,
      messages: [{
        type: "text",
        text: $text
      }]
    }')

  curl -s \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${line_token}" \
    -d "${payload}" \
    "https://api.line.me/v2/bot/message/push" >/dev/null 2>&1
}

# ============================================================
# Helper: update trigger file
# ============================================================

_pi_update_trigger() {
  local new_status="$1"
  local detail="${2:-}"
  local timestamp="${3:-}"
  local answer_file="${4:-}"

  local trigger_file="${PI_DIR}/trigger.json"
  local tmp
  tmp=$(mktemp)

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  if [[ -f "${trigger_file}" ]]; then
    local jq_args=()
    jq_args+=(--arg status "${new_status}")
    jq_args+=(--arg updated_at "${now}")

    local jq_expr='.status = $status | .updated_at = $updated_at'

    if [[ -n "${detail}" ]]; then
      jq_args+=(--arg detail "${detail}")
      jq_expr="${jq_expr} | .detail = \$detail"
    fi

    if [[ "${new_status}" == "questions_sent" ]]; then
      jq_args+=(--arg questions_sent_at "${now}")
      jq_expr="${jq_expr} | .questions_sent_at = \$questions_sent_at"
    fi

    if [[ -n "${timestamp}" ]]; then
      jq_args+=(--arg pending_ref "pending_${timestamp}.json")
      jq_expr="${jq_expr} | .pending_file = \$pending_ref"
    fi

    if [[ -n "${answer_file}" ]]; then
      jq_args+=(--arg answer_file "${answer_file}")
      jq_expr="${jq_expr} | .answer_file = \$answer_file"
    fi

    jq "${jq_args[@]}" "${jq_expr}" "${trigger_file}" > "${tmp}" && mv "${tmp}" "${trigger_file}"
  fi
}

# ============================================================
# Manual trigger handler (from OpenClaw keyword detection)
# ============================================================

check_personality_manual_trigger() {
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  # Check both locations: PI_DIR and bot_commands (where OpenClaw writes)
  local manual_trigger="${PI_DIR}/manual_trigger.json"
  local bot_cmd_trigger="${SHARED_DIR}/bot_commands/personality_manual_trigger.json"

  # If trigger exists in bot_commands, move it to PI_DIR
  if [[ -f "${bot_cmd_trigger}" ]]; then
    local bc_status
    bc_status=$(jq -r '.status // ""' "${bot_cmd_trigger}" 2>/dev/null)
    if [[ "${bc_status}" == "pending" ]]; then
      cp "${bot_cmd_trigger}" "${manual_trigger}"
      local tmp
      tmp=$(mktemp)
      jq '.status = "moved_to_pi"' "${bot_cmd_trigger}" > "${tmp}" && mv "${tmp}" "${bot_cmd_trigger}"
    fi
  fi

  [[ -f "${manual_trigger}" ]] || return 0

  local status
  status=$(jq -r '.status // ""' "${manual_trigger}" 2>/dev/null)
  [[ "${status}" == "pending" ]] || return 0

  log "Personality improvement: Manual trigger detected"

  # Verify owner identity (user_id must match OWNER_LINE_ID)
  local trigger_user_id
  trigger_user_id=$(jq -r '.user_id // ""' "${manual_trigger}" 2>/dev/null)
  if [[ -z "${trigger_user_id}" || "${trigger_user_id}" != "${PI_OWNER_LINE_ID}" ]]; then
    log "SECURITY: Personality improvement: Manual trigger REJECTED - user_id mismatch (got: ${trigger_user_id:-empty})"
    local tmp
    tmp=$(mktemp)
    jq '.status = "rejected" | .reason = "unauthorized"' "${manual_trigger}" > "${tmp}" && mv "${tmp}" "${manual_trigger}"
    return 0
  fi

  # Check cooldown (6 hours since last trigger)
  local trigger_file="${PI_DIR}/trigger.json"
  if [[ -f "${trigger_file}" ]]; then
    local last_triggered
    last_triggered=$(jq -r '.triggered_at // ""' "${trigger_file}" 2>/dev/null)
    if [[ -n "${last_triggered}" ]]; then
      local last_epoch now_epoch
      last_epoch=$(date -d "${last_triggered}" +%s 2>/dev/null || echo 0)
      now_epoch=$(date +%s)
      if (( now_epoch - last_epoch < 21600 )); then
        log "Personality improvement: Manual trigger ignored (within 6h cooldown)"
        local tmp
        tmp=$(mktemp)
        jq '.status = "ignored" | .reason = "cooldown"' "${manual_trigger}" > "${tmp}" && mv "${tmp}" "${manual_trigger}"
        _pi_send_line_message "パーソナリティ改善は6時間以内に実行済みです。次回実行可能時間まで少々お待ちください。"
        return 0
      fi
    fi
  fi

  # Create the main trigger
  local tmp
  tmp=$(mktemp)
  jq -n \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg src "manual" \
    '{
      type: "personality_improvement",
      status: "pending",
      triggered_at: $ts,
      triggered_by: $src
    }' > "${tmp}" && mv "${tmp}" "${trigger_file}"

  # Mark manual trigger as processed
  local mt_tmp
  mt_tmp=$(mktemp)
  jq '.status = "processed"' "${manual_trigger}" > "${mt_tmp}" && mv "${mt_tmp}" "${manual_trigger}"

  log "Personality improvement: Manual trigger accepted"
}

# ============================================================
# Rollback trigger handler (from OpenClaw keyword detection)
# ============================================================

check_personality_rollback_trigger() {
  [[ "${NODE_NAME}" == "triceratops" ]] || return 0

  # Check both locations: PI_DIR and bot_commands (where OpenClaw writes)
  local rollback_trigger="${PI_DIR}/rollback_trigger.json"
  local bot_cmd_rollback="${SHARED_DIR}/bot_commands/personality_rollback_trigger.json"

  # If rollback trigger exists in bot_commands, move it to PI_DIR
  if [[ -f "${bot_cmd_rollback}" ]]; then
    local bc_status
    bc_status=$(jq -r '.status // ""' "${bot_cmd_rollback}" 2>/dev/null)
    if [[ "${bc_status}" == "pending" ]]; then
      cp "${bot_cmd_rollback}" "${rollback_trigger}"
      local tmp
      tmp=$(mktemp)
      jq '.status = "moved_to_pi"' "${bot_cmd_rollback}" > "${tmp}" && mv "${tmp}" "${bot_cmd_rollback}"
    fi
  fi

  [[ -f "${rollback_trigger}" ]] || return 0

  local status
  status=$(jq -r '.status // ""' "${rollback_trigger}" 2>/dev/null)
  [[ "${status}" == "pending" ]] || return 0

  log "Personality improvement: Rollback trigger detected"

  # Verify owner identity
  local trigger_user_id
  trigger_user_id=$(jq -r '.user_id // ""' "${rollback_trigger}" 2>/dev/null)
  if [[ -z "${trigger_user_id}" || "${trigger_user_id}" != "${PI_OWNER_LINE_ID}" ]]; then
    log "SECURITY: Personality improvement: Rollback trigger REJECTED - user_id mismatch (got: ${trigger_user_id:-empty})"
    local tmp
    tmp=$(mktemp)
    jq '.status = "rejected" | .reason = "unauthorized"' "${rollback_trigger}" > "${tmp}" && mv "${tmp}" "${rollback_trigger}"
    return 0
  fi

  # Process rollback
  _pi_rollback_last_change

  # Mark rollback trigger as processed
  local tmp
  tmp=$(mktemp)
  jq '.status = "processed" | .processed_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' "${rollback_trigger}" > "${tmp}" && mv "${tmp}" "${rollback_trigger}"
}
