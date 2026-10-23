// 2026-10-23 (owner, build 1014): THE LINK CARD FOLLOWS THE TEXT. A text holding a link is written
// at once; its author adds `linkPreview` in one later update (ChatService.attachLinkPreview): once,
// alone, within 2 minutes, on their own live text with no card, under the card's create checks
// (shape, the group's links switch, a muted member's sendLinks, a suspended group). Never on a 1:1
// request still waiting for its answer, unless that chat started with requests off (`reqOff`).
// Each row runs against the rules BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   git show HEAD:firestore.rules > before-link-late.rules
//   node link-late-1023.test.js before-link-late.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node link-late-1023.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const A = 'uidAaa', B = 'uidBbb', OWNER = 'uidOwner';
const DM = `${A}_${B}`, GID = 'grpLate1';
const NOW = Date.now();
const REQ_TIME = new Date(NOW).toISOString();
const SENT = new Date(NOW - 20 * 1000).toISOString();          // 20 s ago
const OLD = new Date(NOW - 3 * 60 * 1000).toISOString();        // 3 min ago
const dmPath = `${D}/conversations/${DM}`, gPath = `${D}/conversations/${GID}`;
const dmMsg = `${dmPath}/messages/c1`, gMsg = `${gPath}/messages/c2`;

const dm = (over = {}) => ({
  type: 'direct', users: [A, B], startedBy: A, accepted: true, lastSender: A,
  unreadCount: { [A]: 0, [B]: 1 }, updatedAt: REQ_TIME, ...over,
});
const group = (over = {}) => ({
  type: 'group', e2ee: false, title: 'Juni', users: [OWNER, A, B], admins: [OWNER], createdBy: OWNER,
  names: { [OWNER]: OWNER, [A]: A, [B]: B }, unreadCount: { [OWNER]: 0, [A]: 0, [B]: 0 },
  updatedAt: REQ_TIME, ...over,
});
const mocks = (p, data) => ([
  { function: 'get', args: [{ exactValue: p }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: p }], result: { value: true } },
]);
const LP = { url: 'enc1:u', title: 'enc1:t', desc: 'enc1:d',
  imageUrl: 'https://firebasestorage.googleapis.com/v0/b/x/o/chat%2Fc1-lp.enc?alt=media', imageEnc: { k: 'v' } };
const text = (over = {}) => ({ authorId: A, text: 'enc1:abc', createdAt: SENT, clientTs: NOW, clientId: 'c1', ...over });
const gtext = (over = {}) => text({ text: 'look https://fariin.com/juni', clientId: 'c2', ...over });
const card = (m, lp = LP) => ({ ...m, linkPreview: lp });
const STK = (over = {}) => ({ authorId: A, type: 'sticker', stickerPack: 'mine', stickerId: 'abc', animated: false,
  width: 512, height: 512, text: 'fariin-sticker:1', createdAt: REQ_TIME, clientTs: NOW, clientId: 'c2', uploading: true, ...over });
const muted = group({ restrictedFlags: { [A]: ['sendLinks'] }, restrictedUntil: { [A]: NOW + 3600 * 1000 } });

