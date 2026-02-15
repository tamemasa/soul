#!/usr/bin/env bash
# Host-level network restrictions for Docker bridge networks.
# Blocks containers on br-openclaw from accessing host services and LAN.
# Must be run as root. Idempotent — safe to re-run.
#
# Usage: sudo bash scripts/setup-network-restrictions.sh [apply|status|remove]

set -euo pipefail

BRIDGE="br-openclaw"
MARKER="soul-openclaw-restrict"  # comment marker for cleanup

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [network-restrict] $*"
}

remove_existing() {
  # Remove any previous rules with our marker comment
  for chain in DOCKER-USER INPUT; do
    while iptables -L "$chain" -n --line-numbers 2>/dev/null | grep -q "$MARKER"; do
      local num
      num=$(iptables -L "$chain" -n --line-numbers 2>/dev/null | grep "$MARKER" | head -1 | awk '{print $1}')
      iptables -D "$chain" "$num"
    done
  done
  log "Removed existing $MARKER rules"
}

apply() {
  remove_existing

  log "Applying network restrictions for $BRIDGE..."

  # === DOCKER-USER chain (FORWARD traffic) ===
  # Allow container-to-container on same bridge
  iptables -I DOCKER-USER -i "$BRIDGE" -o "$BRIDGE" -j RETURN -m comment --comment "$MARKER"

  # Block RFC1918 private networks
  iptables -A DOCKER-USER -i "$BRIDGE" -d 10.0.0.0/8 -j DROP -m comment --comment "$MARKER"
  iptables -A DOCKER-USER -i "$BRIDGE" -d 172.16.0.0/12 -j DROP -m comment --comment "$MARKER"
  iptables -A DOCKER-USER -i "$BRIDGE" -d 192.168.0.0/16 -j DROP -m comment --comment "$MARKER"

  # Block link-local and metadata
  iptables -A DOCKER-USER -i "$BRIDGE" -d 169.254.0.0/16 -j DROP -m comment --comment "$MARKER"

  log "  DOCKER-USER: allow same-bridge, block RFC1918/link-local"

  # === INPUT chain (direct access to host) ===
  # Insert at top of INPUT so they run before Tailscale/UFW rules.
  # Order: -I inserts at position 1, so add in reverse priority order.
  # Result: ESTABLISHED (1) → DNS (2,3) → DROP (4) → ts-input → ufw ...
  iptables -I INPUT 1 -i "$BRIDGE" -j DROP -m comment --comment "$MARKER"
  iptables -I INPUT 1 -i "$BRIDGE" -p tcp --dport 53 -j ACCEPT -m comment --comment "$MARKER"
  iptables -I INPUT 1 -i "$BRIDGE" -p udp --dport 53 -j ACCEPT -m comment --comment "$MARKER"
  iptables -I INPUT 1 -i "$BRIDGE" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT -m comment --comment "$MARKER"

  log "  INPUT: allow DNS, block all other host access (before ts-input/ufw)"
  log "Network restrictions applied for $BRIDGE"
}

status() {
  echo "=== DOCKER-USER chain ==="
  iptables -L DOCKER-USER -v -n --line-numbers 2>/dev/null | grep -E "^num|$BRIDGE|$MARKER" || echo "(no rules)"
  echo ""
  echo "=== INPUT chain ($BRIDGE rules) ==="
  iptables -L INPUT -v -n --line-numbers 2>/dev/null | grep -E "^num|$MARKER" || echo "(no rules)"
}

case "${1:-apply}" in
  apply)  apply ;;
  status) status ;;
  remove) remove_existing ;;
  *)      echo "Usage: $0 [apply|status|remove]"; exit 1 ;;
esac
