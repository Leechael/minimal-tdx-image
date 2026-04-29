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

main() {
  if [ -n "$SOURCE_IMAGE_DIR" ]; then
    OVMF_FD=${OVMF_FD:-"$SOURCE_IMAGE_DIR/ovmf.fd"}
    KERNEL_IMAGE=${KERNEL_IMAGE:-"$SOURCE_IMAGE_DIR/bzImage"}
  fi

  [ -n "$OVMF_FD" ] || die "set OVMF_FD=/path/to/ovmf.fd or SOURCE_IMAGE_DIR=/dir"
  [ -n "$KERNEL_IMAGE" ] || die "set KERNEL_IMAGE=/path/to/bzImage or SOURCE_IMAGE_DIR=/dir"
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
