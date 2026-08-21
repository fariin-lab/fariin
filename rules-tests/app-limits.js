// Read or change `config/limits` — the live ceilings the app and the rules both read.
//
//   node app-limits.js                              # show what is set right now
//   node app-limits.js stories_per_day_default=0     # set one or more, as integers
//   node app-limits.js --clear                      # delete the document, back to the built-in numbers
//
// ⛔ THIS IS LIVE AND IT IS EVERY USER, the moment it lands. There is no build, no rollout and no
// delay: `firestore.rules` reads this document inside the story-create rule and the app listens to
// it. That is the whole point of it existing, and it is also why it deserves the shouting.
//
// ⚠️ TO TURN STORIES OFF, USE `stories_enabled=0`, NOT A CEILING OF ZERO. Setting
// `stories_per_day_default=0` looks like it should stop everybody and it does not: the budget
// clauses in the rules open with `!exists(the counter)`, a deliberate fail-open, so an account that
// has never posted a story has no counter and is allowed straight through. MEASURED against the
// deployed rules, not reasoned: at a daily limit of 0, an account with a live counter is refused and
// an account with no counter document posts fine. `stories_enabled` is its own clause in front of
// all of that, where nothing can short-circuit around it.
//
// ⚠️ THE APP DOES NOT YET KNOW ABOUT ANY OF THIS, and that is the honest state until the next build.
// `AppLimits` ignores anything that is not a positive integer, so a phone still believes the limit
// is 50, still opens the picker, and the write is then refused by the database — the person gets the
// "that's today's limit" sentence rather than "stories are off". The rules are the enforcement and
// they work this second; the wording is what needs a release.
//
// Written with the CLI's OAuth token, which bypasses rules — the rules let the OWNER write this
// document and nobody else, and no owner is signed in here.
const { token } = require('./auth');

const PROJECT = 'kulan-2ef85';
const DOC = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/config/limits`;

// Every key the two halves know about, with the number that applies when it is absent. Kept here so
// this script can refuse a typo instead of quietly writing a key nothing will ever read.
const KNOWN = {
  stories_per_day_default: 50,
  stories_per_day_verified: 100,
  stories_per_hour_default: 40,
  stories_per_hour_verified: 40,
  // 0 turns story posting off for everybody, immediately, with no build. Absent or 1 = on. It is
  // its own clause in the rules rather than a ceiling of zero, because the ceilings fail open for
  // an account with no counter yet — see the note on `stories_enabled` in firestore.rules.
  stories_enabled: 1,
};

(async () => {
  const t = await token();
  const auth = { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' };
  const args = process.argv.slice(2);

  if (args.includes('--clear')) {
    const res = await fetch(DOC, { method: 'DELETE', headers: auth });
    console.log(res.ok ? 'config/limits DELETED — every limit is back to the number built into the app and the rules'
                       : `delete failed: ${res.status} ${await res.text()}`);
    return;
  }

  const sets = args.filter((a) => a.includes('='));
  if (sets.length) {
    const fields = {};
    for (const pair of sets) {
      const [k, v] = pair.split('=');
      if (!(k in KNOWN)) { console.error(`unknown key "${k}". Known: ${Object.keys(KNOWN).join(', ')}`); process.exit(1); }
      if (!/^-?\d+$/.test(v)) { console.error(`"${k}" must be a whole number, got "${v}"`); process.exit(1); }
      // integerValue, NOT stringValue. A string is ignored by both halves on purpose, so writing one
      // here would look like an edit that did nothing.
      fields[k] = { integerValue: String(parseInt(v, 10)) };
    }
    const mask = Object.keys(fields).map((k) => `updateMask.fieldPaths=${k}`).join('&');
    const res = await fetch(`${DOC}?${mask}`, { method: 'PATCH', headers: auth, body: JSON.stringify({ fields }) });
    if (!res.ok) { console.error(`write failed: ${res.status} ${await res.text()}`); process.exit(1); }
    console.log('wrote: ' + Object.entries(fields).map(([k, v]) => `${k}=${v.integerValue}`).join('  '));
  }

  const res = await fetch(DOC, { headers: auth });
  if (res.status === 404) { console.log('\nconfig/limits does not exist — the built-in numbers are in force:'); }
  const body = res.status === 404 ? { fields: {} } : await res.json();
  const live = body.fields || {};
  console.log('');
  for (const [k, fallback] of Object.entries(KNOWN)) {
    const f = live[k];
    const shown = f ? (f.integerValue !== undefined ? f.integerValue : `⚠️ ${JSON.stringify(f)} (not an integer — IGNORED)`)
                    : `${fallback}  (not set, built-in)`;
    console.log(`  ${k.padEnd(26)} ${shown}`);
  }
  const unknown = Object.keys(live).filter((k) => !(k in KNOWN));
  if (unknown.length) console.log(`\n  ⚠️ keys nothing reads: ${unknown.join(', ')}`);
})();
