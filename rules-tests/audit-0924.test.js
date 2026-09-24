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

// calls area: group call doc as GroupCallService.start writes it (startedAt is a server timestamp
// in the app; plain JSON cannot carry one, and the rules do not read it on these rows).
const gcPath = `${D}/groupCalls/${CID}`;
const gcStart = (by) => ({ active: true, startedBy: by, video: false, title: 'Family', startedAt: REQ_TIME });
// A 1:1 pair from before message requests (no startedBy), so the create's request branches stay out.
const pairPath = `${D}/conversations/${PAIR}`;
const pairMocks = [
  ...notAdmin(ME), ...notAdmin(THIRD),
  { function: 'exists', args: [{ exactValue: pairPath }], result: { value: true } },
  { function: 'get', args: [{ exactValue: pairPath }],
    result: { value: { data: { users: [ME, THIRD], blockedBy: {}, lastMessage: 'hi', lastSender: ME } } } },
];
const callRec = (caller) => ({ type: 'call', authorId: caller, callerUid: caller, callOutcome: 'missed',
  callVideo: false, text: '', createdAt: REQ_TIME });

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
  // 2026-09-24 audit (settings QA): "No One" must be stricter than "My Chats".
  ['ATTACK  a chat partner reads last seen set to No One',
    'ALLOW', 'DENY', ME, `${D}/users/${THIRD}/presence/state`, 'get', null, { online: false },
    presenceMocks('nobody', {})],
  ['OK      the owner reads their own last seen set to No One',
    'ALLOW', 'ALLOW', THIRD, `${D}/users/${THIRD}/presence/state`, 'get', null, { online: false },
    presenceMocks('nobody', {})],
  // 2026-09-24 audit (settings QA): server ceiling on profile name and bio.
  ['OK      owner saves an 81-character name and a 140-character bio',
    'ALLOW', 'ALLOW', ME, `${D}/users/${ME}`, 'update',
    { name: 'a'.repeat(81), about: 'b'.repeat(140) }, { name: 'x', about: '' }, notAdmin(ME)],
  ['OK      owner edits the bio while an older over-long name stays untouched',
    'ALLOW', 'ALLOW', ME, `${D}/users/${ME}`, 'update',
    { name: 'a'.repeat(400), about: 'new' }, { name: 'a'.repeat(400), about: '' }, notAdmin(ME)],
  ['ATTACK  a modified client writes a 5000-character bio',
    'ALLOW', 'DENY', ME, `${D}/users/${ME}`, 'update',
    { name: 'x', about: 'b'.repeat(5000) }, { name: 'x', about: '' }, notAdmin(ME)],
  ['ATTACK  a modified client writes a 5000-character name',
    'ALLOW', 'DENY', ME, `${D}/users/${ME}`, 'update',
    { name: 'a'.repeat(5000) }, { name: 'x' }, notAdmin(ME)],

  // ── 7. calls area (calls QA): group call doc + the callee's fallback call record ──
  ['OK      member starts a group call as themselves',
    'ALLOW', 'ALLOW', ME, gcPath, 'create', gcStart(ME), null, [...members, ...convGet(group)]],
  ['ATTACK  member starts a group call in ADMIN\'s name (spoofed push)',
    'ALLOW', 'DENY', ME, gcPath, 'create', gcStart(ADMIN), null, [...members, ...convGet(group)]],
  ['OK      member restarts after the last call ended',
    'ALLOW', 'ALLOW', ME, gcPath, 'update', gcStart(ME), { ...gcStart(ADMIN), active: false },
    [...members, ...convGet(group)]],
  ['ATTACK  member takes over ADMIN\'s live call as its starter',
    'ALLOW', 'DENY', ME, gcPath, 'update', gcStart(ME), gcStart(ADMIN), [...members, ...convGet(group)]],
  ['ATTACK  member rewrites a live call\'s startedBy to THIRD',
    'ALLOW', 'DENY', ME, gcPath, 'update', gcStart(THIRD), gcStart(ADMIN), [...members, ...convGet(group)]],
  ['OK      last member out ends the call (active:false only)',
    'ALLOW', 'ALLOW', ME, gcPath, 'update', { ...gcStart(ADMIN), active: false }, gcStart(ADMIN),
    [...members, ...convGet(group)]],
  ['ATTACK  ending the call also renames it',
    'ALLOW', 'DENY', ME, gcPath, 'update', { ...gcStart(ADMIN), active: false, title: 'X' }, gcStart(ADMIN),
    [...members, ...convGet(group)]],
  ['ATTACK  member deletes the group call doc',
    'ALLOW', 'DENY', ME, gcPath, 'delete', null, gcStart(ADMIN), [...members, ...convGet(group)]],
  ['GUARD   non-member starts a group call',
    'DENY', 'DENY', 'uidOutsider', gcPath, 'create', gcStart('uidOutsider'), null,
    [...members, ...notAdmin('uidOutsider'), ...convGet(group)]],
  ['OK      caller writes their own call record',
    'ALLOW', 'ALLOW', ME, `${pairPath}/messages/call_abc`, 'create', callRec(ME), null, pairMocks],
  ['FIX     callee writes the fallback call record (author = caller)',
    'DENY', 'ALLOW', THIRD, `${pairPath}/messages/call_abc`, 'create', callRec(ME), null, pairMocks],
  ['GUARD   callee fallback at a non-call id',
    'DENY', 'DENY', THIRD, `${pairPath}/messages/m9`, 'create', callRec(ME), null, pairMocks],
  ['GUARD   callee fallback smuggling text',
    'DENY', 'DENY', THIRD, `${pairPath}/messages/call_abc`, 'create', { ...callRec(ME), text: 'enc1:x' }, null, pairMocks],
  ['GUARD   callee fallback naming an outsider as caller',
    'DENY', 'DENY', THIRD, `${pairPath}/messages/call_abc`, 'create', callRec('uidOutsider'), null, pairMocks],
  ['GUARD   outsider writes a call record into the pair',
    'DENY', 'DENY', 'uidOutsider', `${pairPath}/messages/call_abc`, 'create', callRec(ME), null,
    [...pairMocks, ...notAdmin('uidOutsider')]],

  // ── groups (2026-09-24 audit, groups area): admin rights, the 30 cap, never adminless ──
  ...groupCases(),

  // ── shell (2026-09-24 audit, shell area): push tokens off the public profile, and capped ──
  ...shellCases(),
];

