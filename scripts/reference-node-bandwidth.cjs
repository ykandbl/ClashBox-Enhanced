#!/usr/bin/env node
// Independent curl reference for the phone's currently selected proxy node.
// The caller must create an HDC forward from LOCAL_PORT to the phone's mixed
// port. This script never reads profiles, subscriptions, or credentials.
const {spawn} = require('node:child_process');

const proxyPort = Number(process.argv[2] || 17890);
const bytesPerStream = Number(process.argv[3] || 1000000);
const samples = Number(process.argv[4] || 2);
const concurrency = 4;
if (!Number.isInteger(proxyPort) || proxyPort <= 0 || !Number.isInteger(bytesPerStream) ||
    bytesPerStream <= 0 || !Number.isInteger(samples) || samples < 1) {
  throw new Error('Usage: node reference-node-bandwidth.cjs LOCAL_PORT BYTES_PER_STREAM SAMPLES');
}

function curlTransfer(direction, bytes) {
  const down = direction === 'down';
  const args = [
    '--noproxy', '', '--proxy', `http://127.0.0.1:${proxyPort}`,
    '--connect-timeout', '10', '--max-time', '100', '--silent', '--show-error',
    '--output', '/dev/null', '--write-out', '%{http_code} %{size_download} %{size_upload}',
  ];
  if (down) {
    args.push(`https://speed.cloudflare.com/__down?bytes=${bytes}&reference=${Date.now()}-${Math.random()}`);
  } else {
    args.push('--request', 'POST', '--header', 'Content-Type: application/octet-stream',
      '--data-binary', '@-', 'https://speed.cloudflare.com/__up');
  }
  return new Promise((resolve, reject) => {
    const child = spawn('curl', args, {stdio: ['pipe', 'pipe', 'pipe']});
    let stdout = '';
    let stderr = '';
    child.stdout.on('data', chunk => stdout += chunk);
    child.stderr.on('data', chunk => stderr += chunk);
    child.on('error', reject);
    child.on('close', code => {
      const [status, downloaded, uploaded] = stdout.trim().split(/\s+/).map(Number);
      if (code !== 0 || status < 200 || status >= 300) {
        reject(new Error(`curl ${direction} failed: exit=${code} http=${status || 0} ${stderr.trim()}`));
        return;
      }
      const payload = down ? downloaded : uploaded;
      if (payload < bytes * 0.98) {
        reject(new Error(`curl ${direction} incomplete: ${payload}/${bytes}`));
        return;
      }
      resolve(payload);
    });
    if (down) child.stdin.end();
    else child.stdin.end(Buffer.alloc(bytes));
  });
}

async function group(direction, bytes) {
  const started = process.hrtime.bigint();
  const payloads = await Promise.all(Array.from({length: concurrency}, () => curlTransfer(direction, bytes)));
  const elapsedMs = Number(process.hrtime.bigint() - started) / 1e6;
  const payloadBytes = payloads.reduce((sum, value) => sum + value, 0);
  return {mbps: Math.round(payloadBytes * 8 / elapsedMs / 1000 * 100) / 100,
    elapsedMs: Math.round(elapsedMs), payloadBytes};
}

(async () => {
  await group('down', 100000);
  await group('up', 100000);
  const result = {bytesPerStream, concurrency, down: [], up: []};
  for (const direction of ['down', 'up']) {
    for (let index = 0; index < samples; index++) result[direction].push(await group(direction, bytesPerStream));
  }
  console.log(JSON.stringify(result));
})().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
