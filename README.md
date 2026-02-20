# USBRecovery

USBRecovery is a Raspberry Pi USB-triggered recovery runner.

When a USB partition is inserted, `udev` starts a `systemd` oneshot unit that runs `/usr/local/sbin/usb-recovery.sh`. The handler validates a signed recovery package and executes `scripts/RECOVERY.sh` with `/bin/bash`.

## Delivery model

Technicians copy a single file to USB root:

- `RECOVERYPACKAGE.COBOD`

`RECOVERYPACKAGE.COBOD` is a plain tar archive that includes:

- `scripts/RECOVERY.sh`
- `scripts/modules/*.sh`
- `scripts/manifest.sha256`
- `scripts/manifest.sha256.minisig`

## Security model

The handler executes recovery only if all checks pass:

1. USB label matches `RECOVERYKEY`
2. package archive path/content safety checks pass
3. `scripts/manifest.sha256` signature verifies against `/etc/usb-recovery/cobod_recovery.pub`
4. manifest entries follow strict path policy (`scripts/RECOVERY.sh`, `scripts/modules/*.sh`)
5. `RECOVERY.sh` hash matches manifest
6. all module hashes match manifest with strict coverage (no missing/stale entries)

## Logging

- Syslog/journal via `logger -t usb-recovery`
- Pi log: `/var/log/usb-recovery.log`
- USB run log at USB root: `RECOVERY.YYYYMMDD.HH-MM-SS.log` (new file each run)
- Recovery wrapper log content is appended into the same USB run log

## Install (offline-friendly)

Installer: `installation script/install_usb_recovery.sh`

Before running installer:

- place `cobod_recovery.pub` next to installer (unless already at `/etc/usb-recovery/cobod_recovery.pub`)
- ensure `minisign` is installed, or place one or more `minisign_*.deb` files next to installer
- ensure `sha256sum`, `tar`, and `mktemp` are available on Pi

Run:

```bash
sudo bash "installation script/install_usb_recovery.sh"
```

Minisign installer behavior:

- installed already: continue
- one local package: install via `dpkg -i`
- multiple local packages: prompt to choose
- none: abort before making changes

## Build/sign package

Use helper script:

```bash
bash "installation script/generate_manifest_and_sign.sh"
```

Typical flow:

1. set package root (usually `USB drive structure`)
2. provide private key path
3. optionally verify with pubkey
4. script outputs `RECOVERYPACKAGE.COBOD`
5. copy that single file to USB root

CI example:

```bash
bash "installation script/generate_manifest_and_sign.sh" \
  --ci --force \
  --root "USB drive structure" \
  --key ./cobod_recovery.key \
  --pubkey ./cobod_recovery.pub \
  --verify
```

Detailed guide:

- `installation script/generate_manifest_and_sign.md`
