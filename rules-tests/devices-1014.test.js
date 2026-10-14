// 2026-10-14: a new sign-in may not sign out older devices for 24 hours, and the device record's
// createdAt / authTime cannot be forged. Run against the rules BEFORE the change and AFTER it; a hole
// is only closed when its row FLIPS, and every OK row must pass on both.
//
//   node devices-1014.test.js before-devices-1014.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
// README: plain JSON for data (an ISO string is a timestamp), mock every get()/exists().
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node devices-1014.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const U = 'uidOwner', X = 'uidStranger';
const REQ_TIME = new Date().toISOString();
const now = Date.parse(REQ_TIME);
const iso = (ms) => new Date(ms).toISOString();
const H = 3600e3;
const sec = (ms) => Math.floor(ms / 1000);

// Sign-ins: when each session logged on, as the auth server signs it into the token.
const FRESH = sec(now - 1 * H);                 // device B, an hour ago
const OLD = sec(now - 30 * 24 * H);             // device A, a month ago
const JUST_SETTLED = sec(now - 24 * H);         // exactly 24 h ago
const ALMOST = sec(now - 24 * H + 60e3);        // 23 h 59 m ago

const dev = `${D}/users/${U}/devices/devA`;
const mine = `${D}/users/${U}/devices/devB`;
const refusal = `${D}/users/${U}/deviceRefusals/devB`;
const recA = { model: 'iPhone', createdAt: iso(now - 30 * 24 * H), authTime: OLD, lastSeenAt: iso(now - 60e3) };
const recLegacy = { model: 'iPhone', createdAt: iso(now - 90 * 24 * H), lastSeenAt: iso(now - 60e3) };
const recB = { model: 'iPhone', createdAt: iso(now - 1 * H), authTime: FRESH, lastSeenAt: iso(now) };
const notAdmin = (uid) => [{ function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } }];

// [name, before, after, uid, authTime, path, method, newData, oldData]
function cases() {
  return [
    ['OK      owner reads the device list', 'ALLOW', 'ALLOW', U, FRESH, dev, 'get', null, recA],
    ['GUARD   another account reads it', 'DENY', 'DENY', X, OLD, dev, 'get', null, recA],

    // ── the 24-hour rule ──
    ['HOLE    new sign-in (1 h) signs out an older device', 'ALLOW', 'DENY', U, FRESH, dev, 'delete', null, recA],
    ['HOLE    new sign-in (23 h 59 m) signs out an older device', 'ALLOW', 'DENY', U, ALMOST, dev, 'delete', null, recA],
    ['OK      sign-in exactly 24 h old signs out another device', 'ALLOW', 'ALLOW', U, JUST_SETTLED, dev, 'delete', null, recA],
    ['OK      settled sign-in (30 days) signs out a new device', 'ALLOW', 'ALLOW', U, OLD, mine, 'delete', null, recB],
    ['OK      new sign-in removes ITS OWN record (signing out)', 'ALLOW', 'ALLOW', U, FRESH, mine, 'delete', null, recB],
    ['HOLE    new sign-in removes a pre-authTime record', 'ALLOW', 'DENY', U, FRESH, dev, 'delete', null, recLegacy],
    ['OK      settled sign-in removes a pre-authTime record', 'ALLOW', 'ALLOW', U, OLD, dev, 'delete', null, recLegacy],
    ['GUARD   another account deletes it', 'DENY', 'DENY', X, OLD, dev, 'delete', null, recA],

    // ── no way round it through an update ──
    ['HOLE    new sign-in copies its authTime onto the older record', 'ALLOW', 'DENY', U, FRESH, dev, 'update',
      { ...recA, authTime: FRESH }, recA],
    ['HOLE    new sign-in adds its authTime to a pre-authTime record', 'ALLOW', 'DENY', U, FRESH, dev, 'update',
      { ...recLegacy, authTime: FRESH }, recLegacy],
    ['HOLE    an update moves createdAt', 'ALLOW', 'DENY', U, OLD, dev, 'update',
      { ...recA, createdAt: iso(now - 365 * 24 * H) }, recA],
    ['OK      heartbeat: lastSeenAt only', 'ALLOW', 'ALLOW', U, OLD, dev, 'update',
      { ...recA, lastSeenAt: REQ_TIME }, recA],
    ['OK      push token on an existing record', 'ALLOW', 'ALLOW', U, FRESH, mine, 'update',
      { ...recB, fcmToken: 'tok' }, recB],

    // ── creating a record ──
    ['OK      new phone registers with server time and its own authTime', 'ALLOW', 'ALLOW', U, FRESH, mine, 'create',
      { model: 'iPhone', createdAt: REQ_TIME, authTime: FRESH, lastSeenAt: REQ_TIME }, null],
    ['OK      registration without authTime (token unreadable)', 'ALLOW', 'ALLOW', U, FRESH, mine, 'create',
      { model: 'iPhone', createdAt: REQ_TIME, lastSeenAt: REQ_TIME }, null],
    ['HOLE    registration backdates createdAt (dodges the 5-device order)', 'ALLOW', 'DENY', U, FRESH, mine, 'create',
      { model: 'iPhone', createdAt: iso(now - 365 * 24 * H), authTime: FRESH, lastSeenAt: REQ_TIME }, null],
    ['HOLE    registration claims an older authTime', 'ALLOW', 'DENY', U, FRESH, mine, 'create',
      { model: 'iPhone', createdAt: REQ_TIME, authTime: OLD, lastSeenAt: REQ_TIME }, null],
    ['CHANGE  a bare record with no createdAt (token-first write)', 'ALLOW', 'DENY', U, FRESH, mine, 'create',
      { fcmToken: 'tok', lastSeenAt: REQ_TIME }, null],

    // ── the server's refusal note ──
    ['NEW     owner reads the device-limit note', 'DENY', 'ALLOW', U, FRESH, refusal, 'get', null, { limit: 5 }],
    ['GUARD   owner cannot write the note', 'DENY', 'DENY', U, FRESH, refusal, 'create', { limit: 5 }, null],
    ['GUARD   owner cannot delete the note', 'DENY', 'DENY', U, OLD, refusal, 'delete', null, { limit: 5 }],
  ];
}

async function run(t, source, [, , , uid, authTime, path, method, after, before], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' }, auth_time: authTime } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: notAdmin(uid) };
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
  for (const c of cases()) {
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
