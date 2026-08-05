// Runs real assertions against firestore.rules using Firebase's own rules test engine.
// Nothing is deployed. Each case says what it expects, and a mismatch is printed loudly.
const fs = require('fs');
const { token } = require('./auth');

const RULES = '../firestore.rules';
const P = 'projects/kulan-2ef85/databases/(default)/documents';
const VICTIM = 'uidVictim';

// A user document as it exists for somebody who has been banned by a moderator.
const bannedDoc = {
  name: { stringValue: 'Someone' },
  banned: { booleanValue: true },
  handleLower: { stringValue: 'someone' },
};

function req({ path, method, auth, data, resource }) {
  return {
    expectation: undefined, // filled by caller
    request: {
      auth: auth ? { uid: auth, token: { firebase: { sign_in_provider: 'password' } } } : null,
      path: `/databases/(default)/documents/${path}`,
      method,
      time: new Date().toISOString(),
      ...(data ? { resource: { data } } : {}),
    },
    ...(resource ? { resource: { data: resource } } : {}),
  };
}

const cases = [
  {
    name: 'BANNED user tries to unban THEMSELVES',
    expect: 'DENY',
    tc: {
      expectation: 'DENY',
      request: {
        auth: { uid: VICTIM, token: {} },
        path: `/databases/(default)/documents/users/${VICTIM}`,
        method: 'update',
        resource: { data: { ...bannedDoc, banned: { booleanValue: false } } },
      },
      resource: { data: bannedDoc },
    },
  },
  {
    name: 'normal user edits their own NAME',
    expect: 'ALLOW',
    tc: {
      expectation: 'ALLOW',
      request: {
        auth: { uid: VICTIM, token: {} },
        path: `/databases/(default)/documents/users/${VICTIM}`,
        method: 'update',
        resource: { data: { ...bannedDoc, name: { stringValue: 'New Name' } } },
      },
      resource: { data: bannedDoc },
    },
  },
  {
    name: 'user tries to TAKE A USERNAME directly',
    expect: 'DENY',
    tc: {
      expectation: 'DENY',
      request: {
        auth: { uid: VICTIM, token: {} },
        path: `/databases/(default)/documents/users/${VICTIM}`,
        method: 'update',
        resource: { data: { ...bannedDoc, handleLower: { stringValue: 'malia' } } },
      },
      resource: { data: bannedDoc },
    },
  },
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;

  for (const c of cases) {
    const body = {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [c.tc] },
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
    console.log(`${ok ? 'PASS' : 'FAIL'}  expected ${c.expect.padEnd(5)}  ${c.name}`);
    if (!ok && result?.debugMessages) console.log('      ', result.debugMessages.join(' | ').slice(0, 300));
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
