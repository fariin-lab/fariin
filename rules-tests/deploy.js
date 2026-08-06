// Deploy firestore.rules to the live project.
//
// The Firebase CLI cannot do it here: firebase.json declares hosting only, so
// `firebase deploy --only firestore:rules` has no target to match. This is the same Rules REST API
// the test suites already use, in two steps, which is also what makes it auditable — the ruleset is
// created first and named, and only then does the release point at it.
//
//   node deploy.js            # dry run: compile the ruleset, print its id, change nothing
//   node deploy.js --release  # …and point cloud.firestore at it
const fs = require('fs');
const { token } = require('./auth');

const PROJECT = 'kulan-2ef85';
const RELEASE = 'cloud.firestore';
const RULES = '../firestore.rules';

(async () => {
  const t = await token();
  const auth = { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' };

  const before = await (await fetch(
    `https://firebaserules.googleapis.com/v1/projects/${PROJECT}/releases/${RELEASE}`, { headers: auth })).json();
  console.log('live now:  ' + (before.rulesetName || JSON.stringify(before)));

  const content = fs.readFileSync(RULES, 'utf8');
  const mk = await fetch(`https://firebaserules.googleapis.com/v1/projects/${PROJECT}/rulesets`, {
    method: 'POST', headers: auth,
    body: JSON.stringify({ source: { files: [{ name: 'firestore.rules', content }] } }),
  });
  const ruleset = await mk.json();
  if (!ruleset.name) { console.error('compile failed:\n' + JSON.stringify(ruleset, null, 2)); process.exit(1); }
  console.log('compiled:   ' + ruleset.name);

  if (!process.argv.includes('--release')) {
    console.log('\nDRY RUN — the ruleset exists but nothing points at it. Re-run with --release.');
    return;
  }

  const rel = await fetch(`https://firebaserules.googleapis.com/v1/projects/${PROJECT}/releases/${RELEASE}`, {
    method: 'PATCH', headers: auth,
    body: JSON.stringify({ release: { name: `projects/${PROJECT}/releases/${RELEASE}`, rulesetName: ruleset.name } }),
  });
  const out = await rel.json();
  if (out.error) { console.error('release failed:\n' + JSON.stringify(out, null, 2)); process.exit(1); }
  console.log('released:   ' + out.rulesetName);
  console.log('previous:   ' + (before.rulesetName || '(none)') + '   <- roll back to this if needed');
})();
