// Release 42: the Node entry (scripts/vps-server.mjs, HOSTING_TARGET=node) answers before any DNS change
// (deploy-vps.yml, job node-smoke; docs/hosting/off-cloudflare.md). Run against a server already started on BASE_URL
// with the local stack: health, home, sign-in, the fleet and a car page without a 5xx, each page with a nonce policy;
// a scanner path 404; and inbound email: an unsigned message refused, a signed one taken by the Turo reader.
//   BASE_URL=http://localhost:3000 ENV_FILE=.env.local node scripts/node-smoke.mjs
import fs from 'node:fs';
import { inboundSecret, signInbound, INBOUND_PATH, SIGNATURE_HEADER } from '../src/lib/platform/inbound-email.ts';

const BASE = (process.env.BASE_URL || 'http://localhost:3000').replace(/\/$/, '');
const envFile = process.env.ENV_FILE || '.env.local';
let key = process.env.LINK_SIGNING_KEY || '';
if (!key && fs.existsSync(envFile)) key = (/^LINK_SIGNING_KEY=(.*)$/m.exec(fs.readFileSync(envFile, 'utf8'))?.[1] ?? '').replace(/\s+#.*$/, '').trim();

const problems = [];
const get = (p, init) => fetch(BASE + p, { redirect: 'manual', signal: AbortSignal.timeout(90_000), ...init });

const health = await get('/healthz').then((r) => r.json()).catch((e) => ({ error: String(e) }));
console.log(`/healthz ${JSON.stringify(health)}`);
if (!health.ok || health.target !== 'node') problems.push(`/healthz: ${JSON.stringify(health)}`);

for (const p of ['/', '/sign-in', '/cars', '/cars/mercedes-benz-c300']) {
  const r = await get(p).catch((e) => ({ status: 0, headers: new Headers(), text: async () => String(e) }));
  const body = await r.text();
  const csp = r.headers.get('content-security-policy') ?? '';
  const nonce = /'nonce-([^']+)'/.exec(csp)?.[1];
  const html = (r.headers.get('content-type') ?? '').includes('text/html');
  console.log(`${p} ${r.status}${html ? (nonce ? ' (nonce policy)' : ' (NO nonce policy)') : ''}`);
  if (r.status === 0 || r.status >= 500) problems.push(`${p}: ${r.status || body.slice(0, 200)}`);
  if (p === '/' && r.status !== 200) problems.push(`/: ${r.status}, expected 200`);
  if (html && r.status === 200 && (!nonce || !body.includes(`<script nonce="${nonce}"`))) problems.push(`${p}: no nonce on the scripts or no matching policy`);
  if (!r.headers.get('x-content-type-options')) problems.push(`${p}: the security headers are missing`);
}

const probe = await get('/wp-login.php');
console.log(`/wp-login.php ${probe.status}`);
if (probe.status !== 404) problems.push(`/wp-login.php: ${probe.status}, expected 404`);

const from = 'smoke@example.test', to = 'trips@in.carmacars.ca';
const raw = `From: Smoke <${from}>\r\nTo: ${to}\r\nSubject: Node entry smoke\r\nMessage-ID: <smoke-${Date.now()}@example.test>\r\nDate: ${new Date().toUTCString()}\r\n\r\nNot a Turo email.\r\n`;
const post = (signature) => get(INBOUND_PATH, { method: 'POST', body: raw, headers: { 'content-type': 'message/rfc822', 'x-envelope-from': from, 'x-envelope-to': to, ...(signature ? { [SIGNATURE_HEADER]: signature } : {}) } });
const unsigned = await post(null);
console.log(`inbound email, unsigned: ${unsigned.status}`);
if (unsigned.status !== 403) problems.push(`inbound email: an unsigned message answered ${unsigned.status}, expected 403`);
if (!key) problems.push('inbound email: no LINK_SIGNING_KEY to sign the test message with');
else {
  const t = Math.floor(Date.now() / 1000);
  const forged = await post(await signInbound(await inboundSecret('not-the-key'), t, from, to, raw));
  if (forged.status !== 403) problems.push(`inbound email: a message signed with another key answered ${forged.status}, expected 403`);
  const signed = await post(await signInbound(await inboundSecret(key), t, from, to, raw));
  const j = await signed.json().catch(() => null);
  console.log(`inbound email, signed: ${signed.status} ${JSON.stringify(j)}`);
  if (signed.status !== 200 || !j?.ok) problems.push(`inbound email: a signed message answered ${signed.status}, expected 200`);
}

if (problems.length) {
  for (const p of problems) console.log(`::error title=node smoke::${p}`);
  process.exit(1);
}
console.log('node smoke: passed');
