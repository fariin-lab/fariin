// owner 2026-10-21: A CHAT STARTED WHILE MESSAGE REQUESTS WERE OFF STAYS OPEN (`reqOff`).
//
// What must hold:
//   - `reqOff: true` may be stamped (create, or the seed on an unspent pending 1:1) only while
//     requests are really off for the other member; never while on, never on a request already
//     sent, never taken off or set false;
//   - with the switch back ON, a reqOff chat's later messages pass from either side, while an
//     ordinary unanswered request still takes one message;
//   - the Chat Key (their privacy) still applies to a reqOff chat, and the starter still never
//     accepts their own request.
//
//   node reqoff-1021.test.js <before.rules> <after.rules>
//
// Nothing is deployed and nothing is written. resource.data is PLAIN JSON (README, trap 1).
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2] || '../scratchpad/before-msgpolicy.rules';
const AFTER = process.argv[3] || '../firestore.rules';

const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the stranger who writes first
const B = 'uidBBB';   // the person written to: their setting decides
const CID = [A, B].sort().join('_');

const REQ_TIME = new Date().toISOString();
const now = Date.parse(REQ_TIME);
const iso = (ms) => new Date(ms).toISOString();

const base = { users: [A, B], type: '', names: {}, photos: {}, blockedBy: {}, mutedBy: {},
               clearedAt: {}, lastRead: {}, unreadCount: {}, archivedBy: {}, pinnedBy: {} };
const fresh = { ...base, startedBy: A, accepted: false, lastSender: '' };   // A has not written yet
const spent = { ...fresh, lastSender: A };                                   // A has written once
const shortCipher = 'enc1:' + 'x'.repeat(120);

// ── mocks ──
// `pol` is B's per-person override (users/{B}.msgPolicy), `privacy` their Messages setting.
const userDoc = (uid, privacy = 'everyone', pol = null) => ([
  { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }],
    result: { value: { data: { banned: false, privacy: { messages: privacy }, ...(pol ? { msgPolicy: pol } : {}) } } } },
]);
const global = (g) => g == null
  ? [{ function: 'exists', args: [{ exactValue: `${D}/config/msgPolicy` }], result: { value: false } }]
  : [{ function: 'exists', args: [{ exactValue: `${D}/config/msgPolicy` }], result: { value: true } },
     { function: 'get', args: [{ exactValue: `${D}/config/msgPolicy` }], result: { value: { data: g } } }];
const notAdmin = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
]);
const convDoc = (data) => ([
  { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data } } },
]);
const noConv = [{ function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: false } }];
const neverDeclined = [{ function: 'exists', args: [{ exactValue: `${D}/requestDeclines/${B}/from/${A}` }], result: { value: false } }];
const budgetPath = `${D}/users/${A}/limits/requests`;
const budget = (count) => count == null
  ? [{ function: 'exists', args: [{ exactValue: budgetPath }], result: { value: false } },
     { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: false } }]
  : [{ function: 'exists', args: [{ exactValue: budgetPath }], result: { value: true } },
     { function: 'get', args: [{ exactValue: budgetPath }], result: { value: { data: { windowStart: iso(now - 3600e3), count } } } },
     { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: false } }];

const msgPath = `${D}/conversations/${CID}/messages/m1`;
const convPath = `${D}/conversations/${CID}`;
// A message from A into `conv`, B with `privacy`, global `g`, B's override `pol`.
const sendMocks = (conv, g, privacy = 'everyone', pol = null, count = null) =>
  [...convDoc(conv), ...userDoc(A), ...userDoc(B, privacy, pol), ...global(g), ...notAdmin(A), ...notAdmin(B), ...budget(count)];
const createMocks = (g, privacy = 'everyone', pol = null) =>
  [...noConv, ...userDoc(A), ...userDoc(B, privacy, pol), ...global(g), ...notAdmin(A), ...neverDeclined];
const updMocks = (g, pol = null) => [...userDoc(A), ...userDoc(B, 'everyone', pol), ...global(g), ...notAdmin(A)];

const text = { authorId: A, text: shortCipher };
const photo = { authorId: A, text: shortCipher, type: 'image', imageUrl: 'https://x/y.jpg', width: 100, height: 100 };
const newChat = { ...fresh, updatedAt: REQ_TIME };

const ON = { requests: true, chatKeyRequired: true, chatKeyVisible: true };
const REQ_OFF = { requests: false, chatKeyRequired: true, chatKeyVisible: true };    // scenario B
const KEY_OFF = { requests: true, chatKeyRequired: false, chatKeyVisible: true };    // scenario C
const BOTH_OFF = { requests: false, chatKeyRequired: false, chatKeyVisible: true };  // scenario A
const HIDDEN = { requests: true, chatKeyRequired: true, chatKeyVisible: false };

