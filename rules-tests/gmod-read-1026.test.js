// 2026-10-26 suspended = unavailable (owner): members, owner and admins included, cannot read a
// suspended or disabled group's messages; an ended, limited, ok or expired-suspension group reads.
//
//   node gmod-read-1026.test.js <live.rules> ../firestore.rules
//
// Copied harness from gmod-1018. 2026-10-18 group moderation: the group's `mod` (limited / suspended / disabled) and `verified` are
// the admin panel's alone, and a restricted group refuses what its state forbids (groupModBlocked,
// groupModClosed, groupModWriteOK in firestore.rules). Each row runs against the rules BEFORE the
// change and AFTER it. README: plain JSON (an ISO string is a timestamp), mock every get().
//
//   node gmod-read-1026.test.js before-gmod.rules ../firestore.rules
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const BEFORE = process.argv[2], AFTER = process.argv[3] || '../firestore.rules';
if (!BEFORE) { console.error('usage: node gmod-read-1026.test.js <before.rules> [after.rules]'); process.exit(2); }

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

const END = group({ endedAt: REQ_TIME });
const read = (name, uid, data, b, a) => [name, b, a, uid, msgPath, 'get', null, stored(OWNER), convMocks(data)];
const storyPath = `${D}/stories/storyG1`;
const sdel = (name, uid, data, b, a) => [name, b, a, uid, storyPath, 'delete', null,
  { authorUid: MEMBER, groupId: CID, createdAt: REQ_TIME, expiresAt: LATER, recipientUids: [] }, convMocks(data)];
const cases = [
  read('member reads an ok group', MEMBER, OK, 'ALLOW', 'ALLOW'),
  read('member reads a limited group', MEMBER, LIM, 'ALLOW', 'ALLOW'),
  read('member cannot read a suspended group', MEMBER, SUS, 'ALLOW', 'DENY'),
  read('owner cannot read a suspended group', OWNER, SUS, 'ALLOW', 'DENY'),
  read('admin cannot read a suspended group with no end date', ADMIN, SUS_OPEN, 'ALLOW', 'DENY'),
  read('member cannot read a disabled group', MEMBER, DIS, 'ALLOW', 'DENY'),
  read('member reads once the suspension is over', MEMBER, SUS_OVER, 'ALLOW', 'ALLOW'),
  read('member reads a group its owner ended', MEMBER, END, 'ALLOW', 'ALLOW'),
  read('outsider still cannot read', NEWBIE, OK, 'DENY', 'DENY'),
  // owner 2026-10-26: a group's owner, or an admin with Delete messages, takes down a member's story.
  sdel('the author deletes their group story', MEMBER, OK, 'ALLOW', 'ALLOW'),
  sdel('the owner deletes a member’s group story', OWNER, OK, 'DENY', 'ALLOW'),
  sdel('an admin (default rights) deletes a member’s group story', ADMIN, OK, 'DENY', 'ALLOW'),
  sdel('an admin without Delete messages cannot', ADMIN, group({ adminRights: { [ADMIN]: ['pinMessages'] } }), 'DENY', 'DENY'),
  sdel('another member cannot', NEWBIE, group({ users: [...users, NEWBIE] }), 'DENY', 'DENY'),
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
