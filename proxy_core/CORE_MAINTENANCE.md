# HarmonyOS NEXT core maintenance

> **Connection regression gate:** changes to TUN, VPN RPC, socket protection,
> relay wrappers, DNS, IPv6, MTU or the pinned core require a real-device test
> of new, reused and idle connections. A successful core build alone is not
> proof that long-lived connections are healthy.

The application embeds Mihomo as an OpenHarmony arm64 N-API shared library. It
does not consume the regular Linux or Android executable from upstream releases.

## Source layout

- `src/flclash/core`: clean, pinned `MetaCubeX/mihomo` submodule.
- `src/flclash/gvisor-ohos`: clean, pinned `MetaCubeX/gvisor` submodule.
- `src/flclash/patches/mihomo`: small bridge hooks required by the ArkTS wrapper.
- `src/flclash/patches/gvisor`: OpenHarmony VPN file-descriptor compatibility.
- `src/flclash/core-versions.env`: the reviewed release lock.
- `src/flclash/*.go`: the Harmony-specific N-API/TUN wrapper maintained here.

Release builds export the two exact submodule commits into a temporary staging
directory, apply the patch series there, run compile checks and cross-compile
`libflclash.so`. Submodule working-tree changes are therefore excluded from the
binary by construction.

The current local capability revision is `v1.19.31-ohos.r43`. The 2026-09-15
stable-core update advances Mihomo from v1.19.30 to v1.19.31 and gVisor to
`79317d808312e241b8da115b7e07a912c2e4631f`. It was hand-reviewed against the
upstream release notes and keeps the Harmony patch-set revision at r43 because
the local Harmony behavior did not change. The active Mihomo patch series still
applies after excluding the historical `0007-openai-tcp-activity-diagnostics`
diagnostic patch. The gVisor `0001` VPN FD `fstat` compatibility patch was
manually rebased onto the new exported `IsSocketFD` function, and
`0002-current-consumer-api-compat` was retired because upstream now provides
`SetAllowPromiscuousSource` and the UDP `ForwarderHandler` bool-return API
directly.

Patch-set r42
preserves relay TCP half-close through Mihomo's tracked connection wrapper so
that one direction reaching EOF does not discard the response direction. It
also retains the session-scoped control channel, ordered per-FD Harmony socket
protection, TUN readiness handshake, synchronous teardown barrier, 1280 MTU and
the real-device-validated gVisor baseline. Patch-set r36
pins the last real-device-validated Harmony gVisor baseline while retaining
Mihomo v1.19.30 and all locally maintained capabilities. This isolates a mobile
TCP/WebSocket regression introduced by the newer 2026 gVisor snapshot. Patch-set r35
serializes Harmony `VpnConnection.protect(fd)` calls in arrival order, matching
the last real-device-stable bridge and preventing concurrent platform calls from
misapplying protection during HTTPS/WebSocket connection bursts. Patch-set r34
restores the last real-device-stable, non-fatal socket-protection acknowledgement
semantics while retaining the current Mihomo, gVisor, subscription and speed-test
capabilities. A late or stale Harmony `protect(fd)` result remains visible in
diagnostics but no longer aborts a native TCP/TLS dial. Patch-set r33 introduced
session-scoped control sockets and explicit protection results. Patch-set r32
removes temporary high-frequency per-connection telemetry from the release
runtime after its diagnostic capture completed. Patch-set r31
restores the last validated Harmony/Android compatibility MTU of 1280 after a
controlled 1400 build reproduced minute-long ChatGPT message-send stalls.
Patch-set r30 was the 1400 diagnostic build and is not a release baseline.
Patch-set r29
makes the mobile-connection reaper opt-in rather than part of normal listener
startup. A byte-stationary connection can be a valid ChatGPT/HTTP2 long-poll
or response stream, so the timer must not close it while the VPN is serving
traffic. Foreground recovery in the ArkTS layer remains the only automatic
cleanup path because it knows the exact background boundary and compares two
connection snapshots. Patch-set r28 serializes node-switch responses and
hardens the VPN Extension handshake.

The 2026-09-13 application-side stability fix is part of the release gate even
though it does not change the Mihomo tag or `OHOS_PATCHSET`. It hardens the
one-shot `ClashBox.sock` control RPC and the ArkTS VPN recovery owner:

- `SocketProxyService.ets` and `SocketStubService.ets` now clean up socket
  listeners idempotently and complete one-shot responses through a stable
  server-side FIN sequence;
- `FlClashVpnService.ts` waits for response delivery before closing the
  control connection and keeps protect sockets isolated by VPN session;
