// 2026-10-31 owner's pre-launch pass: what an ordinary account can do to a group it is in, or not in,
// by writing to the database directly instead of through the app. Every DENY has an ALLOW control
// next to it, so a run where the mocks are wrong shows up as a failed control, not as a pass.
const fs = require('fs'); const { token } = require('./auth');
const SRC = fs.readFileSync(process.argv[2] || '../firestore.rules', 'utf8');
const D = '/databases/(default)/documents';
const OWNER = 'uidOWNER', AD = 'uidADMIN', M = 'uidMEMBER', X = 'uidSTRANGER', B = 'uidBANNED', N = 'uidNEW';
const CID = 'grpCID1';
const T = new Date().toISOString();
const group = {
  type: 'group', users: [OWNER, AD, M], admins: [OWNER, AD], createdBy: OWNER, title: 'Team',
  names: { [OWNER]: 'O', [AD]: 'A', [M]: 'M' }, photos: {}, bannedUids: [B], e2ee: false,
  onlyAdminsSend: false, membersCanAdd: false, membersCanEditInfo: false, isPublic: false,
};
const adminsOnly = { ...group, onlyAdminsSend: true };
const msgM = { authorId: M, type: 'text', text: 'hello', createdAt: T };
const msgO = { authorId: OWNER, type: 'text', text: 'from owner', createdAt: T };
const many = Array.from({ length: 300 }, (_, i) => `uidSPAM${i}`);

