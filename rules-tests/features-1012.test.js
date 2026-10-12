// 2026-10-12: config/features is readable by signed-in phones and writable by no client at all
// (only the adminApi function, which has Admin SDK access). adminConfig (verification settings) is
// closed entirely.
//   node features-1012.test.js
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const OWNER = 'ownerUID01';
const mocks = [
  { function: 'exists', args: [{ exactValue: `${D}/admins/${OWNER}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/admins/${OWNER}` }], result: { value: { data: { role: 'owner' } } } },
];
const cases = [
  ['a signed-in phone reads the switches', 'ALLOW', 'someUser01', 'config/features', 'get'],
  ['signed out reads the switches', 'DENY', null, 'config/features', 'get'],
  ['a user writes the switches', 'DENY', 'someUser01', 'config/features', 'update'],
  ['the OWNER writes the switches from a browser', 'DENY', OWNER, 'config/features', 'update'],
  ['the owner creates the switches from a browser', 'DENY', OWNER, 'config/features', 'create'],
  ['the owner reads verification settings from a browser', 'DENY', OWNER, 'adminConfig/verification', 'get'],
  ['the owner writes verification settings from a browser', 'DENY', OWNER, 'adminConfig/verification', 'update'],
  ['CONTROL the owner still writes config/limits', 'ALLOW', OWNER, 'config/limits', 'update'],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;
  for (const [name, expect, who, path, method] of cases) {
    const request = { path: `${D}/${path}`, method, time: new Date().toISOString() };
    if (who) request.auth = { uid: who, token: { firebase: { sign_in_provider: 'google.com' } } };
    if (method !== 'get') request.resource = { data: { glow: true } };
    const body = { source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [{ expectation: expect, request, resource: method === 'create' ? undefined : { data: { glow: false } }, functionMocks: mocks }] } };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST', headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const j = await r.json();
    const ok = j.testResults && j.testResults[0] && j.testResults[0].state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${expect.padEnd(5)}  ${name}${!ok && j.error ? ' [' + j.error.message + ']' : ''}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
})();
