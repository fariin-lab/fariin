// The four conversation escalations found by the 2026-08-09 rules audit, each run against BOTH the
// live ruleset and the fix. An attack row is only proved when it flips: ALLOWED on live, DENIED on
// the fix. A legitimate row must pass on BOTH, or the fix broke the feature instead of the hole.
//
// A DENY suite that passes proves nothing on its own — rules that deny everything pass it perfectly.
// That lesson is written into kulan-firestore-rules-access and it cost a commit that shipped saying
// "NOT PROVEN BY TEST".
//
//   node conversation-escalation.test.js <oldRules> <newRules>
//
// Nothing is deployed and nothing is written. This only asks Google's engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const OLD = process.argv[2], NEW = process.argv[3];
if (!OLD || !NEW) { console.error('usage: node conversation-escalation.test.js <old> <new>'); process.exit(2); }

const ME = 'uidAttacker', VICTIM = 'uidVictim', THIRD = 'uidThird';
const CID = 'cid1';

// PLAIN JSON, never Firestore typed values. Typed values do not error, they parse and then every
// rule reading a VALUE quietly evaluates false — so the document denies everything and a DENY suite
// passes 100% for entirely the wrong reason.
const oneToOne = {
  users: [ME, VICTIM], type: '', accepted: true, startedBy: ME,
  lastSender: VICTIM, blockedBy: { [VICTIM]: true }, mutedBy: {}, clearedAt: {}, lastRead: {},
};
const group = {
  users: [ME, VICTIM, THIRD], type: 'group', admins: [VICTIM], createdBy: VICTIM,
  title: 'Family', onlyAdminsSend: false,
  blockedBy: { [VICTIM]: true }, mutedBy: { [VICTIM]: 1 }, clearedAt: {}, lastRead: {},
  names: {}, photos: {}, posters: {}, unreadCount: {},
};

function tc(expectation, method, path, data, before, auth = ME) {
  const req = {
    auth: { uid: auth, token: { firebase: { sign_in_provider: 'password' } } },
    path: `/databases/(default)/documents/${path}`,
    method,
  };
  if (data) req.resource = { data };
  const out = { expectation, request: req };
  if (before) out.resource = { data: before };
  return out;
}

const cases = [
  {
    name: 'ATTACK  turn a 1:1 into a group I solely administer',
    old: 'ALLOW', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...oneToOne, type: 'group', admins: [ME], createdBy: ME }, oneToOne),
  },
  {
    name: 'ATTACK  leave a group while claiming ownership of it',
    old: 'ALLOW', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, users: [VICTIM, THIRD], createdBy: ME }, group),
  },
  {
    name: 'ATTACK  leave a group after emptying its admin list',
    old: 'ALLOW', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, users: [VICTIM, THIRD], admins: [], onlyAdminsSend: true }, group),
  },
  {
    name: 'ATTACK  unblock myself in a group we share',
    old: 'ALLOW', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, blockedBy: { [VICTIM]: false } }, group),
  },
  {
    name: 'ATTACK  wipe another member\'s copy of a group',
    old: 'ALLOW', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, clearedAt: { [VICTIM]: 99999999999 } }, group),
  },
  // ── the rows that must survive: real features, expected to pass on BOTH files ──
  {
    name: 'OK      ordinary send into a group',
    old: 'ALLOW', new: 'ALLOW',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, lastMessage: 'hi', lastSender: ME, updatedAt: 1 }, group),
  },
  {
    name: 'OK      leave a group cleanly',
    old: 'ALLOW', new: 'ALLOW',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, users: [VICTIM, THIRD] }, group),
  },
  {
    name: 'OK      block someone in a 1:1 (my own key)',
    old: 'ALLOW', new: 'ALLOW',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...oneToOne, blockedBy: { [VICTIM]: true, [ME]: true } }, oneToOne),
  },
  {
    name: 'OK      mute a group for myself',
    old: 'ALLOW', new: 'ALLOW',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, mutedBy: { [VICTIM]: 1, [ME]: 1 } }, group),
  },
];

async function run(t, source, tcase) {
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [tcase] },
    }),
  });
  const j = await r.json();
  if (j.error) return { state: 'APIERROR', detail: JSON.stringify(j.error).slice(0, 200) };
  const res = j.testResults?.[0];
  return { state: res?.state || 'NORESULT', detail: (res?.debugMessages || []).join(' | ').slice(0, 200) };
}

(async () => {
  const t = await token();
  const oldSrc = fs.readFileSync(OLD, 'utf8'), newSrc = fs.readFileSync(NEW, 'utf8');
  let pass = 0, fail = 0;
  for (const c of cases) {
    const o = await run(t, oldSrc, c.build(c.old));
    const n = await run(t, newSrc, c.build(c.new));
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c.old.padEnd(5)}→${c.new.padEnd(5)}  ${c.name}`);
    if (!ok) {
      if (o.state !== 'SUCCESS') console.log(`        on LIVE it was not ${c.old}: ${o.state} ${o.detail}`);
      if (n.state !== 'SUCCESS') console.log(`        on FIX  it was not ${c.new}: ${n.state} ${n.detail}`);
    }
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
