// Group call permissions audit (2026-10-23, agent 5). Pins who may read, start and end a GROUP
// conversation's call doc (groupCalls/{cid}) under the CURRENT rules.
//
// Rows marked GAP were holes found in the audit. The 2026-10-23 fix phase removed the phone's end
// write from the rules, so those rows (now "was GAP") expect DENY. Run against the pre-fix rules
// (git show <fix>^:firestore.rules) they show ALLOW, which is the control.
//
//   node group-call-perms-1023.test.js                 # against ../firestore.rules
//   node group-call-perms-1023.test.js other.rules     # or any other rules file
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
// README: plain JSON, mock every get()/exists() the rules can reach.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', NOCALLS = 'uidAdminNoCalls', M = 'uidMember', M2 = 'uidMember2',
  R = 'uidRemoved', X = 'uidStranger';
const CID = 'Gq7ZkR2mN4pX8sV1tY3w';
const REQ_TIME = new Date().toISOString();
const EARLIER = new Date(Date.now() - 3600e3).toISOString();

const gt = (path, data) => ({ function: 'get', args: [{ exactValue: `${D}/${path}` }], result: { value: { data } } });
const noExists = { function: 'exists', args: [{ anyValue: {} }], result: { value: false } };

const baseConv = {
  type: 'group', users: [OWNER, ADMIN, NOCALLS, M, M2, R], createdBy: OWNER, admins: [OWNER, ADMIN, NOCALLS],
  adminRights: { [NOCALLS]: ['changeInfo'] },
};
const convMocks = (over = {}) => [gt(`conversations/${CID}`, { ...baseConv, ...over }), noExists];

const call = `${D}/groupCalls/${CID}`;
const start = (by, over = {}) => ({ active: true, startedBy: by, video: false, title: 'G', startedAt: REQ_TIME,
  recordId: 'gcall_X', ...over });
const live = (by, over = {}) => ({ active: true, startedBy: by, video: false, title: 'G', startedAt: EARLIER,
  recordId: 'gcall_X', ...over });
const ended = (d) => ({ ...d, active: false });

function cases() {
  const L = live(M2);
  return [
    // ── read ──
    ['member reads the call doc', 'ALLOW', M, call, 'get', null, L, convMocks()],
    ['non-member reads the call doc', 'DENY', X, call, 'get', null, L, convMocks()],
    ['1:1 chat id is not a group call', 'DENY', M, call, 'get', null, L, convMocks({ type: 'direct' })],

    // ── start ──
    ['member starts a call (create)', 'ALLOW', M, call, 'create', start(M), null, convMocks()],
    ['non-member starts a call', 'DENY', X, call, 'create', start(X), null, convMocks()],
    ['start in someone else\'s name', 'DENY', M, call, 'create', start(M2), null, convMocks()],
    ['member starts, admins-only group', 'DENY', M, call, 'create', start(M), null, convMocks({ onlyAdminsCall: true })],
    ['admin starts, admins-only group', 'ALLOW', ADMIN, call, 'create', start(ADMIN), null, convMocks({ onlyAdminsCall: true })],
    // The app's canStartCall lets the owner start even when not listed in `admins`; rules and
    // groupCallToken do not. Today the owner is always kept in `admins`, so this is a mismatch only.
    ['MISMATCH owner not in admins starts, admins-only', 'DENY', OWNER, call, 'create', start(OWNER), null,
      convMocks({ onlyAdminsCall: true, admins: [ADMIN] })],
    ['member starts in an ended group (endGroup)', 'DENY', M, call, 'create', start(M), null,
      convMocks({ endedAt: EARLIER })],
    ['member takes over a live call (start write over active doc)', 'DENY', M, call, 'update', start(M), L, convMocks()],
    ['member starts over an ended doc', 'ALLOW', M, call, 'update', start(M), ended(L), convMocks()],
    ['start write that drops removedUids', 'DENY', M, call, 'update', start(M), ended({ ...L, removedUids: [R] }), convMocks()],

    // ── end (active:false directly on the doc) ──
    // 2026-10-23 fix phase: the phone's end write is gone from the rules. Every end goes through the
    // server (groupCallClose when the room is empty, callAdmin for the owner, the sweep), so all of
    // these are DENY now, including the two former GAP rows.
    ['starter ends own call (now groupCallClose)', 'DENY', M2, call, 'update', ended(L), L, convMocks()],
    ['plain member ends someone else\'s call', 'DENY', M, call, 'update', ended(L), L, convMocks()],
    ['non-member ends the call', 'DENY', X, call, 'update', ended(L), L, convMocks()],
    ['removed-from-call admin ends the call', 'DENY', ADMIN, call, 'update', ended({ ...L, removedUids: [ADMIN] }),
      { ...L, removedUids: [ADMIN] }, convMocks()],
    ['was GAP: admin without manageCalls ends the call doc', 'DENY', NOCALLS, call, 'update', ended(L), L, convMocks()],
    ['was GAP: admin ends the doc of a call still running', 'DENY', ADMIN, call, 'update', ended(L), L, convMocks()],
    ['owner ends the call doc (now callAdmin)', 'DENY', OWNER, call, 'update', ended(L), L, convMocks()],

    // ── `joined` / `rung`: server-only (groupRingAnswer, onGroupCallStarted) ──
    ['start that writes joined', 'DENY', M, call, 'create', start(M, { joined: [M] }), null, convMocks()],
    ['start that writes rung', 'DENY', M, call, 'create', start(M, { rung: [M2] }), null, convMocks()],
    ['member adds self to joined on a live call', 'DENY', M, call, 'update', { ...L, joined: [M] }, L, convMocks()],
    ['member rewrites rung on a live call', 'DENY', M, call, 'update', { ...L, rung: [] }, { ...L, rung: [M] }, convMocks()],
    ['starter restarts own live doc carrying rung', 'DENY', M2, call, 'update', start(M2, { recordId: 'gcall_Y', rung: [M] }),
      { ...L, rung: [M] }, convMocks()],
    // Controls: a fresh start replaces the whole doc, so the old call's server fields simply go.
    ['starter restarts own live doc, new recordId', 'ALLOW', M2, call, 'update', start(M2, { recordId: 'gcall_Y' }),
      { ...L, rung: [M], joined: [M2] }, convMocks()],
    ['member starts over an ended doc that had joined/rung', 'ALLOW', M, call, 'update', start(M),
      ended({ ...L, rung: [M], joined: [M2, M] }), convMocks()],

    // ── keys a phone may not touch ──
    ['member writes removedUids', 'DENY', M2, call, 'update', { ...L, removedUids: [M] }, L, convMocks()],
    ['member writes declined for others', 'DENY', M, call, 'update', { ...L, declined: [M2] }, L, convMocks()],
    ['member deletes the call doc', 'DENY', M2, call, 'delete', null, L, convMocks()],
  ];
}

async function run(t, source, [, , uid, path, method, after, before, mocks], expectation) {
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
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;
  for (const c of cases()) {
    const o = await run(t, source, c, c[1]);
    const ok = o.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c[1].padEnd(5)}  ${c[0]}`);
    if (!ok) console.log(`        ${o.state} ${o.detail}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