- `EntryAbility.ets` probes real runtime health every five seconds, requires
  three consecutive failures, and serializes recovery so a transient socket
  event cannot create multiple VPN Extensions.

This fix specifically covers the regression in which a Harmony NetStack
close/receive race produced `errno=9`, after which a one-second watchdog
repeatedly restarted the VPN and made startup controls appear frozen. It must
be validated with the cold-start, node-switch, background-return and
pure-cellular ChatGPT cases.

The follow-up background-survival fix was validated against a new 10-minute
real-device observation. Before the fix, the main process, VPN process and
`vpn-tun` stayed present, but the watchdog reported repeated health-probe
failures and triggered an automatic recovery that returned `RPC连接已关闭`;
the TUN counters reset while the process IDs remained unchanged. This was a
watchdog false-positive/recovery race, not evidence that the system had killed
the VPN Extension. The follow-up changes therefore:

- pass an explicit 5-second timeout to the silent runtime probe, while keeping
  normal business RPC deadlines unchanged;
- prevent overlapping async watchdog probes even though the timer callback is
  asynchronous;
- require three serialized failures before rebuilding the VPN Extension; and
- invalidate an in-flight watchdog generation when stop/restart begins, so a
  stale recovery cannot start a new VPN after a user stop or a newer lifecycle.

The corresponding release HAP passed `scripts/verify-device.sh` and a new
approximately 10-minute background observation on serial
`DEVICE_SERIAL`. During the observation the two process IDs stayed stable,
`vpn-tun` stayed `UP/RUNNING` at MTU 1280, RX/TX errors and drops stayed at
zero, and no watchdog recovery or continuous-task cancellation was observed.
The subsequent foreground check returned the task to the foreground and
re-established `vpn-tun` with the same MTU and zero errors/drops; the new
foreground PID transition is recorded as a recovery-chain event rather than a
background kill.

Patch-set r27
makes the all-node daily-experience screening fail fast: an unavailable node
uses an eight-second transfer window and stops after its first failed download
or upload probe, while final sustained tests retain their full precision and
timeout. This prevents dead nodes from stalling the batch for repeated 90-second
windows. Patch-set r26 adds the foreground-boundary connection recovery
implementation; the old timer policy is retained only as testable code and is
not started by the runtime. Patch-set r25
adds a persisted validated speed-test target and one-shot rediscovery when a
cached target is unreachable through a different subscription. Patch-set r11
adds per-direction payload floors before a sample may be trusted: the standard
and high-precision tiers use at least 25 MB per download connection and 10 MB
per upload connection. This prevents a slow-started 5 MB transfer from looking
stable while materially under-reporting a 300+ Mbps path. Diagnostics disclose
the actual per-connection sample size. Patch-set r10
replaces fixed-byte and hard-cancel throughput probes with one calibrated
four-connection method shared by all three tiers. Download and upload warm up
separately, request sizes grow until a complete sample lasts long enough, the
selected size is repeated, and results expose per-direction variation and a
reliability verdict. Completed samples are reduced with P90; incomplete HTTP
transfers never become speed results. A deterministic rate-controlled fixture
guards the Mbps calculation and adaptive duration logic. Patch-set r9 exposes
partial-stream failures and per-direction sample counts/durations, excludes HTTP
error bodies and unacknowledged upload buffers from throughput, and uses atomic
upload byte accounting. The result dialog distinguishes measured endpoint
throughput from a guaranteed node maximum. Patch-set r8 keeps
usable full-speed streams in the aggregate when another parallel stream cannot
establish a sample; all attempted traffic remains counted. Patch-set r7 avoided
an observed rejection for a 16 MiB binary-sized request; this was not a general
10 MiB service limit. Upload requests declare their exact content length, and HTTP
rejections retain the returned status code for diagnosis. Patch-set r6 adds
three explicit node-throughput tiers: a 4.75 MiB economy sample, a 41 MiB
two-stream standard sample, and a four-stream time-bounded full-speed sample
whose traffic is determined by measured throughput instead of a byte ceiling.
It records actual payload bytes and counts uploads only after the test server
acknowledges them, preventing socket-buffer prefetch from inflating results.
Patch-set r5 adds native node stability and bandwidth probes. Patch-set r4 adds
sanitized node-latency failure codes, measured request duration and support for
the app's configured test URL (maximum 8 seconds). Upstream sources are unchanged.
The app shares a three-worker queue across individual/batch tests, discards
old-profile results and updates node cards without reloading proxy groups.
Patch-set r3 keeps
the pinned upstream core unchanged and adds the Harmony N-API fallback that
converts base64/V2Ray URI subscriptions into a provider-neutral `Subscription`
selector only when a provider does not return native Clash YAML/JSON. The app
first probes native configuration and provider formats with multiple standard
client identities; provider-native content remains the primary, lossless path.

