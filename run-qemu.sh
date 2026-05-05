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
MOUNT_IN=${MOUNT_IN:-0}
IN_SHARE_DIR=${IN_SHARE_DIR:-}
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

one_line() {
  tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g; s/^ //; s/ $//'
}

cmd_output() {
  if ! command -v "$1" >/dev/null 2>&1; then
    return 0
  fi
  "$@" 2>/dev/null | one_line || true
}

file_value() {
  if [ -r "$1" ]; then
    one_line < "$1"
  else
    printf 'unavailable'
  fi
}

host_info() {
  local key=$1
  local value=${2:-}
  printf '%s=%s\n' "$key" "$value" >> "$WORK_DIR/host-info.log"
  log "$key: $value"
}

dpkg_versions() {
  if ! command -v dpkg-query >/dev/null 2>&1; then
    printf 'unavailable'
    return 0
  fi
  dpkg-query -W -f='${Package}=${Version}\n' "$@" 2>/dev/null | one_line
}

cpu_tdx_flags() {
  awk -F: '/^flags[[:space:]]*:/ { print $2; exit }' /proc/cpuinfo 2>/dev/null |
    tr ' ' '\n' |
    awk '/^(tdx|tdx_guest|vmx|sgx|seamrr|pconfig)$/ { print }' |
    sort -u |
    tr '\n' ',' |
    sed 's/,$//'
}

log_host_environment() {
  local os_pretty qgsd_status qgsd_version flags qemu_packages kernel_package tdx_packages

  : > "$WORK_DIR/host-info.log"

  os_pretty=$(awk -F= '/^PRETTY_NAME=/ { gsub(/^"|"$/, "", $2); print $2 }' /etc/os-release 2>/dev/null | one_line)
  qgsd_status=$(systemctl is-active qgsd 2>/dev/null || true)
  qgsd_status=$(printf '%s' "$qgsd_status" | one_line)
  qgsd_version=$(cmd_output qgsd --version)
  flags=$(cpu_tdx_flags)
  qemu_packages=$(dpkg_versions qemu-system-x86 qemu-system-common qemu-system-data qemu-utils)
  kernel_package=$(dpkg_versions "linux-image-$(uname -r)")
  tdx_packages=$(dpkg-query -W -f='${Package}=${Version}\n' '*tdx*' 2>/dev/null | one_line || true)

  [ -n "$os_pretty" ] || os_pretty=unavailable
  [ -n "$qgsd_status" ] || qgsd_status=unavailable
  [ -n "$qgsd_version" ] || qgsd_version=unavailable
  [ -n "$flags" ] || flags=unavailable
  [ -n "$qemu_packages" ] || qemu_packages=unavailable
  [ -n "$kernel_package" ] || kernel_package=unavailable
  [ -n "$tdx_packages" ] || tdx_packages=unavailable

  host_info host_uname "$(uname -a)"
  host_info host_os "$os_pretty"
  host_info host_kernel_release "$(uname -r)"
  host_info host_cpu_model "$(awk -F: '/^model name[[:space:]]*:/ { gsub(/^ /, "", $2); print $2; exit }' /proc/cpuinfo 2>/dev/null | one_line)"
  host_info host_cpu_tdx_flags "$flags"
  host_info host_kvm_intel_tdx "$(file_value /sys/module/kvm_intel/parameters/tdx)"
  host_info host_kvm_intel_ept "$(file_value /sys/module/kvm_intel/parameters/ept)"
  host_info host_qgsd_status "$qgsd_status"
  host_info host_qgsd_version "$qgsd_version"
  host_info host_qemu_packages "$qemu_packages"
  host_info host_kernel_package "$kernel_package"
  host_info host_tdx_packages "$tdx_packages"

  if [ -f "$IMAGE_DIR/metadata.json" ]; then
    host_info dstack_metadata "$(one_line < "$IMAGE_DIR/metadata.json")"
  fi
}

