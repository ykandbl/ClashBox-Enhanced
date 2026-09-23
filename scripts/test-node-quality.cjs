#!/usr/bin/env node
// Deterministic regression checks for production node-quality calculations,
// traffic budgets and the long-running native RPC contract. No network,
// profile, credential or subscription data is read.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const ts = require(process.env.VPN_TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio-26-Beta.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');

function load(relative) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const code = ts.transpileModule(source, {compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
  }}).outputText;
  const exports = {};
  vm.runInNewContext(code, {exports, console, Date, Math, Number}, {filename: relative});
  return exports;
}

const quality = load('entry/src/main/ets/common/utils/NodeQualityService.ets');
const {NodeQualityService, medianNumber, nodeQualityCacheKey,
  autoFailoverHistoryScore, compactNodeQualitySample, dailyExperienceScore,
  experienceScreeningScore, qualityErrorText, selectExperienceCandidates,
  selectQualityCandidates, summarizeNodeQualityHistory, transferSpeedMbps} = quality;
const tests = [];
function test(name, fn) { tests.push({name, fn}); }

test('decimal Mbps and median calculations match byte/time samples', () => {
  assert.equal(transferSpeedMbps(2_000_000, 1000), 16);
  assert.equal(transferSpeedMbps(512 * 1024, 2000), 2.1);
  assert.equal(medianNumber([90, 300, 120]), 120);
  assert.equal(medianNumber([80, 100]), 90);
});

test('only the three fastest successful nodes become transfer candidates', () => {
  const picked = selectQualityCandidates([
    {name:'slow', delay:400, status:'ok'},
    {name:'timeout', delay:-1, status:'failed'},
    {name:'fast', delay:80, status:'ok'},
    {name:'mid', delay:150, status:'ok'},
    {name:'second', delay:100, status:'ok'},
  ], 3);
  assert.deepEqual(Array.from(picked), ['fast','second','mid']);
});

test('daily experience ranking rewards stable responsive single-link throughput', () => {
  const stable = {status:'ok', successRate:100, downloadMbps:60, uploadMbps:15,
    reliable:true, downloadVariationPercent:8, uploadVariationPercent:10};
  const unstable = {status:'ok', successRate:85, downloadMbps:300, uploadMbps:80,
    reliable:false, downloadVariationPercent:75, uploadVariationPercent:80};
  assert.ok(dailyExperienceScore(stable, 120) > dailyExperienceScore(unstable, 500));
  assert.equal(dailyExperienceScore({...stable, status:'failed'}, 120), 0);
});

test('daily experience shortlist uses real light transfers instead of latency alone', () => {
  const delays = [
    {name:'fast-but-broken', delay:40, status:'ok'},
    {name:'balanced', delay:95, status:'ok'},
    {name:'steady', delay:130, status:'ok'},
    {name:'fallback-only', delay:160, status:'ok'},
  ];
  const broken = {name:'fast-but-broken', status:'failed', successRate:0, jitterMs:0,
    downloadMbps:0, uploadMbps:0, downloadVariationPercent:100, uploadVariationPercent:100};
  const balanced = {name:'balanced', status:'ok', successRate:100, jitterMs:8,
    downloadMbps:45, uploadMbps:18, downloadVariationPercent:8, uploadVariationPercent:10};
  const steady = {name:'steady', status:'ok', successRate:100, jitterMs:12,
    downloadMbps:30, uploadMbps:12, downloadVariationPercent:12, uploadVariationPercent:12};
  assert.ok(experienceScreeningScore(balanced, 95) > experienceScreeningScore(broken, 40));
  const picked = selectExperienceCandidates(delays, [broken, steady, balanced], 3);
  assert.deepEqual(Array.from(picked), ['balanced', 'steady', 'fast-but-broken']);
});

test('bandwidth tiers disclose adaptive traffic instead of a false fixed budget', () => {
  assert.equal(NodeQualityService.expectedTrafficBytes('stability'), 640 * 1024);
  assert.equal(NodeQualityService.expectedTrafficBytes('bandwidth'), 0);
  assert.equal(NodeQualityService.expectedTrafficBytes('bandwidth_economy'), 0);
  assert.equal(NodeQualityService.expectedTrafficBytes('bandwidth_standard'), 0);
  assert.equal(NodeQualityService.expectedTrafficBytes('bandwidth_full'), 0);
  assert.equal(NodeQualityService.expectedTrafficBytes('bandwidth_official'), 0);
  assert.equal(NodeQualityService.expectedTrafficBytes('bandwidth_peak'), 0);
});

