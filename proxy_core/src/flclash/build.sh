#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/core-versions.env"
OUTPUT_FILE="${CORE_OUTPUT:-$SCRIPT_DIR/../../libs/arm64-v8a/libflclash.so}"
ARKTS_BUILD_INFO="$SCRIPT_DIR/../../src/main/ets/CoreBuildInfo.ets"
KEEP_STAGE="${KEEP_CORE_STAGE:-0}"
RUN_HOST_CHECKS="${RUN_CORE_HOST_CHECKS:-1}"

if [[ ! -f "$VERSIONS_FILE" ]]; then
  echo "missing version lock: $VERSIONS_FILE" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "$VERSIONS_FILE"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing command: $1" >&2
    exit 1
  fi
}

require_command git
require_command tar

OHOS_GO="${OHOS_GO:-$WORKSPACE_DIR/.tools/ohos_golang_go/bin/go}"
if [[ ! -x "$OHOS_GO" ]]; then
  echo "OHOS Go toolchain not found: $OHOS_GO" >&2
  exit 1
fi

if [[ -z "${OHOS_NATIVE_HOME:-}" ]]; then
  native_candidates=(
    "/Applications/DevEco-Studio-26-Beta.app/Contents/sdk/default/openharmony/native"
    "/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/native"
  )
  for candidate in "${native_candidates[@]}"; do
    if [[ -x "$candidate/llvm/bin/aarch64-unknown-linux-ohos-clang" ]]; then
      OHOS_NATIVE_HOME="$candidate"
      break
    fi
  done
fi

if [[ -z "${OHOS_NATIVE_HOME:-}" ]]; then
  echo "set OHOS_NATIVE_HOME to the OpenHarmony native SDK directory" >&2
  exit 1
fi

CC="$OHOS_NATIVE_HOME/llvm/bin/aarch64-unknown-linux-ohos-clang"
CXX="$OHOS_NATIVE_HOME/llvm/bin/aarch64-unknown-linux-ohos-clang++"
if [[ ! -x "$CC" || ! -x "$CXX" ]]; then
  echo "OpenHarmony arm64 clang toolchain is incomplete: $OHOS_NATIVE_HOME" >&2
  exit 1
fi

check_source_commit() {
  local source_dir="$1"
  local expected_commit="$2"
  local label="$3"
  if [[ ! -d "$source_dir/.git" && ! -f "$source_dir/.git" ]]; then
    echo "$label submodule is not initialized: $source_dir" >&2
    echo "run: git submodule update --init --recursive" >&2
    exit 1
  fi
  local actual_commit
  actual_commit="$(git -C "$source_dir" rev-parse HEAD)"
  if [[ "$actual_commit" != "$expected_commit" ]]; then
    echo "$label commit mismatch: expected $expected_commit, got $actual_commit" >&2
    exit 1
  fi
}

check_source_commit "$SCRIPT_DIR/core" "$MIHOMO_COMMIT" "mihomo"
check_source_commit "$SCRIPT_DIR/gvisor-ohos" "$GVISOR_COMMIT" "gVisor"

STAGE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vpn-hap-core.XXXXXX")"
STAGE_DIR="$STAGE_ROOT/flclash"

cleanup() {
  if [[ "$KEEP_STAGE" == "1" ]]; then
    echo "kept build stage: $STAGE_ROOT"
    return
  fi
  case "$STAGE_ROOT" in
    "${TMPDIR:-/tmp}"/vpn-hap-core.*) rm -rf "$STAGE_ROOT" ;;
    *) echo "refusing to clean unexpected stage path: $STAGE_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

mkdir -p "$STAGE_DIR/core" "$STAGE_DIR/gvisor-ohos"

# Copy only the Harmony wrapper. Upstream sources are exported from their exact
# pinned commits, so local submodule dirt never leaks into a release build.
tar -C "$SCRIPT_DIR" \
  --exclude='./core' \
  --exclude='./gvisor-ohos' \
  --exclude='./.hvigor' \
  --exclude='./libflclash.so' \
  -cf - . | tar -C "$STAGE_DIR" -xf -
git -C "$SCRIPT_DIR/core" archive "$MIHOMO_COMMIT" | tar -C "$STAGE_DIR/core" -xf -
git -C "$SCRIPT_DIR/gvisor-ohos" archive "$GVISOR_COMMIT" | tar -C "$STAGE_DIR/gvisor-ohos" -xf -

