#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

CC=${CC:-cc}
VM_MEMORY=${VM_MEMORY:-2G}
GUEST_CID=${GUEST_CID:-7798}
RUN_ID=${RUN_ID:-memfill-$(date -u +%Y%m%dT%H%M%SZ)}
RUN_ROOT=${RUN_ROOT:-"$BASE_DIR/runs"}
MEM_FILL_MODE=${MEM_FILL_MODE:-full}
MEM_FILL_PERCENT=${MEM_FILL_PERCENT:-90}
MEM_FILL_LEAVE_MB=${MEM_FILL_LEAVE_MB:-256}
MEM_FILL_PROGRESS_PERCENT=${MEM_FILL_PROGRESS_PERCENT:-5}
MEM_FILL_SLEEP_SECONDS=${MEM_FILL_SLEEP_SECONDS:-0}
MEM_FILL_MB=${MEM_FILL_MB:-}
MEM_FILL_GB=${MEM_FILL_GB:-}
MEM_FILL_BYTES=${MEM_FILL_BYTES:-}
MEM_FILL_SEED=${MEM_FILL_SEED:-}
KERNEL_APPEND=${KERNEL_APPEND:-}

log() {
  printf '[minimal-tdx-memory-fill] %s\n' "$*" >&2
}

die() {
  printf '[minimal-tdx-memory-fill] error: %s\n' "$*" >&2
  exit 1
}

append_arg() {
  local key=$1
  local value=$2
  if [ -n "$value" ]; then
    KERNEL_APPEND="$KERNEL_APPEND $key=$value"
  fi
}

build_payload() {
  local out_dir="$BASE_DIR/build/memory-fill"
  local out_bin="$out_dir/memory-fill"

  mkdir -p "$out_dir"
  log "compiler: $CC"
  if ! "$CC" -O2 -Wall -Wextra -static -o "$out_bin" "$BASE_DIR/examples/memory-fill.c"; then
    die "failed to build a static memory-fill binary; install a C compiler with static libc support or set CC"
  fi
  printf '%s\n' "$out_bin"
}

main() {
  local payload append work_dir

  command -v "$CC" >/dev/null 2>&1 || die "missing compiler: $CC"
  payload=$(build_payload)
  work_dir="$RUN_ROOT/$RUN_ID"

  append_arg mem_fill_mode "$MEM_FILL_MODE"
  append_arg mem_fill_percent "$MEM_FILL_PERCENT"
  append_arg mem_fill_leave_mb "$MEM_FILL_LEAVE_MB"
  append_arg mem_fill_progress_percent "$MEM_FILL_PROGRESS_PERCENT"
  append_arg mem_fill_sleep_seconds "$MEM_FILL_SLEEP_SECONDS"
  append_arg mem_fill_mb "$MEM_FILL_MB"
  append_arg mem_fill_gb "$MEM_FILL_GB"
  append_arg mem_fill_bytes "$MEM_FILL_BYTES"
  append_arg mem_fill_seed "$MEM_FILL_SEED"
  append=${KERNEL_APPEND# }

  log "run id: $RUN_ID"
  log "memory: $VM_MEMORY"
  log "mode: $MEM_FILL_MODE"
  log "kernel append: $append"

  (
    cd "$BASE_DIR"
    PAYLOAD_BIN="$payload" ./build-image.sh
    VM_MEMORY="$VM_MEMORY" \
    GUEST_CID="$GUEST_CID" \
    RUN_ID="$RUN_ID" \
    RUN_ROOT="$RUN_ROOT" \
    KERNEL_APPEND="$append" \
    ./run-qemu.sh
  )

  log "profile: $work_dir/profile.log"
  log "serial: $work_dir/serial.log"
  log "memory fill log: $work_dir/out/memory-fill.log"
}

main "$@"
