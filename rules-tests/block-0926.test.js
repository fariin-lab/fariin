// 2026-09-26 block rebuild: every place the rules now enforce a block, run against the rules BEFORE
// the change and AFTER it. A hole is only closed when its row FLIPS; every OK row must pass on both.
// README: plain JSON, mock every get()/exists() the rules can reach.
//
//   node block-0926.test.js before-block.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node block-0926.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const A = 'uidBlocker', B = 'uidBlocked', C = 'uidStranger';
const REQ_TIME = new Date().toISOString();
const now = Date.parse(REQ_TIME);
const iso = (ms) => new Date(ms).toISOString();
const pair = (x, y) => [x, y].sort().join('_');

// ── mocks ──
const ex = (path, value) => ({ function: 'exists', args: [{ exactValue: `${D}/${path}` }], result: { value } });
const gt = (path, data) => ({ function: 'get', args: [{ exactValue: `${D}/${path}` }], result: { value: { data } } });
const notAdmin = (uid) => [ex(`admins/${uid}`, false)];
// `owner` has (or has not) blocked `reader`: on the account list, and/or on the chat the two share.
const blockMocks = (owner, reader, { listed = false, chat = null } = {}) => [
  ex(`users/${owner}/blocked/${reader}`, listed),
  ex(`conversations/${pair(owner, reader)}`, chat !== null),
  ...(chat !== null ? [gt(`conversations/${pair(owner, reader)}`, { users: [owner, reader], ...chat })] : []),
];
const userDoc = (uid, lastSeen) => gt(`users/${uid}`, { privacy: { lastSeen } });

// ── documents ──
const story = (over = {}) => ({ authorUid: A, recipientUids: [B], public: false, allowsReplies: true, ...over });

