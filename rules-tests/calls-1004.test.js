// 2026-10-04 calls: multi-person (adhoc_) calls, call links and the saved-links list, run against the
// rules BEFORE the change and AFTER it. New paths flip DENY→ALLOW only where intended; group-call rows
// must answer the same on both.
// README: plain JSON, mock every get()/exists() the rules can reach.
//
//   node calls-1004.test.js before.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node calls-1004.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const A = 'uidStarter', B = 'uidInvited', C = 'uidStranger', N = 'uidNew';
const REQ_TIME = new Date().toISOString();
const ROOM = 'adhoc_1b2c3d4e-0000-4000-8000-000000000000';
const LINK = 'a'.repeat(64);

const gt = (path, data) => ({ function: 'get', args: [{ exactValue: `${D}/${path}` }], result: { value: { data } } });
const noExists = { function: 'exists', args: [{ anyValue: {} }], result: { value: false } };
const groupMocks = [gt('conversations/g1', { users: [A, B] }), noExists];
const linkMocks = [gt(`callLinks/${LINK}`, { creatorUid: A }), noExists];

const adhoc = (over = {}) => ({ kind: 'adhoc', active: true, startedBy: A, video: false, title: 'B',
  members: [A, B], names: { [A]: 'A', [B]: 'B' }, photos: {}, joined: [A], ...over });
const groupStart = { active: true, startedBy: A, video: false, title: 'G' };

function cases() {
  const call = `${D}/groupCalls/${ROOM}`;
  const grp = `${D}/groupCalls/g1`;
  const link = `${D}/callLinks/${LINK}`;
  const req = (u) => `${D}/callLinks/${LINK}/requests/${u}`;
  const saved = (u) => `${D}/users/${u}/callLinks/${LINK}`;
  const one = `${D}/calls/c1`;
  const pair = { caller: A, callee: B, status: 'active' };
  return [
    // ── group calls unchanged ──
    ['OK      group member reads group call', 'ALLOW', 'ALLOW', B, grp, 'get', null, groupStart, groupMocks],
    ['OK      stranger cannot read group call', 'DENY', 'DENY', C, grp, 'get', null, groupStart, groupMocks],
    ['OK      group member starts group call', 'ALLOW', 'ALLOW', A, grp, 'create', groupStart, null, groupMocks],
    // ── ad-hoc calls ──
    ['NEW     starter creates ad-hoc call', 'DENY', 'ALLOW', A, call, 'create', adhoc(), null, [noExists]],
    ['OK      create with someone else as starter', 'DENY', 'DENY', B, call, 'create', adhoc(), null, [noExists]],
    ['OK      create without myself in members', 'DENY', 'DENY', A, call, 'create', adhoc({ members: [B] }), null, [noExists]],
    ['OK      create with 33 members', 'DENY', 'DENY', A, call, 'create',
      adhoc({ members: [A, ...Array.from({ length: 32 }, (_, i) => `u${i}`)] }), null, [noExists]],
    ['NEW     member reads ad-hoc call', 'DENY', 'ALLOW', B, call, 'get', null, adhoc(), [noExists]],
    ['OK      stranger reads ad-hoc call', 'DENY', 'DENY', C, call, 'get', null, adhoc(), [noExists]],
    ['NEW     member adds a person', 'DENY', 'ALLOW', B, call, 'update', adhoc({ members: [A, B, N] }), adhoc(), [noExists]],
    ['OK      member removes a person', 'DENY', 'DENY', B, call, 'update', adhoc({ members: [B, N] }), adhoc(), [noExists]],
    ['OK      member changes startedBy', 'DENY', 'DENY', B, call, 'update', adhoc({ startedBy: B }), adhoc(), [noExists]],
    ['OK      stranger adds themself', 'DENY', 'DENY', C, call, 'update', adhoc({ members: [A, B, C] }), adhoc(), [noExists]],
    // ── call links ──
    ['NEW     signed-in user gets a link', 'DENY', 'ALLOW', C, link, 'get', null, { creatorUid: A }, [noExists]],
    ['OK      nobody lists links', 'DENY', 'DENY', A, `${D}/callLinks`, 'list', null, null, [noExists]],
    ['OK      phone cannot write a link', 'DENY', 'DENY', A, link, 'create', { creatorUid: A }, null, [noExists]],
    ['NEW     requester gets own request', 'DENY', 'ALLOW', B, req(B), 'get', null, { status: 'pending' }, linkMocks],
    ['NEW     creator gets a request', 'DENY', 'ALLOW', A, req(B), 'get', null, { status: 'pending' }, linkMocks],
    ['OK      stranger gets someone else request', 'DENY', 'DENY', C, req(B), 'get', null, { status: 'pending' }, linkMocks],
    ['OK      requester approves self', 'DENY', 'DENY', B, req(B), 'update', { status: 'approved' }, { status: 'pending' }, linkMocks],
    // ── saved links ──
    ['NEW     owner saves a link', 'DENY', 'ALLOW', A, saved(A), 'create',
      { key: 'bcdf-ghkm-npqr-stxz-bcdf-ghkm-npqr-stxz', name: 'Kulan Call', admin: true }, null, [noExists]],
    ['OK      someone else reads my saved link', 'DENY', 'DENY', C, saved(A), 'get', null,
      { key: 'k', name: '', admin: true }, [noExists]],
    ['OK      name over 64', 'DENY', 'DENY', A, saved(A), 'create', { key: 'k', name: 'x'.repeat(65), admin: false }, null, [noExists]],
    // ── 1:1 call: new fields ──
    ['OK      callee writes moveTo', 'ALLOW', 'ALLOW', B, one, 'update', { ...pair, moveTo: ROOM }, pair, [noExists]],
    ['OK      caller writes restartRequest', 'ALLOW', 'ALLOW', A, one, 'update', { ...pair, restartRequest: 1 }, pair, [noExists]],
  ];
}

async function run(t, source, [, , , uid, path, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: mocks };
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
  let pass = 0, fail = 0;
  for (const c of cases()) {
    const o = await run(t, before, c, c[1]), n = await run(t, after, c, c[2]);
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c[1].padEnd(5)}→${c[2].padEnd(5)}  ${c[0]}`);
    if (o.state !== 'SUCCESS') console.log(`        BEFORE: ${o.state} ${o.detail}`);
    if (n.state !== 'SUCCESS') console.log(`        AFTER: ${n.state} ${n.detail}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
