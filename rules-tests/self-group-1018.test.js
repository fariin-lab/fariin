// 2026-10-18: a group may be created with only its creator (New Group's Skip). Each row runs against
// the rules BEFORE the change and AFTER it; the self-only create must FLIP, every guard must hold on
// both. README: plain JSON, mock every get().
//
//   node self-group-1018.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node self-group-1018.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const ME = 'uidMember', OTHER = 'uidOther';
const CID = 'grpNew1';
const REQ_TIME = new Date().toISOString();
const path = `${D}/conversations/${CID}`;

// As `ChatService.createGroup` writes it (server timestamps given as the request time).
const group = (users, over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [ME], createdBy: ME, createdAt: REQ_TIME,
  names: Object.fromEntries(users.map((u) => [u, u])), photos: {},
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  typing: Object.fromEntries(users.map((u) => [u, false])),
  updatedAt: REQ_TIME, ...over,
});

const cases = [
  ['FIX     a group with only its creator', 'DENY', 'ALLOW', ME, path, 'create', group([ME])],
  ['OK      a group with the creator and one other', 'ALLOW', 'ALLOW', ME, path, 'create', group([ME, OTHER])],
  ['GUARD   a group with nobody in it', 'DENY', 'DENY', ME, path, 'create', group([])],
  ['GUARD   a one-person group of someone else', 'DENY', 'DENY', ME, path, 'create',
    group([OTHER], { admins: [OTHER], createdBy: OTHER })],
  ['GUARD   a self-only group where the creator is not admin', 'DENY', 'DENY', ME, path, 'create',
    group([ME], { admins: [OTHER] })],
  ['GUARD   a self-only group at a 1:1-shaped id', 'DENY', 'DENY', ME, `${D}/conversations/a_b`, 'create', group([ME])],
];

async function run(t, source, [, , , uid, p, method, after], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  // Not staff, not blocked, no existing document: production's answer for every lookup here.
  const testCase = { expectation, request, functionMocks: [{ function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
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