// [name, before, after, uid, path, method, newData, oldData, mocks]
const cases = [
  ['OK      the author adds the card (1:1)', 'DENY', 'ALLOW', A, dmMsg, 'update', card(text()), text(), mocks(dmPath, dm())],
  ['OK      the author adds the card (group)', 'DENY', 'ALLOW', A, gMsg, 'update', card(gtext()), gtext(), mocks(gPath, group())],
  ['OK      a chat begun with requests off', 'DENY', 'ALLOW', A, dmMsg, 'update', card(text()), text(),
    mocks(dmPath, dm({ accepted: false, reqOff: true }))],
  ['OK      a chat from before requests', 'DENY', 'ALLOW', A, dmMsg, 'update', card(text()), text(),
    mocks(dmPath, dm({ startedBy: '', accepted: false }))],
  ['GUARD   someone else adds it', 'DENY', 'DENY', B, dmMsg, 'update', card(text()), text(), mocks(dmPath, dm())],
  ['GUARD   a second card', 'DENY', 'DENY', A, dmMsg, 'update', card(text(), { url: 'enc1:z' }), card(text()), mocks(dmPath, dm())],
  ['GUARD   the card with the text changed', 'DENY', 'DENY', A, dmMsg, 'update',
    card(text({ text: 'enc1:other' })), text(), mocks(dmPath, dm())],
  ['GUARD   the card with another key', 'DENY', 'DENY', A, dmMsg, 'update',
    card(text({ forwarded: true })), text(), mocks(dmPath, dm())],
  ['GUARD   after the 2 minutes', 'DENY', 'DENY', A, dmMsg, 'update', card(text({ createdAt: OLD })), text({ createdAt: OLD }), mocks(dmPath, dm())],
  ['GUARD   a card of the wrong shape', 'DENY', 'DENY', A, dmMsg, 'update', card(text(), { ...LP, extra: 'x' }), text(), mocks(dmPath, dm())],
  ['GUARD   a card with an http image', 'DENY', 'DENY', A, dmMsg, 'update', card(text(), { ...LP, imageUrl: 'http://x/y' }), text(), mocks(dmPath, dm())],
  ['GUARD   on a deleted message', 'DENY', 'DENY', A, dmMsg, 'update',
    card(text({ deleted: true, text: '', type: 'text' })), text({ deleted: true, text: '', type: 'text' }), mocks(dmPath, dm())],
  ['GUARD   on a photo', 'DENY', 'DENY', A, dmMsg, 'update', card(text({ type: 'image' })), text({ type: 'image' }), mocks(dmPath, dm())],
  ['GUARD   a request still waiting', 'DENY', 'DENY', A, dmMsg, 'update', card(text()), text(),
    mocks(dmPath, dm({ accepted: false }))],
  ['GUARD   a member muted for links', 'DENY', 'DENY', A, gMsg, 'update', card(gtext()), gtext(), mocks(gPath, muted)],
  ['GUARD   the group turned links off', 'DENY', 'DENY', A, gMsg, 'update', card(gtext()), gtext(),
    mocks(gPath, group({ memberSend: { links: false } }))],
  ['GUARD   a suspended group', 'DENY', 'DENY', A, gMsg, 'update', card(gtext()), gtext(),
    mocks(gPath, group({ mod: { state: 'suspended' } }))],
  ['GUARD   an outsider', 'DENY', 'DENY', 'uidOut', gMsg, 'update', card(gtext()), gtext(), mocks(gPath, group())],
  // Canaries: the branches next to it still answer as before.
  ['CANARY  a reaction', 'ALLOW', 'ALLOW', B, dmMsg, 'update', text({ reactions: { [B]: 'enc1:r' } }), text(), mocks(dmPath, dm())],
  ['CANARY  the author edits the text', 'ALLOW', 'ALLOW', A, dmMsg, 'update',
    text({ text: 'enc1:new', edited: true, editedAt: REQ_TIME }), text(), mocks(dmPath, dm())],
  ['CANARY  a text sent WITH its card', 'ALLOW', 'ALLOW', A, dmMsg, 'create', card(text({ createdAt: REQ_TIME })), null, mocks(dmPath, dm())],
  // The same day's sticker fix (StickerSend.write): one I made is written at once with
  // `uploading: true` and no file, then the file is attached by the existing upload branch.
  ['CANARY  a sticker of mine, file to follow', 'ALLOW', 'ALLOW', A, gMsg, 'create', STK(), null, mocks(gPath, group())],
  ['CANARY  its file attached', 'ALLOW', 'ALLOW', A, gMsg, 'update',
    STK({ uploading: false, imageUrl: LP.imageUrl, enc: { k: 'v' } }), STK(), mocks(gPath, group())],
  ['GUARD   someone else attaches it', 'DENY', 'DENY', B, gMsg, 'update',
    STK({ uploading: false, imageUrl: LP.imageUrl, enc: { k: 'v' } }), STK(), mocks(gPath, group())],
];

async function run(t, source, [, , , uid, p, method, after, before, mx], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: [...(mx || []), { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
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
  return { state: (res && res.state) || 'NORESULT', detail: ((res && res.debugMessages) || []).join(' | ').slice(0, 300)
    + (res && res.errorPosition ? ` (line ${res.errorPosition.line})` : '') };
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
