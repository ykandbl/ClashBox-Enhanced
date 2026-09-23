#!/usr/bin/env node
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require(process.env.VPN_TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio-26-Beta.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const root = path.resolve(__dirname, '..');

function load(relative) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8').replace(/^@Concurrent\s*$/gm, '');
  const code = ts.transpileModule(source, { compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
  }}).outputText;
  const exports = {};
  vm.runInNewContext(code, { exports, console, setTimeout, clearTimeout }, { filename: relative });
  return exports;
}

const expiry = load('entry/src/main/ets/common/utils/SubscriptionExpiryNoticeLogic.ets');
const diagnostics = load('entry/src/main/ets/common/utils/RuntimeDiagnosticsService.ets');
const day = 24 * 60 * 60 * 1000;
const now = Date.UTC(2026, 0, 1, 12);

assert.equal(expiry.buildSubscriptionExpiryNotice('p', now + 8 * day, now), null);
assert.equal(expiry.buildSubscriptionExpiryNotice('p', now + 7 * day, now).severity, 'warning');
assert.match(expiry.buildSubscriptionExpiryNotice('p', now + 3 * day, now).text, /3 天/);
assert.match(expiry.buildSubscriptionExpiryNotice('p', now + day, now).marker, /:1:/);
assert.equal(expiry.buildSubscriptionExpiryNotice('p', now - 1, now).severity, 'expired');
const first = expiry.buildSubscriptionExpiryNotice('p', now + 3 * day, now);
assert.equal(first.marker, expiry.buildSubscriptionExpiryNotice('p', now + 3 * day, now).marker);

const packageText = diagnostics.buildRedactedDiagnostics({
  generatedAt: new Date(now).toISOString(), appVersion: 'fixture', coreVersion: 'fixture-core',
  vpnRunning: true, tunHealthy: true, backgroundTaskRunning: true, offlineRecordCount: 2,
  profiles: [{ id: 'fixture-profile', provider: 'yhc', accountState: 'ok',
    subscriptionState: 'ok', subscriptionFormat: 'Clash YAML', subscriptionNodeCount: 34,
    lastGoodContentId: 'fnv1a-deadbeef-12', subscriptionPendingRepair: false,
    subscriptionRetryAt: 0, coreLoadState: 'loaded', coreLoadedContentId: 'fnv1a-deadbeef-12',
    coreLoadedAt: now, lastError: 'request https://private.example/sub?token=secret ' + 'x'.repeat(80) }],
  recentErrors: ['Authorization: bearer ' + 'y'.repeat(80)]
});
assert.match(packageText, /clashbox-diagnostics\/v1/);
assert.match(packageText, /fnv1a-deadbeef-12/);
assert.doesNotMatch(packageText, /private\.example|token=secret|Authorization: bearer|xxxxx/);
assert.doesNotMatch(packageText, /proxies:/);

console.log('P0 state/expiry/diagnostics fixture assertions passed');
