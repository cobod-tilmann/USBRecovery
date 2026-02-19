#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Configure eth0 with static IP using nmcli
# ============================================================

INTERFACE="eth0"
CONNECTION_NAME="eth0-static"

IP_ADDRESS="192.168.1.2/24"
GATEWAY="192.168.1.1"
DNS_SERVER="192.168.1.1"
ETH_ROUTE_METRIC="50"

log() { 
  echo "$*"; 
}

err() { 
  echo "ERROR: $*" >&2; 
}

log "Starting network configuration for $INTERFACE"

if ! systemctl is-active --quiet NetworkManager; then
  err "NetworkManager is not running"
  exit 1
fi

if nmcli -t -f NAME connection show | grep -q "^${CONNECTION_NAME}$"; then
  log "Deleting existing connection: $CONNECTION_NAME"
  nmcli connection delete "$CONNECTION_NAME"
fi

log "Creating connection: $CONNECTION_NAME ($IP_ADDRESS gw $GATEWAY dns $DNS_SERVER)"
nmcli connection add \
  type ethernet \
  ifname "$INTERFACE" \
  con-name "$CONNECTION_NAME" \
  ipv4.method manual \
  ipv4.addresses "$IP_ADDRESS" \
  ipv4.gateway "$GATEWAY" \
  ipv4.dns "$DNS_SERVER" \
  ipv4.route-metric "$ETH_ROUTE_METRIC" \
  connection.autoconnect-priority 100 \
  autoconnect yes

if [[ -r "/sys/class/net/$INTERFACE/carrier" ]] && [[ "$(cat "/sys/class/net/$INTERFACE/carrier")" == "1" ]]; then
  log "Carrier detected on $INTERFACE; bringing connection up: $CONNECTION_NAME"
  nmcli connection up "$CONNECTION_NAME"
else
  log "No carrier on $INTERFACE; keeping profile for autoconnect when cable is plugged."
  nmcli connection down "$CONNECTION_NAME" >/dev/null 2>&1 || true
fi

log "Done. Device status:"
nmcli device show "$INTERFACE"
