// 2026-10-23 (owner): Add people in a link call rings them. callLinks/{roomId}/invites/{uid} is
// written by the Cloud Functions only (linkCallInvite, groupRingAnswer); any signed-in phone may get
// or list it, the same reach as the link doc itself (the call's Not connected list reads it). Each row
// runs against the rules BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   git show HEAD~1:firestore.rules > before-invites.rules      (the rules without the invites block)
//   node link-invites-1023.test.js before-invites.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node link-invites-1023.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const CREATOR = 'uidCreator', INVITER = 'uidInviter', INVITEE = 'uidInvitee', STRANGER = 'uidStranger';
const ROOM = 'ab'.repeat(32);
const REQ_TIME = new Date().toISOString();
const linkPath = `${D}/callLinks/${ROOM}`;
const invPath = `${D}/callLinks/${ROOM}/invites/${INVITEE}`;
const reqPath = `${D}/callLinks/${ROOM}/requests/${INVITEE}`;

const link = { creatorUid: CREATOR, encName: '', restrictions: 'adminApproval', video: true, revoked: false, active: true };
const invite = { uid: INVITEE, by: INVITER, byName: 'Ana', at: REQ_TIME, state: 'ringing', startedAt: 1 };
const request = { name: 'Bo', photoUrl: '', status: 'pending', at: REQ_TIME };
const mocks = [
  { function: 'get', args: [{ exactValue: linkPath }], result: { value: { data: link } } },
  { function: 'exists', args: [{ exactValue: linkPath }], result: { value: true } },
];

const cases = [
  ['NEW     a signed-in phone gets an invite', 'DENY', 'ALLOW', STRANGER, invPath, 'get', null, invite],
  ['NEW     the inviter lists the invites', 'DENY', 'ALLOW', INVITER, `${D}/callLinks/${ROOM}/invites/x`, 'list', null, null],
  ['NEW     the invitee gets their own invite', 'DENY', 'ALLOW', INVITEE, invPath, 'get', null, invite],
  ['GUARD   signed out, get an invite', 'DENY', 'DENY', null, invPath, 'get', null, invite],
  ['GUARD   signed out, list the invites', 'DENY', 'DENY', null, `${D}/callLinks/${ROOM}/invites/x`, 'list', null, null],
  ['GUARD   the invitee writes their own invite', 'DENY', 'DENY', INVITEE, invPath, 'create', invite, null],
  ['GUARD   the invitee marks themself joined', 'DENY', 'DENY', INVITEE, invPath, 'update',
    Object.assign({}, invite, { state: 'joined' }), invite],
  ['GUARD   the inviter rewrites a decline', 'DENY', 'DENY', INVITER, invPath, 'update',
    Object.assign({}, invite, { state: 'ringing' }), Object.assign({}, invite, { state: 'declined' })],
  ['GUARD   the creator deletes an invite', 'DENY', 'DENY', CREATOR, invPath, 'delete', null, invite],
  ['GUARD   a stranger gets a join request (unchanged)', 'DENY', 'DENY', STRANGER, reqPath, 'get', null, request],
  ['GUARD   the creator lists join requests (unchanged)', 'ALLOW', 'ALLOW', CREATOR, `${D}/callLinks/${ROOM}/requests/x`, 'list', null, null],
  ['GUARD   anyone lists call links (unchanged)', 'DENY', 'DENY', STRANGER, `${D}/callLinks/x`, 'list', null, null],
];

async function run(t, source, [, , , uid, p, method, after, before], expectation) {
  const req = { path: p, method, time: REQ_TIME };
  if (uid) req.auth = { uid, token: { firebase: { sign_in_provider: 'password' } } };
  if (after) req.resource = { data: after };
  const testCase = { expectation, request: req, functionMocks: [...mocks, { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
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