// Stage 4 of the push-token move: users/{uid}.fcmTokens / .voipTokens / .pushTokens may shrink,
// never grow; users/{uid}/push/{doc} lists are capped at 50 but may always shrink.
function shellCases() {
  const up = `${D}/users/${ME}`, pushDoc = `${D}/users/${ME}/push/tokens`;
  const m = [...notAdmin(ME), ...notAdmin(THIRD)];
  const toks = (n) => Array.from({ length: n }, (_, i) => `tok${i}`);
  return [
    ['ATTACK  owner adds a stolen FCM token to the public profile', 'ALLOW', 'DENY',
      ME, up, 'update', { name: 'A', fcmTokens: ['t1', 'stolen'] }, { name: 'A', fcmTokens: ['t1'] }, m],
    ['ATTACK  owner adds a VoIP token field to the public profile', 'ALLOW', 'DENY',
      ME, up, 'update', { name: 'A', voipTokens: ['v1'] }, { name: 'A' }, m],
    ['ATTACK  owner adds a legacy Expo token to the public profile', 'ALLOW', 'DENY',
      ME, up, 'update', { name: 'A', pushTokens: ['ExponentPushToken[x]'] }, { name: 'A' }, m],
    ['ATTACK  profile created carrying a token', 'ALLOW', 'DENY',
      ME, up, 'create', { name: 'A', fcmTokens: ['t1'] }, null, m],
    ['OK      app strips its own token off the old field', 'ALLOW', 'ALLOW',
      ME, up, 'update', { name: 'A', fcmTokens: ['t2'] }, { name: 'A', fcmTokens: ['t1', 't2'] }, m],
    ['OK      strip on an account that never had the field (arrayRemove leaves [])', 'ALLOW', 'ALLOW',
      ME, up, 'update', { name: 'A', fcmTokens: [], voipTokens: [] }, { name: 'A' }, m],
    ['OK      name edit with old tokens left as they are', 'ALLOW', 'ALLOW',
      ME, up, 'update', { name: 'B', fcmTokens: ['t1'] }, { name: 'A', fcmTokens: ['t1'] }, m],
    ['OK      app saves a token into its private push doc', 'ALLOW', 'ALLOW',
      ME, pushDoc, 'update', { fcmTokens: ['a', 'b'] }, { fcmTokens: ['a'] }, m],
    ['OK      first token creates the private push doc', 'ALLOW', 'ALLOW',
      ME, pushDoc, 'create', { voipTokens: ['v'] }, null, m],
    ['ATTACK  private push doc grown past 50 tokens', 'ALLOW', 'DENY',
      ME, pushDoc, 'update', { fcmTokens: toks(51) }, { fcmTokens: toks(50) }, m],
    ['OK      an over-cap list may still shrink (sign-out)', 'ALLOW', 'ALLOW',
      ME, pushDoc, 'update', { fcmTokens: toks(59) }, { fcmTokens: toks(60) }, m],
    ['OK      owner deletes the push doc (account delete)', 'ALLOW', 'ALLOW',
      ME, pushDoc, 'delete', null, { fcmTokens: ['a'] }, m],
    ['GUARD   another account writes my push doc', 'DENY', 'DENY',
      THIRD, pushDoc, 'update', { fcmTokens: ['a', 'x'] }, { fcmTokens: ['a'] }, m],
    ['GUARD   another account reads my push doc', 'DENY', 'DENY',
      THIRD, pushDoc, 'get', null, { fcmTokens: ['a'] }, m],
  ];
}

