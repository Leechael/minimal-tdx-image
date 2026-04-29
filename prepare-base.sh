#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-"$BASE_DIR/base"}
SOURCE_IMAGE_DIR=${SOURCE_IMAGE_DIR:-${IMAGE_DIR:-}}
OVMF_FD=${OVMF_FD:-}
KERNEL_IMAGE=${KERNEL_IMAGE:-}

log() {
  printf '[minimal-tdx-base] %s\n' "$*" >&2
}

die() {
  printf '[minimal-tdx-base] error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || die "missing file: $1"
}

pick_first_existing() {
  local path
  for path in "$@"; do
    if [ -f "$path" ]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

find_ovmf() {
  pick_first_existing \
    /usr/share/ovmf/OVMF.tdx.fd \
    /usr/share/qemu/OVMF.fd \
    /usr/share/ovmf/OVMF.fd
}

find_kernel() {
  local kernel
  kernel=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*-intel' 2>/dev/null | sort -V | tail -n 1)
  if [ -n "$kernel" ]; then
    printf '%s\n' "$kernel"
    return 0
  fi

  kernel=$(find /boot -maxdepth 1 -type f -name 'vmlinuz-*' 2>/dev/null | sort -V | tail -n 1)
  if [ -n "$kernel" ]; then
    printf '%s\n' "$kernel"
    return 0
  fi
  return 1
}

main() {
  if [ -n "$SOURCE_IMAGE_DIR" ]; then
    OVMF_FD=${OVMF_FD:-"$SOURCE_IMAGE_DIR/ovmf.fd"}
    KERNEL_IMAGE=${KERNEL_IMAGE:-"$SOURCE_IMAGE_DIR/bzImage"}
  fi

  OVMF_FD=${OVMF_FD:-$(find_ovmf || true)}
  KERNEL_IMAGE=${KERNEL_IMAGE:-$(find_kernel || true)}

  [ -n "$OVMF_FD" ] || die "TDX OVMF not found; install an OVMF package or set OVMF_FD=/path/to/ovmf.fd"
  [ -n "$KERNEL_IMAGE" ] || die "Linux kernel image not found; install a kernel package or set KERNEL_IMAGE=/path/to/bzImage"
  require_file "$OVMF_FD"
  require_file "$KERNEL_IMAGE"

  rm -rf "$BASE_IMAGE_DIR"
  mkdir -p "$BASE_IMAGE_DIR"

  cp "$OVMF_FD" "$BASE_IMAGE_DIR/ovmf.fd"
  cp "$KERNEL_IMAGE" "$BASE_IMAGE_DIR/bzImage"

  {
    printf 'ovmf=ovmf.fd\n'
    printf 'kernel=bzImage\n'
    printf 'source_ovmf=%s\n' "$OVMF_FD"
    printf 'source_kernel=%s\n' "$KERNEL_IMAGE"
  } > "$BASE_IMAGE_DIR/manifest.txt"

  log "base image dir: $BASE_IMAGE_DIR"
  ls -lh "$BASE_IMAGE_DIR"
}

main "$@"
