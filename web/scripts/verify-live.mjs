// Checks the live site from a browser (the verify workflow): pages, status codes, security headers and
// the nonce, /admin behind sign-in, console errors, phone and desktop screenshots, and (with
// --request) one request to book through the real form, as delivered@resend.dev (Resend's test inbox).
//   BASE_URL=https://carmacars.ca node scripts/verify-live.mjs --out /tmp/verify [--request]
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from '@playwright/test';

const BASE = (process.env.BASE_URL ?? 'https://carmacars.ca').replace(/\/$/, '');
const out = process.argv[process.argv.indexOf('--out') + 1] ?? '/tmp/verify';
const doRequest = process.argv.includes('--request');
fs.mkdirSync(out, { recursive: true });
const report = { base: BASE, at: new Date().toISOString(), pages: [], headers: {}, nonce: null, admin: null, console: [], request: null, shots: [] };

const PAGES = ['/', '/cars', '/how-it-works', '/requirements', '/delivery', '/faq', '/contact', '/terms', '/privacy', '/cancellation-policy',
  '/list-your-car', '/investors', '/sign-in', '/create-account', '/reset-password', '/robots.txt', '/sitemap.xml', '/no-such-page'];

const r0 = await fetch(BASE + '/', { redirect: 'manual' });
for (const h of ['content-security-policy', 'strict-transport-security', 'x-frame-options', 'x-content-type-options', 'referrer-policy', 'permissions-policy', 'cross-origin-opener-policy', 'cache-control', 'server'])
  report.headers[h] = r0.headers.get(h);
const html = await r0.text();
const nonce = /'nonce-([^']+)'/.exec(report.headers['content-security-policy'] ?? '')?.[1];
const scripts = [...html.matchAll(/<script\b[^>]*>/g)].map((m) => m[0]);
report.nonce = { inPolicy: Boolean(nonce), scripts: scripts.length, withNonce: scripts.filter((s) => nonce && s.includes(`nonce="${nonce}"`)).length };
const slug = process.env.SLUG || (/\/cars\/([a-z0-9]+(?:-[a-z0-9]+)+)/.exec(await (await fetch(BASE + '/cars')).text())?.[1] ?? null);
if (slug) PAGES.splice(2, 0, `/cars/${slug}`);
for (const p of PAGES) {
  const t = Date.now();
  const r = await fetch(BASE + p, { redirect: 'manual' });
  const body = await r.text();
  report.pages.push({ path: p, status: r.status, ms: Date.now() - t, title: /<title>([^<]*)<\/title>/.exec(body)?.[1] ?? null, location: r.headers.get('location') });
}

const browser = await chromium.launch();
for (const [name, viewport] of [['phone-375', { width: 375, height: 812 }], ['desktop-1440', { width: 1440, height: 900 }]]) {
  const ctx = await browser.newContext({ viewport });
  const page = await ctx.newPage();
  page.on('console', (m) => { if (m.type() === 'error') report.console.push({ viewport: name, url: page.url(), text: m.text().slice(0, 300) }); });
  page.on('pageerror', (e) => report.console.push({ viewport: name, url: page.url(), text: 'pageerror: ' + String(e).slice(0, 300) }));
  page.on('requestfailed', (r) => report.console.push({ viewport: name, url: page.url(), text: `requestfailed: ${r.url().slice(0, 150)} ${r.failure()?.errorText}` }));
  for (const p of ['/', '/cars', ...(slug ? [`/cars/${slug}`] : []), '/terms', '/sign-in']) {
    await page.goto(BASE + p, { waitUntil: 'networkidle' });
    const file = `${name}${p === '/' ? '-home' : p.replace(/\//g, '-')}.png`;
    await page.screenshot({ path: path.join(out, file), fullPage: p !== '/terms' });
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1);
    report.shots.push({ viewport: name, path: p, file, overflow, h1: await page.locator('h1').first().textContent().catch(() => null) });
  }
  if (name === 'desktop-1440') {
    await page.goto(BASE + '/admin', { waitUntil: 'networkidle' });
    report.admin = { finalUrl: page.url(), h1: await page.locator('h1').first().textContent().catch(() => null) };
  }
  await ctx.close();
}

if (doRequest && slug) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 } });
  const page = await ctx.newPage();
  const errs = [];
  page.on('pageerror', (e) => errs.push(String(e).slice(0, 300)));
  try {
    const d = new Date(); d.setUTCDate(d.getUTCDate() + 75); const from = d.toISOString().slice(0, 10);
    d.setUTCDate(d.getUTCDate() + 3); const to = d.toISOString().slice(0, 10);
    await page.goto(`${BASE}/book/${slug}?from=${from}&to=${to}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
    const cookie = page.getByRole('button', { name: 'Necessary only' }).first();
    if (await cookie.isVisible().catch(() => false)) await cookie.click();
    await page.getByRole('button', { name: 'Continue to driver details' }).click();
    await page.locator('#rq-first').fill('Verify');
    await page.locator('#rq-last').fill('Deploy');
    await page.locator('#rq-email').fill('delivered@resend.dev');
    await page.locator('#rq-phone').fill('647-555-0142');
    await page.locator('#rq-dobm').selectOption('4');
    await page.locator('#rq-dobd').fill('9');
    await page.locator('#rq-doby').fill('1990');
    await page.getByRole('button', { name: 'Continue to licence' }).click();
    await page.locator('label', { hasText: 'Ontario G2' }).click();
    await page.locator('label.option', { hasText: 'Option 2' }).click();
    await page.locator('#rq-notes').fill('Deploy verification request: please ignore, it will be removed.');
    await page.getByRole('button', { name: 'Review request' }).click();
    await page.locator('input[name="agree"]').check();
    await page.getByRole('button', { name: 'Send request' }).click();
    await page.waitForURL(/\/book\/sent\//, { timeout: 45_000 });
    report.request = { ok: true, number: decodeURIComponent(page.url().split('/').pop()), slug, from, to, errors: errs };
    await page.screenshot({ path: path.join(out, 'request-sent.png'), fullPage: true });
  } catch (e) {
    await page.screenshot({ path: path.join(out, 'request-failed.png'), fullPage: true }).catch(() => {});
    report.request = { ok: false, error: String(e).slice(0, 800), url: page.url(), errors: errs };
  }
  await ctx.close();
}
await browser.close();
fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
