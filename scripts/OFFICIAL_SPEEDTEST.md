# Node speed-test integrations

## Current production path: sustained sampling (ohos.r26)

The active long-press menu now exposes **单连接 · 大文件持续测速** and
**多连接 · 大文件持续测速**. Both call the native `sustained_bandwidth.go`
sampler through the exact selected Mihomo adapter; there is no selector mutation
or ArkWeb proxy override. Both use the same speedtest-go-discovered server,
pinned globally for all tested adapters and force
HTTP/1.1 so eight workers are not silently multiplexed into one HTTP/2 connection.
The bidirectionally validated public target is stored in the application sandbox
for up to 24 hours, so restarting the process does not repeat server discovery
before every first test. The cache contains only the public test-server label and
URLs, is written atomically with mode 0600, and is never mixed with account or
subscription credentials. If that server later fails through another node or
subscription—or if a newly discovered server closes the first formal large
sample—the same test action deletes it, discovers a new bidirectional target,
and retries once. The in-memory comparison lease is still
renewed in 30-minute windows while the persisted target remains valid.

The sampler warms persistent connections for about one second, then
collects at least three complete payload samples covering at least four seconds per
direction. Payload size adapts toward 1.3 seconds per sample (up to 250 MB
download / 50 MB upload per connection). The server's complete 1000px random image is
repeated over persistent connections to meet the download sample size. Short samples are sizing costs only.
No fixed total-data budget is imposed. A stalled individual sample has an 8-second
deadline; the whole operation is bounded at 60 seconds. A deadline produces an
incomplete result, not a successful peak.

Published throughput is total validated payload / total sample wall time, not
P90, a maximum tick, or a mean of unequal-duration rates. Upload counts only full
requests acknowledged with successful HTTP responses. After the minimum sample
window, the final three-sample coefficient of variation and the first/second-half
drift must be within 15% to report "样本稳定". A variable run keeps its measured
result but is explicitly marked for retesting; it does not secretly extend the
everyday test. This is sample
consistency, not a guarantee of absolute accuracy or a universal node capacity.

The details list per-sample speeds, warmup time, measured duration, CV, the pinned
server name/ID and transferred traffic including warmup. Before pinning a server,
the core validates both a download and an acknowledged upload through the exact
adapter; failed servers are skipped. Upload samples use repeated 4 MB chunks on
one persistent HTTP/1.1 path because public `upload.php` implementations are not
required to accept one unusually large request. The download and upload phases
are separated by closing stale idle connections.

The app polls native progress while a run is active and shows live throughput,
separate download/upload curves, elapsed time, sample count, transferred traffic,
the fixed server and a stop control. Progress byte counters are observational;
the final published result still comes only from complete validated samples.

The initial Cloudflare
backend trial encountered HTTP 403 on a real node; this is why the active long
test uses dedicated speed-test servers rather than relying on a web endpoint.

Calibration checks cover the 1/8-worker paths on a controlled 80 Mbps fixture,
upload acknowledgement, error payload rejection, weighted means, sample duration
gates, real test-target content validation and ramp-up rejection. `scripts/speedtest_audit.go -mode fixture` independently
demonstrates a flaw in the old 15-second wrapper: the upstream sampler can finish
normally at about 10.1 seconds, which the former 12-second gate falsely rejected.

The integrations described below are retained for historical comparison and
dependency provenance, **not active production menu choices**. The new sustained
sampler is our measurement layer, not an unmodified upstream Cloudflare or
speedtest-go algorithm. The old modes/results must not be mixed into its ranking.

## Historical integrations

The product deliberately exposes two different measurements instead of
presenting every result as generic "bandwidth":

- **网页链路 · Cloudflare（单连接）** measures the kind of HTTP path used by
  web pages, social feeds and application APIs. It is sensitive to latency and
  per-connection quality.
- **峰值带宽 · speedtest-go（8连接）** saturates the selected adapter with
  concurrent transfers. It is useful for large downloads and the upper bound
  of the node, but does not promise the same throughput to a specific video
  platform.

## Cloudflare web-link measurement

The node long-press menu runs `@cloudflare/speedtest` **1.13.1** (MIT), vendored
from its npm release. Upstream: https://github.com/cloudflare/speedtest

Upstream `dist/speedtest.js` SHA-256:
`06196f490f3735f2dfbdeb672edbfa5e3cac8672b7e0d09213c084f681543c5c`.
The only distribution-file adaptation is changing its ESM export to
`window.CloudflareSpeedTest` (plus a final newline). This is necessary for the
phone's ArkWeb `resource:/RAWFILE` loader. No timing, sample-size, or percentile
algorithm is patched. The upstream MIT license ships alongside the asset.

The runner uses the upstream default HTTP measurement sequence, including
interleaved idle and loaded latency, and the official P90 result. WebRTC/TURN
packet-loss measurement is excluded: an HTTP proxy override would not establish
that UDP traversed the selected proxy. Result-reporting endpoints are disabled.
The app imposes a 90-second request timeout and six-minute whole-test timeout;
incomplete/failed runs are not accepted as successful bandwidth measurements.

Before starting, wait for IP/platform probes, snapshot the live core selector,
close only this app's loopback Cloudflare speed connections, temporarily select
the target, and explicitly route ArkWeb through the mixed port. In global mode,
the GLOBAL selector is used. While running, inspect the core connection chain;
a test is accepted only if the selected node appears in the actual route.
Cancel, error, completion and component disappearance pause the engine, close
remaining speed-test connections, restore the live selector, remove the ArkWeb
override and release the quality-test lock. No profile selection is persisted.

Meaning: HTTP throughput **through this node to Cloudflare**, not an absolute
node capacity or a promise of throughput to every destination. Completed sample
traffic excludes retries and protocol overhead. Keep the screen on, use the same
Wi-Fi, and avoid competing transfers when comparing repeated runs. Bandwidth
tests remain manually initiated because they can consume hundreds of MB.

Regression checks (offline):

```sh
node scripts/test-node-quality.cjs
node scripts/test-official-speed-runner.cjs
```

Future upstream updates: pin the new release, retain its license, update the
asset/export adaptation and provenance hash, run both checks, build a release,
then test at least two real nodes, repeated runs, cancellation and route restore.
Never replace the official P90 with a custom peak while retaining the official
label. Old native modes remain an internal compatibility API, not menu choices.

## speedtest-go peak measurement

The native core pins `github.com/showwin/speedtest-go` **1.8.0** (MIT).
Upstream: https://github.com/showwin/speedtest-go

The engine discovers speedtest.net servers through the selected proxy, chooses
the available server with the lowest measured HTTP latency, then runs a
15-second download and a 15-second upload with eight concurrent connections.
The whole operation has a 70-second deadline. The UI reports the selected test
server, duration and actual application payload so high traffic use is visible.

Every HTTP connection uses a custom `DialContext` that calls the exact Mihomo
adapter selected from the node card. It does not change the live selector and
does not depend on ArkWeb, a loopback mixed port, the operating-system proxy or
the Mac proxy client. This also means a test of a non-current node cannot leave
the user's policy group on the wrong node.

The peak result is the speed between that proxy exit and the selected
speedtest.net test server. Compare repeated runs on the same phone, access
network and test conditions; use the Cloudflare result for web-link experience.

The pinned version supports the project's Go 1.24 OpenHarmony toolchain. For an
upstream update, inspect the release and license, update `go.mod`, run the Go and
Node regression suites, rebuild the OpenHarmony library, then repeat real-device
tests on at least two protocols. Do not silently change connection count,
capture duration or the traffic disclosure.
