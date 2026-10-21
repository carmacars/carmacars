// Local production server: `next start` behind a small proxy that does what the Worker entry
// (custom-worker.ts) does on Cloudflare: security headers on every response, and on HTML a fresh
// nonce on every <script> plus the matching content security policy, and compression like
// Cloudflare's edge (brotli or gzip). Tests and Lighthouse run against this.
//
//   PORT=3000 node scripts/serve.mjs
import http from 'node:http';
import fs from 'node:fs';
import { spawn } from 'node:child_process';
import { createHmac, randomBytes } from 'node:crypto';
import zlib from 'node:zlib';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.PORT || 3000);
const INNER = PORT + 100;

// Same policy as src/lib/security/csp.ts (kept in step by tests/e2e/security.spec.ts).
const csp = (nonce) => [
  "default-src 'self'", `script-src 'self' 'nonce-${nonce}' https://challenges.cloudflare.com https://js.stripe.com`, "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:", "font-src 'self'", "connect-src 'self' https://*.supabase.co wss://*.supabase.co https://api.stripe.com https://*.r2.cloudflarestorage.com https://challenges.cloudflare.com",
  'frame-src https://challenges.cloudflare.com https://js.stripe.com https://hooks.stripe.com', "frame-ancestors 'none'", "form-action 'self'", "base-uri 'none'", "object-src 'none'"
].join('; ');
const security = {
  'x-content-type-options': 'nosniff', 'x-frame-options': 'DENY', 'referrer-policy': 'strict-origin-when-cross-origin',
  'permissions-policy': 'camera=(self), microphone=(), geolocation=(), payment=(self), usb=(), interest-cohort=()', 'cross-origin-opener-policy': 'same-origin'
};

const next = spawn(process.execPath, [path.join(WEB, 'node_modules/next/dist/bin/next'), 'start', '-p', String(INNER), '-H', '127.0.0.1'], { cwd: WEB, stdio: 'inherit', env: process.env });
process.on('SIGTERM', () => { next.kill('SIGTERM'); process.exit(0); });
process.on('SIGINT', () => { next.kill('SIGINT'); process.exit(0); });

// Files the app writes to the public photo bucket after the build (the listing pipeline's processed photos)
// live in the local storage folder; served here under the bucket's address, as the Worker serves /media.
const STORE = process.env.LOCAL_STORAGE_DIR ?? path.join(WEB, '.local-storage');
const TYPES = { '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.webp': 'image/webp', '.avif': 'image/avif', '.svg': 'image/svg+xml' };
function localPublic(req, res) {
  const u = decodeURIComponent((req.url || '').split('?')[0]);
  if (!u.startsWith('/_local/vehicle-public/') || (req.method !== 'GET' && req.method !== 'HEAD')) return false;
  const root = path.join(STORE, 'vehicle-public');
  const file = path.resolve(root, u.slice('/_local/vehicle-public/'.length));
  if (!file.startsWith(root + path.sep) || !fs.existsSync(file)) return false;
  res.writeHead(200, { ...security, 'content-type': TYPES[path.extname(file).toLowerCase()] ?? 'application/octet-stream', 'cache-control': 'public, max-age=60' });
  if (req.method === 'HEAD') res.end(); else fs.createReadStream(file).pipe(res);
  return true;
}

// The same rule as the Worker entry (src/lib/security/view-as-guard.ts): while an Admin views as someone, every write
// outside the Admin portal is refused; requests for the Admin portal are marked so the Admin is themselves there.
const VIEW_AS_COOKIE = 'cc-view-as';
const isAdminArea = (p) => /^\/admin(\/|$)/.test(p);
function viewAsWriteRefused(method, pathname, cookie) {
  if (['GET', 'HEAD', 'OPTIONS'].includes(method)) return false;
  if (!String(cookie || '').split(';').some((p) => p.trim().startsWith(`${VIEW_AS_COOKIE}=`) && p.trim().length > VIEW_AS_COOKIE.length + 1)) return false;
  return !(isAdminArea(pathname) || pathname.startsWith('/api/view-as/') || pathname.startsWith('/api/webhooks/'));
}

