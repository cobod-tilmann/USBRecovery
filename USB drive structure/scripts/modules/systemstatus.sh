#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# log a system status snapshot
# ============================================================

log() { echo "$*"; }

log "Collecting system status"

CURRENT_TIME="$(date -Is)"
HOSTNAME="$(hostname)"
UPTIME="$(uptime -p)"
LOAD_AVG="$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
MEMORY_USAGE="$(free -h | awk '/Mem:/ {print $3 " used / " $2}')"
DISK_USAGE="$(df -h / | awk 'NR==2 {print $3 " used / " $2 " (" $5 ")"}')"



log "Timestamp: $CURRENT_TIME"
log "Hostname:  $HOSTNAME"
log "Uptime:    $UPTIME"
log "Load avg:  $LOAD_AVG"
log "Memory:    $MEMORY_USAGE"
log "Disk:      $DISK_USAGE"

if [[ -f /sys/class/thermal/thermal_zone0/temp ]]; then
  RAW="$(cat /sys/class/thermal/thermal_zone0/temp)"
  TEMP="$(awk "BEGIN {printf \"%.1f\", $RAW/1000}")"
  log "CPU temp:  ${TEMP}°C"
else
  log "CPU temp:  N/A"
fi

log "System status done"
