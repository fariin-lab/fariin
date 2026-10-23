// 2026-10-23 GROUP STORY VIEWS AND REPLIES (owner: "only the owner and admins can see the views";
// "members reply, only owner and admins read them"). A group story's `views/*`, `meta/*` and
// `replies/*` are read by its author and the group's owner and admins, never by a plain member. A
// member writes and deletes their own reply; the group's owner or an admin deletes any.
// Each row runs against the rules BEFORE the change and AFTER it. Mock every get() and exists().
//
//   git show HEAD:firestore.rules > before-gviews.rules
//   node group-story-views-1023.test.js before-gviews.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
// Reads per request (counted by hand, the :test API does not enforce the 10 limit): views/meta read
// = the story + its group = 2; reply read = 2; reply create = the story = 1; reply delete by an
// admin = the story + its group = 2.
const fs = require('fs');
const crypto = require('crypto');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-story-views-1023.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', ADMIN2 = 'uidAdmin2', MEMBER = 'uidMember', OUTSIDER = 'uidOutside';
const CID = 'grpStory1', SID = 'story123', ONE = 'story1to1';
const NOW = new Date();
const REQ_TIME = NOW.toISOString();
const EXPIRES = new Date(NOW.getTime() + 24 * 3600 * 1000).toISOString();
const tok = (uid) => crypto.createHash('sha256').update('fariin-audience-v1:' + uid).digest('hex');

const users = [OWNER, ADMIN, ADMIN2, MEMBER];
const group = { type: 'group', title: 'Plans', users, admins: [ADMIN, ADMIN2], createdBy: OWNER, updatedAt: REQ_TIME };
const convPath = `${D}/conversations/${CID}`;
const storyPath = (id) => `${D}/stories/${id}`;

// ADMIN posted the group story; OWNER, ADMIN2 and MEMBER are its audience.
const gStory = {
  authorUid: ADMIN, createdAt: REQ_TIME, expiresAt: EXPIRES, groupId: CID,
  recipientUids: [OWNER, ADMIN2, MEMBER].map(tok), type: 'image', public: false,
};
const plainStory = { ...gStory, groupId: undefined, authorUid: OWNER, recipientUids: [MEMBER, ADMIN].map(tok) };
delete plainStory.groupId;

const mocks = (sid, data) => ([
  { function: 'get', args: [{ exactValue: storyPath(sid) }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: storyPath(sid) }], result: { value: true } },
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data: group } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);
const G = mocks(SID, gStory), P = mocks(ONE, plainStory);
const views = (sid, who) => `${storyPath(sid)}/views/${who}`;
const meta = (sid) => `${storyPath(sid)}/meta/views`;
const reply = (id) => `${storyPath(SID)}/replies/${id}`;
const replyDoc = (uid, over = {}) => ({ uid, text: 'nice', createdAt: REQ_TIME, ...over });

