// owner 2026-10-18 Role: a member's tag in the group (`roles.{uid}` = {text, emoji?}), given ONLY by
// an admin (roleWriteOK). The owner sets anyone's; an admin needs change-info and never sets the
// owner's; members never set their own. Also: the self-set Member Label it replaces is closed to
// plain members. Each row runs against the rules BEFORE the change and AFTER it. README: plain
// JSON, mock every get().
//
//   node role-1018.test.js before-role.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node role-1018.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', LIMITED = 'uidLimited', MEMBER = 'uidMember', GONE = 'uidGone';
const CID = 'grpRole1';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;

const users = [OWNER, ADMIN, LIMITED, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN, LIMITED], createdBy: OWNER,
  // LIMITED is an admin without the change-info right.
  adminRights: { [LIMITED]: ['inviteUsers'] },
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME, ...over,
});
const convMocks = (data) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);
// A role write as the app makes it: the one role, and `roleEdit` naming who it is about.
const give = (by, who, role, base = {}) => group({
  ...base,
  roles: { ...(base.roles || {}), [who]: role },
  roleEdit: { uid: who, by },
});
const R = { text: 'Designer', emoji: '🎨' };
const g = group();
const withRole = group({ roles: { [MEMBER]: R } });
const withGone = group({ roles: { [GONE]: R } });
const cleared = (by, who, base) => {
  const roles = { ...base.roles }; delete roles[who];
  return group({ roles, roleEdit: { uid: who, by } });
};

// A plain 1:1 the two may write any field of (the HEAD 1:1 branch).
const dmPath = `${D}/conversations/dmRole1`;
const dm = (over = {}) => ({
  type: 'direct', users: [OWNER, MEMBER], accepted: true, startedBy: OWNER, lastSender: MEMBER,
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME, ...over,
});
const dmMocks = (data) => ([
  { function: 'get', args: [{ exactValue: dmPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: dmPath }], result: { value: true } },
]);

