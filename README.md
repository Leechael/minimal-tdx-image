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
examples/run-quote-generator.sh
                              host-side quote-generator example workflow
examples/memory-fill.c        memory dirtying benchmark payload
examples/run-memory-fill.sh   host-side memory-fill benchmark workflow
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
  tdx-guest.ko
  metadata.json
  manifest.txt
```

Archives are cached under `.downloads/`, and extracted release contents live
under `.work/`. `tdx-guest.ko` is extracted from the dstack release rootfs when
`unsquashfs` is available.

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

Set `IN_SHARE_DIR` to mount a read-only host directory into the guest at
`/mnt/in`:

```bash
IN_SHARE_DIR=/path/to/input ./run-qemu.sh
```

Boot timing markers are written to:

```text
runs/<timestamp>/profile.log
runs/<timestamp>/serial.log
```

`profile.log` includes host-side QEMU timing markers such as
`first_serial_byte`, `linux_version`, `guest_init_begin`, and
`guest_payload_exec`.

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

Alternatively, keep the quote generator outside the initramfs and mount its
directory into the guest:

```bash
QUOTE_GENERATOR_BIN=/path/to/quote-generator/tdx/tdx-quote-generator-linux \
./examples/run-quote-generator.sh
```

This example builds the quote payload image, mounts the quote-generator binary's
host directory at `/mnt/in`, runs QEMU with QGS enabled, and asks the generator
to print both `ppid=` and `device_id=`.

The quote example needs `base/tdx-guest.ko`. Install `unsquashfs`
(`squashfs-tools` on many Linux distributions) before running `build-base.sh`
if that file is missing.

Run with QGS enabled:

```bash
ENABLE_QGS=1 \
QGS_PORT=4050 \
IN_SHARE_DIR=/path/to/quote-generator/tdx \
KERNEL_APPEND="device_id_report_data=1 quote_generator=/mnt/in/tdx-quote-generator-linux" \
GUEST_CID=7797 \
VM_MEMORY=512M \
./run-qemu.sh
```

Expected output:

```text
runs/<timestamp>/out/quote.bin
runs/<timestamp>/out/quote-generator.log
runs/<timestamp>/profile.log
runs/<timestamp>/serial.log
```

The quote example adds extra timing markers to `profile.log`:

```text
quote_example_begin
quote_load_tdx_guest_module_begin
quote_load_tdx_guest_module_end
quote_tdx_guest_ready
quote_qgs_port_ready
quote_generator_ready
quote_generator_start
quote_ppid_printed
quote_device_id_printed
quote_generator_done
quote_size_reported
quote_done
quote_example_end
```

Custom report data:

```bash
KERNEL_APPEND="report_data_hex=<64-byte-hex>" ENABLE_QGS=1 ./run-qemu.sh
```

dstack device-id report data:

```bash
KERNEL_APPEND="device_id_report_data=1" ENABLE_QGS=1 ./run-qemu.sh
```

## Memory Fill Example

The memory-fill example measures how VM memory size affects TDX entry, guest
boot, memory dirtying, and shutdown time. It builds a static PID 1 payload that
allocates guest memory and writes pseudo-random 64-bit values across the
allocated range.

Run a 2 GiB VM and fill 90% of guest memory:

```bash
VM_MEMORY=2G ./examples/run-memory-fill.sh
```

Run a 200 GiB VM:

```bash
VM_MEMORY=200G \
MEM_FILL_PERCENT=90 \
MEM_FILL_PROGRESS_PERCENT=10 \
./examples/run-memory-fill.sh
```

Use an explicit fill size instead of a percentage:

```bash
VM_MEMORY=200G MEM_FILL_GB=180 ./examples/run-memory-fill.sh
```

Important knobs:

```text
MEM_FILL_MODE=full             write pseudo-random data across the full range
MEM_FILL_MODE=page             touch one pseudo-random 64-bit word per page
MEM_FILL_PERCENT=90            default target percentage of MemTotal
MEM_FILL_LEAVE_MB=256          keep this much MemAvailable unallocated
MEM_FILL_GB=                   explicit GiB target
MEM_FILL_MB=                   explicit MiB target
MEM_FILL_BYTES=                explicit byte target
MEM_FILL_PROGRESS_PERCENT=5    serial progress interval
MEM_FILL_SLEEP_SECONDS=0       sleep after write, before poweroff
```

The output files are:

```text
runs/<timestamp>/profile.log
runs/<timestamp>/serial.log
runs/<timestamp>/out/memory-fill.log
```

`profile.log` includes:

```text
memfill_begin
memfill_alloc_begin
memfill_alloc_end
memfill_write_begin
memfill_write_end
memfill_result
memfill_end
memfill_poweroff_begin
qemu_exit
```

`memory-fill.log` includes the target size, progress samples, write throughput,
and checksum. The payload does not free the allocation before shutdown, so the
dirty private pages remain present when QEMU exits.

## Relationship To dstack

[dstack](https://github.com/Dstack-TEE/dstack) is the real guest stack.
[meta-dstack](https://github.com/Dstack-TEE/meta-dstack) builds and publishes
the TDX boot artifacts used here.

This project is intentionally smaller. It is for studying the TDX guest boot
path, QEMU behavior, and quote-generation payloads with fewer moving parts than
a full dstack guest image.
