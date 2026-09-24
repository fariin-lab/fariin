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
  // 2026-09-24 decision D8: harmless spare mocks; message create no longer reads the block list
  // (silent block), only /calls create does.
  { function: 'exists', args: [{ exactValue: `${D}/users/${THIRD}/blocked/${ME}` }], result: { value: false } },
  { function: 'exists', args: [{ exactValue: `${D}/users/${ME}/blocked/${THIRD}` }], result: { value: false } },
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

  // ── accounts (2026-09-24 decisions D1 and D6): two-step per sign-in, server-set deletion date ──
  ...accountCases(),

  // ── admin (2026-09-24 decisions D-admin-*): edits never resurrect, retype or declassify ──
  ...adminCases(),

  // ── privacy (2026-09-24 decisions D7, D8, D13): server call privacy, account block list, own unread flag ──
  ...privacyCases(),

  // ── composer (2026-09-24 decision D-composer-3): text ceiling, media address shape, vote shape ──
  ...composerCases(),
];

// 2026-09-24 decision D-composer-3.
function composerCases() {
  const newMsg = `${convPath}/messages/mNew`;
  const gm = [...members, ...convGet(group)];
  const text = (n) => ({ authorId: ME, text: 'encg1:' + 'A'.repeat(n - 6), createdAt: REQ_TIME });
  const gif = (url) => ({ type: 'gif', imageUrl: url, width: 200, height: 200, text: '', authorId: ME,
    createdAt: REQ_TIME });
  const up = { authorId: ME, type: 'image', text: 'enc1:cap', uploading: true, enc: { k: 'x' } };
  const attached = (url) => ({ ...up, uploading: false, imageUrl: url });
  const mine = { authorId: ME, text: 'enc1:old', type: 'text' };
  const GIFURL = 'https://media.giphy.example/media/abc/giphy.gif';
  const FILEURL = 'https://firebasestorage.googleapis.com/v0/b/kulan.appspot.com/o/chat%2Fx.enc?alt=media&token=t';
  const votePath = (who) => `${msgPath}/votes/${who}`;
  const poll = (flag) => [...gm, { function: 'get', args: [{ exactValue: msgPath }],
    result: { value: { data: { authorId: ADMIN, text: 'encg1:poll', ...(flag === undefined ? {} : { pollMulti: flag }) } } } }];
  const vote = (options, extra = {}) => ({ options, at: REQ_TIME, ...extra });
  return [
    ['OK      member sends a group text', 'ALLOW', 'ALLOW', ME, newMsg, 'create', text(40), null, gm],
    ['OK      member sends the longest legitimate sealed text (534k)', 'ALLOW', 'ALLOW',
      ME, newMsg, 'create', text(534000), null, gm],
    ['ATTACK  member sends an 800k-character text', 'ALLOW', 'DENY', ME, newMsg, 'create', text(800000), null, gm],
    ['ATTACK  member sends a text that is not a string', 'ALLOW', 'DENY',
      ME, newMsg, 'create', { authorId: ME, text: { big: 'map' }, createdAt: REQ_TIME }, null, gm],
    ['OK      member sends a GIF (https)', 'ALLOW', 'ALLOW', ME, newMsg, 'create', gif(GIFURL), null, gm],
    ['OK      member sends a built-in sticker (sticker://)', 'ALLOW', 'ALLOW',
      ME, newMsg, 'create', gif('sticker://fariin.love_burst'), null, gm],
    ['ATTACK  GIF whose address is a data: URI', 'ALLOW', 'DENY',
      ME, newMsg, 'create', gif('data:image/gif;base64,R0lGOD'), null, gm],
    ['ATTACK  GIF whose address is plain http', 'ALLOW', 'DENY',
      ME, newMsg, 'create', gif('http://tracker.example/p.gif'), null, gm],
    ['ATTACK  GIF whose address is a number', 'ALLOW', 'DENY', ME, newMsg, 'create', gif(12345), null, gm],
    ['ATTACK  GIF whose address is 3,000 characters', 'ALLOW', 'DENY',
      ME, newMsg, 'create', gif('https://x.example/' + 'a'.repeat(2982)), null, gm],
    ['ATTACK  message carrying a videoUrl with a file: scheme', 'ALLOW', 'DENY',
      ME, newMsg, 'create', { ...text(40), type: 'video', videoUrl: 'file:///etc/passwd' }, null, gm],
    ['OK      author attaches the uploaded photo', 'ALLOW', 'ALLOW',
      ME, msgPath, 'update', attached(FILEURL), up, gm],
    ['ATTACK  author attaches a javascript: address', 'ALLOW', 'DENY',
      ME, msgPath, 'update', attached('javascript:alert(1)'), up, gm],
    ['OK      author edits their text', 'ALLOW', 'ALLOW',
      ME, msgPath, 'update', { ...mine, text: 'enc1:new', edited: true }, mine, gm],
    ['ATTACK  author edits their text to 800k characters', 'ALLOW', 'DENY',
      ME, msgPath, 'update', { ...mine, text: 'enc1:' + 'A'.repeat(800000), edited: true }, mine, gm],
    // votes
    ['OK      one option on a single-answer poll', 'ALLOW', 'ALLOW', ME, votePath(ME), 'create', vote([1]), null, poll(false)],
    ['OK      change a single-answer vote', 'ALLOW', 'ALLOW', ME, votePath(ME), 'update', vote([0]), vote([1]), poll(false)],
    ['OK      two options on a multiple-answer poll', 'ALLOW', 'ALLOW', ME, votePath(ME), 'create', vote([0, 2]), null, poll(true)],
    ['OK      two options on a poll from before the flag', 'ALLOW', 'ALLOW', ME, votePath(ME), 'create', vote([0, 2]), null, poll()],
    ['OK      take my vote back', 'ALLOW', 'ALLOW', ME, votePath(ME), 'delete', null, vote([1]), poll(false)],
    ['ATTACK  three options on a single-answer poll', 'ALLOW', 'DENY', ME, votePath(ME), 'create', vote([0, 1, 2]), null, poll(false)],
    ['ATTACK  eleven options on a multiple-answer poll', 'ALLOW', 'DENY',
      ME, votePath(ME), 'create', vote([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), null, poll(true)],
    ['ATTACK  vote whose options is not a list', 'ALLOW', 'DENY', ME, votePath(ME), 'create', vote('everything'), null, poll(true)],
    ['ATTACK  vote with an empty options list', 'ALLOW', 'DENY', ME, votePath(ME), 'create', vote([]), null, poll(true)],
    ['ATTACK  vote carrying an extra field', 'ALLOW', 'DENY', ME, votePath(ME), 'create', vote([1], { weight: 99 }), null, poll(true)],
    ['GUARD   vote written in THIRD\'s name', 'DENY', 'DENY', ME, votePath(THIRD), 'create', vote([1]), null, poll(true)],
  ];
}

// 2026-09-24 decisions D7 (calls), D8 (account block list) and D13 (markedUnread).
function privacyCases() {
  const ex = (p, v) => ({ function: 'exists', args: [{ exactValue: `${D}/${p}` }], result: { value: v } });
  const gt = (p, data) => ({ function: 'get', args: [{ exactValue: `${D}/${p}` }], result: { value: { data } } });
  const blockDoc = (owner, who) => `users/${owner}/blocked/${who}`;
  const pairDoc = (over = {}) => ({ users: [ME, THIRD], blockedBy: {}, lastMessage: 'hi', lastSender: ME, ...over });
  const base = [...notAdmin(ME), ...notAdmin(THIRD)];
  // A 1:1 message ME → THIRD (or THIRD → ME) in an existing pre-request chat.
  const msgMocks = (pair, blockedOnList, author = ME) => {
    const other = author === ME ? THIRD : ME;
    return [...base, ex(`conversations/${PAIR}`, true), gt(`conversations/${PAIR}`, pair),
      ex(blockDoc(other, author), blockedOnList)];
  };
  const newMsg = (author = ME) => [author, `${pairPath}/messages/m5`, 'create', { authorId: author, text: 'enc1:x' }, null];
  // ME rings THIRD.
  const callMocks = ({ calls, pair, listed = false }) => [
    ...base, ex(blockDoc(THIRD, ME), listed),
    ex(`conversations/${PAIR}`, !!pair), ...(pair ? [gt(`conversations/${PAIR}`, pair)] : []),
    ex(`users/${THIRD}`, true), gt(`users/${THIRD}`, { name: 'T', privacy: calls ? { calls } : {} }),
  ];
  const ring = (mocks) => [ME, `${D}/calls/c1`, 'create', { caller: ME, callee: THIRD, status: 'ringing', type: 'voice' }, null, mocks];
  const friends = pairDoc({ startedBy: THIRD, accepted: true });
  const pending = pairDoc({ startedBy: ME, accepted: false });
  // ME opens a new 1:1 with THIRD (born a request).
  const openMocks = (listed) => [
    ...base, ex(`users/${THIRD}`, true), gt(`users/${THIRD}`, { name: 'T', privacy: {} }),
    ex(`requestDeclines/${THIRD}/from/${ME}`, false), ex(blockDoc(THIRD, ME), listed),
    ex(`conversations/${PAIR}`, false),
  ];
  const open = [ME, pairPath, 'create', { users: [ME, THIRD], startedBy: ME, accepted: false, unreadCount: { [ME]: 0, [THIRD]: 0 } }, null];
  const listPath = `${D}/${blockDoc(ME, THIRD)}`;
  return [
    // D13
    ['FIX     D13 group member marks the group unread for themselves', 'DENY', 'ALLOW',
      ME, convPath, 'update', { ...group, markedUnread: { [ME]: true } }, group, members],
    ['GUARD   D13 group member sets THIRD\'s unread flag', 'DENY', 'DENY',
      ME, convPath, 'update', { ...group, markedUnread: { [THIRD]: true } }, group, members],
    ['OK      D13 1:1 member marks the chat unread for themselves', 'ALLOW', 'ALLOW',
      ME, pairPath, 'update', pairDoc({ markedUnread: { [ME]: true } }), pairDoc(), base],
    ['OK      D13 opening clears my flag (count to 0, flag removed)', 'ALLOW', 'ALLOW',
      ME, pairPath, 'update', pairDoc({ unreadCount: { [ME]: 0 } }), pairDoc({ unreadCount: { [ME]: -1 }, markedUnread: { [ME]: true } }), base],
    ['ATTACK  D13 1:1 member sets the other person\'s unread flag', 'ALLOW', 'DENY',
      ME, pairPath, 'update', pairDoc({ markedUnread: { [THIRD]: true } }), pairDoc(), base],
    // D8 the list itself
    ['FIX     D8 owner blocks somebody on their account list', 'DENY', 'ALLOW',
      ME, listPath, 'create', { at: REQ_TIME }, null, base],
    ['FIX     D8 owner unblocks (deletes the entry)', 'DENY', 'ALLOW', ME, listPath, 'delete', null, { at: REQ_TIME }, base],
    ['FIX     D8 owner reads their list entry', 'DENY', 'ALLOW', ME, listPath, 'get', null, { at: REQ_TIME }, base],
    ['GUARD   D8 the blocked person reads the blocker\'s list', 'DENY', 'DENY', THIRD, listPath, 'get', null, { at: REQ_TIME }, base],
    ['GUARD   D8 somebody writes into another person\'s list', 'DENY', 'DENY', THIRD, listPath, 'create', { at: REQ_TIME }, null, base],
    ['GUARD   D8 list entry carrying extra fields', 'DENY', 'DENY', ME, listPath, 'create', { at: REQ_TIME, note: 'x' }, null, base],
    // D8 new chat and messages. 2026-09-24 decision D8 correction: blocking is SILENT, so the
    // blocked person's new chat and message still write (they look sent); the blocker's app hides
    // them and onNewMessage skips the push. Only /calls refuses (rows below).
    ['OK      D8 start a chat with somebody who has not blocked me', 'ALLOW', 'ALLOW', ...open, openMocks(false)],
    ['SILENT  D8 start a chat with somebody who blocked me with no chat (lands, hidden)', 'ALLOW', 'ALLOW', ...open, openMocks(true)],
    ['OK      D8 message to somebody who has not blocked me', 'ALLOW', 'ALLOW', ...newMsg(), msgMocks(pairDoc(), false)],
    ['SILENT  D8 message to somebody who blocked me (account list, lands, hidden)', 'ALLOW', 'ALLOW', ...newMsg(), msgMocks(pairDoc(), true)],
    ['SILENT  D8 message to somebody who blocked me (old chat block, lands, hidden)', 'ALLOW', 'ALLOW',
      ...newMsg(), msgMocks(pairDoc({ blockedBy: { [THIRD]: true } }), false)],
    ['OK      D8 the blocker can still write to the person they blocked', 'ALLOW', 'ALLOW',
      ...newMsg(THIRD), msgMocks(pairDoc({ blockedBy: { [THIRD]: true } }), false, THIRD)],
    // D7 calls
    ['OK      D7 a friend rings (Calls: My Chats)', 'ALLOW', 'ALLOW', ...ring(callMocks({ calls: 'contacts', pair: friends }))],
    ['OK      D7 a stranger rings somebody set to Everyone', 'ALLOW', 'ALLOW', ...ring(callMocks({ calls: 'everyone' }))],
    ['OK      D7 an old pre-request chat with a message counts as a friend', 'ALLOW', 'ALLOW', ...ring(callMocks({ pair: pairDoc() }))],
    ['ATTACK  D7 a stranger rings somebody with the default (My Chats)', 'ALLOW', 'DENY', ...ring(callMocks({}))],
    ['ATTACK  D7 a stranger rings somebody set to the old "nobody"', 'ALLOW', 'DENY', ...ring(callMocks({ calls: 'nobody' }))],
    ['ATTACK  D7 an unanswered requester rings (not a friend yet)', 'ALLOW', 'DENY', ...ring(callMocks({ calls: 'contacts', pair: pending }))],
    ['ATTACK  D7 a blocked friend rings (account list)', 'ALLOW', 'DENY',
      ...ring(callMocks({ calls: 'contacts', pair: friends, listed: true }))],
    ['ATTACK  D7 a blocked person rings somebody set to Everyone (chat block)', 'ALLOW', 'DENY',
      ...ring(callMocks({ calls: 'everyone', pair: pairDoc({ blockedBy: { [THIRD]: true } }) }))],
  ];
}

// 2026-09-24 decisions D-admin-resurrect / D-admin-security / D-admin-fanout.
function adminCases() {
  const B = `${D}/announcements/b1`, L = `${D}/announcementLog/a1`, C = `${D}/users/${ME}/announcements/a1`;
  const gone = { deleted: true, deletedAt: REQ_TIME };
  const log = (over = {}) => ({ recipients: [ME], deliveredCount: 0, ...ann(over) });
  return [
    ['OK      edit admin fixes a live broadcast', 'ALLOW', 'ALLOW', ADM, B, 'update',
      broadcast({ title: 'Changed', editedAt: REQ_TIME }), broadcast(), staff(['edit'])],
    ['ATTACK  edit brings back a WITHDRAWN broadcast', 'ALLOW', 'DENY', ADM, B, 'update',
      broadcast({ title: 'Changed', editedAt: REQ_TIME }), broadcast(gone), staff(['edit'])],
    ['ATTACK  edit brings back a withdrawn chosen record', 'ALLOW', 'DENY', ADM, L, 'update',
      log({ title: 'Changed' }), log(gone), staff(['edit', 'targetChosen'])],
    ['ATTACK  edit brings back a withdrawn person\'s copy', 'ALLOW', 'DENY', ADM, C, 'update',
      ann({ title: 'Changed' }), ann(gone), staff(['edit', 'targetChosen'])],
    ['ATTACK  edit rewrites a withdrawn copy, keeping it withdrawn', 'ALLOW', 'DENY', ADM, C, 'update',
      ann({ ...gone, title: 'Changed' }), ann(gone), staff(['edit', 'targetChosen'])],
    ['FIX     edit-only admin fixes a typo in a security alert', 'DENY', 'ALLOW', ADM, B, 'update',
      broadcast({ kind: 'security', title: 'Fixed' }), broadcast({ kind: 'security' }), staff(['edit'])],
    ['ATTACK  edit-only admin strips the Security kind', 'ALLOW', 'DENY', ADM, B, 'update',
      broadcast({ kind: 'news' }), broadcast({ kind: 'security' }), staff(['edit'])],
    ['ATTACK  edit-only admin strips Security from a person\'s copy', 'ALLOW', 'DENY', ADM, C, 'update',
      ann({ kind: 'news' }), ann({ kind: 'security' }), staff(['edit', 'targetChosen'])],
    ['OK      security admin changes a security alert to news', 'ALLOW', 'ALLOW', ADM, B, 'update',
      broadcast({ kind: 'news' }), broadcast({ kind: 'security' }), staff(['edit', 'security'])],
    ['ATTACK  edit turns an everyone broadcast into a country send', 'ALLOW', 'DENY', ADM, B, 'update',
      broadcast({ audience: { scope: 'countries', countries: ['US'], chosenCount: 0 } }), broadcast(),
      staff(['edit', 'targetCountry'])],
    ['OK      sender counts delivered copies onto the chosen record', 'ALLOW', 'ALLOW', ADM, L, 'update',
      log({ deliveredCount: 1 }), log(), staff(['send', 'targetChosen'])],
    ['ATTACK  delivered count above the recipient list', 'ALLOW', 'DENY', ADM, L, 'update',
      log({ deliveredCount: 5 }), log(), staff(['send', 'targetChosen'])],
    ['ATTACK  delivered count onto a withdrawn record', 'ALLOW', 'DENY', ADM, L, 'update',
      log({ ...gone, deliveredCount: 1 }), log(gone), staff(['send', 'targetChosen'])],
  ];
}

// 2026-09-24 decisions D1 and D6. D1 rows read my own profile (`allow get: if signedIn()`), so
// the only thing that changes between them is the token.
function accountCases() {
  const up = `${D}/users/${ME}`;
  const m = [...notAdmin(ME)];
  const T = Math.floor(now / 1000) - 3600;   // this session's sign-in, an hour ago
  const ts = (claim, at = T) => ({ auth_time: at, ...(claim ? { twoStep: claim } : {}) });
  const read = (tok) => [ME, up, 'get', null, { name: 'A' }, m, tok];
  return [
    ['OK      D1 account without two-step reads its profile', 'ALLOW', 'ALLOW', ...read(ts(null))],
    ['OK      D1 sign-in that entered the password (on the list)', 'ALLOW', 'ALLOW',
      ...read(ts({ required: true, ok: true, at: now, authTimes: [T - 50, T] }))],
    ['OK      D1 old-style claim, session let in before it (kept after deploy)', 'ALLOW', 'ALLOW',
      ...read(ts({ required: true, ok: true, at: (T + 60) * 1000 }))],
    ['OK      D1 old session still in after a new device verified (legacyAt)', 'ALLOW', 'ALLOW',
      ...read(ts({ required: true, ok: true, at: now, authTimes: [T + 900], legacyAt: (T + 60) * 1000 }))],
    ['ATTACK  D1 fresh sign-in rides another session\'s pass', 'ALLOW', 'DENY',
      ...read(ts({ required: true, ok: true, at: now, authTimes: [T] }, T + 500))],
    ['ATTACK  D1 fresh sign-in after an old-style claim', 'ALLOW', 'DENY',
      ...read(ts({ required: true, ok: true, at: (T + 60) * 1000 }, T + 120))],
    ['ATTACK  D1 locked sign-in let in by a LATER device verifying', 'ALLOW', 'DENY',
      ...read(ts({ required: true, ok: true, at: now, authTimes: [T + 900] }, T + 500))],
    ['GUARD   D1 required and not passed', 'DENY', 'DENY', ...read(ts({ required: true, ok: false }))],

    ['OK      D6 restore removes the deletion date', 'ALLOW', 'ALLOW',
      ME, up, 'update', { name: 'A' }, { name: 'A', deletionScheduledFor: iso(now + 86400e3), isHidden: true }, m],
    ['OK      D6 profile edit on an account with a date leaves it alone', 'ALLOW', 'ALLOW',
      ME, up, 'update', { name: 'B', deletionScheduledFor: iso(now + 86400e3) },
      { name: 'A', deletionScheduledFor: iso(now + 86400e3) }, m],
    ['ATTACK  D6 phone writes its own deletion date', 'ALLOW', 'DENY',
      ME, up, 'update', { name: 'A', deletionScheduledFor: iso(now + 365 * 86400e3), isHidden: true }, { name: 'A' }, m],
    ['ATTACK  D6 phone moves an existing deletion date', 'ALLOW', 'DENY',
      ME, up, 'update', { name: 'A', deletionScheduledFor: iso(now + 365 * 86400e3) },
      { name: 'A', deletionScheduledFor: iso(now + 86400e3) }, m],
    ['ATTACK  D6 profile created with a deletion date', 'ALLOW', 'DENY',
      ME, up, 'create', { name: 'A', deletionScheduledFor: iso(now) }, null, m],
  ];
}

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

    // 2026-09-24 decision D23: the owner's leave hands ownership on, and only that write may move it
    ['OK      owner leaves, ownership to the longest-serving admin (D23)', 'ALLOW', 'ALLOW',
      ...up(ADMIN, { users: [LIM, LEG, ME, THIRD], admins: [LIM, LEG], createdBy: LIM, adminRights: {},
                     lastMessage: 'x left', lastSender: ADMIN })],
    ['OK      sole-admin owner leaves, ownership to the first member (D23)', 'ALLOW', 'ALLOW',
      ADMIN, convPath, 'update', clean(left(soloOwner, { _who: ADMIN, admins: [ME], createdBy: ME })), soloOwner, m],
    ['FIX     admin renames a group whose owner already left (D23)', 'DENY', 'ALLOW',
      ...up(ADMIN, { title: 'New name' }, ownerGone)],
    ['ATTACK  owner leaves and hands ownership to an outsider (D23)', 'ALLOW', 'DENY',
      ...up(ADMIN, { users: [LIM, LEG, ME, THIRD], admins: [LIM, LEG], createdBy: NEW })],
    ['ATTACK  owner leaves and names a non-admin the owner (D23)', 'ALLOW', 'DENY',
      ...up(ADMIN, { users: [LIM, LEG, ME, THIRD], admins: [LIM, LEG], createdBy: THIRD })],
    ['ATTACK  owner gives the group away without leaving (D23)', 'ALLOW', 'DENY', ...up(ADMIN, { createdBy: LEG })],
    ['GUARD   admin removes the owner while the owner is a member (D23)', 'DENY', 'DENY',
      ...up(LEG, { users: [LIM, LEG, ME, THIRD], admins: [LIM, LEG] })],

    // 2026-09-24 decision D24: admins are held to the members' private-map pin
    ['OK      admin mutes the group for themselves (D24)', 'ALLOW', 'ALLOW', ...up(LEG, { mutedBy: { [LEG]: 1e15 } })],
    ['OK      owner marks their own read (D24)', 'ALLOW', 'ALLOW', ...up(ADMIN, { lastRead: { [ADMIN]: REQ_TIME } })],
    ['ATTACK  owner mutes THIRD (D24)', 'ALLOW', 'DENY', ...up(ADMIN, { mutedBy: { [THIRD]: 1e15 } })],
    ['ATTACK  admin forges THIRD\'s read receipt (D24)', 'ALLOW', 'DENY', ...up(LEG, { lastRead: { [THIRD]: REQ_TIME } })],
    ['ATTACK  admin clears THIRD\'s copy of the chat (D24)', 'ALLOW', 'DENY', ...up(LEG, { clearedAt: { [THIRD]: now } })],
  ];
}

// 2026-09-24 decision D1: an optional 10th element adds claims to the token (auth_time, twoStep).
async function run(t, source, [, , , uid, path, method, after, before, mocks, tok], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' }, ...(tok || {}) } },
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
