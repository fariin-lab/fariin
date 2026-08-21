// Write the DEPLOYED rules to a file so they can be diffed against the repo copy.
//
//   node fetch-live.js [outfile]      # default: live.rules
//
// There is no CLI command for this. The Rules REST API is the only way to read what is actually
// enforced, and reading it before every deploy is the habit that catches the repo copy having
// drifted ahead of live with somebody else's unshipped change in it.
const fs = require('fs');
const { token } = require('./auth');

const PROJECT = 'kulan-2ef85';
const OUT = process.argv[2] || 'live.rules';

(async () => {
  const t = await token();
  const auth = { Authorization: `Bearer ${t}` };
  const rel = await (await fetch(
    `https://firebaserules.googleapis.com/v1/projects/${PROJECT}/releases/cloud.firestore`, { headers: auth })).json();
  if (!rel.rulesetName) { console.error(JSON.stringify(rel, null, 2)); process.exit(1); }
  const rs = await (await fetch(
    `https://firebaserules.googleapis.com/v1/${rel.rulesetName}`, { headers: auth })).json();
  const file = rs.source.files.find(f => f.name.endsWith('.rules')) || rs.source.files[0];
  fs.writeFileSync(OUT, file.content);
  console.log(`live ruleset: ${rel.rulesetName}`);
  console.log(`created:      ${rs.createTime}`);
  console.log(`wrote:        ${OUT}  (${file.content.split('\n').length} lines)`);
})();
