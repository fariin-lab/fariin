// owner 2026-10-18: GROUP OWNER AND ADMIN RIGHTS, the reference app's logic. The owner keeps
// ultimate control; an admin given "Add new admins" (`addAdmins`) may promote members with at most
// their own rights and manage only the admins they promoted (`adminBy`); nobody but the owner may
// touch the owner, remove another admin, or move ownership, and the owner may now transfer it while
// staying. Each row runs against the rules BEFORE the change and AFTER it. README: plain JSON, mock
// every get().
//
//   node group-admin-rights-1018.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-admin-rights-1018.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', DELEG = 'uidDeleg', LIMITED = 'uidLimited';
const PROMO = 'uidPromo', OWNPROMO = 'uidOwnPromo', MEMBER = 'uidMember', MEMBER2 = 'uidMember2';
const OUTSIDER = 'uidOutsider';
const CID = 'grpRights1';
const REQ_TIME = new Date().toISOString();
const convPath = `${D}/conversations/${CID}`;

const users = [OWNER, ADMIN, DELEG, LIMITED, PROMO, OWNPROMO, MEMBER, MEMBER2];
// ADMIN: legacy, no entry. DELEG: holds addAdmins. PROMO: DELEG's appointee. OWNPROMO: the owner's.
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN, DELEG, LIMITED, PROMO, OWNPROMO], createdBy: OWNER,
  adminRights: {
    [DELEG]: ['changeInfo', 'inviteUsers', 'addAdmins'],
    [LIMITED]: ['inviteUsers'],
    [PROMO]: ['changeInfo'],
    [OWNPROMO]: ['pinMessages'],
  },
  adminBy: { [PROMO]: DELEG, [OWNPROMO]: OWNER },
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME, ...over,
});
const convMocks = (data) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);
const g = group();
const without = (list, ...gone) => list.filter((u) => !gone.includes(u));
const omit = (m, k) => { const c = { ...m }; delete c[k]; return c; };
const edit = (uid, by) => ({ adminEdit: { uid, by } });
const promote = (who, rights, by, extra = {}) => group({
  admins: [...g.admins, who], adminRights: { ...g.adminRights, [who]: rights },
  adminBy: { ...g.adminBy, [who]: by }, ...edit(who, by), ...extra,
});
const demote = (who, by) => group({
  admins: without(g.admins, who), adminRights: omit(g.adminRights, who),
  adminBy: omit(g.adminBy, who), ...edit(who, by),
});
const setRights = (who, rights, by) => group({ adminRights: { ...g.adminRights, [who]: rights }, ...edit(who, by) });
const removeFromGroup = (who) => group({
  users: without(users, who), admins: without(g.admins, who), bannedUids: [who],
  adminRights: omit(g.adminRights, who), adminBy: omit(g.adminBy, who),
});
// After the owner handed the group to ADMIN and stayed (ChatService.transferGroupOwnership).
const transferred = group({
  createdBy: ADMIN,
  adminRights: { ...g.adminRights, [OWNER]: ['changeInfo', 'deleteMessages', 'banUsers', 'inviteUsers', 'pinMessages', 'manageCalls', 'addAdmins'] },
  adminBy: { ...g.adminBy, [OWNER]: ADMIN },
});