test('same named adapter shares cache across groups but not profiles', () => {
  assert.equal(nodeQualityCacheKey('p','group-a','node'), nodeQualityCacheKey('p','group-b','node'));
  assert.notEqual(nodeQualityCacheKey('p','group','node'), nodeQualityCacheKey('other','group','node'));
});

test('seven-day history summarizes repeated real tests without peak-speed bias', () => {
  const base = {profileId:'p', profileUpdatedAt:1, group:'g', name:'node', mode:'bandwidth_single_sustained'};
  const samples = [
    {...base, status:'ok', checkedAt:1000, latencyMs:120, successRate:100,
      downloadMbps:30, uploadMbps:10, reliable:true, downloadVariationPercent:8,
      uploadVariationPercent:10, experienceScore:82},
    {...base, status:'ok', checkedAt:2000, latencyMs:140, successRate:100,
      downloadMbps:300, uploadMbps:80, reliable:false, downloadVariationPercent:80,
      uploadVariationPercent:70, experienceScore:58},
    {...base, status:'failed', checkedAt:3000, latencyMs:0, successRate:0,
      downloadMbps:0, uploadMbps:0, reliable:false, downloadVariationPercent:100,
      uploadVariationPercent:100, experienceScore:0},
  ];
  const summary = summarizeNodeQualityHistory(samples);
  assert.equal(summary.sampleCount, 3);
  assert.equal(summary.successRate, 67);
  assert.equal(summary.medianDownloadMbps, 165);
  assert.equal(summary.consecutiveFailures, 1);
  assert.equal(compactNodeQualitySample({...samples[0], errorMessage:'', quality:'ok'}).reliable, true);
});

test('automatic failover prefers repeated reliable history and rejects repeated failures', () => {
  const steady = summarizeNodeQualityHistory([
    {status:'ok', checkedAt:1, latencyMs:120, successRate:100, downloadMbps:40, uploadMbps:12,
      reliable:true, experienceScore:85},
    {status:'ok', checkedAt:2, latencyMs:130, successRate:100, downloadMbps:42, uploadMbps:13,
      reliable:true, experienceScore:87},
    {status:'ok', checkedAt:3, latencyMs:125, successRate:100, downloadMbps:39, uploadMbps:11,
      reliable:true, experienceScore:84},
  ]);
  const flaky = summarizeNodeQualityHistory([
    {status:'ok', checkedAt:1, latencyMs:80, successRate:100, downloadMbps:250, uploadMbps:60,
      reliable:false, experienceScore:60},
    {status:'failed', checkedAt:2, latencyMs:0, successRate:0, downloadMbps:0, uploadMbps:0,
      reliable:false, experienceScore:0},
    {status:'failed', checkedAt:3, latencyMs:0, successRate:0, downloadMbps:0, uploadMbps:0,
      reliable:false, experienceScore:0},
  ]);
  assert.ok(autoFailoverHistoryScore(steady) > autoFailoverHistoryScore(flaky));
  assert.equal(autoFailoverHistoryScore(flaky), 0);
});

test('native result preserves real metrics and classifies transport errors', () => {
  const result = NodeQualityService.fromCore('p', 1, 'g', 'n', 'bandwidth',
    'ok', '稳定', 100, 20, 100, 26.59, 5.22, 4864 * 1024, '');
  assert.equal(result.downloadMbps, 26.59);
  assert.equal(result.uploadMbps, 5.22);
  assert.equal(result.transferredBytes, 4864 * 1024);
  assert.equal(qualityErrorText('timeout'), '连接超时');
  assert.equal(qualityErrorText('incomplete'), '传输未完成');
  assert.equal(qualityErrorText('http_403'), '测速服务拒绝请求（HTTP 403）');
});

test('partial native samples stay visible in the compatibility result model', () => {
  const result = NodeQualityService.fromCore('p', 1, 'g', 'n', 'bandwidth_full',
    'ok', '速度波动较大，仅供参考', 100, 20, 100, 200, 30, 250000000, '',
    '下载有效连接 8/8', false, 40, 12);
  assert.match(quality.nodeQualityBrief(result), /旧版测速结果，请重测/);
  assert.equal(result.diagnostic, '下载有效连接 8/8');
});

