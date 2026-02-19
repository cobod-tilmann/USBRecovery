# USBRecovery

USBRecovery is a Linux-side USB-triggered recovery runner.

When a USB partition is inserted, `udev` starts a `systemd` templated service, which runs a handler script on the host. The handler validates the device (label + token), mounts it, executes `scripts/RECOVERY.sh` from the USB via `/bin/bash`, logs everything, and unmounts when done.

## What is in this repo

- `installation.md`
  - Manual, step-by-step setup guide for dependencies, host script, udev rule, systemd service, mount path, logging, and USB prep.
- `installation script/install_usb_recovery.sh`
  - One-shot installer that writes all required host files and activates the setup.
- `USB drive structure/scripts/RECOVERY.sh`
  - USB-side recovery wrapper that runs module scripts in sequence and appends structured logs.

## Runtime architecture

1. USB partition insert event is captured by udev:
   - Rule: `ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd*[0-9]", ENV{ID_BUS}=="usb"`
2. udev requests `systemd` unit:
   - `usb-recovery@%k.service`
3. Service executes host handler:
   - `/usr/local/sbin/usb-recovery.sh /dev/%I`
4. Host handler validates and runs USB recovery:
   - Device format check (`/dev/sdXn` pattern)
   - Label check (`RECOVERYKEY`)
   - Token file existence and content check (`COBOD_RECOVERY_OK_v1`)
   - Mount handling with retry and cleanup trap
   - Executes USB script: `/bin/bash <mount>/scripts/RECOVERY.sh`

## USB-side expected structure

Minimum required files on the USB root:

```text
scripts/
  RECOVERY.sh
  COBOD_TOKEN.txt
```

Logs are written under:

```text
scripts/output/
```

The wrapper script (`RECOVERY.sh`) expects module scripts in:

```text
scripts/modules/
```

Current module execution order in `RECOVERY.sh`:

1. `netconfig_eth0_static.sh` (required)
2. `systemstatus.sh` (optional)
3. `list_interfaces.sh` (optional)

`netconfig_wlan0_new.sh` is present as a commented-out step.

## Logging behavior

Host-side handler logs to:

- Syslog/journal via `logger -t usb-recovery`
- `/var/log/usb-recovery.log`

USB-side handler log mirror:

- `scripts/output/pi-recovery.log`

USB wrapper (`RECOVERY.sh`) writes its own module execution log:

- `scripts/output/recovery_wrapper.log`

## Install options

### Option A: Automated install

Run the installer on the Linux host as root:

```bash
sudo bash "installation script/install_usb_recovery.sh"
```

It creates:

- `/usr/local/sbin/usb-recovery.sh`
- `/etc/udev/rules.d/99-usb-recovery.rules`
- `/etc/systemd/system/usb-recovery@.service`
- `/mnt/usb-recovery`
- `/var/log/usb-recovery.log`

### Option B: Manual install

Follow `installation.md` for the full manual procedure.

## Important notes

- The installer is fail-fast and aborts if target files already exist.
- Scripts are executed with `/bin/bash` (works around missing exec bits on FAT32/exFAT).
- Token validation strips CRLF/LF, so Windows-edited token files are accepted.
- The expected USB volume label is `RECOVERYKEY`.
