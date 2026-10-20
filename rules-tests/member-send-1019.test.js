// 2026-10-19 WHAT MEMBERS MAY SEND (memberSend: media, voice, files, stickers, links). Admins never limited.
// `e2ee == false` on the group document (server-written by the groupsE2eeOff migration, or `false`
// by the app at create) lets a group take text in the clear, capped at 65,536 characters. A group
// that has not switched still takes only sealed text on an ordinary message. `e2ee`/`e2eeOffAt` are
// the server's on every update branch. 1:1 chats untouched. Each row runs against the rules BEFORE
// the change and AFTER it. README: plain JSON, mock every get().
//
//   node group-e2ee-off-1019.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-e2ee-off-1019.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', MEMBER = 'uidMember';
const CID = 'grpE2ee1';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;
const msgPath = `${convPath}/messages/msgE2ee1`;
const newPath = `${D}/conversations/grpE2eeNew`;
const dmPath = `${D}/conversations/${MEMBER}_${OWNER}`;

const users = [OWNER, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER], createdBy: OWNER, createdAt: REQ_TIME,
  names: { [OWNER]: OWNER, [MEMBER]: MEMBER }, photos: {},
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME, ...over,
});
const SEALED = group();                       // never switched: still end-to-end encrypted
const PLAIN = group({ e2ee: false });          // switched by the server
const dm = (over = {}) => ({
  type: 'direct', users: [MEMBER, OWNER], accepted: true, startedBy: OWNER, lastSender: MEMBER,
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME, ...over,
});
const mocksFor = (p, data) => ([
  { function: 'get', args: [{ exactValue: p }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: p }], result: { value: true } },
]);
const convMocks = (data) => mocksFor(convPath, data);
const encg1 = 'encg1:' + Buffer.from(JSON.stringify({ n: 'AAAA', c: 'BBBB', w: { [OWNER]: 'x.y', [MEMBER]: 'x.y' } })).toString('base64');
const msg = (text, over = {}) => ({ authorId: MEMBER, text, createdAt: REQ_TIME, ...over });
const with_ = (base, over) => ({ ...base, ...over });

const cases = [
  ["OK      text in an open group", "ALLOW", "ALLOW", MEMBER, msgPath, "create", msg("hello"), null, convMocks(PLAIN)],
  ["OK      photo in an open group", "ALLOW", "ALLOW", MEMBER, msgPath, "create", msg("", { type: "image", imageUrl: "https://x.test/a", enc: { v: 0, n: "", k: "", kn: "" } }), null, convMocks(PLAIN)],
  ["FIX     photo with media off", "ALLOW", "DENY", MEMBER, msgPath, "create", msg("", { type: "image", imageUrl: "https://x.test/a", enc: { v: 0, n: "", k: "", kn: "" } }), null, convMocks(with_(PLAIN, { memberSend: { media: false } }))],
  ["OK      admin photo with media off", "ALLOW", "ALLOW", OWNER, msgPath, "create", msg("", { authorId: OWNER, type: "image", imageUrl: "https://x.test/a", enc: { v: 0, n: "", k: "", kn: "" } }), null, convMocks(with_(PLAIN, { memberSend: { media: false } }))],
  ["FIX     sticker with stickers off", "ALLOW", "DENY", MEMBER, msgPath, "create", msg("", { type: "sticker", stickerPack: "p", stickerId: "s" }), null, convMocks(with_(PLAIN, { memberSend: { stickers: false } }))],
  ["OK      sticker with only links off", "ALLOW", "ALLOW", MEMBER, msgPath, "create", msg("", { type: "sticker", stickerPack: "p", stickerId: "s" }), null, convMocks(with_(PLAIN, { memberSend: { links: false } }))],
  ["FIX     text with a link, links off", "ALLOW", "DENY", MEMBER, msgPath, "create", msg("see https://spam.test now"), null, convMocks(with_(PLAIN, { memberSend: { links: false } }))],
  ["FIX     text with WWW., links off", "ALLOW", "DENY", MEMBER, msgPath, "create", msg("WWW.spam.test"), null, convMocks(with_(PLAIN, { memberSend: { links: false } }))],
  ["OK      plain text, links off", "ALLOW", "ALLOW", MEMBER, msgPath, "create", msg("homework is page 4"), null, convMocks(with_(PLAIN, { memberSend: { links: false } }))],
  ["OK      text with a link, links on", "ALLOW", "ALLOW", MEMBER, msgPath, "create", msg("see https://ok.test"), null, convMocks(with_(PLAIN, { memberSend: { links: true } }))],
  ["OK      notice with everything off", "ALLOW", "ALLOW", MEMBER, msgPath, "create", msg("uidMember changed the group name", { type: "system" }), null, convMocks(with_(PLAIN, { membersCanEditInfo: true, memberSend: { media: false, voice: false, files: false, stickers: false, links: false } }))],
  ["OK      owner sets memberSend", "ALLOW", "ALLOW", OWNER, convPath, "update", with_(PLAIN, { memberSend: { stickers: false } }), PLAIN, convMocks(PLAIN)],
  ["GUARD   member sets memberSend", "DENY", "DENY", MEMBER, convPath, "update", with_(PLAIN, { memberSend: { stickers: true } }), with_(PLAIN, { memberSend: { stickers: false } }), convMocks(with_(PLAIN, { memberSend: { stickers: false } }))],
  ["GUARD   info-editing member sets memberSend", "DENY", "DENY", MEMBER, convPath, "update", with_(PLAIN, { membersCanEditInfo: true, memberSend: { stickers: false } }), with_(PLAIN, { membersCanEditInfo: true }), convMocks(with_(PLAIN, { membersCanEditInfo: true }))],
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
