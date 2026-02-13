#!/bin/bash
# collect-host-metrics.sh - Collect host CPU/Memory/Disk/Temperature metrics
# Run via crontab: */5 * * * * /home/masaru/soul/scripts/collect-host-metrics.sh

set -euo pipefail

METRICS_FILE="/home/masaru/soul/shared/host_metrics/metrics.json"
MAX_ENTRIES=864  # 72h at 5-min intervals
TMP_FILE="${METRICS_FILE}.tmp"

# --- CPU usage (1-second delta from /proc/stat) ---
read_cpu() {
  awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat
}

cpu_before=$(read_cpu)
sleep 1
cpu_after=$(read_cpu)

cpu_total_before=$(echo "$cpu_before" | awk '{print $1}')
cpu_idle_before=$(echo "$cpu_before" | awk '{print $2}')
cpu_total_after=$(echo "$cpu_after" | awk '{print $1}')
cpu_idle_after=$(echo "$cpu_after" | awk '{print $2}')

cpu_delta_total=$((cpu_total_after - cpu_total_before))
cpu_delta_idle=$((cpu_idle_after - cpu_idle_before))

if [ "$cpu_delta_total" -gt 0 ]; then
  cpu_pct=$(awk "BEGIN{printf \"%.1f\", 100*(1-${cpu_delta_idle}/${cpu_delta_total})}")
else
  cpu_pct="0.0"
fi

# --- Memory from /proc/meminfo ---
mem_total=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
mem_available=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
mem_used=$((mem_total - mem_available))

if [ "$mem_total" -gt 0 ]; then
  mem_pct=$(awk "BEGIN{printf \"%.1f\", 100*${mem_used}/${mem_total}}")
else
  mem_pct="0.0"
fi

mem_total_mb=$((mem_total / 1024))
mem_used_mb=$((mem_used / 1024))

# --- Disk usage ---
disk_info=$(df / | awk 'NR==2{print $3, $2, $5}')
disk_used_kb=$(echo "$disk_info" | awk '{print $1}')
disk_total_kb=$(echo "$disk_info" | awk '{print $2}')
disk_pct_raw=$(echo "$disk_info" | awk '{print $3}')
disk_pct="${disk_pct_raw%\%}"

disk_total_gb=$(awk "BEGIN{printf \"%.1f\", ${disk_total_kb}/1048576}")
disk_used_gb=$(awk "BEGIN{printf \"%.1f\", ${disk_used_kb}/1048576}")

# --- Temperature ---
temp_raw=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo "0")
temp_c=$(awk "BEGIN{printf \"%.1f\", ${temp_raw}/1000}")

# --- Build JSON entry ---
timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

new_entry=$(jq -n \
  --arg ts "$timestamp" \
  --argjson cpu "$cpu_pct" \
  --argjson mem_pct "$mem_pct" \
  --argjson mem_used "$mem_used_mb" \
  --argjson mem_total "$mem_total_mb" \
  --argjson disk_pct "$disk_pct" \
  --arg disk_used "$disk_used_gb" \
  --arg disk_total "$disk_total_gb" \
  --argjson temp "$temp_c" \
  '{timestamp:$ts, cpu:$cpu, mem_pct:$mem_pct, mem_used_mb:$mem_used, mem_total_mb:$mem_total, disk_pct:$disk_pct, disk_used_gb:$disk_used, disk_total_gb:$disk_total, temp:$temp}')

# --- Atomic append to rolling array ---
if [ -f "$METRICS_FILE" ]; then
  jq --argjson entry "$new_entry" --argjson max "$MAX_ENTRIES" \
    '(. + [$entry]) | .[-$max:]' "$METRICS_FILE" > "$TMP_FILE"
else
  echo "[$new_entry]" | jq '.' > "$TMP_FILE"
fi

mv "$TMP_FILE" "$METRICS_FILE"
