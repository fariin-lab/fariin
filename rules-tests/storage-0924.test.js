// 2026-09-24 fix-all, group A: storage.rules rows, run before and after like audit-0924.test.js.
//
//   node storage-0924.test.js <before.storage.rules> ../storage.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../storage.rules';
if (!BEFORE) { console.error('usage: node storage-0924.test.js <before.rules> [after.rules]'); process.exit(2); }

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
const cases = [
  // #24 group avatar
  ['FIX     group admin sets the group photo', 'DENY', 'ALLOW',
    ADMIN, `${O}/profiles/group_${CID}.jpg`, 'create', jpeg, null, groupGet(group())],
  ['FIX     group admin replaces the group photo', 'DENY', 'ALLOW',
    ADMIN, `${O}/profiles/group_${CID}.jpg`, 'update', jpeg, { ...jpeg, md5Hash: 'old' }, groupGet(group())],
  ['FIX     member sets it while members can edit info', 'DENY', 'ALLOW',
    ME, `${O}/profiles/group_${CID}.jpg`, 'create', jpeg, null, groupGet(group({ membersCanEditInfo: true }))],
  ['GUARD   plain member sets the group photo', 'DENY', 'DENY',
    ME, `${O}/profiles/group_${CID}.jpg`, 'create', jpeg, null, groupGet(group())],
  ['GUARD   outsider sets the group photo', 'DENY', 'DENY',
    OUT, `${O}/profiles/group_${CID}.jpg`, 'create', jpeg, null, groupGet(group({ membersCanEditInfo: true }))],
  ['GUARD   admin uploads a non-image as the group photo', 'DENY', 'DENY',
    ADMIN, `${O}/profiles/group_${CID}.jpg`, 'create', { ...jpeg, contentType: 'text/html' }, null, groupGet(group())],
  ['OK      I set my own profile photo', 'ALLOW', 'ALLOW', ME, `${O}/profiles/${ME}.jpg`, 'create', jpeg, null, []],

  // #12 storage: a retried upload of the same bytes
  ['OK      first upload of chat media', 'ALLOW', 'ALLOW', ME, pairFile, 'create', blob, null, []],
  ['FIX     retried upload of the same bytes', 'DENY', 'ALLOW', ME, pairFile, 'update', blob, blob, []],
  ['GUARD   overwrite with different bytes', 'DENY', 'DENY', ME, pairFile, 'update', blob, { ...blob, md5Hash: 'zzz' }, []],
  ['FIX     retried story photo, same bytes', 'DENY', 'ALLOW', ME, `${O}/stories/s1/photo.jpg`, 'update', jpeg, jpeg, []],
  ['GUARD   story photo overwritten with other bytes', 'DENY', 'DENY',
    ME, `${O}/stories/s1/photo.jpg`, 'update', jpeg, { ...jpeg, md5Hash: 'old' }, []],
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
