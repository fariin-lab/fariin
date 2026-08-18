// The 2026-08-18 story hardening, fenced.
//
// Six rule changes went out together and three of them sit on paths that MUST NOT break:
// an ordinary message, an ordinary story post, and an ordinary view receipt. So this suite is
// half security assertions and half outage guards, and the outage guards matter more — a rule
// that denies too much is worse than the hole it was closing.
//
// Run BOTH ways. The security cases must FLIP (allowed on old.rules, denied on the new ones, or
// the reverse where a hole is being opened deliberately); the outage guards must pass on both.
//
//   git show HEAD:firestore.rules > old.rules
//   node story-hardening.test.js old.rules
//   node story-hardening.test.js
//
// resource.data is PLAIN JSON here, not Firestore typed values — see README, trap 1.
const fs = require('fs');
const crypto = require('crypto');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';      // the story's author
const B = 'uidBBB';      // a recipient
const C = 'uidCCC';      // a stranger
const MOD = 'uidMOD';    // a moderator
const SID = 'story123';
const CID = [A, B].sort().join('_');

// The same hash the app computes in `StoryAudienceToken.token` and the rules compute in
// `audienceToken`. If these three ever disagree nothing is readable, so the test computes it the
// third way on purpose rather than pasting a constant.
const tok = (uid) =>
  crypto.createHash('sha256').update('fariin-audience-v1:' + uid).digest('hex').toLowerCase();

const friendsStory = {
  authorUid: A,
  createdAt: 1700000000000,
  expiresAt: 1700086400000,
  recipientUids: [tok(B)],
  mediaPath: `stories/${SID}/photo.jpg`,
  type: 'image',
  mediaUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/real.jpg',
  caption: 'at the wedding',
  replyCount: 0,
  public: false,
  allowsReplies: true,
  audienceLabel: 'friends',
  oneTime: false,
};
const legacyStory = { ...friendsStory, recipientUids: [B] };          // written before tokenisation
const publicStory = { ...friendsStory, recipientUids: [], public: true, audienceLabel: 'everyone' };
const noReplies = { ...friendsStory, allowsReplies: false };
const onceStory = { ...friendsStory, oneTime: true, audienceLabel: 'oneTime',
                    recipientUids: [tok(B), tok(C)] };

const conv = { users: [A, B], accepted: true, startedBy: '', lastSender: '' };
const convBlocked = { ...conv, blockedBy: { [A]: true } };

