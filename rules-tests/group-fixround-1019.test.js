// 2026-10-19 group fix round: S1 (group notices need a reason), M1 (leaving always works), S2/S3
// ("Members can add": no banned uid, only the new people's keys), S4 (a member's send preview is
// their own), S7 (a member's unpin is only the clean-up after a delete), S8 (the creator is the
// owner), S10 (join requests read by the people who answer them). Each row runs against the rules
// BEFORE the change and AFTER it. README: plain JSON, mock every get() (and getAfter()).
//
//   node group-fixround-1019.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node group-fixround-1019.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember', NEW = 'uidNewOne', BANNED = 'uidBanned';
const CID = 'grpFix1';
const REQ_TIME = new Date().toISOString();
const LATER = 'later-stamp';
const convPath = `${D}/conversations/${CID}`;
const msgPath = `${D}/conversations/${CID}/messages/m9`;
const msgOf = (id) => `${D}/conversations/${CID}/messages/${id}`;
const reqPath = (u) => `${D}/conversations/${CID}/joinRequests/${u}`;

const users = [OWNER, ADMIN, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users, admins: [OWNER, ADMIN], createdBy: OWNER,
  names: Object.fromEntries(users.map((u) => [u, u])),
  photos: {},
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  bannedUids: [BANNED],
  pinnedMessageIds: ['p1', 'p2'],
  lastMessage: 'hi', lastSender: OWNER,
  updatedAt: REQ_TIME, ...over,
});
const fresh = (over = {}) => ({
  type: 'group', title: 'Plans', users: [OWNER, MEMBER], admins: [OWNER], createdBy: OWNER, createdAt: REQ_TIME,
  names: { [OWNER]: OWNER, [MEMBER]: MEMBER }, photos: {},
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, typing: { [OWNER]: false, [MEMBER]: false },
  updatedAt: REQ_TIME, ...over,
});
const convMocks = (data, after) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
  ...(after ? [{ function: 'getAfter', args: [{ exactValue: convPath }], result: { value: { data: after } } }] : []),
]);
const liveMsg = (id, deleted = false) => ([
  { function: 'exists', args: [{ exactValue: msgOf(id) }], result: { value: true } },
  { function: 'get', args: [{ exactValue: msgOf(id) }], result: { value: { data: { authorId: OWNER, deleted } } } },
]);
const notice = (author, text = 'X left') => ({ text, authorId: author, type: 'system', createdAt: 'x' });
const without = (u, d) => Object.assign({}, d, { users: d.users.filter((x) => x !== u), admins: d.admins.filter((x) => x !== u) });

// "Members can add" group, MEMBER adding NEW the way ChatService.addGroupMembers writes it.
const ca = group({ membersCanAdd: true });
const add = (over = {}, uid = NEW) => Object.assign(group({ membersCanAdd: true }), {
  users: [...users, uid],
  names: Object.assign({}, ca.names, { [uid]: 'New' }),
  unreadCount: Object.assign({}, ca.unreadCount, { [uid]: 0 }),
  lastMessage: 'M added New', lastSender: MEMBER, updatedAt: LATER,
}, over);

const g = group();
// The badges are left alone here so the badge rule (unreadUpdateOk) is not what decides.
const send = (over = {}) => Object.assign(group(), { lastMessage: 'encg1:abc', lastSender: MEMBER, updatedAt: LATER }, over);
const oas = group({ onlyAdminsSend: true });
const far = Date.now() + 3600 * 1000;
const muted = group({ restrictedFlags: { [MEMBER]: ['sendText'] }, restrictedUntil: { [MEMBER]: far } });
const susp = group({ mod: { state: 'suspended', until: null } });
const rightsOnly = (r) => group({ adminRights: { [ADMIN]: r } });