serial_has() {
  grep -q "$1" "$WORK_DIR/serial.log" 2>/dev/null
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

profile_once() {
  local var_name=$1
  local pattern=$2
  local label=$3
  local value

  eval "value=\${$var_name}"
  if [ "$value" = 0 ] && serial_has "$pattern"; then
    eval "$var_name=1"
    profile "$label"
  fi
}

scan_memfill_progress() {
  local line percent

  [ -f "$WORK_DIR/serial.log" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      *MEM_FILL_PROGRESS*percent=*)
        percent=${line#*percent=}
        percent=${percent%% *}
        case "$percent" in
          ''|*[!0-9]*) continue ;;
        esac
        case " $memfill_progress_seen " in
          *" $percent "*) ;;
          *)
            memfill_progress_seen="$memfill_progress_seen $percent"
            profile "memfill_progress_${percent}"
            ;;
        esac
        ;;
    esac
  done < "$WORK_DIR/serial.log"
}

scan_serial_markers() {
  profile_once linux_version 'Linux version' linux_version
  profile_once init_begin 'MINIMAL_TDX init_begin' guest_init_begin
  profile_once payload_exec 'MINIMAL_TDX payload_exec' guest_payload_exec
  profile_once quote_begin 'TDX_QUOTE_EXAMPLE_BEGIN' quote_example_begin
  profile_once quote_load_module_begin 'TDX_QUOTE_EXAMPLE_LOAD_TDX_GUEST_MODULE_BEGIN' quote_load_tdx_guest_module_begin
  profile_once quote_load_module_end 'TDX_QUOTE_EXAMPLE_LOAD_TDX_GUEST_MODULE_END' quote_load_tdx_guest_module_end
  profile_once quote_tdx_ready 'TDX_QUOTE_EXAMPLE_TDX_GUEST_READY' quote_tdx_guest_ready
  profile_once quote_qgs_ready 'TDX_QUOTE_EXAMPLE_QGS_PORT_READY' quote_qgs_port_ready
  profile_once quote_generator_ready 'TDX_QUOTE_EXAMPLE_GENERATOR_READY' quote_generator_ready
  profile_once quote_generator_start 'TDX_QUOTE_EXAMPLE_GENERATOR_START' quote_generator_start
  profile_once quote_ppid '^ppid=' quote_ppid_printed
  profile_once quote_device_id '^device_id=' quote_device_id_printed
  profile_once quote_generator_done 'TDX_QUOTE_EXAMPLE_GENERATOR_DONE' quote_generator_done
  profile_once quote_size '^quote_size=' quote_size_reported
  profile_once quote_done '^quote_done' quote_done
  profile_once quote_end 'TDX_QUOTE_EXAMPLE_END' quote_example_end
  profile_once memfill_begin 'MEM_FILL_BEGIN' memfill_begin
  profile_once memfill_alloc_begin 'MEM_FILL_ALLOC_BEGIN' memfill_alloc_begin
  profile_once memfill_alloc_end 'MEM_FILL_ALLOC_END' memfill_alloc_end
  profile_once memfill_write_begin 'MEM_FILL_WRITE_BEGIN' memfill_write_begin
  scan_memfill_progress
  profile_once memfill_write_end 'MEM_FILL_WRITE_END' memfill_write_end
  profile_once memfill_result '^MEM_FILL_RESULT' memfill_result
  profile_once memfill_end 'MEM_FILL_END' memfill_end
  profile_once memfill_poweroff_begin 'MEM_FILL_POWEROFF_BEGIN' memfill_poweroff_begin
  profile_once summary_poweroff '^SUMMARY poweroff_start' guest_poweroff_start
  profile_once summary_result '^SUMMARY guest_result=' guest_result
}

