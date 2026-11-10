// Release audit 2026-11-10, storage.rules rows (M5 upload caps, M8 chat media read), run before and
// after like storage-0924.test.js. Official Story rows (L10) are in official-stories-1016.test.js.
//
//   git show 8997387cb:storage.rules > before-audit-1110.storage.rules
//   node storage-audit-1110.test.js before-audit-1110.storage.rules ../storage.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../storage.rules';
if (!BEFORE) { console.error('usage: node storage-audit-1110.test.js <before.rules> [after.rules]'); process.exit(2); }

const O = '/b/kulan-2ef85.appspot.com/o';
const D = '/databases/(default)/documents';
const ADMIN = 'uidAdmin', ME = 'uidMember', OUT = 'uidOutsider';
const CID = 'grp1';
const REQ_TIME = new Date().toISOString();
const group = (over = {}) => ({ users: [ADMIN, ME], admins: [ADMIN], type: 'group', ...over });
const groupGet = (data) => ([
  { function: 'firestore.get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data } } },
]);
const follower = (uid, yes) => ([
  { function: 'firestore.exists', args: [{ exactValue: `${D}/conversations/${CID}/followers/${uid}` }], result: { value: yes } },
]);
const adminRow = (uid, yes) => ([
  { function: 'firestore.exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: yes } },
]);
const blob = { size: 90000, contentType: 'application/octet-stream', md5Hash: 'bbb' };
const jpeg = (size = 50000) => ({ size, contentType: 'image/jpeg', md5Hash: 'aaa' });
const mp4 = (size = 9000000) => ({ size, contentType: 'video/mp4', md5Hash: 'ccc' });
const groupFile = `${O}/chat/${CID}/m1.enc`;
const pairFile = `${O}/chat/${[ADMIN, ME].sort().join('_')}/m1.enc`;
const channel = group({ users: [ADMIN], channel: true });

// [name, before, after, uid, path, method, newObject, existingObject, mocks, provider]
const cases = [
  // M8: who reads a chat's media.
  ['OK      a member reads group media', 'ALLOW', 'ALLOW', ME, groupFile, 'get', null, blob, groupGet(group())],
  ['FIX     an outsider reads group media', 'ALLOW', 'DENY', OUT, groupFile, 'get', null, blob, groupGet(group())],
  ['OK      a member reads 1:1 media', 'ALLOW', 'ALLOW', ME, pairFile, 'get', null, blob, []],
  ['FIX     an outsider reads 1:1 media', 'ALLOW', 'DENY', OUT, pairFile, 'get', null, blob, []],
  ['OK      a channel follower reads its media', 'ALLOW', 'ALLOW', ME, groupFile, 'get', null, blob,
    [...groupGet(channel), ...follower(ME, true)]],
  ['FIX     a banned follower reads channel media', 'ALLOW', 'DENY', ME, groupFile, 'get', null, blob,
    [...groupGet({ ...channel, bannedUids: [ME] }), ...follower(ME, true)]],
  ['FIX     a non-follower reads private channel media', 'ALLOW', 'DENY', OUT, groupFile, 'get', null, blob,
    [...groupGet(channel), ...follower(OUT, false)]],
  ['OK      an outsider reads a public plain group\'s media', 'ALLOW', 'ALLOW', OUT, groupFile, 'get', null, blob,
    groupGet(group({ isPublic: true, e2ee: false }))],
  // M8 check: the public branch matches firestore.rules publicPreviewRead, and anonymous is refused.
  ['FIX     an outsider reads a public group\'s media after it hid history', 'ALLOW', 'DENY', OUT, groupFile, 'get',
    null, blob, groupGet(group({ isPublic: true, e2ee: false, hideHistoryAt: REQ_TIME }))],
  ['FIX     an outsider reads an ended public group\'s media', 'ALLOW', 'DENY', OUT, groupFile, 'get',
    null, blob, groupGet(group({ isPublic: true, e2ee: false, endedAt: REQ_TIME }))],
  ['FIX     an outsider reads a disabled public group\'s media', 'ALLOW', 'DENY', OUT, groupFile, 'get',
    null, blob, groupGet(group({ isPublic: true, e2ee: false, mod: { state: 'disabled' } }))],
  ['FIX     an outsider reads a suspended public group\'s media', 'ALLOW', 'DENY', OUT, groupFile, 'get',
    null, blob, groupGet(group({ isPublic: true, e2ee: false, mod: { state: 'suspended' } }))],
  ['FIX     anonymous session reads a public group\'s media', 'ALLOW', 'DENY', OUT, groupFile, 'get',
    null, blob, groupGet(group({ isPublic: true, e2ee: false })), 'anonymous'],
  ['FIX     anonymous session reads 1:1 media', 'ALLOW', 'DENY', ME, pairFile, 'get', null, blob, [], 'anonymous'],

  // M5: what may be uploaded.
  ['OK      sealed chat media', 'ALLOW', 'ALLOW', ME, `${O}/chat/${CID}/m1.mp4.enc`, 'create', blob, null, groupGet(group())],
  ['OK      sealed album tile thumb', 'ALLOW', 'ALLOW', ME, `${O}/chat/${CID}/m1-2-thumb.enc`, 'create', blob, null, groupGet(group())],
  ['FIX     chat upload as a web page', 'ALLOW', 'DENY', ME, `${O}/chat/${CID}/m1.enc`, 'create',
    { ...blob, contentType: 'text/html' }, null, groupGet(group())],
  ['FIX     chat upload with a made-up name', 'ALLOW', 'DENY', ME, `${O}/chat/${CID}/page.html`, 'create', blob, null, groupGet(group())],
  ['FIX     anonymous account uploads chat media', 'ALLOW', 'DENY', ME, pairFile, 'create', blob, null, [], 'anonymous'],
  ['OK      story photo', 'ALLOW', 'ALLOW', ME, `${O}/stories/s1/photo.jpg`, 'create', jpeg(), null, []],
  ['FIX     a 20 MB story photo', 'ALLOW', 'DENY', ME, `${O}/stories/s1/photo.jpg`, 'create', jpeg(20 * 1024 * 1024), null, []],
  ['OK      a 40 MB story video', 'ALLOW', 'ALLOW', ME, `${O}/stories/s1/video.mp4`, 'create', mp4(40 * 1024 * 1024), null, []],
  ['OK      an admin uploads an announcement picture', 'ALLOW', 'ALLOW', ADMIN,
    `${O}/announcements/a1/image.jpg`, 'create', jpeg(), null, adminRow(ADMIN, true)],
  ['FIX     a plain account uploads an announcement picture', 'ALLOW', 'DENY', ME,
    `${O}/announcements/a1/image.jpg`, 'create', jpeg(), null, adminRow(ME, false)],
];

async function run(t, source, [, , , uid, path, method, after, before, mocks, provider], expectation) {
  const request = { auth: { uid, token: { firebase: { sign_in_provider: provider || 'password' } } }, path, method, time: REQ_TIME };
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
