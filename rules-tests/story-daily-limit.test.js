// THE DAILY STORY CEILING, AND THE BIGGER ONE A BADGE BUYS.
//
// Owner, 2026-08-21: verified accounts get 100 stories a day, everybody else stays on 50, and both
// numbers have to be changeable from the server without shipping an app. The rule reads them out of
// `config/limits` with the old constants as its fallback.
//
// RUN THE CONTROL, or this proves nothing (README). The parent commit has one flat ceiling of 50:
//
//   git show HEAD:firestore.rules > old.rules
//   node story-daily-limit.test.js old.rules   # "VERIFIED, 50 spent" is DENIED there
//   node story-daily-limit.test.js             # and ALLOWED here
//
// The case to watch is "ordinary account, 49 spent" — it must be ALLOWED on BOTH files. It is the
// canary for trap 1: if the payload below stops being a legally postable story for some unrelated
// reason, every DENY in here passes for the wrong reason and only that one case notices.
//
// `windowStart` is deliberately ABSENT from the mocked counters. The rule reads it as
// `.get('windowStart', request.time)`, so leaving it out hands the comparison request.time itself —
// a live window, which is the state where the count actually matters. Putting a number there would
// compare an int with a timestamp, and that errors rather than evaluating false.
const fs = require('fs');
const { token } = require('./auth');

const RULES = process.argv[2] || '../firestore.rules';
const D = '/databases/(default)/documents';
const A = 'uidAAA';
const SID = 'story123';

const NOW = new Date();
const EXPIRES = new Date(NOW.getTime() + 24 * 3600 * 1000).toISOString();

const story = {
  authorUid: A,
  createdAt: NOW.getTime(),
  expiresAt: EXPIRES,
  recipientUids: ['uidBBB', 'uidCCC'],
  mediaPath: 'stories/' + SID + '/photo.jpg',
  type: 'image',
  mediaUrl: '',
  thumbUrl: '',
  caption: '',
  replyCount: 0,
  public: false,
  allowsReplies: true,
  oneTime: false,
  audienceLabel: 'friends',
};

// hourly count, daily count, verified?, and what config/limits holds (null = no document at all)
function mocks(o) {
  const hour = o.hour || 0;
  const day = o.day || 0;
  const verified = o.verified === undefined ? false : o.verified;
  const config = o.config === undefined ? {} : o.config;

  const user = { banned: false };
  // null = an account with no verification map at all, which is nearly everybody.
  if (verified !== null) user.verification = { isVerified: verified };

  const m = [
    { function: 'exists', args: [{ exactValue: D + '/admins/' + A }], result: { value: false } },
    { function: 'exists', args: [{ exactValue: D + '/users/' + A }], result: { value: true } },
    { function: 'get', args: [{ exactValue: D + '/users/' + A }], result: { value: { data: user } } },
    { function: 'exists', args: [{ exactValue: D + '/users/' + A + '/limits/stories' }], result: { value: true } },
    { function: 'get', args: [{ exactValue: D + '/users/' + A + '/limits/stories' }], result: { value: { data: { count: hour } } } },
    { function: 'exists', args: [{ exactValue: D + '/users/' + A + '/limits/storiesDaily' }], result: { value: true } },
    { function: 'get', args: [{ exactValue: D + '/users/' + A + '/limits/storiesDaily' }], result: { value: { data: { count: day } } } },
    { function: 'exists', args: [{ exactValue: D + '/config/limits' }], result: { value: config !== null } },
  ];
  if (config !== null) {
    m.push({ function: 'get', args: [{ exactValue: D + '/config/limits' }], result: { value: { data: config } } });
  }
  return m;
}

