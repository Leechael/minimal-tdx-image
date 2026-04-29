#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

BUSYBOX_BIN=${BUSYBOX_BIN:-/bin/busybox}
PAYLOAD_BIN=${PAYLOAD_BIN:-}
EXTRA_FILES=${EXTRA_FILES:-}
OUT_DIR=${OUT_DIR:-"$BASE_DIR/out"}
BUILD_DIR=${BUILD_DIR:-"$BASE_DIR/build/rootfs"}
INITRAMFS=${INITRAMFS:-"$OUT_DIR/minimal-tdx-initramfs.cpio.gz"}

log() {
  printf '[minimal-tdx-build] %s\n' "$*" >&2
}

die() {
  printf '[minimal-tdx-build] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  [ -f "$1" ] || die "missing file: $1"
}

install_file() {
  local src=$1
  local dst=$2
  local mode=${3:-0755}

  [ "${dst#/}" != "$dst" ] || die "destination must be absolute: $dst"
  require_file "$src"
  mkdir -p "$(dirname "$BUILD_DIR$dst")"
  cp "$src" "$BUILD_DIR$dst"
  chmod "$mode" "$BUILD_DIR$dst"
}

install_extra_files() {
  local spec src dst

  for spec in $EXTRA_FILES; do
    case "$spec" in
      *:*)
        src=${spec%%:*}
        dst=${spec#*:}
        ;;
      *)
        src=$spec
        dst="/extra/$(basename "$src")"
        ;;
    esac
    install_file "$src" "$dst" 0755
  done
}

write_init() {
  cat > "$BUILD_DIR/init" <<'EOF'
#!/bin/sh
set -eu

PATH=/bin:/payload
export PATH

cmdline_value() {
  key=$1
  for arg in $(cat /proc/cmdline 2>/dev/null || true); do
    case "$arg" in
      "$key="*) printf '%s\n' "${arg#*=}"; return 0 ;;
    esac
  done
  return 1
}

mount_basic_fs() {
  mkdir -p /proc /sys /dev /run /tmp /mnt/out /mnt/in /etc
  mount -t proc proc /proc 2>/dev/null || true
  mount -t sysfs sysfs /sys 2>/dev/null || true
  mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
  mount -t tmpfs tmpfs /run 2>/dev/null || true
}

mount_input() {
  IN_TAG=$(cmdline_value in_tag || printf '')
  IN_DIR=$(cmdline_value in_dir || printf '/mnt/in')
  export IN_TAG IN_DIR

  mkdir -p "$IN_DIR"
  if [ -n "$IN_TAG" ]; then
    mount -t 9p -o trans=virtio,version=9p2000.L "$IN_TAG" "$IN_DIR" 2>/dev/null || true
  fi
}

mount_output() {
  OUT_TAG=$(cmdline_value out_tag || printf 'out')
  OUT_DIR=$(cmdline_value out_dir || printf '/mnt/out')
  export OUT_TAG OUT_DIR

  mkdir -p "$OUT_DIR"
  if [ -n "$OUT_TAG" ]; then
    mount -t 9p -o trans=virtio,version=9p2000.L "$OUT_TAG" "$OUT_DIR" 2>/dev/null || true
  fi
}

mount_basic_fs
mount_input
mount_output

echo "MINIMAL_TDX init_begin uptime=$(cut -d' ' -f1 /proc/uptime 2>/dev/null || printf 0)"
echo "MINIMAL_TDX payload_exec"
exec /payload/init
EOF
  chmod 0755 "$BUILD_DIR/init"
}

main() {
  need_cmd cpio
  need_cmd gzip
  need_cmd find

  [ -n "$PAYLOAD_BIN" ] || die "set PAYLOAD_BIN=/path/to/program-or-script"

  require_file "$BUSYBOX_BIN"
  require_file "$PAYLOAD_BIN"

  log "busybox: $BUSYBOX_BIN"
  log "payload: $PAYLOAD_BIN"
  log "initramfs: $INITRAMFS"

  rm -rf "$BUILD_DIR"
  mkdir -p "$BUILD_DIR/bin" "$BUILD_DIR/dev" "$BUILD_DIR/payload" "$OUT_DIR"

  install_file "$BUSYBOX_BIN" /bin/busybox 0755
  (
    cd "$BUILD_DIR/bin"
    for applet in sh mount umount mkdir mknod insmod modprobe ls cat echo printf sleep poweroff reboot sync stat sha256sum wc cut tr date uname grep sed env true false; do
      ln -sf busybox "$applet"
    done
  )

  install_file "$PAYLOAD_BIN" /payload/init 0755
  install_extra_files
  write_init

  (
    cd "$BUILD_DIR"
    find . -print0 | cpio --null -o --format=newc 2>/dev/null | gzip -9 > "$INITRAMFS"
  )

  ls -lh "$INITRAMFS"
}

main "$@"
