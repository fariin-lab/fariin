// owner 2026-10-25: TRANSFER OWNERSHIP IS THE SERVER'S ALONE. A client write may move `createdBy` only
// as the owner leaves (ChatService.leaveGroup's hand-off); the owner staying in the group and
// handing it on goes through groups:transferGroupOwnership (password proven). Each row runs against
// the rules BEFORE the change and AFTER it. Plain JSON, mock every get().
//
//   git show HEAD:firestore.rules > before-owner-transfer.rules
//   node owner-transfer-1025.test.js before-owner-transfer.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
// The edit adds no get()/exists() to the conversation update path.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node owner-transfer-1025.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember', OTHER = 'uidOther';
const CID = 'grpOwner1';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;
const ALL = ['changeInfo', 'deleteMessages', 'banUsers', 'inviteUsers', 'pinMessages', 'manageCalls', 'postStories', 'addAdmins'];
const DEF = ALL.filter((r) => r !== 'addAdmins');

const users = [OWNER, ADMIN, MEMBER, OTHER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN], createdBy: OWNER,
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME, ...over,
});

// The old app's client transfer: the owner stays and hands the group to ADMIN.
const clientTransfer = group({ createdBy: ADMIN, adminRights: { [OWNER]: ALL }, adminBy: { [OWNER]: ADMIN },
  lastMessage: `${ADMIN} is now the owner`, lastSender: OWNER });
// The owner leaves and the longest-serving admin inherits (leaveGroup).
const ownerLeaves = group({ users: [ADMIN, MEMBER, OTHER], admins: [ADMIN], createdBy: ADMIN,
  lastMessage: `${OWNER} left`, lastSender: OWNER });
// The owner, the only admin, leaves: the first member is made admin and owner.
const soloBefore = group({ admins: [OWNER] });
const soloAfter = group({ users: [ADMIN, MEMBER, OTHER], admins: [ADMIN], createdBy: ADMIN,
  lastMessage: `${OWNER} left`, lastSender: OWNER });
// After a server transfer: ADMIN owns it, OWNER is an ordinary admin.
const afterServer = group({ createdBy: ADMIN, adminRights: { [OWNER]: DEF } });
// A former owner left with every right by an older build, appointed by the new owner.
const afterOldBuild = group({ createdBy: ADMIN, adminRights: { [OWNER]: ALL }, adminBy: { [OWNER]: ADMIN } });

const mocks = [
  { function: 'get', args: [{ exactValue: `${D}/config/limits` }], result: { value: null } },
];

// [name, before, after, uid, newData, oldData]
const cases = [
  ['CHANGE  owner transfers by a client write (stays in the group)', 'ALLOW', 'DENY', OWNER, clientTransfer, group()],
  ['CHANGE  owner names a plain member owner directly', 'ALLOW', 'DENY', OWNER,
    group({ createdBy: MEMBER, admins: [OWNER, ADMIN, MEMBER] }), group()],
  ['GUARD   an admin makes themselves owner', 'DENY', 'DENY', ADMIN, group({ createdBy: ADMIN }), group()],
  ['GUARD   an admin with every right makes themselves owner', 'DENY', 'DENY', ADMIN,
    group({ createdBy: ADMIN, adminRights: { [ADMIN]: ALL } }), group({ adminRights: { [ADMIN]: ALL } })],
  ['GUARD   former owner (all rights, old build) transfers again', 'DENY', 'DENY', OWNER,
    { ...afterOldBuild, createdBy: OTHER, admins: [OWNER, ADMIN, OTHER] }, afterOldBuild],
  ['GUARD   former owner (server defaults) transfers again', 'DENY', 'DENY', OWNER,
    { ...afterServer, createdBy: OTHER, admins: [OWNER, ADMIN, OTHER] }, afterServer],
  ['OK      owner leaves, an admin inherits (leaveGroup)', 'ALLOW', 'ALLOW', OWNER, ownerLeaves, group()],
  ['OK      owner leaves, a member is made admin and owner', 'ALLOW', 'ALLOW', OWNER, soloAfter, soloBefore],
  ['OK      an admin renames the group', 'ALLOW', 'ALLOW', ADMIN, group({ title: 'New name' }), group()],
  ['OK      the owner renames the group', 'ALLOW', 'ALLOW', OWNER, group({ title: 'New name' }), group()],
  ['OK      the owner promotes a member', 'ALLOW', 'ALLOW', OWNER,
    group({ admins: [OWNER, ADMIN, MEMBER], adminRights: { [MEMBER]: DEF }, adminBy: { [MEMBER]: OWNER },
            adminEdit: { uid: MEMBER, by: OWNER } }), group()],
  ['GUARD   former owner (server defaults) promotes a member', 'DENY', 'DENY', OWNER,
    { ...afterServer, admins: [OWNER, ADMIN, MEMBER], adminRights: { [OWNER]: DEF, [MEMBER]: ['pinMessages'] },
      adminBy: { [MEMBER]: OWNER }, adminEdit: { uid: MEMBER, by: OWNER } }, afterServer],
];

async function run(t, source, [, , , uid, after, before], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: convPath, method: 'update', time: REQ_TIME, resource: { data: after },
  };
  const testCase = { expectation, request, resource: { data: before },
    functionMocks: [...mocks, { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
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
