// Can a one-time story actually be burned, and only by the person burning it?
//
// The enforcement is NOT a read rule. A Firestore `list` query fails entirely if any document it
// returns is unreadable, and a consumed story still matches `recipientUids array-contains me` — so
// denying the read would not hide one story, it would break the whole story tray. Instead the
// recipient writes `stories/{id}/consumed/{me}` and the server takes that uid OUT of recipientUids,
// which changes what the query MATCHES. This file tests the half the rules own: who may write that
// document, and that the story's kind cannot be changed afterwards.
//
// Run BOTH ways. Before this change there was no `consumed` block at all, so every create must be
// DENIED on the old rules (no rule, no permission) and the legitimate one ALLOWED on the new ones:
//
//   git show HEAD:firestore.rules > old.rules
//   node one-time-story.test.js old.rules     # the legitimate burn is DENIED (no such rule yet)
//   node one-time-story.test.js               # and ALLOWED here
//
// resource.data is PLAIN JSON, not Firestore typed values — see README, trap 1. Every cross-document
// get()/exists() the rules can reach is mocked, or the expression errors and the whole case fails
// for a reason that has nothing to do with the rule — README, trap 2.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the author
const B = 'uidBBB';   // a recipient
const C = 'uidCCC';   // somebody who was never sent it
const SID = 'story123';

const oneTimeStory = {
  authorUid: A,
  createdAt: 1700000000000,
  expiresAt: 1700086400000,
  recipientUids: [B],
  mediaPath: `stories/${SID}/photo.jpg`,
  type: 'image',
  mediaUrl: 'https://firebasestorage.googleapis.com/v0/b/kulan/o/real.jpg',
  thumbUrl: '',
  caption: '',
  replyCount: 0,
  public: false,
  allowsReplies: true,
  oneTime: true,
  audienceLabel: 'oneTime',
};
// The same story posted normally. Burning one of these is meaningless and must be refused, or the
// `consumed` document becomes a way to remove yourself from any story you please.
const ordinaryStory = { ...oneTimeStory, oneTime: false, audienceLabel: 'friends' };

function mocks(story) {
  return [
    { function: 'exists', args: [{ exactValue: `${D}/admins/${B}` }], result: { value: false } },
    { function: 'exists', args: [{ exactValue: `${D}/admins/${C}` }], result: { value: false } },
    { function: 'exists', args: [{ exactValue: `${D}/admins/${A}` }], result: { value: false } },
    { function: 'get', args: [{ exactValue: `${D}/stories/${SID}` }], result: { value: { data: story } } },
  ];
}

// [name, expectation, actingUid, docUid, method, payload, parentStory]
const cases = [
  // The one that has to work, or one-time stories do not work at all.
  ['recipient burns their own copy', 'ALLOW', B, B, 'create', { at: 1700000900000 }, oneTimeStory],

  // Burning is per person and only your own.
  ['recipient burns it for SOMEBODY ELSE', 'DENY', B, C, 'create', { at: 1700000900000 }, oneTimeStory],
  ['a stranger burns a story they were never sent', 'DENY', C, C, 'create', { at: 1700000900000 }, oneTimeStory],

  // Not a general "take me off this story" tool.
  ['burn an ORDINARY story (not one-time)', 'DENY', B, B, 'create', { at: 1700000900000 }, ordinaryStory],

  // The document says one thing and carries nothing else.
  ['smuggle extra fields into the burn', 'DENY', B, B, 'create',
    { at: 1700000900000, recipientUids: [] }, oneTimeStory],

  // Unburning is the whole thing this prevents. There is no update rule and no delete rule.
  ['unburn by rewriting the record', 'DENY', B, B, 'update', { at: 1 }, oneTimeStory],
  ['unburn by deleting the record', 'DENY', B, B, 'delete', null, oneTimeStory],
];

// A story cannot change what KIND of story it is once people have it — otherwise an author posts a
// one-time story, lets it be consumed, and clears the flag. Author-acting, on the story itself.
const kindCases = [
  ['author clears oneTime after posting', 'DENY', { ...oneTimeStory, oneTime: false }],
  ['author rewrites the audience label', 'DENY', { ...oneTimeStory, audienceLabel: 'everyone' }],
  ['author counts a reply (must stay allowed)', 'ALLOW', { ...oneTimeStory, replyCount: 2 }],
];

async function run(t, source, body, label, expect) {
  const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  const res = j.testResults && j.testResults[0];
  const ok = res && res.state === 'SUCCESS';
  console.log(`${ok ? 'PASS' : 'FAIL'}  want ${expect.padEnd(5)}  ${label}`);
  return ok;
}

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  console.log(`rules: ${RULES}\n`);
  let pass = 0, fail = 0;
  const bad = [];

  for (const [name, expect, actor, docUid, method, payload, story] of cases) {
    const request = {
      auth: { uid: actor, token: { firebase: { sign_in_provider: 'password' } } },
      path: `${D}/stories/${SID}/consumed/${docUid}`,
      method,
      time: new Date().toISOString(),
    };
    if (payload) request.resource = { data: payload };
    const testCase = { expectation: expect, request, functionMocks: mocks(story) };
    // An update or a delete needs something to already be there, or the engine is judging a
    // different question from the one being asked.
    if (method !== 'create') testCase.resource = { data: { at: 1700000900000 } };
    const ok = await run(t, source, {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: { testCases: [testCase] },
    }, name, expect);
    ok ? pass++ : fail++;
    if (!ok) bad.push(name);
  }

  for (const [name, expect, after] of kindCases) {
    const ok = await run(t, source, {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: {
        testCases: [{
          expectation: expect,
          request: {
            auth: { uid: A, token: { firebase: { sign_in_provider: 'password' } } },
            path: `${D}/stories/${SID}`,
            method: 'update',
            time: new Date().toISOString(),
            resource: { data: after },
          },
          resource: { data: oneTimeStory },
          functionMocks: mocks(oneTimeStory),
        }],
      },
    }, name, expect);
    ok ? pass++ : fail++;
    if (!ok) bad.push(name);
  }

  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) console.log('failed: ' + bad.join(' | '));
  process.exit(fail ? 1 : 0);
})();
