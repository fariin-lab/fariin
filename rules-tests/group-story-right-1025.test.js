// 2026-10-25 GROUP STORY = EACH ADMIN'S RIGHT (owner: "this page is only members", then "add new option
// Add story" on the admin's page). The group-wide `adminsPostStories` switch is gone; an admin posts a
// group story when their `adminRights` list holds `postStories`, or when they have no list (legacy).
// Each row runs against the rules BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   git show HEAD:firestore.rules > before-gstory-right.rules
//   node group-story-right-1025.test.js before-gstory-right.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-story-right-1025.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember';
const CID = 'grpStory1', DM = 'uidAdmin_uidOwner';
const SID = 'story123';
const NOW = new Date();
const REQ_TIME = NOW.toISOString();
const EXPIRES = new Date(NOW.getTime() + 24 * 3600 * 1000).toISOString();
const convPath = `${D}/conversations/${CID}`;
const dmPath = `${D}/conversations/${DM}`;
const storyPath = `${D}/stories/${SID}`;

// 50: the group-story minimum.
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

const withRight = group({ adminRights: { [ADMIN]: ['pinMessages', 'postStories'] } });
const without = group({ adminRights: { [ADMIN]: ['pinMessages'] } });
const OUTSIDER = 'uidOutside';
const pub = group({ isPublic: true, username: 'plans' });
const switchOffWithRight =group({ adminsPostStories: false, adminRights: { [ADMIN]: ['postStories'] } });
// [name, before, after, uid, path, method, newData, oldData, mocks]
const cases = [
  ['CANARY  an ordinary story', 'ALLOW', 'ALLOW', MEMBER, storyPath, 'create', story(MEMBER), null, storyMocks(MEMBER)],
  ['OK      the owner posts a group story', 'ALLOW', 'ALLOW', OWNER, storyPath, 'create', gs(OWNER), null, storyMocks(OWNER)],
  ['OK      a legacy admin (no rights list) posts', 'ALLOW', 'ALLOW', ADMIN, storyPath, 'create', gs(ADMIN), null, storyMocks(ADMIN)],
  ['OK      an admin holding Add story posts', 'ALLOW', 'ALLOW', ADMIN, storyPath, 'create', gs(ADMIN), null, storyMocks(ADMIN, withRight)],
  ['CHANGE  an admin without Add story', 'ALLOW', 'DENY', ADMIN, storyPath, 'create', gs(ADMIN), null, storyMocks(ADMIN, without)],
  ['CHANGE  old group switch off no longer stops a holder', 'DENY', 'ALLOW', ADMIN, storyPath, 'create', gs(ADMIN), null,
    storyMocks(ADMIN, switchOffWithRight)],
  ['GUARD   a plain member', 'DENY', 'DENY', MEMBER, storyPath, 'create', gs(MEMBER), null, storyMocks(MEMBER, withRight)],
  ['GUARD   a member named in adminRights but not an admin', 'DENY', 'DENY', MEMBER, storyPath, 'create', gs(MEMBER), null,
    storyMocks(MEMBER, group({ adminRights: { [MEMBER]: ['postStories'] } }))],
  // 2026-10-25: a public group's story opens from its link for anyone signed in.
  ['CHANGE  an outsider opens a public group story by link', 'DENY', 'ALLOW', OUTSIDER, storyPath, 'get', null, gs(OWNER),
    [...authorMocks(OUTSIDER), ...convMocks(convPath, pub)]],
  ['GUARD   an outsider opens a private group story', 'DENY', 'DENY', OUTSIDER, storyPath, 'get', null, gs(OWNER),
    [...authorMocks(OUTSIDER), ...convMocks(convPath, group())]],
  ['GUARD   an outsider opens an ended public group story', 'DENY', 'DENY', OUTSIDER, storyPath, 'get', null, gs(OWNER),
    [...authorMocks(OUTSIDER), ...convMocks(convPath, group({ isPublic: true, username: 'plans', endedAt: REQ_TIME }))]],
  ['GUARD   an outsider opens an ordinary friends story', 'DENY', 'DENY', OUTSIDER, storyPath, 'get', null, story(OWNER),
    authorMocks(OUTSIDER)],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
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
