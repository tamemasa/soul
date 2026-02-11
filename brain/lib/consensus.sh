#!/usr/bin/env bash
# consensus.sh - Consensus evaluation and decision logic

evaluate_consensus() {
  local task_id="$1"
  local round="$2"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"
  local round_dir="${discussion_dir}/round_${round}"
  local status_file="${discussion_dir}/status.json"

  # Collect all votes
  local approve_count=0
  local reject_count=0
  local modify_count=0

  for node in "${ALL_NODES[@]}"; do
    local response_file="${round_dir}/${node}.json"
    if [[ -f "${response_file}" ]]; then
      local vote
      vote=$(jq -r '.vote' "${response_file}")

      case "${vote}" in
        approve) ((approve_count++)) ;;
        reject) ((reject_count++)) ;;
        approve_with_modification) ((modify_count++)) ;;
      esac
    fi
  done

  log "Consensus check for ${task_id} round ${round}: approve=${approve_count} modify=${modify_count} reject=${reject_count}"

  # Unanimous reject = immediate rejection (any round)
  if [[ ${reject_count} -eq ${#ALL_NODES[@]} ]]; then
    log "Unanimous reject for ${task_id} in round ${round}, rejecting immediately"
    finalize_decision "${task_id}" "rejected" "${round}" ""
    return
  fi

  # Still have more rounds → advance to next round
  if [[ ${round} -lt ${MAX_ROUNDS} ]]; then
    local next_round=$((round + 1))
    mkdir -p "${discussion_dir}/round_${next_round}"

    local tmp
    tmp=$(mktemp)
    jq '.current_round = '"${next_round}"' | .status = "discussing"' \
      "${status_file}" > "${tmp}" && mv "${tmp}" "${status_file}"

    log "Advancing ${task_id} to round ${next_round} (minimum 2 rounds required)"
    return
  fi

  # Final round reached → Triceratops makes the final decision
  log "All ${MAX_ROUNDS} rounds complete for ${task_id}, Triceratops renders final decision"
  triceratops_final_decision "${task_id}" "${round}"
}

triceratops_final_decision() {
  local task_id="$1"
  local final_round="$2"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"

  # Collect all round responses with full detail
  local all_responses=""
  for r in $(seq 1 "${final_round}"); do
    all_responses="${all_responses}
### Round ${r}:"
    for node in "${ALL_NODES[@]}"; do
      local resp_file="${discussion_dir}/round_${r}/${node}.json"
      if [[ -f "${resp_file}" ]]; then
        local opinion vote approach concerns
        opinion=$(jq -r '.opinion' "${resp_file}")
        vote=$(jq -r '.vote' "${resp_file}")
        approach=$(jq -r '.proposed_approach // ""' "${resp_file}")
        concerns=$(jq -r '.concerns // [] | join(", ")' "${resp_file}")
        all_responses="${all_responses}
#### ${node} (vote: ${vote}):
Opinion: ${opinion}"
        if [[ -n "${approach}" ]]; then
          all_responses="${all_responses}
Proposed approach: ${approach}"
        fi
        if [[ -n "${concerns}" ]]; then
          all_responses="${all_responses}
Concerns: ${concerns}"
        fi
        all_responses="${all_responses}
"
      fi
    done
  done

  # Load user comments if any
  local user_comments=""
  local comments_file="${discussion_dir}/comments.json"
  if [[ -f "${comments_file}" ]]; then
    local comment_count
    comment_count=$(jq 'length' "${comments_file}" 2>/dev/null || echo 0)
    if [[ ${comment_count} -gt 0 ]]; then
      user_comments="
## User Comments:"
      local i
      for ((i=0; i<comment_count; i++)); do
        local msg timestamp
        msg=$(jq -r ".[$i].message" "${comments_file}")
        timestamp=$(jq -r ".[$i].created_at" "${comments_file}")
        user_comments="${user_comments}
- [${timestamp}] ${msg}"
      done
    fi
  fi

  local task_content
  task_content=$(cat "${discussion_dir}/task.json")

  local prompt="あなたはSoul Systemのトリケラトプス議長です。
全ブレインノードによる${final_round}ラウンドの議論を経て、最終判断を下してください。

## タスク:
${task_content}

## 議論全履歴:
${all_responses}
${user_comments}

## 指示:
議論のすべての観点をレビューし、議長として：
1. 全ノードの主要な論点を統合する
2. 安全性の懸念（パンダ）、革新の機会（ゴリラ）、実用的バランスを考慮する
3. タスクの目標に最も適した最終判断を下す

reasoning、final_approachは日本語で記述すること。JSONキー名とdecision値は英語のまま維持する。

Respond with ONLY a valid JSON object:
{
  \"decision\": \"approved|rejected\",
  \"final_approach\": \"議論の最良のアイデアを統合したアプローチ\",
  \"reasoning\": \"この判断に至った理由（各ノードの論点を参照）\",
  \"decided_by\": \"triceratops\"
}"

  local response
  response=$(invoke_claude "${prompt}")

  # Strip markdown code fences if Claude wrapped the response
  response=$(echo "${response}" | sed '/^```\(json\)\?$/d')

  local decision="approved"
  local approach=""
  if echo "${response}" | jq . > /dev/null 2>&1; then
    decision=$(echo "${response}" | jq -r '.decision // "approved"')
    approach=$(echo "${response}" | jq -r '.final_approach // ""')
  fi

  finalize_decision "${task_id}" "${decision}" "${final_round}" "${approach}"
}

finalize_decision() {
  local task_id="$1"
  local decision="$2"
  local final_round="$3"
  local approach="$4"
  local discussion_dir="${SHARED_DIR}/discussions/${task_id}"
  local status_file="${discussion_dir}/status.json"

  # Guard: if a newer round was requested (e.g. via user comment), don't overwrite
  local current_round_now
  current_round_now=$(jq -r '.current_round' "${status_file}")
  if [[ ${current_round_now} -gt ${final_round} ]]; then
    log "New round ${current_round_now} requested during finalization of round ${final_round} for ${task_id}, skipping"
    return
  fi

  # Update discussion status
  local tmp
  tmp=$(mktemp)
  jq '.status = "decided" | .decided_at = "'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"' \
    "${status_file}" > "${tmp}" && mv "${tmp}" "${status_file}"

  # Executor is always triceratops
  local executor="triceratops"

  # Write decision file — status is pending_announcement so triceratops can announce
  local final_status="pending_announcement"
  if [[ "${decision}" == "rejected" ]]; then
    # Check if there's a previous execution in history that needs rollback
    local history_file="${SHARED_DIR}/decisions/${task_id}_history.json"
    local has_prev_exec=false
    if [[ -f "${history_file}" ]]; then
      local exec_count
      exec_count=$(jq '[.[] | select(.result != null and .result.result != null)] | length' "${history_file}" 2>/dev/null || echo 0)
      [[ ${exec_count} -gt 0 ]] && has_prev_exec=true
    fi

    if [[ "${has_prev_exec}" == "true" ]]; then
      # Previous execution exists — trigger rollback via announcement+execution pipeline
      final_status="pending_announcement"

      local rb="【ロールバック実行】\nこのタスクは以前実行済みですが、再議論でリジェクトされました。前回の実行内容を取り消してください。\n"

      # Include user's request
      local comments_file="${discussion_dir}/comments.json"
      if [[ -f "${comments_file}" ]]; then
        local last_msg
        last_msg=$(jq -r '[.[] | select(.author == "user")] | last | .message // ""' "${comments_file}" 2>/dev/null)
        [[ -n "${last_msg}" ]] && rb="${rb}\n## ユーザの要求\n${last_msg}\n"
      fi

      # Include previous execution result so executor knows what to undo
      local prev_result
      prev_result=$(jq -r '[.[] | select(.result != null and .result.result != null)] | last | .result.result // ""' "${history_file}" 2>/dev/null)
      [[ -n "${prev_result}" ]] && rb="${rb}\n## 前回の実行結果（取り消し対象）\n${prev_result}\n"

      # Prepend triceratops rejection reasoning if available
      [[ -n "${approach}" ]] && rb="## リジェクト理由\n${approach}\n\n${rb}"

      rb="${rb}\n## 指示\n上記の前回実行内容を元に戻してください。ファイルの変更、設定の追加等があれば削除・復元してください。"
      approach="${rb}"
      log "Previous execution found for ${task_id}, triggering rollback execution"
    else
      final_status="rejected"
    fi
  fi

  local escaped_approach
  escaped_approach=$(echo "${approach}" | jq -Rs .)
  cat > "${SHARED_DIR}/decisions/${task_id}.json" <<EOF
{
  "task_id": "${task_id}",
  "decision": "${decision}",
  "status": "${final_status}",
  "final_round": ${final_round},
  "final_approach": ${escaped_approach},
  "executor": "${executor}",
  "decided_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

  log "Decision finalized for ${task_id}: ${decision} (executor: ${executor}, status: ${final_status})"
}
