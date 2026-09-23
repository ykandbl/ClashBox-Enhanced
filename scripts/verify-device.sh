#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SERIAL=""
OFFLINE=0
VPN_REQUIRED=0
RESTART_APP=0
HAP_PATH="${HAP_PATH:-$APP_ROOT/entry/build/default/outputs/default/entry-default-unsigned.hap}"
BUNDLE_NAME="${BUNDLE_NAME:-org.xbgroup.clashboxLTS}"

usage() { echo "Usage: $0 [--offline] [--vpn-required] [--restart-app] [--serial SERIAL]"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --offline) OFFLINE=1; shift ;;
    --vpn-required) VPN_REQUIRED=1; shift ;;
    --restart-app) RESTART_APP=1; shift ;;
    --serial) SERIAL="${2:?missing serial}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

cd "$APP_ROOT"
node scripts/test-p0-regression.cjs
node scripts/test-bitz-subscription.cjs
node scripts/verify-stability-invariants.cjs
node scripts/test-rpc-socket-lifecycle.cjs

if [[ "$OFFLINE" == "1" ]]; then
  echo "LOCAL FIXTURE GATE PASSED; device matrix intentionally skipped (--offline)."
  exit 0
fi
if ! command -v hdc >/dev/null 2>&1; then
  echo "WAITING_FOR_PHONE: hdc is not installed or no phone tool is connected." >&2
  exit 3
fi

devices="$(hdc list targets 2>/dev/null | sed '/^[[:space:]]*$/d' || true)"
if [[ -z "$SERIAL" ]]; then SERIAL="$(printf '%s\n' "$devices" | head -n 1)"; fi
if [[ -z "$SERIAL" ]]; then
  echo "WAITING_FOR_PHONE: no HDC target detected." >&2
  exit 3
fi

HDC=(hdc -t "$SERIAL")
evidence="$(mktemp -d "${TMPDIR:-/tmp}/clashbox-device-gate.XXXXXX")"
cleanup() { echo "redacted evidence: $evidence"; }
trap cleanup EXIT

if [[ ! -f "$HAP_PATH" ]]; then
  echo "device gate requires HAP_PATH=$HAP_PATH" >&2
  exit 2
fi
"${HDC[@]}" install -r "$HAP_PATH" >"$evidence/install.txt" 2>&1
if [[ "$RESTART_APP" == "1" ]]; then
  "${HDC[@]}" shell aa force-stop "$BUNDLE_NAME" >"$evidence/force-stop.txt" 2>&1 || true
fi
"${HDC[@]}" shell aa start -b "$BUNDLE_NAME" -a EntryAbility >"$evidence/start.txt" 2>&1
layout_output="$("${HDC[@]}" shell uitest dumpLayout 2>&1 | tee "$evidence/layout-command.txt")"
layout_path="$(printf '%s\n' "$layout_output" | sed -n 's/.*saved to:\([^[:space:]]*\).*/\1/p' | tail -n 1)"
if [[ -z "$layout_path" ]]; then
  echo "device gate could not locate dumpLayout output" >&2
  exit 1
fi
"${HDC[@]}" shell cat "$layout_path" >"$evidence/layout.json"
grep -q 'org.xbgroup.clashboxLTS' "$evidence/layout.json"
app_pid="$("${HDC[@]}" shell pidof "$BUNDLE_NAME" 2>/dev/null | tr -d '\r' | awk '{print $1}')"
if [[ -z "$app_pid" ]]; then
  echo "device gate could not resolve the restarted app pid" >&2
  exit 1
fi

# Device evidence is limited to layout/log snippets and never copies profile bodies.
for attempt in $(seq 1 12); do
  "${HDC[@]}" shell "hilog -x -e 'ClashVPN-DIAG|SubscriptionCompat|NetworkRecovery|VpnLifecycle|NodeDelay'" \
    >"$evidence/hilog.txt" 2>&1 || true
  tr -d '\000' <"$evidence/hilog.txt" >"$evidence/hilog-clean.txt" || true
  if [[ "$VPN_REQUIRED" != "1" ]] || awk -v pid="$app_pid" \
    '$3 == pid && $4 == pid && /TUN ready|VPN.*运行|VpnLifecycle/ { found=1 } END { exit !found }' \
    "$evidence/hilog-clean.txt"; then
    break
  fi
  sleep 1
done
grep -E 'ClashVPN-DIAG|SubscriptionCompat|NetworkRecovery|VpnLifecycle|NodeDelay' \
  "$evidence/hilog-clean.txt" | tail -n 500 >"$evidence/relevant.log" || true
if [[ "$VPN_REQUIRED" == "1" ]]; then
  awk -v pid="$app_pid" \
    '$3 == pid && $4 == pid && /TUN ready|VPN.*运行|VpnLifecycle/ { found=1 } END { exit !found }' \
    "$evidence/hilog-clean.txt"
fi
echo "DEVICE GATE PASSED: serial=$SERIAL; cases=$(node -e "console.log(require('./scripts/fixtures/device-regression-matrix.json').cases.length)")"
