// owner 2026-10-06 group call roles: the groupCalls rules for the server-enforced removed list, the
// ad-hoc owner and "ended stays ended", run against the rules BEFORE the change and AFTER it. Each HOLE
// row must flip ALLOW→DENY; every OK row must answer the same on both; a FIX row is a write the app
// has always made that the old rules refused, so it flips DENY→ALLOW.
//
//   git show HEAD:firestore.rules > before.rules
//   node callroles-1006.test.js before.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node callroles-1006.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const A = 'uidOwner', B = 'uidMember', R = 'uidRemoved', C = 'uidStranger';
const REQ_TIME = new Date().toISOString();
const EARLIER = new Date(Date.now() - 3600e3).toISOString();
const ROOM = 'adhoc_1b2c3d4e-0000-4000-8000-000000000000';
const CID = 'g1';
const LINK = 'a'.repeat(64);

const gt = (path, data) => ({ function: 'get', args: [{ exactValue: `${D}/${path}` }], result: { value: { data } } });
const noExists = { function: 'exists', args: [{ anyValue: {} }], result: { value: false } };
const mocks = [gt(`conversations/${CID}`, { users: [A, B, R], createdBy: A, admins: [A] }),
  gt(`callLinks/${LINK}`, { creatorUid: A }), noExists];

const without = (o, k) => { const x = { ...o }; delete x[k]; return x; };
const adhoc = (over = {}) => ({ kind: 'adhoc', active: true, startedBy: A, video: false, title: 'A & B',
  members: [A, B], names: { [A]: 'A', [B]: 'B' }, photos: {}, joined: [A], removedUids: [R], ...over });
// The group call doc exactly as the app's start write makes it (GroupCallService.join, startedHere).
const gstart = (by, over = {}) => ({ active: true, startedBy: by, video: false, title: 'G', startedAt: REQ_TIME,
  recordId: 'gcall_X', ...over });

function cases() {
  const call = `${D}/groupCalls/${ROOM}`;
  const gc = `${D}/groupCalls/${CID}`;
  const live = gstart(A, { startedAt: EARLIER, removedUids: [R] });   // a live call with one removal
  const ended = { ...live, active: false };
  const old = without(gstart(A, { startedAt: EARLIER, active: false }), 'recordId');   // older call, no removals
  return [
    // ── group: the app's own writes ──
    ['FIX     app starts a group call (start write carries recordId)', 'DENY', 'ALLOW', B, gc, 'create', gstart(B), null],
    ['FIX     app starts a group call over an ended doc (recordId)', 'DENY', 'ALLOW', B, gc, 'update', gstart(B), old],
    ['OK      start without recordId over an ended doc', 'ALLOW', 'ALLOW', B, gc, 'update', without(gstart(B), 'recordId'), old],
    ['OK      last one out ends the group call (removals kept)', 'ALLOW', 'ALLOW', B, gc, 'update', ended, live],
    ['OK      stranger starts a group call', 'DENY', 'DENY', C, gc, 'create', gstart(C), null],
    // ── group: removedUids is the server's ──
    ['OK      member creates the doc with a removed list', 'DENY', 'DENY', B, gc, 'create',
      without(gstart(B, { removedUids: [A] }), 'recordId'), null],
    ['HOLE    removed member restarts over the ended call, wiping the list', 'ALLOW', 'DENY', R, gc, 'update',
      without(gstart(R), 'recordId'), without(ended, 'recordId')],
    ['HOLE    starter re-starts own live call, wiping the list', 'ALLOW', 'DENY', A, gc, 'update',
      without(gstart(A), 'recordId'), without(live, 'recordId')],
    ['OK      member edits the removed list while ending', 'DENY', 'DENY', B, gc, 'update', { ...ended, removedUids: [] }, live],
    // ── ad-hoc ──
    ['OK      starter creates ad-hoc call (app)', 'ALLOW', 'ALLOW', A, call, 'create', without(adhoc(), 'removedUids'), null],
    ['OK      create carrying a removed list', 'DENY', 'DENY', A, call, 'create', adhoc(), null],
    ['OK      member invites a new person (app)', 'ALLOW', 'ALLOW', B, call, 'update',
      adhoc({ members: [A, B, C], names: { [A]: 'A', [B]: 'B', [C]: 'C' }, title: 'A, B & 1 other' }), adhoc()],
    ['HOLE    member re-adds a removed person', 'ALLOW', 'DENY', B, call, 'update',
      adhoc({ members: [A, B, R], names: { [A]: 'A', [B]: 'B', [R]: 'R' } }), adhoc()],
    ['OK      member joins (app)', 'ALLOW', 'ALLOW', B, call, 'update', adhoc({ joined: [A, B] }), adhoc()],
    ['OK      last one out ends (app)', 'ALLOW', 'ALLOW', B, call, 'update', adhoc({ active: false, endedAt: REQ_TIME }), adhoc()],
    ['OK      abandoned start ends again (app, already ended)', 'ALLOW', 'ALLOW', A, call, 'update',
      adhoc({ active: false, endedAt: REQ_TIME }), adhoc({ active: false, endedAt: EARLIER })],
    ['HOLE    member re-opens an ended call', 'ALLOW', 'DENY', B, call, 'update',
      adhoc({ active: true, endedAt: EARLIER }), adhoc({ active: false, endedAt: EARLIER })],
    ['OK      member writes the removed list', 'DENY', 'DENY', B, call, 'update', adhoc({ removedUids: [] }), adhoc()],
    ['OK      member takes the owner role', 'DENY', 'DENY', B, call, 'update', adhoc({ startedBy: B }), adhoc()],
    // ── link removed list: server only ──
    ['OK      removed person reads the link removed list', 'DENY', 'DENY', R, `${D}/callLinks/${LINK}/removed/${R}`, 'get', null, null],
    ['OK      creator writes the link removed list', 'DENY', 'DENY', A, `${D}/callLinks/${LINK}/removed/${R}`, 'create', { by: A }, null],
  ];
}

async function run(t, source, [, , , uid, path, method, after, before], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: mocks };
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
