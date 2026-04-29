#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

IMAGE_OUT=${IMAGE_OUT:-"$BASE_DIR/out/image"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-"$BASE_DIR/base"}
SOURCE_IMAGE_DIR=${SOURCE_IMAGE_DIR:-${IMAGE_DIR:-}}
OVMF_FD=${OVMF_FD:-}
KERNEL_IMAGE=${KERNEL_IMAGE:-}

log() {
  printf '[minimal-tdx-image] %s\n' "$*" >&2
}

die() {
  printf '[minimal-tdx-image] error: %s\n' "$*" >&2
  exit 1
}

require_file() {
  [ -f "$1" ] || die "missing file: $1"
}

prepare_base_if_needed() {
  if [ -f "$BASE_IMAGE_DIR/ovmf.fd" ] && [ -f "$BASE_IMAGE_DIR/bzImage" ]; then
    return 0
  fi
  log "base artifacts not found; running prepare-base.sh"
  BASE_IMAGE_DIR="$BASE_IMAGE_DIR" "$BASE_DIR/prepare-base.sh"
}

main() {
  if [ -n "$SOURCE_IMAGE_DIR" ]; then
    OVMF_FD=${OVMF_FD:-"$SOURCE_IMAGE_DIR/ovmf.fd"}
    KERNEL_IMAGE=${KERNEL_IMAGE:-"$SOURCE_IMAGE_DIR/bzImage"}
  elif [ -d "$BASE_IMAGE_DIR" ]; then
    OVMF_FD=${OVMF_FD:-"$BASE_IMAGE_DIR/ovmf.fd"}
    KERNEL_IMAGE=${KERNEL_IMAGE:-"$BASE_IMAGE_DIR/bzImage"}
  fi

  [ -n "${PAYLOAD_BIN:-}" ] || die "set PAYLOAD_BIN=/path/to/payload"
  if [ -z "$OVMF_FD" ] || [ -z "$KERNEL_IMAGE" ]; then
    prepare_base_if_needed
    OVMF_FD=${OVMF_FD:-"$BASE_IMAGE_DIR/ovmf.fd"}
    KERNEL_IMAGE=${KERNEL_IMAGE:-"$BASE_IMAGE_DIR/bzImage"}
  fi

  [ -n "$OVMF_FD" ] || die "missing ovmf.fd"
  [ -n "$KERNEL_IMAGE" ] || die "missing bzImage"
  require_file "$OVMF_FD"
  require_file "$KERNEL_IMAGE"

  rm -rf "$IMAGE_OUT"
  mkdir -p "$IMAGE_OUT"

  log "ovmf: $OVMF_FD"
  log "kernel: $KERNEL_IMAGE"
  log "payload: $PAYLOAD_BIN"
  log "image out: $IMAGE_OUT"

  cp "$OVMF_FD" "$IMAGE_OUT/ovmf.fd"
  cp "$KERNEL_IMAGE" "$IMAGE_OUT/bzImage"

  INITRAMFS="$IMAGE_OUT/initramfs.cpio.gz" "$BASE_DIR/build-initramfs.sh"

  {
    printf 'ovmf=ovmf.fd\n'
    printf 'kernel=bzImage\n'
    printf 'initramfs=initramfs.cpio.gz\n'
    printf 'payload=%s\n' "$PAYLOAD_BIN"
  } > "$IMAGE_OUT/manifest.txt"

  ls -lh "$IMAGE_OUT"
}

main "$@"