const notBanned = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: { data: { banned: false } } } },
]);
const notAdmin = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
]);
const isModerator = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/admins/${uid}` }],
    result: { value: { data: { role: 'admin', permissions: ['moderate'] } } } },
]);
const storyDoc = (data) => ([
  { function: 'exists', args: [{ exactValue: `${D}/stories/${SID}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/stories/${SID}` }], result: { value: { data } } },
]);
const noStoryDoc = [
  { function: 'exists', args: [{ exactValue: `${D}/stories/${SID}` }], result: { value: false } },
];
const convDoc = (data) => ([
  { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data } } },
]);
const noConvDoc = [
  { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: false } },
];
const budget = (uid, data) => (
  data === null
    ? [{ function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/stories` }], result: { value: false } }]
    : [
        { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/stories` }], result: { value: true } },
        { function: 'get', args: [{ exactValue: `${D}/users/${uid}/limits/stories` }], result: { value: { data } } },
      ]
);

const receipt = { viewedAt: 1700000100000 };
const now = Date.now();

// [name, expect, uid, path, method, after, before, mocks]
const cases = [
  // ---- 1. view receipts. THE OUTAGE GUARD FIRST: this is the write that has been denied for
  // every non-public story since the audience was tokenised.
  ['receipt on a friends story, recipient by TOKEN', 'ALLOW', B,
    `${D}/stories/${SID}/views/${B}`, 'create', receipt, null,
    [...storyDoc(friendsStory), ...notBanned(B), ...notAdmin(B)]],
  ['receipt on a legacy story, recipient by raw uid', 'ALLOW', B,
    `${D}/stories/${SID}/views/${B}`, 'create', receipt, null,
    [...storyDoc(legacyStory), ...notBanned(B), ...notAdmin(B)]],
  ['receipt on a public story by a stranger', 'ALLOW', C,
    `${D}/stories/${SID}/views/${C}`, 'create', receipt, null,
    [...storyDoc(publicStory), ...notBanned(C), ...notAdmin(C)]],
  ['receipt on a friends story by somebody not in it', 'DENY', C,
    `${D}/stories/${SID}/views/${C}`, 'create', receipt, null,
    [...storyDoc(friendsStory), ...notBanned(C), ...notAdmin(C)]],
  ['a reaction on a story whose author turned replies off', 'DENY', B,
    `${D}/stories/${SID}/views/${B}`, 'create', { ...receipt, reaction: '❤️' }, null,
    [...storyDoc(noReplies), ...notBanned(B), ...notAdmin(B)]],

  // ---- 2. a one-time story's audience may shrink and only shrink
  ['take a blocked person off a one-time story', 'ALLOW', A,
    `${D}/stories/${SID}`, 'update', { ...onceStory, recipientUids: [tok(B)] }, onceStory,
    [...notBanned(A), ...notAdmin(A)]],
  ['put somebody back into a one-time story', 'DENY', A,
    `${D}/stories/${SID}`, 'update',
    { ...onceStory, recipientUids: [tok(B), tok(C), tok('uidDDD')] }, onceStory,
    [...notBanned(A), ...notAdmin(A)]],
  ['swap one name for another on a one-time story', 'DENY', A,
    `${D}/stories/${SID}`, 'update',
    { ...onceStory, recipientUids: [tok(B), tok('uidDDD')] }, onceStory,
    [...notBanned(A), ...notAdmin(A)]],

  // ---- 3. the public mirror
  ['a moderator deletes the public mirror', 'ALLOW', MOD,
    `${D}/users/${A}/publicStories/${SID}`, 'delete', null, { authorUid: A },
    [...isModerator(MOD)]],
  ['a stranger deletes the public mirror', 'DENY', C,
    `${D}/users/${A}/publicStories/${SID}`, 'delete', null, { authorUid: A },
    [...notAdmin(C)]],
  ['the author deletes their own mirror', 'ALLOW', A,
    `${D}/users/${A}/publicStories/${SID}`, 'delete', null, { authorUid: A },
    [...notAdmin(A)]],
  ['somebody the author blocked reads the mirror', 'DENY', B,
    `${D}/users/${A}/publicStories/${SID}`, 'get', null, { authorUid: A },
    [...convDoc(convBlocked), ...notAdmin(B)]],
  ['somebody with no conversation reads the mirror', 'ALLOW', B,
    `${D}/users/${A}/publicStories/${SID}`, 'get', null, { authorUid: A },
    [...noConvDoc, ...notAdmin(B)]],
  ['an ordinary reader reads the mirror', 'ALLOW', B,
    `${D}/users/${A}/publicStories/${SID}`, 'get', null, { authorUid: A },
    [...convDoc(conv), ...notAdmin(B)]],

  // ---- 4. replies. THE OUTAGE GUARD: an ordinary message must still send.
  ['an ordinary message with no quote', 'ALLOW', B,
    `${D}/conversations/${CID}/messages/m1`, 'create',
    { authorId: B, text: 'hello' }, null,
    [...convDoc(conv), ...notBanned(B), ...notAdmin(B)]],
  ['a reply quoting a MESSAGE, not a story', 'ALLOW', B,
    `${D}/conversations/${CID}/messages/m1`, 'create',
    { authorId: B, text: 'hello', replyTo: { id: 'm0', authorId: A, text: 'x' } }, null,
    [...convDoc(conv), ...notBanned(B), ...notAdmin(B)]],
  ['a story reply where the author allows them', 'ALLOW', B,
    `${D}/conversations/${CID}/messages/m1`, 'create',
    { authorId: B, text: 'nice', replyTo: { id: SID, authorId: A, text: 'x', isStatus: true } }, null,
    [...convDoc(conv), ...storyDoc(friendsStory), ...notBanned(B), ...notAdmin(B)]],
  ['a story reply where the author turned them off', 'DENY', B,
    `${D}/conversations/${CID}/messages/m1`, 'create',
    { authorId: B, text: 'nice', replyTo: { id: SID, authorId: A, text: 'x', isStatus: true } }, null,
    [...convDoc(conv), ...storyDoc(noReplies), ...notBanned(B), ...notAdmin(B)]],
  ['a story reply after the story expired', 'ALLOW', B,
    `${D}/conversations/${CID}/messages/m1`, 'create',
    { authorId: B, text: 'nice', replyTo: { id: SID, authorId: A, text: 'x', isStatus: true } }, null,
    [...convDoc(conv), ...noStoryDoc, ...notBanned(B), ...notAdmin(B)]],

  // ---- 5. the rate limit. THE OUTAGE GUARD: a client that has never written a counter must post.
  ['post with no counter at all', 'ALLOW', A,
    `${D}/stories/${SID}`, 'create',
    { ...friendsStory, expiresAt: new Date(now + 23 * 3600e3).toISOString() }, null,
    [...notBanned(A), ...notAdmin(A), ...budget(A, null)]],
  ['post inside a window that is not full', 'ALLOW', A,
    `${D}/stories/${SID}`, 'create',
    { ...friendsStory, expiresAt: new Date(now + 23 * 3600e3).toISOString() }, null,
    [...notBanned(A), ...notAdmin(A), ...budget(A, { windowStart: now - 60e3, count: 3 })]],
  ['post inside a window that is full', 'DENY', A,
    `${D}/stories/${SID}`, 'create',
    { ...friendsStory, expiresAt: new Date(now + 23 * 3600e3).toISOString() }, null,
    [...notBanned(A), ...notAdmin(A), ...budget(A, { windowStart: now - 60e3, count: 40 })]],
  ['post after a full window has expired', 'ALLOW', A,
    `${D}/stories/${SID}`, 'create',
    { ...friendsStory, expiresAt: new Date(now + 23 * 3600e3).toISOString() }, null,
    [...notBanned(A), ...notAdmin(A), ...budget(A, { windowStart: now - 2 * 3600e3, count: 99 })]],

  // ---- 6. the counter itself
  ['open a counter at one', 'ALLOW', A,
    `${D}/users/${A}/limits/stories`, 'create', { windowStart: now, count: 1 }, null, []],
  ['open a counter already part-spent', 'DENY', A,
    `${D}/users/${A}/limits/stories`, 'create', { windowStart: now, count: 0 }, null, []],
  ['take one more inside the window', 'ALLOW', A,
    `${D}/users/${A}/limits/stories`, 'update',
    { windowStart: now - 60e3, count: 4 }, { windowStart: now - 60e3, count: 3 }, []],
  ['reset the count inside the window', 'DENY', A,
    `${D}/users/${A}/limits/stories`, 'update',
    { windowStart: now - 60e3, count: 1 }, { windowStart: now - 60e3, count: 30 }, []],
  ['move the window forward while it is still open', 'DENY', A,
    `${D}/users/${A}/limits/stories`, 'update',
    { windowStart: now, count: 1 }, { windowStart: now - 60e3, count: 30 }, []],
  ['open a fresh window once the old one expired', 'ALLOW', A,
    `${D}/users/${A}/limits/stories`, 'update',
    { windowStart: now, count: 1 }, { windowStart: now - 2 * 3600e3, count: 40 }, []],
  ['delete the counter', 'DENY', A,
    `${D}/users/${A}/limits/stories`, 'delete', null, { windowStart: now, count: 40 }, []],
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
      path, method, time: new Date().toISOString(),
    };
    if (after) request.resource = { data: after };
    const testCase = { expectation: expect, request, functionMocks: mocks };
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
