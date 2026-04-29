#!/bin/sh
set -eu

PATH=/bin:/payload
OUT_DIR=${OUT_DIR:-/mnt/out}

cmdline_value() {
  key=$1
  for arg in $(cat /proc/cmdline 2>/dev/null || true); do
    case "$arg" in
      "$key="*) printf '%s\n' "${arg#*=}"; return 0 ;;
    esac
  done
  return 1
}

finish() {
  rc=$1
  sync
  poweroff -f 2>/dev/null || reboot -f 2>/dev/null || exit "$rc"
}

mkdir -p "$OUT_DIR"

if [ ! -e /dev/tdx_guest ] && [ -f /lib/modules/tdx-guest.ko ]; then
  insmod /lib/modules/tdx-guest.ko || true
fi

if [ ! -e /dev/tdx_guest ]; then
  echo "quote_error=/dev/tdx_guest_missing"
  finish 2
fi

if [ ! -x /payload/tdx-quote-generator-linux ]; then
  echo "quote_error=/payload/tdx-quote-generator-linux_missing"
  finish 2
fi

QGS_PORT=$(cmdline_value qgs_port || printf '')
if [ -z "$QGS_PORT" ]; then
  echo "quote_error=qgs_port_missing"
  finish 2
fi

REPORT_DATA_HEX=$(cmdline_value report_data_hex || printf '')
DEVICE_ID_REPORT_DATA=$(cmdline_value device_id_report_data || printf '0')

echo "quote_begin"
if [ "$DEVICE_ID_REPORT_DATA" = 1 ]; then
  /payload/tdx-quote-generator-linux -qgs-port "$QGS_PORT" -device-id-report-data -print-device-id -o "$OUT_DIR/quote.bin" || finish $?
elif [ -n "$REPORT_DATA_HEX" ]; then
  /payload/tdx-quote-generator-linux -qgs-port "$QGS_PORT" -d "$REPORT_DATA_HEX" -o "$OUT_DIR/quote.bin" || finish $?
else
  /payload/tdx-quote-generator-linux -qgs-port "$QGS_PORT" -o "$OUT_DIR/quote.bin" || finish $?
fi
stat -c 'quote_size=%s' "$OUT_DIR/quote.bin" 2>/dev/null || true
sha256sum "$OUT_DIR/quote.bin" 2>/dev/null | sed 's/^/quote_sha256=/' || true
echo "quote_done"
finish 0
