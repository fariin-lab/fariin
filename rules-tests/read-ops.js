// Print the app-health issues the server grouped (opsIssues), worst and newest first, with each
// issue's latest sample. Read-only; same firebase-tools token as read-diag.js. For the AI watcher
// (owner 2026-10-21: "monitor new issues without me reporting them").
//
//   node read-ops.js [count] [status]        status: new | open | regressed | all (default: not resolved)
//   node read-ops.js --alerts [count]         the newest alerts the detector raised

const { token } = require('./auth');

const BASE = 'https://firestore.googleapis.com/v1/projects/kulan-2ef85/databases/(default)/documents';
const args = process.argv.slice(2);
const alerts = args[0] === '--alerts';
const count = Number((alerts ? args[1] : args[0]) || 25);
const status = alerts ? null : (args[1] || 'unresolved');

// Firestore REST values into plain JS.
function val(v) {
  if (!v) return undefined;
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return v.timestampValue;
  if ('nullValue' in v) return null;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(val);
  if ('mapValue' in v) return obj(v.mapValue.fields || {});
  return undefined;
}
const obj = (f) => Object.fromEntries(Object.entries(f).map(([k, v]) => [k, val(v)]));

const RANK = { P0: 0, P1: 1, P2: 2, P3: 3 };

(async () => {
  const t = await token();
  const coll = alerts ? 'opsAlerts' : 'opsIssues';
  const res = await fetch(`${BASE}/${coll}?pageSize=300`, { headers: { Authorization: `Bearer ${t}` } });
  const j = await res.json();
  if (j.error) { console.error(JSON.stringify(j.error)); process.exit(1); }
  let rows = (j.documents || []).map((d) => ({ id: d.name.split('/').pop(), ...obj(d.fields || {}) }));
  if (!rows.length) { console.log(alerts ? 'no alerts' : 'no issues recorded'); return; }
  if (alerts) {
    rows.sort((a, b) => String(b.at || b.createdAt || '').localeCompare(String(a.at || a.createdAt || '')));
  } else {
    if (status === 'unresolved') rows = rows.filter((r) => !['resolved', 'ignored'].includes(r.status));
    else if (status !== 'all') rows = rows.filter((r) => r.status === status);
    rows.sort((a, b) => (RANK[a.priority] ?? 9) - (RANK[b.priority] ?? 9)
      || String(b.lastSeen || '').localeCompare(String(a.lastSeen || '')));
  }
  for (const r of rows.slice(0, count)) console.log(JSON.stringify(r, null, 1));
})();
