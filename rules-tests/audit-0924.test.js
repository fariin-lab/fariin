// 2026-09-24 rules audit (backend-rules area): each change run against the rules BEFORE it and AFTER
// it. A hole is only proved closed when its row FLIPS; every OK row must pass on both files, or the
// change broke a real client write instead of closing the hole. README: plain JSON, mock every get().
//
//   node audit-0924.test.js <before.rules> ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node audit-0924.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const ME = 'uidMember', ADMIN = 'uidAdmin', THIRD = 'uidThird', GONE = 'uidGoneOwner', ADM = 'uidStaff';
const CID = 'grp1';
const REQ_TIME = new Date().toISOString();
const now = Date.parse(REQ_TIME);
const iso = (ms) => new Date(ms).toISOString();

// ── documents ──
const group = {
  users: [ME, ADMIN, THIRD], type: 'group', admins: [ADMIN], createdBy: ADMIN, title: 'Family',
  onlyAdminsSend: false, pinnedMessageIds: [], blockedBy: {}, mutedBy: {}, clearedAt: {},
  lastRead: {}, pinnedBy: {}, archivedBy: {}, names: {}, photos: {}, posters: {},
  unreadCount: { [ME]: 0, [ADMIN]: 0, [THIRD]: 0 }, lastMessage: 'hi', lastSender: ADMIN,
};
// The owner already left, so a non-owner admin leaving cannot use the admin branch.
const ownerGone = { ...group, createdBy: GONE };
const msg = { authorId: ADMIN, text: 'enc1:xx', type: 'text', reactions: { [THIRD]: 'r3' } };

// ── mocks ──
const notAdmin = (uid) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
]);
const members = [ME, ADMIN, THIRD].flatMap(notAdmin);
const convGet = (data) => ([
  { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data } } },
]);
const staff = (perms) => ([
  { function: 'exists', args: [{ exactValue: `${D}/admins/${ADM}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/admins/${ADM}` }], result: { value: { data: { role: 'admin', perms } } } },
]);
const ann = (over = {}) => ({
  kind: 'news', title: 'Hello', body: 'Body text', buttons: [],
  audience: { scope: 'chosen', chosenCount: 1 }, publishAt: iso(now), deleted: false,
  createdBy: ADM, createdAt: REQ_TIME, ...over,
});
const broadcast = (over = {}) => ann({ audience: { scope: 'everyone', chosenCount: 0 }, ...over });
const PAIR = [ME, THIRD].sort().join('_');
const presenceMocks = (lastSeen, blockedBy) => ([
  ...notAdmin(ME),
  { function: 'get', args: [{ exactValue: `${D}/users/${THIRD}` }], result: { value: { data: { privacy: { lastSeen } } } } },
  { function: 'exists', args: [{ exactValue: `${D}/conversations/${PAIR}` }], result: { value: true } },
  { function: 'get', args: [{ exactValue: `${D}/conversations/${PAIR}` }],
    result: { value: { data: { users: [ME, THIRD], blockedBy } } } },
]);

const convPath = `${D}/conversations/${CID}`;
const msgPath = `${convPath}/messages/m1`;
const left = (base, over = {}) => ({ ...base, users: base.users.filter((u) => u !== (over._who || ME)),
  lastMessage: 'x left', lastSender: over._who || ME, updatedAt: REQ_TIME, ...over, _who: undefined });
const clean = (o) => { const c = { ...o }; delete c._who; return c; };

