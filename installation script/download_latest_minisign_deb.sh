#!/usr/bin/env bash
set -euo pipefail

# Downloads latest minisign .deb package for a target architecture.
# Intended for internet-connected Debian/Raspberry Pi OS machines.

# Usage:
#   ./download_latest_minisign_deb.sh [target-arch] [output-dir]
# Examples:
#   ./download_latest_minisign_deb.sh
#   ./download_latest_minisign_deb.sh arm64 "./installation script"

TARGET_ARCH="${1:-$(dpkg --print-architecture)}"
OUT_DIR="${2:-$(pwd)}"

need_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    printf 'ERROR: Missing required command: %s\n' "$cmd" >&2
    exit 1
  fi
}

run_apt_update() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    apt-get update
    return $?
  fi

  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update
    return $?
  fi

  printf 'ERROR: apt metadata update requires root or sudo.\n' >&2
  return 1
}

print_ubuntu_ports_hint() {
  local id_like=""
  local id=""

  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    id="${ID:-}"
    id_like="${ID_LIKE:-}"
  fi

  if [[ "$id" != "ubuntu" && "$id_like" != *"ubuntu"* ]]; then
    return 0
  fi

  if [[ "$TARGET_ARCH" != "arm64" && "$TARGET_ARCH" != "armhf" ]]; then
    return 0
  fi

  cat >&2 <<EOF
Hint for Ubuntu host downloading ARM packages:
  ARM packages are served from ports.ubuntu.com, not archive.ubuntu.com.
  Your apt sources likely need arch-qualified entries.

  Typical approach:
    1) Keep amd64 lines on archive/security with [arch=amd64]
    2) Add arm64/armhf lines on ports.ubuntu.com with [arch=arm64,armhf]
    3) Run: sudo apt-get update

  Quick alternative: run this downloader directly on a Raspberry Pi with internet,
  then copy the downloaded minisign_*.deb to your offline installer directory.
EOF
}

check_arch_enabled() {
  local native_arch foreign_arches
  native_arch="$(dpkg --print-architecture)"
  foreign_arches="$(dpkg --print-foreign-architectures || true)"

  if [[ "$TARGET_ARCH" == "$native_arch" ]]; then
    return 0
  fi

  if grep -qx "$TARGET_ARCH" <<<"$foreign_arches"; then
    return 0
  fi

  printf 'ERROR: target arch %s is not enabled on this host.\n' "$TARGET_ARCH" >&2
  printf 'Enable and refresh apt if needed:\n' >&2
  printf '  sudo dpkg --add-architecture %s\n' "$TARGET_ARCH" >&2
  printf '  sudo apt-get update\n' >&2
  exit 1
}

main() {
  need_cmd apt-get
  need_cmd apt-cache
  need_cmd dpkg
  need_cmd awk
  need_cmd stat
  need_cmd sha256sum

  mkdir -p "$OUT_DIR"
  OUT_DIR="$(cd "$OUT_DIR" && pwd)"
  cd "$OUT_DIR"

  printf 'Target architecture: %s\n' "$TARGET_ARCH"
  printf 'Output directory   : %s\n' "$OUT_DIR"

  check_arch_enabled

  printf 'Updating apt metadata...\n'
  if ! run_apt_update; then
    printf 'ERROR: apt update failed.\n' >&2
    print_ubuntu_ports_hint
    exit 1
  fi

  local candidate policy_out
  policy_out="$(apt-cache policy "minisign:${TARGET_ARCH}" 2>/dev/null || true)"
  candidate="$(awk '/Candidate:/ {print $2; exit}' <<<"$policy_out")"

  if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    # Fallback: some environments don't expose arch-qualified package names.
    policy_out="$(apt-cache policy minisign 2>/dev/null || true)"
    candidate="$(awk '/Candidate:/ {print $2; exit}' <<<"$policy_out")"
  fi

  if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
    printf 'ERROR: No minisign candidate found for arch %s.\n' "$TARGET_ARCH" >&2
    printf 'Check that the package exists in your enabled apt repositories.\n' >&2
    printf 'Try: apt-cache search minisign\n' >&2
    exit 1
  fi

  printf 'Downloading minisign candidate %s (%s)...\n' "$candidate" "$TARGET_ARCH"
  if ! apt-get download "minisign:${TARGET_ARCH}"; then
    printf 'Primary download command failed, retrying without explicit arch...\n' >&2
    if ! apt-get download minisign; then
      printf 'ERROR: Failed to download minisign package.\n' >&2
      exit 1
    fi
  fi

  local latest_pkg=""
  local latest_mtime=0
  local file=""

  shopt -s nullglob
  for file in minisign_*.deb; do
    local mtime
    mtime="$(stat -c %Y "$file")"
    if (( mtime > latest_mtime )); then
      latest_mtime="$mtime"
      latest_pkg="$file"
    fi
  done
  shopt -u nullglob

  if [[ -z "$latest_pkg" ]]; then
    printf 'ERROR: Download completed but no minisign_*.deb found in %s\n' "$OUT_DIR" >&2
    exit 1
  fi

  sha256sum "$latest_pkg" > "${latest_pkg}.sha256"

  printf 'Done.\n'
  printf 'Package: %s/%s\n' "$OUT_DIR" "$latest_pkg"
  printf 'SHA256 : %s/%s.sha256\n' "$OUT_DIR" "$latest_pkg"
}

main