const cases = [
  // THE CANARY. Allowed on the old rules and on these; if this one fails, read the payload, not the rule.
  ['ordinary account, 49 spent', 'ALLOW', { day: 49 }],

  // The ordinary ceiling is unchanged. 50 is spent, not remaining.
  ['ordinary account, 50 spent', 'DENY', { day: 50 }],
  ['ordinary account, 99 spent', 'DENY', { day: 99 }],

  // THE FLIP. Denied on the old rules, allowed here.
  ['VERIFIED, 50 spent', 'ALLOW', { day: 50, verified: true }],
  ['VERIFIED, 99 spent', 'ALLOW', { day: 99, verified: true }],

  // A badge raises the ceiling, it does not remove it.
  ['VERIFIED, 100 spent', 'DENY', { day: 100, verified: true }],
  ['VERIFIED, 400 spent', 'DENY', { day: 400, verified: true }],

  // A suspended or revoked badge is not a badge. VerificationAdmin writes isVerified:false for both.
  ['badge SUSPENDED, 50 spent', 'DENY', { day: 50, verified: false }],
  ['no verification map at all, 50 spent', 'DENY', { day: 50, verified: null }],

  // The hour still bounds the day. 40 in an hour refuses a verified account on its 51st of the day.
  ['VERIFIED, 50 spent today but 40 this hour', 'DENY', { day: 50, hour: 40, verified: true }],

  // THE POINT OF THE WHOLE THING: the owner widens it from the console, nobody installs anything.
  ['config raises the ordinary day to 200, 150 spent', 'ALLOW',
    { day: 150, config: { stories_per_day_default: 200 } }],
  ['config raises the verified day to 500, 400 spent', 'ALLOW',
    { day: 400, verified: true, config: { stories_per_day_default: 50, stories_per_day_verified: 500 } }],
  // And narrows it, which is the same mechanism pointing the other way.
  ['config drops the ordinary day to 10, 10 spent', 'DENY',
    { day: 10, config: { stories_per_day_default: 10 } }],

  // A field typed in the console is a STRING unless somebody says otherwise. It must fall back to
  // the built-in number, not error — an errored expression denies, and a limit that cannot be raised
  // looks exactly like a limit that was never edited.
  ['limit typed as text, 49 spent', 'ALLOW',
    { day: 49, config: { stories_per_day_default: '200' } }],
  ['limit typed as text, 50 spent (falls back to 50)', 'DENY',
    { day: 50, config: { stories_per_day_default: '200' } }],

  // No config document at all is the state this ships in. The fallbacks ARE the limits.
  ['no config document, 49 spent', 'ALLOW', { day: 49, config: null }],
  ['no config document, 50 spent', 'DENY', { day: 50, config: null }],
  ['no config document, VERIFIED, 99 spent', 'ALLOW', { day: 99, verified: true, config: null }],
];

(async () => {
  const t = await token();
  const source = fs.readFileSync(RULES, 'utf8');
  console.log('rules: ' + RULES + '\n');
  let pass = 0, fail = 0;
  const bad = [];

  for (const c of cases) {
    const name = c[0], expect = c[1], setup = c[2];
    const r = await fetch('https://firebaserules.googleapis.com/v1/projects/kulan-2ef85:test', {
      method: 'POST',
      headers: { Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        source: { files: [{ name: 'firestore.rules', content: source }] },
        testSuite: {
          testCases: [{
            expectation: expect,
            request: {
              auth: { uid: A, token: { firebase: { sign_in_provider: 'password' } } },
              path: D + '/stories/' + SID,
              method: 'create',
              time: NOW.toISOString(),
              resource: { data: story },
            },
            functionMocks: mocks(setup),
          }],
        },
      }),
    });
    const j = await r.json();
    const res = j.testResults && j.testResults[0];
    const ok = res && res.state === 'SUCCESS';
    console.log((ok ? 'PASS' : 'FAIL') + '  want ' + expect.padEnd(5) + '  ' + name);
    if (!ok && res && res.errorPosition) {
      console.log('      rule error at line ' + res.errorPosition.line);
    }
    if (!ok && !res) console.log('      ' + JSON.stringify(j).slice(0, 300));
    ok ? pass++ : fail++;
    if (!ok) bad.push(name);
  }

  console.log('\n' + pass + ' passed, ' + fail + ' failed');
  if (fail) console.log('failed: ' + bad.join(' | '));
  process.exit(fail ? 1 : 0);
})();
