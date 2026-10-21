// 2026-10-21 MESSAGES BEFORE JOINING (owner): a signed-in outsider may READ the messages of a public
// group sent in the clear, with history open to newcomers, not ended, not suspended/disabled, and
// not banning them. Nothing else opens: the conversation document stays members-only, votes stay
// members-only, and no outsider may write a message. Each row runs against the rules BEFORE the
// change and AFTER it. README: plain JSON, mock every get().
//
//   node public-preview-1021.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node public-preview-1021.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', MEMBER = 'uidMember', OUT = 'uidOutsider';
const CID = 'grpPub1021';
const REQ_TIME = new Date().toISOString();
const PAST = new Date(Date.now() - 3600e3).toISOString();
const FUTURE = new Date(Date.now() + 3600e3).toISOString();
const convPath = `${D}/conversations/${CID}`;
const msgPath = `${convPath}/messages/msgPub1`;
const votePath = `${msgPath}/votes/${OWNER}`;

const users = [OWNER, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER], createdBy: OWNER, createdAt: REQ_TIME,
  names: { [OWNER]: OWNER, [MEMBER]: MEMBER }, photos: {},
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME, ...over,
});
const PUB = group({ e2ee: false, isPublic: true, username: 'plansgroup', usernameLower: 'plansgroup' });
const with_ = (base, over) => ({ ...base, ...over });
const without = (base, key) => { const c = { ...base }; delete c[key]; return c; };
const mocksFor = (p, data) => ([
  { function: 'get', args: [{ exactValue: p }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: p }], result: { value: true } },
]);
const convMocks = (data) => mocksFor(convPath, data);
const MSG = { authorId: OWNER, text: 'hello', createdAt: REQ_TIME };

const cases = [
  ["OK      member reads a public group", "ALLOW", "ALLOW", MEMBER, msgPath, "get", null, MSG, convMocks(PUB)],
  ["NEW     outsider reads a public plain group", "DENY", "ALLOW", OUT, msgPath, "get", null, MSG, convMocks(PUB)],
  ["NEW     outsider lists a public plain group", "DENY", "ALLOW", OUT, msgPath, "list", null, MSG, convMocks(PUB)],
  ["NEW     outsider, hideHistoryAt 0 counts as open", "DENY", "ALLOW", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { hideHistoryAt: 0 }))],
  ["NEW     outsider, endedAt 0 counts as open", "DENY", "ALLOW", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { endedAt: 0 }))],
  ["NEW     outsider, a suspension that ran out", "DENY", "ALLOW", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { mod: { state: 'suspended', until: PAST } }))],
  ["GUARD   outsider, private group", "DENY", "DENY", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { isPublic: false }))],
  ["GUARD   outsider, isPublic missing", "DENY", "DENY", OUT, msgPath, "list", null, MSG, convMocks(without(PUB, 'isPublic'))],
  ["GUARD   outsider, encrypted group (e2ee missing)", "DENY", "DENY", OUT, msgPath, "get", null, MSG, convMocks(without(PUB, 'e2ee'))],
  ["GUARD   outsider, encrypted group (e2ee true)", "DENY", "DENY", OUT, msgPath, "list", null, MSG, convMocks(with_(PUB, { e2ee: true }))],
  ["GUARD   outsider, history hidden from newcomers", "DENY", "DENY", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { hideHistoryAt: 1760000000000 }))],
  ["GUARD   outsider, history hidden (timestamp)", "DENY", "DENY", OUT, msgPath, "list", null, MSG, convMocks(with_(PUB, { hideHistoryAt: PAST }))],
  ["GUARD   outsider, group ended", "DENY", "DENY", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { endedAt: PAST }))],
  ["GUARD   outsider, banned", "DENY", "DENY", OUT, msgPath, "list", null, MSG, convMocks(with_(PUB, { bannedUids: [OUT] }))],
  ["GUARD   outsider, disabled by Fariin", "DENY", "DENY", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { mod: { state: 'disabled' } }))],
  ["GUARD   outsider, suspended by Fariin", "DENY", "DENY", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { mod: { state: 'suspended', until: FUTURE } }))],
  ["GUARD   outsider, a 1:1-shaped doc (not a group)", "DENY", "DENY", OUT, msgPath, "get", null, MSG, convMocks(with_(PUB, { type: 'direct' }))],
  ["GUARD   outsider, no such conversation", "DENY", "DENY", OUT, msgPath, "get", null, MSG, []],
  ["GUARD   outsider reads the group document", "DENY", "DENY", OUT, convPath, "get", null, PUB, convMocks(PUB)],
  ["GUARD   outsider reads votes", "DENY", "DENY", OUT, votePath, "list", null, { options: [0], at: REQ_TIME }, convMocks(PUB)],
  ["GUARD   outsider sends a message", "DENY", "DENY", OUT, msgPath, "create", { authorId: OUT, text: 'hi', createdAt: REQ_TIME }, null, convMocks(PUB)],
  ["GUARD   outsider deletes a message", "DENY", "DENY", OUT, msgPath, "delete", null, MSG, convMocks(PUB)],
  ["GUARD   signed out", "DENY", "DENY", null, msgPath, "get", null, MSG, convMocks(PUB)],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = { path: p, method, time: REQ_TIME };
  if (uid) request.auth = { uid, token: { firebase: { sign_in_provider: 'password' } } };
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
