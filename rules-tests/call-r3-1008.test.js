// 1:1 audit r3 (2026-10-08): F1 (a conversation's id is its membership: nobody can create my pair
// id as a group, or with a second account of theirs as the other member, and pass every call gate
// as my friend), F2 (callScreens is the callee's alone), F3 (only the callee writes the answer
// fields), J1 (an answered call cannot be ended as a ring by the callee's side), J2 (a block is
// refused at call create again until the owner flips `config/calls.silentBlocks`), F7 (only the two
// candidate lists, own side, own fields, not after the end).
//
//   git show HEAD:firestore.rules > before.rules
//   node call-r3-1008.test.js before.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
// README: plain JSON, mock every get()/exists() the rules can reach.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node call-r3-1008.test.js <before.rules> [after.rules]'); process.exit(2); }

const D = '/databases/(default)/documents';
const A = 'uidAAA', A2 = 'uidAA2', B = 'uidBBB';   // A = the stranger, A2 = A's second account, B = victim
const PAIR = [A, B].sort().join('_');
const GROUP_ID = 'Gq7ZkR2mN4pX8sV1tY3w';          // what `document()` mints: letters and digits
const REQ_TIME = new Date().toISOString();
const EARLIER = new Date(Date.now() - 3600e3).toISOString();

const ex = (p, v) => ({ function: 'exists', args: [{ exactValue: `${D}/${p}` }], result: { value: v } });
const gt = (p, data) => ({ function: 'get', args: [{ exactValue: `${D}/${p}` }], result: { value: { data } } });
const user = (uid, privacy = {}) => [ex(`users/${uid}`, true), gt(`users/${uid}`, { name: uid, privacy })];
const everyone = [A, A2, B].flatMap((u) => [ex(`admins/${u}`, false)]);
const friends = { users: [A, B], blockedBy: {}, startedBy: B, accepted: true, lastSender: B };

// ── conversation create: everybody accepts strangers, nobody declined anybody ──
const convMocks = [
  ...user(A), ...user(A2), ...user(B), ...everyone,
  ex(`requestDeclines/${B}/from/${A}`, false), ex(`requestDeclines/${A2}/from/${A}`, false),
  ex(`requestDeclines/${A}/from/${A}`, false),
  ex(`conversations/${PAIR}`, false), ex(`config/limits`, false), ex(`users/${A}/limits/requests`, false),
];

// ── call create: A rings B. `pair` = the doc at the pair id, `listed` = on B's account block list ──
const callMocks = ({ calls = 'contacts', pair = friends, listed = false, silent = null }) => [
  ex(`users/${B}/blocked/${A}`, listed),
  ex(`conversations/${PAIR}`, !!pair), ...(pair ? [gt(`conversations/${PAIR}`, pair)] : []),
  ...user(B, { calls }), ...everyone,
  ex('config/calls', silent !== null), ...(silent !== null ? [gt('config/calls', { silentBlocks: silent })] : []),
];