const cases = [
  // S8
  ['OK      a group create by its owner', 'ALLOW', 'ALLOW', OWNER, convPath, 'create', fresh(), null, null],
  ['FIX S8  a create that names somebody else the owner', 'ALLOW', 'DENY', OWNER, convPath, 'create',
    fresh({ createdBy: MEMBER, admins: [OWNER, MEMBER] }), null, null],
  // S2/S3
  ['OK      a member adds somebody (Members can add)', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update', add(), ca, convMocks(ca)],
  ['FIX S2  a member adds somebody the group removed', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    add({}, BANNED), ca, convMocks(ca)],
  ['FIX S3  a member adds and renames the owner', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    add({ names: Object.assign({}, ca.names, { [NEW]: 'New', [OWNER]: 'Fake' }) }), ca, convMocks(ca)],
  ['FIX S3  a member adds with a badge of 7', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    add({ unreadCount: Object.assign({}, ca.unreadCount, { [NEW]: 7 }) }), ca, convMocks(ca)],
  ['FIX S3  a member adds and moves the admin badge', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    add({ unreadCount: Object.assign({}, ca.unreadCount, { [NEW]: 0, [ADMIN]: 0, [OWNER]: 3 }) }), ca, convMocks(ca)],
  // S4
  ['OK      a member send preview', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update', send(), g, convMocks(g)],
  ['FIX S4  a member send preview naming the admin', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    send({ lastSender: ADMIN }), g, convMocks(g)],
  ['FIX S4  a member preview in an admins-only group', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    Object.assign(send(), { onlyAdminsSend: true }), oas, convMocks(oas)],
  ['FIX S4  a muted member writes a send preview', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    Object.assign(send(), { restrictedFlags: muted.restrictedFlags, restrictedUntil: muted.restrictedUntil }), muted, convMocks(muted)],
  ['OK      the summary rewrite after a delete (no updatedAt)', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update',
    group({ lastMessage: 'This message was deleted', lastSender: ADMIN }), g, convMocks(g)],
  ['OK      the admin\'s own send preview, admins-only group', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update',
    Object.assign(send({ lastSender: ADMIN }), { onlyAdminsSend: true }), oas, convMocks(oas)],
  // S7
  ['OK      a member\'s clean-up unpin of a deleted message', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update',
    group({ pinnedMessageIds: ['p2'] }), g, convMocks(g)],
  ['OK      a member\'s clean-up unpin of a tombstone', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update',
    group({ pinnedMessageIds: ['p2'] }), g, [...convMocks(g), ...liveMsg('p1', true)]],
  ['FIX S7  a member unpins a live message', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    group({ pinnedMessageIds: ['p2'] }), g, [...convMocks(g), ...liveMsg('p1')]],
  ['OK      a member\'s no-op unpin', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update', group(), g, convMocks(g)],
  ['OK      an admin with Pin messages unpins a live message', 'ALLOW', 'ALLOW', ADMIN, convPath, 'update',
    Object.assign(rightsOnly(['pinMessages']), { pinnedMessageIds: ['p2'] }), rightsOnly(['pinMessages']),
    [...convMocks(rightsOnly(['pinMessages'])), ...liveMsg('p1')]],
  ['FIX S7  an admin without Pin messages unpins a live message', 'ALLOW', 'DENY', ADMIN, convPath, 'update',
    Object.assign(rightsOnly(['changeInfo']), { pinnedMessageIds: ['p2'] }), rightsOnly(['changeInfo']),
    [...convMocks(rightsOnly(['changeInfo'])), ...liveMsg('p1')]],
  // M1
  ['FIX M1  leave notice, admins-only group', 'DENY', 'ALLOW', MEMBER, msgPath, 'create', notice(MEMBER), null,
    convMocks(oas, without(MEMBER, oas))],
  ['GUARD   a notice in an admins-only group, not leaving', 'DENY', 'DENY', MEMBER, msgPath, 'create', notice(MEMBER), null,
    convMocks(oas, oas)],
  ['FIX M1  leave notice, muted member', 'DENY', 'ALLOW', MEMBER, msgPath, 'create', notice(MEMBER), null,
    convMocks(muted, without(MEMBER, muted))],
  ['FIX M1  leave notice, suspended group', 'DENY', 'ALLOW', MEMBER, msgPath, 'create', notice(MEMBER), null,
    convMocks(susp, without(MEMBER, susp))],
  ['FIX M1  admin removal notice, suspended group', 'DENY', 'ALLOW', ADMIN, msgPath, 'create', notice(ADMIN, 'A removed M'), null,
    convMocks(susp, without(MEMBER, susp))],
  ['GUARD   admin notice, suspended group, no removal', 'DENY', 'DENY', ADMIN, msgPath, 'create', notice(ADMIN, 'A renamed'), null,
    convMocks(susp, susp)],
  ['GUARD   a member text, suspended group', 'DENY', 'DENY', MEMBER, msgPath, 'create',
    { text: 'encg1:abc', authorId: MEMBER, createdAt: 'x' }, null, convMocks(susp, without(MEMBER, susp))],
  // S1
  ['FIX S1  a plain member\'s made-up notice', 'ALLOW', 'DENY', MEMBER, msgPath, 'create',
    notice(MEMBER, 'Owner made M an admin'), null, convMocks(g, g)],
  ['OK      an admin\'s notice', 'ALLOW', 'ALLOW', ADMIN, msgPath, 'create', notice(ADMIN, 'A renamed'), null, convMocks(g, g)],
  ['OK      a member\'s notice with Members can edit info', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create',
    notice(MEMBER, 'M renamed'), null, convMocks(group({ membersCanEditInfo: true }), group({ membersCanEditInfo: true }))],
  ['OK      a member\'s add notice in the add batch', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create',
    notice(MEMBER, 'M added New'), null, convMocks(ca, add())],
  ['OK      a member\'s plain leave notice', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', notice(MEMBER), null,
    convMocks(g, without(MEMBER, g))],
  ['OK      a member text (no getAfter mocked)', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create',
    { text: 'encg1:abc', authorId: MEMBER, createdAt: 'x' }, null, convMocks(g)],
  ['GUARD   a notice signed by somebody else', 'DENY', 'DENY', MEMBER, msgPath, 'create', notice(OWNER), null, convMocks(g, g)],
  // S10
  ['FIX S10 a plain member reads a join request', 'ALLOW', 'DENY', MEMBER, reqPath(NEW), 'get', null, { uid: NEW }, convMocks(g)],
  ['OK      a full admin reads a join request', 'ALLOW', 'ALLOW', ADMIN, reqPath(NEW), 'get', null, { uid: NEW }, convMocks(g)],
  ['OK      an admin with Add members reads one', 'ALLOW', 'ALLOW', ADMIN, reqPath(NEW), 'get', null, { uid: NEW },
    convMocks(rightsOnly(['inviteUsers']))],
  ['FIX S10 an admin without Add members reads one', 'ALLOW', 'DENY', ADMIN, reqPath(NEW), 'get', null, { uid: NEW },
    convMocks(rightsOnly(['changeInfo']))],
  ['OK      the owner reads one', 'ALLOW', 'ALLOW', OWNER, reqPath(NEW), 'get', null, { uid: NEW }, convMocks(g)],
  ['FIX S10 the requester reads their own', 'DENY', 'ALLOW', NEW, reqPath(NEW), 'get', null, { uid: NEW }, convMocks(g)],
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
