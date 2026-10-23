// 2026-10-23 FULL AUDIT, FIX PHASE: the Firestore rules half.
//   H1  a message request is accepted only by the person written to; `lastSender` cannot be forged
//   F3  an admin without rights cannot rename or re-photo other members
//   F4  nobody is put in a group with someone who blocked them, or whom they blocked
//   G1  an ended group cannot be edited or grown
//   H5  the group-story minimum no longer trusts the story's own `posterCountry`
//   F6  a group call row is written in the writer's own name
// Each row runs against the rules BEFORE the change and AFTER it. README: plain JSON, mock every get().
//
//   git show HEAD:firestore.rules > before-audit1023.rules
//   node audit-fix-1023.test.js before-audit1023.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node audit-fix-1023.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const NOW = new Date(), REQ_TIME = NOW.toISOString();
const EARLIER = new Date(NOW.getTime() - 3600e3).toISOString();
const EXPIRES = new Date(NOW.getTime() + 24 * 3600e3).toISOString();

const getM = (path, data) => [
  { function: 'exists', args: [{ exactValue: path }], result: { value: true } },
  { function: 'get', args: [{ exactValue: path }], result: { value: { data } } },
];
const yes = (path) => ({ function: 'exists', args: [{ exactValue: path }], result: { value: true } });

// ── H1: 1:1 message requests. A opened the chat (startedBy A). ──
const A = 'uidAAA', B = 'uidBBB';
const DM = [A, B].sort().join('_');
const dmPath = `${D}/conversations/${DM}`;
const dmBase = { users: [A, B], type: '', names: {}, photos: {}, blockedBy: {}, mutedBy: {},
  clearedAt: {}, lastRead: {}, unreadCount: {}, archivedBy: {}, pinnedBy: {}, updatedAt: EARLIER };
const fresh = { ...dmBase, startedBy: A, accepted: false, lastSender: '', lastMessage: '' };
const aKnocked = { ...fresh, lastSender: A, lastMessage: 'enc1:hi' };
const bKnocked = { ...fresh, lastSender: B, lastMessage: 'enc1:hi' };   // A opened, B wrote first
const friends = { ...dmBase, startedBy: A, accepted: true, lastSender: B, lastMessage: 'enc1:x' };

// ── groups ──
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember', NEW = 'uidNew', V = 'uidVictim';
const GID = 'grpAudit1';
const gPath = `${D}/conversations/${GID}`;
const group = (over = {}) => ({
  type: 'group', title: 'Plans', users: [OWNER, ADMIN, MEMBER], admins: [OWNER, ADMIN], createdBy: OWNER,
  adminRights: { [ADMIN]: [] },
  names: { [OWNER]: 'O', [ADMIN]: 'A', [MEMBER]: 'M' }, photos: {},
  unreadCount: { [OWNER]: 0, [ADMIN]: 0, [MEMBER]: 0 }, updatedAt: EARLIER, ...over,
});
const g = group();
const gInvite = group({ adminRights: { [ADMIN]: ['inviteUsers'] } });
const gInfo = group({ adminRights: { [ADMIN]: ['changeInfo'] } });
const gMembersAdd = group({ membersCanAdd: true });
const gEnded = group({ endedAt: EARLIER });
const bigUsers = [OWNER, ADMIN, MEMBER, ...Array.from({ length: 26 }, (_, i) => `uidB${i}`)];
const big = group({ users: bigUsers, adminRights: { [ADMIN]: ['inviteUsers', 'changeInfo', 'banUsers', 'pinMessages'] },
  names: Object.fromEntries(bigUsers.map((u) => [u, u])), photos: Object.fromEntries(bigUsers.map((u) => [u, `https://x/${u}`])),
  unreadCount: Object.fromEntries(bigUsers.map((u) => [u, 0])), bannedUids: [NEW], pinnedMessageIds: ['m1'] });
const add = (base, who, over = {}) => ({ ...base, users: [...base.users, who],
  names: { ...base.names, [who]: who }, unreadCount: { ...base.unreadCount, [who]: 0 }, updatedAt: REQ_TIME, ...over });
const blockedBy = (blocker, blocked) => yes(`${D}/users/${blocker}/blocked/${blocked}`);

// ── H5: group stories ──
const SID = 'storyAud1';
const fill = (n) => Array.from({ length: n }, (_, i) => `uidF${i}`);
const sGroup = (size) => ({ type: 'group', title: 'G', users: [OWNER, ADMIN, ...fill(size - 2)],
  admins: [OWNER, ADMIN], createdBy: OWNER, updatedAt: EARLIER });
