// 2026-10-18 group moderation: the group's `mod` (limited / suspended / disabled) and `verified` are
// the admin panel's alone, and a restricted group refuses what its state forbids (groupModBlocked,
// groupModClosed, groupModWriteOK in firestore.rules). Each row runs against the rules BEFORE the
// change and AFTER it. README: plain JSON (an ISO string is a timestamp), mock every get().
//
//   node gmod-1018.test.js before-gmod.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node gmod-1018.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', ADMIN = 'uidAdmin', MEMBER = 'uidMember', NEWBIE = 'uidNewbie';
const CID = 'grpMod1';
const NOW = Date.now();
const REQ_TIME = new Date(NOW).toISOString();
const LATER = new Date(NOW + 7 * 864e5).toISOString();
const EARLIER = new Date(NOW - 3600e3).toISOString();
const convPath = `${D}/conversations/${CID}`;
const msgPath = `${convPath}/messages/msgMod1`;
const invPath = `${D}/invites/codeMod1`;

const users = [OWNER, ADMIN, MEMBER];
const group = (over = {}) => ({
  type: 'group', title: 'Market', users, admins: [OWNER, ADMIN], createdBy: OWNER,
  names: Object.fromEntries(users.map((u) => [u, u])),
  unreadCount: Object.fromEntries(users.map((u) => [u, 0])),
  updatedAt: REQ_TIME, ...over,
});
const mod = (state, until = null) => ({ mod: { state, reason: 'spam', label: null, until, at: REQ_TIME, notice: 'x' } });
const OK = group();
const LIM = group(mod('limited'));
const SUS = group(mod('suspended', LATER));
const SUS_OVER = group(mod('suspended', EARLIER));
const SUS_OPEN = group(mod('suspended', null));
const DIS = group(mod('disabled'));
const convMocks = (data) => ([
  { function: 'get', args: [{ exactValue: convPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: convPath }], result: { value: true } },
]);
const msg = (by) => ({ authorId: by, text: 'enc1:AAAA', createdAt: REQ_TIME });
const with_ = (base, over) => ({ ...base, ...over });
// A member leaving, as ChatService.leaveGroup writes it.
const left = (base) => with_(base, { users: [OWNER, ADMIN], lastMessage: 'uidMember left', lastSender: MEMBER, updatedAt: REQ_TIME });
const added = (base) => with_(base, { users: [...users, NEWBIE], names: { ...base.names, [NEWBIE]: NEWBIE } });
const inv = (over = {}) => ({ cid: CID, createdBy: OWNER, revoked: false, expireAt: 0, usageLimit: 0, usedCount: 0, ...over });

const callPath = `${D}/groupCalls/${CID}`;
const call = (by) => ({ active: true, startedBy: by, video: false, title: 'Market', startedAt: REQ_TIME });
const stored = (by) => ({ authorId: by, text: 'enc1:AAAA', createdAt: REQ_TIME });
const edited = (m) => ({ ...m, text: 'enc1:BBBB', edited: true, editedAt: REQ_TIME, edits: [{ t: m.text, at: REQ_TIME }] });
const tomb = (m) => ({ authorId: m.authorId, createdAt: m.createdAt, deleted: true, text: '', type: 'text' });
const votePath = `${msgPath}/votes/${MEMBER}`;
const pollMocks = [{ function: 'get', args: [{ exactValue: msgPath }], result: { value: { data: { ...stored(ADMIN), type: 'poll', pollMulti: false } } } },
  { function: 'exists', args: [{ exactValue: msgPath }], result: { value: true } }];

// A plain 1:1 the two may write any field of.
const dmPath = `${D}/conversations/dmMod1`;
const dm = (over = {}) => ({
  type: 'direct', users: [OWNER, MEMBER], accepted: true, startedBy: OWNER, lastSender: MEMBER,
  unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME, ...over,
});
const dmMocks = (data) => ([
  { function: 'get', args: [{ exactValue: dmPath }], result: { value: { data } } },
  { function: 'exists', args: [{ exactValue: dmPath }], result: { value: true } },
]);
const newPath = `${D}/conversations/grpModNew`;
const born = (over = {}) => ({ type: 'group', title: 'New', users: [OWNER, MEMBER], admins: [OWNER], createdBy: OWNER, createdAt: REQ_TIME,
  names: { [OWNER]: OWNER, [MEMBER]: MEMBER }, photos: {}, unreadCount: { [OWNER]: 0, [MEMBER]: 0 }, updatedAt: REQ_TIME, ...over });

