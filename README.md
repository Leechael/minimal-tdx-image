# Minimal TDX Image

> Lightweight Intel TDX guest images for QEMU, built from dstack releases.

A minimal toolkit for running and benchmarking Intel Trust Domain Extensions
(TDX) workloads. It downloads the TDX-capable OVMF and Linux kernel from
[meta-dstack](https://github.com/Dstack-TEE/meta-dstack) releases, then builds
a tiny initramfs around a single payload — keeping the boot path small and
focused on the TDX/QEMU guest behavior without pulling in the full dstack
userspace stack.

## What This Builds

The output image bundle contains:

```text
out/image/
  ovmf.fd
  bzImage
  initramfs.cpio.gz
  manifest.txt
```

`ovmf.fd` and `bzImage` come from the latest
[meta-dstack release](https://github.com/Dstack-TEE/meta-dstack/releases/latest).
`initramfs.cpio.gz` is built locally from a selected payload.

This repository does not build dstack itself. It consumes dstack release
artifacts so the local test loop stays small.

## Files

```text
build-base.sh                 download OVMF and kernel from a dstack release
build-image.sh                assemble a runnable TDX image bundle
build-initramfs.sh             build the payload initramfs
run-qemu.sh                   boot the image bundle with QEMU TDX
examples/hello.sh             minimal payload example
examples/quote-generator.sh   quote-generator payload example
```

## Build Base Artifacts

Download the latest dstack release artifacts:

```bash
./build-base.sh
```

By default this resolves GitHub `latest` and downloads:

```text
dstack-<version>.tar.gz
```

Pin a release when you need reproducible comparisons:

```bash
DSTACK_RELEASE_TAG=v0.5.9 ./build-base.sh
```

Use another published dstack flavor if needed:

```bash
DSTACK_DIST=dstack-dev ./build-base.sh
```

The base output is:

```text
base/
  ovmf.fd
  bzImage
  metadata.json
  manifest.txt
```

Archives are cached under `.downloads/`, and extracted release contents live
under `.work/`.

## Build A Payload Image

The initramfs builder installs the selected payload as `/payload/init`. The
generated `/init` mounts basic filesystems, exports `OUT_DIR`, optionally mounts
the QEMU output share at `/mnt/out`, and then runs:

```sh
exec /payload/init
```

Build the hello payload:

```bash
PAYLOAD_BIN=examples/hello.sh ./build-image.sh
```

If `base/ovmf.fd` or `base/bzImage` is missing, `build-image.sh` runs
`build-base.sh` first.

Add extra files to the initramfs with `EXTRA_FILES`:

```bash
PAYLOAD_BIN=./my-payload \
EXTRA_FILES="/host/tool:/payload/tool /host/config.json:/etc/config.json" \
./build-image.sh
```

Each item can be `src:/guest/path` or `src`. The `src` form installs to
`/extra/<basename>`.

## Run QEMU TDX

```bash
GUEST_CID=7796 \
VM_MEMORY=512M \
./run-qemu.sh
```

The guest writes shared output to:

```text
runs/<timestamp>/out/
```

Boot timing markers are written to:

```text
runs/<timestamp>/profile.log
runs/<timestamp>/serial.log
```

To compare QEMU versions, keep the image and VM parameters fixed and change only
`QEMU_BIN`:

```bash
QEMU_BIN=/path/to/qemu-system-x86_64 ./run-qemu.sh
```

## Quote Generator Example

TDX quote generation is provided by the separate
[quote-generator](https://github.com/Leechael/quote-generator) repository.

Build the TDX quote generator:

```bash
git clone https://github.com/Leechael/quote-generator.git
cd quote-generator/tdx
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o tdx-quote-generator-linux .
```

Build an initramfs that runs it:

```bash
cd minimal-tdx-image
PAYLOAD_BIN=examples/quote-generator.sh \
EXTRA_FILES="/path/to/quote-generator/tdx/tdx-quote-generator-linux:/payload/tdx-quote-generator-linux" \
./build-image.sh
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

## Relationship To dstack

[dstack](https://github.com/Dstack-TEE/dstack) is the real guest stack.
[meta-dstack](https://github.com/Dstack-TEE/meta-dstack) builds and publishes
the TDX boot artifacts used here.

This project is intentionally smaller. It is for studying the TDX guest boot
path, QEMU behavior, and quote-generation payloads with fewer moving parts than
a full dstack guest image.