// [name, before, after, caller, path, method, newData, oldData, mocks]
const cases = [
  // ── 1. group self-leave may touch only what leaveGroup writes ──
  ['OK      member leaves (users, updatedAt, "X left" preview)',
    'ALLOW', 'ALLOW', ME, convPath, 'update', clean(left(group)), group, members],
  ['OK      last admin leaves and hands the group to one member',
    'ALLOW', 'ALLOW', ADMIN, convPath, 'update',
    clean(left(ownerGone, { _who: ADMIN, admins: [ME] })), ownerGone, members],
  ['ATTACK  member leaves and renames the group in the same write',
    'ALLOW', 'DENY', ME, convPath, 'update', clean(left(group, { title: 'Hacked' })), group, members],
  ['ATTACK  member leaves and makes THIRD an admin',
    'ALLOW', 'DENY', ME, convPath, 'update', clean(left(group, { admins: [ADMIN, THIRD] })), group, members],
  ['ATTACK  member leaves and restricts THIRD',
    'ALLOW', 'DENY', ME, convPath, 'update',
    clean(left(group, { restrictedFlags: { [THIRD]: { sendText: false } } })), group, members],
  ['ATTACK  member leaves and names someone else as the sender',
    'ALLOW', 'DENY', ME, convPath, 'update', clean(left(group, { lastSender: THIRD })), group, members],

  // ── 2. group per-member private maps are pinned to the caller's own key ──
  ['OK      member marks their own read',
    'ALLOW', 'ALLOW', ME, convPath, 'update', { ...group, lastRead: { [ME]: REQ_TIME } }, group, members],
  ['OK      member mutes the group for themselves',
    'ALLOW', 'ALLOW', ME, convPath, 'update', { ...group, mutedBy: { [ME]: 1e15 } }, group, members],
  ['OK      member sends (preview + others\' unread badges)',
    'ALLOW', 'ALLOW', ME, convPath, 'update',
    { ...group, lastMessage: 'enc', lastSender: ME, updatedAt: REQ_TIME,
      unreadCount: { [ME]: 0, [ADMIN]: 1, [THIRD]: 1 } }, group, members],
  ['OK      member refreshes their own name',
    'ALLOW', 'ALLOW', ME, convPath, 'update', { ...group, names: { [ME]: 'New' } }, group, members],
  ['ATTACK  member mutes THIRD',
    'ALLOW', 'DENY', ME, convPath, 'update', { ...group, mutedBy: { [THIRD]: 1e15 } }, group, members],
  ['ATTACK  member forges THIRD\'s read receipt',
    'ALLOW', 'DENY', ME, convPath, 'update', { ...group, lastRead: { [THIRD]: REQ_TIME } }, group, members],
  ['ATTACK  member clears THIRD\'s copy of the chat',
    'ALLOW', 'DENY', ME, convPath, 'update', { ...group, clearedAt: { [THIRD]: now } }, group, members],

  // ── 3. reactions: only my own key ──
  ['OK      member adds their own reaction',
    'ALLOW', 'ALLOW', ME, msgPath, 'update', { ...msg, reactions: { [THIRD]: 'r3', [ME]: 'r1' } }, msg,
    [...members, ...convGet(group)]],
  ['OK      member removes their own reaction',
    'ALLOW', 'ALLOW', THIRD, msgPath, 'update', { ...msg, reactions: {} }, msg, [...members, ...convGet(group)]],
  ['ATTACK  member deletes THIRD\'s reaction',
    'ALLOW', 'DENY', ME, msgPath, 'update', { ...msg, reactions: {} }, msg, [...members, ...convGet(group)]],
  ['ATTACK  member invents a reaction in ADMIN\'s name',
    'ALLOW', 'DENY', ME, msgPath, 'update', { ...msg, reactions: { [THIRD]: 'r3', [ADMIN]: 'fake' } }, msg,
    [...members, ...convGet(group)]],

  // ── 4. announcements: chosen sends carry the same checks; schedule is enforced ──
  ['OK      send+targetChosen writes the chosen record',
    'ALLOW', 'ALLOW', ADM, `${D}/announcementLog/a1`, 'create', { ...ann(), recipients: [ME] }, null,
    staff(['send', 'targetChosen'])],
  ['OK      send+targetChosen writes a person\'s copy',
    'ALLOW', 'ALLOW', ADM, `${D}/users/${ME}/announcements/a1`, 'create', ann(), null,
    staff(['send', 'targetChosen'])],
  ['ATTACK  targetChosen alone sends a SECURITY alert to a person',
    'ALLOW', 'DENY', ADM, `${D}/users/${ME}/announcements/a1`, 'create', ann({ kind: 'security' }), null,
    staff(['targetChosen'])],
  ['ATTACK  send+targetChosen pushes a 5000-character body',
    'ALLOW', 'DENY', ADM, `${D}/users/${ME}/announcements/a1`, 'create', ann({ body: 'x'.repeat(5000) }), null,
    staff(['send', 'targetChosen'])],
  ['ATTACK  send+targetChosen schedules two days out without `schedule`',
    'ALLOW', 'DENY', ADM, `${D}/announcementLog/a1`, 'create', { ...ann({ publishAt: iso(now + 2 * 86400e3) }), recipients: [ME] }, null,
    staff(['send', 'targetChosen'])],
  ['ATTACK  send+targetChosen EDITS a chosen record without `edit`',
    'ALLOW', 'DENY', ADM, `${D}/announcementLog/a1`, 'update', { ...ann({ title: 'Changed' }), recipients: [ME] },
    { ...ann(), recipients: [ME] }, staff(['send', 'targetChosen'])],
  ['FIX     `remove` alone withdraws a person\'s copy',
    'DENY', 'ALLOW', ADM, `${D}/users/${ME}/announcements/a1`, 'update', { ...ann(), deleted: true }, ann(),
    staff(['remove'])],
  ['FIX     `remove` alone withdraws the chosen record',
    'DENY', 'ALLOW', ADM, `${D}/announcementLog/a1`, 'update',
    { ...ann(), recipients: [ME], deleted: true, deletedAt: REQ_TIME }, { ...ann(), recipients: [ME] },
    staff(['remove'])],
  ['GUARD   `remove` alone cannot rewrite the title while withdrawing',
    'DENY', 'DENY', ADM, `${D}/users/${ME}/announcements/a1`, 'update', { ...ann(), title: 'X', deleted: true }, ann(),
    staff(['remove'])],
  ['OK      send-only admin sends a broadcast now',
    'ALLOW', 'ALLOW', ADM, `${D}/announcements/b1`, 'create', broadcast(), null, staff(['send'])],
  ['OK      send+schedule admin schedules a broadcast',
    'ALLOW', 'ALLOW', ADM, `${D}/announcements/b1`, 'create', broadcast({ publishAt: iso(now + 2 * 86400e3) }), null,
    staff(['send', 'schedule'])],
  ['ATTACK  send-only admin schedules a broadcast',
    'ALLOW', 'DENY', ADM, `${D}/announcements/b1`, 'create', broadcast({ publishAt: iso(now + 2 * 86400e3) }), null,
    staff(['send'])],

  // ── 5. read counters: one of the hundred shards only ──
  ['OK      a phone counts a read on shard 42',
    'ALLOW', 'ALLOW', ME, `${D}/announcements/b1/readShards/42`, 'create', { count: 1 }, null, notAdmin(ME)],
  ['ATTACK  a script mints shard "junk-123"',
    'ALLOW', 'DENY', ME, `${D}/announcements/b1/readShards/junk-123`, 'create', { count: 1 }, null, notAdmin(ME)],

  // ── 6. presence: a block ends last-seen visibility through the conversation branch ──
  ['OK      a contact reads last seen (My Contacts, no block)',
    'ALLOW', 'ALLOW', ME, `${D}/users/${THIRD}/presence/state`, 'get', null, { online: false },
    presenceMocks('contacts', {})],
  ['OK      last seen set to Everyone, reader blocked (Everyone means everyone)',
    'ALLOW', 'ALLOW', ME, `${D}/users/${THIRD}/presence/state`, 'get', null, { online: false },
    presenceMocks('everyone', { [THIRD]: true })],
  ['ATTACK  a blocked person reads the blocker\'s last seen',
    'ALLOW', 'DENY', ME, `${D}/users/${THIRD}/presence/state`, 'get', null, { online: false },
    presenceMocks('contacts', { [THIRD]: true })],
];

async function run(t, source, [, , , uid, path, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: mocks };
  if (before) testCase.resource = { data: before };
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [testCase] },
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
  const before = fs.readFileSync(BEFORE, 'utf8'), after = fs.readFileSync(AFTER, 'utf8');
  console.log(`before: ${BEFORE}\nafter:  ${AFTER}\n`);
  let pass = 0, fail = 0;
  for (const c of cases) {
    const [name, expBefore, expAfter] = c;
    const o = await run(t, before, c, expBefore);
    const n = await run(t, after, c, expAfter);
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${expBefore.padEnd(5)}→${expAfter.padEnd(5)}  ${name}`);
    if (!ok) {
      if (o.state !== 'SUCCESS') console.log(`        BEFORE was not ${expBefore}: ${o.state} ${o.detail}`);
      if (n.state !== 'SUCCESS') console.log(`        AFTER was not ${expAfter}: ${n.state} ${n.detail}`);
    }
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
