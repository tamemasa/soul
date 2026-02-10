#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SOUL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SHARED_DIR="${SOUL_DIR}/shared"

source "${SCRIPT_DIR}/commands.sh"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

print_banner() {
  echo -e "${MAGENTA}${BOLD}"
  echo '  ____              _   '
  echo ' / ___|  ___  _   _| |  '
  echo ' \___ \ / _ \| | | | |  '
  echo '  ___) | (_) | |_| | |  '
  echo ' |____/ \___/ \__,_|_|  '
  echo -e "${NC}"
  echo -e "${DIM}  3-Brain Autonomous Agent System${NC}"
  echo ""
}

print_help() {
  echo -e "${BOLD}Commands:${NC}"
  echo -e "  ${CYAN}/task${NC} <description>    Submit a new task to the Brain nodes"
  echo -e "  ${CYAN}/status${NC}               Show system overview (nodes, tasks, workers)"
  echo -e "  ${CYAN}/discussions${NC}           List active discussions"
  echo -e "  ${CYAN}/discussion${NC} <id>       Show details of a specific discussion"
  echo -e "  ${CYAN}/decisions${NC}             List all decisions"
  echo -e "  ${CYAN}/eval${NC}                  Trigger a manual evaluation cycle"
  echo -e "  ${CYAN}/params${NC} [node]         Show parameters (all nodes or specific)"
  echo -e "  ${CYAN}/set${NC} <node> <k> <v>    Set a parameter value for a node"
  echo -e "  ${CYAN}/workers${NC}               List worker nodes"
  echo -e "  ${CYAN}/logs${NC} [node] [lines]   View recent logs"
  echo -e "  ${CYAN}/ask${NC} <question>        Ask the Brains a question (discussion without execution)"
  echo -e "  ${CYAN}/restart${NC} <node>        Restart a brain node container"
  echo -e "  ${CYAN}/help${NC}                  Show this help"
  echo -e "  ${CYAN}/quit${NC}                  Exit"
  echo ""
  echo -e "${DIM}  Or type any text to submit it as a task to the Brains.${NC}"
}

prompt_loop() {
  print_banner
  print_help

  while true; do
    echo -ne "${GREEN}${BOLD}soul>${NC} "
    read -r input || break

    # Trim whitespace
    input=$(echo "${input}" | xargs)
    [[ -n "${input}" ]] || continue

    case "${input}" in
      /help)
        print_help
        ;;
      /quit|/exit|/q)
        echo -e "${DIM}Goodbye.${NC}"
        break
        ;;
      /status)
        cmd_status
        ;;
      /discussions)
        cmd_list_discussions
        ;;
      /discussion\ *)
        local_id="${input#/discussion }"
        cmd_show_discussion "${local_id}"
        ;;
      /decisions)
        cmd_list_decisions
        ;;
      /task\ *)
        local_desc="${input#/task }"
        cmd_submit_task "${local_desc}"
        ;;
      /ask\ *)
        local_question="${input#/ask }"
        cmd_ask_question "${local_question}"
        ;;
      /eval)
        cmd_trigger_eval
        ;;
      /params)
        cmd_show_params ""
        ;;
      /params\ *)
        local_node="${input#/params }"
        cmd_show_params "${local_node}"
        ;;
      /set\ *)
        local_args="${input#/set }"
        read -r set_node set_key set_value <<< "${local_args}"
        cmd_set_param "${set_node}" "${set_key}" "${set_value}"
        ;;
      /workers)
        cmd_list_workers
        ;;
      /logs)
        cmd_show_logs "" 20
        ;;
      /logs\ *)
        local_args="${input#/logs }"
        read -r log_node log_lines <<< "${local_args}"
        cmd_show_logs "${log_node}" "${log_lines:-20}"
        ;;
      /restart\ *)
        local_node="${input#/restart }"
        cmd_restart_node "${local_node}"
        ;;
      /*)
        echo -e "${RED}Unknown command: ${input}${NC}"
        echo -e "${DIM}Type /help for available commands${NC}"
        ;;
      *)
        # Free text -> submit as task
        echo -e "${YELLOW}Submitting as task to the Brains...${NC}"
        cmd_submit_task "${input}"
        ;;
    esac

    echo ""
  done
}

# Allow single command execution: soul-chat.sh /status
if [[ $# -gt 0 ]]; then
  case "$1" in
    --help|-h) print_help; exit 0 ;;
    *)
      input="$*"
      case "${input}" in
        /status) cmd_status ;;
        /discussions) cmd_list_discussions ;;
        /discussion\ *) cmd_show_discussion "${input#/discussion }" ;;
        /decisions) cmd_list_decisions ;;
        /eval) cmd_trigger_eval ;;
        /params) cmd_show_params "" ;;
        /params\ *) cmd_show_params "${input#/params }" ;;
        /set\ *)
          _set_args="${input#/set }"
          read -r _s_node _s_key _s_value <<< "${_set_args}"
          cmd_set_param "${_s_node}" "${_s_key}" "${_s_value}"
          ;;
        /workers) cmd_list_workers ;;
        /logs) cmd_show_logs "" 20 ;;
        /logs\ *) cmd_show_logs "${input#/logs }" 20 ;;
        /restart\ *) cmd_restart_node "${input#/restart }" ;;
        /task\ *) cmd_submit_task "${input#/task }" ;;
        /ask\ *) cmd_ask_question "${input#/ask }" ;;
        *) cmd_submit_task "${input}" ;;
      esac
      exit 0
      ;;
  esac
fi

prompt_loop
