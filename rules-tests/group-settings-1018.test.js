// 2026-10-18 Group Settings: who may start a call (`onlyAdminsCall`), Restricted Group
// (`restrictedBy` by an admin), and Member Label (`memberLabels`). Each row runs against the rules
// BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   node group-settings-1018.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-settings-1018.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', LIMITED = 'uidLimited', MEMBER = 'uidMember';
const CID = 'grpSet1';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;
const callPath = `${D}/groupCalls/${CID}`;

const users = [OWNER, ADMIN, LIMITED, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN, LIMITED], createdBy: OWNER,
  // LIMITED is an admin without the change-info right.
  adminRights: { [LIMITED]: ['inviteUsers'] },
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME, ...over,
});
const convMocks = (data) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);
const start = (by) => ({ active: true, startedBy: by, video: false, title: 'Plans', startedAt: REQ_TIME });

const g = group();
const cases = [
  // ── who may start a call ──
  ['OK      a member starts a call (Everyone)', 'ALLOW', 'ALLOW', MEMBER, callPath, 'create', start(MEMBER), null, convMocks(g)],
  ['FIX     a member starts a call (Admins only)', 'ALLOW', 'DENY', MEMBER, callPath, 'create', start(MEMBER), null,
    convMocks(group({ onlyAdminsCall: true }))],
  ['OK      an admin starts a call (Admins only)', 'ALLOW', 'ALLOW', ADMIN, callPath, 'create', start(ADMIN), null,
    convMocks(group({ onlyAdminsCall: true }))],
  ['FIX     a member restarts an ended call (Admins only)', 'ALLOW', 'DENY', MEMBER, callPath, 'update', start(MEMBER),
    { ...start(OWNER), active: false }, convMocks(group({ onlyAdminsCall: true }))],
  // ── the switch itself ──
  ['OK      the owner sets Admins only', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', group({ onlyAdminsCall: true }), g, convMocks(g)],
  ['OK      an admin with change-info sets Admins only', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update', group({ onlyAdminsCall: true }), g, convMocks(g)],
  ['FIX     an admin without change-info sets Admins only', 'ALLOW', 'DENY', LIMITED, convPath, 'update', group({ onlyAdminsCall: true }), g, convMocks(g)],
  ['GUARD   a member sets Admins only', 'DENY', 'DENY', MEMBER, convPath, 'update', group({ onlyAdminsCall: true }), g, convMocks(g)],
  // ── Restricted Group ──
  ['OK      an admin with change-info turns on Restricted Group', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update',
    group({ restrictedBy: { [ADMIN]: true } }), g, convMocks(g)],
  ['FIX     an admin without change-info turns it on', 'ALLOW', 'DENY', LIMITED, convPath, 'update',
    group({ restrictedBy: { [LIMITED]: true } }), g, convMocks(g)],
  ['GUARD   a member turns it on', 'DENY', 'DENY', MEMBER, convPath, 'update',
    group({ restrictedBy: { [MEMBER]: true } }), g, convMocks(g)],
  ['GUARD   a member turns it off', 'DENY', 'DENY', MEMBER, convPath, 'update',
    g, group({ restrictedBy: { [ADMIN]: true } }), convMocks(group({ restrictedBy: { [ADMIN]: true } }))],
  // ── Member Label ──
  ['FIX     a member sets their own label', 'DENY', 'ALLOW', MEMBER, convPath, 'update',
    group({ memberLabels: { [MEMBER]: 'Designer' } }), g, convMocks(g)],
  ['GUARD   a member sets someone else\'s label', 'DENY', 'DENY', MEMBER, convPath, 'update',
    group({ memberLabels: { [ADMIN]: 'Boss' } }), g, convMocks(g)],
  ['GUARD   a member sets a 25-character label', 'DENY', 'DENY', MEMBER, convPath, 'update',
    group({ memberLabels: { [MEMBER]: 'x'.repeat(25) } }), g, convMocks(g)],
  ['OK      an admin with change-info labels a member', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update',
    group({ memberLabels: { [MEMBER]: 'Designer' } }), g, convMocks(g)],
  ['OK      an admin without change-info labels themselves', 'ALLOW', 'ALLOW', LIMITED, convPath, 'update',
    group({ memberLabels: { [LIMITED]: 'Helper' } }), g, convMocks(g)],
  ['FIX     an admin without change-info labels a member', 'ALLOW', 'DENY', LIMITED, convPath, 'update',
    group({ memberLabels: { [MEMBER]: 'Designer' } }), g, convMocks(g)],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  // Not staff, not blocked: production's answer for every other lookup here.
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
