// Message requests + Chat PIN rules (owner's spec, 2026-09-11), each case run against BOTH the rules
// before the change and the rules after it.
//
// A security row is only proved when it FLIPS (allowed before, denied after — or the reverse where a
// door is being opened on purpose, like Remove Friend and the decline ledger). A feature row must
// pass on BOTH files, or the change broke the app instead of closing the hole. A DENY suite that
// passes on its own proves nothing; rules that deny everything pass it perfectly.
//
//   node message-requests.test.js                       # before-pin.rules vs ../firestore.rules
//   node message-requests.test.js <before> <after>
//
// Nothing is deployed and nothing is written; this only asks Google's engine what it would do.
// resource.data is PLAIN JSON, never typed values — README, trap 1. Timestamps are ISO strings.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2] || 'before-pin.rules';
const AFTER = process.argv[3] || '../firestore.rules';

const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the stranger who knocks
const B = 'uidBBB';   // the person being asked
const CID = [A, B].sort().join('_');

const REQ_TIME = new Date().toISOString();
const now = Date.parse(REQ_TIME);
const iso = (ms) => new Date(ms).toISOString();
const DAY = 24 * 3600e3;

// ── documents ──
const base = { users: [A, B], type: '', names: {}, photos: {}, blockedBy: {}, mutedBy: {},
               clearedAt: {}, lastRead: {}, unreadCount: {}, archivedBy: {}, pinnedBy: {} };
const fresh = { ...base, startedBy: A, accepted: false, lastSender: '' };   // A may knock once
const spent = { ...fresh, lastSender: A };                                   // A has knocked
const open = { ...base, startedBy: A, accepted: true, lastSender: B };       // friends
const legacy = { ...base };                                                  // before requests existed

// 150 emoji seal to 862 characters; an ordinary short message to far less.
const shortCipher = 'enc1:' + 'x'.repeat(120);
const maxCipher = 'enc1:' + 'x'.repeat(875);
const longCipher = 'enc1:' + 'x'.repeat(2000);

// ── mocks ──
const userDoc = (uid, messages = 'everyone') => ([
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }],
    result: { value: { data: { banned: false, privacy: { messages } } } } },
]);
const notAdmin = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
]);
const convDoc = (data) => ([
  { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data } } },
]);
const noConv = [
  { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: false } },
];
const declinePath = `${D}/requestDeclines/${B}/from/${A}`;
const neverDeclined = [
  { function: 'exists', args: [{ exactValue: declinePath }], result: { value: false } },
];
const declinedAt = (ms) => ([
  { function: 'exists', args: [{ exactValue: declinePath }], result: { value: true } },
  { function: 'get', args: [{ exactValue: declinePath }], result: { value: { data: { at: iso(ms) } } } },
]);

// The day's-knocks counter (spec §25) and the config it reads its ceiling from.
const budgetPath = `${D}/users/${A}/limits/requests`;
const noBudget = [
  { function: 'exists', args: [{ exactValue: budgetPath }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: false } },
];
const budget = (count, startMs) => ([
  { function: 'exists', args: [{ exactValue: budgetPath }], result: { value: true } },
  { function: 'get', args: [{ exactValue: budgetPath }],
    result: { value: { data: { windowStart: iso(startMs), count } } } },
  { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: false } },
]);

const msgPath = `${D}/conversations/${CID}/messages/m1`;
const convPath = `${D}/conversations/${CID}`;
const knockMocks = (conv, privacy = 'everyone', counter = noBudget) =>
  [...convDoc(conv), ...userDoc(A), ...userDoc(B, privacy), ...notAdmin(A), ...notAdmin(B), ...counter];