apply_patch_series() {
  local source_dir="$1"
  local patch_dir="$2"
  local label="$3"
  local patches=()
  while IFS= read -r patch_file; do
    # 0007 used a net.Conn wrapper for temporary OpenAI diagnostics. It hid
    # Mihomo's ExtendedConn/half-close interfaces and caused long-lived HTTP/2
    # streams to stall, so keep the artifact for historical traces but do not
    # include it in production cores.
    if [[ "$(basename "$patch_file")" == "0007-openai-tcp-activity-diagnostics.patch" ]]; then
      echo "skipping obsolete diagnostic patch: $patch_file"
      continue
    fi
    patches+=("$patch_file")
  done < <(find "$patch_dir" -maxdepth 1 -type f -name '*.patch' -print | sort)
  if [[ ! -e "${patches[0]}" ]]; then
    echo "missing $label patch series: $patch_dir" >&2
    exit 1
  fi
  git -C "$source_dir" apply --check "${patches[@]}"
  git -C "$source_dir" apply "${patches[@]}"
  echo "applied ${#patches[@]} $label patch(es)"
}

apply_patch_series "$STAGE_DIR/core" "$SCRIPT_DIR/patches/mihomo" "mihomo"
apply_patch_series "$STAGE_DIR/gvisor-ohos" "$SCRIPT_DIR/patches/gvisor" "gVisor"

"$OHOS_GO" -C "$STAGE_DIR" mod tidy

if [[ "$RUN_HOST_CHECKS" == "1" ]]; then
	"$OHOS_GO" -C "$STAGE_DIR" test delay_diagnostics.go delay_diagnostics_test.go
	"$OHOS_GO" -C "$STAGE_DIR" test node_quality.go peak_speedtest.go sustained_bandwidth.go sustained_target.go sustained_progress.go node_quality_logic_test.go sustained_bandwidth_test.go delay_diagnostics.go
  echo "running host compile checks for patched mihomo packages"
	"$OHOS_GO" -C "$STAGE_DIR/core" test ./adapter ./adapter/outbound ./component/iface ./dns ./hub/executor ./tunnel/statistic
fi

mkdir -p "$(dirname "$OUTPUT_FILE")"
STAGED_OUTPUT="$STAGE_ROOT/libflclash.so"
BUILD_VERSION="${MIHOMO_VERSION}-ohos.r${OHOS_PATCHSET}"

echo "building $BUILD_VERSION for HarmonyOS NEXT arm64"
CC="$CC" \
CXX="$CXX" \
GOOS=linux \
GOARCH=arm64 \
CGO_ENABLED=1 \
"$OHOS_GO" -C "$STAGE_DIR" build \
  -buildmode=c-shared \
  -tags='ohos with_gvisor' \
  -trimpath \
  -ldflags="-s -w -X github.com/metacubex/mihomo/constant.Version=$BUILD_VERSION" \
  -o "$STAGED_OUTPUT" .

OUTPUT_TMP="${OUTPUT_FILE}.tmp.$$"
cp -f "$STAGED_OUTPUT" "$OUTPUT_TMP"
mv -f "$OUTPUT_TMP" "$OUTPUT_FILE"

OUTPUT_SHA256="$(shasum -a 256 "$OUTPUT_FILE" | awk '{print $1}')"
BUILD_TIME="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
MANIFEST_FILE="${OUTPUT_FILE}.build.json"

{
  printf '{\n'
  printf '  "version": "%s",\n' "$BUILD_VERSION"
  printf '  "mihomoVersion": "%s",\n' "$MIHOMO_VERSION"
  printf '  "mihomoCommit": "%s",\n' "$MIHOMO_COMMIT"
  printf '  "gvisorCommit": "%s",\n' "$GVISOR_COMMIT"
  printf '  "ohosPatchset": %s,\n' "$OHOS_PATCHSET"
  printf '  "goVersion": "%s",\n' "$("$OHOS_GO" version | awk '{print $3}')"
  printf '  "builtAt": "%s",\n' "$BUILD_TIME"
  printf '  "sha256": "%s"\n' "$OUTPUT_SHA256"
  printf '}\n'
} > "$MANIFEST_FILE"

ARKTS_BUILD_INFO_TMP="${ARKTS_BUILD_INFO}.tmp.$$"
{
  printf '%s\n' '// Generated from proxy_core/src/flclash/core-versions.env and the verified'
  printf '%s\n' '// libflclash.so build manifest. Keep this file in source control so a normal'
  printf '%s\n' '// HAP build always displays the exact native core it packages.'
  printf "export const CORE_VERSION: string = '%s'\n" "$BUILD_VERSION"
  printf "export const CORE_MIHOMO_COMMIT: string = '%s'\n" "$MIHOMO_COMMIT"
  printf "export const CORE_GVISOR_COMMIT: string = '%s'\n" "$GVISOR_COMMIT"
  printf "export const CORE_SHA256: string = '%s'\n" "$OUTPUT_SHA256"
  printf "export const CORE_BUILT_AT: string = '%s'\n" "$BUILD_TIME"
} > "$ARKTS_BUILD_INFO_TMP"
mv -f "$ARKTS_BUILD_INFO_TMP" "$ARKTS_BUILD_INFO"

echo "built: $OUTPUT_FILE"
echo "manifest: $MANIFEST_FILE"
echo "ArkTS build info: $ARKTS_BUILD_INFO"
echo "sha256: $OUTPUT_SHA256"
