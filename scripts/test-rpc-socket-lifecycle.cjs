#!/usr/bin/env node
// Regression fixtures for the short-lived and streaming LocalSocket clients.
// The fake socket deliberately delivers late callbacks after close: those
// callbacks must be detached and must not settle a request a second time.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');

const root = path.resolve(__dirname, '..');
const ts = require(process.env.VPN_TYPESCRIPT_PATH ||
  '/Applications/DevEco-Studio-26-Beta.app/Contents/tools/hvigor/hvigor/node_modules/typescript/lib/typescript.js');
class FixtureTextDecoder {
  decodeToString(bytes) {
    return Buffer.from(bytes).toString('utf8');
  }
}

class FakeLocalSocket {
  constructor() {
    this.listeners = new Map();
    this.closeCount = 0;
    this.sendBehavior = undefined;
    this.connected = false;
    this.closed = false;
  }

  on(type, callback) {
    if (!this.listeners.has(type)) this.listeners.set(type, new Set());
    this.listeners.get(type).add(callback);
  }

  off(type, callback) {
    if (!callback) {
      this.listeners.delete(type);
      return;
    }
    this.listeners.get(type)?.delete(callback);
  }

  listenerCount(type) {
    return this.listeners.get(type)?.size || 0;
  }

  connect() {
    this.connected = true;
    return Promise.resolve();
  }

  send(options) {
    if (this.sendBehavior) return this.sendBehavior(this, options);
    return Promise.resolve();
  }

  close() {
    this.closeCount++;
    this.closed = true;
    return Promise.resolve();
  }

  remoteClose() {
    this.closed = true;
    this.emit('close');
  }

  getState() {
    return Promise.resolve({isBound: this.connected, isConnected: this.connected && !this.closed,
      isClose: this.closed});
  }

  getSocketFd() {
    return Promise.resolve(1000 + sockets.indexOf(this));
  }

  emit(type, value) {
    for (const callback of Array.from(this.listeners.get(type) || [])) callback(value);
  }
}

const sockets = [];
const plannedBehaviors = [];
const socketApi = {
  constructLocalSocketInstance() {
    const client = new FakeLocalSocket();
    client.sendBehavior = plannedBehaviors.shift();
    sockets.push(client);
    return client;
  },
};

function load(relative) {
  const source = fs.readFileSync(path.join(root, relative), 'utf8');
  const code = ts.transpileModule(source, {compilerOptions: {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.CommonJS,
  }}).outputText;
  const exports = {};
  const adapters = {
    '@kit.NetworkKit': {socket: socketApi, vpnExtension: {}},
    '@kit.ArkTS': {JSON, util: {TextDecoder: FixtureTextDecoder}},
    '@kit.AbilityKit': {},
    '@kit.ArkUI': {},
    '@ohos.file.fs': {default: {AccessModeType: {EXIST: 0}}},
    '@kit.CoreFileKit': {fileIo: {access: async () => true}},
    './IClashManager': {ClashRpcType: {startClash: 100, stopClash: 101}},
    '../models/Common': {},
    '../Request': {checkIp: async () => true, queryCurrentIpInfo: async () => undefined},
    './FlClashVpnService': {},
    'libflclash.so': {
      convertV2RaySubscription: async () => '',
      getVpnOptions: () => ({}),
      setFdMap: () => {},
    },
    './CommonVpnService': {
      Address: class Address {},
      isIpv4: () => false,
      isIpv6: () => false,
      VpnConfig: class VpnConfig {},
    },
  };
  vm.runInNewContext(code, {
    exports,
    console,
    setTimeout,
    clearTimeout,
    TextDecoder,
    require(name) { return adapters[name] || {}; },
  }, {filename: relative});
  return exports;
}

const {SocketProxyService} = load('proxy_core/src/main/ets/rpc/SocketProxyService.ets');
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function newestSocket(previousCount) {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (sockets.length > previousCount) return sockets.at(-1);
    await wait(0);
  }
  throw new Error('fixture socket was not created');
}
const frame = value => ({message: Array.from(Buffer.from(`${JSON.stringify({result: value})}EOF`))});

async function expectReject(promise, expected) {
  await assert.rejects(promise, error => {
    assert.match(`${error?.message || error}`, expected);
    return true;
  });
}

