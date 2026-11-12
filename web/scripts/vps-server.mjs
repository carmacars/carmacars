// Release 42: the site's entry on the company's server (docs/hosting/off-cloudflare.md, infra/vps/web). It starts the
// standalone Next.js server (`npm run build:node`, .next/standalone) on an inner port and stands in front of it, doing
// what the Worker entry (custom-worker.ts) does on Cloudflare with the same modules:
//   - scanners and unused framework paths answered 404, the crawler shield, the place and model-year 404s;
//   - a write from another site refused, an Admin viewing as someone kept read only, the Admin portal marked;
//   - the Supabase session refreshed before the app reads it;
//   - the security headers on every response, and on HTML a fresh nonce on every <script> with the matching policy;
//   - the notices due asked for right after a write, and, with CRON_ENABLED=1, the minute tick of the job routes.
//   - inbound email: POST /api/inbound/email from the free Email Worker (infra/cloudflare/email-forwarder), signed;
//     it runs what the Worker entry's email() runs (src/lib/platform/inbound-email.ts);
//   - Bytespider paced (60 pages a minute), and the scraper guard's check for an agent posing as a browser on a
//     long-tail page (SCRAPER_GUARD=0 turns it off). The hosting-network rule needs Cloudflare's network data, which
//     the free plan does not send to a server: not here;
//   - the last good copy of each public page on disk (COPIES_DIR; KEPT_COPIES=0 turns it off): served when the app
//     answers 5xx, cannot be reached or takes more than 4 seconds, and to the scraper guard;
//   - the cookie notice's region cookie (cc_geo) from the headers of Cloudflare's free proxy (src/lib/platform/node-edge.ts).
// Not here: the edge copies per data centre (Next.js keeps its own page cache on disk; Cloudflare's free proxy caches
// the static files), cached-only mode by usage (nothing is billed by CPU time on the server).
// TLS, http to https and compression are Caddy's (infra/vps/web/site.caddy).
//
//   PORT=3000 node scripts/vps-server.mjs        (Node 22.18 or later: the .ts modules below load as they are)
//   ENV_FILE=.env.local                          optional: NAME=value lines read into the environment (names already set win)
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { createHmac, randomUUID } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { cspHeader, embeddable, newNonce, securityHeaders } from '../src/lib/security/csp.ts';
import { ADMIN_AREA_HEADER, isAdminArea, viewAsRefusal, viewAsWriteRefused } from '../src/lib/security/view-as-guard.ts';
import { crossSiteRefusal, crossSiteWriteRefused, unusedFrameworkPath } from '../src/lib/security/request-guard.ts';
import { refreshSession } from '../src/lib/auth/edge-refresh.ts';
import { emailLinkCookie } from '../src/lib/track/shared.ts';
import { SCHEMA_HEADER, SCHEMA_MARKER } from '../src/lib/schema-marker.ts';
import { ORIGIN_WAIT_MS, STALE_HEADER, isProbe, staleKey, staleWorthy } from '../src/lib/edge/page-cache.ts';
import { checkPage, marketOf, marketStored, offMarketPlace, oldModelYear, oldYearGone, outOfMarket, placeRegionBit, scraperGuard, tooMany, vehiclePageYear } from '../src/lib/edge/scraper-guard.ts';
import { RATE_LIMITED_BOT, keptToScope, shield, shieldResponse } from '../src/lib/edge/bot-shield.ts';
import { jobsToRun, pushWaiting } from '../src/lib/edge/cron-gate.ts';
import { kickNow, notifyKick, tickPlan } from '../src/lib/edge/notify-kick.ts';
import { cronEnabled, jobsForTick } from '../src/lib/platform/cron-plan.ts';
import { INBOUND_PATH, MAX_INBOUND_BYTES, SIGNATURE_HEADER, inboundSecret, routeInbound, verifyInbound } from '../src/lib/platform/inbound-email.ts';
import { WindowLimiter, geoCookie, geoFromHeaders, keptCopies } from '../src/lib/platform/node-edge.ts';
import { replyMime } from '../src/features/auto-reply/faq.ts';

