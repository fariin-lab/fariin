// GLOW — the /glows collection and the two server-only counters (2026-09-02).
//
// One document per glow edge: /glows/{from}_{to} = {from, to, createdAt}. Give is create by the
// giver with the id matching the payload; either END may delete; nobody updates; reads are for
// participants only. glowerCount/glowingCount on the user doc are the function's alone.
//
// Run BOTH ways, per the README's control rule — every FIX row must DENY on the live rules and
// ALLOW on the new file; every GUARD row must DENY on both:
//
//   git show HEAD:firestore.rules > rules-tests/old.rules
//   node glow.test.js old.rules
//   node glow.test.js
//
// resource.data is PLAIN JSON, never Firestore typed values — README trap 1.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the giver
const B = 'uidBBB';   // the receiver
const C = 'uidCCC';   // a complete stranger

// ⚠️ ONE CLOCK FOR THE WHOLE SUITE. The create rule pins `createdAt` to `request.time` (that is what
// `FieldValue.serverTimestamp()` resolves to before a rule sees it), so the stamp on the payload and
// the stamp on the request have to be the SAME STRING or every ordinary give reads as a forged one.
// The runner below hands `NOW` to `request.time` unless a case names its own.
const NOW = new Date().toISOString();
const iso = (ms) => new Date(Date.parse(NOW) + ms).toISOString();
const edge = { from: A, to: B, createdAt: NOW };

