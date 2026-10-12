// Local production server: `next start` behind a small proxy that does what the Worker entry
// (custom-worker.ts) does on Cloudflare: security headers on every response, and on HTML a fresh
// nonce on every <script> plus the matching content security policy. Tests run against this.
//
//   PORT=3000 node scripts/serve.mjs
import http from 'node:http';
import { spawn } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.PORT || 3000);
const INNER = PORT + 100;

// Same policy as src/lib/security/csp.ts (kept in step by tests/e2e/security.spec.ts).
const csp = (nonce) => [
  "default-src 'self'", `script-src 'self' 'nonce-${nonce}' https://challenges.cloudflare.com`, "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:", "font-src 'self'", "connect-src 'self' https://*.supabase.co wss://*.supabase.co https://challenges.cloudflare.com",
  'frame-src https://challenges.cloudflare.com', "frame-ancestors 'none'", "form-action 'self'", "base-uri 'none'", "object-src 'none'"
].join('; ');
const security = {
  'x-content-type-options': 'nosniff', 'x-frame-options': 'DENY', 'referrer-policy': 'strict-origin-when-cross-origin',
  'permissions-policy': 'camera=(self), microphone=(), geolocation=(), payment=(self), usb=(), interest-cohort=()', 'cross-origin-opener-policy': 'same-origin'
};

const next = spawn(process.execPath, [path.join(WEB, 'node_modules/next/dist/bin/next'), 'start', '-p', String(INNER), '-H', '127.0.0.1'], { cwd: WEB, stdio: 'inherit', env: process.env });
process.on('SIGTERM', () => { next.kill('SIGTERM'); process.exit(0); });
process.on('SIGINT', () => { next.kill('SIGINT'); process.exit(0); });

http.createServer((req, res) => {
  const headers = { ...req.headers, 'accept-encoding': 'identity', 'x-forwarded-host': req.headers.host, 'x-forwarded-proto': 'http' };
  const up = http.request({ host: '127.0.0.1', port: INNER, method: req.method, path: req.url, headers }, (r) => {
    const h = { ...r.headers, ...security };
    const html = String(r.headers['content-type'] || '').includes('text/html');
    if (!html) { res.writeHead(r.statusCode, h); r.pipe(res); return; }
    const chunks = [];
    r.on('data', (c) => chunks.push(c));
    r.on('end', () => {
      const nonce = randomBytes(16).toString('base64');
      const body = Buffer.from(Buffer.concat(chunks).toString('utf8').replace(/<script(?=[\s>])/g, `<script nonce="${nonce}"`));
      delete h['content-length']; delete h['transfer-encoding'];
      h['content-security-policy'] = csp(nonce); h['content-length'] = body.length;
      res.writeHead(r.statusCode, h); res.end(body);
    });
  });
  up.on('error', () => { res.writeHead(502); res.end('Starting'); });
  req.pipe(up);
}).listen(PORT, () => console.log(`serve: http://localhost:${PORT} (next on ${INNER})`));