const U = (name, b, a, uid, after, before = g) => [name, b, a, uid, convPath, 'update', after, before, convMocks(before)];
const ALL_BUT_ADD = ['changeInfo', 'deleteMessages', 'banUsers', 'inviteUsers', 'pinMessages', 'manageCalls'];
const cases = [
  // ── the owner runs the team ──
  U('OK      the owner promotes a member with the defaults', 'ALLOW', 'ALLOW', OWNER, promote(MEMBER, ALL_BUT_ADD, OWNER)),
  U('OK      the owner demotes a legacy admin', 'ALLOW', 'ALLOW', OWNER, demote(ADMIN, OWNER)),
  U('OK      the owner demotes an admin another admin promoted', 'ALLOW', 'ALLOW', OWNER, demote(PROMO, OWNER)),
  U('OK      the owner changes an admin\'s rights', 'ALLOW', 'ALLOW', OWNER, setRights(LIMITED, ['inviteUsers', 'pinMessages'], OWNER)),
  U('OK      the owner removes an admin from the group', 'ALLOW', 'ALLOW', OWNER, removeFromGroup(ADMIN)),
  // ── an admin with "Add new admins" ──
  U('NEW     add-admins admin promotes a member with a right they hold', 'DENY', 'ALLOW', DELEG, promote(MEMBER, ['changeInfo'], DELEG)),
  U('NEW     add-admins admin passes on add-admins itself', 'DENY', 'ALLOW', DELEG, promote(MEMBER, ['inviteUsers', 'addAdmins'], DELEG)),
  U('GUARD   ...with a right they do NOT hold', 'DENY', 'DENY', DELEG, promote(MEMBER, ['deleteMessages'], DELEG)),
  U('GUARD   ...with no rights entry (= the defaults)', 'DENY', 'DENY', DELEG,
    group({ admins: [...g.admins, MEMBER], adminBy: { ...g.adminBy, [MEMBER]: DELEG }, ...edit(MEMBER, DELEG) })),
  U('GUARD   ...without naming the person in adminEdit', 'DENY', 'DENY', DELEG,
    group({ admins: [...g.admins, MEMBER], adminRights: { ...g.adminRights, [MEMBER]: ['changeInfo'] }, adminBy: { ...g.adminBy, [MEMBER]: DELEG } })),
  U('GUARD   ...saying the owner promoted them', 'DENY', 'DENY', DELEG, promote(MEMBER, ['changeInfo'], OWNER, edit(MEMBER, DELEG))),
  U('GUARD   ...two people in one write', 'DENY', 'DENY', DELEG,
    group({ admins: [...g.admins, MEMBER, MEMBER2], adminRights: { ...g.adminRights, [MEMBER]: ['changeInfo'], [MEMBER2]: ['changeInfo'] },
            adminBy: { ...g.adminBy, [MEMBER]: DELEG, [MEMBER2]: DELEG }, ...edit(MEMBER, DELEG) })),
  U('GUARD   ...someone who is not in the group', 'DENY', 'DENY', DELEG, promote(OUTSIDER, ['changeInfo'], DELEG)),
  U('NEW     add-admins admin changes the rights of their own appointee', 'DENY', 'ALLOW', DELEG, setRights(PROMO, ['inviteUsers'], DELEG)),
  U('NEW     add-admins admin demotes their own appointee', 'DENY', 'ALLOW', DELEG, demote(PROMO, DELEG)),
  U('GUARD   add-admins admin demotes the owner\'s appointee', 'DENY', 'DENY', DELEG, demote(OWNPROMO, DELEG)),
  U('GUARD   add-admins admin demotes a legacy admin', 'DENY', 'DENY', DELEG, demote(ADMIN, DELEG)),
  U('GUARD   add-admins admin changes the owner\'s appointee\'s rights', 'DENY', 'DENY', DELEG, setRights(OWNPROMO, ['changeInfo'], DELEG)),
  U('GUARD   add-admins admin gives themselves a right', 'DENY', 'DENY', DELEG, setRights(DELEG, ['changeInfo', 'inviteUsers', 'addAdmins', 'banUsers'], DELEG)),
  U('GUARD   add-admins admin demotes the owner', 'DENY', 'DENY', DELEG,
    group({ admins: without(g.admins, OWNER), ...edit(OWNER, DELEG) })),
  U('GUARD   add-admins admin gives the owner a rights entry', 'DENY', 'DENY', DELEG, setRights(OWNER, ['changeInfo'], DELEG)),
  U('GUARD   add-admins admin takes ownership', 'DENY', 'DENY', DELEG, group({ createdBy: DELEG })),
  U('GUARD   add-admins admin removes the owner from the group', 'DENY', 'DENY', DELEG,
    group({ users: without(users, OWNER), admins: without(g.admins, OWNER) })),
  // ── admins without it ──
  U('GUARD   a legacy admin promotes a member', 'DENY', 'DENY', ADMIN, promote(MEMBER, ['changeInfo'], ADMIN)),
  U('GUARD   a limited admin promotes a member', 'DENY', 'DENY', LIMITED, promote(MEMBER, ['inviteUsers'], LIMITED)),
  U('FIX     a limited admin writes adminEdit alone', 'ALLOW', 'DENY', LIMITED, group(edit(MEMBER, LIMITED))),
  U('GUARD   a legacy admin demotes the owner\'s appointee', 'DENY', 'DENY', ADMIN, demote(OWNPROMO, ADMIN)),
  U('FIX     a legacy admin removes ANOTHER ADMIN from the group', 'ALLOW', 'DENY', ADMIN, removeFromGroup(OWNPROMO)),
  U('OK      a legacy admin removes a member from the group', 'ALLOW', 'ALLOW', ADMIN, removeFromGroup(MEMBER)),
  U('OK      a legacy admin changes the title', 'ALLOW', 'ALLOW', ADMIN, group({ title: 'New' })),
  U('OK      an admin leaves the group', 'ALLOW', 'ALLOW', DELEG,
    group({ users: without(users, DELEG), admins: without(g.admins, DELEG) })),
  // ── Removed Users: letting someone back (ChatService.unbanGroupMember) ──
  U('OK      a legacy admin lets a removed person back', 'ALLOW', 'ALLOW', ADMIN,
    group({ bannedUids: [] }), group({ bannedUids: [OUTSIDER] })),
  U('OK      an add-members admin lets a removed person back', 'ALLOW', 'ALLOW', LIMITED,
    group({ bannedUids: [] }), group({ bannedUids: [OUTSIDER] })),
  U('GUARD   an admin with neither right lets them back', 'DENY', 'DENY', PROMO,
    group({ bannedUids: [] }), group({ bannedUids: [OUTSIDER] })),
  U('GUARD   a member lets them back', 'DENY', 'DENY', MEMBER,
    group({ bannedUids: [] }), group({ bannedUids: [OUTSIDER] })),
  // ── members ──
  U('GUARD   a member promotes themselves', 'DENY', 'DENY', MEMBER, promote(MEMBER, ['changeInfo'], MEMBER)),
  U('GUARD   a member writes adminBy', 'DENY', 'DENY', MEMBER, group({ adminBy: { ...g.adminBy, [MEMBER]: OWNER } })),
  // ── ownership ──
  U('NEW     the owner transfers to an admin and stays', 'DENY', 'ALLOW', OWNER, transferred),
  U('NEW     the owner transfers to a member (made admin) and stays', 'DENY', 'ALLOW', OWNER,
    group({ createdBy: MEMBER, admins: [...g.admins, MEMBER] })),
  U('GUARD   the owner transfers to a member without making them admin', 'DENY', 'DENY', OWNER, group({ createdBy: MEMBER })),
  U('GUARD   the owner transfers to an outsider', 'DENY', 'DENY', OWNER,
    group({ createdBy: OUTSIDER, admins: [...g.admins, OUTSIDER] })),
  U('OK      the owner leaves, handing on to an admin', 'ALLOW', 'ALLOW', OWNER,
    group({ users: without(users, OWNER), admins: without(g.admins, OWNER), createdBy: ADMIN })),
  U('GUARD   the old owner (now an add-admins admin) demotes the new owner', 'DENY', 'DENY', OWNER,
    { ...transferred, admins: without(g.admins, ADMIN), ...edit(ADMIN, OWNER) }, transferred),
  U('GUARD   the old owner takes ownership back', 'DENY', 'DENY', OWNER, { ...transferred, createdBy: OWNER }, transferred),
  U('OK      the new owner demotes the old owner', 'ALLOW', 'ALLOW', ADMIN,
    { ...transferred, admins: without(g.admins, OWNER), adminRights: omit(transferred.adminRights, OWNER), adminBy: omit(transferred.adminBy, OWNER) },
    transferred),
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
