// 1:1 audit r2 (2026-10-08): G6 (a block is no longer refused at call create, so a refused create
// is no block test) and G8 (`screenedAt` is the server's alone). Run against the rules BEFORE the
// fix and AFTER it. G1 lives in message-requests.test.js.
//
//   git show HEAD:firestore.rules > before.rules
//   node call-r2-1008.test.js before.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
// README: plain JSON, mock every get()/exists() the rules can reach.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node call-r2-1008.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const A = 'uidAAA', B = 'uidBBB';
const PAIR = [A, B].sort().join('_');
const REQ_TIME = new Date().toISOString();
const EARLIER = new Date(Date.now() - 3600e3).toISOString();

const ex = (p, v) => ({ function: 'exists', args: [{ exactValue: `${D}/${p}` }], result: { value: v } });
const gt = (p, data) => ({ function: 'get', args: [{ exactValue: `${D}/${p}` }], result: { value: { data } } });
const friends = { users: [A, B], blockedBy: {}, startedBy: B, accepted: true, lastSender: B };

// A rings B. `calls` is B's Calls setting; `listed` = B has A on their account block list.
const mocks = ({ calls = 'contacts', pair = friends, listed = false }) => [
  ex(`users/${B}/blocked/${A}`, listed),
  ex(`conversations/${PAIR}`, !!pair), ...(pair ? [gt(`conversations/${PAIR}`, pair)] : []),
  ex(`users/${B}`, true), gt(`users/${B}`, { name: 'B', privacy: { calls } }),
];

function cases() {
  const one = `${D}/calls/c1`;
  const dial = (over = {}) => ({ caller: A, callee: B, callerName: 'A', callerPhoto: '', type: 'voice',
    status: 'ringing', offerEnc: 'enc1:x', sig: 2, cams: { [A]: false }, createdAt: REQ_TIME, ...over });
  const live = { caller: A, callee: B, callerName: 'A', callerPhoto: '', status: 'ringing', createdAt: EARLIER };
  const allowed = { ...live, screenedAt: EARLIER };
  return [
    ['OK      a friend rings', 'ALLOW', 'ALLOW', A, one, 'create', dial(), null, mocks({})],
    ['OK      a stranger rings somebody on My Chats (still refused)', 'DENY', 'DENY', A, one, 'create', dial(), null,
      mocks({ pair: null })],
    ['G6      a blocked person rings somebody on Everyone (silent now)', 'DENY', 'ALLOW', A, one, 'create', dial(), null,
      mocks({ calls: 'everyone', pair: null, listed: true })],
    ['G6      a blocked friend rings (old chat block, silent now)', 'DENY', 'ALLOW', A, one, 'create', dial(), null,
      mocks({ pair: { ...friends, blockedBy: { [B]: true } } })],
    ['HOLE    caller pre-writes screenedAt on create', 'ALLOW', 'DENY', A, one, 'create',
      dial({ screenedAt: REQ_TIME }), null, mocks({})],
    ['HOLE    caller adds screenedAt later', 'ALLOW', 'DENY', A, one, 'update', allowed, live, mocks({})],
    ['HOLE    callee removes screenedAt', 'ALLOW', 'DENY', B, one, 'update', live, allowed, mocks({})],
    ['OK      callee accepts a call the server allowed', 'ALLOW', 'ALLOW', B, one, 'update',
      { ...allowed, acceptedAt: REQ_TIME, answerEnc: 'enc1:y' }, allowed, mocks({})],
    ['OK      caller hangs up a call the server allowed', 'ALLOW', 'ALLOW', A, one, 'update',
      { ...allowed, status: 'ended', endReason: 'hangup' }, allowed, mocks({})],
  ];
}

async function run(t, source, [, , , uid, path, method, after, before, fm], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: fm };
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
  let pass = 0, fail = 0;
  for (const c of cases()) {
    const o = await run(t, before, c, c[1]), n = await run(t, after, c, c[2]);
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c[1].padEnd(5)}→${c[2].padEnd(5)}  ${c[0]}`);
    if (o.state !== 'SUCCESS') console.log(`        BEFORE: ${o.state} ${o.detail}`);
    if (n.state !== 'SUCCESS') console.log(`        AFTER: ${n.state} ${n.detail}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
