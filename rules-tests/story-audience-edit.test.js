// Can the author of a POSTED story change WHO CAN SEE IT, and only that?
//
// The owner asked for the reference app's behaviour (2026-08-18): change the audience of a story
// that is already up, keeping its id, its posting time, its media and everybody who has already
// watched it. Two clauses had to move for it — `recipientUids` and `audienceLabel` were pinned, so
// a posted story's audience was frozen for its whole life.
//
// This suite is the fence around that opening. The audience may move; NOTHING else may move with
// it, and a one-time story's audience may not move at all — being taken out of `recipientUids` is
// precisely how its single view is spent, so putting somebody back in would hand them a second look.
//
// Run BOTH ways. The new ALLOWs must be DENIED on the old rules (or the change did nothing) and the
// DENYs must be denied on both (or the change opened something it should not have):
//
//   git show HEAD:firestore.rules > old.rules
//   node story-audience-edit.test.js old.rules   # the audience edits DENY, the guards DENY
//   node story-audience-edit.test.js             # the audience edits ALLOW, the guards still DENY
//
// resource.data is PLAIN JSON here, not Firestore typed values — see README, trap 1.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the author
const B = 'uidBBB';   // somebody else
const SID = 'story123';

// Tokens, not uids — the audience travels as sha256 hashes on the document. Their VALUES do not
// matter to any clause under test; only whether the array changed, and how long it is.
const tok = (n) => `${n}`.padStart(64, '0');

// A posted story that went to My Friends.
const friends = {
  authorUid: A,
  createdAt: 1700000000000,
  expiresAt: 1700086400000,
  recipientUids: [tok(1), tok(2)],
  mediaPath: `stories/${SID}/photo.jpg`,
  type: 'image',
  mediaUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/real.jpg',
  thumbUrl: '',
  caption: 'at the wedding',
  replyCount: 0,
  public: false,
  allowsReplies: true,
  audienceLabel: 'friends',
  oneTime: false,
};

// The same story moved to Everyone: a wider recipient list, the public flag on, the label changed.
// The media and the caption are untouched, which is the whole point of the feature.
const everyone = { ...friends, recipientUids: [tok(1), tok(2), tok(3)], public: true, audienceLabel: 'everyone' };

// A one-time story. Its audience is spent as it is watched, so it is frozen.
const once = { ...friends, oneTime: true, audienceLabel: 'oneTime' };

const tooMany = { ...friends, recipientUids: Array.from({ length: 1001 }, (_, i) => tok(i)) };

const mocks = [
  { function: 'exists', args: [{ exactValue: `${D}/users/${A}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${A}` }], result: { value: { data: { banned: false } } } },
  { function: 'exists', args: [{ exactValue: `${D}/admins/${A}` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/admins/${B}` }], result: { value: false } },
  { function: 'get', args: [{ exactValue: `${D}/stories/${SID}` }], result: { value: { data: friends } } },
];

// [name, expectation, before, after, actingUid]
const cases = [
  // THE FEATURE. These are the ones that were denied before the change.
  ['widen a posted story to Everyone', 'ALLOW', friends, everyone, A],
  ['narrow an Everyone story back to My Friends', 'ALLOW', everyone, friends, A],
  ['move a story to a custom list', 'ALLOW', friends,
    { ...friends, recipientUids: [tok(9)], audienceLabel: 'custom' }, A],
  ['turn replies off while changing the audience', 'ALLOW', friends,
    { ...everyone, allowsReplies: false }, A],

  // THE FENCE. An audience edit must not be a way to smuggle a content edit through.
  ['swap the picture while changing the audience', 'DENY', friends,
    { ...everyone, mediaUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/swapped.jpg' }, A],
  ['rewrite the caption while changing the audience', 'DENY', friends,
    { ...everyone, caption: 'something else entirely' }, A],
  ['point the picture elsewhere while changing the audience', 'DENY', friends,
    { ...everyone, mediaUrl: 'https://evil.example/illegal.jpg' }, A],

  // A one-time story's audience is frozen: a viewer is REMOVED as they burn their single view, so
  // rewriting the list is how somebody gets a second look at something already gone.
  ['put a viewer back into a one-time story', 'DENY', once,
    { ...once, recipientUids: [tok(1), tok(2), tok(3)] }, A],
  ['make a one-time story public after the fact', 'DENY', once,
    { ...once, public: true, audienceLabel: 'everyone' }, A],
  ['count a reply on a one-time story', 'ALLOW', once, { ...once, replyCount: 1 }, A],

  // The fan-out cap the create rule enforces, enforced here too.
  ['edit the audience past the 1000 cap', 'DENY', friends, tooMany, A],

  // Somebody else's story is still somebody else's.
  ['change the audience of a story I did not post', 'DENY', friends, everyone, B],

  // Regressions: everything that was pinned before this change is still pinned.
  ['rewrite authorUid to impersonate somebody', 'DENY', friends, { ...friends, authorUid: B }, A],
  ['push expiresAt out so it never expires', 'DENY', friends, { ...friends, expiresAt: 99999999999999 }, A],
  ['restamp createdAt to jump the queue', 'DENY', friends, { ...friends, createdAt: 1700086000000 }, A],
  ['turn an ordinary story into a one-time one', 'DENY', friends, { ...friends, oneTime: true }, A],
  ['repoint mediaPath at another story folder', 'DENY', friends,
    { ...friends, mediaPath: 'stories/other/photo.jpg' }, A],
  ['count a reply on a posted story', 'ALLOW', friends, { ...friends, replyCount: 3 }, A],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  console.log(`rules: ${RULES}\n`);
  let pass = 0, fail = 0;
  const bad = [];
  for (const [name, expect, before, after, uid] of cases) {
    const body = {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: {
        testCases: [{
          expectation: expect,
          request: {
            auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
            path: `${D}/stories/${SID}`,
            method: 'update',
            time: new Date().toISOString(),
            resource: { data: after },
          },
          resource: { data: before },
          functionMocks: mocks,
        }],
      },
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
