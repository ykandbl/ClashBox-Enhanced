#!/usr/bin/env node
// Opt-in real-device UI acceptance test. Never run automatically: adaptive
// bandwidth samples can consume substantial traffic. Reads node labels/results,
// never subscriptions.
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const [serial, name, mode = 'single'] = process.argv.slice(2);
if (!serial || !name || !['web','peak','single','multi'].includes(mode)) {
  throw new Error('Usage: node test-node-bandwidth-device.cjs SERIAL VISIBLE_NODE_NAME [single|multi|web|peak]');
}
const hdc = process.env.HDC_PATH || 'hdc';
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'bandwidth-ui-'));
const layoutPath = path.join(temp, 'layout.json');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function run(...args) { return execFileSync(hdc, ['-t', serial, ...args], {encoding:'utf8', timeout:15000}); }
function dump() {
  run('shell', 'uitest', 'dumpLayout', '-p', '/data/local/tmp/bandwidth_acceptance.json');
  run('file', 'recv', '/data/local/tmp/bandwidth_acceptance.json', layoutPath);
  const nodes = [];
  function walk(value) {
    if (!value || typeof value !== 'object') return;
    if (value.attributes) nodes.push(value.attributes);
    for (const child of Object.values(value)) {
      if (Array.isArray(child)) child.forEach(walk);
      else if (child && typeof child === 'object') walk(child);
    }
  }
  walk(JSON.parse(fs.readFileSync(layoutPath, 'utf8')));
  return nodes;
}
function find(nodes, predicate) {
  const found = nodes.filter(x => predicate(x.text || '') && x.bounds && x.type !== 'Radio');
  return found.find(x => x.type === 'Text') || found[0];
}
function tap(node, action='click') {
  if (!node) throw new Error('Expected visible control not found; no guessed tap performed');
  const [left, top, right, bottom] = node.bounds.match(/\d+/g).map(Number);
  run('shell', 'uitest', 'uiInput', action, String(Math.round((left+right)/2)), String(Math.round((top+bottom)/2)));
}
(async () => {
  const before = dump();
  tap(find(before, text => text === name), 'longClick');
  await sleep(500);
  const sustained = mode === 'single' || mode === 'multi';
  const menu = sustained ? (mode === 'single' ? '单连接 · 大文件持续测速' : '多连接 · 大文件持续测速') :
    (mode === 'peak' ? '峰值带宽 · speedtest-go（8连接）' : '网页链路 · Cloudflare（单连接）');
  tap(find(dump(), text => text === menu));
  await sleep(500);
  const confirm = dump();
  if (!confirm.some(x => (x.text || '').includes(`节点：${name}`))) throw new Error('Wrong node in confirmation');
  tap(find(confirm, text => text === (sustained ? '开始持续测速' : (mode === 'peak' ? '开始峰值测试' : '开始官方精测'))));
  const started = Date.now();
  const engine = sustained ? `sustained-v1-${mode}` : (mode === 'peak' ? 'speedtest-go-1.8.0' : 'cloudflare-1.13.1');
  process.stdout.write(`START ${JSON.stringify({name,engine})}\n`);
  let lastProgress = 0;
  while (Date.now()-started < 360000) {
    await sleep(3000);
    const nodes = dump();
    if (mode === 'peak' || sustained) {
      const sustainedDone = sustained && nodes.some(x => /^(测速完成|测速未完成|测速异常)/.test(x.text || ''));
      const peakDone = !sustained && nodes.some(x => ['峰值带宽结果','测速未完成'].includes(x.text));
      if (sustainedDone || peakDone) {
        const result = nodes.filter(x => x.type === 'Text' &&
          /^(测速完成|测速未完成|测速异常)|实测传输量|Mbps|固定测试点|本次样本|连接|超时/.test(x.text || '')).map(x => x.text);
        const completed = sustained ? nodes.some(x => (x.text || '').startsWith('测速完成')) :
          !nodes.some(x => x.text === '测速未完成');
        const report = {name,engine,completed,elapsedSeconds:Math.round((Date.now()-started)/1000),result};
        fs.writeFileSync(path.join(temp, 'result.json'), JSON.stringify(report,null,2));
        process.stdout.write(`RESULT ${JSON.stringify(report)}\nARTIFACT ${temp}\n`);
        if (process.env.BANDWIDTH_KEEP_RESULT !== '1') {
          const close = find(nodes, text => text === (sustained ? '完成' : '知道了'));
          if (close) tap(close);
          else run('shell','uitest','uiInput','keyEvent','Back');
        }
        if (!completed) process.exitCode = 1;
        return;
      }
      if (Date.now()-started > (sustained ? 320000 : 120000)) throw new Error('Native test did not finish within bounded deadline');
      continue;
    }
    const webIndex = nodes.findIndex(x => (x.text || '').startsWith('resource:/RAWFILE/speedtest/'));
    const webTexts = webIndex >= 0 ? nodes.slice(webIndex + 1).map(x => x.text || '').filter(Boolean) : [];
    if (Date.now()-lastProgress > 20000 && webTexts.length) {
      process.stdout.write(`PROGRESS ${JSON.stringify(webTexts.slice(0, 18))}\n`);
      lastProgress = Date.now();
    }
    if (nodes.some(x => x.text === '测速失败')) {
      run('shell','uitest','uiInput','keyEvent','Back');
      throw new Error(`Official speed test failed: ${JSON.stringify(webTexts)}`);
    }
    if (nodes.some(x => x.text === '测速完成')) {
      const report = {name,engine:'cloudflare-1.13.1',elapsedSeconds:Math.round((Date.now()-started)/1000),result:webTexts};
      fs.writeFileSync(path.join(temp, 'result.json'), JSON.stringify(report,null,2));
      process.stdout.write(`RESULT ${JSON.stringify(report)}\nARTIFACT ${temp}\n`);
      if (process.env.BANDWIDTH_KEEP_RESULT !== '1') run('shell','uitest','uiInput','keyEvent','Back');
      return;
    }
  }
  run('shell','uitest','uiInput','keyEvent','Back');
  throw new Error('No completed result within bounded wait; test page closed');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
