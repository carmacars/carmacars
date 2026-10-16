#!/usr/bin/env node
// The guides' stored PDFs (migration 0044), through the site's job endpoints with the jobs' bearer token (derived from
// LINK_SIGNING_KEY, like the listing worker's), so it works the same for every storage provider:
//
//   node scripts/guides-pdf.mjs --base https://carmacars.ca --committed
//        uploads the committed PDFs of docs/guides/pdf (the October 2026 edition) for every guide that has none stored
//   node scripts/guides-pdf.mjs --base https://carmacars.ca [--portals owner,renter] [--out dir]
//        prints each published guide from the database (the same HTML the portal shows, in the print layout of
//        src/styles/guide.css) with Playwright Chromium and stores it as the guide's PDF, with its version and date
//
// LINK_SIGNING_KEY comes from the environment (the workflow reads it from the Supabase vault) or, on the local stack,
// from web/.env.local. Run by .github/workflows/guides-pdf.yml and by the deploy (committed, only where missing).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHmac } from 'node:crypto';
import { fileURLToPath, pathToFileURL } from 'node:url';

const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ROOT = path.resolve(WEB, '..');
const arg = (k, d = null) => { const i = process.argv.indexOf(k); return i > 0 ? process.argv[i + 1] : d; };
const has = (k) => process.argv.includes(k);
const BASE = (arg('--base') ?? process.env.BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');
const PORTALS = (arg('--portals') ?? 'renter,owner,admin,va,field,investor').split(',').map((x) => x.trim()).filter(Boolean);
const OUT = arg('--out');
const FILES = { renter: 'Renter', owner: 'Owner', admin: 'Admin', va: 'VA', field: 'Field', investor: 'Investor' };

function linkKey() {
  if (process.env.LINK_SIGNING_KEY) return process.env.LINK_SIGNING_KEY;
  const env = path.join(WEB, '.env.local');
  if (fs.existsSync(env)) {
    const m = /^LINK_SIGNING_KEY=(.*)$/m.exec(fs.readFileSync(env, 'utf8'));
    if (m) return m[1].trim().replace(/^["']|["']$/g, '');
  }
  throw new Error('LINK_SIGNING_KEY is not set');
}
const TOKEN = createHmac('sha256', linkKey()).update('carmacars-listing-worker-v1').digest('hex');
const H = { authorization: `Bearer ${TOKEN}` };

async function post(portal, bytes, q) {
  const qs = new URLSearchParams({ portal, ...q }).toString();
  for (let attempt = 1; attempt <= 3; attempt++) {
    const r = await fetch(`${BASE}/api/jobs/guide-pdf?${qs}`, { method: 'POST', headers: { ...H, 'content-type': 'application/pdf' }, body: bytes });
    const text = await r.text();
    if (r.ok) return JSON.parse(text);
    if (attempt === 3 || r.status < 500) throw new Error(`${portal}: ${r.status} ${text.slice(0, 200)}`);
    await new Promise((res) => setTimeout(res, 2000 * attempt));
  }
}

async function committed() {
  const report = [];
  for (const p of PORTALS) {
    const f = path.join(ROOT, 'docs/guides/pdf', `CarmaCars-${FILES[p]}-Guide.pdf`);
    if (!fs.existsSync(f)) { report.push(`${p}: no committed PDF`); continue; }
    const stat = fs.statSync(f);
    const r = await post(p, fs.readFileSync(f), { source: 'committed', generated_at: '2026-10-15T04:24:00Z' });
    report.push(`${p}: ${r.skipped ? 'a PDF is already stored' : `stored ${(stat.size / 1e6).toFixed(1)} MB`}`);
  }
  return report;
}

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const day = (iso) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', month: 'long', day: 'numeric', year: 'numeric' }).format(new Date(iso));

// The print document: the same blocks as the portal's guide page (src/features/guides/GuideView.tsx) in its print layout.
function documentHtml(g) {
  const css = ['tokens.css', 'core.css', 'guide.css'].map((f) => fs.readFileSync(path.join(WEB, 'src/styles', f), 'utf8')).join('\n');
  const font = (w, f) => `@font-face{font-family:'Inter Guide';src:url('${pathToFileURL(path.join(WEB, 'src/fonts', f)).href}') format('woff2');font-weight:${w};}`;
  const fonts = [font(400, 'inter-400.woff2'), font(500, 'inter-500.woff2'), font('600 700', 'inter-600.woff2'), font(800, 'inter-display-800.woff2')].join('');
  let n = 0;
  const secs = g.sections.map((s) => ({ ...s, num: s.kind === 'chapter' ? ++n : null }));
  const toc = secs.map((s) => `<li><a href="#${esc(s.slug)}"><span class="gd-tn">${s.num ? String(s.num).padStart(2, '0') : '&rarr;'}</span><b>${esc(s.title)}</b></a></li>`).join('');
  const body = secs.map((s) => `<section id="${esc(s.slug)}" class="gd-sec gd-sec--${esc(s.kind)}"><header class="gd-sec-head">${s.num ? `<div class="gd-sec-num">${String(s.num).padStart(2, '0')}</div>` : ''}<div><p class="gd-sec-kicker">${s.num ? `Chapter ${s.num}` : s.kind === 'start' ? 'Before you begin' : 'Keep this page handy'}</p><h2 class="gd-sec-title">${esc(s.title)}</h2></div></header>`
    + (s.kind === 'start' ? `<div class="gd-signin"><span>Sign in at</span><b>${esc(g.signin_url)}</b>${g.lands_on ? `<small>You land on ${esc(g.lands_on)}.</small>` : ''}</div>` : '')
    + `<div class="gd-content">${s.html}</div>`
    + (s.kind === 'reference' ? `<div class="gd-contact"><h3>Talk to us</h3><dl>${g.contact?.email ? `<div><dt>Email</dt><dd>${esc(g.contact.email)}</dd></div>` : ''}${g.contact?.phone ? `<div><dt>Phone</dt><dd>${esc(g.contact.phone)}</dd></div>` : ''}</dl><p>Tell us your name, the booking or car, and what you see on the screen.</p></div>` : '')
    + '</section>').join('');
  const site = String(g.contact?.site ?? 'https://carmacars.ca').replace(/^https?:\/\//, '');
  return `<!doctype html><html lang="en-CA"><head><meta charset="utf-8"><base href="${esc(BASE)}/"><title>CarmaCars ${esc(g.title)}</title>
<style>${fonts}:root{--ff-text:'Inter Guide';--ff-display:'Inter Guide';}body{margin:0;font-family:var(--font-text);}${css}</style></head>
<body><article class="gd"><div class="gd-cover"><div class="gd-wm">Carma<b>Cars</b></div><div><p class="gd-kicker">User guide</p><h1>${esc(g.title)}</h1><div class="gd-rule"></div>${g.promise ? `<p>${esc(g.promise)}</p>` : ''}</div><small>${esc(site)} · Edition of ${esc(day(g.published_at))}</small></div>
<details class="gd-toc" open><summary>Contents</summary><nav><ol>${toc}</ol></nav></details><div class="gd-body">${body}</div></article></body></html>`;
}

async function printed() {
  const { chromium } = await import('@playwright/test');
  if (!process.env.PLAYWRIGHT_BROWSERS_PATH && fs.existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
  const browser = await chromium.launch();
  const report = [];
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'guides-pdf-'));
  try {
    for (const p of PORTALS) {
      const r = await fetch(`${BASE}/api/jobs/guide-content?portal=${p}`, { headers: H });
      if (!r.ok) throw new Error(`${p}: content ${r.status} ${(await r.text()).slice(0, 200)}`);
      const g = await r.json();
      if (!g.version || !g.sections?.length) { report.push(`${p}: not published, skipped`); continue; }
      const file = path.join(tmp, `${p}.html`);
      fs.writeFileSync(file, documentHtml(g));
      const page = await browser.newPage();
      await page.goto(pathToFileURL(file).href, { waitUntil: 'networkidle', timeout: 120_000 });
      await page.evaluate(() => document.fonts.ready);
      await page.emulateMedia({ media: 'print' });
      const footer = `<style>.f{font-family:Helvetica,Arial,sans-serif;font-size:7.5pt;color:#5E5E5E;width:7.2in;margin:0 auto;padding-top:7pt;border-top:0.75pt solid #E2E2E2;display:flex;justify-content:space-between;-webkit-print-color-adjust:exact}.f b{color:#000}.f b i{font-style:normal;color:#D0111B}</style><div class="f"><span><b>Carma<i>Cars</i></b>&nbsp;&nbsp;|&nbsp;&nbsp;${esc(g.title)}, version ${g.version}</span><span class="pageNumber"></span></div>`;
      const pdf = await page.pdf({ format: 'Letter', printBackground: true, preferCSSPageSize: true, outline: true, tagged: true, displayHeaderFooter: true,
        headerTemplate: '<span></span>', footerTemplate: footer, margin: { top: '0.6in', right: '0.65in', bottom: '0.75in', left: '0.65in' } });
      await page.close();
      const pages = (pdf.toString('latin1').match(/\/Type\s*\/Page[^s]/g) ?? []).length || null;
      if (OUT) { fs.mkdirSync(OUT, { recursive: true }); fs.writeFileSync(path.join(OUT, `CarmaCars-${FILES[p]}-Guide-v${g.version}.pdf`), pdf); }
      const res = await post(p, pdf, { source: 'generated', version: String(g.version), pages: String(pages ?? '') });
      report.push(`${p}: version ${g.version}, ${pages ?? '?'} pages, ${(pdf.length / 1e6).toFixed(1)} MB, stored as ${res.path}`);
    }
  } finally {
    await browser.close();
    fs.rmSync(tmp, { recursive: true, force: true });
  }
  return report;
}

const report = has('--committed') ? await committed() : await printed();
for (const line of report) console.log(line);
