#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Configure eth0 with static IP using nmcli
# ============================================================

log() { echo "$*"; }


log "current interface status:"
ifconfig

log "current nmcli devcice config:"
nmcli device show