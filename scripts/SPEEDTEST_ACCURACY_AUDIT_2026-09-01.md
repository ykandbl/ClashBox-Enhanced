# Node bandwidth measurement audit — 2026-09-01

## What is measured

The production menu has two sustained HTTP/1.1 measurements through the exact
selected Mihomo adapter:

- single connection: representative of one web/video/application transfer path;
- eight connections: representative of aggregate node capacity for parallel
  downloads and applications that open several connections.

Both modes use complete acknowledged payloads. Published Mbps is validated bytes
divided by the corresponding wall time. Incomplete downloads, unacknowledged
uploads and sizing-only warm-up traffic never enter the average.

## Calibration and regression evidence

- A controlled 80 Mbps rate-limited fixture measured 80.000 Mbps in both GET
  and POST paths and with one/eight workers. This validates byte and time math;
  it does not claim that an Internet test server is never the bottleneck.
- The long r15 real-device baseline on `美国5-原生:yhc222.com` measured
  94.66 Mbps down / 29.56 Mbps up, transferred 656.1 MB and took about 109 s
  against Fremont #75892.
- The medium r16 run measured 90.47 / 28.26 Mbps, transferred 233.2 MB and took
  about 50 s of core time against Palo Alto #64241. This was close to r15, but
  the different public server means it is supporting evidence rather than a
  controlled same-target comparison.
- r22 introduced a shared public target for 30 minutes, at least three complete samples
  and at least four measured seconds per direction. The final real-device cached
  single-link run took 15 s of native time and measured 15.12 / 16.65 Mbps. The
  same target's eight-link run took 16 s and measured 115.90 / 28.76 Mbps. Both
  were marked variable. This large single/multi difference is useful information:
  the current path had poor per-connection throughput while aggregate capacity
  remained much higher.
- The final r23 device package adds authoritative per-direction sample counters.
  Its cached single-link acceptance run completed in 13 s of native time with
  three download and four upload samples. The UI automation observed completion
  at 17 s because its external layout poll runs once every three seconds.

## r26 release acceptance

- The public target is now persisted for 24 hours in the application sandbox
  using a versioned, owner-only, atomically replaced cache file. It contains
  only the public target label and test URLs. Account credentials, tokens and
  subscription URLs are never stored in it.
- The first Yinghuochong VLESS/XHTTP run after installation included discovery
  and completed in about 23 s. After a real application force-stop and restart,
  the persisted-target run completed in 13 s with three download and four
  upload samples. The VPN was restored automatically.
- A Yinghuochong Hysteria2/UDP node completed the same cached single-link test in
  15 s with three download and five upload samples. This verifies that the
  measurement is not tied to one subscription protocol.
- When switching to BitzNet, its route could not use the target cached from the
  previous subscription. r25 invalidated that target, discovered a reachable
  replacement and completed the measurement in the same user action. The full
  recovery took 49 s because it included the failed attempt and rediscovery.
- A BitzNet eight-link run completed three download samples around 47–55 Mbps,
  but its upload streams timed out. The final result was correctly reported as
  failed rather than presenting the partial download phase as a successful
  bandwidth result.
- Manual cancellation left no synthetic result and did not interrupt the VPN.
  A separate single-link test continued after pressing Home and completed in
  the background with three samples in each direction; the VPN remained healthy.
- The dashboard was visually inspected on the real device in dark and light
  themes. Adaptive font bounds keep the live speed and summary values on one
  line, and the device theme was restored to follow-system after the check.
- The native core now runs a conservative mobile-connection reaper while the
  listener is active. A session must be at least 90 seconds old and show no
  upload or download byte change in two consecutive 30-second observations
  before it is closed. This handles half-open Telegram-style sessions without
  interrupting active transfers.

Release artifacts used for this acceptance:

- core: `v1.19.30-ohos.r26`
- core SHA-256: `ae8ac8f5b48a8e55976fadb28568d44e2b04507f46abcf180a19817831beea55`
- HAP SHA-256: `28efc0bc52bce5e5ca2221ab5de5e3adba198925fef93ccb48c27600c76867bb`

## Timing fixes verified on device

- Server discovery and bilateral validation are cached and shared by all nodes
  for 30 minutes, so comparisons use one target.
- The sizing warm-up uses the complete speedtest.net 1000 px payload; formal
  samples repeat complete payloads to reach their adaptive size.
- A variable sample set is labelled for retesting instead of silently extending
  the everyday test.
- Manual bandwidth tests lock out new IPPure/platform probes immediately. An
  already-running automatic probe gets at most two seconds before the speed test
  proceeds; deferred cards refresh after completion.

The app therefore targets about 10–15 s of native measurement after a server is
known. UI automation can report roughly two extra seconds because it includes
menu confirmation and polls completion every three seconds. The first test after
a VPN core restart additionally discovers and validates a public server.

## Interpretation and limitations

- A public server, the node-to-server route, radio conditions and provider load
  can all constrain a result. Compare nodes on the same phone/network and within
  the 30-minute shared-target window.
- A variable result is measured data, not a stable ranking. Repeat it while the
  network is idle before choosing between close nodes.
- Sample variation is not UDP packet loss. The current sustained test reports
  HTTP transfer consistency only.
- Single-link and multi-link values answer different questions and should remain
  separately labelled rather than collapsed into one generic speed score.
