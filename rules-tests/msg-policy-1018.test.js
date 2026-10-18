// Message policy from the admin panel (owner 2026-10-18): Message Requests and the Chat Key switched
// globally (config/msgPolicy) or per person (users/{uid}.msgPolicy), each case run against the rules
// BEFORE the change and AFTER it.
//
// What must hold:
//   - nothing changes while the switches are absent or ON (today's behaviour, both files agree);
//   - each of the four mixes does what it says, globally AND through one person's override, and an
//     override beats the global in both directions;
//   - hiding the Chat Key turns the requirement off (nobody is blocked by a key they cannot see);
//   - in every mode the starter never accepts their own request, never moves `startedBy`, never
//     touches the other person's block, and the day's knock budget still counts;
//   - no phone can write the switches.
//
//   node msg-policy-1018.test.js <before.rules> <after.rules>
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

// [name, expect BEFORE, expect AFTER, uid, path, method, after-data, before-data, mocks]
const cases = [
  // ── 0. today's behaviour: no document, or every switch on ──
  ['SAME    no config: second message into an unanswered request', 'DENY', 'DENY', A, msgPath, 'create', text, null, sendMocks(spent, null)],
  ['SAME    no config: photo as the request', 'DENY', 'DENY', A, msgPath, 'create', photo, null, sendMocks(fresh, null)],
  ['SAME    no config: new chat with a Chat Key account', 'DENY', 'DENY', A, convPath, 'create', newChat, null, createMocks(null, 'contacts')],
  ['SAME    all on: second message', 'DENY', 'DENY', A, msgPath, 'create', text, null, sendMocks(spent, ON)],
  ['SAME    all on: new chat with a Chat Key account', 'DENY', 'DENY', A, convPath, 'create', newChat, null, createMocks(ON, 'contacts')],
  ['SAME    all on: the one short text', 'ALLOW', 'ALLOW', A, msgPath, 'create', text, null, sendMocks(fresh, ON)],
  ['SAME    all on: B answers', 'ALLOW', 'ALLOW', B, msgPath, 'create', { authorId: B, text: shortCipher }, null, sendMocks(spent, ON)],

  // ── A. both off (global) ──
  ['A glob  second message lands', 'DENY', 'ALLOW', A, msgPath, 'create', text, null, sendMocks(spent, BOTH_OFF)],
  ['A glob  photo as the first message', 'DENY', 'ALLOW', A, msgPath, 'create', photo, null, sendMocks(fresh, BOTH_OFF)],
  ['A glob  new chat with a Chat Key account', 'DENY', 'ALLOW', A, convPath, 'create', newChat, null, createMocks(BOTH_OFF, 'contacts')],
  ['A glob  second message to a Chat Key account', 'DENY', 'ALLOW', A, msgPath, 'create', text, null, sendMocks(spent, BOTH_OFF, 'contacts')],
  ['A glob  A updates lastMessage while unanswered', 'DENY', 'ALLOW', A, convPath, 'update',
    { ...spent, lastMessage: 'enc1:zz', updatedAt: REQ_TIME }, spent, updMocks(BOTH_OFF)],

  // ── B. requests off, Chat Key on ──
  ['B glob  second message lands', 'DENY', 'ALLOW', A, msgPath, 'create', text, null, sendMocks(spent, REQ_OFF)],
  ['B glob  KEY STILL APPLIES: new chat with a Chat Key account', 'DENY', 'DENY', A, convPath, 'create', newChat, null, createMocks(REQ_OFF, 'contacts')],
  ['B glob  KEY STILL APPLIES: first message to a Chat Key account', 'DENY', 'DENY', A, msgPath, 'create', text, null, sendMocks(fresh, REQ_OFF, 'contacts')],
  ['B glob  KEY STILL APPLIES: second message to a Chat Key account', 'DENY', 'DENY', A, msgPath, 'create', text, null, sendMocks(spent, REQ_OFF, 'contacts')],
  ['B over  global on, B\'s requests off: second message lands', 'DENY', 'ALLOW', A, msgPath, 'create', text, null,
    sendMocks(spent, ON, 'everyone', { requests: false })],
  ['B over  global off, B\'s requests forced on: one message only', 'DENY', 'DENY', A, msgPath, 'create', text, null,
    sendMocks(spent, REQ_OFF, 'everyone', { requests: true })],
  ['B over  global off, B\'s requests forced on: photo refused', 'DENY', 'DENY', A, msgPath, 'create', photo, null,
    sendMocks(fresh, REQ_OFF, 'everyone', { requests: true })],

  // ── C. requests on, Chat Key off ──
  ['C glob  new chat with a Chat Key account', 'DENY', 'ALLOW', A, convPath, 'create', newChat, null, createMocks(KEY_OFF, 'contacts')],
  ['C glob  the one short text to a Chat Key account', 'DENY', 'ALLOW', A, msgPath, 'create', text, null, sendMocks(fresh, KEY_OFF, 'contacts')],
  ['C glob  REQUESTS STILL APPLY: second message', 'DENY', 'DENY', A, msgPath, 'create', text, null, sendMocks(spent, KEY_OFF, 'contacts')],
  ['C glob  REQUESTS STILL APPLY: photo as the request', 'DENY', 'DENY', A, msgPath, 'create', photo, null, sendMocks(fresh, KEY_OFF, 'contacts')],
  ['C over  global on, B\'s key requirement off', 'DENY', 'ALLOW', A, convPath, 'create', newChat, null,
    createMocks(ON, 'contacts', { chatKeyRequired: false })],
  ['C over  global off, B\'s key forced on', 'DENY', 'DENY', A, convPath, 'create', newChat, null,
    createMocks(KEY_OFF, 'contacts', { chatKeyRequired: true })],

  // ── hidden Chat Key = requirement off, even when forced on ──
  ['HIDE    new chat with a Chat Key account', 'DENY', 'ALLOW', A, convPath, 'create', newChat, null, createMocks(HIDDEN, 'contacts')],
  ['HIDE    B\'s key forced on, but hidden', 'DENY', 'ALLOW', A, convPath, 'create', newChat, null,
    createMocks(HIDDEN, 'contacts', { chatKeyRequired: true })],
  ['HIDE    requests still apply', 'DENY', 'DENY', A, msgPath, 'create', text, null, sendMocks(spent, HIDDEN)],

  // ── what no mode opens ──
  ['HOLD    both off: A accepts their own request', 'DENY', 'DENY', A, convPath, 'update', { ...spent, accepted: true }, spent, updMocks(BOTH_OFF)],
  ['HOLD    both off: A accepts a fresh one', 'DENY', 'DENY', A, convPath, 'update', { ...fresh, accepted: true }, fresh, updMocks(BOTH_OFF)],
  ['HOLD    both off: A renames the starter', 'DENY', 'DENY', A, convPath, 'update', { ...spent, startedBy: B }, spent, updMocks(BOTH_OFF)],
  ['HOLD    both off: A lifts B\'s block', 'DENY', 'DENY', A, convPath, 'update',
    { ...spent, blockedBy: { [B]: false } }, { ...spent, blockedBy: { [B]: true } }, updMocks(BOTH_OFF)],
  ['HOLD    both off: A deletes the chat B blocked them in', 'DENY', 'DENY', A, convPath, 'delete', null,
    { ...spent, blockedBy: { [B]: true } }, updMocks(BOTH_OFF)],
  ['HOLD    both off: the 21st new chat of the day', 'DENY', 'DENY', A, msgPath, 'create', text, null, sendMocks(fresh, BOTH_OFF, 'everyone', null, 20)],
  ['HOLD    both off: the 10th new chat of the day', 'ALLOW', 'ALLOW', A, msgPath, 'create', text, null, sendMocks(fresh, BOTH_OFF, 'everyone', null, 9)],

  // ── nobody writes the switches from a phone ──
  ['WRITE   A switches requests off in config', 'DENY', 'DENY', A, `${D}/config/msgPolicy`, 'create', { requests: false }, null, [...notAdmin(A)]],
  ['WRITE   A switches their own requests off', 'ALLOW', 'DENY', A, `${D}/users/${A}`, 'update',
    { name: 'A', msgPolicy: { requests: false } }, { name: 'A' }, [...notAdmin(A)]],
  ['WRITE   A edits their name (control)', 'ALLOW', 'ALLOW', A, `${D}/users/${A}`, 'update',
    { name: 'A2' }, { name: 'A' }, [...notAdmin(A)]],
  ['READ    A reads the global switches', 'DENY', 'ALLOW', A, `${D}/config/msgPolicy`, 'get', null, ON, [...notAdmin(A)]],
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