const cases = [
  // ── who may give a role ──
  ['OK      the owner gives a member a role', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', give(OWNER, MEMBER, R), g, convMocks(g)],
  ['OK      the owner gives an admin a role', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', give(OWNER, ADMIN, R), g, convMocks(g)],
  ['OK      the owner gives themselves a role', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', give(OWNER, OWNER, R), g, convMocks(g)],
  ['OK      an admin with change-info gives a member a role', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update', give(ADMIN, MEMBER, R), g, convMocks(g)],
  ['OK      ... text only, no emoji', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update', give(ADMIN, MEMBER, { text: 'Designer' }), g, convMocks(g)],
  ['OK      ... a flag emoji (several characters underneath)', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update',
    give(ADMIN, MEMBER, { text: 'Lead', emoji: '🇸🇴' }), g, convMocks(g)],
  ['OK      ... exactly 24 characters', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update', give(ADMIN, MEMBER, { text: 'x'.repeat(24) }), g, convMocks(g)],
  ['FIX     an admin WITHOUT change-info gives a member a role', 'ALLOW', 'DENY', LIMITED, convPath, 'update', give(LIMITED, MEMBER, R), g, convMocks(g)],
  ['FIX     an admin gives the OWNER a role', 'ALLOW', 'DENY', ADMIN, convPath, 'update', give(ADMIN, OWNER, R), g, convMocks(g)],
  ['FIX     an admin changes the owner\'s role', 'ALLOW', 'DENY', ADMIN, convPath, 'update',
    give(ADMIN, OWNER, { text: 'Gone' }, group({ roles: { [OWNER]: R } })), group({ roles: { [OWNER]: R } }), convMocks(group({ roles: { [OWNER]: R } }))],
  ['GUARD   a member gives themselves a role', 'DENY', 'DENY', MEMBER, convPath, 'update', give(MEMBER, MEMBER, R), g, convMocks(g)],
  ['GUARD   a member gives someone else a role', 'DENY', 'DENY', MEMBER, convPath, 'update', give(MEMBER, ADMIN, R), g, convMocks(g)],
  ['GUARD   a member removes their own role', 'DENY', 'DENY', MEMBER, convPath, 'update', cleared(MEMBER, MEMBER, withRole), withRole, convMocks(withRole)],
  // ── the shape ──
  ['FIX     25 characters', 'ALLOW', 'DENY', ADMIN, convPath, 'update', give(ADMIN, MEMBER, { text: 'x'.repeat(25) }), g, convMocks(g)],
  ['FIX     an emoji with no words', 'ALLOW', 'DENY', ADMIN, convPath, 'update', give(ADMIN, MEMBER, { text: '', emoji: '🎨' }), g, convMocks(g)],
  ['FIX     an emoji field 17 long', 'ALLOW', 'DENY', ADMIN, convPath, 'update', give(ADMIN, MEMBER, { text: 'Lead', emoji: 'x'.repeat(17) }), g, convMocks(g)],
  ['FIX     an extra key in the role', 'ALLOW', 'DENY', ADMIN, convPath, 'update', give(ADMIN, MEMBER, { text: 'Lead', badge: 'x' }), g, convMocks(g)],
  ['OK      a role with a colour (2026-10-20)', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update', give(ADMIN, MEMBER, { text: 'Lead', color: 'red' }), g, convMocks(g)],
  ['FIX     a role that is a plain string', 'ALLOW', 'DENY', ADMIN, convPath, 'update', give(ADMIN, MEMBER, 'Lead'), g, convMocks(g)],
  ['FIX     a role for someone not in the group', 'ALLOW', 'DENY', ADMIN, convPath, 'update', give(ADMIN, GONE, R), g, convMocks(g)],
  // ── one person per write, named honestly ──
  ['FIX     two roles in one write', 'ALLOW', 'DENY', ADMIN, convPath, 'update',
    group({ roles: { [MEMBER]: R, [LIMITED]: R }, roleEdit: { uid: MEMBER, by: ADMIN } }), g, convMocks(g)],
  ['FIX     roleEdit names someone else than the changed role', 'ALLOW', 'DENY', ADMIN, convPath, 'update',
    group({ roles: { [OWNER]: R }, roleEdit: { uid: MEMBER, by: ADMIN } }), g, convMocks(g)],
  ['FIX     roleEdit.by is not the writer', 'ALLOW', 'DENY', ADMIN, convPath, 'update',
    group({ roles: { [MEMBER]: R }, roleEdit: { uid: MEMBER, by: OWNER } }), g, convMocks(g)],
  ['FIX     no roleEdit at all', 'ALLOW', 'DENY', ADMIN, convPath, 'update', group({ roles: { [MEMBER]: R } }), g, convMocks(g)],
  // ── removing ──
  ['OK      an admin removes a member\'s role', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update', cleared(ADMIN, MEMBER, withRole), withRole, convMocks(withRole)],
  ['OK      an admin clears the role of someone who left', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update', cleared(ADMIN, GONE, withGone), withGone, convMocks(withGone)],
  ['FIX     an admin without change-info removes a role', 'ALLOW', 'DENY', LIMITED, convPath, 'update', cleared(LIMITED, MEMBER, withRole), withRole, convMocks(withRole)],
  // ── everything else still works next to a role ──
  ['OK      a member sends in a group that has roles', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update',
    { ...withRole, roleEdit: { uid: MEMBER, by: ADMIN }, lastMessage: 'hi', lastSender: MEMBER },
    { ...withRole, roleEdit: { uid: MEMBER, by: ADMIN } }, convMocks({ ...withRole, roleEdit: { uid: MEMBER, by: ADMIN } })],
  ['OK      an admin renames a group that has roles', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update',
    { ...withRole, title: 'New' }, withRole, convMocks(withRole)],
  // ── 1:1 never ──
  ['FIX     a 1:1 member writes a role', 'ALLOW', 'DENY', OWNER, dmPath, 'update',
    dm({ roles: { [MEMBER]: R }, roleEdit: { uid: MEMBER, by: OWNER } }), dm(), dmMocks(dm())],
  ['OK      a 1:1 send still works', 'ALLOW', 'ALLOW', OWNER, dmPath, 'update',
    dm({ lastMessage: 'hi', lastSender: OWNER }), dm(), dmMocks(dm())],
  // ── the Member Label it replaces ──
  ['FIX     a member sets their own Member Label', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    group({ memberLabels: { [MEMBER]: 'Designer' } }), g, convMocks(g)],
  ['FIX     an admin without change-info labels themselves', 'ALLOW', 'DENY', LIMITED, convPath, 'update',
    group({ memberLabels: { [LIMITED]: 'Helper' } }), g, convMocks(g)],
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
  return { state: (res && res.state) || 'NORESULT', detail: ((res && res.debugMessages) || []).join(' | ').slice(0, 300) };
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
