// Search Console's sitemaps for the property, and a crawl warm-up (0124; the gsc workflow, .github/workflows/gsc.yml).
//
//   node --experimental-strip-types web/scripts/gsc.mjs
//
// Environment: AT (an OAuth access token for the Search Console API), SITE (the property: sc-domain:carmacars.ca),
// BASE (https://carmacars.ca), MODE (submit: every planned file again; missing: only what the property lacks, the
// errored ones again; report: change nothing), MAX (sitemaps the property may hold, 500), SCAN (place and vehicle files
// looked at, at most), WARM (priority addresses fetched once, 0 for none), OUT (a JSON file for app.gsc_sitemap_log),
// GITHUB_STEP_SUMMARY. The plan is src/features/seo/gsc-plan.ts. Never prints the token.
import fs from 'node:fs';
import { gscRow, locsOf, planSitemaps } from '../src/features/seo/gsc-plan.ts';

const AT = process.env.AT ?? '';
const SITE = process.env.SITE ?? '';
const BASE = (process.env.BASE ?? 'https://carmacars.ca').replace(/\/$/, '');
const MODE = process.env.MODE ?? 'missing';
const MAX = Number(process.env.MAX ?? 500);
const SCAN = Number(process.env.SCAN ?? 1500);
const WARM = Number(process.env.WARM ?? 0);
const UA = 'CarmaCars crawl check (gsc workflow)';
const notice = (title, msg) => console.log(`::notice title=${title}::${msg}`);
const warn = (title, msg) => console.log(`::warning title=${title}::${msg}`);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** GET with up to 3 tries on 503 (its Retry-After, at most 30 s) or a network error; the status, text and time. */
async function get(url) {
  for (let i = 0; ; i++) {
    const t0 = Date.now();
    try {
      const r = await fetch(url, { headers: { 'user-agent': UA }, redirect: 'manual', signal: AbortSignal.timeout(60_000) });
      const text = await r.text();
      if (r.status === 503 && i < 2) { await sleep(Math.min(30, Number(r.headers.get('retry-after')) || 5) * 1000); continue; }
      return { status: r.status, text, ms: Date.now() - t0, edge: r.headers.get('x-edge-cache') ?? r.headers.get('cf-cache-status') ?? '' };
    } catch (e) {
      if (i < 2) { await sleep(3000); continue; }
      return { status: 0, text: '', ms: Date.now() - t0, edge: '', error: String(e) };
    }
  }
}
/** fn over items, n at a time, until stop() says enough; results in order (undefined for those not reached). */
async function pool(items, n, fn, stop = () => false) {
  const out = new Array(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: n }, async () => {
    while (next < items.length && !stop()) { const i = next++; out[i] = await fn(items[i], i); }
  }));
  return out;
}
const gsc = (method, path) => fetch(`https://www.googleapis.com/webmasters/v3/sites/${encodeURIComponent(SITE)}/sitemaps${path ? '/' + encodeURIComponent(path) : ''}`,
  { method, headers: { authorization: `Bearer ${AT}` } });
async function listSitemaps() {
  const r = await gsc('GET');
  if (!r.ok) throw new Error(`Search Console list: ${r.status} ${(await r.text()).slice(0, 200)}`);
  return (await r.json()).sitemap ?? [];
}
const pct = (a, p) => (a.length ? [...a].sort((x, y) => x - y)[Math.min(a.length - 1, Math.floor(a.length * p))] : 0);
const summary = [];

// 1. the root index and its children
const idx = await get(`${BASE}/sitemap.xml`);
if (idx.status !== 200 || !/<sitemapindex/.test(idx.text)) throw new Error(`/sitemap.xml answered ${idx.status}`);
const children = locsOf(idx.text);
const nested = children.filter((c) => !/^\/sitemap-[a-z0-9.-]+\.xml$/.test(new URL(c).pathname));
if (nested.length) warn('gsc', `${nested.length} children of /sitemap.xml are not at the site's root (first: ${nested[0]}): Google ignores them`);
const isHead = (u) => /^\/sitemap-(priority-\d+|[a-z]+)\.xml$/.test(new URL(u).pathname);
const head = [`${BASE}/sitemap.xml`, ...children.filter(isHead)];
const rest = children.filter((u) => !isHead(u));
notice('gsc index', `/sitemap.xml lists ${children.length} files: ${head.length - 1} priority and site files, ${rest.length} place and vehicle files (${idx.ms} ms)`);

