#!/usr/bin/env bash
# Soul System: Network isolation for containers
# - Soul containers: block LAN access, allow internet
# - OpenClaw: handled by openclaw/network-restrict.sh (container-internal iptables)
# Usage: sudo ./network-restrict.sh [apply|remove|status]
# Must be run as root (or via sudo)

set -euo pipefail

LAN_SUBNET="192.168.11.0/24"
SOUL_BRIDGE="br-soul"

# Check if rule exists
rule_exists() {
  iptables -C DOCKER-USER $1 -m comment --comment "$2" 2>/dev/null
}

# Delete rule if it exists
del_rule() {
  local rule="$1"
  local comment="$2"
  while rule_exists "${rule}" "${comment}"; do
    iptables -D DOCKER-USER ${rule} -m comment --comment "${comment}"
    echo "  [removed] ${comment}"
  done
}

apply() {
  echo "=== Applying network restrictions ==="

  # First, remove any existing rules to avoid duplicates
  echo "Cleaning existing rules..."
  del_rule "-i ${SOUL_BRIDGE} -d ${LAN_SUBNET} -j DROP" "soul-block-lan"

  echo ""
  echo "Inserting rules..."

  # Soul: block LAN
  echo "[${SOUL_BRIDGE}] Block LAN access"
  iptables -I DOCKER-USER -i ${SOUL_BRIDGE} -d ${LAN_SUBNET} -j DROP \
    -m comment --comment "soul-block-lan"
  echo "  [added] soul-block-lan"

  echo ""
  echo "Done. Soul containers blocked from LAN (${LAN_SUBNET})."
}

remove() {
  echo "=== Removing network restrictions ==="

  echo "[${SOUL_BRIDGE}] Removing LAN block"
  del_rule "-i ${SOUL_BRIDGE} -d ${LAN_SUBNET} -j DROP" "soul-block-lan"

  echo ""
  echo "Done. All restrictions removed."
}

status() {
  echo "=== DOCKER-USER chain (soul system rules) ==="
  iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null \
    | grep -E "(num|soul-)" || echo "No soul rules found"
  echo ""
  echo "=== Full DOCKER-USER chain ==="
  iptables -L DOCKER-USER -n -v --line-numbers 2>/dev/null
}

case "${1:-apply}" in
  apply)  apply ;;
  remove) remove ;;
  status) status ;;
  *) echo "Usage: $0 [apply|remove|status]"; exit 1 ;;
esac
