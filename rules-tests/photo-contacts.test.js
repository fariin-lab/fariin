// 2026-09-30 `contacts` label: My Chats = the people on the file's `allow` list, no lookups.
//
//   node photo-contacts.test.js <before.storage.rules> ../storage.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
// Every case mocks the owner's document as "No One", so an ALLOW can only come from the label.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../storage.rules';
if (!BEFORE) { console.error('usage: node photo-contacts.test.js <before.rules> [after.rules]'); process.exit(2); }
const O = '/b/kulan-2ef85.appspot.com/o';
const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', FRIEND = 'uidFriend', FRIEND2 = 'uidFriend2', STRANGER = 'uidStranger';
const noOne = [
  { function: 'firestore.exists', args: [{ exactValue: `${D}/users/${OWNER}` }], result: { value: true } },
  { function: 'firestore.get', args: [{ exactValue: `${D}/users/${OWNER}` }],
    result: { value: { data: { privacy: { photo: 'nobody' } } } } },
];
const file = (metadata) => ({ size: 1000, contentType: 'image/jpeg', metadata });
const cases = [
  ['chat partner, first on the list', 'DENY', 'ALLOW', FRIEND, `${OWNER}.jpg`, file({ audience: 'contacts', allow: `${FRIEND},${FRIEND2}` })],
  ['chat partner, second on the list', 'DENY', 'ALLOW', FRIEND2, `${OWNER}.jpg`, file({ audience: 'contacts', allow: `${FRIEND},${FRIEND2}` })],
  ['chat partner, poster', 'DENY', 'ALLOW', FRIEND, `${OWNER}-poster.jpg`, file({ audience: 'contacts', allow: FRIEND })],
  ['stranger, not on the list', 'DENY', 'DENY', STRANGER, `${OWNER}.jpg`, file({ audience: 'contacts', allow: `${FRIEND},${FRIEND2}` })],
  ['contacts with no allow key at all', 'DENY', 'DENY', FRIEND, `${OWNER}.jpg`, file({ audience: 'contacts' })],
  ['contacts with an empty list', 'DENY', 'DENY', FRIEND, `${OWNER}.jpg`, file({ audience: 'contacts', allow: '' })],
  ['a uid that is only part of a listed one', 'DENY', 'DENY', 'uidFri', `${OWNER}.jpg`, file({ audience: 'contacts', allow: FRIEND })],
  ['allow list under another label opens nothing', 'DENY', 'DENY', FRIEND, `${OWNER}.jpg`, file({ audience: 'checked', allow: FRIEND })],
  ['everyone unchanged', 'ALLOW', 'ALLOW', STRANGER, `${OWNER}.jpg`, file({ audience: 'everyone' })],
  ['except unchanged', 'ALLOW', 'ALLOW', FRIEND, `${OWNER}.jpg`, file({ audience: 'except', deny: STRANGER })],
  ['owner always', 'ALLOW', 'ALLOW', OWNER, `${OWNER}.jpg`, file({ audience: 'contacts', allow: '' })],
];

async function run(t, source, [, , , uid, name, resource], expectation) {
  const request = { auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: `${O}/profiles/${name}`, method: 'get', time: new Date().toISOString() };
  const testCase = { expectation, request, resource,
    functionMocks: [...noOne, { function: 'firestore.exists', args: [{ anyValue: {} }], result: { value: false } }] };
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST', headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ source: { files: [{ name: 'storage.rules', content: source }] }, testSuite: { testCases: [testCase] } }),
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
  for (const c of cases) {
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