function cases() {
  const presence = `${D}/users/${A}/presence/state`;
  const pub = `${D}/users/${A}/publicStories/s1`;
  const st = `${D}/stories/s1`;
  const view = `${D}/stories/s1/views/${B}`;
  const listDoc = `${D}/users/${A}/blocked/${B}`;
  const span = (id) => `${D}/users/${A}/blockHistory/${id}`;
  return [
    // ── presence: a block hides last seen whatever the setting says ──
    ['OK      Everyone, not blocked, no chat', 'ALLOW', 'ALLOW', B, presence, 'get', null, { online: true },
      [...notAdmin(B), userDoc(A, 'everyone'), ...blockMocks(A, B)]],
    ['HOLE    Everyone, blocked on the account list with no chat', 'ALLOW', 'DENY', B, presence, 'get', null, { online: true },
      [...notAdmin(B), userDoc(A, 'everyone'), ...blockMocks(A, B, { listed: true })]],
    ['HOLE    Everyone, blocked on the old chat copy', 'ALLOW', 'DENY', B, presence, 'get', null, { online: true },
      [...notAdmin(B), userDoc(A, 'everyone'), ...blockMocks(A, B, { chat: { blockedBy: { [A]: true } } })]],
    ['OK      My Chats, chat, not blocked', 'ALLOW', 'ALLOW', B, presence, 'get', null, { online: true },
      [...notAdmin(B), userDoc(A, 'contacts'), ...blockMocks(A, B, { chat: { blockedBy: {} } })]],
    ['HOLE    My Chats, chat, blocked on the account list only', 'ALLOW', 'DENY', B, presence, 'get', null, { online: true },
      [...notAdmin(B), userDoc(A, 'contacts'), ...blockMocks(A, B, { listed: true, chat: { blockedBy: {} } })]],
    ['GUARD   My Chats, chat, blocked on the old chat copy', 'DENY', 'DENY', B, presence, 'get', null, { online: true },
      [...notAdmin(B), userDoc(A, 'contacts'), ...blockMocks(A, B, { chat: { blockedBy: { [A]: true } } })]],
    ['GUARD   My Chats, stranger with no chat', 'DENY', 'DENY', C, presence, 'get', null, { online: true },
      [...notAdmin(C), userDoc(A, 'contacts'), ...blockMocks(A, C)]],
    ['GUARD   No One, chat partner', 'DENY', 'DENY', B, presence, 'get', null, { online: true },
      [...notAdmin(B), userDoc(A, 'nobody'), ...blockMocks(A, B, { chat: { blockedBy: {} } })]],
    ['OK      the owner reads their own', 'ALLOW', 'ALLOW', A, presence, 'get', null, { online: true },
      [...notAdmin(A), userDoc(A, 'nobody')]],

    // ── public stories on the profile ──
    ['OK      stranger with no chat reads a public story', 'ALLOW', 'ALLOW', C, pub, 'get', null, { mediaUrl: 'x' },
      [...notAdmin(C), ...blockMocks(A, C)]],
    ['HOLE    blocked with no chat reads a public story', 'ALLOW', 'DENY', B, pub, 'get', null, { mediaUrl: 'x' },
      [...notAdmin(B), ...blockMocks(A, B, { listed: true })]],
    ['GUARD   blocked on the old chat copy reads a public story', 'DENY', 'DENY', B, pub, 'get', null, { mediaUrl: 'x' },
      [...notAdmin(B), ...blockMocks(A, B, { chat: { blockedBy: { [A]: true } } })]],
    ['OK      blocked person lists the profile\'s stories? no: list is refused too', 'ALLOW', 'DENY', B, pub, 'list', null, { mediaUrl: 'x' },
      [...notAdmin(B), ...blockMocks(A, B, { listed: true })]],

    // ── the story document itself ──
    ['OK      audience member fetches a story', 'ALLOW', 'ALLOW', B, st, 'get', null, story(),
      [...notAdmin(B), ...blockMocks(A, B)]],
    ['HOLE    blocked person still in the audience fetches it', 'ALLOW', 'DENY', B, st, 'get', null, story(),
      [...notAdmin(B), ...blockMocks(A, B, { listed: true })]],
    ['OK      the author fetches their own', 'ALLOW', 'ALLOW', A, st, 'get', null, story(), [...notAdmin(A)]],
    ['GUARD   outsider fetches it', 'DENY', 'DENY', C, st, 'get', null, story(), [...notAdmin(C), ...blockMocks(A, C)]],
    ['OK      tray query row, audience member (list unchanged)', 'ALLOW', 'ALLOW', B, st, 'list', null, story(),
      [...notAdmin(B)]],

    // ── view receipts and reactions ──
    ['OK      audience member records a view', 'ALLOW', 'ALLOW', B, view, 'create', { viewedAt: REQ_TIME }, null,
      [...notAdmin(B), gt('stories/s1', story()), ...blockMocks(A, B)]],
    ['HOLE    blocked person lands in Seen-by', 'ALLOW', 'DENY', B, view, 'create', { viewedAt: REQ_TIME }, null,
      [...notAdmin(B), gt('stories/s1', story()), ...blockMocks(A, B, { listed: true })]],
    ['HOLE    blocked person lands in Seen-by on a public story', 'ALLOW', 'DENY', B, view, 'create', { viewedAt: REQ_TIME }, null,
      [...notAdmin(B), gt('stories/s1', story({ recipientUids: [], public: true })), ...blockMocks(A, B, { listed: true })]],
    ['OK      audience member reacts', 'ALLOW', 'ALLOW', B, view, 'update', { viewedAt: REQ_TIME, reaction: 'x' }, { viewedAt: REQ_TIME },
      [...notAdmin(B), gt('stories/s1', story()), ...blockMocks(A, B)]],
    ['HOLE    blocked person reacts to an old view', 'ALLOW', 'DENY', B, view, 'update', { viewedAt: REQ_TIME, reaction: 'x' }, { viewedAt: REQ_TIME },
      [...notAdmin(B), gt('stories/s1', story()), ...blockMocks(A, B, { listed: true })]],

    // ── the block list itself ──
    ['OK      owner blocks now', 'ALLOW', 'ALLOW', A, listDoc, 'create', { at: REQ_TIME }, null, notAdmin(A)],
    ['NEW     owner moves an old chat block over with its original time', 'DENY', 'ALLOW', A, listDoc, 'create',
      { at: iso(now - 86400e3) }, null, notAdmin(A)],
    ['GUARD   owner dates a block in the future', 'DENY', 'DENY', A, listDoc, 'create', { at: iso(now + 86400e3) }, null, notAdmin(A)],
    ['GUARD   owner adds a stray field', 'DENY', 'DENY', A, listDoc, 'create', { at: REQ_TIME, x: 1 }, null, notAdmin(A)],
    ['GUARD   the blocked person reads the list entry', 'DENY', 'DENY', B, listDoc, 'get', null, { at: REQ_TIME }, notAdmin(B)],
    ['GUARD   the blocked person deletes it', 'DENY', 'DENY', B, listDoc, 'delete', null, { at: REQ_TIME }, notAdmin(B)],
    ['GUARD   someone writes into another person\'s list', 'DENY', 'DENY', C, listDoc, 'create', { at: REQ_TIME }, null, notAdmin(C)],
    ['OK      owner unblocks', 'ALLOW', 'ALLOW', A, listDoc, 'delete', null, { at: REQ_TIME }, notAdmin(A)],

    // ── past blocks ──
    ['NEW     owner records an ended block', 'DENY', 'ALLOW', A, span(`${B}_123`), 'create',
      { other: B, from: iso(now - 3600e3), to: REQ_TIME }, null, notAdmin(A)],
    ['GUARD   id does not match the person', 'DENY', 'DENY', A, span(`${C}_123`), 'create',
      { other: B, from: iso(now - 3600e3), to: REQ_TIME }, null, notAdmin(A)],
    ['GUARD   ends in the future', 'DENY', 'DENY', A, span(`${B}_123`), 'create',
      { other: B, from: iso(now - 3600e3), to: iso(now + 3600e3) }, null, notAdmin(A)],
    ['GUARD   ends before it starts', 'DENY', 'DENY', A, span(`${B}_123`), 'create',
      { other: B, from: REQ_TIME, to: iso(now - 3600e3) }, null, notAdmin(A)],
    ['GUARD   stray field', 'DENY', 'DENY', A, span(`${B}_123`), 'create',
      { other: B, from: iso(now - 3600e3), to: REQ_TIME, x: 1 }, null, notAdmin(A)],
    ['GUARD   edited after the fact', 'DENY', 'DENY', A, span(`${B}_123`), 'update',
      { other: B, from: iso(now - 7200e3), to: REQ_TIME }, { other: B, from: iso(now - 3600e3), to: REQ_TIME }, notAdmin(A)],
    ['GUARD   the blocked person reads it', 'DENY', 'DENY', B, span(`${B}_123`), 'get', null,
      { other: B, from: iso(now - 3600e3), to: REQ_TIME }, notAdmin(B)],
    ['OK      owner reads it', 'DENY', 'ALLOW', A, span(`${B}_123`), 'get', null,
      { other: B, from: iso(now - 3600e3), to: REQ_TIME }, notAdmin(A)],
  ];
}

async function run(t, source, [, , , uid, path, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: mocks };
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
  for (const c of cases()) {
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
