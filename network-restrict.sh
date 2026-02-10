#!/usr/bin/env bash
# Soul System: Block container access to LAN while allowing internet
# Usage: sudo ./network-restrict.sh [apply|remove|status]

set -euo pipefail

BRIDGE="br-soul"
LAN_SUBNET="192.168.11.0/24"
COMMENT="soul-lan-block"

apply() {
  # Check if rule already exists
  if sudo iptables -C DOCKER-USER -i "${BRIDGE}" -d "${LAN_SUBNET}" -j DROP -m comment --comment "${COMMENT}" 2>/dev/null; then
    echo "Rule already applied"
    return 0
  fi

  # Block traffic from soul containers to LAN
  sudo iptables -I DOCKER-USER -i "${BRIDGE}" -d "${LAN_SUBNET}" -j DROP -m comment --comment "${COMMENT}"
  echo "Applied: containers on ${BRIDGE} cannot reach ${LAN_SUBNET}"
}

remove() {
  if sudo iptables -C DOCKER-USER -i "${BRIDGE}" -d "${LAN_SUBNET}" -j DROP -m comment --comment "${COMMENT}" 2>/dev/null; then
    sudo iptables -D DOCKER-USER -i "${BRIDGE}" -d "${LAN_SUBNET}" -j DROP -m comment --comment "${COMMENT}"
    echo "Removed: LAN access restriction lifted"
  else
    echo "Rule not found, nothing to remove"
  fi
}

status() {
  echo "=== DOCKER-USER chain (soul rules) ==="
  sudo iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null | grep -E "(num|${COMMENT}|${BRIDGE})" || echo "No soul rules found"
}

case "${1:-apply}" in
  apply)  apply ;;
  remove) remove ;;
  status) status ;;
  *) echo "Usage: $0 [apply|remove|status]"; exit 1 ;;
esac