// [name, expect BEFORE, expect AFTER, uid, path, method, after-data, before-data, mocks]
const cases = [
  // ── 1. a request is one short text ──
  ['OK      the one short text a request is allowed',
    'ALLOW', 'ALLOW', A, msgPath, 'create', { authorId: A, text: shortCipher }, null, knockMocks(fresh)],
  ['OK      the longest text 150 characters can seal to',
    'ALLOW', 'ALLOW', A, msgPath, 'create', { authorId: A, text: maxCipher }, null, knockMocks(fresh)],
  ['ATTACK  a photo as the request',
    'ALLOW', 'DENY', A, msgPath, 'create',
    { authorId: A, text: shortCipher, type: 'image', imageUrl: 'https://x/y.jpg', width: 100, height: 100 }, null,
    knockMocks(fresh)],
  ['ATTACK  a voice note as the request',
    'ALLOW', 'DENY', A, msgPath, 'create',
    { authorId: A, text: shortCipher, type: 'audio', audioUrl: 'https://x/y.m4a', duration: 3, waveform: [1, 2] }, null,
    knockMocks(fresh)],
  ['ATTACK  a file as the request',
    'ALLOW', 'DENY', A, msgPath, 'create',
    { authorId: A, text: shortCipher, type: 'file', fileUrl: 'https://x/y.pdf', fileName: 'y.pdf', fileSize: 10 }, null,
    knockMocks(fresh)],
  ['ATTACK  an album as the request',
    'ALLOW', 'DENY', A, msgPath, 'create',
    { authorId: A, text: shortCipher, album: [{ url: 'https://x/1.jpg' }] }, null, knockMocks(fresh)],
  ['ATTACK  a link card as the request',
    'ALLOW', 'DENY', A, msgPath, 'create',
    { authorId: A, text: shortCipher, linkPreview: { url: 'https://x', title: 't' } }, null, knockMocks(fresh)],
  ['ATTACK  a 2000-character essay as the request',
    'ALLOW', 'DENY', A, msgPath, 'create', { authorId: A, text: longCipher }, null, knockMocks(fresh)],
  ['ATTACK  knock on a My Friends account that just removed me',
    'ALLOW', 'DENY', A, msgPath, 'create', { authorId: A, text: shortCipher }, null,
    knockMocks(fresh, 'contacts')],
  ['DENY    the requester\'s SECOND message while unanswered',
    'DENY', 'DENY', A, msgPath, 'create', { authorId: A, text: shortCipher }, null, knockMocks(spent)],

  // ── the outage guards: ordinary chats must not feel any of this ──
  ['OK      the recipient answers the request',
    'ALLOW', 'ALLOW', B, msgPath, 'create', { authorId: B, text: shortCipher }, null, knockMocks(spent)],
  ['OK      a photo into an accepted chat',
    'ALLOW', 'ALLOW', A, msgPath, 'create',
    { authorId: A, text: shortCipher, type: 'image', imageUrl: 'https://x/y.jpg' }, null, knockMocks(open)],
  ['OK      a long text into an accepted chat',
    'ALLOW', 'ALLOW', A, msgPath, 'create', { authorId: A, text: longCipher }, null, knockMocks(open)],
  ['OK      a photo into a chat from before requests existed',
    'ALLOW', 'ALLOW', A, msgPath, 'create',
    { authorId: A, text: shortCipher, type: 'image', imageUrl: 'https://x/y.jpg' }, null, knockMocks(legacy)],

  // ── 2. a declined request is remembered for a week ──
  ['OK      open a new chat, never declined',
    'ALLOW', 'ALLOW', A, convPath, 'create', { ...fresh, updatedAt: REQ_TIME }, null,
    [...noConv, ...userDoc(A), ...userDoc(B), ...notAdmin(A), ...neverDeclined]],
  ['ATTACK  open a new chat one day after being declined',
    'ALLOW', 'DENY', A, convPath, 'create', { ...fresh, updatedAt: REQ_TIME }, null,
    [...noConv, ...userDoc(A), ...userDoc(B), ...notAdmin(A), ...declinedAt(now - DAY)]],
  ['OK      open a new chat eight days after being declined',
    'ALLOW', 'ALLOW', A, convPath, 'create', { ...fresh, updatedAt: REQ_TIME }, null,
    [...noConv, ...userDoc(A), ...userDoc(B), ...notAdmin(A), ...declinedAt(now - 8 * DAY)]],
  ['OK      B records that they declined A',
    'DENY', 'ALLOW', B, declinePath, 'create', { at: REQ_TIME }, null, [...notAdmin(B)]],
  ['ATTACK  A records a decline in B\'s name',
    'DENY', 'DENY', A, declinePath, 'create', { at: REQ_TIME }, null, [...notAdmin(A)]],
  ['ATTACK  A reads whether B declined them',
    'DENY', 'DENY', A, declinePath, 'get', null, { at: REQ_TIME }, [...notAdmin(A)]],
  ['ATTACK  B dates the decline a year ahead',
    'DENY', 'DENY', B, declinePath, 'create', { at: iso(now + 365 * DAY) }, null, [...notAdmin(B)]],
  ['OK      B lifts their decline early',
    'DENY', 'ALLOW', B, declinePath, 'delete', null, { at: REQ_TIME }, [...notAdmin(B)]],

  // ── 3. remove friend: the one way back through the one-way door ──
  ['OK      B removes A from friends',
    'DENY', 'ALLOW', B, convPath, 'update',
    { ...open, accepted: false, startedBy: A, lastSender: '', unfriendedBy: B, unfriendedAt: REQ_TIME }, open,
    [...userDoc(B), ...notAdmin(B)]],
  ['OK      B removes A from a chat older than requests',
    'ALLOW', 'ALLOW', B, convPath, 'update',
    { ...legacy, accepted: false, startedBy: A, lastSender: '', unfriendedBy: B, unfriendedAt: REQ_TIME }, legacy,
    [...userDoc(B), ...notAdmin(B)]],
  ['ATTACK  A resets their own spent request',
    'DENY', 'DENY', A, convPath, 'update',
    { ...spent, accepted: false, startedBy: B, lastSender: '' }, spent, [...userDoc(A), ...notAdmin(A)]],
  ['ATTACK  B removes A but names themselves the requester',
    'DENY', 'DENY', B, convPath, 'update',
    { ...open, accepted: false, startedBy: B, lastSender: '' }, open, [...userDoc(B), ...notAdmin(B)]],
  ['ATTACK  B removes A and rewrites something else in the same write',
    'DENY', 'DENY', B, convPath, 'update',
    { ...open, accepted: false, startedBy: A, lastSender: '', lastMessage: 'enc1:zzz' }, open,
    [...userDoc(B), ...notAdmin(B)]],
  ['ATTACK  A accepts their own request',
    'DENY', 'DENY', A, convPath, 'update', { ...spent, accepted: true }, spent, [...userDoc(A), ...notAdmin(A)]],

  // ── 3b. a day's knocks (§25). The counter is the app's; a missing one fails open by design ──
  ['OK      the tenth knock of the day',
    'ALLOW', 'ALLOW', A, msgPath, 'create', { authorId: A, text: shortCipher }, null,
    knockMocks(fresh, 'everyone', budget(9, now - 3600e3))],
  ['ATTACK  the twenty-first knock of the day',
    'ALLOW', 'DENY', A, msgPath, 'create', { authorId: A, text: shortCipher }, null,
    knockMocks(fresh, 'everyone', budget(20, now - 3600e3))],
  ['OK      twenty knocks yesterday, a fresh day',
    'ALLOW', 'ALLOW', A, msgPath, 'create', { authorId: A, text: shortCipher }, null,
    knockMocks(fresh, 'everyone', budget(20, now - 25 * 3600e3))],
  ['OK      an accepted chat never touches the counter',
    'ALLOW', 'ALLOW', A, msgPath, 'create', { authorId: A, text: shortCipher }, null,
    knockMocks(open, 'everyone', budget(20, now - 3600e3))],

  // ── 3c. only the person who was asked may delete the request (§14, §28) ──
  ['OK      B deletes A\'s request',
    'ALLOW', 'ALLOW', B, convPath, 'delete', null, spent, [...userDoc(B), ...notAdmin(B)]],
  ['ATTACK  A deletes their own request, to knock again fresh or shed a block',
    'ALLOW', 'DENY', A, convPath, 'delete', null, spent, [...userDoc(A), ...notAdmin(A)]],

  // ── 4. the pin documents are nobody's ──
  ['ATTACK  read somebody\'s pin hash',
    'DENY', 'DENY', A, `${D}/chatPins/${B}`, 'get', null, { hash: 'h', salt: 's' }, [...notAdmin(A)]],
  ['ATTACK  write my own pin hash directly',
    'DENY', 'DENY', A, `${D}/chatPins/${A}`, 'create', { hash: 'h', salt: 's' }, null, [...notAdmin(A)]],
  ['ATTACK  reset my own attempt counter',
    'DENY', 'DENY', A, `${D}/pinAttempts/${A}`, 'delete', null, { count: 5 }, [...notAdmin(A)]],
];

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
  for (const c of cases) {
    const [name, expBefore, expAfter] = c;
    const o = await run(t, before, c, expBefore);
    const n = await run(t, after, c, expAfter);
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${expBefore.padEnd(5)}→${expAfter.padEnd(5)}  ${name}`);
    if (!ok) {
      if (o.state !== 'SUCCESS') console.log(`        BEFORE was not ${expBefore}: ${o.state} ${o.detail}`);
      if (n.state !== 'SUCCESS') console.log(`        AFTER  was not ${expAfter}: ${n.state} ${n.detail}`);
    }
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
