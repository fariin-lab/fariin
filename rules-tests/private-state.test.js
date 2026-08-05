// Proving 2062fe3: can one member of a 1:1 chat rewrite the OTHER member's private state?
//
// TWO FALSE STARTS ARE WORTH RECORDING, because both produced confident-looking output.
//
// 1. Cross-document get()/exists() must be mocked or the expression errors. That was real, but it
//    was not the blocker here.
// 2. THE BLOCKER: `resource.data` in this API takes PLAIN JSON, not Firestore typed values
//    ({stringValue:...}). With typed values every rule that reads a VALUE quietly evaluates false,
//    so the document denies everything — and a suite of DENY assertions then passes completely,
//    for entirely the wrong reason. The tell was that the four ALLOW cases failed too, and that the
//    pre-fix rules scored identically to the fixed ones.
//
// The earlier /users proof is unaffected: those rules only ever test KEY sets (keys(), diff()
// .affectedKeys()), and the key names are the same under both encodings. This one reads values.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the attacker: the one making the request
const B = 'uidBBB';   // the victim: the one who blocked A
const CID = 'convAB';

// BEFORE the write. B has blocked A. No startedBy, so this is a legacy/accepted chat.
const base = {
  users: [A, B],
  type: '',
  blockedBy: { [B]: true },
  clearedAt: {},
  lastRead: {},
  mutedBy: {},
  unreadCount: {},
  lastSender: B,
};

const mocks = [
  { function: 'exists', args: [{ exactValue: `${D}/users/${A}` }], result: { value: true } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${B}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/users/${A}` }], result: { value: { data: { banned: false } } } },
  { function: 'get', args: [{ exactValue: `${D}/users/${B}` }], result: { value: { data: { banned: false } } } },
  { function: 'exists', args: [{ exactValue: `${D}/admins/${A}` }], result: { value: false } },
  { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data: base } } },
];

const m = (extra) => ({ ...base, ...extra });

const cases = [
  // THE ATTACKS. A is writing into B's key.
  ["A unblocks THEMSELVES from B's block", 'DENY', m({ blockedBy: { [B]: false } })],
  ["A wipes B's copy of the chat (clearedAt)", 'DENY', m({ clearedAt: { [B]: 9999999999999 } })],
  ["A forges B's read receipt (lastRead)", 'DENY', m({ lastRead: { [B]: 9999999999999 } })],
  ["A un-mutes themselves in B's notifications", 'DENY', m({ mutedBy: { [B]: false } })],
  ["A archives the chat for B", 'DENY', m({ archivedBy: { [B]: true } })],
  ["A pins the chat for B", 'DENY', m({ pinnedBy: { [B]: true } })],

  // THE OTHER HALF OF THE PROOF. A rule that denies everything is an outage, not a fix.
  ["A blocks B (A's OWN key)", 'ALLOW', m({ blockedBy: { [B]: true, [A]: true } })],
  ["A clears their OWN copy", 'ALLOW', m({ clearedAt: { [A]: 1234567890 } })],
  ["A marks their OWN read position", 'ALLOW', m({ lastRead: { [A]: 1234567890 } })],
  ["A mutes the chat for themselves", 'ALLOW', m({ mutedBy: { [A]: true } })],
  ["A archives it for themselves", 'ALLOW', m({ archivedBy: { [A]: true } })],
  ["A sends a message (ordinary write)", 'ALLOW',
    m({ lastMessage: 'hello', lastSender: A, updatedAt: 1234567890 })],
  // unreadCount is deliberately exempt: the SENDER increments the RECIPIENT'S badge, so it is the
  // one uid-keyed map that legitimately crosses. If this denies, sending is broken.
  ["A increments B's unread badge (must stay allowed)", 'ALLOW',
    m({ unreadCount: { [B]: 3 }, lastSender: A, lastMessage: 'hi' })],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;
  const bad = [];
  for (const [name, expect, data] of cases) {
    const body = {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: {
        testCases: [{
          expectation: expect,
          request: {
            auth: { uid: A, token: { firebase: { sign_in_provider: 'password' } } },
            path: `${D}/conversations/${CID}`,
            method: 'update',
            time: new Date().toISOString(),
            resource: { data },
          },
          resource: { data: base },
          functionMocks: mocks,
        }],
      },
    };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const ok = res && res.state === 'SUCCESS';
    ok ? pass++ : fail++;
    if (!ok) bad.push(name);
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${expect.padEnd(5)}  ${name}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) console.log('failed: ' + bad.join(' | '));
})();
