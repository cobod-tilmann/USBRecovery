# USB Recovery Installation Guide (Single-File Package)

This setup wires:

- `udev` USB partition insert event
- `systemd` template unit `usb-recovery@.service`
- host handler `/usr/local/sbin/usb-recovery.sh`

The handler validates and extracts a signed recovery package from USB, then runs `scripts/RECOVERY.sh`.

## 1) Host requirements (Pi)

Required tools:

- `util-linux` (`blkid`, `findmnt`)
- `sha256sum` (`coreutils`)
- `minisign`
- `tar`
- `mktemp`

Check:

```bash
which blkid
which sha256sum
which minisign
which tar
which mktemp
```

## 2) USB contents

Copy one file to USB root:

- `RECOVERYPACKAGE.COBOD`

At runtime, the handler writes one timestamped log file to USB root per run:

- `RECOVERY.YYYYMMDD.HH-MM-SS.log`

`RECOVERYPACKAGE.COBOD` is a tar archive containing:

- `scripts/RECOVERY.sh`
- `scripts/modules/*.sh`
- `scripts/manifest.sha256`
- `scripts/manifest.sha256.minisig`

## 3) Public key on Pi

Pi verifies signatures with:

`/etc/usb-recovery/cobod_recovery.pub`

Only the public key is deployed to Pi. Private key stays offline.

## 4) Preferred installation (offline-friendly)

Installer:

`installation script/install_usb_recovery.sh`

Run as root:

```bash
sudo bash "installation script/install_usb_recovery.sh"
```

Installer preflight checks (before any writes):

1. root privileges
2. minisign available (or local `minisign_*.deb`)
3. runtime tools available (`sha256sum`, `tar`, `mktemp`)
4. public key available (`/etc/usb-recovery/cobod_recovery.pub` or local `cobod_recovery.pub` next to installer)

Minisign handling:

- already installed: continue
- one local package: install automatically
- multiple local packages: prompt for selection
- none: abort

Files created:

- `/usr/local/sbin/usb-recovery.sh`
- `/etc/udev/rules.d/99-usb-recovery.rules`
- `/etc/systemd/system/usb-recovery@.service`
- `/mnt/usb-recovery`
- `/var/log/usb-recovery.log`
- `/etc/usb-recovery/cobod_recovery.pub` (copied from installer dir if missing)

## 5) Manual wiring (if not using installer)

Create udev rule `/etc/udev/rules.d/99-usb-recovery.rules`:

```text
ACTION=="add", SUBSYSTEM=="block", KERNEL=="sd*[0-9]", ENV{ID_BUS}=="usb", ENV{SYSTEMD_WANTS}="usb-recovery@%k.service"
```

Reload udev:

```bash
sudo udevadm control --reload-rules
sudo udevadm trigger
```

Create systemd template `/etc/systemd/system/usb-recovery@.service`:

```ini
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

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Prepare mount and logs:

```bash
sudo mkdir -p /mnt/usb-recovery
sudo chmod 755 /mnt/usb-recovery

sudo touch /var/log/usb-recovery.log
sudo chmod 644 /var/log/usb-recovery.log

sudo mkdir -p /etc/usb-recovery
sudo chmod 755 /etc/usb-recovery
sudo install -m 644 cobod_recovery.pub /etc/usb-recovery/cobod_recovery.pub
```

## 6) Build and sign the package

Use helper script:

```bash
bash "installation script/generate_manifest_and_sign.sh"
```

Interactive quick steps:

1. run command above
2. set package root (directory containing `scripts/`, usually `USB drive structure`)
3. enter private key path
4. optionally provide pubkey for immediate verification
5. confirm overwrite if prompted

Result: `RECOVERYPACKAGE.COBOD` in package root.

Copy only that file to USB root.

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

## 7) Runtime behavior summary

On USB insert, handler:

1. verifies device pattern (`/dev/sdXn`)
2. verifies label is `RECOVERYKEY`
3. mounts USB (reuse automount or retry rw mount)
4. finds `RECOVERYPACKAGE.COBOD`
5. validates archive entries for safety, then extracts to temp dir
6. verifies manifest signature with minisign + Pi public key
7. verifies script/module hashes and strict module coverage
8. executes extracted `/bin/bash scripts/RECOVERY.sh`
9. writes structured START/END and script output to:
   - `/var/log/usb-recovery.log`
   - `RECOVERY.YYYYMMDD.HH-MM-SS.log` on USB root
10. cleans temp dir, syncs, and unmounts if handler mounted device
