// Print the hidden diagnostic logs a phone uploaded (DiagLog.swift -> users/{uid}/diag), newest
// first. Read-only; uses the same firebase-tools token as the rules tests.
//
//   node read-diag.js <uid> [count]
//
// Each document is one upload: the tail of the phone's diag.log at the time (story trace lines are
// prefixed "story:", with "+Nms" = time since the last cube landing).
const { token } = require('./auth');

//   node read-diag.js @username [count]      (the app's own lookup: usernames/{lowercase} -> uid)
const who = process.argv[2];
const count = Number(process.argv[3] || 3);
if (!who) { console.error('usage: node read-diag.js <uid | @username> [count]'); process.exit(2); }

const BASE = 'https://firestore.googleapis.com/v1/projects/kulan-2ef85/databases/(default)/documents';

async function resolve(t) {
  if (!who.startsWith('@')) return who;
  const res = await fetch(`${BASE}/usernames/${who.slice(1).toLowerCase()}`, { headers: { Authorization: `Bearer ${t}` } });
  const j = await res.json();
  if (j.error) { console.error('username lookup: ' + JSON.stringify(j.error)); process.exit(1); }
  const f = j.fields || {};
  const uid = (f.uid || f.userId || f.owner || f.id)?.stringValue;
  if (!uid) { console.error('username doc has no uid field; fields: ' + Object.keys(f).join(', ')); process.exit(1); }
  return uid;
}

(async () => {
  const t = await token();
  const uid = await resolve(t);
  const res = await fetch(`${BASE}/users/${uid}/diag?orderBy=at%20desc&pageSize=${count}`, {
    headers: { Authorization: `Bearer ${t}` },
  });
  const j = await res.json();
  if (j.error) { console.error(JSON.stringify(j.error)); process.exit(1); }
  const docs = j.documents || [];
  if (!docs.length) { console.log('no uploads yet'); return; }
  for (const d of docs) {
    const f = d.fields || {};
    console.log(`===== ${f.at?.timestampValue || '?'}  build ${f.build?.stringValue || '?'}  iOS ${f.ios?.stringValue || '?'}`);
    console.log(f.text?.stringValue || '');
  }
})();
