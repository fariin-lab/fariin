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

  // 2026-09-24 feature-audit (delete-message): who may delete a chat file. `m1-2.enc` is album item 2
  // of message m1. Before = pre-qa.storage.rules, which had no chat delete clause at all.
  ...deleteRows(),
];

function deleteRows() {
  const OWNER = 'uidOwner', LIM = 'uidLimited', DEL = 'uidDeleter';
  const team = group({ users: [OWNER, ADMIN, LIM, DEL, ME], admins: [ADMIN, LIM, DEL], createdBy: OWNER,
    adminRights: { [LIM]: ['pinMessages'], [DEL]: ['deleteMessages'] } });
  const msgGet = (cid, data) => ({ function: 'firestore.get',
    args: [{ exactValue: `${D}/conversations/${cid}/messages/m1` }], result: { value: { data } } });
  const live = (author) => ({ authorId: author, type: 'album', text: 'enc1:x' });
  const tomb = (author) => ({ authorId: author, type: 'text', text: '', deleted: true });
  const g = (msg) => [msgGet(CID, msg), ...groupGet(team)];
  const file = `${O}/chat/${CID}/m1-2.enc`;
  const del = (uid, mocks, path = file) => [uid, path, 'delete', null, blob, mocks];
  const pair = [ME, OUT].sort().join('_');
  return [
    ['FIX     author frees one removed album item (message live)', 'DENY', 'ALLOW', ...del(ME, g(live(ME)))],
    ['FIX     author sweeps before the hard-delete fallback', 'DENY', 'ALLOW',
      ...del(ME, [msgGet(pair, live(ME))], `${O}/chat/${pair}/m1.enc`)],
    ['FIX     author deletes a file of their tombstone', 'DENY', 'ALLOW', ...del(ME, g(tomb(ME)))],
    ['GUARD   the other person in a 1:1 deletes my file', 'DENY', 'DENY',
      ...del(OUT, [msgGet(pair, tomb(ME))], `${O}/chat/${pair}/m1.enc`)],
    ['GUARD   member deletes another member\'s live file', 'DENY', 'DENY', ...del(ADMIN, g(live(ME)))],
    ['FIX     owner deletes a tombstoned member file', 'DENY', 'ALLOW', ...del(OWNER, g(tomb(ME)))],
    ['FIX     admin holding Delete messages deletes it', 'DENY', 'ALLOW', ...del(DEL, g(tomb(ME)))],
    ['FIX     legacy full admin deletes it', 'DENY', 'ALLOW', ...del(ADMIN, g(tomb(ME)))],
    ['GUARD   admin holding only Pin messages deletes it', 'DENY', 'DENY', ...del(LIM, g(tomb(ME)))],
    ['GUARD   Delete-messages admin deletes a LIVE member file', 'DENY', 'DENY', ...del(DEL, g(live(ME)))],
    ['GUARD   limited admin deletes the OWNER\'s tombstoned file', 'DENY', 'DENY', ...del(DEL, g(tomb(OWNER)))],
    ['GUARD   a file whose message doc is gone', 'DENY', 'DENY',
      ...del(ME, [{ function: 'firestore.get', args: [{ exactValue: `${D}/conversations/${CID}/messages/m1` }],
        result: { value: null } }, ...groupGet(team)])],
  ];
}

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
