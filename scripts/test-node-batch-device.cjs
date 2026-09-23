#!/usr/bin/env node
// Real-device acceptance test for the daily quick node test.
// It checks progress continuity across a Home -> Proxy navigation while the
// batch is running, then verifies that the running indicator is cleared.
// The script only reads rendered UI text and never reads profiles or tokens.
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const args = process.argv.slice(2);
const serial = args.find(arg => !arg.startsWith('--'));
const hapArg = args.find(arg => arg.startsWith('--hap='));
const timeoutArg = args.find(arg => arg.startsWith('--timeout='));
const install = args.includes('--install');
const appRoot = path.resolve(__dirname, '..');
const bundleName = process.env.BUNDLE_NAME || 'org.xbgroup.clashboxLTS';
const hapPath = hapArg ? hapArg.slice('--hap='.length) :
  (process.env.HAP_PATH || path.join(appRoot, 'entry/build/release/outputs/default/entry-default-signed.hap'));
const timeoutMs = Number(timeoutArg ? timeoutArg.slice('--timeout='.length) : 180000);
if (!serial || !Number.isFinite(timeoutMs) || timeoutMs < 30000) {
  throw new Error('Usage: node scripts/test-node-batch-device.cjs SERIAL [--install] [--hap=PATH] [--timeout=MS]');
}

const hdc = process.env.HDC_PATH || 'hdc';
const evidence = fs.mkdtempSync(path.join(os.tmpdir(), 'node-batch-device-'));
const remoteLayout = `/data/local/tmp/node_batch_acceptance_${process.pid}.json`;
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
function run(...command) {
  return execFileSync(hdc, ['-t', serial, ...command], {
    encoding: 'utf8', timeout: 20000, maxBuffer: 4 * 1024 * 1024
  }).replace(/\r/g, '');
}
function parseBounds(bounds) {
  const values = String(bounds || '').match(/\d+/g);
  if (!values || values.length < 4) return null;
  const [left, top, right, bottom] = values.map(Number);
  return { left, top, right, bottom };
}
function flatten(value, output = []) {
  if (!value || typeof value !== 'object') return output;
  if (value.attributes) output.push(value.attributes);
  for (const child of Object.values(value)) {
    if (Array.isArray(child)) child.forEach(item => flatten(item, output));
    else if (child && typeof child === 'object') flatten(child, output);
  }
  return output;
}
function dump(label) {
  run('shell', 'uitest', 'dumpLayout', '-p', remoteLayout);
  const layout = JSON.parse(run('shell', 'cat', remoteLayout));
  const nodes = flatten(layout);
  const snapshot = {label, at: new Date().toISOString(), nodes};
  fs.writeFileSync(path.join(evidence, `${String(fs.readdirSync(evidence).length).padStart(3, '0')}-${label}.json`),
    JSON.stringify(snapshot, null, 2));
  return {nodes, snapshot};
}
function nodeText(node) { return String(node?.text || ''); }
function find(nodes, predicate) {
  const matches = nodes.filter(node => predicate(node) && parseBounds(node.bounds));
  return matches.find(node => node.type === 'Text') || matches[0];
}
function tap(nodes, predicate, label) {
  const node = find(nodes, predicate);
  if (!node) throw new Error(`Expected ${label} was not visible`);
  const bounds = parseBounds(node.bounds);
  run('shell', 'uitest', 'uiInput', 'click',
    String(Math.round((bounds.left + bounds.right) / 2)),
    String(Math.round((bounds.top + bounds.bottom) / 2)));
}
function progress(nodes) {
  const text = nodes.map(nodeText).find(value =>
    /^(准备中|检测延迟|连通性|快速实测|实测)\s/.test(value));
  if (!text) return null;
  const phase = text.match(/^(准备中|检测延迟|连通性|快速实测|实测)/)?.[1] || '';
  const match = text.match(/(\d+)\/(\d+).*?(\d+)%/);
  return {text, phase, completed: match ? Number(match[1]) : -1,
    total: match ? Number(match[2]) : -1, percent: match ? Number(match[3]) : -1};
}
function progressAdvanced(before, after) {
  if (!before || !after) return false;
  const phaseOrder = { '准备中': 0, '检测延迟': 1, '连通性': 1, '快速实测': 2, '实测': 2 };
  const beforePhase = phaseOrder[before.phase] ?? -1;
  const afterPhase = phaseOrder[after.phase] ?? -1;
  if (afterPhase > beforePhase) return true;
  if (afterPhase < beforePhase) return false;
  return after.completed > before.completed || after.percent > before.percent;
}
async function waitFor(label, predicate, waitMs = 20000) {
  const deadline = Date.now() + waitMs;
  let last;
  while (Date.now() < deadline) {
    last = dump(label);
    if (predicate(last.nodes)) return last;
    await sleep(700);
  }
  throw new Error(`Timed out waiting for ${label}`);
}

