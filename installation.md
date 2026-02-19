# Installation guide for auto-detect USB and execute script function:

## PART 1 — Install Required Tools

Most systems already have these, but verify:

```
sudo apt update
sudo apt install util-linux
```

`blkid` (used for label detection) is part of `util-linux`.

Check:

`which blkid`

It should return something like:

`/usr/sbin/blkid`


## PART 2 — Create the Recovery Script
Create the script file

`sudo nano /usr/local/sbin/usb-recovery.sh`

Paste the full script, Save and exit.

``` bash
#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# USB Recovery Handler (udev/systemd triggered)
#
# Purpose:
#   Automatically detect an approved USB recovery stick and execute a recovery
#   script stored on it.
#
# Designed for Windows-prepared USB sticks (FAT32/exFAT):
#   - No reliance on Linux executable permissions
#   - Validation via volume label + token file content
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

# Required USB filesystem label (set in Windows formatting / rename step)
EXPECTED_USB_LABEL="RECOVERYKEY"

# Mount location on the Raspberry Pi
MOUNT_POINT="/mnt/usb-recovery"

# Recovery script location on the USB stick (relative to USB root)
TARGET_DIR="scripts"
TARGET_FILE="RECOVERY.sh"

# Token file used as an additional authorization gate
TOKEN_RELATIVE_PATH="scripts/COBOD_TOKEN.txt"
EXPECTED_TOKEN_CONTENT="COBOD_RECOVERY_OK_v1"

# Log files
PI_LOG_FILE="/var/log/usb-recovery.log"
USB_LOG_RELATIVE_PATH="scripts/output/pi-recovery.log"


# =============================================================================
# LOGGING HELPERS
# =============================================================================

DEVNAME="${1:-}"          # Passed from udev/systemd, e.g. /dev/sda1
LOGTAG="usb-recovery"

ts() { date -Is; }

log_sys() {
  logger -t "$LOGTAG" "$*"
}

log_pi() {
  printf '%s %s\n' "$(ts)" "$*" >>"$PI_LOG_FILE"
}

log_all() {
  log_sys "$*"
  log_pi "$*"
}

log_block_start() {
  {
    echo ""
    echo "================================================================="
    echo "USB RECOVERY HANDLER START : $(ts)"
    echo "Device                   : $DEVNAME"
    echo "USB Label                : ${USB_LABEL:-N/A}"
    echo "Mount Point              : ${MOUNT_POINT:-N/A}"
    echo "Recovery Script          : ${TARGET_PATH:-N/A}"
    echo "================================================================="
  } >>"$PI_LOG_FILE"

  {
    echo ""
    echo "================================================================="
    echo "USB RECOVERY HANDLER START : $(ts)"
    echo "Device                   : $DEVNAME"
    echo "USB Label                : ${USB_LABEL:-N/A}"
    echo "Mount Point              : ${MOUNT_POINT:-N/A}"
    echo "Recovery Script          : ${TARGET_PATH:-N/A}"
    echo "================================================================="
  } >>"$USB_LOG_PATH"
}

log_block_end() {
  local rc="$1"

  {
    echo "================================================================="
    echo "USB RECOVERY HANDLER END   : $(ts)"
    echo "Exit Code                : $rc"
    echo "================================================================="
    echo ""
  } >>"$PI_LOG_FILE"

  {
    echo "================================================================="
    echo "USB RECOVERY HANDLER END   : $(ts)"
    echo "Exit Code                : $rc"
    echo "================================================================="
    echo ""
  } >>"$USB_LOG_PATH"
}


# =============================================================================
# INPUT VALIDATION
# =============================================================================

# Ensure a device was provided
if [[ -z "$DEVNAME" ]]; then
  log_all "No device passed; exiting."
  exit 0
fi

# Only handle partitions like /dev/sda1, not whole disks like /dev/sda
if [[ ! "$DEVNAME" =~ ^/dev/sd[a-z][0-9]+$ ]]; then
  log_all "Ignoring non-partition device: $DEVNAME"
  exit 0
fi


# =============================================================================
# USB LABEL VERIFICATION
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

# If already mounted somewhere (e.g. desktop automount), reuse that mountpoint
EXISTING_MNT="$(findmnt -nr -S "$DEVNAME" -o TARGET 2>/dev/null || true)"
if [[ -n "$EXISTING_MNT" ]]; then
  log_all "Device $DEVNAME is already mounted at $EXISTING_MNT; reusing it."
  MOUNT_POINT="$EXISTING_MNT"
else
  # Retry mount a few times to avoid race conditions
  MOUNT_ERR=""
  for i in 1 2 3 4 5; do
    if mount -o rw "$DEVNAME" "$MOUNT_POINT" 2>/tmp/usb-recovery-mount.err; then
      log_all "Mounted $DEVNAME at $MOUNT_POINT (rw)."
      MOUNT_ERR=""
      break
    else
      MOUNT_ERR="$(cat /tmp/usb-recovery-mount.err 2>/dev/null || true)"
      log_all "Mount attempt $i/5 failed for $DEVNAME (rw): ${MOUNT_ERR:-unknown error}"
      sleep 1
    fi
  done

  if [[ -n "$MOUNT_ERR" ]]; then
    log_all "Failed to mount $DEVNAME (rw) after retries. Last error: ${MOUNT_ERR:-unknown}"
    exit 0
  fi
fi

cleanup() {
  # Only unmount if we mounted it ourselves
  if [[ -z "${EXISTING_MNT:-}" ]]; then
    # Flush filesystem buffers (best-effort)
    sync || true

    # If still mounted, try to flush just that mount (best-effort)
    if mountpoint -q "$MOUNT_POINT"; then
      sync -f "$MOUNT_POINT" 2>/dev/null || true
    fi

    # Give the kernel/USB stack a moment to settle (helps on some sticks)
    sleep 1

    # Unmount (best-effort)
    umount "$MOUNT_POINT" 2>/dev/null || true

    # Optional: extra delay after unmount to reduce "still busy" cases
    sleep 1
  fi
}

# Run cleanup on normal exit and common termination signals
trap cleanup EXIT INT TERM


# =============================================================================
# FILE VALIDATION (RECOVERY SCRIPT + TOKEN)
# =============================================================================

TARGET_PATH="$MOUNT_POINT/$TARGET_DIR/$TARGET_FILE"
TOKEN_PATH="$MOUNT_POINT/$TOKEN_RELATIVE_PATH"
USB_LOG_PATH="$MOUNT_POINT/$USB_LOG_RELATIVE_PATH"

if [[ ! -f "$TARGET_PATH" ]]; then
  log_all "Recovery script not found: $TARGET_PATH"
  exit 0
fi

if [[ ! -f "$TOKEN_PATH" ]]; then
  log_all "Token file not found: $TOKEN_PATH"
  exit 0
fi


# =============================================================================
# TOKEN VALIDATION (CRLF-SAFE)
# =============================================================================

TOKEN_CONTENT="$(tr -d '\r\n' < "$TOKEN_PATH" 2>/dev/null || true)"

if [[ -z "$TOKEN_CONTENT" ]]; then
  log_all "Token file is empty or unreadable: $TOKEN_PATH"
  exit 1
fi

if [[ "$TOKEN_CONTENT" != "$EXPECTED_TOKEN_CONTENT" ]]; then
  log_all "Token content mismatch; refusing. (file=$TOKEN_PATH)"
  exit 1
fi

log_all "Token OK."


# =============================================================================
# EXECUTION
# =============================================================================

mkdir -p "$(dirname "$USB_LOG_PATH")" 2>/dev/null || true

# Create USB logfile if it does not exist
touch "$USB_LOG_PATH" 2>/dev/null || true

log_all "Validation complete. Starting recovery execution."

# Write structured header blocks to both log files
log_block_start

# Run recovery script and capture output to both logs
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
  exit $RC
} 2>&1 | tee -a "$PI_LOG_FILE" >>"$USB_LOG_PATH"

# Capture exit code of recovery script (from pipeline)
RC=${PIPESTATUS[0]}

# Write structured footer blocks to both log files
log_block_end "$RC"

log_all "Handler finished successfully (rc=$RC)."

exit "$RC"



```

