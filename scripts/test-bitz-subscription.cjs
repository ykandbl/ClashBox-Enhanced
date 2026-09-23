#!/usr/bin/env node
// Runs production ArkTS logic with small Harmony adapters; no credentials/network required.
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const ts = require(process.env.VPN_TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio-26-Beta.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const yaml = require(path.join(root, 'oh_modules/yaml/dist/index.js'));
const quiet = {info() {}, warn() {}, error() {}, debug() {}};
const sdkUtil = {
  TextEncoder: class {encodeInto(text) { return new TextEncoder().encode(text); }},
  TextDecoder: {create() {return {decodeWithStream(bytes) {return new TextDecoder().decode(bytes);}}}},
};
function loadSource(relative, adapters = {}) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8').replace(/^@Concurrent\s*$/gm, '');
  const code = ts.transpileModule(source, {compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
  }}).outputText;
  const exports = {};
  vm.runInNewContext(code, {exports, console: quiet, setTimeout, clearTimeout, Buffer,
    require(name) {
      if (name === 'yaml') return yaml;
      if (name === '@kit.ArkTS') return {JSON, util: sdkUtil};
      if (name === '@kit.PerformanceAnalysisKit') return {hilog: quiet};
      if (Object.hasOwn(adapters, name)) return adapters[name];
      // Type-only/unreached SDK dependencies are deliberately inert.
      return {};
    },
  }, {filename: relative});
  return exports;
}
let responseFactory;
const requests = [];
const network = {http: {
  RequestMethod: {GET:'GET'}, HttpDataType: {STRING:'STRING'},
  createHttp() {return {async request(url, options) {
    requests.push({url, options});
    assert.equal(new URL(url).protocol, 'https:');
    return responseFactory(url, options);
  }, destroy() {}}},
}};
const bitz = loadSource('entry/src/main/ets/common/utils/BitzNetQuotaService.ets', {'@kit.NetworkKit': network});
const service = bitz.BitzNetQuotaService;
const compatibility = loadSource(
  'entry/src/main/ets/common/utils/SubscriptionCompatibilityService.ets', {'@kit.NetworkKit': network})
  .default;
const tests = [];
function test(name, run) {tests.push({name, run});}
const stable = 'http://subscription.example/sub?token=fixture';
const base = 'https://api.example/api/v1';
const valid = 'proxies:\n  - name: fixture\n    type: ss\n    server: example.com\n    port: 443\n    cipher: aes-128-gcm\n    password: fixture\n';