const P1 = 'uidP1', P2 = 'uidP2', P3 = 'uidP3', BLK = 'uidBLOCKSOWNER';
function mocks(conv, msg) {
  const people = [OWNER, AD, M, X, B, N, P1, P2, P3, BLK];
  const blocks = people.flatMap(a => people.map(b => ({ function: 'exists',
    args: [{ exactValue: `${D}/users/${a}/blocked/${b}` }], result: { value: a === BLK && b === OWNER } })));
  return [
    ...blocks,
    { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: false } },
    ...people.flatMap(u => [
      { function: 'exists', args: [{ exactValue: `${D}/users/${u}` }], result: { value: true } },
      { function: 'get', args: [{ exactValue: `${D}/users/${u}` }], result: { value: { data: { name: u } } } },
      { function: 'exists', args: [{ exactValue: `${D}/admins/${u}` }], result: { value: false } },
      { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}/followers/${u}` }], result: { value: false } },
    ]),
    { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: true } },
    { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data: conv } } },
    { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}/messages/m1` }], result: { value: { data: msg || msgM } } },
    { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}/messages/m1` }], result: { value: true } },
  ];
}
const without = (a, x) => a.filter((u) => u !== x);

// [name, expectation, uid, method, path, resource, newData, conv, msgForGet]
const cases = [
  // reading
  ['member reads the group (control)', 'ALLOW', M, 'get', `conversations/${CID}`, group, null, group],
  ['stranger reads a private group', 'DENY', X, 'get', `conversations/${CID}`, group, null, group],
  ['stranger reads a private group message', 'DENY', X, 'get', `conversations/${CID}/messages/m1`, msgM, null, group],
  // joining without being let in
  ['owner adds a person (control)', 'ALLOW', OWNER, 'update', `conversations/${CID}`, group, { ...group, users: [...group.users, N] }, group],
  ['stranger adds themselves', 'DENY', X, 'update', `conversations/${CID}`, group, { ...group, users: [...group.users, X] }, group],
  ['banned person adds themselves back', 'DENY', B, 'update', `conversations/${CID}`, group, { ...group, users: [...group.users, B] }, group],
  ['member adds someone when only admins may', 'DENY', M, 'update', `conversations/${CID}`, group, { ...group, users: [...group.users, N] }, group],
  ['member lifts a ban', 'DENY', M, 'update', `conversations/${CID}`, group, { ...group, bannedUids: [] }, group],
  ['owner adds someone who blocked the owner', 'DENY', OWNER, 'update', `conversations/${CID}`, group, { ...group, users: [...group.users, BLK] }, group],
  ['owner adds three people (control)', 'ALLOW', OWNER, 'update', `conversations/${CID}`, group, { ...group, users: [...group.users, P1, P2, P3] }, group],
  // ALLOW at the rules (they look up the first three only, Google's lookup budget); the groups
  // function refuseBlockedAdds then takes out EVERY added person who blocked the adder.
  ['owner adds 3 people then someone who blocked the owner', 'ALLOW', OWNER, 'update', `conversations/${CID}`, group, { ...group, users: [...group.users, P1, P2, P3, BLK] }, group],
  // taking power
  ['member makes themselves admin', 'DENY', M, 'update', `conversations/${CID}`, group, { ...group, admins: [...group.admins, M] }, group],
  ['member makes themselves owner', 'DENY', M, 'update', `conversations/${CID}`, group, { ...group, createdBy: M }, group],
  ['admin makes themselves owner', 'DENY', AD, 'update', `conversations/${CID}`, group, { ...group, createdBy: AD }, group],
  ['admin removes the owner', 'DENY', AD, 'update', `conversations/${CID}`, group, { ...group, users: without(group.users, OWNER), admins: without(group.admins, OWNER) }, group],
  ['admin strips the owner of admin', 'DENY', AD, 'update', `conversations/${CID}`, group, { ...group, admins: without(group.admins, OWNER) }, group],
  ['member removes another member', 'DENY', M, 'update', `conversations/${CID}`, group, { ...group, users: without(group.users, AD) }, group],
  ['member leaves (control)', 'ALLOW', M, 'update', `conversations/${CID}`, group, { ...group, users: without(group.users, M) }, group],
  // changing the group behind the owner's back
  ['member renames when members may not', 'DENY', M, 'update', `conversations/${CID}`, group, { ...group, title: 'Hacked' }, group],
  ['member opens sending to all', 'DENY', M, 'update', `conversations/${CID}`, adminsOnly, { ...adminsOnly, onlyAdminsSend: false }, adminsOnly],
  ['member makes the group public', 'DENY', M, 'update', `conversations/${CID}`, group, { ...group, isPublic: true }, group],
  ['admin gives the group a verified badge', 'DENY', OWNER, 'update', `conversations/${CID}`, group, { ...group, verified: true }, group],
  // posting
  ['member posts (control)', 'ALLOW', M, 'create', `conversations/${CID}/messages/m2`, null, { authorId: M, type: 'text', text: 'hi', createdAt: T }, group],
  ['member posts as someone else', 'DENY', M, 'create', `conversations/${CID}/messages/m2`, null, { authorId: OWNER, type: 'text', text: 'hi', createdAt: T }, group],
  ['member posts where only admins send', 'DENY', M, 'create', `conversations/${CID}/messages/m2`, null, { authorId: M, type: 'text', text: 'hi', createdAt: T }, adminsOnly],
  ['banned person posts', 'DENY', B, 'create', `conversations/${CID}/messages/m2`, null, { authorId: B, type: 'text', text: 'hi', createdAt: T }, group],
  ['stranger posts', 'DENY', X, 'create', `conversations/${CID}/messages/m2`, null, { authorId: X, type: 'text', text: 'hi', createdAt: T }, group],
  ['member edits their own text (control)', 'ALLOW', M, 'update', `conversations/${CID}/messages/m1`, msgM, { ...msgM, text: 'fixed', edited: true }, group, msgM],
  ['member edits the owner\'s message', 'DENY', M, 'update', `conversations/${CID}/messages/m1`, msgO, { ...msgO, text: 'fake', edited: true }, group, msgO],
  ['member deletes the owner\'s message', 'DENY', M, 'delete', `conversations/${CID}/messages/m1`, msgO, null, group, msgO],
  // mass adding to spam
  ['someone makes a group with 300 strangers in it', 'DENY', X, 'create', `conversations/grpNEW2`, null,
    { type: 'group', users: [X, ...many], admins: [X], createdBy: X, title: 'Win money', names: {}, photos: {}, e2ee: false }, group],
  ['someone makes a group of only other people', 'DENY', X, 'create', `conversations/grpNEW3`, null,
    { type: 'group', users: [M, OWNER], admins: [M], createdBy: M, title: 'x', names: {}, photos: {}, e2ee: false }, group],
  ['someone makes a chat between two other people', 'DENY', X, 'create', `conversations/${M}_${OWNER}`, null,
    { type: 'direct', users: [M, OWNER], names: {}, photos: {} }, group],
];

(async () => {
  const t = await token();
  let bad = 0;
  for (const [name, exp, uid, method, path, res, after, conv, msg] of cases) {
    const request = { auth: { uid, token: { firebase: { sign_in_provider: 'password' }, email_verified: true } }, path: `${D}/${path}`, method, time: T };
    if (after) request.resource = { data: after };
    const testCase = { expectation: 'ALLOW', request, functionMocks: mocks(conv, msg) };
    if (res) testCase.resource = { data: res };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', { method: 'POST', headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: { files: [{ name: 'firestore.rules', content: SRC }] }, testSuite: { testCases: [testCase] } }) });
    const j = await r.json(); const tr = j.testResults && j.testResults[0];
    const got = (tr && tr.state === 'SUCCESS') ? 'ALLOW' : 'DENY';
    if (got !== exp) bad++;
    console.log(got === exp ? 'ok  ' : 'BAD ', got.padEnd(5), name, j.error ? JSON.stringify(j.error).slice(0, 200) : '',
      got !== exp && tr && tr.debugMessages ? tr.debugMessages.join(' | ').slice(0, 300) : '');
  }
  console.log(bad ? `${bad} unexpected` : 'all as expected');
})();
