// Read or change `config/limits` — the live ceilings and switches the app and the rules both read.
//
//   node app-limits.js                                  # show what is set right now
//   node app-limits.js stories=off                      # nobody can post a story, this second
//   node app-limits.js stories=verified                 # only verified accounts can
//   node app-limits.js stories=normal                   # only ordinary accounts can
//   node app-limits.js stories=on                       # everybody again
//   node app-limits.js stories_enabled_verified=off     # or set one side on its own
//   node app-limits.js stories_per_day_default=200      # any ceiling, as a number
//   node app-limits.js --clear                          # delete the document, back to the built-ins
//
// ⛔ THIS IS LIVE AND IT IS EVERY USER, the moment it lands. There is no build, no rollout and no
// delay: `firestore.rules` reads this document inside the story-create rule and the app listens to
// it. That is the whole point of it existing, and it is also why it deserves the shouting.
//
// ⚠️ TO TURN STORIES OFF, USE THE SWITCHES, NOT A CEILING OF ZERO. Setting
// `stories_per_day_default=0` looks like it should stop everybody and it does not: the budget
// clauses in the rules open with `!exists(the counter)`, a deliberate fail-open, so an account that
// has never posted a story has no counter and is allowed straight through. MEASURED against the
// deployed rules, not reasoned: at a daily limit of 0, an account with a live counter is refused and
// an account with no counter document posts fine. The two `stories_enabled_*` flags are their own
// clause in front of all of that, where nothing can short-circuit around them.
//
// Written with the CLI's OAuth token, which bypasses rules — the rules let the OWNER write this
// document and nobody else, and no owner is signed in here.
const { token } = require('./auth');

const PROJECT = 'kulan-2ef85';
const DOC = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents/config/limits`;

// Every key the two halves know about, with the number that applies when it is absent. Kept here so
// this script can refuse a typo instead of quietly writing a key nothing will ever read.
const KNOWN = {
  stories_enabled_default: 1,
  stories_enabled_verified: 1,
  stories_per_day_default: 50,
  stories_per_day_verified: 100,
  stories_per_hour_default: 40,
  stories_per_hour_verified: 40,
  // How many stories may be ALIVE at once — a different question from how many were posted today.
  // Defaults match the daily ceilings, so they are exactly as permissive as before and are there to
  // be turned DOWN. See `story_expiring_limit_*` in firestore.rules.
  story_expiring_limit_default: 50,
  story_expiring_limit_verified: 100,
};

// The switches are 0 or 1, and every other value reads as 1 — see `appLimit` in firestore.rules.
const SWITCHES = ['stories_enabled_default', 'stories_enabled_verified'];
const WORDS = { off: 0, no: 0, disabled: 0, on: 1, yes: 1, enabled: 1 };

// `stories=` writes BOTH switches in one go, because "off for everybody" and "verified only" are the
// two things somebody actually wants to type, and doing it as two commands leaves a window where one
// tier is off and the other is not.
const PRESETS = {
  off:      { stories_enabled_default: 0, stories_enabled_verified: 0 },
  on:       { stories_enabled_default: 1, stories_enabled_verified: 1 },
  verified: { stories_enabled_default: 0, stories_enabled_verified: 1 },   // only verified may post
  normal:   { stories_enabled_default: 1, stories_enabled_verified: 0 },   // only ordinary may post
};

(async () => {
  const t = await token();
  const auth = { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' };
  const args = process.argv.slice(2);

  if (args.includes('--clear')) {
    const res = await fetch(DOC, { method: 'DELETE', headers: auth });
    console.log(res.ok ? 'config/limits DELETED — every limit and switch is back to the number built into the app and the rules'
                       : `delete failed: ${res.status} ${await res.text()}`);
    return;
  }

  const fields = {};
  for (const pair of args.filter((a) => a.includes('='))) {
    const [k, v] = pair.split('=');
    if (k === 'stories') {
      const preset = PRESETS[v];
      if (!preset) { console.error(`stories= wants one of: ${Object.keys(PRESETS).join(', ')}`); process.exit(1); }
      for (const [pk, pv] of Object.entries(preset)) fields[pk] = { integerValue: String(pv) };
      continue;
    }
    if (!(k in KNOWN)) { console.error(`unknown key "${k}". Known: stories, ${Object.keys(KNOWN).join(', ')}`); process.exit(1); }
    const n = v in WORDS ? WORDS[v] : (/^-?\d+$/.test(v) ? parseInt(v, 10) : null);
    if (n === null) { console.error(`"${k}" wants a whole number, or one of: ${Object.keys(WORDS).join(', ')}`); process.exit(1); }
    // integerValue, NOT stringValue. A string is ignored by both halves on purpose, so writing one
    // here would look like an edit that did nothing.
    fields[k] = { integerValue: String(n) };
  }

  if (Object.keys(fields).length) {
    const mask = Object.keys(fields).map((k) => `updateMask.fieldPaths=${k}`).join('&');
    const res = await fetch(`${DOC}?${mask}`, { method: 'PATCH', headers: auth, body: JSON.stringify({ fields }) });
    if (!res.ok) { console.error(`write failed: ${res.status} ${await res.text()}`); process.exit(1); }
    console.log('wrote: ' + Object.entries(fields).map(([k, v]) => `${k}=${v.integerValue}`).join('  '));
  }

  const res = await fetch(DOC, { headers: auth });
  if (res.status === 404) console.log('\nconfig/limits does not exist — the built-in numbers are in force:');
  const body = res.status === 404 ? { fields: {} } : await res.json();
  const live = body.fields || {};
  const value = (k) => {
    const f = live[k];
    if (!f) return { n: KNOWN[k], note: '  (not set, built-in)' };
    if (f.integerValue === undefined) return { n: KNOWN[k], note: '  ⚠️ not an integer, IGNORED — the built-in applies' };
    return { n: Number(f.integerValue), note: '' };
  };

  console.log('');
  for (const k of Object.keys(KNOWN)) {
    const { n, note } = value(k);
    const state = SWITCHES.includes(k) ? (n === 0 ? '   ⛔ CANNOT POST' : '   can post') : '';
    console.log(`  ${k.padEnd(30)} ${String(n).padEnd(4)}${state}${note}`);
  }
  const d = value('stories_enabled_default').n !== 0;
  const v = value('stories_enabled_verified').n !== 0;
  console.log(`\n  STORIES: ${d && v ? 'on for everybody' : !d && !v ? 'OFF FOR EVERYBODY'
                : d ? 'ordinary accounts only (verified are blocked)' : 'verified accounts only (ordinary are blocked)'}`);

  const unknown = Object.keys(live).filter((k) => !(k in KNOWN));
  if (unknown.length) console.log(`\n  ⚠️ keys nothing reads: ${unknown.join(', ')}`);
})();