http.createServer((req, res) => {
  if (localPublic(req, res)) return;
  const pathname = (req.url || '/').split('?')[0];
  if (viewAsWriteRefused(req.method, pathname, req.headers.cookie)) {
    if (req.headers['next-action']) { res.writeHead(200, { ...security, 'content-type': 'text/plain', 'cache-control': 'no-store', 'x-action-redirect': '/read-only;push' }); res.end(); }
    else {
      res.writeHead(403, { ...security, 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' });
      res.end('Read only. You are viewing CarmaCars as another person, so nothing can be changed. Use Exit on the red banner to go back to your own account.');
    }
    req.resume();
    return;
  }
  const headers = { ...req.headers, 'accept-encoding': 'identity', 'x-forwarded-host': req.headers.host, 'x-forwarded-proto': 'http' };
  delete headers['x-cc-admin-area'];
  if (isAdminArea(pathname)) headers['x-cc-admin-area'] = '1';
  const up = http.request({ host: '127.0.0.1', port: INNER, method: req.method, path: req.url, headers }, (r) => {
    const h = { ...r.headers, ...security };
    // the email link's outbox row, kept through a sign-in redirect for the beacon (src/lib/track/shared.ts emailLinkCookie)
    const mm = req.method === 'GET' && pathname.startsWith('/account/bookings/') ? /[?&]m=([0-9a-f-]{36})(?:&|$)/.exec(req.url || '') : null;
    if (mm) h['set-cookie'] = [...[].concat(r.headers['set-cookie'] ?? []), `cc_m=${mm[1]}; Path=/; Max-Age=3600; SameSite=Lax`];
    const type = String(r.headers['content-type'] || '');
    const html = type.includes('text/html');
    const accept = String(req.headers['accept-encoding'] || '');
    const enc = /\b(text|javascript|json|xml|svg|css)\b/.test(type) && !r.headers['content-encoding'] ? (accept.includes('br') ? 'br' : accept.includes('gzip') ? 'gzip' : '') : '';
    const squeeze = () => (enc === 'br' ? zlib.createBrotliCompress({ params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 5 } }) : zlib.createGzip());
    if (enc) { h['content-encoding'] = enc; h.vary = [h.vary, 'Accept-Encoding'].filter(Boolean).join(', '); delete h['content-length']; }
    if (!html) { res.writeHead(r.statusCode, h); if (enc) r.pipe(squeeze()).pipe(res); else r.pipe(res); return; }
    const chunks = [];
    r.on('data', (c) => chunks.push(c));
    r.on('end', () => {
      const nonce = randomBytes(16).toString('base64');
      const body = Buffer.from(Buffer.concat(chunks).toString('utf8').replace(/<script(?=[\s>])/g, `<script nonce="${nonce}"`));
      delete h['content-length']; delete h['transfer-encoding'];
      h['content-security-policy'] = csp(nonce);
      const out = enc === 'br' ? zlib.brotliCompressSync(body, { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 5 } }) : enc === 'gzip' ? zlib.gzipSync(body) : body;
      h['content-length'] = out.length;
      res.writeHead(r.statusCode, h); res.end(out);
    });
  });
  up.on('error', () => { res.writeHead(502); res.end('Starting'); });
  req.pipe(up);
}).listen(PORT, () => console.log(`serve: http://localhost:${PORT} (next on ${INNER})`));

// What the Worker's cron tick does on Cloudflare (custom-worker.ts, src/lib/edge/fleet-sig.ts): a car put on or taken
// off the site in the database alone rebuilds the fleet page, home, the model pages and the sitemaps. Here every few
// seconds (PUBLIC_REBUILD_TICK_MS, 0 turns it off); the route rebuilds only when the fleet's signature changed.
const fileEnv = {};
for (const f of ['.env', '.env.production', '.env.local']) {
  try { for (const m of fs.readFileSync(path.join(WEB, f), 'utf8').matchAll(/^([A-Z0-9_]+)=([^#\n]*)/gm)) fileEnv[m[1]] = m[2].trim(); } catch { /* not there */ }
}
const envOf = (k) => process.env[k] ?? fileEnv[k];
const TICK = Number(process.env.PUBLIC_REBUILD_TICK_MS ?? 10_000);
const secret = envOf('LINK_SIGNING_KEY') || (envOf('APP_ENV') === 'production' ? '' : envOf('LOCAL_AUTH_SECRET') || 'local-only-link-signing-key-not-for-production');
if (TICK > 0 && secret) {
  const token = createHmac('sha256', secret).update('carmacars-listing-worker-v1').digest('hex');
  const tick = () => {
    const r = http.request({ host: '127.0.0.1', port: INNER, method: 'POST', path: '/api/jobs/public-rebuild',
      headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' } }, (res) => res.resume());
    r.on('error', () => {});
    r.end('{"check":true}');
  };
  setInterval(tick, TICK).unref();
}
