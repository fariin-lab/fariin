// 2026-10-17 story view receipts per account (owner), fenced.
//
// Three rule changes: users/{uid}/private/storyPrefs (the switch), users/{uid}/hiddenStoryViews
// (what I watched while it was off), and `firstAt` on a view receipt (server-set, then frozen).
// The outage guard is the old-shape receipt update: an older build merges only viewedAt/reaction
// onto a receipt the server has already stamped with firstAt, and that must still pass.
//
//   git show HEAD:firestore.rules > old.rules
//   node story-receipts-1017.test.js old.rules
//   node story-receipts-1017.test.js
//
// resource.data is PLAIN JSON here, not Firestore typed values — see README, trap 1.
const fs = require('fs');
const crypto = require('crypto');
const { token } = require('./auth');

// Fallback answers for the block check: nobody in these cases has blocked anybody.
const NOT_BLOCKED = [
  { function: 'exists', args: [{ anyValue: {} }], result: { value: false } },
];

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';      // the story's author
const B = 'uidBBB';      // a recipient
const C = 'uidCCC';      // a stranger
const SID = 'story123';

const tok = (uid) =>
  crypto.createHash('sha256').update('fariin-audience-v1:' + uid).digest('hex').toLowerCase();

// ONE request.time for the run, every timestamp an ISO string (see story-hardening for why).
const REQ_TIME = new Date().toISOString();
const now = Date.parse(REQ_TIME);
const iso = (ms) => new Date(ms).toISOString();

const friendsStory = {
  authorUid: A,
  createdAt: iso(now - 3600e3),
  expiresAt: iso(now + 20 * 3600e3),
  recipientUids: [tok(B)],
  mediaPath: `stories/${SID}/photo.jpg`,
  type: 'image',
  caption: '',
  replyCount: 0,
  public: false,
  allowsReplies: true,
  audienceLabel: 'friends',
  oneTime: false,
};

const notBanned = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: { data: { banned: false } } } },
]);
const notAdmin = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
]);
const storyDoc = (data) => ([
  { function: 'exists', args: [{ exactValue: `${D}/stories/${SID}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/stories/${SID}` }], result: { value: { data } } },
]);
const who = (uid) => [...notBanned(uid), ...notAdmin(uid)];

const prefsOff = { receipts: false, offAt: REQ_TIME };
const prefsOn = { receipts: true, offAt: null };
const hidden = { storyId: SID, authorUid: A, at: REQ_TIME, expiresAt: iso(now + 20 * 3600e3) };
const stamped = { viewedAt: iso(now - 600e3), firstAt: iso(now - 600e3) };

