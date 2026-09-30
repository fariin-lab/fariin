// 2026-09-30 Insights history: the owner reads their own, nobody else reads it, no client writes it.
//
//   node insights.test.js                # against ../firestore.rules
//   node insights.test.js live.rules     # or any other rules file
//
// Nothing is deployed and nothing is written; this only asks Google's rules engine what it would do.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const OWNER = 'uidOwner', OTHER = 'uidOther';
const DAY = `${D}/users/${OWNER}/insightsDaily/2026-09-30`;
const STORY = `${D}/users/${OWNER}/insightsStories/story1`;
const STATE = `${D}/users/${OWNER}/insights/state`;
const dayDoc = { day: '2026-09-30', storyViews: 12, glowersGained: 3 };
const storyDoc = { storyId: 'story1', views: 12, reactions: 2 };

// [name, expectation, uid (null = signed out), method, path, existing document, written document]
const cases = [
  ['owner reads their own day', 'ALLOW', OWNER, 'get', DAY, dayDoc],
  ['owner lists their own days', 'ALLOW', OWNER, 'list', DAY, dayDoc],
  ['owner reads their own story record', 'ALLOW', OWNER, 'get', STORY, storyDoc],
  ['owner lists their own story records', 'ALLOW', OWNER, 'list', STORY, storyDoc],
  ['another account reads the day', 'DENY', OTHER, 'get', DAY, dayDoc],
  ['another account lists the days', 'DENY', OTHER, 'list', DAY, dayDoc],
  ['another account reads the story record', 'DENY', OTHER, 'get', STORY, storyDoc],
  ['signed out reads the day', 'DENY', null, 'get', DAY, dayDoc],
  ['owner creates a day', 'DENY', OWNER, 'create', DAY, null, { ...dayDoc, storyViews: 999999 }],
  ['owner raises their own views', 'DENY', OWNER, 'update', DAY, dayDoc, { ...dayDoc, storyViews: 999999 }],
  ['owner deletes a day', 'DENY', OWNER, 'delete', DAY, dayDoc],
  ['owner creates a story record', 'DENY', OWNER, 'create', STORY, null, storyDoc],
  ['owner raises a story record', 'DENY', OWNER, 'update', STORY, storyDoc, { ...storyDoc, views: 999999 }],
  ['owner deletes a story record', 'DENY', OWNER, 'delete', STORY, storyDoc],
  ['another account writes the day', 'DENY', OTHER, 'update', DAY, dayDoc, { ...dayDoc, storyViews: 0 }],
  ['owner reads the server bookkeeping', 'DENY', OWNER, 'get', STATE, { appliedGlowEvents: [] }],
  ['owner writes the server bookkeeping', 'DENY', OWNER, 'update', STATE, { appliedGlowEvents: [] }, { appliedGlowEvents: [] }],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  let pass = 0, fail = 0;
  for (const [name, expectation, uid, method, path, existing, written] of cases) {
    const request = { path, method, time: new Date().toISOString() };
    if (uid) request.auth = { uid, token: { firebase: { sign_in_provider: 'password' } } };
    if (written) request.resource = { data: written };
    const testCase = { expectation, request };
    if (existing) testCase.resource = { data: existing };
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ source: { files: [{ name: 'firestore.rules', content: source }] }, testSuite: { testCases: [testCase] } }),
    });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const state = j.error ? 'APIERROR' : (j.issues && j.issues.length && !res) ? 'COMPILE' : (res && res.state) || 'NORESULT';
    const ok = state === 'SUCCESS';
    ok ? pass++ : fail++;
    console.log(`${ok ? 'PASS' : 'FAIL'}  want ${expectation.padEnd(5)}  ${name}`);
    if (!ok) console.log(`        ${state} ${JSON.stringify(j.error || j.issues || (res && res.debugMessages) || '').slice(0, 300)}`);
  }
  console.log(`\n${pass} passed, ${fail} failed`);
  process.exit(fail ? 1 : 0);
})();
