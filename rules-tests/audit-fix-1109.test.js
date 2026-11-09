// Audit fix pass 2026-11-09: B5-01 (server-owned channel fields), B5-08 (channelPrefs update keeps
// replyNotifs), B5-09 (server-only fields at post create), B5-11 (visitors of a public channel read
// its change records).
//   node audit-fix-1109.test.js [rules file, LF]   (the source sent must be under 262,144 bytes)
const fs = require('fs'); const { token } = require('./auth');
const SRC = fs.readFileSync(process.argv[2] || '../firestore.rules', 'utf8');
const D = '/databases/(default)/documents';
const OWNER = 'uidOWNER', ADM = 'uidADMIN', F = 'uidFOLLOW', X = 'uidSTRANGER', CID = 'chanCID1';
const T = new Date().toISOString();
const chan = { type: 'group', channel: true, users: [OWNER, ADM], admins: [OWNER, ADM], adminRights: { [ADM]: [] }, createdBy: OWNER,
  onlyAdminsSend: true, hideMembers: true, e2ee: false, title: 'News', names: {}, photos: {}, chSeq: 40, postCount: 12 };
const pub = { ...chan, isPublic: true };
const pubBanned = { ...pub, bannedUids: [X] };
const msg = { authorId: OWNER, text: 'hi', createdAt: T };
const post = { authorId: OWNER, type: 'text', text: 'hi', createdAt: T };

function mocks(conv, followerExists) {
  return [
    ...[OWNER, ADM, F, X].flatMap(u => [
      { function: 'exists', args: [{ exactValue: `${D}/users/${u}` }], result: { value: true } },
      { function: 'get', args: [{ exactValue: `${D}/users/${u}` }], result: { value: { data: { name: u } } } },
      { function: 'exists', args: [{ exactValue: `${D}/admins/${u}` }], result: { value: false } },
      { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}/followers/${u}` }], result: { value: followerExists && u === F } },
    ]),
    { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: true } },
    { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}/messages/m1` }], result: { value: { data: msg } } },
    { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data: conv } } },
  ];
}

// [name, expectation, uid, method, path, resource, newData, conv, followerExists]
const C = `conversations/${CID}`;
const cases = [
  // B5-01
  ['owner renames the channel (control)', 'ALLOW', OWNER, 'update', C, chan, { ...chan, title: 'News 2' }, chan, false],
  ['admin renames nothing, writes archivedAt', 'DENY', ADM, 'update', C, chan, { ...chan, archivedAt: 1 }, chan, false],
  ['owner writes archivedAt', 'DENY', OWNER, 'update', C, chan, { ...chan, archivedAt: 1 }, chan, false],
  ['admin resets chSeq', 'DENY', ADM, 'update', C, chan, { ...chan, chSeq: 0 }, chan, false],
  ['admin sets chClearBefore', 'DENY', ADM, 'update', C, chan, { ...chan, chClearBefore: 9e12 }, chan, false],
  ['admin writes postPreview', 'DENY', ADM, 'update', C, chan, { ...chan, postPreview: { text: 'x', mid: 'm9' } }, chan, false],
  ['admin writes deletedPostSeqs', 'DENY', ADM, 'update', C, chan, { ...chan, deletedPostSeqs: [1, 2, 3] }, chan, false],
  ['admin writes uncountedDeletes', 'DENY', ADM, 'update', C, chan, { ...chan, uncountedDeletes: ['m1'] }, chan, false],
  ['admin turns quotes off directly', 'DENY', ADM, 'update', C, chan, { ...chan, quotesOff: true }, chan, false],
  // B5-09
  ['admin posts (control)', 'ALLOW', OWNER, 'create', `${C}/messages/m3`, null, post, chan, false],
  ['admin posts with a forged chg', 'DENY', OWNER, 'create', `${C}/messages/m3`, null, { ...post, chg: 9e15 }, chan, false],
  ['admin posts with a postSeq', 'DENY', OWNER, 'create', `${C}/messages/m3`, null, { ...post, postSeq: 5 }, chan, false],
  ['admin posts with reactionCounts', 'DENY', OWNER, 'create', `${C}/messages/m3`, null, { ...post, reactionCounts: { '❤️': 50000 } }, chan, false],
  ['admin posts with pollCounts', 'DENY', OWNER, 'create', `${C}/messages/m3`, null, { ...post, pollCounts: { 0: 9 } }, chan, false],
  ['admin posts with replyFaces', 'DENY', OWNER, 'create', `${C}/messages/m3`, null, { ...post, replyFaces: ['https://x'] }, chan, false],
  // B5-08
  ['bell: create silent (control)', 'ALLOW', OWNER, 'create', `users/${OWNER}/channelPrefs/${CID}`, null, { silent: true }, chan, false],
  ['bell: merge keeps replyNotifs', 'ALLOW', OWNER, 'update', `users/${OWNER}/channelPrefs/${CID}`, { silent: false, replyNotifs: 'off' }, { silent: true, replyNotifs: 'off' }, chan, false],
  ['bell: overwrite drops replyNotifs', 'DENY', OWNER, 'update', `users/${OWNER}/channelPrefs/${CID}`, { silent: false, replyNotifs: 'off' }, { silent: true }, chan, false],
  ['bell: app writes replyNotifs itself', 'DENY', OWNER, 'update', `users/${OWNER}/channelPrefs/${CID}`, { silent: false }, { silent: false, replyNotifs: 'on' }, chan, false],
  ['bell: silent as text', 'DENY', OWNER, 'update', `users/${OWNER}/channelPrefs/${CID}`, { silent: false }, { silent: 'y' }, chan, false],
  ['bell: someone else', 'DENY', X, 'update', `users/${OWNER}/channelPrefs/${CID}`, { silent: false }, { silent: true }, chan, false],
  // B5-11
  ['follower reads change records (control)', 'ALLOW', F, 'get', `${C}/changes/5`, { chg: 5, gone: true }, null, chan, true],
  ['visitor reads a PUBLIC channel change record', 'ALLOW', X, 'get', `${C}/changes/5`, { chg: 5, gone: true }, null, pub, false],
  ['visitor reads a PRIVATE channel change record', 'DENY', X, 'get', `${C}/changes/5`, { chg: 5, gone: true }, null, chan, false],
  ['banned visitor reads a public channel change record', 'DENY', X, 'get', `${C}/changes/5`, { chg: 5, gone: true }, null, pubBanned, false],
];

(async () => {
  const t = await token();
  let bad = 0;
  for (const [name, exp, uid, method, path, res, after, conv, fol] of cases) {
    const request = { auth: { uid, token: { firebase: { sign_in_provider: 'password' } } }, path: `${D}/${path}`, method, time: T };
    if (after) request.resource = { data: after };
    const testCase = { expectation: 'ALLOW', request, functionMocks: mocks(conv, fol) };
    if (res) testCase.resource = { data: res };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', { method: 'POST', headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: { files: [{ name: 'firestore.rules', content: SRC }] }, testSuite: { testCases: [testCase] } }) });
    const j = await r.json(); const tr = j.testResults && j.testResults[0];
    const got = (tr && tr.state === 'SUCCESS') ? 'ALLOW' : 'DENY';
    if (got !== exp) bad++;
    console.log(got === exp ? 'ok  ' : 'BAD ', got.padEnd(5), name, j.error ? JSON.stringify(j.error).slice(0, 300) : '',
      got !== exp && tr && tr.debugMessages ? tr.debugMessages.join(' | ').slice(0, 300) : '');
  }
  console.log(bad ? `${bad} WRONG` : 'all as expected');
})();
