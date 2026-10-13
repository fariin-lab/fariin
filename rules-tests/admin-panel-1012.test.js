// Admin panel (2026-10-12): the four collections functions-admin owns must be closed to EVERY client,
// the owner's own browser included. Only the adminApi function (Admin SDK, which skips rules) may
// touch them; that is what makes the audit log something an admin cannot quietly edit.
//
//   node admin-panel-1012.test.js              # against ../firestore.rules
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const OWNER = 'ownerUID01';
const STRANGER = 'strangerUID';

const paths = ['adminAudit/0000000001', 'adminAuditHead/head', 'adminSuspensions/someUser01', 'adminNotes/someUser01/items/n1',
  'adminSessions/ownerUID01', 'adminUserIds/someUser01', 'numericIds/1234567890', 'adminConfig/verification',
  'adminConfig/approvals', 'adminApprovals/req1', 'adminStats/2026-10-13', 'adminKnownNets/ownerUID01', 'adminWatch/someUser01', 'adminSchedule/s1'];
const cases = [];
for (const p of paths) {
  for (const who of [OWNER, STRANGER, null]) {
    for (const method of ['get', 'list', 'create', 'update', 'delete']) {
      cases.push([`${who || 'signed out'} ${method} ${p}`, 'DENY', who, `${D}/${p}`, method]);
    }
  }
}
// Control (README trap 1: an all-DENY suite can pass for the wrong reason). The owner reading their
// own admins row must ALLOW with these same mocks, or the harness itself is broken.
cases.push(['CONTROL owner gets own admins row', 'ALLOW', OWNER, `${D}/admins/${OWNER}`, 'get']);
cases.push(['CONTROL stranger gets the owner admins row', 'DENY', STRANGER, `${D}/admins/${OWNER}`, 'get']);

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;
  const bad = [];
  for (const [name, expect, who, path, method] of cases) {
    const request = { path, method, time: new Date().toISOString() };
    if (who) request.auth = { uid: who, token: { firebase: { sign_in_provider: 'google.com' } } };
    if (method === 'create' || method === 'update') request.resource = { data: { seq: 1, hash: 'x' } };
    const body = {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [{
        expectation: expect, request,
        resource: method === 'create' ? undefined : { data: { seq: 1, hash: 'x' } },
        // An owner row, should any rule on the way ask; the point is that none applies.
        functionMocks: [
          { function: 'exists', args: [{ exactValue: `${D}/admins/${OWNER}` }], result: { value: true } },
          { function: 'get', args: [{ exactValue: `${D}/admins/${OWNER}` }], result: { value: { data: { role: 'owner' } } } },
        ],
      }] },
    };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const ok = res && res.state === 'SUCCESS';
    ok ? pass++ : fail++;
    if (!ok) bad.push(name + (j.error ? ` [${j.error.message}]` : ''));
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${expect.padEnd(5)}  ${name}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) console.log('failed: ' + bad.join(' | '));
})();
