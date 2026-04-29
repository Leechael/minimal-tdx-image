#!/bin/sh
set -eu

OUT_DIR=${OUT_DIR:-/mnt/out}
mkdir -p "$OUT_DIR"

echo "hello_begin"
printf 'hello from minimal tdx payload\n' > "$OUT_DIR/hello.txt" 2>/dev/null || true
date > "$OUT_DIR/started-at.txt" 2>/dev/null || true
echo "hello_done"
sync
poweroff -f 2>/dev/null || reboot -f 2>/dev/null || exit 0
