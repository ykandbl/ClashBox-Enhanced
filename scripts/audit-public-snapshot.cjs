#!/usr/bin/env node
// Checks only files staged for the public snapshot. It prints locations, never
// matched secrets. Run again before every public commit or GitHub release.
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const files = execFileSync('git', ['-C', root, 'ls-files', '-z'], { encoding: 'utf8' })
  .split('\0').filter(Boolean);
const forbiddenPath = [
  /^build-profile\.json5$/,
  /(^|\/)(\.env(?:\..*)?|\.ssh|signing|credentials)(\/|$)/i,
  /\.(?:hap|p12|p7b|cer|csr|pem|key|keystore|jks|pcap|pcapng|log)$/i
];
const suspiciousText = [
  [/\/Users\/[^/\s]+\//, 'local home path'],
  [/(?:5MT\d{10,}|8BB[A-Z0-9]{10,})/, 'device serial'],
  [/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/, 'private key'],
  [/Bearer\s+[A-Za-z0-9._-]{24,}/i, 'embedded bearer token'],
  [/0000001B[A-F0-9]{30,}/, 'signing password blob']
];
const findings = [];

for (const name of files) {
  if (forbiddenPath.some(pattern => pattern.test(name))) {
    findings.push(`${name}: forbidden path`);
    continue;
  }
  const fullPath = path.join(root, name);
  if (!fs.existsSync(fullPath) || !fs.statSync(fullPath).isFile()) continue;
  const bytes = fs.readFileSync(fullPath);
  if (bytes.includes(0)) continue;
  const lines = bytes.toString('utf8').split(/\r?\n/);
  for (let lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    const line = lines[lineIndex];
    for (const [pattern, label] of suspiciousText) {
      if (pattern.test(line)) findings.push(`${name}:${lineIndex + 1}: ${label}`);
    }
    // Tests may use synthetic example domains. A non-example subscription URL
    // with an embedded credential must stay out of the public snapshot.
    const urls = line.match(/https?:\/\/[^\s"'`<>]+/g) || [];
    for (const rawUrl of urls) {
      try {
        const url = new URL(rawUrl);
        const fixture = url.hostname === 'example.com' ||
          url.hostname.endsWith('.example') || url.hostname === 'localhost';
        const credential = [...url.searchParams.keys()].some(key =>
          /^(token|auth|password|passwd|secret|key)$/i.test(key));
        if (!fixture && credential && /\/(sub|subscribe|subscription)(\/|\?|$)/i.test(url.pathname)) {
          findings.push(`${name}:${lineIndex + 1}: subscription credential URL`);
        }
      } catch (_) { /* Fragments in source code are not complete URLs. */ }
    }
  }
}

if (findings.length > 0) {
  console.error(`Public snapshot audit failed (${findings.length} findings):`);
  for (const finding of findings.slice(0, 100)) console.error(finding);
  process.exitCode = 1;
} else {
  console.log(`Public snapshot audit passed: ${files.length} staged files, no local signing files or high-confidence secrets`);
}
