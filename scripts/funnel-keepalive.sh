#!/usr/bin/env bash
# Keep Tailscale Funnel external route warm by periodically hitting endpoints
# via the public Funnel IP (not the internal VPN IP).
#
# Without --doh-url, curl resolves to 100.x.x.x (Tailscale VPN) which bypasses
# the Funnel path entirely. Using DNS-over-HTTPS forces resolution to the public
# Funnel IP (e.g. 103.x.x.x), keeping the DERP relay TLS session alive.
#
# On consecutive failures, auto-restarts tailscaled to recover from stale TLS
# or DERP relay state.
#
# Run via cron every 2 minutes.

LOG="/tmp/funnel-keepalive.log"
FAIL_COUNT_FILE="/tmp/funnel-keepalive-fails"
MAX_CONSECUTIVE_FAILS=3

# DoH providers with fallback
DOH_PROVIDERS=(
  "https://dns.google/dns-query"
  "https://cloudflare-dns.com/dns-query"
  "https://dns.quad9.net/dns-query"
)

URLS=(
  "https://pi5.tail17c60.ts.net/health"
  "https://pi5.tail17c60.ts.net:8443/"
)

try_keepalive() {
  local url="$1"
  for doh in "${DOH_PROVIDERS[@]}"; do
    code=$(curl -sf --max-time 10 --doh-url "$doh" -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
    if [ "$code" = "200" ]; then
      return 0
    fi
  done
  return 1
}

all_ok=true
for url in "${URLS[@]}"; do
  if ! try_keepalive "$url"; then
    echo "$(date -Iseconds) FAIL ${url} (all DoH providers)" >> "$LOG"
    all_ok=false
  fi
done

if $all_ok; then
  # Reset fail counter on success
  rm -f "$FAIL_COUNT_FILE"
  exit 0
fi

# Increment consecutive fail counter
prev=$(cat "$FAIL_COUNT_FILE" 2>/dev/null || echo 0)
count=$((prev + 1))
echo "$count" > "$FAIL_COUNT_FILE"

if [ "$count" -ge "$MAX_CONSECUTIVE_FAILS" ]; then
  echo "$(date -Iseconds) RESTART tailscaled after ${count} consecutive failures" >> "$LOG"
  sudo systemctl restart tailscaled
  rm -f "$FAIL_COUNT_FILE"
  # Wait for tailscaled to come back, then re-apply funnel
  sleep 5
  tailscale funnel --bg 443 2>/dev/null
  tailscale funnel --bg --set-path=/ 8443 2>/dev/null
fi