/// isBanned() reads users/{caller}. An unmocked read makes the whole rule evaluate to nothing and
/// the test reports a confident, meaningless answer — README trap 2.
function mocksFor(uid, { banned = false } = {}) {
  return [
    { function: 'exists', args: [{ exactValue: `${D}/users/${uid}` }], result: { value: true } },
    { function: 'get', args: [{ exactValue: `${D}/users/${uid}` }],
      result: { value: { data: { banned } } } },
    { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
  ];
}

const cases = [
  // ── THE FEATURE (DENY on live — the collection has no rules there — ALLOW on new) ──
  { name: 'FIX   A gives B a glow', expect: 'ALLOW', uid: A, method: 'create',
    path: `${D}/glows/${A}_${B}`, after: edge, mocks: mocksFor(A) },
  { name: 'FIX   A reads their own edge', expect: 'ALLOW', uid: A, method: 'get',
    path: `${D}/glows/${A}_${B}`, before: edge },
  { name: 'FIX   B reads an edge aimed at them', expect: 'ALLOW', uid: B, method: 'get',
    path: `${D}/glows/${A}_${B}`, before: edge },
  { name: 'FIX   A takes their glow back', expect: 'ALLOW', uid: A, method: 'delete',
    path: `${D}/glows/${A}_${B}`, before: edge },
  { name: 'FIX   B removes A from their glowers', expect: 'ALLOW', uid: B, method: 'delete',
    path: `${D}/glows/${A}_${B}`, before: edge },

  // ── THE BOUNDARY (DENY on both files, or the block reaches further than it claims) ──
  { name: 'GUARD B forges a glow FROM A', expect: 'DENY', uid: B, method: 'create',
    path: `${D}/glows/${A}_${B}`, after: edge, mocks: mocksFor(B) },
  { name: 'GUARD id and payload disagree', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/glows/${A}_${C}`, after: edge, mocks: mocksFor(A) },
  { name: 'GUARD A glows themselves', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/glows/${A}_${A}`, after: { from: A, to: A, createdAt: NOW }, mocks: mocksFor(A) },
  { name: 'GUARD an extra field rides the edge', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/glows/${A}_${B}`, after: { ...edge, note: 'hi' }, mocks: mocksFor(A) },
  { name: 'GUARD createdAt missing', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/glows/${A}_${B}`, after: { from: A, to: B }, mocks: mocksFor(A) },
  { name: 'GUARD a banned account gives a glow', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/glows/${A}_${B}`, after: edge, mocks: mocksFor(A, { banned: true }) },
  { name: 'GUARD a stranger reads an edge', expect: 'DENY', uid: C, method: 'get',
    path: `${D}/glows/${A}_${B}`, before: edge },
  { name: 'GUARD a stranger deletes an edge', expect: 'DENY', uid: C, method: 'delete',
    path: `${D}/glows/${A}_${B}`, before: edge },
  { name: 'GUARD an edge is edited in place', expect: 'DENY', uid: A, method: 'update',
    path: `${D}/glows/${A}_${B}`, after: { ...edge, to: C }, before: edge },

  // ── THE STAMP (2026-09-11). The notifications page is ordered by `createdAt`, so a glow that
  //    picks its own time picks its own place in the receiver's list — for ever, because there is
  //    no update. Both rows DENY on the live file only after the pin; before it they ALLOWED.
  { name: 'GUARD a glow is back-dated', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/glows/${A}_${B}`, after: { from: A, to: B, createdAt: iso(-7 * 24 * 3600e3) },
    mocks: mocksFor(A) },
  { name: 'GUARD a glow is dated into the future', expect: 'DENY', uid: A, method: 'create',
    path: `${D}/glows/${A}_${B}`, after: { from: A, to: B, createdAt: iso(365 * 24 * 3600e3) },
    mocks: mocksFor(A) },

  // ── THE LIST (2026-09-11). Nothing in this folder had ever tested a `list` on any collection,
  //    so the half of the privacy model the comment calls "his ruling — counts are public, the name
  //    lists are yours alone" was the untested half.
  //
  //    ⚠️ WHAT A ROW HERE CAN AND CANNOT PROVE. The test API binds `resource` to one document and
  //    asks whether the rule BODY admits it, which is what proves the owner-scoping: a document
  //    with the caller on neither end is refused. It does not model the query planner, and that is
  //    the other half of the enforcement — because the rule names `resource.data.from` /
  //    `resource.data.to`, Firestore can only satisfy it when the query itself pins one of them to
  //    the caller, so an unconstrained list of the collection fails before a document is read.
  { name: 'FIX   A lists the glows they have given', expect: 'ALLOW', uid: A, method: 'list',
    path: `${D}/glows/${A}_${B}`, before: edge },
  { name: 'FIX   B lists the glows aimed at them', expect: 'ALLOW', uid: B, method: 'list',
    path: `${D}/glows/${A}_${B}`, before: edge },
  { name: 'GUARD a stranger lists somebody else\'s glowers', expect: 'DENY', uid: C, method: 'list',
    path: `${D}/glows/${A}_${B}`, before: edge },
  { name: 'GUARD a row of a list belonging to two other people', expect: 'DENY', uid: C,
    method: 'list', path: `${D}/glows/${B}_uidDDD`,
    before: { from: B, to: 'uidDDD', createdAt: NOW } },

  // ── THE COUNTERS (the user-doc halves; the ALLOW row must hold on BOTH files) ──
  { name: 'GUARD A inflates their own glowerCount', expect: 'DENY', uid: A, method: 'update',
    path: `${D}/users/${A}`, after: { name: 'A', glowerCount: 9999 },
    before: { name: 'A', glowerCount: 3 } },
  { name: 'OK    an ordinary profile edit beside untouched counters', expect: 'ALLOW', uid: A,
    method: 'update', path: `${D}/users/${A}`,
    after: { name: 'A renamed', glowerCount: 3, glowingCount: 1 },
    before: { name: 'A', glowerCount: 3, glowingCount: 1 } },
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  console.log(`rules: ${RULES}\n`);
  let pass = 0, fail = 0;
  const bad = [];
  for (const c of cases) {
    const request = {
      auth: { uid: c.uid, token: { firebase: { sign_in_provider: 'password' } } },
      path: c.path,
      method: c.method,
      // ⚠️ `NOW`, NOT A FRESH `new Date()`. A second clock here is a few milliseconds past the one
      // on the payload, and the create rule compares the two for equality — every ordinary give
      // would read as a forged stamp and the suite would fail on its own timing.
      time: c.time || NOW,
    };
    if (c.after) request.resource = { data: c.after };
    const testCase = { expectation: c.expect, request };
    if (c.mocks) testCase.functionMocks = c.mocks;
    if (c.before) testCase.resource = { data: c.before };

    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: { files: [{ name: 'firestore.rules', content: source }] },
        testSuite: { testCases: [testCase] },
      }),
    });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const ok = res && res.state === 'SUCCESS';
    ok ? pass++ : fail++;
    if (!ok) bad.push(c.name);
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${c.expect.padEnd(5)}  ${c.name}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) console.log('failed: ' + bad.join(' | '));
  process.exit(fail ? 1 : 0);
})();
