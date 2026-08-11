// The ghost-pin gap (2026-08-11): in a GROUP, the client's automatic unpin after "delete for
// everyone" edits `pinnedMessageIds`, which the non-admin whitelist did not include — the
// arrayRemove was refused and a dead pin pointed at the tombstone in everyone's bar. The fix lets
// a member REMOVE pins only (new list ⊆ old, strictly shorter); pinning stays admin-only.
//
// Run BOTH files, per the README's control rule — the fix row must FLIP (DENY on live, ALLOW on
// fix), the guard rows must stay DENIED on both, the feature rows ALLOWED on both:
//
//   node group-unpin.test.js old.rules ../firestore.rules
const fs = require('fs');
const { token } = require('./auth');

const OLD = process.argv[2], NEW = process.argv[3];
if (!OLD || !NEW) { console.error('usage: node group-unpin.test.js <old> <new>'); process.exit(2); }

const ME = 'uidMember', ADMIN = 'uidAdmin', THIRD = 'uidThird';
const CID = 'cid1';

// PLAIN JSON, never Firestore typed values — see README trap 1.
const group = {
  users: [ME, ADMIN, THIRD], type: 'group', admins: [ADMIN], createdBy: ADMIN,
  title: 'Family', onlyAdminsSend: false,
  pinnedMessageIds: ['m1', 'm2', 'm3'],
  blockedBy: {}, mutedBy: {}, clearedAt: {}, lastRead: {},
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
    name: 'FIX     member removes one pin (the delete-for-everyone unpin)',
    old: 'DENY', new: 'ALLOW',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, pinnedMessageIds: ['m1', 'm3'] }, group),
  },
  {
    name: 'DOC     member may clear every pin (removal is removal; authorship is not checkable here)',
    old: 'DENY', new: 'ALLOW',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, pinnedMessageIds: [] }, group),
  },
  // ── the boundary: nothing can be PINNED through this branch ──
  {
    name: 'GUARD   member adds a pin',
    old: 'DENY', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, pinnedMessageIds: ['m1', 'm2', 'm3', 'm4'] }, group),
  },
  {
    name: 'GUARD   member swaps a pin at the same size',
    old: 'DENY', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, pinnedMessageIds: ['m1', 'm2', 'm4'] }, group),
  },
  {
    name: 'GUARD   member replaces the list with their own shorter one',
    old: 'DENY', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, pinnedMessageIds: ['mEvil'] }, group),
  },
  {
    name: 'GUARD   an outsider removes a pin',
    old: 'DENY', new: 'DENY',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, pinnedMessageIds: ['m1', 'm3'] }, group, 'uidOutsider'),
  },
  // ── the rows that must survive on BOTH files ──
  {
    name: 'OK      admin pins a new message',
    old: 'ALLOW', new: 'ALLOW',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, pinnedMessageIds: ['m1', 'm2', 'm3', 'm4'] }, group, ADMIN),
  },
  {
    name: 'OK      ordinary member send with pins present (field untouched)',
    old: 'ALLOW', new: 'ALLOW',
    build: (e) => tc(e, 'update', `conversations/${CID}`,
      { ...group, lastMessage: 'hi', lastSender: ME, updatedAt: 1 }, group),
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
      if (o.state !== 'SUCCESS') console.log(`        on OLD it was not ${c.old}: ${o.state} ${o.detail}`);
      if (n.state !== 'SUCCESS') console.log(`        on FIX it was not ${c.new}: ${n.state} ${n.detail}`);
    }
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