function cases() {
  const conv = (id) => `${D}/conversations/${id}`;
  const call = `${D}/calls/c1`;
  const dial = (over = {}) => ({ caller: A, callee: B, callerName: 'A', callerPhoto: '', type: 'voice',
    status: 'ringing', offerEnc: 'enc1:x', sig: 2, cams: { [A]: false }, createdAt: REQ_TIME, ...over });
  const ringing = { caller: A, callee: B, callerName: 'A', callerPhoto: '', status: 'ringing',
    createdAt: EARLIER, screenedAt: EARLIER };
  const answered = { ...ringing, acceptedAt: EARLIER, answeredDevice: 'dev-1' };
  const cm = callMocks({});
  const callDoc = (d) => [gt('calls/c1', d), ex('calls/c1', true), ...everyone];
  const cand = (side) => `${D}/calls/c1/${side}/x1`;
  const oneOne = { users: [A, B], startedBy: A, accepted: false, lastSender: '', type: '', unreadCount: { [A]: 0, [B]: 0 } };

  return [
    // ── F1: creating a conversation ──
    ['OK      a new 1:1 request at our pair id', 'ALLOW', 'ALLOW', A, conv(PAIR), 'create', oneOne, null, convMocks],
    ['OK      the same, members written in the other order', 'ALLOW', 'ALLOW', A, conv(PAIR), 'create',
      { ...oneOne, users: [B, A] }, null, convMocks],
    ['OK      a new group at an auto id', 'ALLOW', 'ALLOW', A, conv(GROUP_ID), 'create',
      { type: 'group', users: [A, B], admins: [A], createdBy: A, title: 'g' }, null, convMocks],
    ['F1      group at my pair id, members A + A2, lastMessage set', 'ALLOW', 'DENY', A, conv(PAIR), 'create',
      { type: 'group', users: [A, A2], admins: [A], lastMessage: 'x' }, null, convMocks],
    ['F1      group at my pair id, members A + B', 'ALLOW', 'DENY', A, conv(PAIR), 'create',
      { type: 'group', users: [A, B], admins: [A], lastMessage: 'x' }, null, convMocks],
    ['F1      group-typed 1:1 request at my pair id (no admins)', 'ALLOW', 'DENY', A, conv(PAIR), 'create',
      { ...oneOne, type: 'group' }, null, convMocks],
    ['F1      1:1 at my pair id with A2 as the other member', 'ALLOW', 'DENY', A, conv(PAIR), 'create',
      { ...oneOne, users: [A, A2] }, null, convMocks],
    ['F1      1:1 A+B at an id that is not theirs', 'ALLOW', 'DENY', A, conv('uidAA2_uidBBB'), 'create',
      oneOne, null, convMocks],
    ['F1      group at somebody else\'s pair-shaped id', 'ALLOW', 'DENY', A, conv('uidAA2_uidBBB'), 'create',
      { type: 'group', users: [A, A2], admins: [A] }, null, convMocks],
    ['HOLD    merge-shaped create (users + updatedAt, no startedBy)', 'DENY', 'DENY', A, conv(PAIR), 'create',
      { users: [A, B], updatedAt: REQ_TIME }, null, convMocks],
    ['HOLD    a member turns a 1:1 into a group', 'DENY', 'DENY', A, conv(PAIR), 'update',
      { ...friends, type: 'group', admins: [A] }, friends, convMocks],
    ['F1      a group owner turns their group into a 1:1', 'ALLOW', 'DENY', A, conv(GROUP_ID), 'update',
      { type: '', users: [A, B], admins: [A], createdBy: A }, { type: 'group', users: [A, B], admins: [A], createdBy: A },
      convMocks],
    ['OK      a group owner renames their group', 'ALLOW', 'ALLOW', A, conv(GROUP_ID), 'update',
      { type: 'group', users: [A, B], admins: [A], createdBy: A, title: 'new' },
      { type: 'group', users: [A, B], admins: [A], createdBy: A, title: 'old' }, convMocks],

    // ── F1: the call gate reading a forged pair doc (one left from before the fix) ──
    ['OK      a friend rings (My Chats)', 'ALLOW', 'ALLOW', A, call, 'create', dial(), null, cm],
    ['F1      forged group pair doc passes My Chats', 'ALLOW', 'DENY', A, call, 'create', dial(), null,
      callMocks({ pair: { type: 'group', users: [A, A2], admins: [A], lastMessage: 'x' } })],
    ['F1      forged A+A2 accepted pair doc passes My Chats', 'ALLOW', 'DENY', A, call, 'create', dial(), null,
      callMocks({ pair: { users: [A, A2], startedBy: A, accepted: true } })],
    ['OK      an old chat from before requests (no startedBy, a message)', 'ALLOW', 'ALLOW', A, call, 'create',
      dial(), null, callMocks({ pair: { users: [B, A], lastMessage: 'x' } })],
    ['OK      a stranger rings somebody on Everyone', 'ALLOW', 'ALLOW', A, call, 'create', dial(), null,
      callMocks({ calls: 'everyone', pair: null })],

    // ── J2: the block refusal while 840-843 are in use ──
    ['J2      a blocked person rings (account list), no switch', 'ALLOW', 'DENY', A, call, 'create', dial(), null,
      callMocks({ calls: 'everyone', pair: null, listed: true })],
    ['J2      a blocked friend rings (old chat block), no switch', 'ALLOW', 'DENY', A, call, 'create', dial(), null,
      callMocks({ pair: { ...friends, blockedBy: { [B]: true } } })],
    ['J2      switch off: still refused', 'ALLOW', 'DENY', A, call, 'create', dial(), null,
      callMocks({ calls: 'everyone', pair: null, listed: true, silent: false })],
    ['OK      switch on: blocked create goes through (silent block)', 'ALLOW', 'ALLOW', A, call, 'create', dial(), null,
      callMocks({ calls: 'everyone', pair: null, listed: true, silent: true })],

    // ── F3: the answer fields are the callee's ──
    ['F3      caller creates the call already answered', 'ALLOW', 'DENY', A, call, 'create',
      dial({ acceptedAt: REQ_TIME, answeredTokenHash: 'ab' }), null, cm],
    ['F3      caller writes acceptedAt + a made-up hash', 'ALLOW', 'DENY', A, call, 'update',
      { ...ringing, acceptedAt: REQ_TIME, answeredTokenHash: 'ab' }, ringing, cm],
    ['F3      caller writes answeredDevice', 'ALLOW', 'DENY', A, call, 'update',
      { ...ringing, answeredDevice: 'x' }, ringing, cm],
    ['F3      caller removes the callee\'s answeredDevice', 'ALLOW', 'DENY', A, call, 'update',
      { ...ringing, acceptedAt: EARLIER }, answered, cm],
    ['OK      callee accepts with the hash', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...ringing, acceptedAt: REQ_TIME, answeredTokenHash: 'ab' }, ringing, cm],
    ['OK      callee accepts, old build (no hash)', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...ringing, acceptedAt: REQ_TIME }, ringing, cm],
    ['OK      callee claims the answer', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...ringing, acceptedAt: EARLIER, answeredDevice: 'dev-1', answerEnc: 'enc1:y' },
      { ...ringing, acceptedAt: EARLIER }, cm],

    // ── J1: an answered call is not ended as a ring by the callee's side ──
    ['J1      older callee phone declines an answered call', 'ALLOW', 'DENY', B, call, 'update',
      { ...answered, status: 'ended', endReason: 'declined' }, answered, cm],
    ['J1      older callee phone rings out on an answered call', 'ALLOW', 'DENY', B, call, 'update',
      { ...answered, status: 'ended', endReason: 'missed' }, answered, cm],
    ['J1      callee phone says busy on an answered call', 'ALLOW', 'DENY', B, call, 'update',
      { ...answered, status: 'ended', endReason: 'busy' }, answered, cm],
    ['OK      callee (840-843 too) hangs up the call they answered', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...answered, status: 'ended', endReason: 'hangup' }, answered, cm],
    ['OK      callee call fails after the answer', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...answered, status: 'ended', endReason: 'failed' }, answered, cm],
    ['OK      caller hangs up an answered call', 'ALLOW', 'ALLOW', A, call, 'update',
      { ...answered, status: 'ended', endReason: 'hangup' }, answered, cm],
    ['OK      caller cancels an unanswered ring (missed + cancelledAt)', 'ALLOW', 'ALLOW', A, call, 'update',
      { ...ringing, status: 'ended', endReason: 'missed', cancelledAt: REQ_TIME }, ringing, cm],
    ['OK      callee declines an unanswered ring', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...ringing, status: 'ended', endReason: 'declined' }, ringing, cm],
    ['OK      callee refuses an unsealed offer (failed, unanswered)', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...ringing, status: 'ended', endReason: 'failed' }, ringing, cm],
    ['OK      callee M-006 marks an older unanswered ring missed', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...ringing, status: 'ended', endReason: 'missed' }, ringing, cm],
    ['OK      callee accept lands on a call the caller already cancelled', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...ringing, status: 'ended', endReason: 'missed', cancelledAt: EARLIER, acceptedAt: REQ_TIME, answeredTokenHash: 'ab' },
      { ...ringing, status: 'ended', endReason: 'missed', cancelledAt: EARLIER }, cm],
    ['OK      callee heartbeat on an answered call', 'ALLOW', 'ALLOW', B, call, 'update',
      { ...answered, hb: { [B]: REQ_TIME } }, answered, cm],

    // ── F7: candidates ──
    ['OK      caller adds a candidate', 'ALLOW', 'ALLOW', A, cand('callerCandidates'), 'create',
      { candidate: 'candidate:1 1 udp 1 1.2.3.4 5 typ host', sdpMLineIndex: 0, sdpMid: '0' }, null, callDoc(ringing)],
    ['OK      callee adds a sealed candidate', 'ALLOW', 'ALLOW', B, cand('calleeCandidates'), 'create',
      { enc: 'enc1:abc' }, null, callDoc(answered)],
    ['OK      a candidate with no sdpMid', 'ALLOW', 'ALLOW', A, cand('callerCandidates'), 'create',
      { candidate: 'candidate:1', sdpMLineIndex: 0, sdpMid: null }, null, callDoc(ringing)],
    ['OK      callee reads the caller\'s candidates', 'ALLOW', 'ALLOW', B, cand('callerCandidates'), 'get',
      null, { candidate: 'c' }, callDoc(ringing)],
    ['F7      caller writes into the callee\'s list', 'ALLOW', 'DENY', A, cand('calleeCandidates'), 'create',
      { candidate: 'c', sdpMLineIndex: 0, sdpMid: '0' }, null, callDoc(ringing)],
    ['F7      a subcollection of any other name', 'ALLOW', 'DENY', A, cand('junk'), 'create',
      { blob: 'x' }, null, callDoc(ringing)],
    ['F7      a candidate with extra fields', 'ALLOW', 'DENY', A, cand('callerCandidates'), 'create',
      { candidate: 'c', sdpMLineIndex: 0, sdpMid: '0', blob: 'x' }, null, callDoc(ringing)],
    ['F7      a candidate after the call ended', 'ALLOW', 'DENY', A, cand('callerCandidates'), 'create',
      { candidate: 'c', sdpMLineIndex: 0, sdpMid: '0' }, null, callDoc({ ...answered, status: 'ended', endReason: 'hangup' })],
    ['F7      a huge candidate', 'ALLOW', 'DENY', A, cand('callerCandidates'), 'create',
      { candidate: 'c'.repeat(5000), sdpMLineIndex: 0, sdpMid: '0' }, null, callDoc(ringing)],
    ['F7      overwrite the other side\'s candidate', 'ALLOW', 'DENY', A, cand('calleeCandidates'), 'update',
      { candidate: 'c2' }, { candidate: 'c' }, callDoc(ringing)],

    // ── F2: the server's verdict is the callee's to read, nobody's to write ──
    ['F2      callee reads their verdict', 'DENY', 'ALLOW', B, `${D}/users/${B}/callScreens/c1`, 'get',
      null, { allowed: false }, everyone],
    ['F2      caller reads the callee\'s verdict', 'DENY', 'DENY', A, `${D}/users/${B}/callScreens/c1`, 'get',
      null, { allowed: false }, everyone],
    ['F2      callee writes their own verdict', 'DENY', 'DENY', B, `${D}/users/${B}/callScreens/c1`, 'create',
      { allowed: true }, null, everyone],
  ];
}

async function run(t, source, [, , , uid, path, method, after, before, fm], expectation) {
  const request = {
    auth: { uid, token: { firebase: { sign_in_provider: 'password' } } },
    path, method, time: REQ_TIME,
  };
  if (after) request.resource = { data: after };
  const testCase = { expectation, request, functionMocks: fm };
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
  let pass = 0, fail = 0;
  for (const c of cases()) {
    const [o, n] = await Promise.all([run(t, before, c, c[1]), run(t, after, c, c[2])]);
    const ok = o.state === 'SUCCESS' && n.state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  ${c[1].padEnd(5)}→${c[2].padEnd(5)}  ${c[0]}`);
    if (o.state !== 'SUCCESS') console.log(`        BEFORE: ${o.state} ${o.detail}`);
    if (n.state !== 'SUCCESS') console.log(`        AFTER: ${n.state} ${n.detail}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exitCode = fail ? 1 : 0;
})();
