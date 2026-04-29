#!/usr/bin/env bash
set -euo pipefail

BASE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

DSTACK_RELEASE_REPO=${DSTACK_RELEASE_REPO:-Dstack-TEE/meta-dstack}
DSTACK_RELEASE_TAG=${DSTACK_RELEASE_TAG:-latest}
DSTACK_DIST=${DSTACK_DIST:-dstack}
DSTACK_ASSET=${DSTACK_ASSET:-}
DOWNLOAD_DIR=${DOWNLOAD_DIR:-"$BASE_DIR/.downloads"}
EXTRACT_DIR=${EXTRACT_DIR:-"$BASE_DIR/.work/release"}
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

resolve_release_tag() {
  local effective_url

  if [ "$DSTACK_RELEASE_TAG" != "latest" ]; then
    printf '%s\n' "$DSTACK_RELEASE_TAG"
    return 0
  fi

  effective_url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
    "https://github.com/$DSTACK_RELEASE_REPO/releases/latest")
  [ -n "$effective_url" ] || die "failed to resolve latest release"
  printf '%s\n' "${effective_url##*/}"
}

download_release_asset() {
  local tag=$1
  local version asset url archive

  version=${tag#v}
  asset=${DSTACK_ASSET:-"$DSTACK_DIST-$version.tar.gz"}
  url="https://github.com/$DSTACK_RELEASE_REPO/releases/download/$tag/$asset"
  archive="$DOWNLOAD_DIR/$asset"

  mkdir -p "$DOWNLOAD_DIR"
  if [ ! -s "$archive" ]; then
    log "downloading: $url"
    curl -fL --retry 3 --retry-delay 2 -o "$archive.tmp" "$url"
    mv "$archive.tmp" "$archive"
  else
    log "using cached archive: $archive"
  fi

  printf '%s\n' "$archive"
}

extract_release_asset() {
  local tag=$1
  local archive=$2
  local target="$EXTRACT_DIR/$tag"

  rm -rf "$target"
  mkdir -p "$target"
  tar -xzf "$archive" -C "$target"
  printf '%s\n' "$target"
}

find_bundle_dir() {
  local target=$1
  local ovmf

  ovmf=$(find "$target" -type f -name ovmf.fd | sort | head -n 1)
  [ -n "$ovmf" ] || die "ovmf.fd not found in extracted release: $target"
  dirname "$ovmf"
}

install_base_artifacts() {
  local tag=$1
  local archive=$2
  local bundle_dir=$3
  local metadata="$bundle_dir/metadata.json"

  require_file "$bundle_dir/ovmf.fd"
  require_file "$bundle_dir/bzImage"

  rm -rf "$BASE_IMAGE_DIR"
  mkdir -p "$BASE_IMAGE_DIR"

  cp "$bundle_dir/ovmf.fd" "$BASE_IMAGE_DIR/ovmf.fd"
  cp "$bundle_dir/bzImage" "$BASE_IMAGE_DIR/bzImage"
  if [ -f "$metadata" ]; then
    cp "$metadata" "$BASE_IMAGE_DIR/metadata.json"
  fi

  {
    printf 'ovmf=ovmf.fd\n'
    printf 'kernel=bzImage\n'
    printf 'source=dstack-release\n'
    printf 'release_repo=%s\n' "$DSTACK_RELEASE_REPO"
    printf 'release_tag=%s\n' "$tag"
    printf 'release_asset=%s\n' "$(basename "$archive")"
    printf 'archive=%s\n' "$archive"
    printf 'source_dir=%s\n' "$bundle_dir"
    printf 'source_ovmf=%s\n' "$bundle_dir/ovmf.fd"
    printf 'source_kernel=%s\n' "$bundle_dir/bzImage"
  } > "$BASE_IMAGE_DIR/manifest.txt"

  log "base image dir: $BASE_IMAGE_DIR"
  ls -lh "$BASE_IMAGE_DIR"
}

main() {
  local tag archive extracted bundle_dir

  need_cmd curl
  need_cmd tar
  need_cmd find
  need_cmd sort

  tag=$(resolve_release_tag)
  log "release repo: $DSTACK_RELEASE_REPO"
  log "release tag: $tag"

  archive=$(download_release_asset "$tag")
  extracted=$(extract_release_asset "$tag" "$archive")
  bundle_dir=$(find_bundle_dir "$extracted")
  install_base_artifacts "$tag" "$archive" "$bundle_dir"
}

main "$@"
