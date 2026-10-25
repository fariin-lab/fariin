// 2026-10-25 groups end-to-end encrypted, step 1 (owner). Every group, private and public, is sealed:
// `e2ee` ABSENT or true = encrypted, `e2ee == false` = LEGACY plain group (made or switched since
// 2026-10-19). Rules: a new group is born with no `e2ee` field (false is refused at create); an
// encrypted group takes only an "encg1:" body on an ordinary message (plus a typed system notice);
// a legacy plain group still takes plain text; an outsider never reads an encrypted public group;
// `e2eeOnAt` (the server's flip back to encrypted) is server-only. Each row runs against the rules
// BEFORE the change and AFTER it. Needs the firebase-tools login on this machine and the network
// (Google's rules test service); nothing is deployed and nothing is written.
// NOT covered here: the 100-member cap (it needs a mocked config/limits and 101 uids; the rule is
// `users.size() <= 100` on create and on growth in groupFloorsKept).
//
//   git show HEAD~1:firestore.rules > before.rules   # the rules before this change
//   node groups-e2ee-1025.test.js before.rules ../firestore.rules
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node groups-e2ee-1025.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', MEMBER = 'uidMember', OUT = 'uidOutsider';
const CID = 'grpE2ee1025';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;
const msgPath = `${convPath}/messages/msgE2ee1`;
const newPath = `${D}/conversations/grpE2eeNew1025`;

const users = [OWNER, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER], createdBy: OWNER, createdAt: REQ_TIME,
  names: { [OWNER]: OWNER, [MEMBER]: MEMBER }, photos: {},
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME, ...over,
});
const ENC = group();                          // e2ee absent: encrypted
const ENC_TRUE = group({ e2ee: true });       // flipped back by the server
const LEGACY = group({ e2ee: false });        // legacy plain group
const PUB = (over) => group({ isPublic: true, username: 'plansgroup', usernameLower: 'plansgroup', ...over });
const mocksFor = (p, data) => ([
  { function: 'get', args: [{ exactValue: p }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: p }], result: { value: true } },
]);
const convMocks = (data) => mocksFor(convPath, data);
const encg1 = 'encg1:' + Buffer.from(JSON.stringify({ n: 'AAAA', c: 'BBBB', w: { [OWNER]: 'x.y', [MEMBER]: 'x.y' } })).toString('base64');
const msg = (text, over = {}) => ({ authorId: MEMBER, text, createdAt: REQ_TIME, ...over });
const with_ = (base, over) => ({ ...base, ...over });
const IMG = { type: 'image', imageUrl: 'https://x.test/a', enc: { v: 0, n: '', k: '', kn: '' } };

const cases = [
  // ── sending into an encrypted group ──
  ['GUARD   plain text, encrypted group (e2ee absent)', 'DENY', 'DENY', MEMBER, msgPath, 'create', msg('hello everyone'), null, convMocks(ENC)],
  ['GUARD   plain text, encrypted group (e2ee true)', 'DENY', 'DENY', MEMBER, msgPath, 'create', msg('hello everyone'), null, convMocks(ENC_TRUE)],
  ['OK      sealed encg1 text, encrypted group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg(encg1), null, convMocks(ENC)],
  ['OK      sealed encg1 text, e2ee true group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg(encg1), null, convMocks(ENC_TRUE)],
  ['FIX     a 1:1 envelope (enc1:) in a group', 'ALLOW', 'DENY', MEMBER, msgPath, 'create', msg('enc1:AAAA:BBBB'), null, convMocks(ENC)],
  ['FIX     photo with a PLAIN caption, encrypted group', 'ALLOW', 'DENY', MEMBER, msgPath, 'create', msg('look', IMG), null, convMocks(ENC)],
  ['OK      photo with a sealed caption, encrypted group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg(encg1, IMG), null, convMocks(ENC)],
  ['OK      photo with no caption, encrypted group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg('', IMG), null, convMocks(ENC)],
  ['OK      plain system notice, encrypted group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create',
    msg('uidMember changed the group name', { type: 'system' }), null, convMocks(with_(ENC, { membersCanEditInfo: true }))],
  // ── a legacy plain group is as before ──
  ['OK      plain text, legacy e2ee:false group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg('hello everyone'), null, convMocks(LEGACY)],
  ['OK      sealed text, legacy e2ee:false group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg(encg1), null, convMocks(LEGACY)],
  ['GUARD   65,537 plain characters, legacy group', 'DENY', 'DENY', MEMBER, msgPath, 'create', msg('a'.repeat(65537)), null, convMocks(LEGACY)],
  // ── creating a group ──
  ['OK      group born with no e2ee field', 'ALLOW', 'ALLOW', OWNER, newPath, 'create', group()],
  ['FIX     group born e2ee:false', 'ALLOW', 'DENY', OWNER, newPath, 'create', group({ e2ee: false })],
  ['GUARD   group born e2ee:true', 'DENY', 'DENY', OWNER, newPath, 'create', group({ e2ee: true })],
  ['GUARD   group born with e2eeOffAt', 'DENY', 'DENY', OWNER, newPath, 'create', group({ e2eeOffAt: REQ_TIME })],
  ['GUARD   group born with e2eeOnAt', 'DENY', 'DENY', OWNER, newPath, 'create', group({ e2eeOnAt: REQ_TIME })],
  // ── the flag is the server's ──
  ['GUARD   owner flips a legacy group to encrypted', 'DENY', 'DENY', OWNER, convPath, 'update', with_(LEGACY, { e2ee: true }), LEGACY, convMocks(LEGACY)],
  ['GUARD   owner switches an encrypted group to plain', 'DENY', 'DENY', OWNER, convPath, 'update', with_(ENC, { e2ee: false }), ENC, convMocks(ENC)],
  ['FIX     owner writes e2eeOnAt', 'ALLOW', 'DENY', OWNER, convPath, 'update', with_(LEGACY, { e2eeOnAt: REQ_TIME }), LEGACY, convMocks(LEGACY)],
  // ── reading ──
  ['OK      member reads an encrypted public group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'get', null, msg(encg1), convMocks(PUB({}))],
  ['GUARD   outsider reads an encrypted public group (e2ee absent)', 'DENY', 'DENY', OUT, msgPath, 'get', null, msg(encg1), convMocks(PUB({}))],
  ['GUARD   outsider lists an encrypted public group (e2ee true)', 'DENY', 'DENY', OUT, msgPath, 'list', null, msg(encg1), convMocks(PUB({ e2ee: true }))],
  ['GUARD   outsider reads an encrypted PRIVATE group', 'DENY', 'DENY', OUT, msgPath, 'get', null, msg(encg1), convMocks(ENC)],
  // Documented, not wanted long term: a LEGACY plain public group is still readable from outside by the
  // rules (the app no longer asks). Closing it is a one-line change in publicPreviewRead.
  ['NOTE    outsider reads a LEGACY plain public group', 'ALLOW', 'ALLOW', OUT, msgPath, 'get', null, msg('hello'), convMocks(PUB({ e2ee: false }))],
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
