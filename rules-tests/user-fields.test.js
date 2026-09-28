// Runs real assertions against firestore.rules using Firebase's own rules test engine.
// Nothing is deployed. Each case says what it expects, and a mismatch is printed loudly.
//
//   node user-fields.test.js              # against ../firestore.rules
//   node user-fields.test.js old.rules    # or any other rules file
//
// 2026-09-28: REWRITTEN IN THE FORMAT THE ENGINE ACTUALLY READS. The first version sent Firestore
// typed values ({stringValue: ...}) and a bare `token: {}`. `resource.data` in this API is PLAIN
// JSON (README, trap 1), and without a sign-in provider the request is not signed in at all, so the
// ALLOW case ("edit own NAME") failed on every rules version for reasons that had nothing to do with
// the rules, and the DENY cases passed for the wrong reason.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const VICTIM = 'uidVictim';

// A user document as it exists for somebody who has been banned by a moderator.
const bannedDoc = { name: 'Someone', banned: true, handleLower: 'someone' };
// The same person, not banned: the ordinary case.
const normalDoc = { name: 'Someone', banned: false, handleLower: 'someone' };

const mocks = [
  { function: 'exists', args: [{ exactValue: `${D}/admins/${VICTIM}` }], result: { value: false } },
  { function: 'get', args: [{ exactValue: `${D}/users/${VICTIM}` }], result: { value: { data: normalDoc } } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${VICTIM}` }], result: { value: true } },
];

const cases = [
  ['BANNED user tries to unban THEMSELVES', 'DENY', bannedDoc, { ...bannedDoc, banned: false }],
  ['normal user edits their own NAME', 'ALLOW', normalDoc, { ...normalDoc, name: 'New Name' }],
  ['user tries to TAKE A USERNAME directly', 'DENY', normalDoc, { ...normalDoc, handleLower: 'malia' }],
  ['user tries to BAN THEMSELVES off (writes banned: false over nothing)', 'DENY',
    { name: 'Someone', handleLower: 'someone' }, { name: 'Someone', handleLower: 'someone', banned: false }],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;

  for (const [name, expect, before, after] of cases) {
    const body = {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: {
        testCases: [{
          expectation: expect,
          request: {
            auth: { uid: VICTIM, token: { firebase: { sign_in_provider: 'password' } } },
            path: `${D}/users/${VICTIM}`,
            method: 'update',
            time: new Date().toISOString(),
            resource: { data: after },
          },
          resource: { data: before },
          functionMocks: mocks,
        }],
      },
    };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    const result = j.testResults?.[0];
    const state = result?.state || JSON.stringify(j).slice(0, 200);
    const ok = state === 'SUCCESS';
    if (ok) pass++; else fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  expected ${expect.padEnd(5)}  ${name}`);
    if (!ok && result?.debugMessages) console.log('      ', result.debugMessages.join(' | ').slice(0, 300));
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
