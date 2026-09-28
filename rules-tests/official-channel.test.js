// The official channel's per-person state machine (2026-09-28): the two watermarks only move
// forward, a switch changes only with a choice time at least as new as the stored one, builds that
// write no choice time still pass, and nobody writes anybody else's state.
//
//   node official-channel.test.js              # against ../firestore.rules
//   node official-channel.test.js old.rules    # or any other rules file
//
// `resource.data` is PLAIN JSON (see README, trap 1), and `request.resource.data` is the whole
// document after the merge, which is what the rules see.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';   // the owner of the state
const B = 'uidBBB';   // somebody else

const stored = {
  lastReadAt: 1000, clearedAt: 500, markedUnread: false,
  muted: true, mutedAt: 2000, blocked: false, blockedAt: 2000,
};
const m = (extra) => ({ ...stored, ...extra });

const cases = [
  // Watermarks.
  ['read moves forward', 'ALLOW', A, m({ lastReadAt: 1500 })],
  ['read moves BACK (a late write from another phone)', 'DENY', A, m({ lastReadAt: 900 })],
  ['mark as unread is its own flag', 'ALLOW', A, m({ markedUnread: true })],
  ['clear moves forward', 'ALLOW', A, m({ clearedAt: 800 })],
  ['clear moves BACK', 'DENY', A, m({ clearedAt: 400 })],
  // Switches.
  ['unmute chosen later than the stored mute', 'ALLOW', A, m({ muted: false, mutedAt: 3000 })],
  ['unmute chosen EARLIER than the stored mute (stale offline write)', 'DENY', A, m({ muted: false, mutedAt: 1500 })],
  ['an older build unmutes, writing no choice time', 'ALLOW', A, m({ muted: false })],
  ['a switch never set before, with its time', 'ALLOW', A, m({ pinned: true, pinnedAt: 100 })],
  ['a write that leaves the switches alone', 'ALLOW', A, m({ lastReadAt: 1200 })],
  ['block chosen earlier than the stored unblock', 'DENY', A, m({ blocked: true, blockedAt: 1000 })],
  // Ownership.
  ["somebody else writes this person's state", 'DENY', B, m({ lastReadAt: 5000 })],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;
  const bad = [];
  for (const [name, expect, who, data] of cases) {
    const body = {
      source: { files: [{ name: 'firestore.rules', content: source }] },
      testSuite: {
        testCases: [{
          expectation: expect,
          request: {
            auth: { uid: who, token: { firebase: { sign_in_provider: 'password' } } },
            path: `${D}/users/${A}/officialChannel/state`,
            method: 'update',
            time: new Date().toISOString(),
            resource: { data },
          },
          resource: { data: stored },
        }],
      },
    };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const ok = res && res.state === 'SUCCESS';
    ok ? pass++ : fail++;
    if (!ok) bad.push(name + (j.error ? ` [${j.error.message}]` : ''));
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${expect.padEnd(5)}  ${name}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  if (fail) console.log('failed: ' + bad.join(' | '));
})();