test('HTTPS normalization and explicit Clash format preserve encoded token', () => {
  assert.equal(bitz.bitzClashSubscriptionUrl('http://panel.example/sub?flag=v2ray&token=a%2Bb#fragment'),
    'https://panel.example/sub?token=a%2Bb&flag=clash');
  assert.equal(bitz.normalizeBitzSubscriptionUrl(' HTTPS://panel.example/sub '), 'https://panel.example/sub');
  assert.equal(bitz.bitzClashSubscriptionUrl('file:///tmp/config.yaml'), '');
  assert.equal(bitz.bitzClashSubscriptionUrl('https://user@untrusted.example/sub'), '');
});
test('profile URL is preferred but never receives account authorization', () => {
  const candidates = service.subscriptionCandidates(stable, 'https://untrusted.example/sub', base);
  assert.ok(candidates.length > 0);
  assert.equal(new URL(candidates[0].url).host, 'untrusted.example');
  assert.equal(candidates[0].useAuthorization, false);
  assert.ok(candidates.some(candidate => candidate.useAuthorization));
});
test('ordinary profile subscription wins over account URI fallback without leaking auth', async () => {
  const start = requests.length;
  responseFactory = (url) => new URL(url).host === 'ordinary.example' ?
    {responseCode:200, result:valid} : {responseCode:200, result:'c3M6Ly9maXh0dXJl'};
  const result = await service.downloadWithSession('fixture-auth', base, stable,
    'https://ordinary.example/sub', {}, 'fixture');
  assert.equal(result.proxyCount, 1);
  assert.equal(new URL(requests[start].url).host, 'ordinary.example');
  assert.equal(requests[start].options.header.Authorization, undefined);
  assert.equal(requests[start].options.header['User-Agent'], 'BBGen2UA');
});
test('official request headers and valid YAML are accepted', async () => {
  responseFactory = () => ({responseCode:200, result:valid});
  const result = await service.downloadWithSession('fixture-auth', base, stable, '', {}, 'fixture');
  assert.equal(result.proxyCount, 1);
  const {url, options} = requests.at(-1);
  assert.equal(new URL(url).searchParams.get('flag'), 'clash');
  assert.equal(options.header['User-Agent'], 'BBGen2UA');
  assert.equal(options.header.Authorization, 'fixture-auth');
  assert.equal(options.header['Accept-Encoding'], 'identity');
});
test('base64 response retries same HTTPS URL with Clash user agent', async () => {
  const start = requests.length;
  responseFactory = (_url, options) => options.header['User-Agent'] === 'BBGen2UA' ?
    {responseCode:200, result:'c3M6Ly9maXh0dXJl'} : {responseCode:200, result:valid};
  const result = await service.downloadWithSession('fixture-auth', base, stable, '', {}, 'fixture');
  assert.equal(result.proxyCount, 1);
  assert.equal(requests[start].options.header['User-Agent'], 'BBGen2UA');
  assert.equal(requests[start + 1].options.header['User-Agent'], 'Clash.Meta');
  assert.equal(requests[start].url, requests[start + 1].url);
});
test('validated-looking base64 URI subscription is returned for core conversion', async () => {
  responseFactory = () => ({responseCode:200, result:'c3M6Ly9maXh0dXJl'});
  const result = await service.downloadWithSession('fixture-auth', base, stable, '', {}, 'fixture');
  assert.equal(result.format, 'v2ray');
  assert.equal(result.proxyCount, 0);
  assert.equal(result.content, 'c3M6Ly9maXh0dXJl');
});
for (const [name, response] of [
  ['HTTP rejection', {responseCode:403,result:'forbidden'}],
  ['HTML response', {responseCode:200,result:'<!doctype html><html>challenge</html>'}],
  ['empty node list', {responseCode:200,result:'proxies: []'}],
  ['malformed YAML', {responseCode:200,result:'proxies: [invalid'}],
]) {
  test(name + ' is rejected before saving', async () => {
    responseFactory = () => response;
    await assert.rejects(service.downloadWithSession('fixture-auth', base, stable, '', {}, 'fixture'));
  });
}
test('DJB2 and secret redaction match expected behavior', () => {
  assert.equal(bitz.bitzSubscriptionHash('proxies:\n  - name: fixture\n'), '61409a4');
  const token = 'a'.repeat(160);
  const reason = service.sanitizeLogReason('request https://private.example/?token=fixture '+token);
  assert.ok(!reason.includes('private.example') && !reason.includes(token));
});
test('gateway failures retain status and do not impersonate credential failures', () => {
  const overloaded = service.httpFailureReason('额度接口', 503, '服务繁忙');
  assert.equal(overloaded, '额度接口 HTTP 503：服务繁忙');
  assert.equal(service.isTransientError(overloaded), true);
  assert.equal(service.isTransientError(service.httpFailureReason('额度接口', 429, '稍后重试')), true);
  assert.equal(service.isTransientError('Failed to connect to host'), true);
  assert.equal(service.isTransientError('TLS handshake closed'), true);
  assert.equal(service.isTransientError(service.httpFailureReason('登录接口', 401, '请重新登录')), false);
  assert.equal(service.isTransientError('账号密码错误'), false);
  assert.equal(service.preferredFailureReason(
    '账号登录 HTTP 503：服务繁忙', '账号登录 HTTP 401：账号不存在'),
  '账号登录 HTTP 503：服务繁忙');
});
test('provider-only subscriptions count providers instead of nested fields', () => {
  const yamlProviders = compatibility.inspectClashContent(
    'proxy-providers:\n  provider-a:\n    type: http\n    url: https://example.com/a\n' +
    '  provider-b:\n    type: file\n    path: ./b.yaml\n');
  assert.equal(yamlProviders.valid, true);
  assert.equal(yamlProviders.providerCount, 2);
  const jsonProviders = compatibility.inspectClashContent(
    '{"proxy-providers":{"provider-a":{"type":"http"},"provider-b":{"type":"file"}}}');
  assert.equal(jsonProviders.valid, true);
  assert.equal(jsonProviders.providerCount, 2);
});