// ADMIN owns `team`; LIM is an admin the owner limited to pinning; LEG is a legacy full admin
// (no adminRights entry). A function so its fixtures stay out of the shared namespace above.
function groupCases() {
  const LIM = 'uidLimited', LEG = 'uidLegacy', NEW = 'uidNew';
  const team = {
    ...group, users: [ADMIN, LIM, LEG, ME, THIRD], admins: [ADMIN, LIM, LEG],
    adminRights: { [LIM]: ['pinMessages'] }, bannedUids: [],
    unreadCount: { [ADMIN]: 0, [LIM]: 0, [LEG]: 0, [ME]: 0, [THIRD]: 0 },
  };
  const m = [ADMIN, LIM, LEG, ME, THIRD, NEW].flatMap(notAdmin);
  const up = (who, over, base = team) => [who, convPath, 'update', { ...base, updatedAt: REQ_TIME, ...over }, base, m];
  const big = (n) => Array.from({ length: n }, (_, i) => (i === 0 ? ADMIN : `uidM${i}`));
  const g29 = { ...team, users: big(29), admins: [ADMIN], adminRights: {} };
  const g31 = { ...team, users: big(31), admins: [ADMIN], adminRights: {} };
  const soloOwner = { ...group, admins: [ADMIN] };
  const lastOne = { ...group, users: [ADMIN], admins: [], createdBy: GONE };
  const inv = { cid: CID, code: 'abc', createdBy: LEG, revoked: false };
  const invPath = `${D}/invites/abc`;
  return [
    // legitimate writes must keep passing
    ['OK      owner makes THIRD an admin', 'ALLOW', 'ALLOW', ...up(ADMIN, { admins: [ADMIN, LIM, LEG, THIRD] })],
    ['OK      owner limits LEG to pinning', 'ALLOW', 'ALLOW',
      ...up(ADMIN, { adminRights: { [LIM]: ['pinMessages'], [LEG]: ['pinMessages'] } })],
    ['OK      legacy admin renames the group', 'ALLOW', 'ALLOW', ...up(LEG, { title: 'New name' })],
    ['OK      legacy admin removes THIRD (ban + notice)', 'ALLOW', 'ALLOW',
      ...up(LEG, { users: [ADMIN, LIM, LEG, ME], bannedUids: [THIRD], lastMessage: 'x removed y', lastSender: LEG })],
    ['OK      legacy admin removes admin LIM from the group', 'ALLOW', 'ALLOW',
      ...up(LEG, { users: [ADMIN, LEG, ME, THIRD], admins: [ADMIN, LEG], adminRights: {}, bannedUids: [LIM] })],
    ['OK      legacy admin adds a member', 'ALLOW', 'ALLOW',
      ...up(LEG, { users: [...team.users, NEW], names: { [NEW]: 'New' }, unreadCount: { ...team.unreadCount, [NEW]: 0 } })],
    ['OK      pin-only admin pins a message', 'ALLOW', 'ALLOW', ...up(LIM, { pinnedMessageIds: ['m1'] })],
    ['OK      pin-only admin sends a message', 'ALLOW', 'ALLOW',
      ...up(LIM, { lastMessage: 'enc', lastSender: LIM, unreadCount: { ...team.unreadCount, [ME]: 1 } })],
    ['OK      a non-owner admin leaves', 'ALLOW', 'ALLOW',
      ...up(LEG, { users: [ADMIN, LIM, ME, THIRD], admins: [ADMIN, LIM], lastMessage: 'x left', lastSender: LEG })],
    ['OK      owner renames a group already over 30', 'ALLOW', 'ALLOW', ...up(ADMIN, { title: 'Big' }, g31)],
    ['OK      owner adds the 30th member', 'ALLOW', 'ALLOW', ...up(ADMIN, { users: [...g29.users, NEW] }, g29)],
    ['OK      the last member of an adminless group leaves', 'ALLOW', 'ALLOW',
      ADMIN, convPath, 'update', { ...lastOne, users: [], lastMessage: 'x left', lastSender: ADMIN, updatedAt: REQ_TIME }, lastOne, m],
    ['OK      legacy admin creates an invite link', 'ALLOW', 'ALLOW', LEG, invPath, 'create', inv, null, [...m, ...convGet(team)]],
    // holes
    ['ATTACK  pin-only admin makes THIRD an admin', 'ALLOW', 'DENY', ...up(LIM, { admins: [ADMIN, LIM, LEG, THIRD] })],
    ['ATTACK  legacy (non-owner) admin makes THIRD an admin', 'ALLOW', 'DENY', ...up(LEG, { admins: [ADMIN, LIM, LEG, THIRD] })],
    ['ATTACK  legacy admin demotes LIM', 'ALLOW', 'DENY', ...up(LEG, { admins: [ADMIN, LEG], adminRights: {} })],
    ['ATTACK  pin-only admin grants itself every right', 'ALLOW', 'DENY',
      ...up(LIM, { adminRights: { [LIM]: ['changeInfo', 'deleteMessages', 'banUsers', 'inviteUsers', 'pinMessages', 'manageCalls'] } })],
    ['ATTACK  pin-only admin clears its own limits (legacy = all)', 'ALLOW', 'DENY', ...up(LIM, { adminRights: {} })],
    ['ATTACK  pin-only admin renames the group', 'ALLOW', 'DENY', ...up(LIM, { title: 'Hacked' })],
    ['ATTACK  pin-only admin removes THIRD', 'ALLOW', 'DENY',
      ...up(LIM, { users: [ADMIN, LIM, LEG, ME], bannedUids: [THIRD] })],
    ['ATTACK  pin-only admin mutes THIRD', 'ALLOW', 'DENY',
      ...up(LIM, { restrictedFlags: { [THIRD]: ['sendText'] }, restrictedUntil: { [THIRD]: 9e15 } })],
    ['ATTACK  pin-only admin adds a member', 'ALLOW', 'DENY', ...up(LIM, { users: [...team.users, NEW] })],
    ['ATTACK  pin-only admin creates an invite link', 'ALLOW', 'DENY',
      LIM, invPath, 'create', { ...inv, createdBy: LIM }, null, [...m, ...convGet(team)]],
    ['ATTACK  owner adds two members to a 29-member group (31)', 'ALLOW', 'DENY',
      ...up(ADMIN, { users: [...g29.users, NEW, 'uidNew2'] }, g29)],
    ['ATTACK  sole admin (owner) leaves with no heir', 'ALLOW', 'DENY',
      ADMIN, convPath, 'update', clean(left(soloOwner, { _who: ADMIN, admins: [] })), soloOwner, m],
    ['ATTACK  last admin leaves with no heir after the owner left', 'ALLOW', 'DENY',
      ADMIN, convPath, 'update', clean(left(ownerGone, { _who: ADMIN, admins: [] })), ownerGone, m],
  ];
}

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
