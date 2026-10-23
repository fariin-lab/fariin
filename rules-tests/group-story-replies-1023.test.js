// 2026-10-23 GROUP STORIES v2 (owner): a group story reaches every member (capped by the group's
// size, not 1000), and replies are one shared thread per story, the reference (signal) way: read and
// written by everyone the story reached until it expires, deleted by the writer or a group admin.
// Each row runs against the rules BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   git show HEAD:firestore.rules > before-gstory2.rules
//   node group-story-replies-1023.test.js before-gstory2.rules ../firestore.rules
const fs = require('fs');
const crypto = require('crypto');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-story-replies-1023.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember', OTHER = 'uidOther', OUTSIDER = 'uidOutside';
const CID = 'grpStory2', SID = 'story456', RID = 'reply1';
const NOW = new Date();
const REQ_TIME = NOW.toISOString();
const EXPIRES = new Date(NOW.getTime() + 24 * 3600 * 1000).toISOString();
const PAST = new Date(NOW.getTime() - 3600 * 1000).toISOString();
const tok = (u) => crypto.createHash('sha256').update('fariin-audience-v1:' + u).digest('hex');
const convPath = `${D}/conversations/${CID}`;
const storyPath = `${D}/stories/${SID}`;
const replyPath = `${storyPath}/replies/${RID}`;

const many = (n) => Array.from({ length: n }, (_, i) => `uid${String(i).padStart(5, '0')}`);
const bigUsers = [OWNER, ADMIN, MEMBER, OTHER, ...many(1996)];          // 2000 members
const group = (users) => ({ type: 'group', title: 'Big', users, admins: [OWNER, ADMIN], createdBy: OWNER, updatedAt: REQ_TIME });

const story = (author, over = {}) => ({
  authorUid: author, createdAt: REQ_TIME, expiresAt: EXPIRES,
  recipientUids: [MEMBER, OTHER, ADMIN].map(tok), mediaPath: `stories/${SID}/photo.jpg`, type: 'image',
  mediaUrl: '', thumbUrl: '', caption: '', replyCount: 0, public: false, allowsReplies: true,
  oneTime: false, audienceLabel: 'group', groupId: CID, groupName: 'Big', groupPhoto: '', ...over,
});

