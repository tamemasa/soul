#!/usr/bin/env bash
# Keep Tailscale Funnel external route warm by periodically hitting endpoints
# via the public Funnel IP (not the internal VPN IP).
#
# Without --doh-url, curl resolves to 100.x.x.x (Tailscale VPN) which bypasses
# the Funnel path entirely. Using DNS-over-HTTPS forces resolution to the public
# Funnel IP (e.g. 103.x.x.x), keeping the DERP relay TLS session alive.
#
# Run via cron every 2 minutes.

LOG="/tmp/funnel-keepalive.log"
DOH="--doh-url https://dns.google/dns-query"

for url in \
  "https://pi5.tail17c60.ts.net/health" \
  "https://pi5.tail17c60.ts.net:8443/"; do
  code=$(curl -sf --max-time 10 ${DOH} -o /dev/null -w "%{http_code}" "$url" 2>/dev/null)
  if [ "$code" != "200" ]; then
    echo "$(date -Iseconds) FAIL ${url} code=${code}" >> "$LOG"
  fi
done
