// Can an "Everyone" story be posted, and can a stranger read it?
//
// The owner re-enabled the Everyone audience on 2026-08-06. The READ rule has honoured
// `public == true` all along; the CREATE rule was the half that refused it, so that clause came out.
// This proves the change does what the commit says, and — the part that actually matters — that
// taking it out did not open anything else.
//
// It also covers the storyLists subcollection the custom stories live in, which already had an
// owner-only rule written for it before this feature existed.
//
// Run BOTH ways. The public create must DENY on the old rules and ALLOW on the new ones; every
// other case must behave identically on both, or the change did more than it claims.
//
//   git show HEAD:firestore.rules > rules-tests/old.rules
//   node story-audience.test.js old.rules
//   node story-audience.test.js
//
// resource.data is PLAIN JSON here, not Firestore typed values — see README, trap 1.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the author
const B = 'uidBBB';   // a recipient
const C = 'uidCCC';   // a complete stranger
const SID = 'story123';

// ⚠️ `expiresAt` MUST BE AN ISO STRING, not the epoch number the update test uses. The create rule
// asserts `expiresAt is timestamp` and then compares it against `request.time`; a plain number
// fails the type check and the whole create denies for a reason that has nothing to do with what is
// being tested. That is trap 1 in the README wearing a different hat — and it is exactly what made
// the first run of this file report that posting a private story was refused.
//
// Computed at run time rather than pinned: the rule also demands it lands inside the next 30 hours.
const base = {
  authorUid: A,
  createdAt: new Date().toISOString(),
  expiresAt: new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
  recipientUids: [B],
  mediaPath: `stories/${SID}/photo.jpg`,
  type: 'image',
  mediaUrl: '',
  thumbUrl: '',
  caption: '',
  replyCount: 0,
  allowsReplies: true,
};
const publicStory = { ...base, public: true };
const privateStory = { ...base, public: false };

/// One mock set per CALLER: isBanned() reads users/{caller} and adminCan() reads admins/{caller}.
/// Getting this wrong is the trap the README calls out — an unmocked read makes the whole rule
/// evaluate to nothing and the test reports a confident, meaningless answer.
function mocksFor(uid, { banned = false } = {}) {
  return [
    { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
    { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }],
      result: { value: { data: { banned } } } },
    { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
  ];
}

const cases = [
  // THE CHANGE ITSELF.
  { name: 'author posts an Everyone story', expect: 'ALLOW', uid: A, method: 'create',
    path: `${D}/stories/${SID}`, after: publicStory, mocks: mocksFor(A) },
  { name: 'author posts a friends-only story', expect: 'ALLOW', uid: A, method: 'create',
    path: `${D}/stories/${SID}`, after: privateStory, mocks: mocksFor(A) },

  // WHAT MUST NOT HAVE MOVED. Everything below behaved this way before the clause came out and has
  // to behave this way after it, or the edit reached further than one audience option.
  { name: 'a BANNED account posts an Everyone story', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/stories/${SID}`, after: publicStory, mocks: mocksFor(A, { banned: true }) },
  { name: 'a banned account posts a private story', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/stories/${SID}`, after: privateStory, mocks: mocksFor(A, { banned: true }) },
  { name: 'post a story under somebody else\'s name', expect: 'DENY', uid: C, method: 'create',
    path: `${D}/stories/${SID}`, after: publicStory, mocks: mocksFor(C) },

  // READS. The public half is the whole point of the audience; the private half is what proves it
  // did not become a skeleton key.
  { name: 'a stranger reads an Everyone story', expect: 'ALLOW', uid: C, method: 'get',
    path: `${D}/stories/${SID}`, before: publicStory, mocks: mocksFor(C) },
  { name: 'a stranger reads a friends-only story', expect: 'DENY', uid: C, method: 'get',
    path: `${D}/stories/${SID}`, before: privateStory, mocks: mocksFor(C) },
  { name: 'a recipient reads a friends-only story', expect: 'ALLOW', uid: B, method: 'get',
    path: `${D}/stories/${SID}`, before: privateStory, mocks: mocksFor(B) },

  // THE CUSTOM LISTS. Names of the people you quietly keep out of things — nobody else's business.
  { name: 'own my story list', expect: 'ALLOW', uid: A, method: 'create',
    path: `${D}/users/${A}/storyLists/list1`,
    after: { kind: 'custom', name: 'close friends', mode: 'only', members: [B], allowReplies: true },
    mocks: mocksFor(A) },
  { name: 'read somebody else\'s story list', expect: 'DENY', uid: C, method: 'get',
    path: `${D}/users/${A}/storyLists/list1`,
    before: { kind: 'custom', name: 'close friends', mode: 'only', members: [B], allowReplies: true },
    mocks: mocksFor(C) },
  { name: 'write into somebody else\'s story list', expect: 'DENY', uid: C, method: 'create',
    path: `${D}/users/${A}/storyLists/list1`,
    after: { kind: 'custom', name: 'mine now', mode: 'only', members: [C], allowReplies: true },
    mocks: mocksFor(C) },
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  console.log(`rules: ${RULES}\n`);
  let pass = 0, fail = 0;
  const bad = [];
  for (const c of cases) {
    const request = {
      auth: { uid: c.uid, token: { firebase: { sign_in_provider: 'password' } } },
      path: c.path,
      method: c.method,
      time: new Date().toISOString(),
    };
    if (c.after) request.resource = { data: c.after };
    const testCase = { expectation: c.expect, request, functionMocks: c.mocks };
    if (c.before) testCase.resource = { data: c.before };

    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: { files: [{ name: 'firestore.rules', content: source }] },
        testSuite: { testCases: [testCase] },
      }),
    });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const ok = res && res.state === 'SUCCESS';
    ok ? pass++ : fail++;
    if (!ok) bad.push(c.name);
    // functionCalls: [] means nothing was evaluated at all — see README, trap 2.
    const empty = res && Array.isArray(res.functionCalls) && res.functionCalls.length === 0;
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${c.expect.padEnd(5)}  ${c.name}${empty ? '   (no functions evaluated — check the mocks)' : ''}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) console.log('failed: ' + bad.join(' | '));
})();
