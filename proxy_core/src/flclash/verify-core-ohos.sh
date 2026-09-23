#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
OUTPUT_FILE="${1:-$SCRIPT_DIR/../../libs/arm64-v8a/libflclash.so}"
MANIFEST_FILE="${OUTPUT_FILE}.build.json"
ARKTS_BUILD_INFO="$SCRIPT_DIR/../../src/main/ets/CoreBuildInfo.ets"

# shellcheck disable=SC1090
source "$SCRIPT_DIR/core-versions.env"

OHOS_GO="${OHOS_GO:-$WORKSPACE_DIR/.tools/ohos_golang_go/bin/go}"
OHOS_NATIVE_HOME="${OHOS_NATIVE_HOME:-/Applications/DevEco-Studio-26-Beta.app/Contents/sdk/default/openharmony/native}"
READELF="$OHOS_NATIVE_HOME/llvm/bin/llvm-readelf"
NM="$OHOS_NATIVE_HOME/llvm/bin/llvm-nm"
EXPECTED_VERSION="${MIHOMO_VERSION}-ohos.r${OHOS_PATCHSET}"

[[ -f "$OUTPUT_FILE" ]] || { echo "core output not found: $OUTPUT_FILE" >&2; exit 1; }
[[ -f "$MANIFEST_FILE" ]] || { echo "core manifest not found: $MANIFEST_FILE" >&2; exit 1; }
[[ -f "$ARKTS_BUILD_INFO" ]] || { echo "ArkTS core build info not found: $ARKTS_BUILD_INFO" >&2; exit 1; }
FILE_INFO="$(file "$OUTPUT_FILE")"
BUILD_INFO="$("$OHOS_GO" version -m "$OUTPUT_FILE")"
DYNAMIC_INFO="$("$READELF" -d "$OUTPUT_FILE")"
SYMBOL_INFO="$("$NM" -D "$OUTPUT_FILE")"
OUTPUT_SHA256="$(shasum -a 256 "$OUTPUT_FILE" | awk '{print $1}')"
MANIFEST_VERSION="$(sed -n 's/^[[:space:]]*"version": "\([^"]*\)".*/\1/p' "$MANIFEST_FILE")"
MANIFEST_MIHOMO_COMMIT="$(sed -n 's/^[[:space:]]*"mihomoCommit": "\([^"]*\)".*/\1/p' "$MANIFEST_FILE")"
MANIFEST_GVISOR_COMMIT="$(sed -n 's/^[[:space:]]*"gvisorCommit": "\([^"]*\)".*/\1/p' "$MANIFEST_FILE")"
MANIFEST_SHA256="$(sed -n 's/^[[:space:]]*"sha256": "\([^"]*\)".*/\1/p' "$MANIFEST_FILE")"

grep -q 'ELF 64-bit.*shared object, ARM aarch64' <<< "$FILE_INFO"
grep -aF "$EXPECTED_VERSION" "$OUTPUT_FILE" >/dev/null
grep -Fq $'path\tcore' <<< "$BUILD_INFO"
grep -Fq 'Shared library: [libace_napi.z.so]' <<< "$DYNAMIC_INFO"
grep -Fq 'Shared library: [libhilog_ndk.z.so]' <<< "$DYNAMIC_INFO"
grep -Eq '[[:space:]]T[[:space:]]InitializeModule$' <<< "$SYMBOL_INFO"
[[ "$MANIFEST_VERSION" == "$EXPECTED_VERSION" ]]
[[ "$MANIFEST_MIHOMO_COMMIT" == "$MIHOMO_COMMIT" ]]
[[ "$MANIFEST_GVISOR_COMMIT" == "$GVISOR_COMMIT" ]]
[[ "$MANIFEST_SHA256" == "$OUTPUT_SHA256" ]]
grep -Fq "export const CORE_VERSION: string = '$MANIFEST_VERSION'" "$ARKTS_BUILD_INFO"
grep -Fq "export const CORE_MIHOMO_COMMIT: string = '$MANIFEST_MIHOMO_COMMIT'" "$ARKTS_BUILD_INFO"
grep -Fq "export const CORE_GVISOR_COMMIT: string = '$MANIFEST_GVISOR_COMMIT'" "$ARKTS_BUILD_INFO"
grep -Fq "export const CORE_SHA256: string = '$MANIFEST_SHA256'" "$ARKTS_BUILD_INFO"

echo "Harmony core verification passed"
echo "version: $EXPECTED_VERSION"
echo "sha256: $OUTPUT_SHA256"
