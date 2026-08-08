// Proves that closing the user directory actually closed it, and did not close anything else.
//
// THE HOLE: `match /users/{uid} { allow read: if signedIn(); }`. In Firestore `read` grants `get`
// AND `list`, and `list` is not "read a few" — it is "run any query you like against this
// collection". So one signed-in phone could ask for every user document and page through the whole
// membership of Fariin. Anonymous sign-in is on, so "signed in" is one silent call away for anybody
// who installs the app. The fix is `allow get`, which keeps single-profile fetches and drops queries.
//
// ⚠️ THIS SUITE RUNS ITSELF TWICE, against the OLD rules and the NEW ones, and that is the whole
// point of it. A DENY suite passing proves nothing on its own: rules that deny everything pass it
// perfectly. The change is only proven when the attacks FLIP (allowed on old, denied on new) while
// the legitimate reads pass on BOTH. That lesson is written into kulan-firestore-rules-access and it
// cost a commit that shipped saying "NOT PROVEN BY TEST".
//
// Usage:
//   node user-directory.test.js <oldRules> <newRules>
//   node user-directory.test.js ../../../scratchpad/live.rules ../firestore.rules
//
// Nothing is deployed. Nothing is written. This only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const OLD = process.argv[2];
const NEW = process.argv[3];
if (!OLD || !NEW) {
  console.error('usage: node user-directory.test.js <oldRules> <newRules>');
  process.exit(2);
}

const ME = 'uidMe';
const OTHER = 'uidOther';

// PLAIN JSON, not Firestore typed values. Typed values do not error here, they parse and then every
// rule that reads a VALUE quietly evaluates false, so the document denies everything and a DENY
// suite passes 100% for entirely the wrong reason. Key-set rules survive either encoding; value
// rules do not, and `signedIn()` is a value rule.
const profile = { name: 'Someone', handle: 'someone', handleLower: 'someone', banned: false };

// ⚠️ A `list` IS TESTED AGAINST THE DOCUMENT PATH, NOT THE COLLECTION PATH. The rule being probed
// is `match /users/{uid}`, so the engine wants `users/<something>` with method `list`; handing it
// the bare collection `users` matches no rule and comes back FAILURE, which reads exactly like a
// rules failure and is not one. Cost one confusing red row before the control explained itself.
function testCase(expectation, method, path, auth, provider = 'anonymous') {
  return {
    expectation,
    request: {
      auth: auth ? { uid: auth, token: { firebase: { sign_in_provider: provider } } } : null,
      path: `/databases/(default)/documents/${path}`,
      method,
    },
    resource: { data: profile },
  };
}

// `expectation` is filled per-run below, because the same request is expected to be ALLOWED on the
// old rules and DENIED on the new ones. That inversion IS the proof.
const cases = [
  {
    name: 'ATTACK  anonymous phone LISTS the whole user directory',
    old: 'ALLOW', new: 'DENY',
    build: (e) => testCase(e, 'list', `users/${OTHER}`, ME),
  },
  {
    // The anonymous case above is the cheap attack, but closing it would be worth little if a real
    // account could still sweep the directory: making an account costs one email. This row proves
    // the door is shut to a fully signed-up password user too, not just to anonymous ones.
    name: 'ATTACK  REAL signed-up account sweeps the directory',
    old: 'ALLOW', new: 'DENY',
    build: (e) => testCase(e, 'list', `users/${OTHER}`, ME, 'password'),
  },
  {
    name: 'OK      fetch ONE profile you already know the id of',
    old: 'ALLOW', new: 'ALLOW',
    build: (e) => testCase(e, 'get', `users/${OTHER}`, ME),
  },
  {
    name: 'OK      fetch your OWN profile',
    old: 'ALLOW', new: 'ALLOW',
    build: (e) => testCase(e, 'get', `users/${ME}`, ME),
  },
  {
    name: 'OK      signed-out phone is refused either way',
    old: 'DENY', new: 'DENY',
    build: (e) => testCase(e, 'get', `users/${OTHER}`, null),
  },
];

async function evaluate(t, source, tc) {
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [tc] },
    }),
  });
  const j = await r.json();
  if (j.error) return { state: 'APIERROR', detail: JSON.stringify(j.error).slice(0, 300) };
  const result = j.testResults?.[0];
  return { state: result?.state || 'NORESULT', detail: (result?.debugMessages || []).join(' | ').slice(0, 300) };
}

(async () => {
  const t = await token();
  const oldSrc = fs.readFileSync(OLD, 'utf8');
  const newSrc = fs.readFileSync(NEW, 'utf8');
  console.log(`old: ${OLD}\nnew: ${NEW}\n`);

  let pass = 0, fail = 0;
  for (const c of cases) {
    const o = await evaluate(t, oldSrc, c.build(c.old));
    const n = await evaluate(t, newSrc, c.build(c.new));
    // SUCCESS means the engine agreed with the expectation we handed it, so both must be SUCCESS
    // for the row to hold: the request behaved as `old` says on the old file and as `new` says on
    // the new one.
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    if (ok) pass++; else fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c.old.padEnd(5)}→${c.new.padEnd(5)}  ${c.name}`);
    if (!ok) {
      if (o.state !== 'SUCCESS') console.log(`        old rules did NOT behave as ${c.old}: ${o.state} ${o.detail}`);
      if (n.state !== 'SUCCESS') console.log(`        new rules did NOT behave as ${c.new}: ${n.state} ${n.detail}`);
    }
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (!fail) {
    console.log('The two ATTACK rows flipped and the OK rows held on both files.');
    console.log('That is the difference between aiming at the hole and breaking the feature.');
  }
  process.exitCode = fail ? 1 : 0;
})();