const story = (author, country) => ({
  authorUid: author, createdAt: REQ_TIME, expiresAt: EXPIRES, recipientUids: ['tokA'],
  mediaPath: `stories/${SID}/photo.jpg`, type: 'image', mediaUrl: '', caption: '', replyCount: 0,
  public: false, allowsReplies: true, oneTime: false, audienceLabel: 'friends',
  ...(country !== undefined ? { audienceLabel: 'group', groupId: GID, groupName: 'G', groupPhoto: '' } : {}),
  ...(country ? { posterCountry: country } : {}),
});
const storyMocks = (uid, conv, { config = null, open = false } = {}) => [
  { function: 'exists', args: [{ exactValue: `${D}/admins/${uid}` }], result: { value: false } },
  ...getM(`${D}/users/${uid}`, { banned: false, ...(open ? { groupStoryOpen: true } : {}) }),
  { function: 'exists', args: [{ exactValue: `${D}/config/limits` }], result: { value: config !== null } },
  ...(config ? [{ function: 'get', args: [{ exactValue: `${D}/config/limits` }], result: { value: { data: config } } }] : []),
  ...getM(gPath, conv),
];
const soCheap = { group_story_min_members: 50, group_story_countries: { SO: 5 } };

// ── F6: call rows ──
const callRow = (caller) => ({ type: 'call', authorId: caller, callerUid: caller, callOutcome: 'missed',
  callVideo: false, text: '', createdAt: REQ_TIME });
const gMsg = `${gPath}/messages/call_abc`;
const dmMsg = `${dmPath}/messages/call_abc`;

