// 2026-10-19 "Share the group link" (`membersCanShareLink`): an admin with change-info sets it,
// nobody else does, and a new group may start with it. Each row runs against the rules
// BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   node group-settings-1018.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node share-link-1019.test.js <before.rules> [after.rules]'); process.exit(2); }

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
  ['OK      an admin with change-info turns it on', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update',
    group({ membersCanShareLink: true }), g, convMocks(g)],
  ['OK      the owner turns it on', 'ALLOW', 'ALLOW', OWNER, convPath, 'update',
    group({ membersCanShareLink: true }), g, convMocks(g)],
  ['FIX     an admin without change-info turns it on', 'ALLOW', 'DENY', LIMITED, convPath, 'update',
    group({ membersCanShareLink: true }), g, convMocks(g)],
  ['GUARD   a member turns it on', 'DENY', 'DENY', MEMBER, convPath, 'update',
    group({ membersCanShareLink: true }), g, convMocks(g)],
  ['GUARD   a member turns it off', 'DENY', 'DENY', MEMBER, convPath, 'update',
    g, group({ membersCanShareLink: true }), convMocks(group({ membersCanShareLink: true }))],
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