const off = { ...fresh, reqOff: true };            // started while off, A not written yet
const offSpent = { ...spent, reqOff: true };       // started while off, A wrote once

// [name, expect BEFORE, expect AFTER, uid, path, method, after-data, before-data, mocks]
const cases = [
  // ── stamping ──
  ['STAMP   seed sets reqOff while requests are off', 'ALLOW', 'ALLOW', A, convPath, 'update',
    { ...fresh, reqOff: true, updatedAt: REQ_TIME }, fresh, updMocks(REQ_OFF)],
  ['STAMP   seed sets reqOff while requests are ON', 'ALLOW', 'DENY', A, convPath, 'update',
    { ...fresh, reqOff: true, updatedAt: REQ_TIME }, fresh, updMocks(ON)],
  ['STAMP   global on, B own requests off: allowed', 'ALLOW', 'ALLOW', A, convPath, 'update',
    { ...fresh, reqOff: true, updatedAt: REQ_TIME }, fresh, updMocks(ON, { requests: false })],
  ['STAMP   on a request already sent (switch off now)', 'ALLOW', 'DENY', A, convPath, 'update',
    { ...spent, reqOff: true, updatedAt: REQ_TIME }, spent, updMocks(REQ_OFF)],
  ['STAMP   reqOff false', 'ALLOW', 'DENY', A, convPath, 'update',
    { ...fresh, reqOff: false, updatedAt: REQ_TIME }, fresh, updMocks(REQ_OFF)],
  ['STAMP   B takes reqOff off again', 'ALLOW', 'DENY', B, convPath, 'update',
    { ...spent, updatedAt: REQ_TIME }, offSpent, updMocks(ON)],
  ['STAMP   new chat born reqOff while off', 'ALLOW', 'ALLOW', A, convPath, 'create',
    { ...newChat, reqOff: true }, null, createMocks(REQ_OFF)],
  ['STAMP   new chat born reqOff while ON', 'ALLOW', 'DENY', A, convPath, 'create',
    { ...newChat, reqOff: true }, null, createMocks(ON)],
  ['STAMP   new chat without reqOff while ON (control)', 'ALLOW', 'ALLOW', A, convPath, 'create',
    newChat, null, createMocks(ON)],

  // ── switch back ON ──
  ['ON      reqOff chat: A, the second message', 'DENY', 'ALLOW', A, msgPath, 'create', text, null, sendMocks(offSpent, ON)],
  ['ON      reqOff chat: A, the second message is a photo', 'DENY', 'ALLOW', A, msgPath, 'create', photo, null, sendMocks(offSpent, ON)],
  ['ON      reqOff chat: A moves lastMessage', 'DENY', 'ALLOW', A, convPath, 'update',
    { ...offSpent, lastMessage: 'enc1:zz', updatedAt: REQ_TIME }, offSpent, updMocks(ON)],
  ['ON      reqOff chat: B replies', 'ALLOW', 'ALLOW', B, msgPath, 'create', { authorId: B, text: shortCipher }, null, sendMocks(offSpent, ON)],
  ['ON      ordinary unanswered chat: second message', 'DENY', 'DENY', A, msgPath, 'create', text, null, sendMocks(spent, ON)],
  ['ON      ordinary unanswered chat: photo as the request', 'DENY', 'DENY', A, msgPath, 'create', photo, null, sendMocks(fresh, ON)],

  // ── what reqOff never opens ──
  ['KEY     reqOff chat, B now Chat Key only: second message', 'DENY', 'DENY', A, msgPath, 'create', text, null,
    sendMocks(offSpent, ON, 'contacts')],
  ['KEY     reqOff chat, B now Chat Key only: photo first', 'DENY', 'DENY', A, msgPath, 'create', photo, null,
    sendMocks(off, ON, 'contacts')],
  ['HOLD    reqOff chat: A accepts their own request', 'DENY', 'DENY', A, convPath, 'update',
    { ...offSpent, accepted: true }, offSpent, updMocks(ON)],
  ['HOLD    reqOff chat: the 21st knock of the day', 'DENY', 'DENY', A, msgPath, 'create', text, null,
    sendMocks(off, ON, 'everyone', null, 20)],
];

async function run(t, source, [, , , uid, path, method, after, before, mocks], expectation) {
  const request = { auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, path, method, time: REQ_TIME };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: mocks };
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
      if (n.state !== 'SUCCESS') console.log(`        AFTER  was not ${expAfter}: ${n.state} ${n.detail}`);
    }
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