(async () => {
  const service = new SocketProxyService();
  service.init({filesDir: '/fixture'}, {showToast() {}});

  let client = undefined;
  let socketCount = sockets.length;
  plannedBehaviors.push(socket => {
    assert.equal(socket.listenerCount('error'), 1, 'connect probe listener must be detached');
    setTimeout(() => {
      socket.emit('message', frame('ok'));
      socket.remoteClose();
    }, 0);
    return Promise.resolve();
  });
  const success = service.sendMessageRequest(1, [], false, 100);
  client = await newestSocket(socketCount);
  assert.equal(await success, 'ok');
  assert.equal(client.closeCount, 0, 'successful RPC leaves the one-shot close to the server');
  assert.equal(client.listenerCount('message'), 0, 'message listener is removed before close');
  assert.equal(client.listenerCount('error'), 0, 'error listener is removed before close');
  assert.equal(client.listenerCount('close'), 0, 'close listener is removed after remote FIN');
  client.emit('error', new Error('late error'));
  client.emit('message', frame('late message'));

  // Some HarmonyOS builds deliver the remote FIN before a response frame that
  // NetStack has already queued. The short grace window must let that frame
  // settle the RPC instead of reporting a false "RPC连接已关闭".
  socketCount = sockets.length;
  plannedBehaviors.push(socket => {
    setTimeout(() => socket.remoteClose(), 0);
    setTimeout(() => socket.emit('message', frame('close-first-ok')), 20);
    return Promise.resolve();
  });
  const closeFirst = service.sendMessageRequest(2, [], false, 500);
  client = await newestSocket(socketCount);
  assert.equal(await closeFirst, 'close-first-ok');
  assert.equal(client.closeCount, 0, 'remote FIN is not closed a second time');
  assert.equal(client.listenerCount('message'), 0);
  assert.equal(client.listenerCount('error'), 0);
  assert.equal(client.listenerCount('close'), 0);

  socketCount = sockets.length;
  plannedBehaviors.push(socket => {
    setTimeout(() => socket.remoteClose(), 0);
    return Promise.resolve();
  });
  const genuinelyClosed = service.sendMessageRequest(3, [], false, 1000);
  client = await newestSocket(socketCount);
  await expectReject(genuinelyClosed, /RPC连接已关闭/);
  assert.equal(client.listenerCount('message'), 0, 'real close removes the message listener');
  assert.equal(client.listenerCount('error'), 0, 'real close removes the error listener');
  assert.equal(client.listenerCount('close'), 0, 'real close removes the close listener');

  const timed = service.sendMessageRequest(4, [], false, 10);
  socketCount = sockets.length;
  plannedBehaviors.push(socket => {
    setTimeout(() => socket.emit('message', frame('late response')), 25);
    return Promise.resolve();
  });
  client = await newestSocket(socketCount);
  await expectReject(timed, /请求超时/);
  await wait(100);
  assert.equal(client.closeCount, 1, 'timeout closes exactly once');
  assert.equal(client.listenerCount('message'), 0);
  assert.equal(client.listenerCount('error'), 0);
  assert.equal(client.listenerCount('close'), 0);

  const failed = service.sendMessageRequest(5);
  socketCount = sockets.length;
  plannedBehaviors.push(() => new Promise((_, reject) => {
    setTimeout(() => reject(new Error('send fixture failure')), 0);
  }));
  client = await newestSocket(socketCount);
  await expectReject(failed, /send fixture failure/);
  await wait(100);
  assert.equal(client.closeCount, 1, 'send failure closes exactly once');
  assert.equal(client.listenerCount('message'), 0);
  assert.equal(client.listenerCount('error'), 0);
  assert.equal(client.listenerCount('close'), 0);

  const dispose = await service.callbackRequest(6, [], () => {});
  client = sockets.at(-1);
  assert.equal(client.listenerCount('message'), 1);
  assert.equal(client.listenerCount('error'), 1);
  dispose();
  dispose();
  await wait(100);
  assert.equal(client.closeCount, 1, 'stream disposer is idempotent');
  assert.equal(client.listenerCount('message'), 0);
  assert.equal(client.listenerCount('error'), 0);

  console.log('RPC socket lifecycle regressions passed: 6');
})().catch(error => {
  console.error(error);
  process.exitCode = 1;
});
