// Can the author of a POSTED story swap its picture or caption afterwards?
//
// This is Durov's attack, adapted. Telegram was pulled from the App Store on 2026-08-05 because an
// extortionist EDITED an old message in a public group: invisible to everybody who had already
// scrolled past, so nobody could report it, while Apple could still be pointed straight at it. Our
// stories had the same shape — mediaUrl and caption were mutable for the life of the document.
//
// The fix allows those two fields to change ONLY while mediaUrl is still empty, which is exactly the
// window the post flow uses (create with "", fill in once after the upload).
//
// Run BOTH ways. The attacks must be ALLOWED on the old rules and DENIED on the new ones, while the
// posting cases pass on both — otherwise this is an outage, not a fix.
//
//   git show HEAD:firestore.rules > old.rules   (before committing the change)
//   node story-freeze.test.js old.rules         # attacks ALLOW
//   node story-freeze.test.js                   # attacks DENY
//
// resource.data is PLAIN JSON here, not Firestore typed values — see README, trap 1.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the author
const B = 'uidBBB';   // a recipient
const SID = 'story123';

// A story that has been posted: the upload finished and mediaUrl was filled in.
const posted = {
  authorUid: A,
  createdAt: 1700000000000,
  expiresAt: 1700086400000,
  recipientUids: [B],
  mediaPath: `stories/${SID}/photo.jpg`,
  type: 'image',
  mediaUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/real.jpg',
  thumbUrl: '',
  caption: 'at the wedding',
  replyCount: 0,
  public: false,
  allowsReplies: true,
};

// The same story a second earlier: created, bytes still uploading, mediaUrl not yet known.
const fresh = { ...posted, mediaUrl: '', caption: '' };

// A video story mid-post: both urls still empty, filled together in one update.
const freshVideo = { ...fresh, type: 'video', mediaPath: `stories/${SID}/video.mp4`, thumbUrl: '' };

const mocks = [
  { function: 'exists', args: [{ exactValue: `${D}/users/${A}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${A}` }], result: { value: { data: { banned: false } } } },
  { function: 'exists', args: [{ exactValue: `${D}/admins/${A}` }], result: { value: false } },
  { function: 'get', args: [{ exactValue: `${D}/stories/${SID}` }], result: { value: { data: posted } } },
];

const cases = [
  // THE ATTACKS. Each one is a posted story being rewritten after people have watched it.
  ['swap the picture on a posted story', 'DENY', posted,
    { ...posted, mediaUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/swapped.jpg' }],
  ['point the picture at a site we do not host', 'DENY', posted,
    { ...posted, mediaUrl: 'https://evil.example/illegal.jpg' }],
  ['rewrite the caption on a posted story', 'DENY', posted,
    { ...posted, caption: 'something else entirely' }],
  ['blank the picture to re-fill it later', 'DENY', posted, { ...posted, mediaUrl: '' }],

  // THE OTHER HALF. If any of these deny, posting a story is broken and this is an outage.
  ['fill in the url right after upload (photo)', 'ALLOW', fresh,
    { ...fresh, mediaUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/real.jpg', caption: 'at the wedding' }],
  ['fill in both urls right after upload (video)', 'ALLOW', freshVideo,
    { ...freshVideo, mediaUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/v.mp4',
      thumbUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/t.jpg' }],
  ['count a reply on a posted story', 'ALLOW', posted, { ...posted, replyCount: 3 }],

  // Still-pinned fields: these were already immutable before this change and must stay that way.
  ['rewrite authorUid to impersonate somebody', 'DENY', posted, { ...posted, authorUid: B }],
  ['push expiresAt out so it never expires', 'DENY', posted, { ...posted, expiresAt: 99999999999999 }],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  console.log(`rules: ${RULES}\n`);
  let pass = 0, fail = 0;
  const bad = [];
  for (const [name, expect, before, after] of cases) {
    const body = {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: {
        testCases: [{
          expectation: expect,
          request: {
            auth: { uid: A, token: { firebase: { sign_in_provider: 'password' } } },
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
