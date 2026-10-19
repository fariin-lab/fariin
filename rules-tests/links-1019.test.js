// 2026-10-19 groups v2 step 4: invite links are the server's. invites/{code} and the new
// conversations/{cid}/links/{code} take no client read or write; the functions-groups callables do it
// all with the admin SDK. Each row runs against the rules BEFORE the change and AFTER it.
// README: plain JSON, mock every get().
//
//   node links-1019.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node links-1019.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember', STRANGER = 'uidStranger';
const CID = 'grpLinks1';
const CODE = 'abcDEF2345';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;
const invPath = `${D}/invites/${CODE}`;
const linkPath = `${D}/conversations/${CID}/links/${CODE}`;

const users = [OWNER, ADMIN, MEMBER];
const group = {
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN], createdBy: OWNER,
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME,
};
const invite = { cid: CID, groupTitle: 'Plans', expireAt: 0, usageLimit: 0, usedCount: 0,
  requestApproval: false, revoked: false, createdBy: OWNER };
const link = Object.assign({ code: CODE, name: 'Class', isPrimary: false, joinedSample: [] }, invite);
const mocks = [
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data: group } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
];

const cases = [
  ['FIX     a stranger reads an invite by its code', 'ALLOW', 'DENY', STRANGER, invPath, 'get', null, invite],
  ['FIX     the owner reads an invite', 'ALLOW', 'DENY', OWNER, invPath, 'get', null, invite],
  ['FIX     an admin creates an invite', 'ALLOW', 'DENY', ADMIN, invPath, 'create', invite, null],
  ['FIX     an admin revokes an invite', 'ALLOW', 'DENY', ADMIN, invPath, 'update',
    Object.assign({}, invite, { revoked: true }), invite],
  ['FIX     an admin deletes an invite', 'ALLOW', 'DENY', ADMIN, invPath, 'delete', null, invite],
  ['GUARD   a member creates an invite', 'DENY', 'DENY', MEMBER, invPath, 'create', invite, null],
  ['GUARD   anyone lists invites', 'DENY', 'DENY', OWNER, `${D}/invites/x`, 'list', null, null],
  ['NEW     the owner reads a link record', 'DENY', 'DENY', OWNER, linkPath, 'get', null, link],
  ['NEW     a member reads a link record', 'DENY', 'DENY', MEMBER, linkPath, 'get', null, link],
  ['NEW     the owner writes a link record', 'DENY', 'DENY', OWNER, linkPath, 'create', link, null],
  ['NEW     the owner lists the links', 'DENY', 'DENY', OWNER, `${D}/conversations/${CID}/links/y`, 'list', null, null],
];

async function run(t, source, [, , , uid, p, method, after, before], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: [...mocks, { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
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
