#!/usr/bin/env bash
# script: install_usb_recovery.sh
# purpose: install and set up auto-detect recovery system
set -euo pipefail

# ===== CONFIGURATION =====
PISCRIPTPATH="/usr/local/sbin/usb-recovery.sh"
UDEVRULEPATH="/etc/udev/rules.d/99-usb-recovery.rules"
SERVICEPATH="/etc/systemd/system/usb-recovery@.service"
USBMOUNTDIR="/mnt/usb-recovery"
LOGFILEPATH="/var/log/usb-recovery.log"

PUBKEYDIR="/etc/usb-recovery"
PUBKEYPATH="$PUBKEYDIR/cobod_recovery.pub"

INSTALLER_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_PUBKEY_PATH="$INSTALLER_DIR/cobod_recovery.pub"

check_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    echo "ERROR: This installer must be run as root."
    echo "Run: sudo bash $0"
    exit 1
  fi
}

choose_minisign_package() {
  local packages=()
  local choice=""
  local idx=""

  shopt -s nullglob
  packages=("$INSTALLER_DIR"/minisign_*.deb)
  shopt -u nullglob

  if [[ "${#packages[@]}" -eq 0 ]]; then
    echo "ERROR: minisign is not installed and no local package was found." >&2
    echo "Expected file pattern in installer directory: minisign_*.deb" >&2
    echo "Directory checked: $INSTALLER_DIR" >&2
    exit 1
  fi

  if [[ "${#packages[@]}" -eq 1 ]]; then
    printf '%s\n' "${packages[0]}"
    return 0
  fi

  if [[ ! -t 0 ]]; then
    echo "ERROR: Multiple minisign packages found, but installer is not interactive." >&2
    echo "Keep only one minisign_*.deb in: $INSTALLER_DIR" >&2
    exit 1
  fi

  echo "Multiple minisign packages found. Select one to install:" >&2
  for idx in "${!packages[@]}"; do
    printf '  %d) %s\n' "$((idx + 1))" "$(basename "${packages[$idx]}")" >&2
  done

  while true; do
    printf 'Enter selection [1-%d]: ' "${#packages[@]}" >&2
    read -r choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#packages[@]} )); then
      printf '%s\n' "${packages[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid selection. Try again." >&2
  done
}

ensure_minisign() {
  local pkg_path=""

  if command -v minisign >/dev/null 2>&1; then
    echo "minisign already installed"
    return 0
  fi

  pkg_path="$(choose_minisign_package)"
  echo "Installing minisign from local package: $(basename "$pkg_path")"

  if ! dpkg -i "$pkg_path"; then
    echo "ERROR: Failed to install minisign package: $pkg_path"
    echo "Resolve package dependency issues and run installer again."
    exit 1
  fi

  if ! command -v minisign >/dev/null 2>&1; then
    echo "ERROR: minisign still not available after package install."
    exit 1
  fi

  echo "minisign installation verified"
}

ensure_pubkey_available() {
  if [[ -r "$PUBKEYPATH" ]]; then
    echo "public key already present at $PUBKEYPATH"
    return 0
  fi

  if [[ ! -r "$LOCAL_PUBKEY_PATH" ]]; then
    echo "ERROR: Public key not found."
    echo "Expected either:"
    echo "  - Existing key on host: $PUBKEYPATH"
    echo "  - Local key next to installer: $LOCAL_PUBKEY_PATH"
    exit 1
  fi

  echo "public key found next to installer"
}

ensure_runtime_dependencies() {
  if ! command -v sha256sum >/dev/null 2>&1; then
    echo "ERROR: sha256sum is required on the Pi for hash verification."
    echo "Install coreutils and run installer again."
    exit 1
  fi
}

check_existing_paths() {
  if [[ -e "$PISCRIPTPATH" ]]; then
    echo "ERROR: $PISCRIPTPATH already exists. Aborting installation"
    exit 1
  fi

  if [[ -e "$UDEVRULEPATH" ]]; then
    echo "ERROR: $UDEVRULEPATH already exists. Aborting installation"
    exit 1
  fi

  if [[ -e "$SERVICEPATH" ]]; then
    echo "ERROR: $SERVICEPATH already exists. Aborting installation"
    exit 1
  fi

  if [[ -e "$LOGFILEPATH" ]]; then
    echo "ERROR: $LOGFILEPATH already exists. Aborting installation"
    exit 1
  fi
}

