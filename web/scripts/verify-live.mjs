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
// --auth: real sign-ins through the live form with one test account per portal (a renter, an owner, an
// investor, a customer service assistant, a field staff member; never an Admin). The accounts are created or
// their passwords reset through the Supabase admin API on each run, any authenticator app left from an earlier
// run is removed, and public.server_verify_accounts gives each its role and puts its address on the email
// suppression list (no email is ever sent to them). Each home must load without errors, and each account must
// be refused the other portals. Needs SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.
const ACCOUNTS = [
  { role: 'renter', email: 'verify-signin@carmacars.ca', name: 'Sign-in Check', home: '/account', width: 390 },
  { role: 'owner', email: 'verify-owner@carmacars.ca', name: 'Verify Owner', home: '/owner', width: 1440 },
  { role: 'investor', email: 'verify-investor@carmacars.ca', name: 'Verify Investor', home: '/investor', width: 390 },
  { role: 'va_cs', email: 'verify-va-cs@carmacars.ca', name: 'Verify Assistant', home: '/va', width: 1440 },
  { role: 'field', email: 'verify-field@carmacars.ca', name: 'Verify Field', home: '/field', width: 390 }
];
const PORTALS = ['/admin', '/owner', '/investor', '/va', '/field'];
// RFC 6238, as an authenticator app computes it (only when staff two-step sign-in is switched on)
async function totp(secret) {
  const { createHmac } = await import('node:crypto');
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = '';
  for (const c of secret.replace(/=+$/, '')) bits += A.indexOf(c).toString(2).padStart(5, '0');
  const key = Buffer.from(bits.match(/.{8}/g).map((x) => parseInt(x, 2)));
  const ctr = Buffer.alloc(8); ctr.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30_000)));
  const h = createHmac('sha1', key).update(ctr).digest(); const o = h[h.length - 1] & 0xf;
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1_000_000).padStart(6, '0');
}
const noise = (t) => /cdn-cgi\/(rum|challenge)|favicon/.test(t);
if (process.argv.includes('--auth')) {
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const h = { apikey: key, Authorization: `Bearer ${key}`, 'content-type': 'application/json' };
  report.portals = [];
  try {
    const list = await (await fetch(`${url}/auth/v1/admin/users?per_page=1000`, { headers: h })).json();
    for (const a of ACCOUNTS) {
      a.password = `V${Math.random().toString(36).slice(2)}${Date.now()}!`;
      let user = (list.users ?? []).find((u) => u.email === a.email);
      if (!user) {
        user = await (await fetch(`${url}/auth/v1/admin/users`, { method: 'POST', headers: h, body: JSON.stringify({ email: a.email, password: a.password, email_confirm: true, user_metadata: { full_name: a.name } }) })).json();
        a.step = 'created';
      } else {
        await fetch(`${url}/auth/v1/admin/users/${user.id}`, { method: 'PUT', headers: h, body: JSON.stringify({ password: a.password, email_confirm: true }) });
        a.step = 'password reset';
        for (const f of (user.factors ?? [])) await fetch(`${url}/auth/v1/admin/users/${user.id}/factors/${f.id}`, { method: 'DELETE', headers: h });
      }
      if (!user?.id) throw new Error(`could not create ${a.email}: ${JSON.stringify(user).slice(0, 200)}`);
      a.id = user.id;
    }
    const reg = await fetch(`${url}/rest/v1/rpc/server_verify_accounts`, { method: 'POST', headers: h,
      body: JSON.stringify({ p: ACCOUNTS.map((a) => ({ user_id: a.id, email: a.email, role: a.role, name: a.name })) }) });
    const regBody = await reg.text();
    report.accounts = { status: reg.status, body: reg.ok ? JSON.parse(regBody).map((x) => `${x.role}:${x.roles?.va ?? ''}${x.roles?.owner ? 'owner' : ''}${x.roles?.investor ? 'investor' : ''}${x.roles?.field ? 'field' : ''}${x.roles?.admin ? 'ADMIN' : ''}`) : regBody.slice(0, 300) };
    if (!reg.ok) throw new Error(`server_verify_accounts ${reg.status}: ${regBody.slice(0, 300)}`);
    for (const a of ACCOUNTS) {
      const r = { role: a.role, home: a.home, steps: [a.step], errors: [], refused: {} };
      const ctx = await browser.newContext({ viewport: { width: a.width, height: 844 } });
      const page = await ctx.newPage();
      page.on('pageerror', (e) => r.errors.push(String(e).slice(0, 300)));
      page.on('console', (m) => { if (m.type() === 'error' && !noise(m.text())) r.errors.push(m.text().slice(0, 300)); });
      try {
        await page.goto(`${BASE}/sign-in`, { waitUntil: 'networkidle' });
        const cookie = page.getByRole('button', { name: 'Necessary only' }).first();
        if (await cookie.isVisible().catch(() => false)) await cookie.click();
        await page.locator('#si-email').fill(a.email);
        await page.locator('#si-pass').fill(a.password);
        await page.getByRole('button', { name: 'Sign in', exact: true }).click();
        await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 30_000 });
        if (new URL(page.url()).pathname.startsWith('/two-step/setup')) {
          // staff two-step sign-in is on: enrol an authenticator for this run, as a person would
          await page.getByTestId('totp-start').click();
          const secret = (await page.getByTestId('totp-secret').textContent({ timeout: 15_000 }))?.trim() ?? '';
          await page.getByTestId('totp-code').fill(await totp(secret));
          await page.getByTestId('totp-submit').click();
          await page.waitForURL((u) => !u.pathname.startsWith('/two-step'), { timeout: 30_000 });
          r.steps.push('two-step enrolled');
        }
        await page.waitForURL((u) => u.pathname.startsWith(a.home), { timeout: 30_000 }).catch(() => {});
        await page.waitForLoadState('networkidle');
        r.afterSignIn = page.url();
        r.h1 = await page.locator('h1').first().textContent({ timeout: 5_000 }).catch(() => null);
        r.broken = /couldn.t load|Application error|Something went wrong/i.test(await page.locator('body').innerText().catch(() => ''));
        await page.screenshot({ path: path.join(out, `portal-${a.role}.png`), fullPage: true });
        for (const p of PORTALS.filter((x) => x !== a.home)) {
          const resp = await page.goto(`${BASE}${p}`, { waitUntil: 'networkidle' });
          const fin = new URL(page.url()).pathname;
          // refused: sent to the portal's no-access page (or "not an owner"), never shown the portal's home
          r.refused[p] = fin !== p && (/no-access|not-an-owner/.test(fin) || fin.startsWith('/sign-in')) ? fin : `SHOWN ${fin} ${resp?.status()}`;
        }
        r.ok = new URL(r.afterSignIn).pathname.startsWith(a.home) && !!r.h1 && !r.broken && r.errors.length === 0 && Object.values(r.refused).every((v) => !String(v).startsWith('SHOWN'));
      } catch (e) {
        r.ok = false; r.error = String(e).slice(0, 500);
        await page.screenshot({ path: path.join(out, `portal-${a.role}-failed.png`), fullPage: true }).catch(() => {});
      }
      report.portals.push(r);
      await ctx.close();
    }
    const renter = report.portals.find((x) => x.role === 'renter');
    report.auth = { ok: !!renter?.ok, steps: renter?.steps, afterSignIn: renter?.afterSignIn, adminForRenter: renter?.refused?.['/admin'], errors: renter?.errors ?? [] };
  } catch (e) {
    report.auth = { ok: false, error: String(e).slice(0, 800) };
  }
  report.portals_ok = report.portals.length === ACCOUNTS.length && report.portals.every((x) => x.ok);
  if (!report.portals_ok) process.exitCode = 1;
}

await browser.close();
fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
