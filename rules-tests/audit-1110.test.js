// Release audit 2026-11-10, firestore.rules rows: M14 (a ban never names the owner or an admin),
// L8 (the profile's Joined date is the server's), L1 (no seeded anonymous accounts) and M6 (a public
// story mirror only links to the story's own files), and the 10-check rows (M11 tombstone, C2
// duration, H1 diag TTL). Each row runs before and after the change. Pass LF
// copies of the rules: a Windows CRLF checkout is over the 262,144 byte source cap. Also run
// admin-delete-1018.test.js: a restricted member's send sits near the 1,000 expression limit.
// Story document rows for M6 are in story-freeze.test.js.
//
//   git show 8997387cb:firestore.rules > before-audit-1110.rules
//   node audit-1110.test.js before-audit-1110.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node audit-1110.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', LIMITED = 'uidLimited', MEMBER = 'uidMember';
const CID = 'grpAudit1';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;

const users = [OWNER, ADMIN, LIMITED, MEMBER];
// ADMIN: legacy admin, every right (banUsers included). LIMITED: invite only.
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN, LIMITED], createdBy: OWNER,
  adminRights: { [LIMITED]: ['inviteUsers'] }, bannedUids: [],
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME, ...over,
});
const convMocks = (data) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);
const g = group();
const U = (name, b, a, uid, after, before = g) => [name, b, a, uid, convPath, 'update', after, before, convMocks(before)];

const me = 'uidPerson01';
const profile = { name: 'Person', handleLower: 'person' };
const SEEDED = 'TuAVsimc3KMU7rWsXwASRCzPjwl2';   // the old "Test Amina"
const SID = 'story123';
const own = (f) => `https://firebasestorage.googleapis.com/v0/b/kulan/o/stories%2F${SID}%2F${f}?alt=media&token=t`;
const mirror = (over = {}) => ({ authorUid: me, createdAt: REQ_TIME, expiresAt: REQ_TIME, mediaUrl: own('photo.jpg'),
  thumbUrl: '', type: 'image', caption: '', duration: 0, allowsReplies: true, ...over });
const mirrorPath = `${D}/users/${me}/publicStories/${SID}`;
const msgPath = `${convPath}/messages/file1`;
const plainFile = { authorId: MEMBER, createdAt: REQ_TIME, text: '', type: 'file',
  fileUrl: 'https://x/y.pdf', fileName: 'y.pdf', fileSize: 10 };
const sealedFile = { ...plainFile, fileName: 'Document.pdf', fileNameEnc: 'enc1:name' };
const tomb = { authorId: MEMBER, createdAt: REQ_TIME, text: '', type: 'text', deleted: true };
const send = (over) => [MEMBER, `${convPath}/messages/new1`, 'create',
  { authorId: MEMBER, createdAt: REQ_TIME, text: 'enc1:x', ...over }, null, convMocks(g)];
const diagPath = `${D}/users/${me}/diag/d1`;
const diag = (over = {}) => ({ text: 'log', build: '1', ios: '18', at: REQ_TIME, ...over });
const inDays = (n) => new Date(Date.parse(REQ_TIME) + n * 86400e3).toISOString();

// [name, before, after, uid, path, method, newData, oldData, mocks, provider]
const cases = [
  // M14
  U('FIX     a ban-right admin bans the owner', 'ALLOW', 'DENY', ADMIN, group({ bannedUids: [OWNER] })),
  U('FIX     a ban-right admin bans another admin', 'ALLOW', 'DENY', ADMIN, group({ bannedUids: [LIMITED] })),
  U('OK      a ban-right admin removes and bans a member', 'ALLOW', 'ALLOW', ADMIN,
    group({ users: [OWNER, ADMIN, LIMITED], bannedUids: [MEMBER] })),
  U('OK      a ban-right admin lifts a ban', 'ALLOW', 'ALLOW', ADMIN, group(), group({ bannedUids: [MEMBER] })),
  // L8
  ['FIX     I back-date my own Joined date', 'ALLOW', 'DENY', me, `${D}/users/${me}`, 'update',
    { ...profile, createdAt: '2015-01-01T00:00:00Z' }, profile, []],
  ['FIX     my profile is born with a Joined date', 'ALLOW', 'DENY', me, `${D}/users/${me}`, 'create',
    { name: 'Person', createdAt: '2015-01-01T00:00:00Z' }, null, []],
  ['OK      I edit my name', 'ALLOW', 'ALLOW', me, `${D}/users/${me}`, 'update', { ...profile, name: 'New' }, profile, []],
  // L1
  ['FIX     a seeded anonymous test account reads a profile', 'ALLOW', 'DENY', SEEDED, `${D}/users/${me}`, 'get',
    null, profile, [], 'anonymous'],
  ['OK      a real account reads a profile', 'ALLOW', 'ALLOW', SEEDED, `${D}/users/${me}`, 'get', null, profile, []],
  // M6, the public mirror
  ['OK      my mirror links to the story\'s own photo', 'ALLOW', 'ALLOW', me, mirrorPath, 'create', mirror(), null, []],
  ['FIX     my mirror links to a site we do not host', 'ALLOW', 'DENY', me, mirrorPath, 'create',
    mirror({ mediaUrl: 'https://evil.example/x.jpg' }), null, []],
  ['FIX     my mirror links to another story\'s file', 'ALLOW', 'DENY', me, mirrorPath, 'create',
    mirror({ mediaUrl: own('photo.jpg').replace(SID, 'other1') }), null, []],
  // M11 check: Delete for Everyone on a document whose real name is sealed in `fileNameEnc`
  ['FIX     my tombstone drops the sealed file name', 'DENY', 'ALLOW', MEMBER, msgPath, 'update',
    tomb, sealedFile, convMocks(g)],
  ['FIX     my tombstone keeps the sealed file name', 'ALLOW', 'DENY', MEMBER, msgPath, 'update',
    { ...tomb, fileNameEnc: 'enc1:name' }, sealedFile, convMocks(g)],
  ['OK      my tombstone of a plain-name document', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'update',
    tomb, plainFile, convMocks(g)],
  // C2 check: every kind's duration is a real length (a voice note's still at most 1,900 s).
  ['OK      a message with a 30 s duration', 'ALLOW', 'ALLOW', ...send({ duration: 30 })],
  ['FIX     a message with a 1e300 duration', 'ALLOW', 'DENY', ...send({ duration: 1e300 })],
  ['FIX     a message with a negative duration', 'ALLOW', 'DENY', ...send({ duration: -5 })],
  ['OK      a 25 minute voice note', 'ALLOW', 'ALLOW', ...send({ type: 'audio', duration: 1500, audioUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/chat%2Fx' })],
  ['GUARD   a 40 minute voice note', 'DENY', 'DENY', ...send({ type: 'audio', duration: 2400, audioUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/chat%2Fx' })],
  // H1 check: the diag upload may carry its TTL stamp.
  ['FIX     a diag upload with expireAt', 'DENY', 'ALLOW', me, diagPath, 'create', diag({ expireAt: inDays(30) }), null, []],
  ['OK      a diag upload without expireAt', 'ALLOW', 'ALLOW', me, diagPath, 'create', diag(), null, []],
  ['GUARD   a diag upload kept for a year', 'DENY', 'DENY', me, diagPath, 'create', diag({ expireAt: inDays(365) }), null, []],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks, provider], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: provider || 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  // Not staff, not blocked, no limits doc: production's answer for every other lookup here.
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
