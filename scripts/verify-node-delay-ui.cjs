#!/usr/bin/env node
// Usage: node scripts/verify-node-delay-ui.cjs filtered-delay.log layout1.json ...
// Correlates sanitized result IDs with rendered cards after scrolling/recycling.
const fs = require('node:fs');
const assert = require('node:assert/strict');
const [logFile, ...layouts] = process.argv.slice(2);
assert.ok(logFile && layouts.length, 'provide filtered NodeDelay log and UI dumps');
function id(name) {
  let hash=5381;
  for(let i=0;i<name.length;i++)hash=((hash<<5)+hash)^name.charCodeAt(i);
  return (hash>>>0).toString(16);
}
const results = new Map();
let expectedCount=0;
for (const line of fs.readFileSync(logFile,'utf8').split('\n')) {
  const batch=line.match(/batch complete total=(\d+)/);
  if(batch){results.clear();expectedCount=Number(batch[1]);}
  const match=line.match(/result index=\d+ id=(\w+) state=(\w+) delay=(-?\d+) code=(\w*)/);
  if(match)results.set(match[1],{state:match[2],delay:Number(match[3]),code:match[4]});
}
assert.ok(results.size > 0, 'no result IDs found in log');
const checked = new Set();
const failures = [];
const errors = {timeout:'超时（8秒）',dns:'DNS失败',tls:'TLS失败',refused:'连接被拒绝',
  unreachable:'网络不可达',missing:'节点已变更',invalid_url:'测速地址无效',service:'本地服务异常',connection:'连接失败'};
function texts(node) {
  return (node.attributes?.text?[node.attributes.text]:[]).concat((node.children||[]).flatMap(texts));
}
function walk(node) {
  const radio=(node.children||[]).find(child=>child.attributes?.type==='Radio');
  if(radio){
    const name=radio.attributes.text;
    const result=results.get(id(name));
    if(result){
      const expected=result.state==='ok'?`${result.delay}ms`:errors[result.code];
      if(!texts(node).includes(expected))failures.push({name,expected,rendered:texts(node)});
      else checked.add(id(name));
    }
  }
  for(const child of node.children||[])walk(child);
}
for(const file of layouts)walk(JSON.parse(fs.readFileSync(file,'utf8')));
assert.deepEqual(failures,[], 'card label/result mismatch after recycling');
assert.equal(checked.size, expectedCount, 'scroll dumps do not cover all measured nodes');
console.log(`PASS all ${checked.size} rendered node results match the native-test log`);
