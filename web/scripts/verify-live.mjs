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

// The statement emails job (the Worker's hourly cron, POST /api/jobs/statements with the listing worker's token):
// called once so a run shows what it renders and sends (owner, investor and company statements with their PDFs).
if (process.env.LINK_SIGNING_KEY) {
  try {
    const { createHmac } = await import('node:crypto');
    const tok = createHmac('sha256', process.env.LINK_SIGNING_KEY).update('carmacars-listing-worker-v1').digest('hex');
    const r = await fetch(`${BASE}/api/jobs/statements`, { method: 'POST', headers: { authorization: `Bearer ${tok}` } });
    report.statement_job = { status: r.status, body: (await r.text()).slice(0, 400) };
  } catch (e) { report.statement_job = { error: String(e).slice(0, 200) }; }
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
// --auth: real sign-ins through the live form with one test account per portal: a renter, an owner, an investor,
// one assistant per function (customer service, Finance, Fleet, Sales), a field staff member and one Admin
// (verify-admin@carmacars.ca, the only verification address the database lets be an Admin). The accounts are
// created or their passwords reset through the Supabase admin API on each run (the Admin's is scrambled again at
// the end), any authenticator app left from an earlier run is removed, and public.server_verify_accounts gives each
// its role and puts its address on the email suppression list (no email is ever sent to them). Each must land on
// its own portal, load it without errors and be refused the others with a page that names the account. Then, as the
// Admin: "view as" for every portal (red banner, the person's own data, a write refused, the audit log), an
// invitation from Admin > Portals through to the password and the portal, and sign-out. Needs SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY (and SUPABASE_ACCESS_TOKEN with SUPABASE_PROJECT_REF to tidy the invitation up).
const ACCOUNTS = [
  { role: 'renter', email: 'verify-signin@carmacars.ca', name: 'Sign-in Check', home: '/account', width: 390 },
  { role: 'owner', email: 'verify-owner@carmacars.ca', name: 'Verify Owner', home: '/owner', width: 1440 },
  { role: 'investor', email: 'verify-investor@carmacars.ca', name: 'Verify Investor', home: '/investor', width: 390 },
  { role: 'va_cs', email: 'verify-va-cs@carmacars.ca', name: 'Verify Assistant', home: '/va', width: 1440, fn: 'Customer service' },
  { role: 'va_finance', email: 'verify-va-finance@carmacars.ca', name: 'Verify Finance', home: '/va', width: 1440, fn: 'Finance' },
  { role: 'va_fleet', email: 'verify-va-fleet@carmacars.ca', name: 'Verify Fleet', home: '/va', width: 390, fn: 'Fleet' },
  { role: 'va_sales', email: 'verify-va-sales@carmacars.ca', name: 'Verify Sales', home: '/va', width: 1440, fn: 'Sales' },
  { role: 'field', email: 'verify-field@carmacars.ca', name: 'Verify Field', home: '/field', width: 390 },
  { role: 'admin', email: 'verify-admin@carmacars.ca', name: 'Verify Admin', home: '/admin', width: 1440 }
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
const BROKEN = /couldn.t load|Application error|Something went wrong|Service Unavailable|Error 1102/i;
const randomPassword = () => `V${Math.random().toString(36).slice(2)}${Date.now()}!${Math.random().toString(36).slice(2, 8)}`;
if (process.argv.includes('--auth')) {
  const url = process.env.SUPABASE_URL, key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const h = { apikey: key, Authorization: `Bearer ${key}`, 'content-type': 'application/json' };
  const rest = async (q) => (await fetch(`${url}/rest/v1/${q}`, { headers: h })).json();
  const runStart = new Date().toISOString();
  report.portals = [];
  const admin = ACCOUNTS.find((a) => a.role === 'admin');
  // one page per account: sign in through the form, land on its portal, be refused the others
  const watchPage = (page, r) => {
    page.on('pageerror', (e) => r.errors.push(String(e).slice(0, 300)));
    page.on('console', (m) => { if (m.type() === 'error' && !noise(m.text()) && !/status of (5\d\d|403)/.test(m.text())) r.errors.push(m.text().slice(0, 300)); });
    page.on('response', async (x) => {
      if (x.status() < 400 || noise(x.url())) return;
      const said = x.status() >= 500 ? ((await x.text().catch(() => '')).match(/Error \d{4}[^<]{0,80}|exceeded[^<]{0,60}/i)?.[0] ?? '') : '';
      (r.responses ??= []).push(`${x.status()} ${x.request().method()} ${x.url().slice(0, 160)}${said ? ` (${said.trim()})` : ''}`);
    });
  };
  const loader = (page, r) => async (u) => {
    let resp = await page.goto(u, { waitUntil: 'networkidle' });
    for (let i = 1; i <= 2 && resp && resp.status() >= 500; i++) { (r.retried ??= []).push(`${resp.status()} ${u}`); await page.waitForTimeout(2000 * i); resp = await page.goto(u, { waitUntil: 'networkidle' }); }
    return resp;
  };
  const bodyText = (page) => page.locator('body').innerText().catch(() => '');
  async function signInForm(page, email, password) {
    await page.goto(`${BASE}/sign-in`, { waitUntil: 'networkidle' });
    const cookie = page.getByRole('button', { name: 'Necessary only' }).first();
    if (await cookie.isVisible().catch(() => false)) await cookie.click();
    await page.locator('#si-email').fill(email);
    await page.locator('#si-pass').fill(password);
    await page.getByRole('button', { name: 'Sign in', exact: true }).click();
    await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 30_000 });
  }
  try {
    const list = await (await fetch(`${url}/auth/v1/admin/users?per_page=1000`, { headers: h })).json();
    for (const a of ACCOUNTS) {
      a.password = randomPassword();
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
    report.accounts = { status: reg.status, body: reg.ok ? JSON.parse(regBody).map((x) => `${x.role}:${x.roles?.va ?? ''}${x.roles?.owner ? 'owner' : ''}${x.roles?.investor ? 'investor' : ''}${x.roles?.field ? 'field' : ''}${x.roles?.admin ? 'admin' : ''}`) : regBody.slice(0, 300) };
    if (!reg.ok) throw new Error(`server_verify_accounts ${reg.status}: ${regBody.slice(0, 300)}`);
    for (const a of ACCOUNTS) {
      const r = { role: a.role, home: a.home, steps: [a.step], errors: [], refused: {} };
      const ctx = await browser.newContext({ viewport: { width: a.width, height: 844 } });
      const page = await ctx.newPage();
      watchPage(page, r);
      const load = loader(page, r);
      for (let attempt = 1; attempt <= 2; attempt++) try {
        if (attempt === 2) { r.errors = []; r.refused = {}; delete r.error; }
        await signInForm(page, a.email, a.password);
        if (new URL(page.url()).pathname.startsWith('/two-step/setup')) {
          // staff two-step sign-in is on: enrol an authenticator for this run, as a person would
          await page.getByTestId('totp-start').click();
          const secret = (await page.getByTestId('totp-secret').textContent({ timeout: 15_000 }))?.trim() ?? '';
          await page.getByTestId('totp-code').fill(await totp(secret));
          await page.getByTestId('totp-submit').click();
          await page.waitForURL((u) => !u.pathname.startsWith('/two-step'), { timeout: 30_000 });
          r.steps.push('two-step enrolled');
        }
        await page.waitForURL((u) => u.pathname === a.home, { timeout: 30_000 }).catch(() => {});
        await page.waitForLoadState('networkidle');
        r.afterSignIn = page.url();
        if (BROKEN.test(await bodyText(page))) {
          // the home itself came back as an error page: load it once more and record the retry
          (r.retried ??= []).push(`home ${a.home}`); await load(`${BASE}${a.home}`);
        }
        r.h1 = await page.locator('h1').first().textContent({ timeout: 5_000 }).catch(() => null);
        r.broken = BROKEN.test(await bodyText(page));
        if (a.fn) r.fn = (await page.locator('.ad__who').first().textContent().catch(() => '')).includes(a.fn) ? a.fn : `NOT ${a.fn}`;
        await page.screenshot({ path: path.join(out, `portal-${a.role}.png`), fullPage: true });
        for (const p of PORTALS.filter((x) => x !== a.home)) {
          const resp = await load(`${BASE}${p}`);
          const fin = new URL(page.url()).pathname;
          // refused: the portal's no-access page (or "not an owner"), which names the account signed in
          const named = (await page.getByTestId('no-access-email').textContent({ timeout: 3_000 }).catch(() => null)) === a.email;
          r.refused[p] = fin !== p && /no-access|not-an-owner/.test(fin) ? `${fin}${named ? '' : ' (account not named)'}` : `SHOWN ${fin} ${resp?.status()}`;
        }
        if (a.role === 'admin') await adminChecks(page, r, load);
        // the automatic monthly owner debit (0037): the owner's Banking block, Admin > Owner debits and the company statements
        if (a.role === 'owner') {
          await load(`${BASE}/owner/banking`);
          r.autoDebit = (await page.getByTestId('owner-auto-debit').textContent({ timeout: 10_000 }).catch(() => null))?.slice(0, 160) ?? null;
          await page.screenshot({ path: path.join(out, 'owner-banking.png'), fullPage: true });
        }
        if (a.role === 'admin') {
          await load(`${BASE}/admin/debits`);
          r.debitsPage = (await page.getByTestId('debit-policy').textContent({ timeout: 10_000 }).catch(() => null))?.slice(0, 200) ?? null;
          await page.screenshot({ path: path.join(out, 'admin-debits.png'), fullPage: true });
          await load(`${BASE}/admin/reports`);
          r.reportsPage = (await page.locator('h1').first().textContent({ timeout: 10_000 }).catch(() => null)) ?? null;
        }
        if (a.role === 'renter') {
          // sign out: back to the home page, and the portal asks for a sign-in again
          await load(`${BASE}/account`);
          await page.getByRole('button', { name: 'Sign out' }).first().click();
          await page.waitForURL((u) => u.pathname === '/', { timeout: 20_000 });
          await load(`${BASE}/account`);
          r.signOut = new URL(page.url()).pathname.startsWith('/sign-in') ? 'signed out' : `STILL SIGNED IN ${page.url()}`;
        }
        r.ok = new URL(r.afterSignIn).pathname === a.home && !!r.h1 && !r.broken && r.errors.length === 0
          && Object.values(r.refused).every((v) => !String(v).startsWith('SHOWN') && !String(v).includes('not named'))
          && (!a.fn || r.fn === a.fn) && (a.role !== 'renter' || r.signOut === 'signed out')
          && (a.role !== 'owner' || !!r.autoDebit) && (a.role !== 'admin' || (!!r.debitsPage && r.reportsPage === 'Company statements'))
          && (a.role !== 'admin' || (r.viewAs?.every((v) => v.ok) && r.writeRefused?.ok && r.audit?.ok && r.exit?.ok && r.invite?.ok));
        if (r.ok) break;
      } catch (e) {
        r.ok = false; r.error = String(e).slice(0, 500);
        await page.screenshot({ path: path.join(out, `portal-${a.role}-failed.png`), fullPage: true }).catch(() => {});
        // a sign-in that never arrived (the Worker refused the request) is tried once more with a fresh page
        if (attempt === 1) { (r.retried ??= []).push(`sign-in: ${r.error.slice(0, 120)}`); await ctx.clearCookies(); }
      }
      report.portals.push(r);
      await ctx.close();
    }
    const renter = report.portals.find((x) => x.role === 'renter');
    report.auth = { ok: !!renter?.ok, steps: renter?.steps, afterSignIn: renter?.afterSignIn, adminForRenter: renter?.refused?.['/admin'], errors: renter?.errors ?? [] };
  } catch (e) {
    report.auth = { ok: false, error: String(e).slice(0, 800) };
  }

  // As the verification Admin: every portal through "view as", a write refused, the audit log, Exit, and an
  // invitation from Admin > Portals through to the password and the portal.
  async function adminChecks(page, r, load) {
    const target = (role) => ACCOUNTS.find((x) => x.role === role);
    const VIEWS = [['owner', 'owner', '/owner'], ['va-cs', 'va_cs', '/va'], ['va-finance', 'va_finance', '/va'], ['va-fleet', 'va_fleet', '/va'],
      ['va-sales', 'va_sales', '/va'], ['field', 'field', '/field'], ['investor', 'investor', '/investor'], ['account', 'renter', '/account']];
    r.viewAs = [];
    for (const [section, role, home] of VIEWS) {
      const t = target(role); const v = { portal: section, as: t.email };
      try {
        await load(`${BASE}/admin/portals?q=${encodeURIComponent(t.email)}`);
        const form = page.getByTestId(`open-as-${section}`);
        await form.locator('select').selectOption(t.id);
        await form.getByRole('button', { name: 'Open as this person' }).click();
        await page.waitForURL((u) => u.pathname === home, { timeout: 30_000 }).catch(async () => {
          // the form's answer was Cloudflare's Error 1102 (the free plan's CPU limit): send it once more
          (r.retried ??= []).push(`view as ${section} start`);
          await load(`${BASE}/admin/portals?q=${encodeURIComponent(t.email)}`);
          await page.getByTestId(`open-as-${section}`).locator('select').selectOption(t.id);
          await page.getByTestId(`open-as-${section}`).getByRole('button', { name: 'Open as this person' }).click();
          await page.waitForURL((u) => u.pathname === home, { timeout: 30_000 });
        });
        await page.waitForLoadState('networkidle');
        if (BROKEN.test(await bodyText(page))) { (r.retried ??= []).push(`view as ${section}`); await load(`${BASE}${home}`); }
        v.banner = (await page.getByTestId('view-as-banner').textContent({ timeout: 10_000 }).catch(() => '')).replace('Exit', '').trim();
        v.h1 = await page.locator('h1').first().textContent({ timeout: 5_000 }).catch(() => null);
        v.who = await page.getByTestId('account-email').first().textContent({ timeout: 3_000 }).catch(() => null);
        v.broken = BROKEN.test(await bodyText(page));
        v.ok = v.banner.includes(`Viewing as ${t.name} (${t.email}), read only`) && !!v.h1 && !v.broken && (!v.who || v.who === t.email || v.who === t.name);
        await page.screenshot({ path: path.join(out, `view-as-${section}.png`), fullPage: true });
      } catch (e) { v.ok = false; v.error = String(e).slice(0, 300); }
      r.viewAs.push(v);
    }
    // a write while viewing as the owner: the Save goes to the read-only page, a direct POST is refused, nothing changes
    try {
      const owner = target('owner');
      await load(`${BASE}/admin/portals?q=${encodeURIComponent(owner.email)}`);
      const form = page.getByTestId('open-as-owner');
      await form.locator('select').selectOption(owner.id);
      await form.getByRole('button', { name: 'Open as this person' }).click();
      await page.waitForURL((u) => u.pathname === '/owner', { timeout: 30_000 });
      const before = (await rest(`owners?user_id=eq.${owner.id}&select=phone`))[0]?.phone ?? null;
      await load(`${BASE}/owner/profile`);
      await page.locator('#ow-pr-phone').fill('416-555-0142');
      await page.getByRole('button', { name: 'Save', exact: true }).click();
      await page.waitForURL((u) => u.pathname === '/read-only', { timeout: 20_000 });
      const post = await page.request.post(`${BASE}/owner/profile`, { data: 'x', headers: { 'content-type': 'text/plain' } });
      const after = (await rest(`owners?user_id=eq.${owner.id}&select=phone`))[0]?.phone ?? null;
      r.writeRefused = { save: new URL(page.url()).pathname, post: post.status(), unchanged: before === after, ok: post.status() === 403 && before === after && new URL(page.url()).pathname === '/read-only' };
      await page.screenshot({ path: path.join(out, 'view-as-write-refused.png'), fullPage: true });
    } catch (e) { r.writeRefused = { ok: false, error: String(e).slice(0, 300) }; }
    try {
      const rows = await rest(`audit_log?actor_user_id=eq.${admin.id}&action=eq.view_as_start&at=gte.${encodeURIComponent(runStart)}&select=entity_id,after`);
      r.audit = { view_as_starts: Array.isArray(rows) ? rows.length : rows, ok: Array.isArray(rows) && rows.length >= VIEWS.length + 1 };
    } catch (e) { r.audit = { ok: false, error: String(e).slice(0, 200) }; }
    try {
      await load(`${BASE}/owner`);
      await page.getByTestId('view-as-exit').click();
      await page.waitForURL((u) => u.pathname === '/admin/portals', { timeout: 20_000 });
      const banner = await page.getByTestId('view-as-banner').count();
      await load(`${BASE}/owner`);
      r.exit = { banner, after: new URL(page.url()).pathname, ok: banner === 0 && /not-an-owner/.test(new URL(page.url()).pathname) };
    } catch (e) { r.exit = { ok: false, error: String(e).slice(0, 300) }; }
    // an invitation from Admin > Portals: the branded email goes to Resend's test inbox; the link it carries is made
    // again by the admin API (the inbox cannot be read here), opened, a password chosen, and the portal opens
    const inv = { email: `delivered+verify-invite-${Date.now()}@resend.dev` };
    try {
      await load(`${BASE}/admin/portals`);
      const f = page.getByTestId('invite-form');
      await f.getByLabel('Role').selectOption('va');
      await f.getByLabel('Name').fill('Verify Invitation');
      await f.getByLabel('Email').fill(inv.email);
      await f.getByLabel('Main function').selectOption('sales');
      await f.getByRole('button', { name: 'Invite' }).click();
      inv.said = await f.getByRole('status').textContent({ timeout: 30_000 }).catch(() => null);
      const g = await (await fetch(`${url}/auth/v1/admin/generate_link`, { method: 'POST', headers: h, body: JSON.stringify({ type: 'invite', email: inv.email }) })).json();
      let hashed = g.properties?.hashed_token ?? g.hashed_token, type = 'invite';
      if (!hashed) {
        const g2 = await (await fetch(`${url}/auth/v1/admin/generate_link`, { method: 'POST', headers: h, body: JSON.stringify({ type: 'recovery', email: inv.email }) })).json();
        hashed = g2.properties?.hashed_token ?? g2.hashed_token; type = 'recovery'; inv.note = `invite link: ${JSON.stringify(g).slice(0, 120)}`;
      }
      inv.id = g.user?.id ?? g.id;
      const c2 = await browser.newContext({ viewport: { width: 390, height: 844 } });
      const p2 = await c2.newPage();
      p2.on('response', async (x) => {
        if (x.status() < 500) return;
        const said = (await x.text().catch(() => '')).match(/Error \d{4}[^<]{0,80}|exceeded[^<]{0,60}/i)?.[0] ?? '';
        (r.responses ??= []).push(`${x.status()} ${x.request().method()} ${x.url().slice(0, 160)}${said ? ` (${said.trim()})` : ''}`);
      });
      await p2.goto(`${BASE}/auth/callback?token_hash=${encodeURIComponent(hashed)}&type=${type}&next=/update-password`, { waitUntil: 'networkidle' });
      inv.landed = new URL(p2.url()).pathname;
      for (let i = 1; i <= 2 && inv.landed === '/update-password' && BROKEN.test(await bodyText(p2)); i++) {
        // Error 1102 on the page itself: the link already signed the person in, so the page is loaded again
        (inv.retried ??= []).push('update-password'); await p2.waitForTimeout(2000 * i); await p2.goto(`${BASE}/update-password`, { waitUntil: 'networkidle' });
      }
      inv.h1 = await p2.locator('h1').first().textContent({ timeout: 5_000 }).catch(() => null);
      await p2.locator('#np-pass').fill(randomPassword());
      await p2.getByRole('button', { name: 'Save the new password' }).click();
      await p2.waitForURL((u) => u.pathname === '/va', { timeout: 30_000 });
      if (BROKEN.test(await bodyText(p2))) { (inv.retried ??= []).push('va'); await p2.goto(`${BASE}/va`, { waitUntil: 'networkidle' }); }
      inv.portal = new URL(p2.url()).pathname;
      inv.who = await p2.locator('.ad__who').first().textContent().catch(() => null);
      await p2.screenshot({ path: path.join(out, 'invite-landed.png'), fullPage: true });
      await c2.close();
      inv.ok = /Invitation sent/.test(inv.said ?? '') && inv.landed === '/update-password' && inv.portal === '/va' && /Sales/.test(inv.who ?? '') && /Verify Invitation/.test(inv.who ?? '');
    } catch (e) { inv.ok = false; inv.error = String(e).slice(0, 300); }
    // tidy up: the sign-in, and the staff record the invitation made
    try {
      const uid = inv.id ?? (await rest(`users?email=eq.${encodeURIComponent(inv.email)}&select=id`))[0]?.id;
      if (uid) {
        inv.removed = (await fetch(`${url}/auth/v1/admin/users/${uid}`, { method: 'DELETE', headers: h })).status;
        const ref = process.env.SUPABASE_PROJECT_REF, mt = process.env.SUPABASE_ACCESS_TOKEN;
        if (ref && mt) {
          const q = `delete from public.staff_profiles where user_id = '${uid}'; delete from public.user_roles where user_id = '${uid}'; delete from public.users where id = '${uid}' and email like 'delivered+verify-invite-%@resend.dev';`;
          inv.tidied = (await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, { method: 'POST', headers: { Authorization: `Bearer ${mt}`, 'content-type': 'application/json' }, body: JSON.stringify({ query: q }) })).status;
        }
      }
    } catch (e) { inv.tidy_error = String(e).slice(0, 200); }
    r.invite = inv;
  }

  // The Supabase Auth email links end to end: a recovery link for the renter test account (through to a new password
  // and the renter portal), an invitation and a sign-up confirmation for throwaway addresses at Resend's test inbox
  // (removed again), and a used link (it must offer a new one). Each link is made by the admin API exactly as the email
  // would carry it (generate_link sends nothing) and opened at the site's /auth/callback as the templates of
  // scripts/deploy/auth-templates.mjs link it. The templates stored in the project are checked to link the same way.
  report.auth_links = [];
  try {
    const ref = process.env.SUPABASE_PROJECT_REF, mt = process.env.SUPABASE_ACCESS_TOKEN;
    let cfg = null;
    if (ref && mt) cfg = await (await fetch(`https://api.supabase.com/v1/projects/${ref}/config/auth`, { headers: { Authorization: `Bearer ${mt}` } })).json();
    const stamp = Date.now();
    const LINKS = [
      { type: 'recovery', email: 'verify-signin@carmacars.ca', next: '/update-password', tpl: 'recovery', choose: '/account' },
      { type: 'invite', email: `delivered+invite-${stamp}@resend.dev`, next: '/update-password', tpl: 'invite', remove: true },
      { type: 'signup', email: `delivered+signup-${stamp}@resend.dev`, next: '/account', tpl: 'confirmation', remove: true, password: `S${stamp}x!aA` }
    ];
    for (const l of LINKS) {
      const r = { type: l.type, ok: false };
      const tplBody = cfg?.[`mailer_templates_${l.tpl}_content`] ?? '';
      r.template = tplBody ? (tplBody.includes(`/auth/callback?token_hash={{ .TokenHash }}&type=${l.type}`) ? 'links to /auth/callback' : 'DOES NOT link to /auth/callback') : 'not read';
      r.subject = cfg?.[`mailer_subjects_${l.tpl}`] ?? null;
      try {
        const g = await (await fetch(`${url}/auth/v1/admin/generate_link`, { method: 'POST', headers: h, body: JSON.stringify({ type: l.type, email: l.email, ...(l.password ? { password: l.password } : {}) }) })).json();
        const hashed = g.properties?.hashed_token ?? g.hashed_token; const uid = g.user?.id ?? g.id;
        if (!hashed) throw new Error('generate_link: ' + JSON.stringify(g).slice(0, 200));
        const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
        const page = await ctx.newPage();
        if (tplBody) {
          for (const w of [375, 640]) {
            await page.setViewportSize({ width: w, height: 900 });
            await page.setContent(tplBody.replaceAll('{{ .SiteURL }}', BASE).replaceAll('{{ .TokenHash }}', 'sample'));
            await page.screenshot({ path: path.join(out, `auth-${l.tpl}-${w}.png`), fullPage: true });
            if (await page.evaluate(() => document.documentElement.scrollWidth > window.innerWidth + 1)) r.overflow = (r.overflow ?? []).concat(w);
          }
        }
        const link = `${BASE}/auth/callback?token_hash=${encodeURIComponent(hashed)}&type=${l.type}&next=${l.next}`;
        await page.goto(link, { waitUntil: 'networkidle' });
        for (let i = 1; i <= 2 && BROKEN.test(await bodyText(page)) && new URL(page.url()).pathname === l.next; i++) {
          // Error 1102 on the landing page: the link already signed the person in, so the page is loaded again
          (r.retried ??= []).push(l.next); await page.waitForTimeout(2000 * i); await page.goto(`${BASE}${l.next}`, { waitUntil: 'networkidle' });
        }
        r.final = new URL(page.url()).pathname + new URL(page.url()).search;
        r.h1 = await page.locator('h1').first().textContent({ timeout: 5_000 }).catch(() => null);
        r.ok = r.final.startsWith(l.next) && !/error=link|link-expired/.test(r.final) && !BROKEN.test(await bodyText(page));
        await page.screenshot({ path: path.join(out, `auth-link-${l.type}.png`), fullPage: true });
        if (l.choose) {
          // the reset through to the end: a new password, then the person's portal
          await page.locator('#np-pass').fill(randomPassword());
          await page.getByRole('button', { name: 'Save the new password' }).click();
          await page.waitForURL((u) => u.pathname === l.choose, { timeout: 30_000 }).catch(() => {});
          r.chosen = new URL(page.url()).pathname + new URL(page.url()).search;
          r.saved = await page.getByText('Password saved').count();
          r.ok = r.ok && r.chosen.startsWith(l.choose) && r.saved > 0;
          // the same link again: spent, so a friendly page that sends a new one
          // (not networkidle: the page carries the bot check widget, which keeps the network busy)
          await page.goto(link, { waitUntil: 'load' });
          await page.getByRole('button', { name: 'Send me a new link' }).waitFor({ timeout: 15_000 }).catch(() => {});
          r.reused = new URL(page.url()).pathname;
          r.offersNew = await page.getByRole('button', { name: 'Send me a new link' }).count();
          r.ok = r.ok && r.reused === '/link-expired' && r.offersNew > 0;
          await page.screenshot({ path: path.join(out, 'auth-link-reused.png'), fullPage: true });
        }
        await ctx.close();
        if (l.remove && uid) r.removed = (await fetch(`${url}/auth/v1/admin/users/${uid}`, { method: 'DELETE', headers: h })).status;
      } catch (e) { r.ok = false; r.error = String(e).slice(0, 300); }
      report.auth_links.push(r);
    }
  } catch (e) { report.auth_links.push({ error: String(e).slice(0, 300) }); }
  // The reset form itself, as the owner will use it (/reset-password, then Supabase sends the email): a throwaway account
  // at Resend's test inbox asks for a link; Supabase must record the email as sent. Removed again. Informational when
  // the bot check (Turnstile) does not let a headless browser through.
  try {
    const email = `delivered+reset-${Date.now()}@resend.dev`;
    const made = await (await fetch(`${url}/auth/v1/admin/users`, { method: 'POST', headers: h, body: JSON.stringify({ email, password: randomPassword(), email_confirm: true }) })).json();
    const r = { email, ok: false };
    const ctx = await browser.newContext({ viewport: { width: 390, height: 844 } });
    const page = await ctx.newPage();
    await page.goto(`${BASE}/reset-password`, { waitUntil: 'load' });
    await page.locator('#rp-email').fill(email);
    await page.waitForTimeout(3000);
    await page.getByRole('button', { name: 'Send the link' }).click();
    r.said = await page.locator('.alert').first().textContent({ timeout: 30_000 }).catch(() => null);
    for (let i = 0; i < 10 && made?.id; i++) {
      const u = await (await fetch(`${url}/auth/v1/admin/users/${made.id}`, { headers: h })).json();
      r.recovery_sent_at = u.recovery_sent_at ?? null;
      if (r.recovery_sent_at) break;
      await new Promise((x) => setTimeout(x, 1500));
    }
    r.ok = /Check your email/.test(r.said ?? '') && !!r.recovery_sent_at;
    r.botCheck = /not a bot/.test(r.said ?? '');
    await page.screenshot({ path: path.join(out, 'reset-form.png'), fullPage: true });
    await ctx.close();
    if (made?.id) r.removed = (await fetch(`${url}/auth/v1/admin/users/${made.id}`, { method: 'DELETE', headers: h })).status;
    report.reset_form = r;
  } catch (e) { report.reset_form = { ok: false, error: String(e).slice(0, 300) }; }
  // the verification Admin cannot be used between runs: its password is scrambled again
  try { if (admin?.id) await fetch(`${url}/auth/v1/admin/users/${admin.id}`, { method: 'PUT', headers: h, body: JSON.stringify({ password: randomPassword() + randomPassword() }) }); report.admin_password_scrambled = true; } catch { report.admin_password_scrambled = false; }
  report.auth_links_ok = report.auth_links.length === 3 && report.auth_links.every((x) => x.ok);
  report.portals_ok = report.portals.length === ACCOUNTS.length && report.portals.every((x) => x.ok);
  // Cloudflare's 1102 ("Worker exceeded resource limits": the plan's CPU or memory limit) per run
  report.worker_limits = report.portals.flatMap((x) => (x.responses ?? []).filter((y) => /exceeded resource limits|Error 1102/i.test(y))).length;
  if (!report.portals_ok || !report.auth_links_ok) process.exitCode = 1;
}

await browser.close();
fs.writeFileSync(path.join(out, 'report.json'), JSON.stringify(report, null, 2));
console.log(JSON.stringify(report, null, 2));