(async () => {
  const tempDir = await fsp.mkdtemp(path.join(os.tmpdir(), 'vpn-bitz-regression-'));
  const handles = new Map();
  let rejectWrite = false;
  const adapter = {
    OpenMode: {CREATE:1, READ_WRITE:2, TRUNC:4}, AccessModeType: {EXIST:0},
    async open(filename) {const h = await fsp.open(filename, 'w+'); handles.set(h.fd,h); return {fd:h.fd};},
    async write(fd, buffer) {if (rejectWrite) throw new Error('fixture write failure'); await handles.get(fd).write(Buffer.from(buffer));},
    async fsync(fd) {await handles.get(fd).sync();},
    async close(fd) {const h=handles.get(fd);handles.delete(fd);await h.close();},
    async access(filename) {try {await fsp.access(filename); return true;} catch {return false;}},
    readText: filename => fsp.readFile(filename,'utf8'), rename:fsp.rename, unlink:fsp.unlink,
  };
  const profilePath = path.join(tempDir, 'config.yaml');
  const {Profile} = loadSource('proxy_core/src/main/ets/Profile.ets', {
    '@ohos.file.fs': {default:adapter},
    './appPath': {getProfilePath:async()=>profilePath, getProfileDir:async()=>tempDir},
  });
  const profile = new Profile(1, stable);
  test('changed configuration validates before atomic replacement', async () => {
    await fsp.writeFile(profilePath,'previous');
    const changed = await profile.saveIfChanged(valid, async temporary => {
      assert.notEqual(temporary, profilePath);
      assert.equal(await fsp.readFile(profilePath,'utf8'),'previous');
      assert.equal(await fsp.readFile(temporary,'utf8'),valid);
      return '';
    });
    assert.equal(changed,true);
    assert.equal(await fsp.readFile(profilePath,'utf8'),valid);
  });
  test('unchanged configuration skips validation, file write and reload signal', async () => {
    const before = (await fsp.stat(profilePath)).mtimeMs;
    profile.lastUpdateDate = 1;
    assert.equal(await profile.saveIfChanged(valid,async()=>{throw new Error('must not validate unchanged content');}),false);
    assert.equal((await fsp.stat(profilePath)).mtimeMs,before);
    assert.ok(profile.lastUpdateDate > 1);
  });
  test('core validation failure preserves bytes and last successful date', async () => {
    const date = profile.lastUpdateDate;
    await assert.rejects(profile.saveIfChanged('proxies: []',async()=> 'fixture invalid core config'));
    assert.equal(await fsp.readFile(profilePath,'utf8'),valid);
    assert.equal(profile.lastUpdateDate,date);
    assert.deepEqual(await fsp.readdir(tempDir),['config.yaml']);
  });
  test('disk write failure preserves old configuration and cleans temporary file', async () => {
    rejectWrite = true;
    await assert.rejects(profile.saveIfChanged('new data',async()=>''));
    rejectWrite = false;
    assert.equal(await fsp.readFile(profilePath,'utf8'),valid);
    assert.deepEqual(await fsp.readdir(tempDir),['config.yaml']);
  });
  try {
    for (const {name,run} of tests) {await run();console.log('PASS  '+name);}
    console.log(`${tests.length} subscription regression tests passed`);
  } finally {
    for (const handle of handles.values()) await handle.close();
    // Only this run's mkdtemp directory, never application data.
    await fsp.rm(tempDir,{recursive:true,force:true});
  }
})().catch(error=>{console.error(error);process.exitCode=1;});
