# `generate_manifest_and_sign.sh` Guide

This script generates all artifacts for the single-file USB delivery model.

It creates:

- `scripts/manifest.sha256`
- `scripts/manifest.sha256.minisig`
- `RECOVERYPACKAGE.COBOD`

`RECOVERYPACKAGE.COBOD` is a plain tar archive (custom extension) that contains:

- `scripts/RECOVERY.sh`
- `scripts/modules/*.sh`
- `scripts/manifest.sha256`
- `scripts/manifest.sha256.minisig`

## Manifest format

`scripts/manifest.sha256` is sha256sum text format:

```text
# USBRECOVERY-MANIFEST-V1
<sha256>  scripts/RECOVERY.sh
<sha256>  scripts/modules/<module>.sh
```

Two spaces are required between hash and path.

## What "package root directory" means

It is the directory that contains `scripts/`.

Example in this repo:

```text
USBRecovery/
  USB drive structure/
    scripts/
      RECOVERY.sh
```

Package root is:

`USBRecovery/USB drive structure`

## Prerequisites

- `minisign`
- `tar`
- `sha256sum` (or `shasum`)
- signing key file (for example `cobod_recovery.key`)

## Interactive quick steps

1. Run:

```bash
bash "installation script/generate_manifest_and_sign.sh"
```

2. Enter package root directory.
3. Enter private key path.
4. Optionally enter pubkey path for verification.
5. Confirm overwrite when prompted.

Then copy only `RECOVERYPACKAGE.COBOD` to USB root.

## CI/non-interactive usage

```bash
bash "installation script/generate_manifest_and_sign.sh" \
  --ci --force \
  --root "USB drive structure" \
  --key ./cobod_recovery.key \
  --pubkey ./cobod_recovery.pub \
  --verify
```

## Options

- `--root <dir>` package root containing `scripts/`
- `--key <path>` minisign secret key
- `--pubkey <path>` minisign public key for verification
- `--script-rel <path>` recovery script relative path (default `scripts/RECOVERY.sh`)
- `--manifest-rel <path>` manifest output path (default `scripts/manifest.sha256`)
- `--sig-rel <path>` signature output path (default `scripts/manifest.sha256.minisig`)
- `--package-rel <path>` package output path (default `RECOVERYPACKAGE.COBOD`)
- `--verify` require verification
- `--no-verify` skip verification
- `--force` overwrite existing outputs
- `--ci` disable prompts
- `--help` show usage

## Recommended release flow

1. Update `scripts/RECOVERY.sh` and/or `scripts/modules/*.sh`.
2. Run `generate_manifest_and_sign.sh`.
3. Copy only `RECOVERYPACKAGE.COBOD` to the USB root.
4. Keep private key offline; never place it on USB or Pi.

Runtime note:

- The Pi writes per-run USB logs to USB root as `RECOVERY.YYYYMMDD.HH-MM-SS.log`.
