#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_VERSION="${1:-}"

if [[ -z "$TARGET_VERSION" ]]; then
  echo "usage: $0 v1.19.xx" >&2
  exit 2
fi

case "$TARGET_VERSION" in
  v[0-9]*.[0-9]*.[0-9]*) ;;
  *) echo "invalid stable tag: $TARGET_VERSION" >&2; exit 2 ;;
esac

CHECK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vpn-hap-core-check.XXXXXX")"
cleanup() {
  case "$CHECK_ROOT" in
    "${TMPDIR:-/tmp}"/vpn-hap-core-check.*) rm -rf "$CHECK_ROOT" ;;
    *) echo "refusing to clean unexpected check path: $CHECK_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

MIHOMO_DIR="$CHECK_ROOT/mihomo"
GVISOR_DIR="$CHECK_ROOT/gvisor"
mkdir -p "$MIHOMO_DIR" "$GVISOR_DIR"

MIHOMO_COMMIT="$(git ls-remote https://github.com/MetaCubeX/mihomo.git "refs/tags/$TARGET_VERSION" | awk 'NR == 1 {print $1}')"
if [[ -z "$MIHOMO_COMMIT" ]]; then
  echo "upstream tag not found: $TARGET_VERSION" >&2
  exit 1
fi

curl -LfsS "https://github.com/MetaCubeX/mihomo/archive/refs/tags/$TARGET_VERSION.tar.gz" \
  | tar -xz -C "$MIHOMO_DIR" --strip-components=1

MIHOMO_PATCHES=("$SCRIPT_DIR/patches/mihomo"/*.patch)
git -C "$MIHOMO_DIR" apply --check "${MIHOMO_PATCHES[@]}"

GVISOR_VERSION="$(awk '$1 == "github.com/metacubex/gvisor" {print $2}' "$MIHOMO_DIR/go.mod")"
GVISOR_SHORT="${GVISOR_VERSION##*-}"
if [[ -z "$GVISOR_SHORT" || "$GVISOR_SHORT" == "$GVISOR_VERSION" ]]; then
  echo "failed to resolve gVisor commit from $TARGET_VERSION/go.mod" >&2
  exit 1
fi

curl -LfsS "https://github.com/MetaCubeX/gvisor/archive/$GVISOR_SHORT.tar.gz" \
  | tar -xz -C "$GVISOR_DIR" --strip-components=1
GVISOR_COMMIT="$(git ls-remote https://github.com/MetaCubeX/gvisor.git | awk -v p="$GVISOR_SHORT" 'index($1, p) == 1 && !found {print $1; found = 1}')"
if [[ -z "$GVISOR_COMMIT" ]]; then
  GVISOR_COMMIT="$GVISOR_SHORT"
fi

GVISOR_PATCHES=("$SCRIPT_DIR/patches/gvisor"/*.patch)
git -C "$GVISOR_DIR" apply --check "${GVISOR_PATCHES[@]}"

echo "patch compatibility check passed"
echo "MIHOMO_VERSION=$TARGET_VERSION"
echo "MIHOMO_COMMIT=$MIHOMO_COMMIT"
echo "GVISOR_COMMIT=$GVISOR_COMMIT"
echo "next: update core-versions.env and both submodule pointers, then run ./build.sh"
