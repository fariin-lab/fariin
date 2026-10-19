// 2026-10-19 groups v2: a group's type and public @name (`isPublic`, `username`, `usernameLower`)
// are written only by functions-username setGroupUsername. No client write may set them, at create
// or at update, the owner's included. Each row runs against the rules BEFORE the change and AFTER it.
// README: plain JSON, mock every get().
//
//   node group-type-1019.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-type-1019.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember';
const CID = 'grpType1';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;

const users = [OWNER, ADMIN, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN], createdBy: OWNER,
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME, ...over,
});
// As ChatService.createGroup writes it (server timestamps given as the request time).
const fresh = (over = {}) => ({
  type: 'group', title: 'Plans', users: [OWNER, MEMBER], admins: [OWNER], createdBy: OWNER, createdAt: REQ_TIME,
  names: { [OWNER]: OWNER, [MEMBER]: MEMBER }, photos: {},
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, typing: { [OWNER]: false, [MEMBER]: false },
  updatedAt: REQ_TIME, ...over,
});
const convMocks = (data) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);
const pub = { isPublic: true, username: 'PlansClub', usernameLower: 'plansclub' };

const g = group();
const gp = group(pub);
const cases = [
  ['OK      a plain group create', 'ALLOW', 'ALLOW', OWNER, convPath, 'create', fresh(), null, null],
  ['FIX     a create that makes itself public', 'ALLOW', 'DENY', OWNER, convPath, 'create', fresh({ isPublic: true }), null, null],
  ['FIX     a create that names itself', 'ALLOW', 'DENY', OWNER, convPath, 'create',
    fresh({ username: 'PlansClub', usernameLower: 'plansclub' }), null, null],
  ['OK      the owner renames the group', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', group({ title: 'New' }), g, convMocks(g)],
  ['OK      the owner renames a public group', 'ALLOW', 'ALLOW', OWNER, convPath, 'update',
    group(Object.assign({ title: 'New' }, pub)), gp, convMocks(gp)],
  ['FIX     the owner makes the group public', 'ALLOW', 'DENY', OWNER, convPath, 'update', group({ isPublic: true }), g, convMocks(g)],
  ['FIX     an admin sets a group @name', 'ALLOW', 'DENY', ADMIN, convPath, 'update',
    group({ username: 'Mine', usernameLower: 'mine' }), g, convMocks(g)],
  ['FIX     the owner drops the @name by hand', 'ALLOW', 'DENY', OWNER, convPath, 'update',
    group({ isPublic: false }), gp, convMocks(gp)],
  ['FIX     the owner turns on join approval by hand', 'ALLOW', 'DENY', OWNER, convPath, 'update',
    group(Object.assign({ joinApproval: true }, pub)), gp, convMocks(gp)],
  ['GUARD   a member makes the group public', 'DENY', 'DENY', MEMBER, convPath, 'update',
    group({ isPublic: true, usernameLower: 'x' }), g, convMocks(g)],
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
