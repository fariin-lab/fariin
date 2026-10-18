// 2026-10-18 (owner): "Create new groups" from the admin panel (config/features `groupCreate`). OFF
// refuses a NEW group; on, or not set, or no features doc at all, creates as before. Only the group
// create rule reads the switch, so existing groups are untouched by construction.
// README: plain JSON, mock every get().
//
//   node group-create-switch-1018.test.js [rules]      (default ../firestore.rules)
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const ME = 'uidMember', OTHER = 'uidOther';
const REQ_TIME = new Date().toISOString();
const path = `${D}/conversations/grpNew1`;
const FEATURES = `${D}/config/features`;

// As `ChatService.createGroup` writes it (server timestamps given as the request time).
const group = (users) => ({
  type: 'group', title: 'Plans', users, admins: [ME], createdBy: ME, createdAt: REQ_TIME,
  names: Object.fromEntries(users.map((u) => [u, u])), photos: {},
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  typing: Object.fromEntries(users.map((u) => [u, false])),
  updatedAt: REQ_TIME,
});

// The features doc as the panel leaves it: `docExists` false = never written.
function mocks(docExists, groupCreate) {
  const m = [];
  if (docExists) {
    m.push({ function: 'exists', args: [{ exactValue: FEATURES }], result: { value: true } });
    m.push({ function: 'get', args: [{ exactValue: FEATURES }],
      result: { value: { data: groupCreate === undefined ? { glow: false } : { groupCreate } } } });
  }
  // Not staff, not blocked: production's answer for every other lookup here.
  m.push({ function: 'exists', args: [{ anyValue: {} }], result: { value: false } });
  return m;
}

const cases = [
  ['switch OFF: a new group is refused', 'DENY', mocks(true, false), group([ME, OTHER])],
  ['switch OFF: a new self-only group is refused', 'DENY', mocks(true, false), group([ME])],
  ['switch ON: a new group is created', 'ALLOW', mocks(true, true), group([ME, OTHER])],
  ['switch never set (doc has other keys): created', 'ALLOW', mocks(true, undefined), group([ME, OTHER])],
  ['no features doc at all: created', 'ALLOW', mocks(false), group([ME, OTHER])],
];

async function run(t, source, mk, data, expectation) {
  const request = {
    auth: { uid: ME, token: { firebase: { sign_in_provider: 'password' } } },
    path, method: 'create', time: REQ_TIME, resource: { data },
  };
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [{ expectation, request, functionMocks: mk }] },
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
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;
  for (const [name, exp, mk, data] of cases) {
    const o = await run(t, source, mk, data, exp);
    const ok = o.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${exp.padEnd(5)}  ${name}`);
    if (!ok) console.log(`        got ${o.state} ${o.detail}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
})();
