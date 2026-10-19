// 2026-10-19 Groups v2 step 1: the most members a group may hold is config/limits.group_members_max
// (set from the admin panel, 2..500), read through appLimit, instead of a fixed 30. Each row runs
// against the rules BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   node group-limit-1019.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-limit-1019.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', MEMBER = 'uidMember';
const CID = 'grpLim1';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;
const limitsPath = `${D}/config/limits`;

// `n` members: the owner, one plain member, then filler accounts.
const people = (n) => [OWNER, MEMBER, ...Array.from({ length: Math.max(0, n - 2) }, (_, i) => `uidFill${i + 1}`)].slice(0, n);
const group = (users, over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER], createdBy: OWNER, createdAt: REQ_TIME,
  names: Object.fromEntries(users.map((u) => [u, u])), photos: {},
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  typing: Object.fromEntries(users.map((u) => [u, false])),
  updatedAt: REQ_TIME, ...over,
});
// An add as `addGroupMembers` writes it: users, names and unread grow, nothing else.
const grown = (from, n, over = {}) => {
  const users = people(n);
  return { ...from, users, names: Object.fromEntries(users.map((u) => [u, u])),
    unreadCount: Object.fromEntries(users.map((u) => [u, 0])), ...over };
};
const limits = (max) => ([
  { function: 'get', args: [{ exactValue: limitsPath }], result: { value: { data: { group_members_max: max } } } },
  { function: 'exists', args: [{ exactValue: limitsPath }], result: { value: true } },
]);
const convMocks = (data) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);

const five = group(people(5), { membersCanAdd: true });
const four = group(people(4), { membersCanAdd: true });
const cases = [
  // No config/limits document: the built-in 30 holds on both sides.
  ['OK      create with 30 members, no limits doc', 'ALLOW', 'ALLOW', OWNER, convPath, 'create', group(people(30)), null, []],
  ['GUARD   create with 31 members, no limits doc', 'DENY', 'DENY', OWNER, convPath, 'create', group(people(31)), null, []],
  // The panel raised it to 40: the rules read it.
  ['FIX     create with 31 members, limit 40', 'DENY', 'ALLOW', OWNER, convPath, 'create', group(people(31)), null, limits(40)],
  ['GUARD   create with 41 members, limit 40', 'DENY', 'DENY', OWNER, convPath, 'create', group(people(41)), null, limits(40)],
  // The panel lowered it to 5.
  ['FIX     create with 6 members, limit 5', 'ALLOW', 'DENY', OWNER, convPath, 'create', group(people(6)), null, limits(5)],
  ['OK      create with 5 members, limit 5', 'ALLOW', 'ALLOW', OWNER, convPath, 'create', group(people(5)), null, limits(5)],
  ['FIX     member adds the 6th, limit 5', 'ALLOW', 'DENY', MEMBER, convPath, 'update', grown(five, 6), five, [...limits(5), ...convMocks(five)]],
  ['OK      member adds the 5th, limit 5', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update', grown(four, 5), four, [...limits(5), ...convMocks(four)]],
  ['FIX     owner adds the 6th, limit 5', 'ALLOW', 'DENY', OWNER, convPath, 'update', grown(five, 6), five, [...limits(5), ...convMocks(five)]],
  ['OK      owner adds the 5th, limit 5', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', grown(four, 5), four, [...limits(5), ...convMocks(four)]],
  // Text in the document is ignored (appLimit wants an int): back to 30.
  ['GUARD   create with 31, limit stored as text', 'DENY', 'DENY', OWNER, convPath, 'create', group(people(31)), null,
    [{ function: 'get', args: [{ exactValue: limitsPath }], result: { value: { data: { group_members_max: '40' } } } },
     { function: 'exists', args: [{ exactValue: limitsPath }], result: { value: true } }]],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  // Not staff, not blocked, no other document: production's answer for every other lookup here.
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
