# USBRecovery

USBRecovery is a Raspberry Pi USB-triggered recovery runner.

When a USB partition is inserted, `udev` triggers a `systemd` oneshot unit that runs `/usr/local/sbin/usb-recovery.sh`. The handler verifies a signed checksum manifest, then runs `scripts/RECOVERY.sh` via `/bin/bash` and mirrors output to Pi and USB logs.

## Security model

The handler executes recovery only if all gates pass:

1. USB label matches `RECOVERYKEY`
2. `scripts/manifest.sha256` signature verifies with `/etc/usb-recovery/cobod_recovery.pub`
3. Manifest lines are valid and only allowed paths are present (`scripts/RECOVERY.sh`, `scripts/modules/*.sh`)
4. `scripts/RECOVERY.sh` hash matches manifest
5. Every `scripts/modules/*.sh` file hash matches manifest
6. Coverage is strict: no extra modules on USB and no stale module entries in manifest

## Expected USB structure

```text
scripts/
  RECOVERY.sh
  manifest.sha256
  manifest.sha256.minisig
  modules/
  output/
```

## Logging

- Syslog/journal via `logger -t usb-recovery`
- Pi log: `/var/log/usb-recovery.log`
- USB mirror log: `scripts/output/pi-recovery.log`
- Recovery wrapper log (from USB script): `scripts/output/recovery_wrapper.log`

## Install (offline-friendly)

Installer: `installation script/install_usb_recovery.sh`

Before running installer:

- Place `cobod_recovery.pub` next to installer (unless already at `/etc/usb-recovery/cobod_recovery.pub`)
- Ensure `minisign` is installed, or place one or more `minisign_*.deb` files in the installer directory
- Ensure `sha256sum` is available on Pi (typically from `coreutils`)

Run:

```bash
sudo bash "installation script/install_usb_recovery.sh"
```

Minisign install behavior:

- If minisign exists: continue
- If missing and one `minisign_*.deb` exists: install via `dpkg -i`
- If missing and multiple packages exist: prompt for selection
- If missing and no local package exists: abort before making changes

## Signed package creation

Use helper script (interactive + CI):

```bash
bash "installation script/generate_manifest_and_sign.sh"
```

Interactive quick guide:

1. Run the command above
2. For `Package root directory`, enter directory that contains `scripts/` (usually `USB drive structure`)
3. Provide secret key path (for example `./cobod_recovery.key`)
4. Optionally provide pubkey path for immediate verification
5. Confirm overwrite if prompted

Generated files:

- `scripts/manifest.sha256`
- `scripts/manifest.sha256.minisig`

CI example:

```bash
bash "installation script/generate_manifest_and_sign.sh" \
  --ci --force \
  --root "USB drive structure" \
  --key ./cobod_recovery.key \
  --pubkey ./cobod_recovery.pub \
  --verify
```

Detailed script guide:

- `installation script/generate_manifest_and_sign.md`

## Manual manifest creation (without helper script)

Generate keypair once (keep private key offline):

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