// [name, expect, uid, path, method, after, before, mocks]
const cases = [
  // ---- 1. storyPrefs: mine alone
  ['turn my receipts off', 'ALLOW', B,
    `${D}/users/${B}/private/storyPrefs`, 'create', prefsOff, null, who(B)],
  ['turn my receipts back on', 'ALLOW', B,
    `${D}/users/${B}/private/storyPrefs`, 'update', prefsOn, prefsOff, who(B)],
  ['read my own switch', 'ALLOW', B,
    `${D}/users/${B}/private/storyPrefs`, 'get', null, prefsOff, who(B)],
  ['somebody else reads my switch', 'DENY', C,
    `${D}/users/${B}/private/storyPrefs`, 'get', null, prefsOff, who(C)],
  ['somebody else turns my receipts on', 'DENY', C,
    `${D}/users/${B}/private/storyPrefs`, 'update', prefsOn, prefsOff, who(C)],
  ['an offAt in the future', 'DENY', B,
    `${D}/users/${B}/private/storyPrefs`, 'create',
    { receipts: false, offAt: iso(now + 3600e3) }, null, who(B)],
  ['an extra field on the switch', 'DENY', B,
    `${D}/users/${B}/private/storyPrefs`, 'create', { ...prefsOff, x: 1 }, null, who(B)],

  // ---- 2. hiddenStoryViews: mine alone
  ['note a story I watched with receipts off', 'ALLOW', B,
    `${D}/users/${B}/hiddenStoryViews/${SID}`, 'create', hidden, null, who(B)],
  ['read my own hidden views', 'ALLOW', B,
    `${D}/users/${B}/hiddenStoryViews/${SID}`, 'get', null, hidden, who(B)],
  ['the author reads my hidden views', 'DENY', A,
    `${D}/users/${B}/hiddenStoryViews/${SID}`, 'get', null, hidden, who(A)],
  ['somebody writes a hidden view into my list', 'DENY', C,
    `${D}/users/${B}/hiddenStoryViews/${SID}`, 'create', hidden, null, who(C)],
  ['a hidden view under the wrong story id', 'DENY', B,
    `${D}/users/${B}/hiddenStoryViews/other`, 'create', hidden, null, who(B)],
  ['a hidden view with a made-up time', 'DENY', B,
    `${D}/users/${B}/hiddenStoryViews/${SID}`, 'create',
    { ...hidden, at: iso(now - 3600e3) }, null, who(B)],

  // ---- 3. firstAt on the receipt
  ['plain receipt create (outage guard)', 'ALLOW', B,
    `${D}/stories/${SID}/views/${B}`, 'create', { viewedAt: REQ_TIME }, null,
    [...storyDoc(friendsStory), ...who(B)]],
  ['a client sets firstAt on create', 'DENY', B,
    `${D}/stories/${SID}/views/${B}`, 'create', { viewedAt: REQ_TIME, firstAt: iso(now - 9e6) }, null,
    [...storyDoc(friendsStory), ...who(B)]],
  ['old-shape re-view on a stamped receipt (outage guard)', 'ALLOW', B,
    `${D}/stories/${SID}/views/${B}`, 'update', { ...stamped, viewedAt: REQ_TIME }, stamped,
    [...storyDoc(friendsStory), ...who(B)]],
  ['old-shape reaction on a stamped receipt (outage guard)', 'ALLOW', B,
    `${D}/stories/${SID}/views/${B}`, 'update',
    { ...stamped, viewedAt: REQ_TIME, reaction: '❤️' }, stamped,
    [...storyDoc(friendsStory), ...who(B)]],
  ['re-view on a receipt the server has not stamped yet', 'ALLOW', B,
    `${D}/stories/${SID}/views/${B}`, 'update', { viewedAt: REQ_TIME }, { viewedAt: iso(now - 600e3) },
    [...storyDoc(friendsStory), ...who(B)]],
  ['a client moves firstAt', 'DENY', B,
    `${D}/stories/${SID}/views/${B}`, 'update',
    { ...stamped, firstAt: iso(now - 9e6) }, stamped,
    [...storyDoc(friendsStory), ...who(B)]],
  ['a client removes firstAt', 'DENY', B,
    `${D}/stories/${SID}/views/${B}`, 'update', { viewedAt: REQ_TIME }, stamped,
    [...storyDoc(friendsStory), ...who(B)]],
  ['a client adds firstAt to an unstamped receipt', 'DENY', B,
    `${D}/stories/${SID}/views/${B}`, 'update',
    { viewedAt: REQ_TIME, firstAt: iso(now - 9e6) }, { viewedAt: iso(now - 600e3) },
    [...storyDoc(friendsStory), ...who(B)]],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  console.log(`rules: ${RULES}\n`);
  let pass = 0, fail = 0;
  const bad = [];
  for (const [name, expect, uid, path, method, after, before, mocks] of cases) {
    const request = {
      auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
      path, method, time: REQ_TIME,
    };
    if (after) request.resource = { data: after };
    const testCase = { expectation: expect, request, functionMocks: [...(mocks || []), ...NOT_BLOCKED] };
    if (before) testCase.resource = { data: before };
    const body = {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [testCase] },
    };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const ok = res && res.state === 'SUCCESS';
    ok ? pass++ : fail++;
    if (!ok) bad.push(name);
    // functionCalls: [] means nothing was evaluated at all — see README, trap 2.
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${expect.padEnd(5)}  ${name}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) console.log('failed: ' + bad.join(' | '));
})();
