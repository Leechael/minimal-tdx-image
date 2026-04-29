# Minimal TDX Image

This directory builds a small payload-runner initramfs for QEMU TDX tests.
After minimal setup, `/init` replaces itself with the selected payload, so the
payload runs as process ID 1 (PID 1).

## Files

```text
build-base.sh                 download TDX OVMF and kernel from dstack release
build-image.sh                build a runnable image bundle
build-initramfs.sh             build a payload initramfs
run-qemu.sh                   boot the initramfs as a TDX guest
examples/hello.sh             minimal PID 1 payload
examples/quote-generator.sh   quote-generator payload example
```

## Base Artifacts

`build-base.sh` downloads the latest dstack release tarball from:

```text
https://github.com/dstack-TEE/meta-dstack.git
```

By default it resolves GitHub `latest` and downloads `dstack-<version>.tar.gz`.
Set `DSTACK_RELEASE_TAG` to pin a release tag:

```bash
cd minimal-tdx-image
DSTACK_RELEASE_TAG=v0.5.9 ./build-base.sh
```

Set `DSTACK_DIST` to download another published flavor, for example
`dstack-dev`, `dstack-nvidia`, or `dstack-nvidia-dev`.

The output is:

```text
base/
  ovmf.fd
  bzImage
  manifest.txt
```

`manifest.txt` records the resolved release tag and source artifact paths.
Downloaded release archives are cached under `.downloads/`, and extracted
archives live under `.work/`.

## Payload Contract

`build-initramfs.sh` installs the selected payload as `/payload/init`. The
generated `/init` mounts basic filesystems, optionally mounts a QEMU 9p output
share at `/mnt/out`, exports `OUT_DIR`, and then runs:

```sh
exec /payload/init
```

After the payload becomes PID 1, it should shut the guest down when it finishes:

```sh
sync
poweroff -f 2>/dev/null || reboot -f 2>/dev/null || exit 0
```

## Build A Minimal Image

```bash
cd minimal-tdx-image
PAYLOAD_BIN=examples/hello.sh ./build-image.sh
```

If `base/ovmf.fd` or `base/bzImage` is missing, `build-image.sh` runs
`build-base.sh` first. For normal payload iteration, keep `base/` and rerun only
`build-image.sh`.

The output is:

```text
out/image/
  ovmf.fd
  bzImage
  initramfs.cpio.gz
  manifest.txt
```

`EXTRA_FILES` can add files to the initramfs. Each item can use
`src:/guest/path` or `src`. The `src` form installs the file to
`/extra/<basename>`:

```bash
PAYLOAD_BIN=./my-payload \
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
EXTRA_FILES="/path/to/quote-generator/tdx/tdx-quote-generator-linux:/payload/tdx-quote-generator-linux" \
./build-image.sh
```

If your guest kernel needs `tdx-guest.ko` as a module instead of providing
`/dev/tdx_guest` directly, include it explicitly:

```bash
EXTRA_FILES="/path/to/quote-generator/tdx/tdx-quote-generator-linux:/payload/tdx-quote-generator-linux \
/path/to/tdx-guest.ko:/lib/modules/tdx-guest.ko"
```

Run with the Quote Generation Service (QGS) enabled:

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
