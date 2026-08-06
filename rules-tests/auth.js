// Small Firestore REST helper using the firebase-tools refresh token. Reads only unless told
// otherwise. An OAuth token with cloud-platform scope bypasses security rules, which is exactly what
// seeding the owner row needs (the rules deliberately refuse it from any client).
const fs = require('fs');
const os = require('os');
const path = require('path');

const PROJECT = 'kulan-2ef85';
const BASE = `https://firestore.googleapis.com/v1/projects/${PROJECT}/databases/(default)/documents`;

async function token() {
  // ⚠️ AN ESCAPE HATCH FOR WHEN NODE CANNOT REACH GOOGLE FROM THIS PC.
  //
  // Node's fetch times out against oauth2.googleapis.com here while PowerShell's Invoke-RestMethod
  // on the same machine succeeds — repeatedly, on the same network, minutes apart. Rather than
  // discover that mid-suite and report a rules failure that is really a connectivity failure, mint
  // the token in PowerShell and hand it over:
  //
  //   $env:FIREBASE_ACCESS_TOKEN = "<token from the oauth exchange>"
  //
  // Same token, same scope, one fewer hop that can time out.
  if (process.env.FIREBASE_ACCESS_TOKEN) return process.env.FIREBASE_ACCESS_TOKEN;
  const cfg = JSON.parse(fs.readFileSync(path.join(os.homedir(), '.config/configstore/firebase-tools.json'), 'utf8'));
  const res = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'refresh_token',
      refresh_token: cfg.tokens.refresh_token,
      client_id: '563584335869-fgrhgmd47bqnekij5i8b5pr03ho849e6.apps.googleusercontent.com',
      client_secret: 'j9iVZfS8kkCEFUPaAeJV0sAi',
    }),
  });
  const j = await res.json();
  if (!j.access_token) throw new Error('no access token: ' + JSON.stringify(j));
  return j.access_token;
}

async function get(t, pathSuffix) {
  const res = await fetch(`${BASE}/${pathSuffix}`, { headers: { Authorization: `Bearer ${t}` } });
  return { status: res.status, body: await res.json() };
}

async function patch(t, pathSuffix, fields) {
  const res = await fetch(`${BASE}/${pathSuffix}`, {
    method: 'PATCH',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ fields }),
  });
  return { status: res.status, body: await res.json() };
}

async function runQuery(t, body) {
  const res = await fetch(`${BASE}:runQuery`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${t}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return { status: res.status, body: await res.json() };
}

module.exports = { token, get, patch, runQuery, BASE };
