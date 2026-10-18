// owner 2026-10-18: the admin delete sheet ("What can this member do?"). Two things changed:
//   · `sendMedia` split into sendPhotos / sendFiles / sendLinks on message create (the old flag
//     still covers all three);
//   · a non-owner admin may not write a restriction for the owner or another admin.
// Each row runs against the rules BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   node admin-delete-1018.test.js before-delacts-tree.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node admin-delete-1018.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', LIMITED = 'uidLimited', ME = 'uidMember';
const CID = 'grpDel1';
const REQ_TIME = new Date().toISOString();
const now = Date.parse(REQ_TIME);
const until = now + 3600e3;
const convPath = `${D}/conversations/${CID}`;

const users = [OWNER, ADMIN, LIMITED, ME];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN, LIMITED], createdBy: OWNER,
  // LIMITED is an admin without the restrict right.
  adminRights: { [LIMITED]: ['inviteUsers'] },
  onlyAdminsSend: false, pinnedMessageIds: [], blockedBy: {}, mutedBy: {}, clearedAt: {},
  lastRead: {}, pinnedBy: {}, archivedBy: {}, photos: {}, posters: {},
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  lastMessage: 'hi', lastSender: ADMIN, updatedAt: REQ_TIME, ...over,
});
const convMocks = (data) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);
const notStaff = users.map((u) => ({ function: 'exists', args: [{ exactValue: `${D}/admins/${u}` }], result: { value: false } }));

const restricted = (uid, flags, u = until) => group({ restrictedFlags: { [uid]: flags }, restrictedUntil: { [uid]: u } });
const send = (data, flags = [], u = until) => [ME, `${convPath}/messages/m9`, 'create',
  { authorId: ME, createdAt: REQ_TIME, text: '', ...data }, null,
  [...notStaff, ...convMocks(flags.length ? restricted(ME, flags, u) : group())]];

const photo = { type: 'image', imageUrl: 'https://x/y' };
const file = { type: 'file', fileUrl: 'https://x/y.pdf', fileName: 'y.pdf', fileSize: 10 };
const link = { text: 'enc1:x', linkPreview: { url: 'enc1:sealed' } };
const text = { text: 'enc1:x' };

const g = group();
const upd = (by, after, before = g) => [by, convPath, 'update', after, before, [...notStaff, ...convMocks(before)]];

// [name, before, after, caller, path, method, newData, oldData, mocks]
const cases = [
  // ── the finer media flags on send ──
  ['FIX     photo-restricted member sends a photo', 'ALLOW', 'DENY', ...send(photo, ['sendPhotos'])],
  ['OK      photo-restricted member sends a file', 'ALLOW', 'ALLOW', ...send(file, ['sendPhotos'])],
  ['OK      photo-restricted member sends a text', 'ALLOW', 'ALLOW', ...send(text, ['sendPhotos'])],
  ['FIX     file-restricted member sends a file', 'ALLOW', 'DENY', ...send(file, ['sendFiles'])],
  ['OK      file-restricted member sends a photo', 'ALLOW', 'ALLOW', ...send(photo, ['sendFiles'])],
  ['FIX     link-restricted member sends a link card', 'ALLOW', 'DENY', ...send(link, ['sendLinks'])],
  ['OK      link-restricted member sends plain text', 'ALLOW', 'ALLOW', ...send(text, ['sendLinks'])],
  ['OK      photo restriction that has ended', 'ALLOW', 'ALLOW', ...send(photo, ['sendPhotos'], now - 1000)],
  ['GUARD   old all-media flag still stops a file', 'DENY', 'DENY', ...send(file, ['sendMedia'])],
  ['GUARD   old all-media flag still stops a link card', 'DENY', 'DENY', ...send(link, ['sendMedia'])],
  ['GUARD   muted member sends a text', 'DENY', 'DENY', ...send(text, ['sendText'])],
  // ── who may write a restriction ──
  ['OK      admin restricts a member', 'ALLOW', 'ALLOW',
    ...upd(ADMIN, restricted(ME, ['sendPhotos', 'sendLinks']))],
  ['OK      admin lifts a member\'s restriction', 'ALLOW', 'ALLOW',
    ...upd(ADMIN, group({ restrictedFlags: {}, restrictedUntil: {} }), restricted(ME, ['sendText']))],
  ['FIX     admin restricts the owner', 'ALLOW', 'DENY', ...upd(ADMIN, restricted(OWNER, ['sendText']))],
  ['FIX     admin restricts another admin', 'ALLOW', 'DENY', ...upd(ADMIN, restricted(LIMITED, ['sendText']))],
  ['FIX     admin sets only an until date on the owner', 'ALLOW', 'DENY',
    ...upd(ADMIN, group({ restrictedUntil: { [OWNER]: until } }))],
  ['OK      the owner restricts an admin (owner branch)', 'ALLOW', 'ALLOW', ...upd(OWNER, restricted(LIMITED, ['sendText']))],
  ['GUARD   admin without the restrict right restricts a member', 'DENY', 'DENY',
    ...upd(LIMITED, restricted(ME, ['sendText']))],
  ['GUARD   a member restricts another member', 'DENY', 'DENY', ...upd(ME, restricted(ADMIN, ['sendText']))],
  ['OK      admin removes and bans a member (Fully ban)', 'ALLOW', 'ALLOW',
    ...upd(ADMIN, group({ users: [OWNER, ADMIN, LIMITED], bannedUids: [ME],
      lastMessage: 'x removed y', lastSender: ADMIN,
      restrictedFlags: {}, restrictedUntil: {} }), restricted(ME, ['sendText']))],
  ['OK      plain link card, nobody restricted', 'ALLOW', 'ALLOW', ...send(link)],
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
