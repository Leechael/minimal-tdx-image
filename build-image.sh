#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

IMAGE_OUT=${IMAGE_OUT:-"$BASE_DIR/out/image"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-"$BASE_DIR/base"}

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
  log "base artifacts not found; running build-base.sh"
  BASE_IMAGE_DIR="$BASE_IMAGE_DIR" "$BASE_DIR/build-base.sh"
}

main() {
  [ -n "${PAYLOAD_BIN:-}" ] || die "set PAYLOAD_BIN=/path/to/payload"
  prepare_base_if_needed

  require_file "$BASE_IMAGE_DIR/ovmf.fd"
  require_file "$BASE_IMAGE_DIR/bzImage"

  rm -rf "$IMAGE_OUT"
  mkdir -p "$IMAGE_OUT"

  log "base: $BASE_IMAGE_DIR"
  log "ovmf: $BASE_IMAGE_DIR/ovmf.fd"
  log "kernel: $BASE_IMAGE_DIR/bzImage"
  log "payload: $PAYLOAD_BIN"
  log "image out: $IMAGE_OUT"

  cp "$BASE_IMAGE_DIR/ovmf.fd" "$IMAGE_OUT/ovmf.fd"
  cp "$BASE_IMAGE_DIR/bzImage" "$IMAGE_OUT/bzImage"

  INITRAMFS="$IMAGE_OUT/initramfs.cpio.gz" "$BASE_DIR/build-initramfs.sh"

  {
    printf 'ovmf=ovmf.fd\n'
    printf 'kernel=bzImage\n'
    printf 'initramfs=initramfs.cpio.gz\n'
    printf 'payload=%s\n' "$PAYLOAD_BIN"
    printf 'base_image_dir=%s\n' "$BASE_IMAGE_DIR"
  } > "$IMAGE_OUT/manifest.txt"

  ls -lh "$IMAGE_OUT"
}

main "$@"
