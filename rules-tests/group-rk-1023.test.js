// 2026-10-23 (owner): groups are not end-to-end encrypted, only 1:1 is. Old sealed group items get
// their keys released by the server (releaseGroupKeys) into `rk` on the message. `rk` is the
// server's: no client may create a message carrying it, add it, change it or remove it. Members read
// it with the message; outsiders read it in a switched PUBLIC group with history open (owner: yes,
// the whole history). Each row runs against the rules BEFORE the change and AFTER it.
// README: plain JSON, mock every get().
//
//   node group-rk-1023.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-rk-1023.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', MEMBER = 'uidMember', OUT = 'uidOutsider';
const CID = 'grpRk1023';
const REQ_TIME = new Date().toISOString();
const AT = new Date(Date.now() - 86400e3).toISOString();
const convPath = `${D}/conversations/${CID}`;
const msgPath = `${convPath}/messages/msgRk1`;
const dmPath = `${D}/conversations/${MEMBER}_${OWNER}`;

const users = [OWNER, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER], createdBy: OWNER, createdAt: REQ_TIME,
  names: { [OWNER]: OWNER, [MEMBER]: MEMBER }, photos: {},
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME, e2ee: false, ...over,
});
const PLAIN = group();
const PUB = group({ isPublic: true, username: 'plansgroup', usernameLower: 'plansgroup' });
const dm = () => ({
  type: 'direct', users: [MEMBER, OWNER], accepted: true, startedBy: OWNER, lastSender: MEMBER,
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME,
});
const notAdmin = (uid) => ({ function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } });
const mocksFor = (p, data) => ([
  { function: 'get', args: [{ exactValue: p }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: p }], result: { value: true } },
  notAdmin(OWNER), notAdmin(MEMBER), notAdmin(OUT),
]);
const convMocks = (data) => mocksFor(convPath, data);
const RK = { AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA: 'a2V5a2V5a2V5a2V5a2V5a2V5a2V5a2V5a2V5a2U=' };
const encg1 = 'encg1:' + Buffer.from(JSON.stringify({ n: 'AAAA', c: 'BBBB', w: { [OWNER]: 'x.y' } })).toString('base64');
const OLD = { authorId: OWNER, text: encg1, type: 'text', createdAt: AT, rk: RK };
const NORK = { authorId: OWNER, text: encg1, type: 'text', createdAt: AT };
const tomb = { authorId: OWNER, type: 'text', text: '', deleted: true, createdAt: AT };
const msg = (over = {}) => ({ authorId: MEMBER, text: 'hello', createdAt: REQ_TIME, ...over });

const cases = [
  // ── create ──
  ['OK      plain group message', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg(), null, convMocks(PLAIN)],
  ['FIX     group message born with rk', 'ALLOW', 'DENY', MEMBER, msgPath, 'create', msg({ rk: RK }), null, convMocks(PLAIN)],
  ['FIX     sealed group message born with rk', 'ALLOW', 'DENY', MEMBER, msgPath, 'create', msg({ text: encg1, rk: RK }), null, convMocks(PLAIN)],
  ['FIX     1:1 message born with rk', 'ALLOW', 'DENY', MEMBER, `${dmPath}/messages/m1`, 'create',
    msg({ text: 'enc1:AAAA:BBBB', rk: RK }), null, mocksFor(dmPath, dm())],
  ['OK      1:1 sealed message', 'ALLOW', 'ALLOW', MEMBER, `${dmPath}/messages/m1`, 'create',
    msg({ text: 'enc1:AAAA:BBBB' }), null, mocksFor(dmPath, dm())],
  // ── update: no branch takes rk ──
  ['GUARD   member adds rk to a message', 'DENY', 'DENY', MEMBER, msgPath, 'update', { ...NORK, rk: RK }, NORK, convMocks(PLAIN)],
  ['GUARD   author adds rk to own message', 'DENY', 'DENY', OWNER, msgPath, 'update', { ...NORK, rk: RK }, NORK, convMocks(PLAIN)],
  ['GUARD   member reacts and adds rk', 'DENY', 'DENY', MEMBER, msgPath, 'update',
    { ...NORK, reactions: { [MEMBER]: 'x' }, rk: RK }, NORK, convMocks(PLAIN)],
  ['OK      member reacts on a message with rk', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'update',
    { ...OLD, reactions: { [MEMBER]: 'x' } }, OLD, convMocks(PLAIN)],
  ['GUARD   member changes rk', 'DENY', 'DENY', MEMBER, msgPath, 'update', { ...OLD, rk: { x: 'y' } }, OLD, convMocks(PLAIN)],
  ['GUARD   author removes rk', 'DENY', 'DENY', OWNER, msgPath, 'update', NORK, OLD, convMocks(PLAIN)],
  // ── delete for everyone: the tombstone keeps working; the server trigger drops rk ──
  ['OK      author tombstones a message carrying rk', 'ALLOW', 'ALLOW', OWNER, msgPath, 'update', { ...tomb, rk: RK }, OLD, convMocks(PLAIN)],
  ['GUARD   tombstone that also removes rk', 'DENY', 'DENY', OWNER, msgPath, 'update', tomb, OLD, convMocks(PLAIN)],
  ['OK      author hard-deletes a message carrying rk', 'ALLOW', 'ALLOW', OWNER, msgPath, 'delete', null, OLD, convMocks(PLAIN)],
  // ── read ──
  ['OK      member reads a message with rk', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'get', null, OLD, convMocks(PLAIN)],
  ['OK      outsider reads old history (rk) of a public switched group', 'ALLOW', 'ALLOW', OUT, msgPath, 'get', null, OLD, convMocks(PUB)],
  ['OK      outsider lists a public switched group', 'ALLOW', 'ALLOW', OUT, msgPath, 'list', null, OLD, convMocks(PUB)],
  ['GUARD   outsider, public group with history hidden', 'DENY', 'DENY', OUT, msgPath, 'get', null, OLD,
    convMocks(group({ isPublic: true, hideHistoryAt: AT }))],
  ['GUARD   outsider, public group not switched', 'DENY', 'DENY', OUT, msgPath, 'get', null, OLD,
    convMocks(group({ isPublic: true, e2ee: true }))],
  ['GUARD   outsider, private switched group', 'DENY', 'DENY', OUT, msgPath, 'get', null, OLD, convMocks(PLAIN)],
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
