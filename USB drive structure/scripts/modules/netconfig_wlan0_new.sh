#!/usr/bin/env bash
set -euo pipefail

WIFI_IF="wlan0"
CON_NAME="wifi-backup"
SSID="YOUR_SSID"
PSK="YOUR_PASSWORD"
WIFI_METRIC="600"
CONNECT_TIMEOUT_SEC="120"
POLL_INTERVAL_SEC="2"

log() { echo "$*"; }
err() { echo "ERROR: $*" >&2; }

if ! systemctl is-active --quiet NetworkManager; then
    err "NetworkManager is not running"
    exit 1
fi

if nmcli -t -f NAME connection show | grep -qx "$CON_NAME"; then
    log "Deleting existing Wi-Fi profile: $CON_NAME"
    nmcli connection delete "$CON_NAME"
fi

log "Creating Wi-Fi profile: $CON_NAME (ssid=$SSID)"
nmcli connection add type wifi \
    ifname "$WIFI_IF" \
    con-name "$CON_NAME" \
    ssid "$SSID"

nmcli connection modify "$CON_NAME" \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$PSK" \
    connection.interface-name "$WIFI_IF" \
    connection.autoconnect yes \
    connection.autoconnect-priority 10 \
    ipv4.method auto \
    ipv4.route-metric "$WIFI_METRIC"

log "Bringing connection up: $CON_NAME"
if ! nmcli connection up "$CON_NAME"; then
    log "Initial activation command returned non-zero; continuing to wait for activation."
fi

log "Waiting up to ${CONNECT_TIMEOUT_SEC}s for '$CON_NAME' on $WIFI_IF to become active..."
elapsed=0
while (( elapsed < CONNECT_TIMEOUT_SEC )); do
    if nmcli -t -f NAME,DEVICE connection show --active | awk -F: -v n="$CON_NAME" -v d="$WIFI_IF" '$1==n && $2==d {found=1} END {exit !found}'; then
        log "Wi-Fi connection '$CON_NAME' is active on $WIFI_IF after ${elapsed}s."
        log "Wi-Fi profile '$CON_NAME' configured on $WIFI_IF."
        exit 0
    fi
    sleep "$POLL_INTERVAL_SEC"
    elapsed=$((elapsed + POLL_INTERVAL_SEC))
done

err "Timed out after ${CONNECT_TIMEOUT_SEC}s waiting for '$CON_NAME' to become active on $WIFI_IF."
nmcli -f DEVICE,TYPE,STATE,CONNECTION device status || true
exit 1
