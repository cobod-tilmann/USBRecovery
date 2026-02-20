#!/usr/bin/env bash
set -euo pipefail

# Generates and signs USB recovery manifest files.
# Supports interactive mode and CI/non-interactive mode.
# Produces a single archive payload: RECOVERYPACKAGE.COBOD

SCRIPT_REL="scripts/RECOVERY.sh"
MANIFEST_REL="scripts/manifest.sha256"
SIG_REL="scripts/manifest.sha256.minisig"
PACKAGE_REL="RECOVERYPACKAGE.COBOD"

ROOT_DIR=""
SECRET_KEY=""
PUBKEY=""

FORCE="false"
CI_MODE="false"
VERIFY_MODE="auto"  # auto | true | false

usage() {
  cat <<'EOF'
Usage:
  generate_manifest_and_sign.sh [options]

Default behavior hashes:
  - scripts/RECOVERY.sh
  - all scripts/modules/*.sh files

Default outputs:
  - scripts/manifest.sha256
  - scripts/manifest.sha256.minisig
  - RECOVERYPACKAGE.COBOD

Options:
  --root <dir>            Package root containing scripts/
  --key <path>            minisign secret key path
  --pubkey <path>         minisign public key path (optional)
  --script-rel <path>     Script path in package (default: scripts/RECOVERY.sh)
  --manifest-rel <path>   Manifest output path (default: scripts/manifest.sha256)
  --sig-rel <path>        Signature output path (default: scripts/manifest.sha256.minisig)
  --package-rel <path>    Archive output path (default: RECOVERYPACKAGE.COBOD)
  --verify                Require signature verification step
  --no-verify             Skip signature verification step
  --force                 Overwrite existing files
  --ci                    Non-interactive mode (fail instead of prompting)
  -h, --help              Show this help

Examples:
  Interactive:
    ./generate_manifest_and_sign.sh

  CI:
    ./generate_manifest_and_sign.sh --ci --force --root "USB drive structure" \
      --key ./cobod_recovery.key --pubkey ./cobod_recovery.pub --verify
EOF
}

err() {
  printf 'ERROR: %s\n' "$*" >&2
}

note() {
  printf '%s\n' "$*"
}

prompt() {
  local text="$1"
  local default="${2:-}"
  local reply=""

  if [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$text" "$default" >&2
  else
    printf '%s: ' "$text" >&2
  fi

  read -r reply
  if [[ -n "$reply" ]]; then
    printf '%s\n' "$reply"
  else
    printf '%s\n' "$default"
  fi
}

confirm() {
  local text="$1"
  local reply=""

  printf '%s [y/N]: ' "$text" >&2
  read -r reply
  [[ "$reply" =~ ^[Yy]([Ee][Ss])?$ ]]
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    err "Missing required command: $1"
    exit 1
  fi
}

compute_sha256() {
  local file="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print tolower($1)}'
    return 0
  fi

  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print tolower($1)}'
    return 0
  fi

  err "sha256sum or shasum is required"
  exit 1
}

is_interactive() {
  [[ -t 0 && -t 1 ]]
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --root)
        ROOT_DIR="${2:-}"
        shift 2
        ;;
      --key)
        SECRET_KEY="${2:-}"
        shift 2
        ;;
      --pubkey)
        PUBKEY="${2:-}"
        shift 2
        ;;
      --script-rel)
        SCRIPT_REL="${2:-}"
        shift 2
        ;;
      --manifest-rel)
        MANIFEST_REL="${2:-}"
        shift 2
        ;;
      --sig-rel)
        SIG_REL="${2:-}"
        shift 2
        ;;
      --package-rel)
        PACKAGE_REL="${2:-}"
        shift 2
        ;;
      --verify)
        VERIFY_MODE="true"
        shift
        ;;
      --no-verify)
        VERIFY_MODE="false"
        shift
        ;;
      --force)
        FORCE="true"
        shift
        ;;
      --ci)
        CI_MODE="true"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        usage
        exit 1
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  require_cmd minisign
  require_cmd tar
  require_cmd awk

  if [[ -z "$ROOT_DIR" ]]; then
    ROOT_DIR="$(pwd)"
  fi
  ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

  if [[ -z "$SECRET_KEY" ]]; then
    SECRET_KEY="$ROOT_DIR/cobod_recovery.key"
  fi

  if [[ -z "$PUBKEY" && -f "$ROOT_DIR/cobod_recovery.pub" ]]; then
    PUBKEY="$ROOT_DIR/cobod_recovery.pub"
  fi

  local interactive="false"
  if [[ "$CI_MODE" != "true" ]] && is_interactive; then
    interactive="true"
  fi

  if [[ "$interactive" == "true" ]]; then
    note "=== Signed Recovery Package Generator ==="
    note "This tool creates:"
    note "  - $MANIFEST_REL"
    note "  - $SIG_REL"
    note "  - $PACKAGE_REL"
    note ""

    ROOT_DIR="$(prompt "Package root directory" "$ROOT_DIR")"
    ROOT_DIR="$(cd "$ROOT_DIR" && pwd)"

    SECRET_KEY="$(prompt "Secret key path (.key)" "$SECRET_KEY")"

    if [[ -n "$PUBKEY" ]]; then
      PUBKEY="$(prompt "Public key path for verification (blank to skip)" "$PUBKEY")"
    else
      PUBKEY="$(prompt "Public key path for verification (blank to skip)" "")"
    fi
  fi

  local script_path manifest_path sig_path package_path modules_dir_rel modules_dir_abs
  script_path="$ROOT_DIR/$SCRIPT_REL"
  manifest_path="$ROOT_DIR/$MANIFEST_REL"
  sig_path="$ROOT_DIR/$SIG_REL"
  package_path="$ROOT_DIR/$PACKAGE_REL"
  modules_dir_rel="$(dirname "$SCRIPT_REL")/modules"
  modules_dir_abs="$ROOT_DIR/$modules_dir_rel"

  if [[ ! -f "$script_path" ]]; then
    err "Recovery script not found: $script_path"
    exit 1
  fi

  if [[ ! -f "$SECRET_KEY" ]]; then
    err "Secret key not found: $SECRET_KEY"
    exit 1
  fi

  if [[ "$FORCE" != "true" && ( -e "$manifest_path" || -e "$sig_path" || -e "$package_path" ) ]]; then
    if [[ "$interactive" == "true" ]]; then
      if ! confirm "Manifest/signature/package already exists. Overwrite"; then
        note "Aborted."
        exit 0
      fi
    else
      err "Output file exists. Use --force to overwrite."
      exit 1
    fi
  fi

  mkdir -p "$(dirname "$manifest_path")"
  mkdir -p "$(dirname "$sig_path")"
  mkdir -p "$(dirname "$package_path")"

  local -a module_rel_paths=()
  local module_abs=""
  local module_rel=""

  shopt -s nullglob
  for module_abs in "$modules_dir_abs"/*.sh; do
    module_rel="${module_abs#$ROOT_DIR/}"
    if [[ "$module_rel" == "$module_abs" ]]; then
      err "Failed to build module relative path for: $module_abs"
      exit 1
    fi
    module_rel_paths+=("$module_rel")
  done
  shopt -u nullglob

  {
    echo "# USBRECOVERY-MANIFEST-V1"
    (cd "$ROOT_DIR" && sha256sum "$SCRIPT_REL")
    if (( ${#module_rel_paths[@]} > 0 )); then
      (cd "$ROOT_DIR" && sha256sum "${module_rel_paths[@]}")
    fi
  } >"$manifest_path"

  note "Created manifest: $manifest_path"

  minisign -S -s "$SECRET_KEY" -m "$manifest_path" -x "$sig_path"
  note "Created signature: $sig_path"

  local verify_now="false"
  case "$VERIFY_MODE" in
    true)
      verify_now="true"
      ;;
    false)
      verify_now="false"
      ;;
    auto)
      if [[ -n "$PUBKEY" && -f "$PUBKEY" ]]; then
        verify_now="true"
      fi
      ;;
  esac

  if [[ "$verify_now" == "true" ]]; then
    if [[ -z "$PUBKEY" || ! -f "$PUBKEY" ]]; then
      err "Verification requested but pubkey missing: $PUBKEY"
      exit 1
    fi
    minisign -V -p "$PUBKEY" -m "$manifest_path" -x "$sig_path"
    note "Verification: PASS"
  else
    note "Verification: SKIPPED"
  fi

  local -a archive_entries=()
  archive_entries+=("$SCRIPT_REL")
  archive_entries+=("$MANIFEST_REL")
  archive_entries+=("$SIG_REL")
  if (( ${#module_rel_paths[@]} > 0 )); then
    archive_entries+=("${module_rel_paths[@]}")
  fi

  local tmp_package
  tmp_package="$package_path.tmp.$$"
  rm -f "$tmp_package"
  (
    cd "$ROOT_DIR"
    tar -cf "$tmp_package" "${archive_entries[@]}"
  )
  mv -f "$tmp_package" "$package_path"

  local script_sha256
  script_sha256="$(compute_sha256 "$script_path")"

  note "Created recovery package: $package_path"
  note ""
  note "Done."
  note "  Script   : $SCRIPT_REL"
  note "  Manifest : $MANIFEST_REL"
  note "  Signature: $SIG_REL"
  note "  Package  : $PACKAGE_REL"
  note "  SHA256   : $script_sha256"
  note "  Modules  : ${#module_rel_paths[@]}"
}

main "$@"
