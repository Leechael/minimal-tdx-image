#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

QUOTE_GENERATOR_BIN=${QUOTE_GENERATOR_BIN:-}
GUEST_CID=${GUEST_CID:-7797}
VM_MEMORY=${VM_MEMORY:-512M}
QGS_PORT=${QGS_PORT:-4050}
RUN_ID=${RUN_ID:-quote-$(date -u +%Y%m%dT%H%M%SZ)}
RUN_ROOT=${RUN_ROOT:-"$BASE_DIR/runs"}
KERNEL_APPEND=${KERNEL_APPEND:-}

log() {
  printf '[minimal-tdx-quote-example] %s\n' "$*" >&2
}

die() {
  printf '[minimal-tdx-quote-example] error: %s\n' "$*" >&2
  exit 1
}

pick_quote_generator() {
  if [ -n "$QUOTE_GENERATOR_BIN" ]; then
    printf '%s\n' "$QUOTE_GENERATOR_BIN"
    return 0
  fi

  local candidate
  for candidate in \
    "$BASE_DIR/../quote-generator/tdx/tdx-quote-generator-linux" \
    "$BASE_DIR/quote-generator/tdx/tdx-quote-generator-linux" \
    "$PWD/tdx-quote-generator-linux"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

main() {
  local quote_generator_bin quote_generator_dir quote_generator_name work_dir append

  quote_generator_bin=$(pick_quote_generator || true)
  [ -n "$quote_generator_bin" ] || die "set QUOTE_GENERATOR_BIN=/path/to/tdx-quote-generator-linux"
  [ -x "$quote_generator_bin" ] || die "quote generator is not executable: $quote_generator_bin"

  quote_generator_dir=$(cd -- "$(dirname -- "$quote_generator_bin")" && pwd)
  quote_generator_name=$(basename -- "$quote_generator_bin")
  work_dir="$RUN_ROOT/$RUN_ID"

  log "quote generator: $quote_generator_bin"
  log "run id: $RUN_ID"

  if [ ! -f "$BASE_DIR/base/tdx-guest.ko" ]; then
    (
      cd "$BASE_DIR"
      ./build-base.sh
    )
  fi
  [ -f "$BASE_DIR/base/tdx-guest.ko" ] || die "base/tdx-guest.ko missing; install unsquashfs/squashfs-tools and rerun ./build-base.sh"

  (
    cd "$BASE_DIR"
    PAYLOAD_BIN=examples/quote-generator.sh ./build-image.sh
  )

  append="device_id_report_data=1 quote_generator=/mnt/in/$quote_generator_name"
  if [ -n "$KERNEL_APPEND" ]; then
    append="$append $KERNEL_APPEND"
  fi

  (
    cd "$BASE_DIR"
    ENABLE_QGS=1 \
    QGS_PORT="$QGS_PORT" \
    GUEST_CID="$GUEST_CID" \
    VM_MEMORY="$VM_MEMORY" \
    RUN_ID="$RUN_ID" \
    RUN_ROOT="$RUN_ROOT" \
    IN_SHARE_DIR="$quote_generator_dir" \
    KERNEL_APPEND="$append" \
    ./run-qemu.sh
  )

  log "quote: $work_dir/out/quote.bin"
  log "quote generator log: $work_dir/out/quote-generator.log"
  log "serial: $work_dir/serial.log"

  if [ -f "$work_dir/out/quote-generator.log" ]; then
    grep -E '^(ppid|device_id)=' "$work_dir/out/quote-generator.log" || true
  else
    grep -E '^(ppid|device_id)=' "$work_dir/serial.log" || true
  fi
}

main "$@"