// 2. the place and vehicle files with addresses, in order (each fetch also leaves the file at the edge for Googlebot)
const current = MODE === 'report' && !WARM ? [] : await listSitemaps();
const room = Math.max(0, MAX - head.length);
const files = [];
const probe = { n: 0, empty: 0, bad: 0, ms: [] };
if (MODE !== 'report') {
  let found = 0;
  const res = await pool(rest.slice(0, SCAN), 6, async (u) => {
    const r = await get(u);
    probe.n++; probe.ms.push(r.ms);
    const n = r.status === 200 ? (r.text.match(/<url>/g) ?? []).length : -1;
    if (n < 0) probe.bad++; else if (n === 0) probe.empty++; else found++;
    return n;
  }, () => found >= room);
  res.forEach((n, i) => { if (n > 0) files.push(rest[i]); });
  notice('gsc files', `looked at ${probe.n} place and vehicle files: ${files.length} with addresses, ${probe.empty} empty, ${probe.bad} not 200; p50 ${pct(probe.ms, 0.5)} ms, p95 ${pct(probe.ms, 0.95)} ms`);
}

// 3. the plan, applied
if (MODE !== 'report') {
  const plan = planSitemaps({ base: BASE, head, files, current, max: MAX, all: MODE === 'submit' });
  let removed = 0, submitted = 0, retried = 0, failed = 0;
  for (const p of plan.remove) { const r = await gsc('DELETE', p); if (r.ok) removed++; else { failed++; console.log(`remove ${p} -> ${r.status}`); } await sleep(150); }
  for (const p of plan.submit) { const r = await gsc('PUT', p); if (r.ok) submitted++; else { failed++; console.log(`submit ${p} -> ${r.status}`); } await sleep(200); }
  // Google's first fetch of a batch can fail while it fetches many at once: the errored ones again, a few seconds apart
  for (const p of plan.retry) { const r = await gsc('PUT', p); if (r.ok) retried++; await sleep(3000); }
  notice('gsc submitted', `${plan.desired.length} sitemaps planned (limit ${MAX}): ${submitted} submitted, ${retried} with errors resubmitted, ${removed} old ones removed, ${failed} failed`);
}

// 4. the figures per file
if (AT && SITE) {
  const list = await listSitemaps();
  const rows = list.map(gscRow);
  if (process.env.OUT) fs.writeFileSync(process.env.OUT, JSON.stringify(rows));
  const discovered = rows.reduce((a, r) => a + (r.submitted ?? 0), 0);
  const errs = rows.filter((r) => (r.errors ?? 0) > 0).length;
  const pending = rows.filter((r) => r.is_pending).length;
  const zero = rows.filter((r) => !r.is_pending && r.last_downloaded && !r.submitted).length;
  notice('gsc status', `${rows.length} sitemaps in Search Console: ${discovered.toLocaleString('en-CA')} addresses discovered, ${errs} with errors, ${pending} pending, ${zero} read with 0 addresses`);
  summary.push('## Search Console sitemaps', '', `${rows.length} sitemaps, ${discovered.toLocaleString('en-CA')} addresses discovered, ${errs} with errors, ${pending} pending.`, '',
    '| Sitemap | Discovered | Errors | Pending | Last read |', '|---|---:|---:|---|---|',
    ...rows.sort((a, b) => (b.submitted ?? 0) - (a.submitted ?? 0)).slice(0, 200)
      .map((r) => `| ${r.path.replace(BASE, '')} | ${r.submitted ?? ''} | ${r.errors ?? ''} | ${r.is_pending ? 'yes' : ''} | ${r.last_downloaded ?? 'never'} |`), '');
}

// 5. the warm-up: the first priority addresses, once each (the edge and the database's caches), 4 at a time
if (WARM > 0) {
  const parts = children.filter((u) => /\/sitemap-priority-\d+\.xml$/.test(u));
  const urls = [];
  for (const p of parts) { if (urls.length >= WARM) break; urls.push(...locsOf((await get(p)).text)); }
  const pick = [...new Set([`${BASE}/`, `${BASE}/robots.txt`, ...urls])].slice(0, WARM);
  const res = await pool(pick, 4, async (u) => { const r = await get(u); return { s: r.status, ms: r.ms }; });
  const by = {};
  for (const r of res) by[r.s] = (by[r.s] ?? 0) + 1;
  const ms = res.map((r) => r.ms);
  const bad = res.filter((r) => r.s >= 500 || r.s === 0).length;
  (bad ? warn : notice)('crawl warm-up', `${pick.length} priority addresses: ${Object.entries(by).map(([k, v]) => `${v} x ${k}`).join(', ')}; p50 ${pct(ms, 0.5)} ms, p95 ${pct(ms, 0.95)} ms, slowest ${Math.max(0, ...ms)} ms`);
  summary.push('## Warm-up', '', `${pick.length} priority addresses: ${Object.entries(by).map(([k, v]) => `${v} answered ${k}`).join(', ')}. p50 ${pct(ms, 0.5)} ms, p95 ${pct(ms, 0.95)} ms.`, '');
}
if (process.env.GITHUB_STEP_SUMMARY && summary.length) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary.join('\n') + '\n');
