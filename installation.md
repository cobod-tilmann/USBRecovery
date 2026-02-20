# USB Recovery Installation Guide (Signed Checksum Manifest)

This setup wires:

- `udev` USB partition insert event
- `systemd` template unit `usb-recovery@.service`
- host handler `/usr/local/sbin/usb-recovery.sh`

The handler validates USB label + signed checksum manifest, then runs `scripts/RECOVERY.sh` via `/bin/bash`.

## 1) Host requirements (Pi)

Required tools:

- `util-linux` (`blkid`, `findmnt`)
- `sha256sum` (usually from `coreutils`)
- `minisign`

Check:

```bash
which blkid
which sha256sum
which minisign
```

## 2) USB contents

Required files:

```text
scripts/
  RECOVERY.sh
  manifest.sha256
  manifest.sha256.minisig
  modules/
```

Manifest format (`scripts/manifest.sha256`):

- text lines in sha256sum format: `<64hex><two spaces><relative path>`
- comments allowed using `#`
- allowed paths:
  - `scripts/RECOVERY.sh`
  - `scripts/modules/*.sh`

Example:

```text
# USBRECOVERY-MANIFEST-V1
196c589a3d37870c071465494a7b84e19f0543d73d998d0e07705c27473756a4  scripts/RECOVERY.sh
6a5763ba3869c8115b23b775e5d379d7bbd4392edaef45fe9ed47d48e6896171  scripts/modules/list_interfaces.sh
```

## 3) Public key on Pi

Pi verification key path:

`/etc/usb-recovery/cobod_recovery.pub`

Only public key is deployed to Pi. Keep private key offline.

## 4) Preferred installation (offline-friendly)

Installer:

`installation script/install_usb_recovery.sh`

Run from repo root:

```bash
sudo bash "installation script/install_usb_recovery.sh"
```

Installer preflight checks (before writing system files):

1. root privileges
2. minisign availability (or local `minisign_*.deb` package)
3. runtime tool `sha256sum`
4. public key availability (`/etc/usb-recovery/cobod_recovery.pub` or local `cobod_recovery.pub` next to installer)

Minisign behavior:

- installed already: continue
- one local `minisign_*.deb`: install automatically
- multiple local `minisign_*.deb`: prompt selection
- none: abort (no online fallback)

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

## 6) Signed package generation

Use helper script:

```bash
bash "installation script/generate_manifest_and_sign.sh"
```

Interactive quick steps:

1. run the command
2. enter package root (directory that contains `scripts/`; usually `USB drive structure`)
3. enter secret key path
4. optionally enter pubkey path for immediate verification
5. confirm overwrite if prompted

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

## 7) Manual package signing (without helper script)

Generate keys once:

```bash
minisign -G -p cobod_recovery.pub -s cobod_recovery.key
```

Build manifest:

```bash
shopt -s nullglob
MODULE_FILES=(scripts/modules/*.sh)
shopt -u nullglob
{
  echo "# USBRECOVERY-MANIFEST-V1"
  sha256sum scripts/RECOVERY.sh "${MODULE_FILES[@]}"
} > scripts/manifest.sha256
```

Sign manifest:

```bash
minisign -S -s cobod_recovery.key -m scripts/manifest.sha256 -x scripts/manifest.sha256.minisig
```

Copy to USB:

- `scripts/RECOVERY.sh`
- `scripts/modules/*.sh`
- `scripts/manifest.sha256`
- `scripts/manifest.sha256.minisig`

## 8) Runtime behavior summary

On USB insert, handler performs:

1. verify partition name pattern (`/dev/sdXn`)
2. verify USB label is `RECOVERYKEY`
3. mount USB (reuse automount or retry rw mount)
4. verify minisign signature of `scripts/manifest.sha256`
5. parse/validate each manifest line and enforce path policy
6. verify hash of `scripts/RECOVERY.sh`
7. verify hash of every `scripts/modules/*.sh` and enforce coverage
8. execute `/bin/bash <mount>/scripts/RECOVERY.sh`
9. write structured START/END + script output to:
   - `/var/log/usb-recovery.log`
   - `scripts/output/pi-recovery.log`
10. sync and unmount if handler mounted device