print_run_artifacts() {
  log "serial markers:"
  grep -E 'MINIMAL_TDX|TDX_QUOTE_EXAMPLE|^quote_|^ppid=|^device_id=|MEM_FILL_|^SUMMARY ' "$WORK_DIR/serial.log" || true
  log "output share: $OUT_SHARE_DIR"
  log "host info: $WORK_DIR/host-info.log"
  log "profile: $WORK_DIR/profile.log"
  log "serial: $WORK_DIR/serial.log"
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

  if [ -n "$IN_SHARE_DIR" ]; then
    MOUNT_IN=1
  fi
  if [ "$MOUNT_IN" = 1 ]; then
    [ -n "$IN_SHARE_DIR" ] || die "set IN_SHARE_DIR=/host/input/dir or disable MOUNT_IN"
    [ -d "$IN_SHARE_DIR" ] || die "input share directory not found: $IN_SHARE_DIR"
  fi

  PROFILE_START=$(now_ns)
  export PROFILE_START

  log "qemu: $("$QEMU_BIN" --version | head -n 1)"
  log_host_environment
  log "ovmf: $OVMF_FD"
  log "kernel: $KERNEL_IMAGE"
  log "initramfs: $INITRAMFS"
  log "guest cid: $GUEST_CID"
  log "memory: $VM_MEMORY"
  log "timeout seconds: $TIMEOUT_SECONDS"
  log "work dir: $WORK_DIR"

  local tdx_object append
  if [ "$ENABLE_QGS" = 1 ]; then
    tdx_object=$(printf '{"qom-type":"tdx-guest","id":"tdx","quote-generation-socket":{"type":"vsock","cid":"2","port":"%s"}}' "$QGS_PORT")
  else
    tdx_object=tdx-guest,id=tdx
  fi

  append="console=ttyS0 init=/init panic=1 random.trust_cpu=y random.trust_bootloader=n tsc=reliable no-kvmclock out_tag=out out_dir=/mnt/out"
  if [ "$MOUNT_IN" = 1 ]; then
    append="$append in_tag=in in_dir=/mnt/in"
  fi
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
  if [ "$MOUNT_IN" = 1 ]; then
    qemu_args+=(-virtfs "local,path=$IN_SHARE_DIR,mount_tag=in,readonly=on,security_model=mapped,id=in")
  fi

  profile "qemu_start"
  "$QEMU_BIN" "${qemu_args[@]}"

  local pid
  pid=$(cat "$WORK_DIR/qemu.pid")
  profile "qemu_pid=$pid"

  local wait_start first_serial linux_version init_begin payload_exec
  local quote_begin quote_load_module_begin quote_load_module_end quote_tdx_ready quote_qgs_ready quote_generator_ready
  local quote_generator_start quote_generator_done quote_ppid quote_device_id
  local quote_size quote_done quote_end
  local memfill_begin memfill_alloc_begin memfill_alloc_end memfill_write_begin
  local memfill_write_end memfill_result memfill_end memfill_poweroff_begin
  local summary_poweroff summary_result
  local memfill_progress_seen
  wait_start=$(date +%s)
  first_serial=0
  linux_version=0
  init_begin=0
  payload_exec=0
  quote_begin=0
  quote_load_module_begin=0
  quote_load_module_end=0
  quote_tdx_ready=0
  quote_qgs_ready=0
  quote_generator_ready=0
  quote_generator_start=0
  quote_generator_done=0
  quote_ppid=0
  quote_device_id=0
  quote_size=0
  quote_done=0
  quote_end=0
  memfill_begin=0
  memfill_alloc_begin=0
  memfill_alloc_end=0
  memfill_write_begin=0
  memfill_write_end=0
  memfill_result=0
  memfill_end=0
  memfill_poweroff_begin=0
  summary_poweroff=0
  summary_result=0
  memfill_progress_seen=""

  while is_pid_alive "$pid"; do
    if [ "$(($(date +%s) - wait_start))" -ge "$TIMEOUT_SECONDS" ]; then
      scan_serial_markers
      profile "timeout"
      print_run_artifacts
      kill "$pid" 2>/dev/null || true
      die "timed out waiting for qemu exit; inspect $WORK_DIR/serial.log"
    fi
    if [ "$first_serial" = 0 ] && [ -s "$WORK_DIR/serial.log" ]; then
      first_serial=1
      profile "first_serial_byte"
    fi
    scan_serial_markers
    sleep 0.1
  done
  scan_serial_markers
  profile "qemu_exit"

  print_run_artifacts
}

main "$@"
