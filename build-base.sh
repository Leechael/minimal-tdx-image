#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

META_DSTACK_REPO=${META_DSTACK_REPO:-https://github.com/dstack-TEE/meta-dstack.git}
META_DSTACK_REF=${META_DSTACK_REF:-v0.5.9}
WORK_ROOT=${WORK_ROOT:-"$BASE_DIR/.work"}
META_DSTACK_DIR=${META_DSTACK_DIR:-"$WORK_ROOT/meta-dstack"}
BB_BUILD_DIR=${BB_BUILD_DIR:-"$META_DSTACK_DIR/bb-build"}
BASE_IMAGE_DIR=${BASE_IMAGE_DIR:-"$BASE_DIR/base"}

log() {
  printf '[minimal-tdx-base] %s\n' "$*" >&2
}

die() {
  printf '[minimal-tdx-base] error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_file() {
  [ -f "$1" ] || die "missing file: $1"
}

checkout_meta_dstack() {
  mkdir -p "$WORK_ROOT"

  if [ ! -d "$META_DSTACK_DIR/.git" ]; then
    log "cloning meta-dstack: $META_DSTACK_REPO"
    git clone --recursive "$META_DSTACK_REPO" "$META_DSTACK_DIR"
  fi

  (
    cd "$META_DSTACK_DIR"
    git fetch --tags origin '+refs/heads/*:refs/remotes/origin/*'

    if git rev-parse --verify --quiet "refs/remotes/origin/$META_DSTACK_REF" >/dev/null; then
      git checkout --force -B "$META_DSTACK_REF" "origin/$META_DSTACK_REF"
    else
      git checkout --force --detach "$META_DSTACK_REF"
    fi

    git submodule sync --recursive
    git submodule update --init --recursive
  )
}

build_meta_dstack_base() {
  log "building meta-dstack base artifacts"
  log "meta-dstack dir: $META_DSTACK_DIR"
  log "meta-dstack ref: $META_DSTACK_REF"
  log "bitbake build dir: $BB_BUILD_DIR"

  (
    cd "$META_DSTACK_DIR"
    # dev-setup wires poky, layers, MACHINE, DISTRO, and BitBake environment.
    source ./dev-setup "$BB_BUILD_DIR"
    bitbake virtual/kernel dstack-ovmf
  )
}

find_deploy_dir() {
  local images_dir="$BB_BUILD_DIR/tmp/deploy/images"
  local deploy_dir
  [ -d "$images_dir" ] || die "Yocto deploy images directory not found: $images_dir"

  if [ -d "$images_dir/tdx" ]; then
    printf '%s\n' "$images_dir/tdx"
    return 0
  fi

  deploy_dir=$(find "$images_dir" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)
  [ -n "$deploy_dir" ] || die "no Yocto deploy image directory found under $images_dir"
  printf '%s\n' "$deploy_dir"
}

find_kernel_image() {
  local deploy_dir=$1

  if [ -e "$deploy_dir/bzImage" ]; then
    printf '%s\n' "$deploy_dir/bzImage"
    return 0
  fi

  find "$deploy_dir" -maxdepth 1 \( -type f -o -type l \) -name 'bzImage*' | sort | tail -n 1
}

install_base_artifacts() {
  local deploy_dir ovmf_fd kernel_image commit

  deploy_dir=$(find_deploy_dir)
  ovmf_fd="$deploy_dir/ovmf.fd"
  kernel_image=$(find_kernel_image "$deploy_dir")

  require_file "$ovmf_fd"
  [ -n "$kernel_image" ] || die "bzImage not found in $deploy_dir"
  require_file "$kernel_image"

  rm -rf "$BASE_IMAGE_DIR"
  mkdir -p "$BASE_IMAGE_DIR"

  cp -L "$ovmf_fd" "$BASE_IMAGE_DIR/ovmf.fd"
  cp -L "$kernel_image" "$BASE_IMAGE_DIR/bzImage"

  commit=$(git -C "$META_DSTACK_DIR" rev-parse HEAD)
  {
    printf 'ovmf=ovmf.fd\n'
    printf 'kernel=bzImage\n'
    printf 'source=meta-dstack\n'
    printf 'meta_dstack_repo=%s\n' "$META_DSTACK_REPO"
    printf 'meta_dstack_ref=%s\n' "$META_DSTACK_REF"
    printf 'meta_dstack_commit=%s\n' "$commit"
    printf 'bb_build_dir=%s\n' "$BB_BUILD_DIR"
    printf 'deploy_dir=%s\n' "$deploy_dir"
    printf 'source_ovmf=%s\n' "$ovmf_fd"
    printf 'source_kernel=%s\n' "$kernel_image"
  } > "$BASE_IMAGE_DIR/manifest.txt"

  log "base image dir: $BASE_IMAGE_DIR"
  ls -lh "$BASE_IMAGE_DIR"
}

main() {
  need_cmd git
  need_cmd find
  need_cmd sort

  checkout_meta_dstack
  build_meta_dstack_base
  install_base_artifacts
}

main "$@"