const authorMocks = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: { data: { banned: false } } } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/storiesActive` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/stories` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/storiesDaily` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: false } },
]);
const docMock = (path, data) => ([
  { function: 'get', args: [{ exactValue: path }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: path }], result: { value: true } },
]);
const replyMocks = (uid, st = story(OWNER), conv = group(bigUsers)) =>
  [...authorMocks(uid), ...docMock(storyPath, st), ...docMock(convPath, conv)];

const bigList = bigUsers.filter((u) => u !== OWNER).map(tok);   // 1999 tokens
const reply = (uid, over = {}) => ({ uid, text: 'nice', createdAt: REQ_TIME, ...over });

// [name, before, after, uid, path, method, newData, oldData, mocks]
const cases = [
  // Delivery: the whole group, however big; never more than the group.
  ['FIX     a 2000-member group story', 'DENY', 'ALLOW', OWNER, storyPath, 'create',
    story(OWNER, { recipientUids: bigList }), null, [...authorMocks(OWNER), ...docMock(convPath, group(bigUsers))]],
  ['GUARD   more recipients than the group has', 'DENY', 'DENY', OWNER, storyPath, 'create',
    story(OWNER, { recipientUids: bigList }), null, [...authorMocks(OWNER), ...docMock(convPath, group([OWNER, ADMIN, MEMBER]))]],
  ['GUARD   an ordinary story over 1000', 'DENY', 'DENY', MEMBER, storyPath, 'create',
    story(MEMBER, { recipientUids: many(1001).map(tok), groupId: '', audienceLabel: 'friends' }), null, authorMocks(MEMBER)],
  ['CANARY  an ordinary story', 'ALLOW', 'ALLOW', MEMBER, storyPath, 'create',
    story(MEMBER, { groupId: '', audienceLabel: 'friends' }), null, authorMocks(MEMBER)],
  ['FIX     filling in a 2000-member story\'s media', 'DENY', 'ALLOW', OWNER, storyPath, 'update',
    story(OWNER, { recipientUids: bigList, mediaUrl: 'https://x/y.jpg' }), story(OWNER, { recipientUids: bigList }), authorMocks(OWNER)],
  ['GUARD   widening a big group story after posting', 'DENY', 'DENY', OWNER, storyPath, 'update',
    story(OWNER, { recipientUids: [...bigList, tok('uidNew')] }), story(OWNER, { recipientUids: bigList }), authorMocks(OWNER)],

  // Replies: one shared thread for everyone the story reached.
  ['FIX     a member replies', 'DENY', 'ALLOW', MEMBER, replyPath, 'create', reply(MEMBER), null, replyMocks(MEMBER)],
  ['FIX     a member reacts', 'DENY', 'ALLOW', MEMBER, replyPath, 'create',
    { uid: MEMBER, emoji: '❤️', createdAt: REQ_TIME }, null, replyMocks(MEMBER)],
  ['FIX     the poster replies', 'DENY', 'ALLOW', OWNER, replyPath, 'create', reply(OWNER), null, replyMocks(OWNER)],
  ['FIX     a member reads the thread', 'DENY', 'ALLOW', OTHER, replyPath, 'get', null, reply(MEMBER), replyMocks(OTHER)],
  ['GUARD   an outsider reads the thread', 'DENY', 'DENY', OUTSIDER, replyPath, 'get', null, reply(MEMBER), replyMocks(OUTSIDER)],
  ['GUARD   an outsider replies', 'DENY', 'DENY', OUTSIDER, replyPath, 'create', reply(OUTSIDER), null, replyMocks(OUTSIDER)],
  ['GUARD   replying as someone else', 'DENY', 'DENY', MEMBER, replyPath, 'create', reply(OTHER), null, replyMocks(MEMBER)],
  ['GUARD   replying to an expired story', 'DENY', 'DENY', MEMBER, replyPath, 'create', reply(MEMBER), null,
    replyMocks(MEMBER, story(OWNER, { expiresAt: PAST }))],
  ['GUARD   replies on a story that is not a group story', 'DENY', 'DENY', MEMBER, replyPath, 'create', reply(MEMBER), null,
    replyMocks(MEMBER, story(OWNER, { groupId: '', audienceLabel: 'friends' }))],
  ['GUARD   an empty reply', 'DENY', 'DENY', MEMBER, replyPath, 'create', reply(MEMBER, { text: '' }), null, replyMocks(MEMBER)],
  ['GUARD   an extra field', 'DENY', 'DENY', MEMBER, replyPath, 'create', reply(MEMBER, { name: 'x' }), null, replyMocks(MEMBER)],
  ['GUARD   editing a reply', 'DENY', 'DENY', MEMBER, replyPath, 'update', reply(MEMBER, { text: 'changed' }), reply(MEMBER), replyMocks(MEMBER)],
  // Managing: the writer, or a group admin / the owner.
  ['FIX     deleting my own reply', 'DENY', 'ALLOW', MEMBER, replyPath, 'delete', null, reply(MEMBER), replyMocks(MEMBER)],
  ['FIX     an admin deletes a member\'s reply', 'DENY', 'ALLOW', ADMIN, replyPath, 'delete', null, reply(MEMBER), replyMocks(ADMIN)],
  ['FIX     the owner deletes a member\'s reply', 'DENY', 'ALLOW', OWNER, replyPath, 'delete', null, reply(MEMBER), replyMocks(OWNER)],
  ['GUARD   a member deletes someone else\'s reply', 'DENY', 'DENY', OTHER, replyPath, 'delete', null, reply(MEMBER), replyMocks(OTHER)],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = { auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, path: p, method, time: REQ_TIME };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: [...(mocks || []), { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
  if (before) testCase.resource = { data: before };
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ source: { files: [{ name: 'firestore.rules', content: source }] }, testSuite: { testCases: [testCase] } }),
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