test('production RPC grants adaptive quality checks a bounded six-minute window', () => {
  const socket = fs.readFileSync(path.join(root,
    'proxy_core/src/main/ets/rpc/SocketProxyService.ets'), 'utf8');
  assert.match(socket, /nodeQualityCheck[\s\S]*?true,\s*360000\)/);
});

test('long-press actions bind an immutable node snapshot and identify it to the user', () => {
  const component = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Proxy/ProxyGroupItem.ets'), 'utf8');
  assert.match(component, /currentTouchProxyData\s*=\s*this\.snapshotProxyItem\(item\)/);
  assert.match(component, /content: '单连接 · 大文件持续测速'/);
  assert.match(component, /content: '多连接 · 大文件持续测速'/);
  assert.match(component, /confirmPeakBandwidthTest\(ProxyGroupItem\.currentTouchProxyData, false\)/);
  assert.match(component, /confirmPeakBandwidthTest\(ProxyGroupItem\.currentTouchProxyData, true\)/);
  assert.doesNotMatch(component, /带宽 · 快速/);
  assert.doesNotMatch(component, /带宽 · 标准/);
  assert.doesNotMatch(component, /带宽 · 高精度/);
  assert.match(component, /节点：\$\{item\.name\}/);
});

test('native fallback keeps complete adaptive four-stream samples and variation diagnostics', () => {
  const core = fs.readFileSync(path.join(root,
    'proxy_core/src/flclash/node_quality.go'), 'utf8');
  assert.match(core, /qualityBandwidthConcurrency\s*=\s*4/);
  assert.match(core, /qualityScreeningTimeout\s*=\s*8 \* time.Second/);
  assert.match(core, /qualityEconomyTimeout\s*=\s*15 \* time.Second/);
  assert.match(core, /params\.Mode ===?\s*"bandwidth_economy"|params\.Mode ==\s*"bandwidth_economy"/);
  assert.match(core, /qualityEconomyConcurrency\s*=\s*2/);
  assert.match(core, /qualityEconomyDownloadSizes\s*=\s*\[\]int\{512_000, 2_000_000\}/);
  assert.match(core, /qualityEconomyUploadSizes\s*=\s*\[\]int\{512_000, 2_000_000\}/);
  assert.match(core, /MinimumDownloadBytes:\s*2_000_000, MinimumUploadBytes:\s*2_000_000/);
  assert.match(core, /qualityScreeningTransfer/);
  assert.match(core, /if !probe\.Success \{/);
  assert.match(core, /qualityAdaptiveDirection\([\s\S]*?qualityParallelTransfer/);
  assert.match(core, /MinimumSampleDuration/);
  assert.match(core, /SampleCount/);
  assert.match(core, /MinimumDownloadBytes:\s*25_000_000/);
  assert.match(core, /MinimumUploadBytes:\s*10_000_000/);
  assert.doesNotMatch(core, /qualitySustainedTransfer/);
  assert.match(core, /DownloadVariation/);
  assert.match(core, /PayloadBytes\s+int64/);
});

test('official speed test uses the vendored Cloudflare engine through the selected node', () => {
  const component = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Proxy/ProxyGroupItem.ets'), 'utf8');
  const runner = fs.readFileSync(path.join(root,
    'entry/src/main/resources/rawfile/speedtest/cloudflare_runner.html'), 'utf8');
  const engine = fs.readFileSync(path.join(root,
    'entry/src/main/resources/rawfile/speedtest/cloudflare-speedtest-1.13.1.js'), 'utf8');
  const license = fs.readFileSync(path.join(root,
    'entry/src/main/resources/rawfile/speedtest/CLOUDFLARE_SPEEDTEST_LICENSE.txt'), 'utf8');
  assert.match(runner, /cloudflare-speedtest-1\.13\.1\.js/);
  assert.match(runner, /new window\.CloudflareSpeedTest/);
  assert.match(runner, /logAimApiUrl:\s*null/);
  assert.match(runner, /logMeasurementApiUrl:\s*null/);
  assert.match(runner, /bandwidthPercentile:\s*0\.9/);
  assert.match(engine, /window\.CloudflareSpeedTest\s*=\s*SpeedTestEngine/);
  assert.doesNotMatch(engine, /^export /m);
  assert.match(license, /MIT License/);
  assert.match(component, /ProxyController\.applyProxyOverride/);
  assert.match(component, /ProxyController\.removeProxyOverride/);
  assert.match(component, /socketProxy\.changeProxy\(routingGroupName, item\.name\)/);
  assert.match(component, /socketProxy\.changeProxy\(this\.officialSpeedGroup, this\.officialPreviousProxy\)/);
  assert.match(component, /bandwidth_official/);
  assert.match(component, /connection\.chains\.includes\(target\.name\)/);
  assert.match(component, /this\.officialPreviousProxy = runtimeGroup\.now/);
  assert.match(component, /fireflyStopSpeedTest/);
});

test('peak speed test uses pinned speedtest-go through the explicit target adapter', () => {
  const component = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Proxy/ProxyGroupItem.ets'), 'utf8');
  const core = fs.readFileSync(path.join(root,
    'proxy_core/src/flclash/peak_speedtest.go'), 'utf8');
  const gomod = fs.readFileSync(path.join(root,
    'proxy_core/src/flclash/go.mod'), 'utf8');
  const license = fs.readFileSync(path.join(root,
    'entry/src/main/resources/rawfile/speedtest/SHOWWIN_SPEEDTEST_GO_LICENSE.txt'), 'utf8');
  assert.match(gomod, /github\.com\/showwin\/speedtest-go v1\.8\.0/);
  assert.match(core, /peakSpeedtestConnections\s*=\s*8/);
  assert.match(core, /peakSpeedtestDuration\s*=\s*15 \* time\.Second/);
  assert.match(core, /return proxy\.DialContext\(ctx, metadata\)/);
  assert.match(core, /speedtest\.WithDoer\(client\)/);
  assert.match(core, /target\.DownloadTestContext\(ctx\)/);
  assert.match(core, /target\.UploadTestContext\(ctx\)/);
  assert.match(core, /GetTotalDownload\(\)/);
  assert.match(core, /GetTotalUpload\(\)/);
  assert.match(core, /validPeakCaptureDuration\(target\.TestDuration\.Download\)/);
  assert.match(core, /validPeakCaptureDuration\(target\.TestDuration\.Upload\)/);
  assert.match(component, /'bandwidth_multi_sustained'/);
  assert.match(component, /流量.*formatPeakTraffic\(this\.sustainedTrafficBytes\)/);
  assert.match(license, /MIT License/);
});

test('active modes require full sustained samples and never hard-code reliable', () => {
  const core = fs.readFileSync(path.join(root, 'proxy_core/src/flclash/sustained_bandwidth.go'), 'utf8');
  const progress = fs.readFileSync(path.join(root, 'proxy_core/src/flclash/sustained_progress.go'), 'utf8');
  const routing = fs.readFileSync(path.join(root, 'proxy_core/src/flclash/node_quality.go'), 'utf8');
  const rpc = fs.readFileSync(path.join(root, 'proxy_core/src/main/ets/rpc/SocketProxyService.ets'), 'utf8');
  const group = fs.readFileSync(path.join(root, 'entry/src/main/ets/components/Proxy/ProxyGroupItem.ets'), 'utf8');
  assert.match(core, /sustainedMinimumTime\s*=\s*4 \* time.Second/);
  assert.match(core, /sustainedMinimumSamples\s*=\s*3/);
  assert.match(core, /result.Reliable = sustainedStable\(down.Samples\) && sustainedStable\(up.Samples\)/);
  assert.match(core, /bytesPerSecondMbps\(bytes, milliseconds\)/);
  assert.doesNotMatch(core, /percentileFloat|Reliable:\s*true/);
  assert.match(core, /Cloudflare 备用测速源/);
  assert.match(core, /buildSustainedResult/);
  assert.match(routing, /NextProtos = \[\]string\{"http\/1.1"\}/);
  assert.match(progress, /TransferredBytes[\s\S]*ElapsedMs[\s\S]*cancelSustainedProgress/);
  assert.match(rpc, /nodeQualityProgress\(\)[\s\S]*cancelNodeQuality\(\)/);
  assert.match(group, /sustainedDownloadPoints/);
  assert.match(group, /sustainedUploadPoints/);
  assert.match(group, /实时下载/);
  assert.match(group, /停止测速/);
});

test('proxy page exposes one daily-experience batch action and ranks fast adaptive tests', () => {
  const page = fs.readFileSync(path.join(root, 'entry/src/main/ets/pages/ProxyPage.ets'), 'utf8');
  const viewModel = fs.readFileSync(path.join(root,
    'entry/src/main/ets/entryability/ClashViewModel.ets'), 'utf8');
  assert.match(page, /experienceButton\(\)/);
  assert.doesNotMatch(page, /this\.delayButton\(\)|this\.qualityButton\(\)/);
  assert.match(page, /DailyExperienceBatchButton/);
  assert.match(viewModel, /testDailyExperience[\s\S]*?measurementMode: NodeQualityMode = 'bandwidth_economy'/);
  assert.match(viewModel, /candidatePoolLimit\s*=\s*Math\.max\(successLimit, Math\.min\(5, successLimit \+ 2\)\)/);
  assert.match(viewModel, /selectQualityCandidates\(delays, candidatePoolLimit\)/);
  assert.match(viewModel, /runNodeQualityBatchLocked\([\s\S]*?measurementMode, false, '快速实测', 25, 75, false, successLimit, 3\)/);
  assert.match(viewModel, /successLimit: number = 0/);
  assert.match(viewModel, /parallelism: number = 1/);
  assert.match(viewModel, /Promise\.all\(currentItems\.map/);
  assert.match(viewModel, /if \(successLimit > 0 && successful >= successLimit\) break/);
  assert.match(viewModel, /candidates: results\.length/);
  assert.match(viewModel, /commitDailyExperienceResults/);
  assert.match(viewModel, /publishResults: boolean = true/);
  assert.doesNotMatch(viewModel, /runNodeQualityBatchLocked\(profile, group, reachableItems,[\s\S]*?'stability', false, '筛'/);
  assert.match(viewModel, /dailyExperienceScore/);
  assert.match(viewModel, /experienceRank = index \+ 1/);
  assert.match(page, /只重测失败/);
  assert.doesNotMatch(page, /this\.needChangeSort\s*=\s*true/);
  assert.match(viewModel, /nodeQualitySortRevision/);
  assert.match(viewModel, /config\.proxySort\s*=\s*ProxySort\.Experience/);
  assert.match(page, /最多5个候选/);
  assert.match(page, /快速测试完成/);
});

test('daily experience publishes visible progress before its bounded network wait', () => {
  const viewModel = fs.readFileSync(path.join(root,
    'entry/src/main/ets/entryability/ClashViewModel.ets'), 'utf8');
  assert.match(viewModel, /nodeQualityTestRunning', true\)[\s\S]*?nodeQualityTestProgress', '准备中 · 0%'/);
  assert.match(viewModel, /waitForAutomaticNetworkChecks\(8, false\)/);
  assert.match(viewModel, /连通性 \$\{completed\}\/\$\{total\} · \$\{percent\}%/);
  assert.match(viewModel, /progressStart: number = 0, progressWeight: number = 100/);
});

test('vpn watchdog uses guarded three-strike node failover with candidate verification', () => {
  const viewModel = fs.readFileSync(path.join(root,
    'entry/src/main/ets/entryability/ClashViewModel.ets'), 'utf8');
  const diagnostics = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Settings/RuntimeDiagnostics.ets'), 'utf8');
  assert.match(viewModel, /nodeFailoverFailures\+\+/);
  assert.match(viewModel, /nodeFailoverFailures < 3/);
  assert.match(viewModel, /nodeFailoverLastUserChangeAt < 2 \* 60 \* 1000/);
  assert.match(viewModel, /nodeFailoverLastSwitchAt < 5 \* 60 \* 1000/);
  assert.match(viewModel, /const candidateDelay = await this\.testDelay\(candidate\.item\.name\)/);
  assert.match(viewModel, /changeProxy\(context\.profile, context\.group\.name,[\s\S]*?'auto'\)/);
  assert.match(viewModel, /closeConnectionsFromNode\(oldName\)/);
  assert.match(diagnostics, /节点自动接管/);
  assert.match(diagnostics, /约每分钟主备检查/);
  assert.match(diagnostics, /setAutoFailoverEnabled\(enabled\)/);
});

test('vpn startup accepts an already-running tunnel before the control reply timeout', () => {
  const viewModel = fs.readFileSync(path.join(root,
    'entry/src/main/ets/entryability/ClashViewModel.ets'), 'utf8');
  assert.match(viewModel, /startClashWithRuntimeWitness[\s\S]*?Promise\.race<boolean>/);
  assert.match(viewModel, /waitForStartedTunnelOrRequest[\s\S]*?coreIsResponsive\(true\)/);
  assert.match(viewModel, /let result = await this\.startClashWithRuntimeWitness\(silent\)/);
});

test('delay probes use two independent targets and node menu exposes diagnostics', () => {
  const viewModel = fs.readFileSync(path.join(root,
    'entry/src/main/ets/entryability/ClashViewModel.ets'), 'utf8');
  const runner = fs.readFileSync(path.join(root,
    'entry/src/main/ets/common/utils/NodeDelayRunner.ets'), 'utf8');
  const group = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Proxy/ProxyGroupItem.ets'), 'utf8');
  assert.match(viewModel, /probeNodeDelayWithFallback/);
  assert.match(viewModel, /cp\.cloudflare\.com\/generate_204/);
  assert.match(viewModel, /www\.gstatic\.com\/generate_204/);
  assert.match(runner, /primaryErrorCode/);
  assert.match(runner, /fallbackErrorCode/);
  assert.match(group, /节点检测详情/);
  assert.match(group, /重测可达性/);
  assert.match(group, /delayConclusion/);
});

test('recycled node taps resolve the current card and rapid taps are serialized', () => {
  const card = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Proxy/ProxyNodeItem.ets'), 'utf8');
  const group = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Proxy/ProxyGroupItem.ets'), 'utf8');
  assert.match(card, /selectCurrentProxy\(\)[\s\S]*?this\.selectProxy\?\.\(this\.item\)/);
  assert.doesNotMatch(group, /\.onClick\(\(\)\s*=>\s*\{\s*this\.selectProxy\(item\)/);
  assert.match(group, /while \(this\.pendingSelection\)/);
  assert.match(group, /const target = this\.snapshotProxyItem\(item\)/);
  // The radio is rendered from the child's optimistic state.  The previous
  // assertion targeted the removed @Reusable implementation, which assigned
  // the incoming @Prop and could reintroduce the stale-node race.
  assert.match(group, /if \(!this\.pendingSelection\)[\s\S]*?this\.selectedNodeName = this\.confirmedSelectedName/);
  assert.match(group, /this\.appConfig\.currentProxyName = this\.confirmedCurrentName/);
});

test('list arrangement passes the owning proxy group into node speed actions', () => {
  const arrangement = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Proxy/ProxyArrangement.ets'), 'utf8');
  assert.match(arrangement, /ProxyGroupItem\(\{\s*proxyGroup:\s*index,/);
});

test('connection page separates live app routes from retained connection history', () => {
  const connect = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/More/Connect.ets'), 'utf8');
  assert.match(connect, /summarizeConnectionsByApp/);
  assert.match(connect, /this\.appRouteSummaries = (?:await )?this\.resolveBundleNames\(summarizeConnectionsByApp\(result\)\)/);
  assert.match(connect, /this\.refreshRouteCounts\(result\)/);
  assert.match(connect, /this\.activeConnectionCount = result\.length/);
  assert.match(connect, /Button\('按应用'\)/);
  assert.match(connect, /Button\('连接详情'\)/);
  assert.match(connect, /setInterval\([\s\S]*?3000\)/);
  assert.match(connect, /route === '混合'/);
});

test('platform checks clear stale data, publish each platform and keep dialog actions visible', () => {
  const service = fs.readFileSync(path.join(root,
    'entry/src/main/ets/common/utils/PlatformConnectivityService.ets'), 'utf8');
  const index = fs.readFileSync(path.join(root,
    'entry/src/main/ets/pages/Index.ets'), 'utf8');
  const dialog = fs.readFileSync(path.join(root,
    'entry/src/main/ets/components/Home/CurrentNode.ets'), 'utf8');
  assert.match(service, /for \(const target of PLATFORM_TARGETS\)/);
  assert.match(service, /request\(target\.url,[\s\S]*?method:\s*http\.RequestMethod\.HEAD/);
  assert.match(service, /onProgress\(results\.slice\(\), results\.length, PLATFORM_TARGETS\.length\)/);
  assert.match(index, /platformCheckResults', '\[\]'[\s\S]*?PlatformConnectivityService\.testAll/);
  assert.match(index, /platformCheckResults', JSON\.stringify\(partialResults\)/);
  assert.match(dialog, /List\(\{ space: 7 \}\)[\s\S]*?\.layoutWeight\(1\)/);
  assert.match(dialog, /Button\(this\.platformCheckState[\s\S]*?\.height\(42\)/);
  assert.doesNotMatch(dialog, /List\(\{ space: 7 \}\)[\s\S]{0,2600}?\.height\(500\)/);
});

for (const {name, fn} of tests) {
  fn();
  console.log('PASS ' + name);
}
console.log(`node-quality regressions passed: ${tests.length}`);
