# `generate_manifest_and_sign.sh` Guide

This script builds and signs the USB recovery checksum manifest:

- `scripts/manifest.sha256`
- `scripts/manifest.sha256.minisig`

It hashes:

- `scripts/RECOVERY.sh`
- every `scripts/modules/*.sh`

Then it signs `scripts/manifest.sha256` with minisign.

## Manifest format

`scripts/manifest.sha256` is plain text in sha256sum format:

```text
# USBRECOVERY-MANIFEST-V1
<sha256>  scripts/RECOVERY.sh
<sha256>  scripts/modules/<module>.sh
...
```

- two spaces between hash and path
- comments with `#` are allowed

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

- `minisign` installed on signing machine
- `sha256sum` or `shasum` installed
- `scripts/RECOVERY.sh` exists under package root
- secret key file exists (for example `cobod_recovery.key`)
- optional pubkey file for local verification (`cobod_recovery.pub`)

## Interactive quick steps

1. Run:

```bash
bash "installation script/generate_manifest_and_sign.sh"
```

2. Enter package root directory.
3. Enter secret key path.
4. Optionally enter pubkey path for verification.
5. Confirm overwrite if prompted.

Outputs:

- `scripts/manifest.sha256`
- `scripts/manifest.sha256.minisig`

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
- `--script-rel <path>` recovery script path relative to root (default `scripts/RECOVERY.sh`)
- `--manifest-rel <path>` manifest output path (default `scripts/manifest.sha256`)
- `--sig-rel <path>` signature output path (default `scripts/manifest.sha256.minisig`)
- `--verify` require verification
- `--no-verify` skip verification
- `--force` overwrite existing files
- `--ci` disable prompts
- `--help` show usage

## Recommended release flow

1. Update `scripts/RECOVERY.sh` and/or `scripts/modules/*.sh`.
2. Run `generate_manifest_and_sign.sh`.
3. Copy to USB:
   - `scripts/RECOVERY.sh`
   - `scripts/modules/*.sh`
   - `scripts/manifest.sha256`
   - `scripts/manifest.sha256.minisig`
4. Keep private key offline; never copy private key to Pi/USB.
