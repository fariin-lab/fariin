// Official Stories (2026-10-16): officialStories in Firestore is closed to phones (admins with `send`
// may read; nobody writes), and officialStories/{id}/... in Storage is admin-only, three names, three
// types, 50 MB, no delete.
//
//   node official-stories-1016.test.js        # against ../firestore.rules and ../storage.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const D = '/databases/(default)/documents';
const O = '/b/kulan-2ef85.appspot.com/o';
const OWNER = 'ownerUID01', SENDER = 'senderUID01', MOD = 'modUID0001', USER = 'plainUser01';
const adminRows = { [OWNER]: { role: 'owner' }, [SENDER]: { perms: ['send'] }, [MOD]: { perms: ['moderate'] } };
const fsMocks = (fn) => Object.keys(adminRows).flatMap((u) => [
  { function: fn('exists'), args: [{ exactValue: `${D}/admins/${u}` }], result: { value: true } },
  { function: fn('get'), args: [{ exactValue: `${D}/admins/${u}` }], result: { value: { data: adminRows[u] } } },
]).concat([{ function: fn('exists'), args: [{ anyValue: {} }], result: { value: false } }]);

const story = { kind: 'image', caption: 'hi', deleted: false };
const F = `${D}/officialStories/abc123`;
// [name, expect, uid, path, method]
const fcases = [
  ['owner reads', 'ALLOW', OWNER, F, 'get'],
  ['sender reads', 'ALLOW', SENDER, F, 'get'],
  ['sender lists', 'ALLOW', SENDER, `${D}/officialStories/x`, 'list'],
  ['moderator (no send) reads', 'DENY', MOD, F, 'get'],
  ['plain user reads', 'DENY', USER, F, 'get'],
  ['plain user lists', 'DENY', USER, `${D}/officialStories/x`, 'list'],
  ['signed out reads', 'DENY', null, F, 'get'],
  ...['create', 'update', 'delete'].flatMap((m) => [OWNER, SENDER, USER].map((u) => [`${u} ${m}`, 'DENY', u, F, m])),
];

const jpg = (size = 500000) => ({ size, contentType: 'image/jpeg', md5Hash: 'a' });
const mp4 = (size = 9000000) => ({ size, contentType: 'video/mp4', md5Hash: 'b' });
const P = (f) => `${O}/officialStories/abc123/${f}`;
// [name, expect, uid, path, method, newObject, existingObject]
const scases = [
  ['owner uploads media.jpg', 'ALLOW', OWNER, P('media.jpg'), 'create', jpg(), null],
  ['sender uploads media.mp4', 'ALLOW', SENDER, P('media.mp4'), 'create', mp4(), null],
  ['sender uploads thumb.jpg', 'ALLOW', SENDER, P('thumb.jpg'), 'create', jpg(), null],
  ['admin overwrites media.jpg', 'ALLOW', SENDER, P('media.jpg'), 'update', jpg(600000), jpg()],
  ['admin reads media.mp4', 'ALLOW', MOD, P('media.mp4'), 'get', null, mp4()],
  ['plain user uploads media.jpg', 'DENY', USER, P('media.jpg'), 'create', jpg(), null],
  ['plain user reads media.jpg', 'DENY', USER, P('media.jpg'), 'get', null, jpg()],
  ['signed out reads media.jpg', 'DENY', null, P('media.jpg'), 'get', null, jpg()],
  ['admin uploads other name', 'DENY', OWNER, P('evil.html'), 'create', { size: 10, contentType: 'text/html', md5Hash: 'c' }, null],
  ['admin uploads png as media.jpg', 'DENY', OWNER, P('media.jpg'), 'create', { size: 10, contentType: 'image/png', md5Hash: 'c' }, null],
  ['admin uploads jpeg as media.mp4', 'DENY', OWNER, P('media.mp4'), 'create', jpg(), null],
  ['admin uploads 51 MB video', 'DENY', OWNER, P('media.mp4'), 'create', mp4(51 * 1024 * 1024), null],
  ['admin uploads into a sub-folder', 'DENY', OWNER, `${O}/officialStories/abc123/x/media.jpg`, 'create', jpg(), null],
  ['admin deletes media.jpg', 'DENY', OWNER, P('media.jpg'), 'delete', null, jpg()],
];

async function ask(t, file, content, testCase) {
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ source: { files: [{ name: file, content }] }, testSuite: { testCases: [testCase] } }),
  });
  const j = await r.json();
  if (j.error) return 'APIERROR ' + JSON.stringify(j.error).slice(0, 200);
  if (j.issues && j.issues.length) return 'COMPILE ' + JSON.stringify(j.issues).slice(0, 300);
  const res = j.testResults && j.testResults[0];
  return (res && res.state) || 'NORESULT';
}

(async () => {
  const t = await token();
  const fsrc = fs.readFileSync('../firestore.rules', 'utf8'), ssrc = fs.readFileSync('../storage.rules', 'utf8');
  let pass = 0, fail = 0;
  const auth = (uid, provider) => (uid ? { uid, token: { firebase: { sign_in_provider: provider } } } : undefined);
  for (const [name, expect, uid, path, method] of fcases) {
    const request = { path, method, time: new Date().toISOString(), auth: auth(uid, 'google.com') };
    if (method === 'create' || method === 'update') request.resource = { data: story };
    const st = await ask(t, 'firestore.rules', fsrc, { expectation: expect, request,
      resource: method === 'create' ? undefined : { data: story }, functionMocks: fsMocks((f) => f) });
    const ok = st === 'SUCCESS'; ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  firestore want ${expect.padEnd(5)}  ${name}${ok ? '' : '  ' + st}`);
  }
  for (const [name, expect, uid, path, method, after, before] of scases) {
    const request = { path, method, time: new Date().toISOString(), auth: auth(uid, 'password') };
    if (after) request.resource = after;
    const st = await ask(t, 'storage.rules', ssrc, { expectation: expect, request, resource: before || null,
      functionMocks: fsMocks((f) => 'firestore.' + f) });
    const ok = st === 'SUCCESS'; ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  storage   want ${expect.padEnd(5)}  ${name}${ok ? '' : '  ' + st}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) process.exitCode = 1;
})();
