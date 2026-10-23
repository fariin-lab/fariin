// 2026-10-23 (owner): group stories only in a group of at least 50 members (config/limits
// group_story_min_members, fallback 50), except app admins (admins/{uid}), who may post to any group
// they own or run. Each row runs against the rules BEFORE the change and AFTER it.
//
//   git show HEAD:firestore.rules > before-gstory3.rules
//   node group-story-min-1023.test.js before-gstory3.rules ../firestore.rules
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-story-min-1023.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin';
const CID = 'grpMin1', SID = 'story789';
const NOW = new Date(), REQ_TIME = NOW.toISOString();
const EXPIRES = new Date(NOW.getTime() + 24 * 3600 * 1000).toISOString();
const convPath = `${D}/conversations/${CID}`;
const fill = (n) => Array.from({ length: n }, (_, i) => `uidF${i}`);
const group = (size, over = {}) => ({
  type: 'group', title: 'G', users: [OWNER, ADMIN, ...fill(size - 2)], admins: [OWNER, ADMIN], createdBy: OWNER,
  updatedAt: REQ_TIME, ...over,
});
const story = (author) => ({
  authorUid: author, createdAt: REQ_TIME, expiresAt: EXPIRES, recipientUids: ['tokA'],
  mediaPath: `stories/${SID}/photo.jpg`, type: 'image', mediaUrl: '', caption: '', replyCount: 0,
  public: false, allowsReplies: true, oneTime: false, audienceLabel: 'group', groupId: CID,
});
const mocks = (uid, conv, { appAdmin = false, config = null } = {}) => [
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: appAdmin } },
  ...(appAdmin ? [{ function: 'get', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: { data: { role: 'owner' } } } }] : []),
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: { data: { banned: false } } } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/storiesActive` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/stories` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}/limits/storiesDaily` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: config !== null } },
  ...(config ? [{ function: 'get', args: [{ exactValue: `${D}/config/limits` }], result: { value: { data: config } } }] : []),
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data: conv } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
];

// [name, before, after, uid, mocks]
const cases = [
  ['OK      the owner of a 50-member group', 'ALLOW', 'ALLOW', OWNER, mocks(OWNER, group(50))],
  ['OK      an admin of a 120-member group', 'ALLOW', 'ALLOW', ADMIN, mocks(ADMIN, group(120))],
  ['FIX     the owner of a 49-member group', 'ALLOW', 'DENY', OWNER, mocks(OWNER, group(49))],
  ['FIX     an admin of a 3-member group', 'ALLOW', 'DENY', ADMIN, mocks(ADMIN, group(3))],
  ['OK      an APP admin, 3-member group they own', 'ALLOW', 'ALLOW', OWNER, mocks(OWNER, group(3), { appAdmin: true })],
  ['OK      the panel lowers it to 5: a 6-member group', 'ALLOW', 'ALLOW', OWNER, mocks(OWNER, group(6), { config: { group_story_min_members: 5 } })],
  ['FIX     the panel raises it to 200: a 120-member group', 'ALLOW', 'DENY', OWNER, mocks(OWNER, group(120), { config: { group_story_min_members: 200 } })],
  ['GUARD   an APP admin who is not in the group', 'DENY', 'DENY', 'uidStranger', mocks('uidStranger', group(3), { appAdmin: true })],
];

async function run(t, source, [, , , uid, m], expectation) {
  const testCase = { expectation, functionMocks: [...m, { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }],
    request: { auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, path: `${D}/stories/${SID}`, method: 'create',
      time: REQ_TIME, resource: { data: story(uid) } } };
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST', headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ source: { files: [{ name: 'firestore.rules', content: source }] }, testSuite: { testCases: [testCase] } }),
  });
  const j = await r.json();
  if (j.error) return { state: 'APIERROR', detail: JSON.stringify(j.error).slice(0, 300) };
  const res = j.testResults && j.testResults[0];
  return { state: (res && res.state) || 'NORESULT', detail: res && res.errorPosition ? `line ${res.errorPosition.line}` : '' };
}

(async () => {
  const t = await token();
  const before = fs.readFileSync(BEFORE, 'utf8'), after = fs.readFileSync(AFTER, 'utf8');
  let pass = 0, fail = 0;
  for (const c of cases) {
    const o = await run(t, before, c, c[1]), n = await run(t, after, c, c[2]);
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c[1].padEnd(5)}→${c[2].padEnd(5)}  ${c[0]}`);
    if (!ok) console.log(`        before ${o.state} ${o.detail} | after ${n.state} ${n.detail}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
