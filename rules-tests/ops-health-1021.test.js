// owner 2026-10-21 APP HEALTH: telemetry, opsIssues, opsAlerts and telemetryRate are written only by
// the telemetryIngest / opsDetect functions (admin SDK). No phone reads or writes any of them; an
// admin may read the first three. Each row runs against the rules BEFORE the change and AFTER it.
//
//   node ops-health-1021.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node ops-health-1021.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const ADMIN = 'uidAdmin', USER = 'uidUser';
const REQ_TIME = new Date().toISOString();
const adminMocks = [{ function: 'exists', args: [{ exactValue: `${D}/admins/${ADMIN}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/admins/${ADMIN}` }], result: { value: { data: { role: 'admin', perms: [] } } } }];
const EV = { sev: 'error', comp: 'send', code: 'upload_failed', uid: USER, at: REQ_TIME };
const ISSUE = { comp: 'send', code: 'upload_failed', status: 'open', count: 3 };

const tel = `${D}/telemetry/t1`, iss = `${D}/opsIssues/abc123`, alr = `${D}/opsAlerts/a1`, rate = `${D}/telemetryRate/${USER}`;
const cases = [
  ["NEW     admin reads a telemetry event", "DENY", "ALLOW", ADMIN, tel, "get", null, EV, adminMocks],
  ["NEW     admin lists telemetry", "DENY", "ALLOW", ADMIN, tel, "list", null, EV, adminMocks],
  ["NEW     admin reads an issue", "DENY", "ALLOW", ADMIN, iss, "get", null, ISSUE, adminMocks],
  ["NEW     admin lists issues", "DENY", "ALLOW", ADMIN, iss, "list", null, ISSUE, adminMocks],
  ["NEW     admin reads an alert", "DENY", "ALLOW", ADMIN, alr, "get", null, { fp: 'abc123' }, adminMocks],
  ["GUARD   admin writes an issue", "DENY", "DENY", ADMIN, iss, "update", { ...ISSUE, status: 'resolved' }, ISSUE, adminMocks],
  ["GUARD   admin reads the rate counter", "DENY", "DENY", ADMIN, rate, "get", null, { h: 1, n: 2 }, adminMocks],
  ["GUARD   user reads own telemetry event", "DENY", "DENY", USER, tel, "get", null, EV, []],
  ["GUARD   user lists telemetry", "DENY", "DENY", USER, tel, "list", null, EV, []],
  ["GUARD   user writes a telemetry event", "DENY", "DENY", USER, tel, "create", EV, null, []],
  ["GUARD   user reads issues", "DENY", "DENY", USER, iss, "list", null, ISSUE, []],
  ["GUARD   user creates an issue", "DENY", "DENY", USER, iss, "create", ISSUE, null, []],
  ["GUARD   user reads alerts", "DENY", "DENY", USER, alr, "list", null, { fp: 'abc123' }, []],
  ["GUARD   user resets own rate counter", "DENY", "DENY", USER, rate, "update", { h: 1, n: 0 }, { h: 1, n: 300 }, []],
  ["GUARD   user reads own rate counter", "DENY", "DENY", USER, rate, "get", null, { h: 1, n: 300 }, []],
  ["GUARD   signed out reads issues", "DENY", "DENY", null, iss, "get", null, ISSUE, []],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = { path: p, method, time: REQ_TIME };
  if (uid) request.auth = { uid, token: { firebase: { sign_in_provider: 'password' } } };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: [...(mocks || []), { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
  if (before) testCase.resource = { data: before };
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [testCase] },
    }),
  });
  const j = await r.json();
  if (j.error) return { state: 'APIERROR', detail: JSON.stringify(j.error).slice(0, 300) };
  if (j.issues && j.issues.length) return { state: 'COMPILE', detail: JSON.stringify(j.issues).slice(0, 300) };
  const res = j.testResults && j.testResults[0];
  return { state: (res && res.state) || 'NORESULT', detail: ((res && res.debugMessages) || []).join(' | ').slice(0, 300) };
}

(async () => {
  const t = await token();
  const before = fs.readFileSync(BEFORE, 'utf8'), after = fs.readFileSync(AFTER, 'utf8');
  console.log(`before: ${BEFORE}\nafter:  ${AFTER}\n`);
  let pass = 0, fail = 0;
  for (const c of cases) {
    const [name, expBefore, expAfter] = c;
    const o = await run(t, before, c, expBefore);
    const n = await run(t, after, c, expAfter);
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${expBefore.padEnd(5)}→${expAfter.padEnd(5)}  ${name}`);
    if (!ok) {
      if (o.state !== 'SUCCESS') console.log(`        BEFORE was not ${expBefore}: ${o.state} ${o.detail}`);
      if (n.state !== 'SUCCESS') console.log(`        AFTER was not ${expAfter}: ${n.state} ${n.detail}`);
    }
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