## Rebuild the pinned release

```bash
cd proxy_core/src/flclash
./build.sh
./verify-core-ohos.sh
```

The result is written to `proxy_core/libs/arm64-v8a/libflclash.so`; a neighboring
`.build.json` records the upstream commits, patch-set revision, Go version and
SHA-256 digest.

## Review a future stable release

```bash
cd proxy_core/src/flclash
./check-core-update.sh v1.19.xx
```

The command downloads the candidate into a system temporary directory and tests
both patch series without changing the workspace. When it passes:

1. Review the upstream changelog, security fixes, protocol changes and breaking
   REST/config changes.
2. Update `core-versions.env` with the printed commits.
3. Advance the two clean submodules to those exact commits.
4. Run `./build.sh` and `./verify-core-ohos.sh`.
5. Rebuild the HAP and complete the device regression matrix below.
6. Increment `OHOS_PATCHSET` whenever Harmony behavior changes without changing
   the Mihomo tag.

## Device regression gate

- VPN start, stop, restart and foreground/background survival.
- Cold start must not surface a transient RPC/Ability failure while the VPN
  Extension socket is being recreated.
- A transient one-shot control-socket failure must not start a recovery loop:
  require three consecutive real health-probe failures and allow only one
  recovery operation at a time.
- A one-shot config RPC that closes during LocalSocket final-frame delivery must
  keep a short receive grace window; if the load still fails with a transient
  RPC/transport error, verify or rebuild the core and retry the same runtime
  config once before persisting `coreLoadState=error`/showing “核心·待重载”.
- After cold start, there must be one main process and one VPN Extension;
  `recv failed`, `errno=9`, `sock closed failed`, `ReStartVpn` and core-init
  failure must remain absent during the observation window.
- Rule mode, global mode, access-control allowlist and denylist.
- Node switching closes old connections and refreshes the public-IP card.
- DNS across Wi-Fi/mobile transitions, IPv4/IPv6 and system DNS changes.
- VLESS/XHTTP/TCP upload and streaming; Hysteria2/UDP and packet-loss behavior.
- ChatGPT message/upload/image generation, Grok media, X posting and Telegram.
- Complete a ChatGPT new/reused/idle-session and three-cycle rapid restart
  matrix, including one-to-one `[Protect] request`/`ok` evidence and
  bidirectional OpenAI `[TCP-FLOW]` growth.
- Both Yinghuochong and BitzNet profile switching and subscription parsing.
- Node latency: single/batch tests share a maximum of three workers, repeat taps
  do not enqueue a second batch, old-profile results are discarded, configured
  URLs reach the core, and failures retain sanitized cause codes. An 8-second
  cancellation that surfaces as EOF must still be classified as a timeout.
- In delay-sort mode, complete a batch while scrolled down: no group reload or
  jump to the top. Scroll/recycle all cards and correlate every label with its
  hashed diagnostic ID, including failed and unmeasured entries.
- Harmony VPN, Mihomo and gVisor all use MTU 1280; `vpn-tun` reports zero RX/TX
  errors and drops, and new/reused ChatGPT conversations continue streaming.
- There is one `_bgmode_` VPN notification only; the same key must receive
  repeated `isUpdate: true` updates containing node, upload and download data.
- With Wi-Fi disabled and cellular data available, `rmnet0` and `vpn-tun`
  must remain up, `vpn-tun` must keep MTU 1280 with zero RX/TX errors/drops,
  and a short ChatGPT message must complete successfully.

The repeatable local device gate is:

```bash
scripts/verify-device.sh --vpn-required --restart-app --serial SERIAL
```

Only a build that passes the computer checks and this device gate becomes the
new bundled core.

## Node-latency regression commands

From the application directory:

```bash
node scripts/test-node-delay.cjs
node scripts/test-bitz-subscription.cjs
node scripts/verify-node-delay-ui.cjs FILTERED_NODE_DELAY_LOG UI_DUMP_1 UI_DUMP_2
```

The first two commands use local fixtures and never read real subscriptions.
For the third, collect only `[NodeDelay]` log lines from the app process and
`uitest dumpLayout` snapshots covering the complete list after a batch. The
verifier requires every measured node to be covered and asserts exact agreement
between displayed results and native-test results, not merely a success count.
Latency checks are HTTP HEAD reachability/latency checks; they are distinct from
platform workflow checks and do not assert bandwidth or authenticated app usage.
