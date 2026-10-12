// 2026-10-12: moderators lose their DIRECT client writes (ban fields, closing a report, deleting a
// story or its public mirror). Those actions now go only through the adminApi function, which is
// what records them in the audit log. Run against BOTH rule files: each moderator case must flip
// from ALLOW (live.rules, proving the mocks reach the moderator clause) to DENY (the new file), and
// the author's own deletes must stay ALLOW in both.
//
//   node fetch-live.js && node admin-writes-1012.test.js live.rules before
//   node admin-writes-1012.test.js ../firestore.rules after
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const WHICH = process.argv[3] || 'after';
const D = '/databases/(default)/documents';
const MOD = 'moderatorUID1';
const AUTHOR = 'authorUID0001';

const mocks = [
  { function: 'exists', args: [{ exactValue: `${D}/admins/${MOD}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/admins/${MOD}` }], result: { value: { data: { role: 'admin', perms: ['moderate'] } } } },
  { function: 'exists', args: [{ anyValue: {} }], result: { value: false } },
];

const profile = { name: 'A', handle: 'a', banned: false };
const report = { reporterUid: 'x1234567', reportedUid: AUTHOR, handled: false, createdAt: 1 };
const story = { authorUid: AUTHOR, recipientUids: [], createdAt: 1, expiresAt: 2 };

// [name, before, after, who, path, method, stored, newData]
const cases = [
  ['moderator bans an account from the browser', 'ALLOW', 'DENY', MOD, `users/${AUTHOR}`, 'update', profile,
    { ...profile, banned: true, bannedAt: 5, bannedBy: MOD, banReason: 'spam' }],
  ['moderator closes a report from the browser', 'ALLOW', 'DENY', MOD, 'reports/r1', 'update', report,
    { ...report, handled: true, handledBy: MOD, handledAt: 5, outcome: 'handled' }],
  ['moderator deletes somebody else\'s story', 'ALLOW', 'DENY', MOD, 'stories/s1', 'delete', story, null],
  ['moderator deletes the public mirror', 'ALLOW', 'DENY', MOD, `users/${AUTHOR}/publicStories/s1`, 'delete', { createdAt: 1 }, null],
  ['author deletes own story (must keep working)', 'ALLOW', 'ALLOW', AUTHOR, 'stories/s1', 'delete', story, null],
  ['author deletes own mirror (must keep working)', 'ALLOW', 'ALLOW', AUTHOR, `users/${AUTHOR}/publicStories/s1`, 'delete', { createdAt: 1 }, null],
  ['moderator still READS reports', 'ALLOW', 'ALLOW', MOD, 'reports/r1', 'get', report, null],
  ['stranger reads reports', 'DENY', 'DENY', 'stranger0001', 'reports/r1', 'get', report, null],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;
  const bad = [];
  for (const [name, before, after, who, path, method, stored, data] of cases) {
    const expect = WHICH === 'before' ? before : after;
    const request = { auth: { uid: who, token: { firebase: { sign_in_provider: 'google.com' } } }, path: `${D}/${path}`, method, time: new Date().toISOString() };
    if (data) request.resource = { data };
    const body = { source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [{ expectation: expect, request, resource: { data: stored }, functionMocks: mocks }] } };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST', headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const ok = res && res.state === 'SUCCESS';
    ok ? pass++ : fail++;
    if (!ok) bad.push(name + (j.error ? ` [${j.error.message}]` : '') + (res && res.debugMessages ? ' ' + res.debugMessages.join(';') : ''));
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${expect.padEnd(5)}  ${name}`);
  }
  console.log(`\n${WHICH}: ${pass} passed, ${fail} failed`);
  if (fail) console.log('failed: ' + bad.join(' | '));
})();
