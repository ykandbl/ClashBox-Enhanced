#!/usr/bin/env node
// Execute production scheduler/data-source/lifecycle code with local SDK shims.
// No user profiles, credentials or external network are read.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '..');
const ts = require(process.env.VPN_TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio-26-Beta.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
const results = new Map();
const listeners = new Map();
const model = {delayMap: results, getNodeQualityResult() { return undefined; }};
const EventKey = {TestDelay: 1, NodeDelayReset: 2, NodeQualityUpdated: 3};
const EventHub = {on(key, cb) {
  if (!listeners.has(key)) listeners.set(key, new Set());
  listeners.get(key).add(cb);
  return () => listeners.get(key).delete(cb);
}};
const noDecorator = () => () => {};
function load(relative, adapters = {}, transform = s => s) {
  const source = transform(fs.readFileSync(path.join(root, relative), 'utf8'));
  const code = ts.transpileModule(source, {compilerOptions: {
    target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS,
    experimentalDecorators: true,
  }}).outputText;
  const exports = {};
  vm.runInNewContext(code, {exports, console, setTimeout, clearTimeout,
    Observed: x => x, Reusable: x => x, Component: x => x,
    Consume: noDecorator, StorageLink: noDecorator, Prop() {}, State() {},
    Watch: noDecorator,
    require(name) {
      if (Object.hasOwn(adapters, name)) return adapters[name];
      if (name.includes('NodeDelayRunner')) return runner;
      if (name.includes('ClashViewModel')) return {default: model};
      if (name.includes('EventHub')) return {EventKey, EventHub};
      if (name.includes('AppState')) return {AppConfig: class {}, UIConfig: class {}};
      if (name === '@kit.LocalizationKit') return {intl: Intl};
      if (name === '@kit.ArkTS') return {JSON};
      return {};
    },
  }, {filename: relative});
  return exports;
}
const runner = load('entry/src/main/ets/common/utils/NodeDelayRunner.ets');
const {NodeDelayRunner, emptyNodeDelay, nodeDelayText, normalizeDelayTestUrl} = runner;
const tests = [];
function test(name, fn) { tests.push({name, fn}); }
const pause = () => new Promise(resolve => setTimeout(resolve, 2));
const done = (name, delay) => ({...emptyNodeDelay(name), status:'ok', delay});

test('33-node batch and single tests share a maximum of six concurrent probes', async () => {
  let active = 0, max = 0, calls = 0;
  const progress = [];
  const service = new NodeDelayRunner(async () => {
    calls++; active++; max = Math.max(max, active); await pause(); active--;
    return {value:123, elapsedMs:400};
  }, () => {}, (...p) => progress.push(p));
  const one = service.test('node-0');
  const names = Array.from({length:33}, (_,i) => `node-${i}`);
  const batch = service.testAll([...names, 'node-0']);
  assert.equal(service.testAll(names), batch, 'repeat tap must return the existing batch');
  const values = await batch; await one;
  assert.equal(max, 6); assert.equal(calls, 33); assert.equal(values.length, 33);
  assert.ok(values.every(v => v.status === 'ok'));
  assert.deepEqual(progress.at(-1), [false,33,33]);
});

test('errors are completed and classified, never left testing or relabeled as timeouts', async () => {
  const service = new NodeDelayRunner(async name => {
    if (name === 'rpc') throw new Error('private.example/?token=fixture');
    return {value:-1, errorCode:name, elapsedMs:8000};
  }, () => {}, () => {});
  for (const code of ['timeout','dns','tls','refused','connection','invalid_url','rpc']) {
    const result = await service.test(code);
    assert.equal(result.status, 'failed');
    assert.equal(result.errorCode, code === 'rpc' ? 'service' : code);
    assert.ok(!JSON.stringify(result).includes('private.example'));
    assert.equal(nodeDelayText(result).includes('超时'), code === 'timeout');
    assert.equal(service.results.get(code), result);
  }
});

test('profile reload discards queued and active old results without exceeding the limit', async () => {
  let active = 0, max = 0, serial = 0;
  const releases = [];
  const published = [];
  const service = new NodeDelayRunner(() => new Promise(resolve => {
    active++; max = Math.max(max, active); const value = ++serial;
    releases.push(() => {active--;resolve({value});});
  }), result => published.push(result), () => {}, 3);
  const oldBatch = service.testAll(['same','old-2','old-3','queued-old']);
  assert.equal(releases.length, 3);
  service.invalidate(); published.length = 0;
  const newBatch = service.testAll(['same','new']);
  releases.shift()(); await pause();
  releases.shift()(); await pause();
  releases.shift()(); await pause();
  while (releases.length) {releases.shift()();await pause();}
  assert.ok((await oldBatch).every(r => r.status === 'cancelled'));
  assert.ok((await newBatch).every(r => r.status === 'ok'));
  assert.ok(published.every(r => r.name === 'same' || r.name === 'new'));
  assert.equal(service.results.get('same').delay, 4);
  assert.equal(service.results.has('queued-old'), false);
  assert.ok(max <= 3);
});

test('old default URL migrates and empty batch always releases the button', async () => {
  assert.equal(normalizeDelayTestUrl('https://www.gstatic.com/generate204'),
    'https://www.gstatic.com/generate_204');
  assert.equal(normalizeDelayTestUrl(' https://fixture.example/ping '), 'https://fixture.example/ping');
  const progress = [];
  const service = new NodeDelayRunner(async () => ({value:1}), () => {}, (...p) => progress.push(p));
  assert.equal((await service.testAll([])).length, 0);
  assert.deepEqual(progress.at(-1), [false,0,0]);
});

test('batch probes keep settled numbers until the whole batch is committed', async () => {
  const published = [];
  const service = new NodeDelayRunner(async name => ({value: name === 'a' ? 120 : 80}),
    result => published.push(result), () => {});
  service.results.set('a', done('a', 999));
  const batch = await service.testAll(['a', 'b'], false);
  assert.equal(service.results.get('a').delay, 999);
  assert.equal(service.results.has('b'), false);
  assert.equal(published.length, 0);
  service.publishBatch(batch);
  assert.equal(service.results.get('a').delay, 120);
  assert.equal(service.results.get('b').delay, 80);
  assert.equal(published.length, 2);
});

const base = load('entry/src/main/ets/common/datasources/BaseDataSource.ets');
const data = load('entry/src/main/ets/common/datasources/ProxyData.ets', {'./BaseDataSource':base});
test('delay sorting swaps stable items without clearing/reloading or mutating source order', () => {
  const source = new data.ProxyItemDataSource();
  const nodes = ['a','b','c','d'].map((name,id) => ({name,id:String(id),g:'fixture',type:'Vless',latency:0}));
  const events = [];
  source.registerDataChangeListener({onDataReloaded(){events.push('reload');},
    onDataMove(from,to){events.push([from,to]);}});
  source.DefaultSortItems(nodes); events.length = 0;
  results.clear(); results.set('a',done('a',400));results.set('b',done('b',300));results.set('d',done('d',50));
  source.LatencySortItems(nodes);
  assert.deepEqual(nodes.map(n=>n.name), ['a','b','c','d']);
  assert.deepEqual(Array.from({length:4},(_,i)=>source.getData(i).name), ['d','b','a','c']);
  assert.ok(events.length > 0 && events.every(Array.isArray));
  events.length = 0;source.LatencySortItems(nodes);assert.equal(events.length,0);
});

const node = load('entry/src/main/ets/components/Proxy/ProxyNodeItem.ets', {}, source =>
  source.split('  build() {')[0].replace('export struct ProxyNode', 'export class ProxyNode') + '\n}\n');
test('recycled card loads the new node result and unregisters only its own listeners', () => {
  results.clear();results.set('a',done('a',123));results.set('b',{...emptyNodeDelay('b'),status:'failed',delay:-1,errorCode:'tls'});
  const card = new node.ProxyNode();card.item={name:'a'};card.aboutToAppear();
  assert.equal(card.delayResult.delay,123);
  // The production card is no longer @Reusable.  ArkUI rebinds @Prop during
  // incremental updates; syncDelay is the same path used by @Watch('item').
  card.item={name:'b'};card.syncDelay();assert.equal(card.delayResult.errorCode,'tls');
  card.item={name:'a'};card.syncDelay();assert.equal(card.delayResult.delay,123);
  card.item={name:'b'};card.syncDelay();assert.equal(card.delayResult.errorCode,'tls');
  assert.equal(listeners.get(EventKey.TestDelay).size,1);
  for(const cb of listeners.get(EventKey.TestDelay))cb(done('a',99));
  assert.equal(card.delayResult.errorCode,'tls');
  card.aboutToDisappear();assert.equal(listeners.get(EventKey.NodeDelayReset).size,0);
  assert.equal(listeners.get(EventKey.TestDelay).size,0);
});

const socket = load('proxy_core/src/main/ets/rpc/SocketProxyService.ets', {
  './IClashManager': {ClashRpcType:{healthCheck:6}},
});
test('RPC preserves eight-second default and user test URL and rejects malformed replies', async () => {
  const service = new socket.SocketProxyService();
  let received;
  service.sendMessageRequest=async (...args) => {received=args;return '{"name":"fixture","value":-1,"errorCode":"dns"}';};
  const result=await service.healthCheckDetailed('fixture','https://fixture.example/ping');
  assert.equal(result.errorCode,'dns');assert.equal(received[1][1],8000);
  assert.equal(received[1][2],'https://fixture.example/ping');assert.equal(received[2],true);
  service.sendMessageRequest=async ()=>'{}';await assert.rejects(service.healthCheckDetailed('fixture'));
});

(async () => {
  for(const {name,fn} of tests){await fn();console.log('PASS '+name);}
  console.log(`node-delay regressions passed: ${tests.length}`);
})().catch(error => {console.error(error);process.exitCode=1;});
