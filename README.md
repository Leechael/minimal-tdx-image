# Minimal TDX Image

This directory builds a small initramfs for QEMU TDX boot tests. It is only a
payload runner: after minimal setup, `/init` replaces itself with the selected
payload, so the payload runs as PID 1.

## Files

```text
build-image.sh                build a runnable image bundle
build-initramfs.sh             build a payload initramfs
run-qemu.sh                   boot the initramfs as a TDX guest
examples/hello.sh             minimal PID 1 payload
examples/quote-generator.sh   quote-generator payload example
```

## Payload Contract

`build-initramfs.sh` installs the selected payload as `/payload/init`. The
generated `/init` mounts basic filesystems, optionally mounts a QEMU 9p output
share at `/mnt/out`, exports `OUT_DIR`, and then runs:

```sh
exec /payload/init
```

Because the payload becomes PID 1, it should shut the guest down itself when it
is done:

```sh
sync
poweroff -f 2>/dev/null || reboot -f 2>/dev/null || exit 0
```

## Build A Minimal Image

```bash
cd minimal-tdx-image
PAYLOAD_BIN=examples/hello.sh \
OVMF_FD=/path/to/ovmf.fd \
KERNEL_IMAGE=/path/to/bzImage \
./build-image.sh
```

The output is:

```text
out/image/
  ovmf.fd
  bzImage
  initramfs.cpio.gz
  manifest.txt
```

For convenience, `SOURCE_IMAGE_DIR=/dir` is also accepted when the directory
contains:

```text
ovmf.fd
bzImage
```

`EXTRA_FILES` can add files to the initramfs. Each item is either
`src:/guest/path` or just `src`, which installs to `/extra/<basename>`:

```bash
PAYLOAD_BIN=./my-payload \
OVMF_FD=/path/to/ovmf.fd \
KERNEL_IMAGE=/path/to/bzImage \
EXTRA_FILES="/host/tool:/payload/tool /host/config.json:/etc/config.json" \
./build-image.sh
```

## Run QEMU TDX

```bash
GUEST_CID=7796 \
VM_MEMORY=512M \
./run-qemu.sh
```

`run-qemu.sh` defaults to `IMAGE_DIR=out/image`. You can set `IMAGE_DIR` to run
another image bundle with the same file names.

The guest mounts the output share at `/mnt/out`. Host output appears in:

```text
runs/<timestamp>/out/
```

## Quote Generator Example

The quote generator lives in its own public repository:

```bash
git clone https://github.com/Leechael/quote-generator.git
cd quote-generator/tdx
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o tdx-quote-generator-linux .
```

Build an initramfs that runs the quote generator payload:

```bash
cd minimal-tdx-image
PAYLOAD_BIN=examples/quote-generator.sh \
OVMF_FD=/path/to/ovmf.fd \
KERNEL_IMAGE=/path/to/bzImage \
EXTRA_FILES="/path/to/quote-generator/tdx/tdx-quote-generator-linux:/payload/tdx-quote-generator-linux" \
./build-image.sh
```

If your guest kernel needs `tdx-guest.ko` as a module instead of providing
`/dev/tdx_guest` directly, include it explicitly:

```bash
EXTRA_FILES="/path/to/quote-generator/tdx/tdx-quote-generator-linux:/payload/tdx-quote-generator-linux \
/path/to/tdx-guest.ko:/lib/modules/tdx-guest.ko"
```

Run with QGS enabled:

```bash
ENABLE_QGS=1 \
QGS_PORT=4050 \
GUEST_CID=7797 \
VM_MEMORY=512M \
./run-qemu.sh
```

Expected output:

```text
runs/<timestamp>/out/quote.bin
```

Custom report data:

```bash
KERNEL_APPEND="report_data_hex=<64-byte-hex>" ENABLE_QGS=1 ./run-qemu.sh
```

dstack device-id report data:

```bash
KERNEL_APPEND="device_id_report_data=1" ENABLE_QGS=1 ./run-qemu.sh
```

## Benchmarking QEMU Versions

Keep `IMAGE_DIR`, `VM_MEMORY`, and `VM_CPUS` fixed, then vary only `QEMU_BIN`:

```bash
QEMU_BIN=/path/to/qemu-system-x86_64 ./run-qemu.sh
```

Profile markers go to:

```text
runs/<timestamp>/profile.log
runs/<timestamp>/serial.log
```
