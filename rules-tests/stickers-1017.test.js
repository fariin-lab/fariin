// 2026-10-17 chat stickers (owner), fenced. Run against the rules BEFORE and AFTER the change; a row
// that names a hole is only closed when it FLIPS, and every OK row must pass on both sides except the
// ones that are new on purpose (a `sticker` message did not exist before).
//
//   git show HEAD:firestore.rules > old.rules
//   node stickers-1017.test.js old.rules ../firestore.rules
//
// resource.data is PLAIN JSON here, not Firestore typed values — see README, trap 1.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node stickers-1017.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const ME = 'uidMember', ADMIN = 'uidAdmin', THIRD = 'uidThird';
const CID = 'grp1';
const REQ_TIME = new Date().toISOString();
const now = Date.parse(REQ_TIME);

const group = {
  users: [ME, ADMIN, THIRD], type: 'group', admins: [ADMIN], createdBy: ADMIN, title: 'Family',
  onlyAdminsSend: false, pinnedMessageIds: [], blockedBy: {}, mutedBy: {}, clearedAt: {},
  lastRead: {}, pinnedBy: {}, archivedBy: {}, names: {}, photos: {}, posters: {},
  unreadCount: { [ME]: 0, [ADMIN]: 0, [THIRD]: 0 }, lastMessage: 'hi', lastSender: ADMIN,
};

const notAdmin = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
]);
const convGet = (data) => ([
  { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data } } },
]);
const m = [ME, ADMIN, THIRD].flatMap(notAdmin);
const convPath = `${D}/conversations/${CID}`;
const until = now + 3600e3;
const restricted = (flags) => ({ ...group, restrictedFlags: { [ME]: flags }, restrictedUntil: { [ME]: until } });
const send = (data, flags = []) => [ME, `${convPath}/messages/m9`, 'create',
  { authorId: ME, createdAt: REQ_TIME, text: '', ...data }, null,
  [...m, ...convGet(flags.length ? restricted(flags) : group)]];

const bundled = { type: 'sticker', stickerPack: 'noto-faces', stickerId: 'joy', emoji: '😂', animated: true,
  width: 512, height: 512, imageUrl: 'https://fonts.gstatic.com/s/e/notoemoji/latest/1f602/512.webp' };
const mine = { type: 'sticker', stickerPack: 'mine', stickerId: 'A1B2C3', emoji: '🙂', animated: false,
  width: 400, height: 512, imageUrl: 'https://firebasestorage.googleapis.com/v0/b/x/o/chat%2Fgrp1%2Fm9.enc',
  enc: { k: 'wrapped', n: 'nonce' } };

// [name, before, after, caller, path, method, newData, oldData, mocks]
const cases = [
  ['OK      a built-in sticker', 'ALLOW', 'ALLOW', ...send(bundled)],
  ['OK      a sticker I made (encrypted, like a photo)', 'ALLOW', 'ALLOW', ...send(mine)],
  ['OK      a sticker with no emoji and no animated flag', 'ALLOW', 'ALLOW',
    ...send({ type: 'sticker', stickerPack: 'noto-faces', stickerId: 'joy' })],
  ['OK      a GIF is still a GIF', 'ALLOW', 'ALLOW',
    ...send({ type: 'gif', imageUrl: 'https://media.giphy.com/x.gif', width: 200, height: 200 })],
  ['OK      a plain text message', 'ALLOW', 'ALLOW', ...send({ text: 'enc1:x' })],
  ['OK      media-restricted member still sends a sticker', 'ALLOW', 'ALLOW', ...send(bundled, ['sendMedia'])],
  ['ATTACK  sticker-restricted member sends a sticker', 'ALLOW', 'DENY', ...send(bundled, ['sendStickers'])],
  ['GUARD   sticker-restricted member sends a GIF', 'DENY', 'DENY',
    ...send({ type: 'gif', imageUrl: 'https://media.giphy.com/x.gif' }, ['sendStickers'])],
  ['ATTACK  a sticker with no stickerId', 'ALLOW', 'DENY',
    ...send({ type: 'sticker', stickerPack: 'noto-faces', emoji: '😂' })],
  ['ATTACK  a sticker whose pack is a 1 KB string', 'ALLOW', 'DENY',
    ...send({ ...bundled, stickerPack: 'p'.repeat(1024) })],
  ['ATTACK  a sticker whose emoji is a paragraph', 'ALLOW', 'DENY',
    ...send({ ...bundled, emoji: 'x'.repeat(200) })],
  ['ATTACK  a sticker whose animated flag is a string', 'ALLOW', 'DENY',
    ...send({ ...bundled, animated: 'yes' })],
  ['ATTACK  sticker fields smuggled onto a text message', 'ALLOW', 'DENY',
    ...send({ text: 'enc1:x', stickerPack: 'noto-faces', stickerId: 'joy' })],
  ['GUARD   a sticker with a non-https address', 'DENY', 'DENY',
    ...send({ ...bundled, imageUrl: 'http://evil/x.webp' })],
];

async function run(t, source, [, , , uid, path, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  // Production answers "not blocked" / "no such doc" for the lookups these rows do not care about.
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
