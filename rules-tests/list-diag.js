// Every phone's recent diag uploads, newest first, across all accounts (collection group query).
// Read-only. Shows which accounts uploaded and when, so a report can be matched to its phone.
//
//   node list-diag.js [count]
const { token } = require('./auth');
const count = Number(process.argv[2] || 20);
const BASE = 'https://firestore.googleapis.com/v1/projects/kulan-2ef85/databases/(default)/documents';

(async () => {
  const t = await token();
  const res = await fetch(`${BASE}:runQuery`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ structuredQuery: {
      from: [{ collectionId: 'diag', allDescendants: true }],
      orderBy: [{ field: { fieldPath: 'at' }, direction: 'DESCENDING' }],
      limit: count,
    } }),
  });
  const rows = await res.json();
  if (!Array.isArray(rows)) { console.error(JSON.stringify(rows)); process.exit(1); }
  for (const r of rows) {
    if (!r.document) continue;
    const f = r.document.fields || {};
    const uid = r.document.name.split('/users/')[1]?.split('/')[0];
    const log = f.log?.stringValue || f.text?.stringValue || '';
    console.log(`${f.at?.timestampValue || '?'}  uid ${uid}  build ${f.build?.stringValue || '?'}  ` +
      `reason ${f.reason?.stringValue || '?'}  ${log.length} chars`);
  }
})();