const cases = [
  // ── sending ──
  ['OK      a member sends in a group in good standing', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg(MEMBER), null, convMocks(OK)],
  ['FIX     a member sends while suspended', 'ALLOW', 'DENY', MEMBER, msgPath, 'create', msg(MEMBER), null, convMocks(SUS)],
  ['FIX     the owner sends while suspended', 'ALLOW', 'DENY', OWNER, msgPath, 'create', msg(OWNER), null, convMocks(SUS)],
  ['FIX     a member sends while suspended until lifted (no end date)', 'ALLOW', 'DENY', MEMBER, msgPath, 'create', msg(MEMBER), null, convMocks(SUS_OPEN)],
  ['FIX     a member sends in a disabled group', 'ALLOW', 'DENY', MEMBER, msgPath, 'create', msg(MEMBER), null, convMocks(DIS)],
  ['OK      a member sends after the suspension ran out', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg(MEMBER), null, convMocks(SUS_OVER)],
  ['OK      a member sends in a limited group', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'create', msg(MEMBER), null, convMocks(LIM)],

  // ── the fields are the server's ──
  ['FIX     the owner lifts their own suspension', 'ALLOW', 'DENY', OWNER, convPath, 'update', with_(SUS, mod('ok')), SUS, convMocks(SUS)],
  ['FIX     the owner gives the group a badge', 'ALLOW', 'DENY', OWNER, convPath, 'update', with_(OK, { verified: true }), OK, convMocks(OK)],
  ['FIX     the owner removes a Scam label', 'ALLOW', 'DENY', OWNER, convPath, 'update',
    with_(OK, { mod: { state: 'ok', label: null } }), with_(OK, { mod: { state: 'ok', label: 'scam' } }), convMocks(with_(OK, { mod: { state: 'ok', label: 'scam' } }))],
  ['FIX     a 1:1 member writes `mod`', 'ALLOW', 'DENY', MEMBER, dmPath, 'update', dm(mod('ok')), dm(), dmMocks(dm())],
  ['FIX     a group born with a badge', 'ALLOW', 'DENY', OWNER, newPath, 'create', born({ verified: true })],
  ['FIX     a group born with `mod`', 'ALLOW', 'DENY', OWNER, newPath, 'create', born(mod('ok'))],
  ['OK      a plain new group', 'ALLOW', 'ALLOW', OWNER, newPath, 'create', born()],

  // ── adding people ──
  ['OK      the owner adds someone in good standing', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', added(OK), OK, convMocks(OK)],
  ['FIX     the owner adds someone while limited', 'ALLOW', 'DENY', OWNER, convPath, 'update', added(LIM), LIM, convMocks(LIM)],
  ['FIX     the owner adds someone while suspended', 'ALLOW', 'DENY', OWNER, convPath, 'update', added(SUS), SUS, convMocks(SUS)],
  ['OK      the owner adds someone after the suspension ran out', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', added(SUS_OVER), SUS_OVER, convMocks(SUS_OVER)],

  // ── changing the group ──
  ['FIX     the owner renames a suspended group', 'ALLOW', 'DENY', OWNER, convPath, 'update', with_(SUS, { title: 'Free money' }), SUS, convMocks(SUS)],
  ['FIX     an admin renames a disabled group', 'ALLOW', 'DENY', ADMIN, convPath, 'update', with_(DIS, { title: 'Free money' }), DIS, convMocks(DIS)],
  ['OK      the owner renames a limited group', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', with_(LIM, { title: 'Market 2' }), LIM, convMocks(LIM)],
  ['FIX     the owner sets a new invite code while suspended', 'ALLOW', 'DENY', OWNER, convPath, 'update', with_(SUS, { inviteCode: 'abc123' }), SUS, convMocks(SUS)],
  ['FIX     the owner hands the group on while suspended (staying in)', 'ALLOW', 'DENY', OWNER, convPath, 'update', with_(SUS, { createdBy: ADMIN }), SUS, convMocks(SUS)],
  ['FIX     a member writes a chat-list preview while suspended', 'ALLOW', 'DENY', MEMBER, convPath, 'update',
    with_(SUS, { lastMessage: 'enc1:BBBB', lastSender: MEMBER }), SUS, convMocks(SUS)],

  // ── what still works ──
  ['OK      a member leaves a suspended group', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update', left(SUS), SUS, convMocks(SUS)],
  ['OK      a member leaves a disabled group', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update', left(DIS), DIS, convMocks(DIS)],
  ['OK      a member marks a disabled group read', 'ALLOW', 'ALLOW', MEMBER, convPath, 'update',
    with_(DIS, { lastRead: { [MEMBER]: REQ_TIME } }), DIS, convMocks(DIS)],
  ['OK      the owner removes a member from a suspended group', 'ALLOW', 'ALLOW', OWNER, convPath, 'update',
    with_(SUS, { users: [OWNER, ADMIN] }), SUS, convMocks(SUS)],

  // ── invite links ──
  ['OK      the owner makes a link in good standing', 'ALLOW', 'ALLOW', OWNER, invPath, 'create', inv(), null, convMocks(OK)],
  ['FIX     the owner makes a link while limited', 'ALLOW', 'DENY', OWNER, invPath, 'create', inv(), null, convMocks(LIM)],
  ['FIX     the owner makes a link while suspended', 'ALLOW', 'DENY', OWNER, invPath, 'create', inv(), null, convMocks(SUS)],
  ['OK      the owner switches a link off while suspended', 'ALLOW', 'ALLOW', OWNER, invPath, 'update', inv({ revoked: true }), inv(), convMocks(SUS)],
  ['FIX     the owner switches a link back on while suspended', 'ALLOW', 'DENY', OWNER, invPath, 'update', inv(), inv({ revoked: true }), convMocks(SUS)],
  ['FIX     the owner lifts a link\'s usage limit while limited', 'ALLOW', 'DENY', OWNER, invPath, 'update', inv({ usageLimit: 0 }), inv({ usageLimit: 5 }), convMocks(LIM)],
  ['OK      the owner deletes a link of a disabled group', 'ALLOW', 'ALLOW', OWNER, invPath, 'delete', null, inv(), convMocks(DIS)],
  // ── second round: calls, edits, reactions, votes, pins ──
  ['OK      a member starts a call in good standing', 'ALLOW', 'ALLOW', MEMBER, callPath, 'create', call(MEMBER), null, convMocks(OK)],
  ['FIX     a member starts a call while suspended', 'ALLOW', 'DENY', MEMBER, callPath, 'create', call(MEMBER), null, convMocks(SUS)],
  ['FIX     a member restarts an ended call in a disabled group', 'ALLOW', 'DENY', MEMBER, callPath, 'update', call(MEMBER), with_(call(OWNER), { active: false }), convMocks(DIS)],
  ['OK      a member ends a call while suspended', 'ALLOW', 'ALLOW', MEMBER, callPath, 'update', with_(call(OWNER), { active: false }), call(OWNER), convMocks(SUS)],
  ['OK      a member starts a call in a limited group', 'ALLOW', 'ALLOW', MEMBER, callPath, 'create', call(MEMBER), null, convMocks(LIM)],
  ['OK      a member reacts in good standing', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'update', with_(stored(ADMIN), { reactions: { [MEMBER]: 'enc1:R' } }), stored(ADMIN), convMocks(OK)],
  ['FIX     a member reacts while suspended', 'ALLOW', 'DENY', MEMBER, msgPath, 'update', with_(stored(ADMIN), { reactions: { [MEMBER]: 'enc1:R' } }), stored(ADMIN), convMocks(SUS)],
  ['FIX     the author edits a message in a disabled group', 'ALLOW', 'DENY', MEMBER, msgPath, 'update', edited(stored(MEMBER)), stored(MEMBER), convMocks(DIS)],
  ['OK      the author edits a message in good standing', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'update', edited(stored(MEMBER)), stored(MEMBER), convMocks(OK)],
  ['OK      the author deletes a message for everyone while suspended', 'ALLOW', 'ALLOW', MEMBER, msgPath, 'update', tomb(stored(MEMBER)), stored(MEMBER), convMocks(SUS)],
  ['FIX     a member votes while suspended', 'ALLOW', 'DENY', MEMBER, votePath, 'create', { options: [0], at: REQ_TIME }, null, [...convMocks(SUS), ...pollMocks]],
  ['OK      a member votes in good standing', 'ALLOW', 'ALLOW', MEMBER, votePath, 'create', { options: [0], at: REQ_TIME }, null, [...convMocks(OK), ...pollMocks]],
  ['FIX     the owner pins a message while suspended', 'ALLOW', 'DENY', OWNER, convPath, 'update', with_(SUS, { pinnedMessageIds: ['msgMod1'] }), SUS, convMocks(SUS)],
  ['OK      the owner unpins a message while suspended', 'ALLOW', 'ALLOW', OWNER, convPath, 'update', SUS, with_(SUS, { pinnedMessageIds: ['msgMod1'] }), convMocks(with_(SUS, { pinnedMessageIds: ['msgMod1'] }))],
  ['OK      the owner edits a link after the suspension ran out', 'ALLOW', 'ALLOW', OWNER, invPath, 'update', inv({ usageLimit: 10 }), inv(), convMocks(SUS_OVER)],
];

async function run(t, source, [, , , uid, p, method, after, before, mocks], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path: p, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  // Not staff, not blocked: production's answer for every other lookup here.
  const testCase = { expectation, request, functionMocks: [...(mocks || []), { function: 'exists', args: [{ anyValue: {} }], result: { value: false } }] };
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
