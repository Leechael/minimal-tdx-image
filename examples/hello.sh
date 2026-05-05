#!/bin/sh
set -eu

OUT_DIR=${OUT_DIR:-/mnt/out}
mkdir -p "$OUT_DIR"

uptime_now() {
  cut -d' ' -f1 /proc/uptime 2>/dev/null || printf 0
}

summary() {
  printf 'SUMMARY %s\n' "$*"
}

echo "hello_begin"
summary "workload_start_uptime=$(uptime_now)"
printf 'hello from minimal tdx payload\n' > "$OUT_DIR/hello.txt" 2>/dev/null || true
date > "$OUT_DIR/started-at.txt" 2>/dev/null || true
echo "hello_done"
summary "workload_done_uptime=$(uptime_now)"
summary "guest_result=ok"
summary "poweroff_start_uptime=$(uptime_now)"
sync
poweroff -f 2>/dev/null || reboot -f 2>/dev/null || exit 0
