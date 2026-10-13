// 2026-10-13 verification audit. Badges: no client writes, even for a `verify` admin (adminApi only).
// The Fariin badge: owner only, one of three values, signed by the writer.
// (Header below kept from the file this was copied from.)
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
const MOD = 'verifierUID01';
const AUTHOR = 'authorUID0001';

const mocks = [
  { function: 'exists', args: [{ exactValue: `${D}/admins/${MOD}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/admins/${MOD}` }], result: { value: { data: { role: 'admin', perms: ['verify'] } } } },
  { function: 'exists', args: [{ anyValue: {} }], result: { value: false } },
];

const OWNER = 'ownerUID00001';
mocks.unshift(
  { function: 'exists', args: [{ exactValue: `${D}/admins/${OWNER}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/admins/${OWNER}` }], result: { value: { data: { role: 'owner', perms: [] } } } },
);
const profile = { name: 'A', handle: 'a', banned: false };
const mine = { name: 'V', handle: 'v', banned: false };
const badge = { isVerified: true, status: 'active', type: 'business', verifiedBy: MOD, verifiedAt: 5, lastUpdated: 5, version: 1 };
const official = { appStoreUrl: 'https://apps.apple.com/x', badge: 'blue', badgeBy: OWNER };

// [name, before (live), after (this file), who, path, method, stored, newData]
const cases = [
  ['verify admin writes a stranger badge from the app', 'ALLOW', 'DENY', MOD, `users/${AUTHOR}`, 'update', profile, { ...profile, verification: badge }],
  ['verify admin writes their OWN badge', 'ALLOW', 'DENY', MOD, `users/${MOD}`, 'update', mine, { ...mine, verification: badge }],
  ['verify admin writes a made-up badge shape', 'ALLOW', 'DENY', MOD, `users/${AUTHOR}`, 'update', profile, { ...profile, verification: { anything: true } }],
  ['verify admin writes a case file', 'ALLOW', 'DENY', MOD, `verifications/user:${AUTHOR}`, 'create', null, { peerKey: 'user:' + AUTHOR, reason: 'x', updatedBy: MOD, updatedAt: 5 }],
  ['verify admin writes an audit entry', 'ALLOW', 'DENY', MOD, 'verificationAudit/e1', 'create', null, { peerKey: 'user:' + AUTHOR, action: 'granted', adminUid: MOD, at: 5 }],
  ['verify admin still READS the audit', 'ALLOW', 'ALLOW', MOD, 'verificationAudit/e1', 'get', { adminUid: MOD }, null],
  ['the person writes their own badge (never allowed)', 'DENY', 'DENY', AUTHOR, `users/${AUTHOR}`, 'update', profile, { ...profile, verification: badge }],
  ['owner sets the Fariin badge to gold, signed', 'ALLOW', 'ALLOW', OWNER, 'config/official', 'update', official, { ...official, badge: 'gold', badgeBy: OWNER }],
  ['owner sets the Fariin badge to none, signed', 'ALLOW', 'ALLOW', OWNER, 'config/official', 'update', official, { ...official, badge: 'none', badgeBy: OWNER }],
  ['owner sets the Fariin badge to an unknown value', 'ALLOW', 'DENY', OWNER, 'config/official', 'update', official, { ...official, badge: 'purple', badgeBy: OWNER }],
  ['owner sets the Fariin badge signed as somebody else', 'ALLOW', 'DENY', OWNER, 'config/official', 'update', official, { ...official, badge: 'gold', badgeBy: MOD }],
  ['owner changes only the update link (badge untouched)', 'ALLOW', 'ALLOW', OWNER, 'config/official', 'update', official, { ...official, appStoreUrl: 'https://apps.apple.com/y' }],
  ['owner creates the document with a badge', 'ALLOW', 'ALLOW', OWNER, 'config/official', 'create', null, { badge: 'gold', badgeBy: OWNER }],
  ['a non-owner admin sets the Fariin badge', 'DENY', 'DENY', MOD, 'config/official', 'update', official, { ...official, badge: 'gold', badgeBy: MOD }],
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
      testSuite: { testCases: [{ expectation: expect, request, ...(stored ? { resource: { data: stored } } : {}), functionMocks: mocks }] } };
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
