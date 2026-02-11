#!/usr/bin/env bash
# OpenClaw container network restriction script
# Blocks access to: LAN, other Docker networks, host gateway
# Allows: DNS (udp/tcp 53) and public internet
#
# Must run as root (before dropping to openclaw user)
# Requires NET_ADMIN capability and iptables installed in container

set -euo pipefail

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [network-restrict] $*"
}

apply() {
  log "Applying network restrictions inside container..."

  # Flush any existing OUTPUT rules (start clean)
  iptables -F OUTPUT 2>/dev/null || true

  # 1. Allow loopback (localhost)
  iptables -A OUTPUT -o lo -j ACCEPT
  log "  [allow] loopback"

  # 2. Allow established/related connections (responses to allowed outbound)
  iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  log "  [allow] established/related"

  # 3. Allow DNS (UDP and TCP port 53) to any destination
  iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
  log "  [allow] DNS (udp/tcp 53)"

  # 4. Block all RFC1918 private networks
  iptables -A OUTPUT -d 10.0.0.0/8 -j DROP
  iptables -A OUTPUT -d 172.16.0.0/12 -j DROP
  iptables -A OUTPUT -d 192.168.0.0/16 -j DROP
  log "  [block] RFC1918 (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)"

  # 5. Block link-local
  iptables -A OUTPUT -d 169.254.0.0/16 -j DROP
  log "  [block] link-local (169.254.0.0/16)"

  # 6. Block metadata service (cloud environments)
  iptables -A OUTPUT -d 169.254.169.254/32 -j DROP
  log "  [block] metadata service (169.254.169.254)"

  # 7. Allow everything else (public internet)
  iptables -A OUTPUT -j ACCEPT
  log "  [allow] public internet (default)"

  log "Network restrictions applied successfully."
  log "Container can only access: DNS + public internet"
}

status() {
  echo "=== OUTPUT chain (container network rules) ==="
  iptables -L OUTPUT -n -v --line-numbers 2>/dev/null
}

case "${1:-apply}" in
  apply)  apply ;;
  status) status ;;
  *)      echo "Usage: $0 [apply|status]"; exit 1 ;;
esac