if (process.env.ENV_FILE) {
  for (const line of fs.readFileSync(process.env.ENV_FILE, 'utf8').split('\n')) {
    const m = /^([A-Z0-9_]+)=(.*)$/.exec(line.replace(/\s+#.*$/, '').trim());
    if (m && process.env[m[1]] === undefined) process.env[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2');
  }
}

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const PORT = Number(process.env.PORT || 3000);
const INNER = Number(process.env.INNER_PORT || PORT + 100);
const STANDALONE = process.env.NEXT_STANDALONE_DIR || path.join(WEB, '.next', 'standalone');
const env = { ...process.env, HOSTING_TARGET: 'node', INTERNAL_ORIGIN: process.env.INTERNAL_ORIGIN || `http://127.0.0.1:${INNER}` };
const log = (m) => console.log(`[web] ${m}`);

// ------------------------------------------------------------------ the app
const app = spawn(process.execPath, [path.join(STANDALONE, 'server.js')], { cwd: STANDALONE, stdio: 'inherit', env: { ...env, PORT: String(INNER), HOSTNAME: '127.0.0.1' } });
app.on('exit', (code) => { log(`the app stopped (${code}); stopping`); process.exit(code || 1); });
let ready = false;
async function waitReady() {
  for (let i = 0; i < 240 && !ready; i++) {
    try { const r = await fetch(`http://127.0.0.1:${INNER}/robots.txt`, { signal: AbortSignal.timeout(5000) }); await r.arrayBuffer(); ready = r.status < 500; } catch { /* starting */ }
    if (!ready) await new Promise((r) => setTimeout(r, 500));
  }
  log(ready ? `ready on :${PORT} (the app on 127.0.0.1:${INNER})` : 'the app did not answer in 2 minutes');
}

// ------------------------------------------------------------------ what the tick learns (the Worker keeps these in KV or D1)
const flags = { searchCore: false, cpuGuard: false, placeMarket: 0, vpageMinYear: 0 };

const secHeaders = () => Object.fromEntries(Object.entries(securityHeaders()).map(([k, v]) => [k.toLowerCase(), v]));
const supabaseOrigin = () => { try { const o = new URL(String(env.NEXT_PUBLIC_SUPABASE_URL)).origin; return o.endsWith('.supabase.co') ? [] : [o]; } catch { return []; } };

/** A web Response sent as it is (the refusals and 404s the modules above make). */
async function sendWeb(res, out) {
  const h = {};
  out.headers.forEach((v, k) => { if (k !== 'set-cookie') h[k] = v; });
  const cookies = out.headers.getSetCookie?.() ?? [];
  if (cookies.length) h['set-cookie'] = cookies;
  const body = Buffer.from(await out.arrayBuffer());
  h['content-length'] = String(body.length);
  res.writeHead(out.status, h); res.end(body);
}

// ------------------------------------------------------------------ the jobs
const jobSecret = typeof env.LINK_SIGNING_KEY === 'string' ? env.LINK_SIGNING_KEY : '';
const jobToken = jobSecret ? createHmac('sha256', jobSecret).update('carmacars-listing-worker-v1').digest('hex') : '';
const appUrl = (() => { try { return new URL(env.NEXT_PUBLIC_APP_URL ?? ''); } catch { return null; } })();
const running = new Set();
/** POSTs one of the app's protected job routes, straight to the app; a job still running is not started again. */
async function runJob(pathname, body) {
  if (!jobToken || running.has(pathname)) return;
  running.add(pathname);
  try {
    const r = await fetch(`http://127.0.0.1:${INNER}${pathname}`, { method: 'POST', body: body ?? undefined, signal: AbortSignal.timeout(280_000),
      headers: { authorization: `Bearer ${jobToken}`, 'content-type': 'application/json', ...(appUrl ? { 'x-forwarded-host': appUrl.host, 'x-forwarded-proto': appUrl.protocol.replace(':', '') } : {}) } });
    await r.arrayBuffer();
    if (r.status >= 500) log(`job ${pathname}: ${r.status}`);
  } catch (e) { log(`job ${pathname}: ${e instanceof Error ? e.message.slice(0, 120) : 'error'}`); } finally { running.delete(pathname); }
}
const background = { waitUntil: (p) => { Promise.resolve(p).catch(() => undefined); } };

// ------------------------------------------------------------------ inbound email (the free Email Worker's POST)
const inboundKey = jobSecret ? inboundSecret(jobSecret) : Promise.resolve('');
async function inbound(req, res, head) {
  const json = (status, o) => { res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', ...secHeaders() }); res.end(JSON.stringify(o)); };
  if (!jobToken) { req.resume(); return json(503, { ok: false }); }
  // the forwarder refuses a message above 1 MB; as text sent on, it can be up to three times that in bytes
  const chunks = []; let size = 0;
  for await (const c of req) { size += c.length; if (size > MAX_INBOUND_BYTES * 3 + 4096) { json(413, { ok: false }); req.destroy(); return; } chunks.push(c); }
  const raw = Buffer.concat(chunks).toString('utf8');
  const from = head('x-envelope-from') ?? '', to = head('x-envelope-to') ?? '';
  if (!(await verifyInbound(await inboundKey, head(SIGNATURE_HEADER), from, to, raw, Math.floor(Date.now() / 1000)))) return json(403, { ok: false });
  const post = async (pathname, m) => {
    const r = await fetch(`http://127.0.0.1:${INNER}${pathname}`, { method: 'POST', body: m.raw, signal: AbortSignal.timeout(120_000),
      headers: { authorization: `Bearer ${jobToken}`, 'content-type': 'message/rfc822', 'x-envelope-from': m.from, 'x-envelope-to': m.to,
        ...(appUrl ? { 'x-forwarded-host': appUrl.host, 'x-forwarded-proto': appUrl.protocol.replace(':', '') } : {}) } });
    return { status: r.status, json: await r.json().catch(() => null) };
  };
  const out = await routeInbound({ from, to, raw }, post).catch(() => ({ status: 502, reply: null }));
  // the automatic answer as a finished message: the forwarder sends it back with message.reply, from the address written to
  const reply_raw = out.reply ? replyMime({ from: to, to: from, subject: out.reply.subject, text: out.reply.text, inReplyTo: out.reply.in_reply_to,
    id: `${randomUUID()}@${to.split('@')[1] || 'in.carmacars.ca'}`, date: new Date() }) : null;
  if (out.status !== 200) log(`inbound email: ${out.status}`);
  return json(out.status, { ok: out.status === 200, reply_raw });
}

// ------------------------------------------------------------------ crawl pacing, the scraper guard, last good copies
const crawlLimiter = new WindowLimiter(60, 60_000);
const guardOn = env.SCRAPER_GUARD !== '0';
let copies = null;
if (env.KEPT_COPIES !== '0') {
  keptCopies(env.COPIES_DIR || path.join(os.tmpdir(), 'carmacars-copies')).then((c) => {
    copies = c;
    setInterval(() => { c.prune().then((n) => { if (n) log(`last good copies: ${n} removed`); }); }, 3_600_000).unref();
  }).catch((e) => log(`last good copies: off (${e instanceof Error ? e.message.slice(0, 120) : 'error'})`));
}

/** An HTML page sent with a fresh nonce on every <script> and the matching policy; never reused by the browser without
 *  asking first. `h` holds the response headers so far (lower case). */
function sendHtml(res, o) {
  const { method, status, h, raw, pathname, proto, cookieHeader, geo } = o;
  const nonce = newNonce();
  const body = Buffer.from(raw.toString('utf8').replace(/<script(?=[\s>])/g, `<script nonce="${nonce}"`));
  const framed = embeddable(pathname);
  h['cache-control'] = 'no-cache';
  h['content-security-policy'] = cspHeader(nonce, { turnstile: true, connectOrigins: supabaseOrigin(), frameAncestors: framed ? 'https:' : undefined, upgrade: proto === 'https' });
  h['content-length'] = String(body.length);
  // where the visitor is browsing from (country-region, e.g. CA-ON), for the cookie notice; not stored
  const g = geoCookie(geo, cookieHeader, proto === 'https');
  if (g) h['set-cookie'] = [...[].concat(h['set-cookie'] ?? []), g];
  res.writeHead(status, h); res.end(method === 'HEAD' ? undefined : body);
}

async function tick() {
  const plan = tickPlan(Date.now());
  if (!plan.full) { await kickNow(env, (p) => runJob(p)).catch(() => undefined); return; }
  const due = await jobsToRun(env);
  if (due.checked) {
    flags.cpuGuard = !!due.cpu_guard; flags.searchCore = !!due.search_core;
    if (due.place_market !== undefined) flags.placeMarket = marketStored(due.place_market);
    if (due.vpage_min_year !== undefined) flags.vpageMinYear = due.vpage_min_year;
  }
  const pushDue = await pushWaiting(env).catch(() => false);
  for (const j of jobsForTick(plan, due, pushDue)) void runJob(j.path, j.body);
}
function startCron() {
  if (!cronEnabled(env)) { log('cron: off (CRON_ENABLED is not 1): the job routes are not asked for from here'); return; }
  if (!jobToken) { log('cron: off (no LINK_SIGNING_KEY)'); return; }
  const next = () => setTimeout(() => { tick().catch(() => undefined); next(); }, 60_000 - (Date.now() % 60_000) + 250).unref();
  next();
  log('cron: on (every minute; the jobs on every fifth)');
}

// ------------------------------------------------------------------ requests
const HOP = new Set(['connection', 'keep-alive', 'transfer-encoding', 'upgrade', 'proxy-connection', 'te', 'trailer']);

async function handle(req, res) {
  const method = req.method || 'GET';
  // only Caddy reaches this port (it is not published): its X-Forwarded-Proto says how the visitor came
  const proto = String(req.headers['x-forwarded-proto'] || 'http').split(',')[0].trim() === 'https' ? 'https' : 'http';
  const host = String(req.headers.host || 'localhost');
  let url;
  try { url = new URL(req.url || '/', `${proto}://${host}`); } catch { res.writeHead(400, secHeaders()); res.end(); return; }
  const pathname = url.pathname;
  const head = (k) => { const v = req.headers[k]; return v === undefined ? null : Array.isArray(v) ? v.join(', ') : String(v); };

  if (pathname === '/healthz') {
    const body = JSON.stringify({ ok: ready, target: 'node', version: env.DEPLOY_VERSION || null, schema: SCHEMA_MARKER, cron: cronEnabled(env) });
    res.writeHead(ready ? 200 : 503, { 'content-type': 'application/json', 'cache-control': 'no-store', ...secHeaders() }); res.end(body); return;
  }
  if (isProbe(pathname) || unusedFrameworkPath(pathname)) {
    res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'public, max-age=3600', ...secHeaders() }); res.end('Not found'); req.resume(); return;
  }
  if (pathname === INBOUND_PATH && method === 'POST') return inbound(req, res, head);
  const ua = head('user-agent');
  if (method === 'GET' || method === 'HEAD') {
    if (placeRegionBit(pathname) !== null && offMarketPlace(pathname, marketOf(flags.placeMarket))) return sendWeb(res, outOfMarket(secHeaders()));
    if (vehiclePageYear(pathname) !== null && oldModelYear(pathname, flags.vpageMinYear)) return sendWeb(res, oldYearGone(secHeaders()));
  }
  const core = await keptToScope(ua, pathname, async () => flags.searchCore, async () => flags.cpuGuard);
  const sh = shield(method, url.toString(), ua, core);
  if (sh.kind !== 'pass') { req.resume(); return sendWeb(res, shieldResponse(sh, secHeaders())); }
  // Bytespider reads every page, paced: 60 a minute (the Worker's rate limiting binding, here one counter for the one server)
  if (ua && RATE_LIMITED_BOT.test(ua) && !crawlLimiter.take('bytespider', Date.now())) { req.resume(); return sendWeb(res, tooMany(60, secHeaders())); }
  const geo = geoFromHeaders(head);
  const htmlOut = (status, h, raw) => sendHtml(res, { method, status, h, raw, pathname, proto, cookieHeader: head('cookie'), geo });
  // the page's last good copy: only a public page asked for without a session (src/lib/edge/page-cache.ts staleKey), as a document
  const sKey = copies && method === 'GET' && head('rsc') !== '1' ? staleKey({ method, url: url.toString(), headers: { get: head } }) : null;
  const copyHeaders = (why) => { const h = { 'content-type': 'text/html; charset=utf-8', [STALE_HEADER]: why, ...secHeaders() }; if (embeddable(pathname)) delete h['x-frame-options']; h[SCHEMA_HEADER] = SCHEMA_MARKER; return h; };
  // an agent posing as a browser, on a long-tail page, with none of our cookies: the kept copy, else a tiny page that sets
  // a cookie and reloads; never a render (src/lib/edge/scraper-guard.ts; without Cloudflare's network data, the check only)
  if (guardOn && scraperGuard(method, pathname, undefined, ua, head('cookie'), head('rsc') === '1') === 'check') {
    req.resume();
    const c = sKey ? await copies.get(sKey) : null;
    if (c) return htmlOut(200, copyHeaders('guard'), c.body);
    return sendWeb(res, checkPage(secHeaders()));
  }
  if (crossSiteWriteRefused(method, url.toString(), head('origin'), head('sec-fetch-site'))) { req.resume(); return sendWeb(res, crossSiteRefusal(secHeaders())); }
  if (viewAsWriteRefused(method, pathname, head('cookie'))) { req.resume(); return sendWeb(res, viewAsRefusal(req.headers['next-action'] !== undefined, secHeaders())); }

  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) if (!HOP.has(k) && v !== undefined) headers[k] = v;
  headers['accept-encoding'] = 'identity';
  headers['x-forwarded-host'] = host; headers['x-forwarded-proto'] = proto;
  delete headers[ADMIN_AREA_HEADER];
  if (isAdminArea(pathname)) headers[ADMIN_AREA_HEADER] = '1';

  // the session refreshed here, where the response can set the cookie, before a page reads it (src/lib/auth/edge-refresh.ts)
  let setCookies = [];
  const sbUrl = env.NEXT_PUBLIC_SUPABASE_URL, sbKey = env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  if (sbUrl && sbKey && headers.cookie && !pathname.startsWith('/_next/static/')) {
    try {
      const r = await refreshSession(new Request(url, { headers: { cookie: String(headers.cookie) } }), { url: sbUrl, anonKey: sbKey });
      if (r) { setCookies = r.setCookies; const c = r.request.headers.get('cookie'); if (c) headers.cookie = c; else delete headers.cookie; }
    } catch { /* the app then reads the session as it came */ }
  }

  // the last good copy answers when the app is failing or slow; the app's own answer is then kept for the next visitor
  let answered = false;
  const serveCopy = async (why) => {
    if (answered || !sKey) return false;
    const c = await copies.get(sKey);
    if (!c || answered || res.headersSent) return false;
    answered = true;
    htmlOut(200, copyHeaders(why), c.body);
    return true;
  };
  const slow = sKey ? setTimeout(() => { serveCopy('slow').catch(() => undefined); }, ORIGIN_WAIT_MS) : null;
  const up = http.request({ host: '127.0.0.1', port: INNER, method, path: req.url, headers }, (r) => {
    if (slow) clearTimeout(slow);
    const status = r.statusCode || 502;
    const html = String(r.headers['content-type'] || '').includes('text/html');
    const worthy = () => sKey && html && staleWorthy(status, { get: (n) => { const v = r.headers[n]; return v === undefined ? null : Array.isArray(v) ? v.join(', ') : String(v); } });
    const collect = (done) => { const chunks = []; r.on('data', (c) => chunks.push(c)); r.on('error', () => done(null)); r.on('end', () => done(Buffer.concat(chunks))); };
    // the copy was already sent (the app was slow): its answer, when good, is the copy from now on
    if (answered) { collect((raw) => { if (raw && worthy()) copies.put(sKey, raw); }); return; }
    const h = {};
    for (const [k, v] of Object.entries(r.headers)) if (!HOP.has(k) && v !== undefined) h[k] = v;
    Object.assign(h, secHeaders());
    if (embeddable(pathname)) delete h['x-frame-options'];
    h[SCHEMA_HEADER] = SCHEMA_MARKER;
    const cookies = [...[].concat(r.headers['set-cookie'] ?? []), ...setCookies];
    if (method === 'GET' && pathname.startsWith('/account/bookings/')) { const m = emailLinkCookie(url.toString(), proto === 'https'); if (m) cookies.push(m); }
    if (cookies.length) h['set-cookie'] = cookies;
    if (method === 'POST' && status < 500 && jobToken) notifyKick(pathname, env, background, (p) => runJob(p));
    const asIs = (raw) => { if (answered || res.headersSent) return; answered = true; h['content-length'] = String(raw.length); res.writeHead(status, h); res.end(method === 'HEAD' ? undefined : raw); };
    // a failed render of a public page: its last good copy when there is one, else the app's own answer
    if (sKey && status >= 500) {
      collect((raw) => {
        const own = () => { if (answered || res.headersSent) return; if (raw && html) { answered = true; htmlOut(status, h, raw); } else asIs(raw ?? Buffer.alloc(0)); };
        serveCopy('error').then((ok) => { if (!ok) own(); }, own);
      });
      return;
    }
    if (!html) { answered = true; res.writeHead(status, h); r.pipe(res); return; }
    collect((raw) => {
      if (raw && worthy()) copies.put(sKey, raw);
      if (answered || res.headersSent) return;
      answered = true;
      if (!raw) { res.writeHead(502, secHeaders()); res.end(); return; }
      htmlOut(status, h, raw);
    });
  });
  up.on('error', () => {
    if (slow) clearTimeout(slow);
    const starting = () => {
      if (answered || res.headersSent) return;
      answered = true;
      res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store', 'retry-after': '5', ...secHeaders() });
      res.end('Starting');
    };
    serveCopy('error').then((ok) => { if (!ok) starting(); }, starting);
  });
  req.pipe(up);
}

const server = http.createServer((req, res) => {
  handle(req, res).catch(() => { if (!res.headersSent) res.writeHead(500, secHeaders()); res.end(); });
});
server.listen(PORT, () => { waitReady().then(startCron); });
for (const sig of ['SIGTERM', 'SIGINT']) process.on(sig, () => { app.removeAllListeners('exit'); app.kill('SIGTERM'); server.close(() => process.exit(0)); setTimeout(() => process.exit(0), 10_000).unref(); });
