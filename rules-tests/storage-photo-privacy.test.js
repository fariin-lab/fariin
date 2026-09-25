// 2026-09-25 profile photo privacy: who may READ profiles/<uid>.jpg. Run before and after:
//
//   node storage-photo-privacy.test.js <before.storage.rules> ../storage.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../storage.rules';
if (!BEFORE) { console.error('usage: node storage-photo-privacy.test.js <before.rules> [after.rules]'); process.exit(2); }

const O = '/b/kulan-2ef85.appspot.com/o';
const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', FRIEND = 'uidFriend', STRANGER = 'uidStranger';
const REQ_TIME = new Date().toISOString();
const cidOf = (a, b) => (a < b ? `${a}_${b}` : `${b}_${a}`);

// The world each case runs in: the owner's audience, whether the viewer is hidden, and the chat.
function world(viewer, { audience = 'everyone', hidden = false, chat = null } = {}) {
  const cid = cidOf(OWNER, viewer);
  const conv = `${D}/conversations/${cid}`;
  return [
    { function: 'firestore.get', args: [{ exactValue: `${D}/users/${OWNER}` }],
      result: { value: { data: { privacy: { photo: audience } } } } },
    { function: 'firestore.exists', args: [{ exactValue: `${D}/users/${OWNER}/photoHiddenFrom/${viewer}` }],
      result: { value: hidden } },
    { function: 'firestore.exists', args: [{ exactValue: conv }], result: { value: chat !== null } },
    { function: 'firestore.get', args: [{ exactValue: conv }],
      result: { value: chat === null ? null : { data: chat } } },
  ];
}
const read = (uid, file, mocks) => [uid, `${O}/profiles/${file}`, 'get', null, { size: 1000, contentType: 'image/jpeg' }, mocks];
const photo = `${OWNER}.jpg`, poster = `${OWNER}-poster.jpg`;
const accepted = { users: [OWNER, FRIEND], accepted: true, startedBy: FRIEND };
const ownerStarted = { users: [OWNER, FRIEND], accepted: false, startedBy: OWNER };
const pending = { users: [OWNER, STRANGER], accepted: false, startedBy: STRANGER };

// [name, before, after, ...read()]
const cases = [
  ['OK      owner reads own photo, audience No One', 'ALLOW', 'ALLOW', ...read(OWNER, photo, world(OWNER, { audience: 'nobody' }))],
  ['OK      anyone reads it, audience Everyone', 'ALLOW', 'ALLOW', ...read(STRANGER, photo, world(STRANGER))],
  ['FIX     stranger reads it, audience No One', 'ALLOW', 'DENY', ...read(STRANGER, photo, world(STRANGER, { audience: 'nobody' }))],
  ['FIX     friend reads it, audience No One', 'ALLOW', 'DENY', ...read(FRIEND, photo, world(FRIEND, { audience: 'nobody', chat: accepted }))],
  ['OK      friend in an accepted chat, audience My Chats', 'ALLOW', 'ALLOW', ...read(FRIEND, photo, world(FRIEND, { audience: 'contacts', chat: accepted }))],
  ['OK      someone the owner wrote to, audience My Chats', 'ALLOW', 'ALLOW', ...read(FRIEND, photo, world(FRIEND, { audience: 'contacts', chat: ownerStarted }))],
  ['FIX     stranger with no chat, audience My Chats', 'ALLOW', 'DENY', ...read(STRANGER, photo, world(STRANGER, { audience: 'contacts' }))],
  ['FIX     stranger whose request is unanswered, My Chats', 'ALLOW', 'DENY', ...read(STRANGER, photo, world(STRANGER, { audience: 'contacts', chat: pending }))],
  ['FIX     hidden person, audience Everyone', 'ALLOW', 'DENY', ...read(STRANGER, photo, world(STRANGER, { hidden: true }))],
  ['FIX     hidden friend, audience My Chats', 'ALLOW', 'DENY', ...read(FRIEND, photo, world(FRIEND, { audience: 'contacts', chat: accepted, hidden: true }))],
  ['FIX     the poster follows the same rule', 'ALLOW', 'DENY', ...read(STRANGER, poster, world(STRANGER, { audience: 'nobody' }))],
  ['OK      the poster, audience Everyone', 'ALLOW', 'ALLOW', ...read(STRANGER, poster, world(STRANGER))],
  ['OK      an account with no setting yet counts as Everyone', 'ALLOW', 'ALLOW', ...read(STRANGER, photo, [
    { function: 'firestore.get', args: [{ exactValue: `${D}/users/${OWNER}` }], result: { value: { data: {} } } },
    ...world(STRANGER).slice(1)])],
  ['OK      a group photo stays readable to members', 'ALLOW', 'ALLOW', ...read(STRANGER, 'group_grp1.jpg', [])],
];

async function run(t, source, [, , , uid, path, method, after, before, mocks], expectation) {
  const request = { auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, path, method, time: REQ_TIME };
  if (after) request.resource = after;
  const testCase = { expectation, request, functionMocks: mocks, resource: before || null };
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: { files: [{ name: 'storage.rules', content: source }] },
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