Make it executable with 
`sudo chmod 755 /usr/local/sbin/usb-recovery.sh`


Verify with 
`ls -l /usr/local/sbin/usb-recovery.sh`


You should see:

`-rwxr-xr-x`

Alternatively use `stat usb-recovery.sh` to see the numeric permission set


## PART 3 — Create the udev Rule

This makes the script run automatically when a USB partition is added.

### Create rule file
`sudo nano /etc/udev/rules.d/99-usb-recovery.rules`


Paste:

```
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd*[0-9]", ENV{ID_BUS}=="usb", ENV{SYSTEMD_WANTS}="usb-recovery@%k.service"
```

Save and exit.

### Reload udev

```
sudo udevadm control --reload-rules
sudo udevadm trigger
```

reload:

`sudo udevadm control --reload-rules`

## PART 3.5 - Create systemd service template

Create:

`sudo nano /etc/systemd/system/usb-recovery@.service`


Paste:

``` 
[Unit]
Description=USB Recovery Service for %I
After=local-fs.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/usb-recovery.sh /dev/%I
TimeoutStartSec=5min

[Install]
WantedBy=multi-user.target
```

Save.

Reload systemd:

`sudo systemctl daemon-reload`

## PART 4 — Create Mount Directory

The script expects:

`/mnt/usb-recovery`


Create it once:

`sudo mkdir -p /mnt/usb-recovery`


Permissions:

`sudo chmod 755 /mnt/usb-recovery`

## PART 5 — Ensure Logging Location Exists

Make sure `/var/log/usb-recovery.log` can be written.

```
sudo touch /var/log/usb-recovery.log
sudo chmod 644 /var/log/usb-recovery.log
```

## PART 6 — Prepare the USB (Windows Side Requirements)

On Windows:

1. Format as FAT32 or exFAT
2. Set Volume Label: `RECOVERYKEY`


(Right-click drive → Rename, or during format)

### Folder structure:

```
\scripts\RECOVERY.sh
\scripts\COBOD_TOKEN.txt
```

### Token file content:

Inside COBOD_TOKEN.txt: (No quotes)

```
COBOD_RECOVERY_OK_v1
```

---

## System Behavior Summary

When USB is inserted:

1. udev detects USB partition
2. Script runs as root
3. Checks:
	-  Partition device format
	- Label = RECOVERYKEY
	- File exists in /scripts
	- Token content matches
4. Mounts RW
5. Executes script via bash
6. Logs to:
	- `/var/log/usb-recovery.log`
	- `\scripts\recovery.log on USB`
7. Unmounts USB
