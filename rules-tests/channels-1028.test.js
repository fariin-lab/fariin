// 2026-10-28 channels: followers (conversations/{cid}/followers/{uid}, server-written) read a
// channel and its posts; nobody else does unless it is public; `channel` is server-only.
const fs = require('fs'); const { token } = require('./auth');
const SRC = fs.readFileSync(process.argv[2] || '../firestore.rules', 'utf8');
const D = '/databases/(default)/documents';
const OWNER = 'uidOWNER', F = 'uidFOLLOW', X = 'uidSTRANGER', CID = 'chanCID1';
const T = new Date().toISOString();
const chan = { type: 'group', channel: true, users: [OWNER], admins: [OWNER], createdBy: OWNER, onlyAdminsSend: true, hideMembers: true, e2ee: false, title: 'News', names: {}, photos: {} };
const group = { ...chan, channel: false };
const suspended = { ...chan, mod: { state: 'suspended' } };
const msg = { authorId: OWNER, text: 'hi', createdAt: T };

function mocks(conv, followerExists) {
  return [
    ...[OWNER, F, X].flatMap(u => [
      { function: 'exists', args: [{ exactValue: `${D}/users/${u}` }], result: { value: true } },
      { function: 'get', args: [{ exactValue: `${D}/users/${u}` }], result: { value: { data: { name: u } } } },
      { function: 'exists', args: [{ exactValue: `${D}/admins/${u}` }], result: { value: false } },
      { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}/followers/${u}` }], result: { value: followerExists && u === F } },
    ]),
    { function: 'exists', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: true } },
    { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}/messages/m1` }], result: { value: { data: { ...msg, pollMulti: false } } } },
    { function: 'get', args: [{ exactValue: `${D}/conversations/${CID}` }], result: { value: { data: conv } } },
  ];
}

// [name, expectation, uid, method, path, resource, newData, conv, followerExists]
const cases = [
  ['follower reads the channel doc', 'ALLOW', F, 'get', `conversations/${CID}`, chan, null, chan, true],
  ['stranger reads the channel doc', 'DENY', X, 'get', `conversations/${CID}`, chan, null, chan, false],
  ['follower doc on a plain GROUP gives nothing', 'DENY', F, 'get', `conversations/${CID}`, group, null, group, true],
  ['follower reads a post', 'ALLOW', F, 'get', `conversations/${CID}/messages/m1`, msg, null, chan, true],
  ['stranger reads a post of a private channel', 'DENY', X, 'get', `conversations/${CID}/messages/m1`, msg, null, chan, false],
  ['follower reads a post of a SUSPENDED channel', 'DENY', F, 'get', `conversations/${CID}/messages/m1`, msg, null, suspended, true],
  ['owner (member) still reads posts', 'ALLOW', OWNER, 'get', `conversations/${CID}/messages/m1`, msg, null, chan, false],
  ['follower posts in the channel', 'DENY', F, 'create', `conversations/${CID}/messages/m2`, null, { ...msg, authorId: F }, chan, true],
  ['I read my own followed list', 'ALLOW', F, 'get', `users/${F}/channels/${CID}`, { at: T }, null, chan, true],
  ['I read someone else\'s followed list', 'DENY', X, 'get', `users/${F}/channels/${CID}`, { at: T }, null, chan, true],
  ['I write my own followed list', 'DENY', F, 'create', `users/${F}/channels/${CID}`, null, { at: T }, chan, true],
  ['I mark read + muted on my entry', 'ALLOW', F, 'update', `users/${F}/channels/${CID}`, { at: T }, { at: T, read: 12, muted: true }, chan, true],
  ['I change the follow time', 'DENY', F, 'update', `users/${F}/channels/${CID}`, { at: T }, { at: '2020-01-01T00:00:00Z' }, chan, true],
  ['read as text', 'DENY', F, 'update', `users/${F}/channels/${CID}`, { at: T }, { at: T, read: 'x' }, chan, true],
  ['someone marks my entry', 'DENY', X, 'update', `users/${F}/channels/${CID}`, { at: T }, { at: T, read: 1 }, chan, true],
  ['follower reacts (own key)', 'ALLOW', F, 'update', `conversations/${CID}/messages/m1`, msg, { ...msg, reactions: { [F]: '👍' } }, chan, true],
  ['follower writes SOMEONE ELSES reaction', 'DENY', F, 'update', `conversations/${CID}/messages/m1`, msg, { ...msg, reactions: { [OWNER]: '👍' } }, chan, true],
  ['stranger reacts', 'DENY', X, 'update', `conversations/${CID}/messages/m1`, msg, { ...msg, reactions: { [X]: '👍' } }, chan, false],
  ['follower edits the post text', 'DENY', F, 'update', `conversations/${CID}/messages/m1`, msg, { ...msg, text: 'hacked', edited: true }, chan, true],
  ['follower reacts in a SUSPENDED channel', 'DENY', F, 'update', `conversations/${CID}/messages/m1`, msg, { ...msg, reactions: { [F]: '👍' } }, suspended, true],
  ['follower votes', 'ALLOW', F, 'create', `conversations/${CID}/messages/m1/votes/${F}`, null, { options: [0], at: T }, chan, true],
  ['stranger votes', 'DENY', X, 'create', `conversations/${CID}/messages/m1/votes/${X}`, null, { options: [0], at: T }, chan, false],
  ['admin posts (control)', 'ALLOW', OWNER, 'create', `conversations/${CID}/messages/m3`, null, { authorId: OWNER, type: 'text', text: 'hi', createdAt: T }, chan, false],
  ['admin posts with fake views', 'DENY', OWNER, 'create', `conversations/${CID}/messages/m3`, null, { authorId: OWNER, type: 'text', text: 'hi', createdAt: T, views: 99999 }, chan, false],
  ['admin bumps views on a post', 'DENY', OWNER, 'update', `conversations/${CID}/messages/m1`, msg, { ...msg, views: 99999 }, chan, false],
  ['admin renames the channel (control)', 'ALLOW', OWNER, 'update', `conversations/${CID}`, chan, { ...chan, title: 'News 2' }, chan, false],
  ['admin turns a group INTO a channel', 'DENY', OWNER, 'update', `conversations/${CID}`, group, { ...group, channel: true }, group, false],
  ['admin edits followerCount', 'DENY', OWNER, 'update', `conversations/${CID}`, chan, { ...chan, followerCount: 999 }, chan, false],
  ['admin moves the channel to another country', 'DENY', OWNER, 'update', `conversations/${CID}`, chan, { ...chan, country: 'US' }, chan, false],
  ['admin edits postCount', 'DENY', OWNER, 'update', `conversations/${CID}`, chan, { ...chan, postCount: 5 }, chan, false],
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
