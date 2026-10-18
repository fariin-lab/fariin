// owner 2026-10-18 group wallpaper: storage.rules rows for profiles/group_<cid>-wp<millis>.jpg, before and after.
//
//   node storage-wallpaper-1018.test.js <before.storage.rules> ../storage.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../storage.rules';
if (!BEFORE) { console.error('usage: node storage-wallpaper-1018.test.js <before.rules> [after.rules]'); process.exit(2); }

const O = '/b/kulan-2ef85.appspot.com/o';
const D = '/databases/(default)/documents';
const ADMIN = 'uidAdmin', ME = 'uidMember', OUT = 'uidOutsider';
const CID = 'grp1';
const REQ_TIME = new Date().toISOString();
const group = (over = {}) => ({ users: [ADMIN, ME], admins: [ADMIN], type: 'group', ...over });
const groupGet = (data) => ([
  { function: 'firestore.get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data } } },
]);
const jpeg = { size: 50000, contentType: 'image/jpeg', md5Hash: 'aaa' };
const blob = { size: 90000, contentType: 'application/octet-stream', md5Hash: 'bbb' };
const pairFile = `${O}/chat/${[ADMIN, ME].sort().join('_')}/m1.enc`;

// [name, before, after, uid, path, method, newObject, existingObject, mocks]
const WP = `${O}/profiles/group_${CID}-wp1760000000000.jpg`;
const cases = [
  ['FIX     group admin uploads a wallpaper', 'DENY', 'ALLOW', ADMIN, WP, 'create', jpeg, null, groupGet(group())],
  ['FIX     member uploads one while members can edit info', 'DENY', 'ALLOW', ME, WP, 'create', jpeg, null,
    groupGet(group({ membersCanEditInfo: true }))],
  ['GUARD   plain member uploads one', 'DENY', 'DENY', ME, WP, 'create', jpeg, null, groupGet(group())],
  ['GUARD   outsider uploads one', 'DENY', 'DENY', OUT, WP, 'create', jpeg, null, groupGet(group({ membersCanEditInfo: true }))],
  ['GUARD   admin uploads a PNG as the wallpaper', 'DENY', 'DENY', ADMIN, WP, 'create', { ...jpeg, contentType: 'image/png' }, null, groupGet(group())],
  ['GUARD   admin uploads 9 MB', 'DENY', 'DENY', ADMIN, WP, 'create', { ...jpeg, size: 9 * 1024 * 1024 }, null, groupGet(group())],
  ['FIX     admin deletes the old wallpaper', 'DENY', 'ALLOW', ADMIN, WP, 'delete', null, jpeg, groupGet(group())],
  ['GUARD   plain member deletes it', 'DENY', 'DENY', ME, WP, 'delete', null, jpeg, groupGet(group())],
  ['GUARD   admin deletes the group photo through it', 'DENY', 'DENY', ADMIN, `${O}/profiles/group_${CID}.jpg`, 'delete', null, jpeg, groupGet(group())],
];

async function run(t, source, [, , , uid, path, method, after, before, mocks], expectation) {
  const request = { auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, path, method, time: REQ_TIME };
  if (after) request.resource = after;
  const testCase = { expectation, request, functionMocks: mocks };
  // An absent object must be sent as an explicit null, or `resource == null` is a null-value error.
  testCase.resource = before || null;
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