const S = (p) => `${D}/stories/${p}`;
// [name, before, after, uid, path, method, newData, oldData, mocks]
const cases = [
  // H1 — the holes.
  ['FIX  H1 the opener writes "B spoke last" on a fresh request', 'ALLOW', 'DENY', A, dmPath, 'update',
    { ...fresh, lastSender: B, lastMessage: 'enc1:hi' }, fresh, []],
  ['FIX  H1 B wrote first into A\'s opened chat, B accepts', 'ALLOW', 'DENY', B, dmPath, 'update',
    { ...bKnocked, accepted: true }, bKnocked, []],
  ['FIX  H1 B accepts a chat nobody wrote in', 'ALLOW', 'DENY', B, dmPath, 'update',
    { ...fresh, accepted: true }, fresh, []],
  // H1 — normal use.
  ['OK   H1 B accepts A\'s knock (Accept button)', 'ALLOW', 'ALLOW', B, dmPath, 'update',
    { ...aKnocked, accepted: true }, aKnocked, []],
  ['OK   H1 B replies to A\'s knock (reply carries accepted)', 'ALLOW', 'ALLOW', B, dmPath, 'update',
    { ...aKnocked, lastSender: B, lastMessage: 'enc1:yo', accepted: true, updatedAt: REQ_TIME }, aKnocked, []],
  ['OK   H1 A accepts B\'s knock (A opened, B wrote first)', 'ALLOW', 'ALLOW', A, dmPath, 'update',
    { ...bKnocked, accepted: true }, bKnocked, []],
  ['OK   H1 B knocks first into A\'s opened chat', 'ALLOW', 'ALLOW', B, dmPath, 'update',
    { ...fresh, lastSender: B, lastMessage: 'enc1:hi', updatedAt: REQ_TIME }, fresh, []],
  ['OK   H1 B deletes their knock: summary goes to empty', 'ALLOW', 'ALLOW', B, dmPath, 'update',
    { ...bKnocked, lastSender: '', lastMessage: '' }, bKnocked, []],
  ['GUARD H1 A accepts their own knock', 'DENY', 'DENY', A, dmPath, 'update',
    { ...aKnocked, accepted: true }, aKnocked, []],
  ['OK   H1 friends: summary rewrite names the other (ChatService 3421)', 'ALLOW', 'ALLOW', B, dmPath, 'update',
    { ...friends, lastSender: A, lastMessage: 'This message was deleted' }, friends, []],
  ['OK   H1 friends: callee\'s call line names the caller (ChatService 3155)', 'ALLOW', 'ALLOW', B, dmPath, 'update',
    { ...friends, lastSender: A, lastMessage: '📞 Missed call', updatedAt: REQ_TIME }, friends, []],
  ['OK   H1 friends: an ordinary send', 'ALLOW', 'ALLOW', A, dmPath, 'update',
    { ...friends, lastSender: A, lastMessage: 'enc1:z', updatedAt: REQ_TIME, unreadCount: { [B]: 1 } }, friends, []],

  // F3 — names/photos by a rights-less admin.
  ['FIX  F3 admin with no rights renames a member', 'ALLOW', 'DENY', ADMIN, gPath, 'update',
    { ...g, names: { ...g.names, [MEMBER]: 'SCAMMER' } }, g, []],
  ['FIX  F3 admin with no rights swaps a member\'s photo', 'ALLOW', 'DENY', ADMIN, gPath, 'update',
    { ...g, photos: { [MEMBER]: 'https://x/fake.jpg' } }, g, []],
  ['OK   F3 admin refreshes their own name', 'ALLOW', 'ALLOW', ADMIN, gPath, 'update',
    { ...g, names: { ...g.names, [ADMIN]: 'New me' } }, g, []],
  ['OK   F3 admin with changeInfo renames the group', 'ALLOW', 'ALLOW', ADMIN, gPath, 'update',
    { ...gInfo, title: 'New title' }, gInfo, []],
  ['GUARD F3 a plain member renames another member', 'DENY', 'DENY', MEMBER, gPath, 'update',
    { ...g, names: { ...g.names, [ADMIN]: 'x' } }, g, []],

  // F4 — blocks on group create and add.
  ['FIX  F4 create a group with someone who blocked me', 'ALLOW', 'DENY', OWNER, `${D}/conversations/grpNew1`, 'create',
    { type: 'group', title: 'G', users: [OWNER, V], admins: [OWNER], createdBy: OWNER, unreadCount: { [OWNER]: 0, [V]: 0 } }, null,
    [blockedBy(V, OWNER)]],
  ['FIX  F4 create a group with someone I blocked', 'ALLOW', 'DENY', OWNER, `${D}/conversations/grpNew1`, 'create',
    { type: 'group', title: 'G', users: [V, OWNER], admins: [OWNER], createdBy: OWNER }, null,
    [blockedBy(OWNER, V)]],
  ['OK   F4 create a group with no blocks', 'ALLOW', 'ALLOW', OWNER, `${D}/conversations/grpNew1`, 'create',
    { type: 'group', title: 'G', users: [OWNER, V, NEW], admins: [OWNER], createdBy: OWNER }, null, []],
  ['FIX  F4 admin (Add members) adds someone who blocked them', 'ALLOW', 'DENY', ADMIN, gPath, 'update',
    add(gInvite, V), gInvite, [blockedBy(V, ADMIN)]],
  ['FIX  F4 the owner adds someone they blocked', 'ALLOW', 'DENY', OWNER, gPath, 'update',
    add(g, V), g, [blockedBy(OWNER, V)]],
  ['FIX  F4 a member (Members can add) adds someone who blocked them', 'ALLOW', 'DENY', MEMBER, gPath, 'update',
    add(gMembersAdd, V), gMembersAdd, [blockedBy(V, MEMBER)]],
  ['FIX  F4 an add that reshuffles the old list', 'ALLOW', 'DENY', OWNER, gPath, 'update',
    { ...add(g, NEW), users: [NEW, OWNER, ADMIN, MEMBER] }, g, []],
  ['OK   F4 admin (Add members) adds a new person', 'ALLOW', 'ALLOW', ADMIN, gPath, 'update',
    add(gInvite, NEW), gInvite, []],
  ['OK   F4 the app\'s full admin add, 29 to 30 members (expression ceiling)', 'ALLOW', 'ALLOW', ADMIN, gPath, 'update',
    add(big, NEW, { photos: { ...big.photos, [NEW]: 'https://x/n.jpg' }, posters: { [NEW]: 'https://x/np.jpg' },
      bannedUids: [], lastMessage: 'A added N', lastSender: ADMIN }), big, []],
  ['FIX  F3 admin (Add members) adds and renames another member', 'ALLOW', 'DENY', ADMIN, gPath, 'update',
    add(gInvite, NEW, { names: { ...gInvite.names, [NEW]: NEW, [MEMBER]: 'SCAMMER' } }), gInvite, []],
  ['OK   F4 a member (Members can add) adds a new person', 'ALLOW', 'ALLOW', MEMBER, gPath, 'update',
    add(gMembersAdd, NEW, { lastMessage: 'M added N', lastSender: MEMBER }), gMembersAdd, []],
  ['OK   F4 a member sends (no growth, no lookups)', 'ALLOW', 'ALLOW', MEMBER, gPath, 'update',
    { ...g, lastMessage: 'hello', lastSender: MEMBER, updatedAt: REQ_TIME,
      unreadCount: { [OWNER]: 1, [ADMIN]: 1, [MEMBER]: 0 } }, g, []],

  // G1 — ended groups.
  ['FIX  G1 owner renames an ended group', 'ALLOW', 'DENY', OWNER, gPath, 'update',
    { ...gEnded, title: 'Back again' }, gEnded, []],
  ['FIX  G1 owner adds a member to an ended group', 'ALLOW', 'DENY', OWNER, gPath, 'update',
    add(gEnded, NEW), gEnded, []],
  ['FIX  G1 owner changes a setting in an ended group', 'ALLOW', 'DENY', OWNER, gPath, 'update',
    { ...gEnded, onlyAdminsSend: true }, gEnded, []],
  ['FIX  G1 owner changes the photo of an ended group', 'ALLOW', 'DENY', OWNER, gPath, 'update',
    { ...gEnded, avatarUrl: 'https://x/p.jpg' }, gEnded, []],
  ['OK   G1 a member leaves an ended group', 'ALLOW', 'ALLOW', MEMBER, gPath, 'update',
    { ...gEnded, users: [OWNER, ADMIN], updatedAt: REQ_TIME }, gEnded, []],
  ['OK   G1 a member marks an ended group read', 'ALLOW', 'ALLOW', MEMBER, gPath, 'update',
    { ...gEnded, lastRead: { [MEMBER]: REQ_TIME }, unreadCount: { ...gEnded.unreadCount } }, gEnded, []],
  ['OK   G1 owner renames a live group', 'ALLOW', 'ALLOW', OWNER, gPath, 'update',
    { ...g, title: 'Renamed' }, g, []],

  // H5 — group story country minimum.
  ['FIX  H5 10-member group claims SO (min 5) against a global 50', 'ALLOW', 'DENY', OWNER, S(SID), 'create',
    story(OWNER, 'SO'), null, storyMocks(OWNER, sGroup(10), { config: soCheap })],
  ['OK   H5 a 50-member group, any country', 'ALLOW', 'ALLOW', OWNER, S(SID), 'create',
    story(OWNER, 'KE'), null, storyMocks(OWNER, sGroup(50), { config: soCheap })],
  ['OK   H5 a person the panel opened, 10-member group', 'ALLOW', 'ALLOW', OWNER, S(SID), 'create',
    story(OWNER, ''), null, storyMocks(OWNER, sGroup(10), { config: soCheap, open: true })],
  ['OK   H5 an ordinary story', 'ALLOW', 'ALLOW', MEMBER, S(SID), 'create',
    story(MEMBER), null, storyMocks(MEMBER, sGroup(10))],

  // F6 — call rows.
  ['FIX  F6 a member writes a group call row as the owner', 'ALLOW', 'DENY', MEMBER, gMsg, 'create',
    callRow(OWNER), null, getM(gPath, g)],
  ['OK   F6 a member writes their own group call row', 'ALLOW', 'ALLOW', MEMBER, gMsg, 'create',
    callRow(MEMBER), null, getM(gPath, g)],
  ['OK   F6 1:1 callee writes the row naming the caller', 'ALLOW', 'ALLOW', B, dmMsg, 'create',
    callRow(A), null, getM(dmPath, friends)],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = { auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, path: p, method, time: REQ_TIME };
  if (after) request.resource = { data: after };
  // Not staff, not blocked, no config: production's answer for every other lookup here.
  const testCase = { expectation, request, functionMocks: [...(mocks || []), { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
  if (before) testCase.resource = { data: before };
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ source: { files: [{ name: 'firestore.rules', content: source }] }, testSuite: { testCases: [testCase] } }),
  });
  const j = await r.json();
  if (j.error) return { state: 'APIERROR', detail: JSON.stringify(j.error).slice(0, 300) };
  if (j.issues && j.issues.length) return { state: 'COMPILE', detail: JSON.stringify(j.issues).slice(0, 300) };
  const res = j.testResults && j.testResults[0];
  return { state: (res && res.state) || 'NORESULT', detail: ((res && res.debugMessages) || []).join(' | ').slice(0, 300)
    + (res && res.errorPosition ? ` (line ${res.errorPosition.line})` : '') };
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
