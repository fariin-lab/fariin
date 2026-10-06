// owner audit 2026-10-06 (#25, #26 and the low "ended call re-rung" item): the 1:1 call rules and the
// ad-hoc call names/photos rules, run against the rules BEFORE the fix and AFTER it. Each HOLE row must
// flip ALLOW→DENY; every OK row must answer the same on both, so the app's own writes still pass.
// README: plain JSON, mock every get()/exists() the rules can reach.
//
//   git show HEAD:firestore.rules > before.rules
//   node call-fix-1006.test.js before.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node call-fix-1006.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const A = 'uidStarter', B = 'uidInvited', C = 'uidStranger', N = 'uidNew';
// The engine reads a timestamp only as an ISO string (story-daily-limit.test.js).
const REQ_TIME = new Date().toISOString();
const LATER = new Date(Date.now() + 365 * 24 * 3600e3).toISOString();
const EARLIER = new Date(Date.now() - 3600e3).toISOString();
const ROOM = 'adhoc_1b2c3d4e-0000-4000-8000-000000000000';

// Nothing exists: the callee has no profile (so Calls = allowed) and no block list entry.
const noExists = { function: 'exists', args: [{ anyValue: {} }], result: { value: false } };

const adhoc = (over = {}) => ({ kind: 'adhoc', active: true, startedBy: A, video: false, title: 'A & B',
  members: [A, B], names: { [A]: 'A', [B]: 'B' }, photos: { [B]: 'https://p/b' }, joined: [A], ...over });

function cases() {
  const one = `${D}/calls/c1`;
  const call = `${D}/groupCalls/${ROOM}`;
  const dial = (over = {}) => ({ caller: A, callee: B, callerName: 'A', callerPhoto: '', type: 'voice',
    status: 'ringing', offer: { sdp: 'x', type: 'offer' }, cams: { [A]: false }, createdAt: REQ_TIME, ...over });
  const live = { caller: A, callee: B, callerName: 'A', callerPhoto: '', status: 'active', createdAt: EARLIER };
  const over = { ...live, status: 'ended', endReason: 'hangup' };
  const noStamp = dial(); delete noStamp.createdAt;
  return [
    // ── 1:1 create: createdAt is the server's clock (#26) ──
    ['OK      app dials (createdAt = server time)', 'ALLOW', 'ALLOW', A, one, 'create', dial(), null],
    ['HOLE    dial with createdAt missing', 'ALLOW', 'DENY', A, one, 'create', noStamp, null],
    ['HOLE    dial with createdAt in the future', 'ALLOW', 'DENY', A, one, 'create', dial({ createdAt: LATER }), null],
    ['HOLE    dial with createdAt in the past', 'ALLOW', 'DENY', A, one, 'create', dial({ createdAt: EARLIER }), null],
    ['OK      stranger dials as someone else', 'DENY', 'DENY', C, one, 'create', dial(), null],
    // ── 1:1 update: ended stays ended (audit 15 low), stamps and caller fields fixed (#25/#26) ──
    ['OK      caller hangs up', 'ALLOW', 'ALLOW', A, one, 'update', over, live],
    ['OK      callee accepts', 'ALLOW', 'ALLOW', B, one, 'update',
      { ...live, status: 'active', answer: { sdp: 'y', type: 'answer' } }, { ...live, status: 'ringing' }],
    ['OK      ended again as busy', 'ALLOW', 'ALLOW', B, one, 'update', { ...over, endReason: 'busy' }, over],
    ['OK      moveTo on an ended call', 'ALLOW', 'ALLOW', A, one, 'update', { ...over, moveTo: ROOM }, over],
    ['HOLE    ended call flipped back to ringing', 'ALLOW', 'DENY', A, one, 'update', { ...over, status: 'ringing' }, over],
    ['HOLE    ended call flipped back to active', 'ALLOW', 'DENY', B, one, 'update', { ...over, status: 'active' }, over],
    ['HOLE    party rewrites createdAt', 'ALLOW', 'DENY', A, one, 'update', { ...live, createdAt: LATER }, live],
    ['HOLE    caller rewrites callerName', 'ALLOW', 'DENY', A, one, 'update', { ...live, callerName: 'Bank' }, live],
    ['HOLE    caller rewrites callerPhoto', 'ALLOW', 'DENY', A, one, 'update', { ...live, callerPhoto: 'https://evil/x' }, live],
    ['OK      stranger updates a call', 'DENY', 'DENY', C, one, 'update', over, live],
    // ── ad-hoc names / photos (#25) ──
    ['OK      starter creates ad-hoc call', 'ALLOW', 'ALLOW', A, call, 'create', adhoc(), null],
    ['HOLE    create with a name for a non-member', 'ALLOW', 'DENY', A, call, 'create',
      adhoc({ names: { [A]: 'A', [B]: 'B', [C]: 'C' } }), null],
    ['OK      member adds a person with name + photo (app invite)', 'ALLOW', 'ALLOW', B, call, 'update',
      adhoc({ members: [A, B, N], names: { [A]: 'A', [B]: 'B', [N]: 'N' }, photos: { [B]: 'https://p/b', [N]: 'https://p/n' },
              title: 'A, B & 1 other' }), adhoc()],
    ['OK      member joins', 'ALLOW', 'ALLOW', B, call, 'update', adhoc({ joined: [A, B] }), adhoc()],
    ['OK      member ends', 'ALLOW', 'ALLOW', B, call, 'update', adhoc({ active: false, endedAt: REQ_TIME }), adhoc()],
    ['HOLE    member rewrites the starter name', 'ALLOW', 'DENY', B, call, 'update',
      adhoc({ names: { [A]: 'Your Bank', [B]: 'B' } }), adhoc()],
    ['HOLE    member removes a name', 'ALLOW', 'DENY', B, call, 'update', adhoc({ names: { [A]: 'A' } }), adhoc()],
    ['HOLE    member rewrites a photo', 'ALLOW', 'DENY', A, call, 'update',
      adhoc({ photos: { [B]: 'https://evil/x' } }), adhoc()],
    ['HOLE    member adds a name for a non-member', 'ALLOW', 'DENY', B, call, 'update',
      adhoc({ names: { [A]: 'A', [B]: 'B', [C]: 'C' } }), adhoc()],
    ['HOLE    names turned into a string', 'ALLOW', 'DENY', B, call, 'update', adhoc({ names: 'x' }), adhoc()],
    ['OK      stranger adds themself', 'DENY', 'DENY', C, call, 'update', adhoc({ members: [A, B, C] }), adhoc()],
  ];
}

async function run(t, source, [, , , uid, path, method, after, before], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: [noExists] };
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
