#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

QEMU_BIN=${QEMU_BIN:-qemu-system-x86_64}
IMAGE_DIR=${IMAGE_DIR:-"$BASE_DIR/out/image"}
OVMF_FD=${OVMF_FD:-}
KERNEL_IMAGE=${KERNEL_IMAGE:-}
INITRAMFS=${INITRAMFS:-}
RUN_ROOT=${RUN_ROOT:-"$BASE_DIR/runs"}
QGS_PORT=${QGS_PORT:-4050}
ENABLE_QGS=${ENABLE_QGS:-0}
GUEST_CID=${GUEST_CID:-7794}
VM_MEMORY=${VM_MEMORY:-512M}
VM_CPUS=${VM_CPUS:-1}
TIMEOUT_SECONDS=${TIMEOUT_SECONDS:-120}
MOUNT_OUT=${MOUNT_OUT:-1}
KERNEL_APPEND=${KERNEL_APPEND:-}

RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}
WORK_DIR=${WORK_DIR:-"$RUN_ROOT/$RUN_ID"}
OUT_SHARE_DIR=${OUT_SHARE_DIR:-"$WORK_DIR/out"}

log() {
  printf '[minimal-tdx-qemu] %s\n' "$*" >&2
}

die() {
  printf '[minimal-tdx-qemu] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  [ -f "$1" ] || die "missing file: $1"
}

is_pid_alive() {
  [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null
}

now_ns() {
  date +%s.%N
}

profile() {
  local now
  now=$(now_ns)
  awk -v now="$now" -v start="$PROFILE_START" -v msg="$*" \
    'BEGIN { printf("PROFILE +%.3fs %s\n", now - start, msg); fflush(); }' | tee -a "$WORK_DIR/profile.log"
}

main() {
  need_cmd "$QEMU_BIN"
  need_cmd awk
  need_cmd date
  need_cmd grep

  if [ -n "$IMAGE_DIR" ]; then
    OVMF_FD=${OVMF_FD:-"$IMAGE_DIR/ovmf.fd"}
    KERNEL_IMAGE=${KERNEL_IMAGE:-"$IMAGE_DIR/bzImage"}
    INITRAMFS=${INITRAMFS:-"$IMAGE_DIR/initramfs.cpio.gz"}
  fi

  [ -n "$OVMF_FD" ] || die "missing ovmf.fd; run ./build-image.sh or set OVMF_FD"
  [ -n "$KERNEL_IMAGE" ] || die "missing bzImage; run ./build-image.sh or set KERNEL_IMAGE"
  [ -n "$INITRAMFS" ] || die "missing initramfs; run ./build-image.sh or set INITRAMFS"
  require_file "$OVMF_FD"
  require_file "$KERNEL_IMAGE"
  require_file "$INITRAMFS"

  [ -e /dev/kvm ] || die "/dev/kvm not found"
  [ -r /dev/kvm ] && [ -w /dev/kvm ] || die "/dev/kvm is not readable/writable by $(whoami)"
  "$QEMU_BIN" -object help 2>/dev/null | grep -q '^  tdx-guest$' || die "$QEMU_BIN does not list tdx-guest object support"
  if ps -ef | grep -F "guest-cid=$GUEST_CID" | grep -v grep >/dev/null 2>&1; then
    die "guest CID $GUEST_CID is already in use; set GUEST_CID to a free value"
  fi

  rm -rf "$WORK_DIR"
  mkdir -p "$WORK_DIR" "$OUT_SHARE_DIR"
  : > "$WORK_DIR/profile.log"

  PROFILE_START=$(now_ns)
  export PROFILE_START

  log "qemu: $("$QEMU_BIN" --version | head -n 1)"
  log "ovmf: $OVMF_FD"
  log "kernel: $KERNEL_IMAGE"
  log "initramfs: $INITRAMFS"
  log "guest cid: $GUEST_CID"
  log "memory: $VM_MEMORY"
  log "work dir: $WORK_DIR"

  local tdx_object append
  if [ "$ENABLE_QGS" = 1 ]; then
    tdx_object=$(printf '{"qom-type":"tdx-guest","id":"tdx","quote-generation-socket":{"type":"vsock","cid":"2","port":"%s"}}' "$QGS_PORT")
  else
    tdx_object=tdx-guest,id=tdx
  fi

  append="console=ttyS0 init=/init panic=1 random.trust_cpu=y random.trust_bootloader=n tsc=reliable no-kvmclock out_tag=out out_dir=/mnt/out"
  if [ "$ENABLE_QGS" = 1 ]; then
    append="$append qgs_port=$QGS_PORT"
  fi
  append="$append $KERNEL_APPEND"

  local qemu_args=(
    -accel kvm
    -cpu host
    -nographic -nodefaults
    -chardev "file,id=com0,path=$WORK_DIR/serial.log"
    -serial chardev:com0
    -qmp "unix:$WORK_DIR/qmp.sock,server=on,wait=off"
    -bios "$OVMF_FD"
    -kernel "$KERNEL_IMAGE"
    -initrd "$INITRAMFS"
    -machine q35,kernel-irqchip=split,confidential-guest-support=tdx,hpet=off
    -object "$tdx_object"
    -smbios type=1,manufacturer=minimal-tdx,product=payload-initramfs
    -device "vhost-vsock-pci,guest-cid=$GUEST_CID"
    -smp "$VM_CPUS"
    -m "$VM_MEMORY"
    -append "$append"
    -pidfile "$WORK_DIR/qemu.pid"
    -daemonize
  )

  if [ "$MOUNT_OUT" = 1 ]; then
    qemu_args+=(-virtfs "local,path=$OUT_SHARE_DIR,mount_tag=out,readonly=off,security_model=mapped,id=out")
  fi

  profile "qemu_start"
  "$QEMU_BIN" "${qemu_args[@]}"

  local pid
  pid=$(cat "$WORK_DIR/qemu.pid")
  profile "qemu_pid=$pid"

  local wait_start first_serial init_begin payload_exec
  wait_start=$(date +%s)
  first_serial=0
  init_begin=0
  payload_exec=0

  while is_pid_alive "$pid"; do
    if [ "$(($(date +%s) - wait_start))" -ge "$TIMEOUT_SECONDS" ]; then
      kill "$pid" 2>/dev/null || true
      die "timed out waiting for qemu exit; inspect $WORK_DIR/serial.log"
    fi
    if [ "$first_serial" = 0 ] && [ -s "$WORK_DIR/serial.log" ]; then
      first_serial=1
      profile "first_serial_byte"
    fi
    if [ "$init_begin" = 0 ] && grep -q 'MINIMAL_TDX init_begin' "$WORK_DIR/serial.log" 2>/dev/null; then
      init_begin=1
      profile "guest_init_begin"
    fi
    if [ "$payload_exec" = 0 ] && grep -q 'MINIMAL_TDX payload_exec' "$WORK_DIR/serial.log" 2>/dev/null; then
      payload_exec=1
      profile "guest_payload_exec"
    fi
    sleep 0.1
  done
  profile "qemu_exit"

  log "serial markers:"
  grep -E 'MINIMAL_TDX' "$WORK_DIR/serial.log" || true
  log "output share: $OUT_SHARE_DIR"
  log "profile: $WORK_DIR/profile.log"
  log "serial: $WORK_DIR/serial.log"
}

main "$@"
