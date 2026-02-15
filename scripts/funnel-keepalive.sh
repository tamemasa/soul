#!/usr/bin/env bash
# Keep Tailscale Funnel WireGuard peers warm by periodically hitting the endpoints.
# Prevents idle peer reconfiguration from dropping incoming webhook connections.
# Run via cron every 2 minutes.

curl -sf --max-time 5 https://pi5.tail17c60.ts.net/health >/dev/null 2>&1
curl -sf --max-time 5 https://pi5.tail17c60.ts.net:8443/ >/dev/null 2>&1
