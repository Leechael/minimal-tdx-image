#!/bin/sh
set -eu

PATH=/bin:/payload:/mnt/in
OUT_DIR=${OUT_DIR:-/mnt/out}
IN_DIR=${IN_DIR:-/mnt/in}

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
  mknod /dev/tdx_guest c 10 124 2>/dev/null || true
  chmod 600 /dev/tdx_guest 2>/dev/null || true
fi

if [ ! -e /dev/tdx_guest ]; then
  echo "quote_error=/dev/tdx_guest_missing"
  finish 2
fi

QGS_PORT=$(cmdline_value qgs_port || printf '')
if [ -z "$QGS_PORT" ]; then
  echo "quote_error=qgs_port_missing"
  finish 2
fi

REPORT_DATA_HEX=$(cmdline_value report_data_hex || printf '')
DEVICE_ID_REPORT_DATA=$(cmdline_value device_id_report_data || printf '0')
QUOTE_GENERATOR=$(cmdline_value quote_generator || printf '')

if [ -z "$QUOTE_GENERATOR" ]; then
  for candidate in \
    /payload/tdx-quote-generator-linux \
    "$IN_DIR/tdx-quote-generator-linux" \
    "$IN_DIR/tdx/tdx-quote-generator-linux" \
    "$IN_DIR/quote-generator/tdx/tdx-quote-generator-linux"; do
    if [ -x "$candidate" ]; then
      QUOTE_GENERATOR=$candidate
      break
    fi
  done
fi

if [ ! -x "$QUOTE_GENERATOR" ]; then
  echo "quote_error=tdx_quote_generator_missing"
  echo "quote_generator_checked=/payload/tdx-quote-generator-linux"
  echo "quote_generator_checked=$IN_DIR/tdx-quote-generator-linux"
  echo "quote_generator_checked=$IN_DIR/tdx/tdx-quote-generator-linux"
  echo "quote_generator_checked=$IN_DIR/quote-generator/tdx/tdx-quote-generator-linux"
  finish 2
fi

QUOTE_LOG="$OUT_DIR/quote-generator.log"
echo "quote_begin"
echo "quote_generator=$QUOTE_GENERATOR"
if [ "$DEVICE_ID_REPORT_DATA" = 1 ]; then
  "$QUOTE_GENERATOR" -qgs-port "$QGS_PORT" -device-id-report-data -print-ppid -print-device-id -o "$OUT_DIR/quote.bin" > "$QUOTE_LOG" 2>&1 || {
    rc=$?
    cat "$QUOTE_LOG" 2>/dev/null || true
    finish "$rc"
  }
elif [ -n "$REPORT_DATA_HEX" ]; then
  "$QUOTE_GENERATOR" -qgs-port "$QGS_PORT" -d "$REPORT_DATA_HEX" -print-ppid -print-device-id -o "$OUT_DIR/quote.bin" > "$QUOTE_LOG" 2>&1 || {
    rc=$?
    cat "$QUOTE_LOG" 2>/dev/null || true
    finish "$rc"
  }
else
  "$QUOTE_GENERATOR" -qgs-port "$QGS_PORT" -print-ppid -print-device-id -o "$OUT_DIR/quote.bin" > "$QUOTE_LOG" 2>&1 || {
    rc=$?
    cat "$QUOTE_LOG" 2>/dev/null || true
    finish "$rc"
  }
fi
cat "$QUOTE_LOG" 2>/dev/null || true
stat -c 'quote_size=%s' "$OUT_DIR/quote.bin" 2>/dev/null || true
sha256sum "$OUT_DIR/quote.bin" 2>/dev/null | sed 's/^/quote_sha256=/' || true
echo "quote_done"
finish 0