(async () => {
  const startedAt = Date.now();
  if (install) {
    if (!fs.existsSync(hapPath)) throw new Error(`HAP not found: ${hapPath}`);
    run('install', '-r', hapPath);
  }
  run('shell', 'aa', 'force-stop', bundleName);
  run('shell', 'aa', 'start', '-b', bundleName, '-a', 'EntryAbility');
  await sleep(2500);

  let current = await waitFor('proxy-tab', nodes =>
    !!find(nodes, node => nodeText(node) === '代理'), 30000);
  tap(current.nodes, node => nodeText(node) === '代理', '代理标签');
  current = await waitFor('proxy-page', nodes =>
    !!find(nodes, node => node.id === 'DailyExperienceBatchButton'), 30000);
  tap(current.nodes, node => node.id === 'DailyExperienceBatchButton', '一键测试按钮');
  current = await waitFor('confirm-dialog', nodes =>
    !!find(nodes, node => nodeText(node) === '开始体验测试'), 10000);
  tap(current.nodes, node => nodeText(node) === '开始体验测试', '开始体验测试');

  const first = await waitFor('first-progress', nodes => {
    const value = progress(nodes);
    return !!value && value.phase !== '准备中' && value.completed > 0;
  }, 30000);
  const beforeNavigation = progress(first.nodes);
  current = dump('before-navigation');
  const before = progress(current.nodes) || beforeNavigation;

  tap(current.nodes, node => nodeText(node) === '主页', '主页标签');
  current = await waitFor('home-page', nodes =>
    !find(nodes, node => node.id === 'DailyExperienceBatchButton') &&
    !!find(nodes, node => nodeText(node) === '主页'), 10000);
  await sleep(700);
  tap(current.nodes, node => nodeText(node) === '代理', '代理标签');
  current = await waitFor('return-proxy', nodes =>
    !!find(nodes, node => node.id === 'DailyExperienceBatchButton'), 15000);
  const returned = await waitFor('progress-after-return', nodes => {
    const value = progress(nodes);
    const completed = nodes.map(nodeText).some(text => text.includes('快速测试完成'));
    return completed || progressAdvanced(before, value);
  }, 30000);
  const afterReturn = progress(returned.nodes);
  const completedOnReturn = returned.nodes.map(nodeText).some(text => text.includes('快速测试完成'));
  if (!completedOnReturn && !progressAdvanced(before, afterReturn)) {
    throw new Error(`Progress did not advance after returning to Proxy: before=${JSON.stringify(before)} after=${JSON.stringify(afterReturn)}`);
  }

  const deadline = Date.now() + timeoutMs;
  let completedSnapshot;
  let completionText = returned.nodes.map(nodeText).find(text => text.includes('快速测试完成')) || '';
  while (Date.now() < deadline) {
    current = dump('poll');
    completionText = current.nodes.map(nodeText).find(text => text.includes('快速测试完成')) || completionText;
    if (!progress(current.nodes)) {
      completedSnapshot = current;
      break;
    }
    await sleep(1200);
  }
  if (!completedSnapshot) throw new Error(`Quick node test did not finish within ${timeoutMs}ms`);
  const finalProgress = progress(completedSnapshot.nodes);
  if (finalProgress) throw new Error(`Residual running progress after completion: ${finalProgress.text}`);
  if (!find(completedSnapshot.nodes, node => node.id === 'DailyExperienceBatchButton')) {
    throw new Error('DailyExperienceBatchButton was not restored after completion');
  }
  if (!completionText || !/推荐\s*\d+\s*个节点/.test(completionText)) {
    throw new Error(`Completion toast did not expose a recommendation count: ${completionText || '(missing)'}`);
  }
  const trafficMatch = completionText.match(/本次约\s*([\d.]+)\s*(MiB|KiB)/);
  const trafficMiB = trafficMatch ? Number(trafficMatch[1]) * (trafficMatch[2] === 'KiB' ? 1 / 1024 : 1) : -1;
  if (trafficMiB > 220) {
    throw new Error(`Quick test traffic exceeded 220 MiB: ${completionText}`);
  }
  const report = {
    serial, elapsedSeconds: Math.round((Date.now() - startedAt) / 1000),
    progressBeforeNavigation: before, progressAfterReturn: afterReturn,
    completionText, trafficMiB, noResidualProgress: true, artifact: evidence
  };
  fs.writeFileSync(path.join(evidence, 'result.json'), JSON.stringify(report, null, 2));
  process.stdout.write(`PASS ${JSON.stringify(report)}\nARTIFACT ${evidence}\n`);
})().catch(error => {
  console.error(`FAIL ${error.message}\nARTIFACT ${evidence}`);
  process.exitCode = 1;
});