install_handler_script() {
  cat << 'EOF_HANDLER' > "$PISCRIPTPATH"
#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# USB Recovery Handler (udev/systemd triggered)
#
# Purpose:
#   Automatically detect an approved USB recovery stick and execute a signed
#   recovery script stored on it.
#
# Security gates:
#   A) Volume label match
#   B) minisign verifies manifest signature with Pi-stored public key
#   C) Signed manifest format + path policy validation
#   D) Referenced recovery script hash matches manifest
#   E) All module hashes in scripts/modules are validated + full coverage check
#
# Designed for Windows-prepared USB sticks (FAT32/exFAT):
#   - No reliance on Linux executable permissions
#   - Recovery script executed explicitly using /bin/bash
#
# Logging:
#   - Logs operational events to syslog/journal
#   - Logs events to a persistent Pi logfile
#   - Captures recovery script output to both Pi and USB logfile
# =============================================================================

# =============================================================================
# CONFIGURATION
# =============================================================================

EXPECTED_USB_LABEL="RECOVERYKEY"
MOUNT_POINT="/mnt/usb-recovery"

EXPECTED_SCRIPT_RELATIVE_PATH="scripts/RECOVERY.sh"
EXPECTED_MODULES_DIR_RELATIVE_PATH="scripts/modules"
MANIFEST_RELATIVE_PATH="scripts/manifest.sha256"
MANIFEST_SIG_RELATIVE_PATH="scripts/manifest.sha256.minisig"

PUBKEY_PATH="/etc/usb-recovery/cobod_recovery.pub"

PI_LOG_FILE="/var/log/usb-recovery.log"
USB_LOG_RELATIVE_PATH="scripts/output/pi-recovery.log"
MOUNT_ERR_FILE="/tmp/usb-recovery-mount.err"

# =============================================================================
# RUNTIME STATE
# =============================================================================

DEVNAME="${1:-}"
LOGTAG="usb-recovery"

USB_LABEL="N/A"
TARGET_PATH="N/A"
MANIFEST_PATH="N/A"
MANIFEST_SIG_PATH="N/A"
USB_LOG_PATH=""

EXISTING_MNT=""
MOUNTED_BY_HANDLER="false"

START_LOGGED="false"
END_LOGGED="false"

MANIFEST_SIG_STATUS="NOT_RUN"
MANIFEST_CONTENT_STATUS="NOT_RUN"
SCRIPT_HASH_STATUS="NOT_RUN"
MODULE_HASH_STATUS="NOT_RUN"

ts() { date -Is; }

log_sys() {
  logger -t "$LOGTAG" "$*"
}

log_pi() {
  printf '%s %s\n' "$(ts)" "$*" >>"$PI_LOG_FILE"
}

log_usb() {
  if [[ -n "$USB_LOG_PATH" ]]; then
    printf '%s %s\n' "$(ts)" "$*" >>"$USB_LOG_PATH" 2>/dev/null || true
  fi
}

log_all() {
  log_sys "$*"
  log_pi "$*"
  log_usb "$*"
}

log_block_start() {
  {
    echo ""
    echo "================================================================="
    echo "USB RECOVERY HANDLER START : $(ts)"
    echo "Device                   : $DEVNAME"
    echo "USB Label                : ${USB_LABEL:-N/A}"
    echo "Mount Point              : ${MOUNT_POINT:-N/A}"
    echo "Manifest Signature       : ${MANIFEST_SIG_STATUS:-N/A}"
    echo "Manifest Content         : ${MANIFEST_CONTENT_STATUS:-N/A}"
    echo "Script Hash              : ${SCRIPT_HASH_STATUS:-N/A}"
    echo "Module Hashes            : ${MODULE_HASH_STATUS:-N/A}"
    echo "Recovery Script          : ${TARGET_PATH:-N/A}"
    echo "================================================================="
  } >>"$PI_LOG_FILE"

  if [[ -n "$USB_LOG_PATH" ]]; then
    {
      echo ""
      echo "================================================================="
      echo "USB RECOVERY HANDLER START : $(ts)"
      echo "Device                   : $DEVNAME"
      echo "USB Label                : ${USB_LABEL:-N/A}"
      echo "Mount Point              : ${MOUNT_POINT:-N/A}"
      echo "Manifest Signature       : ${MANIFEST_SIG_STATUS:-N/A}"
      echo "Manifest Content         : ${MANIFEST_CONTENT_STATUS:-N/A}"
      echo "Script Hash              : ${SCRIPT_HASH_STATUS:-N/A}"
      echo "Module Hashes            : ${MODULE_HASH_STATUS:-N/A}"
      echo "Recovery Script          : ${TARGET_PATH:-N/A}"
      echo "================================================================="
    } >>"$USB_LOG_PATH" 2>/dev/null || true
  fi

  log_sys "START device=$DEVNAME label=${USB_LABEL:-N/A} mount=${MOUNT_POINT:-N/A} manifest_sig=$MANIFEST_SIG_STATUS manifest_content=$MANIFEST_CONTENT_STATUS script_hash=$SCRIPT_HASH_STATUS module_hash=$MODULE_HASH_STATUS script=${TARGET_PATH:-N/A}"
  START_LOGGED="true"
}

log_block_end() {
  local rc="$1"

  {
    echo "================================================================="
    echo "USB RECOVERY HANDLER END   : $(ts)"
    echo "Manifest Signature       : ${MANIFEST_SIG_STATUS:-N/A}"
    echo "Manifest Content         : ${MANIFEST_CONTENT_STATUS:-N/A}"
    echo "Script Hash              : ${SCRIPT_HASH_STATUS:-N/A}"
    echo "Module Hashes            : ${MODULE_HASH_STATUS:-N/A}"
    echo "Exit Code                : $rc"
    echo "================================================================="
    echo ""
  } >>"$PI_LOG_FILE"

  if [[ -n "$USB_LOG_PATH" ]]; then
    {
      echo "================================================================="
      echo "USB RECOVERY HANDLER END   : $(ts)"
      echo "Manifest Signature       : ${MANIFEST_SIG_STATUS:-N/A}"
      echo "Manifest Content         : ${MANIFEST_CONTENT_STATUS:-N/A}"
      echo "Script Hash              : ${SCRIPT_HASH_STATUS:-N/A}"
      echo "Module Hashes            : ${MODULE_HASH_STATUS:-N/A}"
      echo "Exit Code                : $rc"
      echo "================================================================="
      echo ""
    } >>"$USB_LOG_PATH" 2>/dev/null || true
  fi

  log_sys "END rc=$rc device=$DEVNAME label=${USB_LABEL:-N/A} mount=${MOUNT_POINT:-N/A} manifest_sig=$MANIFEST_SIG_STATUS manifest_content=$MANIFEST_CONTENT_STATUS script_hash=$SCRIPT_HASH_STATUS module_hash=$MODULE_HASH_STATUS"
  END_LOGGED="true"
}

cleanup_mount() {
  if [[ "$MOUNTED_BY_HANDLER" == "true" ]]; then
    sync || true
    if mountpoint -q "$MOUNT_POINT"; then
      sync -f "$MOUNT_POINT" 2>/dev/null || true
      sleep 1
      umount "$MOUNT_POINT" 2>/dev/null || true
      sleep 1
    fi
  fi
}

on_exit() {
  local rc="$?"

  if [[ "$START_LOGGED" == "true" && "$END_LOGGED" != "true" ]]; then
    log_block_end "$rc"
  fi

  cleanup_mount
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

exit_with() {
  local rc="$1"
  shift || true
  if [[ "$#" -gt 0 ]]; then
    log_all "$*"
  fi
  exit "$rc"
}

# =============================================================================
# INPUT VALIDATION
# =============================================================================

if [[ -z "$DEVNAME" ]]; then
  log_all "No device passed; exiting."
  exit 0
fi

if [[ ! "$DEVNAME" =~ ^/dev/sd[a-z][0-9]+$ ]]; then
  log_all "Ignoring non-partition device: $DEVNAME"
  exit 0
fi

# =============================================================================
# GATE A - USB LABEL VERIFICATION
# =============================================================================

USB_LABEL="$(blkid -o value -s LABEL "$DEVNAME" 2>/dev/null || true)"

if [[ -z "$USB_LABEL" ]]; then
  log_all "No filesystem label found on $DEVNAME; refusing."
  exit 0
fi

if [[ "$USB_LABEL" != "$EXPECTED_USB_LABEL" ]]; then
  log_all "USB label mismatch on $DEVNAME: found '$USB_LABEL', expected '$EXPECTED_USB_LABEL'; refusing."
  exit 0
fi

log_all "USB label OK on $DEVNAME: '$USB_LABEL'"

# =============================================================================
# MOUNT HANDLING (RW, WITH AUTOMOUNT DETECTION + RETRIES)
# =============================================================================

mkdir -p "$MOUNT_POINT"

EXISTING_MNT="$(findmnt -nr -S "$DEVNAME" -o TARGET 2>/dev/null || true)"
if [[ -n "$EXISTING_MNT" ]]; then
  MOUNT_POINT="$EXISTING_MNT"
  log_all "Device $DEVNAME is already mounted at $EXISTING_MNT; reusing it."
else
  MOUNT_ERR=""
  for i in 1 2 3 4 5; do
    if mount -o rw "$DEVNAME" "$MOUNT_POINT" 2>"$MOUNT_ERR_FILE"; then
      MOUNTED_BY_HANDLER="true"
      MOUNT_ERR=""
      log_all "Mounted $DEVNAME at $MOUNT_POINT (rw)."
      break
    fi
    MOUNT_ERR="$(cat "$MOUNT_ERR_FILE" 2>/dev/null || true)"
    log_all "Mount attempt $i/5 failed for $DEVNAME (rw): ${MOUNT_ERR:-unknown error}"
    sleep 1
  done

  if [[ -n "$MOUNT_ERR" ]]; then
    exit_with 1 "Failed to mount $DEVNAME (rw) after retries. Last error: ${MOUNT_ERR:-unknown}"
  fi
fi

# =============================================================================
# FILE PATHS + USB LOG INITIALIZATION
# =============================================================================

TARGET_PATH="$MOUNT_POINT/$EXPECTED_SCRIPT_RELATIVE_PATH"
MANIFEST_PATH="$MOUNT_POINT/$MANIFEST_RELATIVE_PATH"
MANIFEST_SIG_PATH="$MOUNT_POINT/$MANIFEST_SIG_RELATIVE_PATH"
USB_LOG_PATH="$MOUNT_POINT/$USB_LOG_RELATIVE_PATH"

if ! mkdir -p "$(dirname "$USB_LOG_PATH")" 2>/dev/null; then
  USB_LOG_PATH=""
  exit_with 1 "Unable to create USB log directory under mount point."
fi

if ! touch "$USB_LOG_PATH" 2>/dev/null; then
  USB_LOG_PATH=""
  exit_with 1 "Unable to create USB log file under mount point."
fi

log_block_start

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================

if ! command -v minisign >/dev/null 2>&1; then
  MANIFEST_SIG_STATUS="FAIL_NO_MINISIGN"
  exit_with 1 "minisign is not installed on the Pi; cannot verify manifest signature."
fi

if ! command -v sha256sum >/dev/null 2>&1; then
  SCRIPT_HASH_STATUS="FAIL_NO_SHA256SUM"
  MODULE_HASH_STATUS="FAIL_NO_SHA256SUM"
  exit_with 1 "sha256sum is not available on this system."
fi

if [[ ! -r "$PUBKEY_PATH" ]]; then
  MANIFEST_SIG_STATUS="FAIL_NO_PUBKEY"
  exit_with 1 "Public key missing or unreadable: $PUBKEY_PATH"
fi

if [[ ! -f "$MANIFEST_PATH" ]]; then
  MANIFEST_SIG_STATUS="FAIL_NO_MANIFEST"
  MANIFEST_CONTENT_STATUS="FAIL_NO_MANIFEST"
  exit_with 1 "Manifest file not found: $MANIFEST_PATH"
fi

if [[ ! -f "$MANIFEST_SIG_PATH" ]]; then
  MANIFEST_SIG_STATUS="FAIL_NO_SIGNATURE"
  exit_with 1 "Manifest signature file not found: $MANIFEST_SIG_PATH"
fi

# =============================================================================
# GATE B - SIGNATURE VERIFICATION
# =============================================================================

if minisign -V -m "$MANIFEST_PATH" -x "$MANIFEST_SIG_PATH" -p "$PUBKEY_PATH" -q >/dev/null 2>&1; then
  MANIFEST_SIG_STATUS="PASS"
  log_all "Manifest signature verification: PASS"
else
  MANIFEST_SIG_STATUS="FAIL_BAD_SIGNATURE"
  exit_with 1 "Manifest signature verification failed."
fi

# =============================================================================
# GATE C - MANIFEST FORMAT + PATH POLICY
# Manifest format:
#   <sha256><two spaces><relative path>
#   # comments and blank lines allowed
# =============================================================================

declare -A manifest_hashes=()
manifest_script_hash=""

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="${raw_line%$'\r'}"

  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && continue

  if [[ ! "$line" =~ ^([A-Fa-f0-9]{64})[[:space:]][[:space:]](.+)$ ]]; then
    MANIFEST_CONTENT_STATUS="FAIL_MALFORMED_LINE"
    exit_with 1 "Manifest line is malformed: $line"
  fi

  entry_hash="${BASH_REMATCH[1],,}"
  entry_path="${BASH_REMATCH[2]}"

  if [[ "$entry_path" == "$EXPECTED_SCRIPT_RELATIVE_PATH" ]]; then
    if [[ -n "$manifest_script_hash" ]]; then
      MANIFEST_CONTENT_STATUS="FAIL_DUPLICATE_SCRIPT_ENTRY"
      exit_with 1 "Manifest has duplicate RECOVERY.sh entry."
    fi
    manifest_script_hash="$entry_hash"
    continue
  fi

  if [[ ! "$entry_path" =~ ^scripts/modules/[A-Za-z0-9._/-]+\.sh$ || "$entry_path" == *".."* ]]; then
    MANIFEST_CONTENT_STATUS="FAIL_PATH_NOT_ALLOWED"
    exit_with 1 "Manifest path is not allowed: $entry_path"
  fi

  if [[ -n "${manifest_hashes[$entry_path]+x}" ]]; then
    MANIFEST_CONTENT_STATUS="FAIL_DUPLICATE_MODULE_ENTRY"
    exit_with 1 "Manifest has duplicate module entry: $entry_path"
  fi

  manifest_hashes["$entry_path"]="$entry_hash"
done < "$MANIFEST_PATH"

if [[ -z "$manifest_script_hash" ]]; then
  MANIFEST_CONTENT_STATUS="FAIL_MISSING_SCRIPT_ENTRY"
  exit_with 1 "Manifest is missing RECOVERY.sh entry."
fi

MANIFEST_CONTENT_STATUS="PASS"

# =============================================================================
# GATE D - RECOVERY SCRIPT HASH VERIFICATION
# =============================================================================

if [[ ! -f "$TARGET_PATH" ]]; then
  SCRIPT_HASH_STATUS="FAIL_SCRIPT_NOT_FOUND"
  exit_with 1 "Recovery script not found: $TARGET_PATH"
fi

sha_line="$(sha256sum "$TARGET_PATH" 2>/dev/null || true)"
actual_sha256="${sha_line%% *}"
actual_sha256="${actual_sha256,,}"

if [[ ! "$actual_sha256" =~ ^[a-f0-9]{64}$ ]]; then
  SCRIPT_HASH_STATUS="FAIL_HASH_COMPUTE_ERROR"
  exit_with 1 "Failed to compute sha256 for: $TARGET_PATH"
fi

if [[ "$actual_sha256" != "$manifest_script_hash" ]]; then
  SCRIPT_HASH_STATUS="FAIL_HASH_MISMATCH"
  exit_with 1 "Recovery script sha256 mismatch."
fi

SCRIPT_HASH_STATUS="PASS"

# =============================================================================
# GATE E - MODULE HASH VERIFICATION + COVERAGE ENFORCEMENT
# =============================================================================

declare -A actual_module_set=()

shopt -s nullglob
for module_abs in "$MOUNT_POINT/$EXPECTED_MODULES_DIR_RELATIVE_PATH"/*.sh; do
  module_rel="${module_abs#$MOUNT_POINT/}"
  actual_module_set["$module_rel"]="1"

  if [[ -z "${manifest_hashes[$module_rel]+x}" ]]; then
    MODULE_HASH_STATUS="FAIL_MODULE_NOT_LISTED"
    shopt -u nullglob
    exit_with 1 "Module exists on USB but is not listed in manifest: $module_rel"
  fi

  module_sha_line="$(sha256sum "$module_abs" 2>/dev/null || true)"
  module_actual_sha256="${module_sha_line%% *}"
  module_actual_sha256="${module_actual_sha256,,}"
  if [[ ! "$module_actual_sha256" =~ ^[a-f0-9]{64}$ ]]; then
    MODULE_HASH_STATUS="FAIL_MODULE_HASH_COMPUTE"
    shopt -u nullglob
    exit_with 1 "Failed to compute sha256 for module: $module_rel"
  fi

  if [[ "$module_actual_sha256" != "${manifest_hashes[$module_rel]}" ]]; then
    MODULE_HASH_STATUS="FAIL_MODULE_HASH_MISMATCH"
    shopt -u nullglob
    exit_with 1 "Module sha256 mismatch for: $module_rel"
  fi
done
shopt -u nullglob

for module_rel in "${!manifest_hashes[@]}"; do
  if [[ -z "${actual_module_set[$module_rel]+x}" ]]; then
    MODULE_HASH_STATUS="FAIL_MODULE_LIST_STALE"
    exit_with 1 "Manifest lists module that is missing on USB: $module_rel"
  fi
done

MODULE_HASH_STATUS="PASS"
log_all "Manifest + script hash + module hash verification: PASS"

# =============================================================================
# EXECUTION
# =============================================================================

log_all "Validation complete. Starting recovery execution."

set +e
{
  echo ""
  echo "------------------------------------------------------------"
  echo "RECOVERY SCRIPT OUTPUT START : $(ts)"
  echo "------------------------------------------------------------"
  /bin/bash "$TARGET_PATH"
  RC=$?
  echo "------------------------------------------------------------"
  echo "RECOVERY SCRIPT OUTPUT END   : $(ts)"
  echo "Exit Code                   : $RC"
  echo "------------------------------------------------------------"
  echo ""
  exit "$RC"
} 2>&1 | tee -a "$PI_LOG_FILE" >>"$USB_LOG_PATH"
RC=${PIPESTATUS[0]}
set -e

log_all "Handler finished (rc=$RC)."
log_block_end "$RC"

exit "$RC"
EOF_HANDLER

  chmod 755 "$PISCRIPTPATH"
  echo "created script file"
}

install_udev_rule() {
  cat << 'EOF_UDEV' > "$UDEVRULEPATH"
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd*[0-9]", ENV{ID_BUS}=="usb", ENV{SYSTEMD_WANTS}="usb-recovery@%k.service"
EOF_UDEV

  udevadm control --reload-rules
  udevadm trigger
  echo "created udev rule"
}

install_systemd_service() {
  cat << 'EOF_SERVICE' > "$SERVICEPATH"
[Unit]
Description=USB Recovery Service for %I
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb-recovery.sh /dev/%I
TimeoutStartSec=5min

[Install]
WantedBy=multi-user.target
EOF_SERVICE

  systemctl daemon-reload
  echo "created service"
}

prepare_mount_dir() {
  mkdir -p "$USBMOUNTDIR"
  chmod 755 "$USBMOUNTDIR"
  echo "created mount dir"
}

prepare_log_file() {
  touch "$LOGFILEPATH"
  chmod 644 "$LOGFILEPATH"
  echo "initialised log file"
}

install_pubkey() {
  if [[ -r "$PUBKEYPATH" ]]; then
    echo "public key already present on host"
    return 0
  fi

  mkdir -p "$PUBKEYDIR"
  chmod 755 "$PUBKEYDIR"

  cp "$LOCAL_PUBKEY_PATH" "$PUBKEYPATH"
  chmod 644 "$PUBKEYPATH"
  echo "installed public key"
}

main() {
  check_root

  # Required before any installation writes
  ensure_minisign
  ensure_runtime_dependencies
  ensure_pubkey_available

  check_existing_paths
  install_handler_script
  install_udev_rule
  install_systemd_service
  prepare_mount_dir
  prepare_log_file
  install_pubkey

  echo "installation complete"
}

main "$@"
