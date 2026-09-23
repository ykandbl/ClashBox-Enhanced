#!/usr/bin/env node
// No network or user data. Verify upstream provenance and the ArkWeb bridge.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const base = path.join(__dirname, '../entry/src/main/resources/rawfile/speedtest');
const engineSource = fs.readFileSync(path.join(base, 'cloudflare-speedtest-1.13.1.js'), 'utf8');
const upstream = engineSource.replace(/\/\/ HarmonyOS ArkWeb[\s\S]*?window.CloudflareSpeedTest = SpeedTestEngine;/,
  'export { SpeedTestEngine as default };').trimEnd();
assert.equal(crypto.createHash('sha256').update(upstream).digest('hex'),
  '06196f490f3735f2dfbdeb672edbfa5e3cac8672b7e0d09213c084f681543c5c');
console.log('PASS upstream 1.13.1 algorithm is byte-identical after restoring export/newline');

const html = fs.readFileSync(path.join(base, 'cloudflare_runner.html'), 'utf8');
const inline = [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)][0][1];
const instances = [];
const measured = {download: 173456789, upload: 75432100, latency: 221, jitter: 7,
  downLoadedLatency: 310, upLoadedLatency: 440, totalDurationMs: 42000};
const down = [{bytes: 25000000, bps: 173456789, duration: 1154, ping: 221, transferSize: 25000300}];
const up = [{bytes: 10000000, bps: 75432100, duration: 1060, ping: 221}];
const results = {getSummary: () => measured, getDownloadBandwidthPoints: () => down,
  getUploadBandwidthPoints: () => up};
class FakeEngine {
  constructor(config) {
    this.config = {measurements: [{type:'latency'}, {type:'download'}, {type:'latency'},
      {type:'packetLoss'}, {type:'upload'}, {type:'latency'}], ...config};
    this.results = results;
    this.pauses = 0;
    instances.push(this);
  }
  play() { this.played = true; }
  pause() { this.pauses++; }
}
const elements = new Map();
const events = new Map();
const browser = {CloudflareSpeedTest: FakeEngine, addEventListener: (name, fn) => events.set(name, fn)};
const tasks = [];
vm.runInNewContext(inline, {window: browser, document: {querySelector: selector => {
  if (!elements.has(selector)) elements.set(selector, {});
  return elements.get(selector);
}}, performance:{now: () => 1000}, queueMicrotask: fn => tasks.push(fn), console});
assert.equal(browser.fireflyStartSpeedTest(), 'started');
const engine = instances.at(-1);
assert.deepEqual(Array.from(engine.config.measurements, m => m.type),
  ['latency','download','latency','upload','latency']);
assert.equal(engine.config.logAimApiUrl, null);
assert.equal(engine.config.logMeasurementApiUrl, null);
engine.onResultsChange({type:'download'});
engine.onFinish(results);
let state = JSON.parse(browser.fireflyReadSpeedTest());
assert.equal(state.status, 'done');
assert.equal(state.downloadBps, measured.download);
assert.equal(state.uploadBps, measured.upload);
assert.equal(state.transferredBytes, 35000000);
assert.equal(state.totalDurationMs, 42000);
console.log('PASS official P90 and raw points are preserved; HTTP sequence retains idle latency');

browser.fireflyStartSpeedTest();
const cancelled = instances.at(-1);
events.get('pagehide')();
cancelled.onFinish(results);
assert.equal(JSON.parse(browser.fireflyReadSpeedTest()).status, 'stopped');
assert.equal(cancelled.pauses, 1);
browser.fireflyStartSpeedTest();
const failed = instances.at(-1);
failed.onError('Connection error');
tasks.forEach(fn => fn());
failed.onFinish(results);
state = JSON.parse(browser.fireflyReadSpeedTest());
assert.equal(state.status, 'failed');
assert.equal(failed.pauses, 1);
assert.match(state.error, /Connection error/);
console.log('PASS cancel/error abort requests and late callbacks never become success');