// [name, before, after, uid, path, method, newData, oldData, mocks]
const cases = [
  // Views list and count.
  ['OK      the poster reads a view receipt', 'ALLOW', 'ALLOW', ADMIN, views(SID, MEMBER), 'get', null, { viewedAt: REQ_TIME }, G],
  ['OK      the poster reads the count', 'ALLOW', 'ALLOW', ADMIN, meta(SID), 'get', null, { count: 3 }, G],
  ['NEW     the group owner reads a view receipt', 'DENY', 'ALLOW', OWNER, views(SID, MEMBER), 'get', null, { viewedAt: REQ_TIME }, G],
  ['NEW     another admin reads the count', 'DENY', 'ALLOW', ADMIN2, meta(SID), 'get', null, { count: 3 }, G],
  ['NEW     another admin lists the views', 'DENY', 'ALLOW', ADMIN2, views(SID, OWNER), 'list', null, { viewedAt: REQ_TIME }, G],
  ['GUARD   a member reads someone else\'s receipt', 'DENY', 'DENY', MEMBER, views(SID, OWNER), 'get', null, { viewedAt: REQ_TIME }, G],
  ['GUARD   a member lists the views', 'DENY', 'DENY', MEMBER, views(SID, OWNER), 'list', null, { viewedAt: REQ_TIME }, G],
  ['GUARD   a member reads the count', 'DENY', 'DENY', MEMBER, meta(SID), 'get', null, { count: 3 }, G],
  ['GUARD   an outsider reads the count', 'DENY', 'DENY', OUTSIDER, meta(SID), 'get', null, { count: 3 }, G],
  ['OK      a member reads their own receipt', 'ALLOW', 'ALLOW', MEMBER, views(SID, MEMBER), 'get', null, { viewedAt: REQ_TIME }, G],
  // A 1:1 story is untouched: the author only, even for somebody who is a group admin elsewhere.
  ['OK      a 1:1 story\'s author reads the count', 'ALLOW', 'ALLOW', OWNER, meta(ONE), 'get', null, { count: 1 }, P],
  ['GUARD   a 1:1 story\'s viewer reads the count', 'DENY', 'DENY', ADMIN, meta(ONE), 'get', null, { count: 1 }, P],
  ['GUARD   a 1:1 story\'s viewer reads a receipt', 'DENY', 'DENY', ADMIN, views(ONE, MEMBER), 'get', null, { viewedAt: REQ_TIME }, P],
  // Replies: members write, only the author, owner and admins read.
  ['OK      a member writes a reply', 'ALLOW', 'ALLOW', MEMBER, reply('r1'), 'create', replyDoc(MEMBER), null, G],
  ['OK      a member reacts', 'ALLOW', 'ALLOW', MEMBER, reply('r2'), 'create', { uid: MEMBER, emoji: '🔥', createdAt: REQ_TIME }, null, G],
  ['GUARD   a member writes as someone else', 'DENY', 'DENY', MEMBER, reply('r3'), 'create', replyDoc(OWNER), null, G],
  ['GUARD   an outsider writes a reply', 'DENY', 'DENY', OUTSIDER, reply('r4'), 'create', replyDoc(OUTSIDER), null, G],
  ['FIX     a member reads the thread', 'ALLOW', 'DENY', MEMBER, reply('r1'), 'list', null, replyDoc(OWNER), G],
  ['FIX     a member reads one reply', 'ALLOW', 'DENY', MEMBER, reply('r1'), 'get', null, replyDoc(MEMBER), G],
  ['OK      another admin reads the thread', 'ALLOW', 'ALLOW', ADMIN2, reply('r1'), 'list', null, replyDoc(MEMBER), G],
  ['OK      the group owner reads the thread', 'ALLOW', 'ALLOW', OWNER, reply('r1'), 'list', null, replyDoc(MEMBER), G],
  ['GUARD   an outsider reads the thread', 'DENY', 'DENY', OUTSIDER, reply('r1'), 'list', null, replyDoc(MEMBER), G],
  ['OK      the poster reads the thread', 'ALLOW', 'ALLOW', ADMIN, reply('r1'), 'list', null, replyDoc(MEMBER), G],
  ['OK      a member deletes their own reply', 'ALLOW', 'ALLOW', MEMBER, reply('r1'), 'delete', null, replyDoc(MEMBER), G],
  ['GUARD   a member deletes someone else\'s', 'DENY', 'DENY', MEMBER, reply('r1'), 'delete', null, replyDoc(OWNER), G],
  ['OK      an admin deletes a member\'s reply', 'ALLOW', 'ALLOW', ADMIN2, reply('r1'), 'delete', null, replyDoc(MEMBER), G],
  ['OK      the owner deletes a member\'s reply', 'ALLOW', 'ALLOW', OWNER, reply('r1'), 'delete', null, replyDoc(MEMBER), G],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  // Not staff, not blocked: production's answer for every other lookup here.
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
