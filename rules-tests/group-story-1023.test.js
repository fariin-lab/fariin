// 2026-10-23 GROUP STORIES (owner: "group stories go build"). A story with `groupId` is posted by the
// group's owner, or by an admin while the owner leaves `adminsPostStories` on; never public; the
// group cannot be changed after. Only the owner flips `adminsPostStories`.
// Each row runs against the rules BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   git show HEAD:firestore.rules > before-gstory.rules
//   node group-story-1023.test.js before-gstory.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-story-1023.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember', OUTSIDER = 'uidOutside';
const CID = 'grpStory1', DM = 'uidAdmin_uidOwner';
const SID = 'story123';
const NOW = new Date();
const REQ_TIME = NOW.toISOString();
const EXPIRES = new Date(NOW.getTime() + 24 * 3600 * 1000).toISOString();
const convPath = `${D}/conversations/${CID}`;
const dmPath = `${D}/conversations/${DM}`;
const storyPath = `${D}/stories/${SID}`;

// 50: the group-story minimum since 2026-10-23 (group-story-min-1023 tests the minimum itself).
const users = [OWNER, ADMIN, MEMBER, ...Array.from({ length: 47 }, (_, i) => `uidFill${i}`)];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN], createdBy: OWNER,
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME, ...over,
});
const dm = { type: 'direct', users: [OWNER, ADMIN], createdBy: OWNER, updatedAt: REQ_TIME };

const story = (author, over = {}) => ({
  authorUid: author, createdAt: REQ_TIME, expiresAt: EXPIRES,
  recipientUids: ['tokB', 'tokC'], mediaPath: `stories/${SID}/photo.jpg`, type: 'image',
  mediaUrl: '', thumbUrl: '', caption: '', replyCount: 0, public: false, allowsReplies: true,
  oneTime: false, audienceLabel: 'friends', ...over,
});
const gs = (author, over = {}) => story(author, {
  audienceLabel: 'group', groupId: CID, groupName: 'Plans', groupPhoto: '', ...over,
});

// The story create path reads the author's own documents: no counters yet, not banned, not staff.
const authorMocks = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: { data: { banned: false } } } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/storiesActive` }], result: { value: false } }, { function: 'get', args: [{ exactValue: `${D}/users/${uid}/limits/storiesActive` }], result: { value: null } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/stories` }], result: { value: false } }, { function: 'get', args: [{ exactValue: `${D}/users/${uid}/limits/stories` }], result: { value: null } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/storiesDaily` }], result: { value: false } }, { function: 'get', args: [{ exactValue: `${D}/users/${uid}/limits/storiesDaily` }], result: { value: null } },
  { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: false } },
]);
const convMocks = (path, data) => ([
  { function: 'get', args: [{ exactValue: path }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: path }], result: { value: true } },
]);
const storyMocks = (uid, conv = group()) => [...authorMocks(uid), ...convMocks(convPath, conv), ...convMocks(dmPath, dm)];

const off = group({ adminsPostStories: false });
const g = group();
// [name, before, after, uid, path, method, newData, oldData, mocks]
const cases = [
  // Canaries: ordinary stories are untouched, and an owner/admin group story posts on both files.
  ['CANARY  an ordinary story', 'ALLOW', 'ALLOW', MEMBER, storyPath, 'create', story(MEMBER), null, storyMocks(MEMBER)],
  ['OK      the owner posts a group story', 'ALLOW', 'ALLOW', OWNER, storyPath, 'create', gs(OWNER), null, storyMocks(OWNER)],
  ['OK      an admin posts (switch never set)', 'ALLOW', 'ALLOW', ADMIN, storyPath, 'create', gs(ADMIN), null, storyMocks(ADMIN)],
  ['OK      an admin posts (switch on)', 'ALLOW', 'ALLOW', ADMIN, storyPath, 'create', gs(ADMIN), null,
    storyMocks(ADMIN, group({ adminsPostStories: true }))],
  ['OK      the owner posts with the switch off', 'ALLOW', 'ALLOW', OWNER, storyPath, 'create', gs(OWNER), null, storyMocks(OWNER, off)],
  // The holes this closes.
  ['FIX     an admin posts with the switch off', 'ALLOW', 'DENY', ADMIN, storyPath, 'create', gs(ADMIN), null, storyMocks(ADMIN, off)],
  ['FIX     a plain member posts a group story', 'ALLOW', 'DENY', MEMBER, storyPath, 'create', gs(MEMBER), null, storyMocks(MEMBER)],
  ['FIX     an outsider posts as the group', 'ALLOW', 'DENY', OUTSIDER, storyPath, 'create', gs(OUTSIDER), null, storyMocks(OUTSIDER)],
  ['FIX     a public group story', 'ALLOW', 'DENY', OWNER, storyPath, 'create', gs(OWNER, { public: true }), null, storyMocks(OWNER)],
  ['FIX     groupId naming a 1:1 chat', 'ALLOW', 'DENY', OWNER, storyPath, 'create', gs(OWNER, { groupId: DM }), null, storyMocks(OWNER)],
  // A posted story keeps its group.
  ['FIX     the author moves a story into a group', 'ALLOW', 'DENY', OWNER, storyPath, 'update',
    gs(OWNER, { mediaUrl: 'https://x/y.jpg' }), story(OWNER), storyMocks(OWNER)],
  ['OK      the author fills in the media url', 'ALLOW', 'ALLOW', OWNER, storyPath, 'update',
    gs(OWNER, { mediaUrl: 'https://x/y.jpg' }), gs(OWNER), storyMocks(OWNER)],
  // The switch is the owner's.
  ['OK      the owner turns admin stories off', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', off, g, convMocks(convPath, g)],
  ['OK      the owner turns them back on', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', g, off, convMocks(convPath, off)],
  ['FIX     an admin turns them back on', 'ALLOW', 'DENY', ADMIN, convPath, 'update',
    group({ adminsPostStories: true }), off, convMocks(convPath, off)],
  ['FIX     an admin turns them off', 'ALLOW', 'DENY', ADMIN, convPath, 'update', off, g, convMocks(convPath, g)],
  ['GUARD   a member turns them off', 'DENY', 'DENY', MEMBER, convPath, 'update', off, g, convMocks(convPath, g)],
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
