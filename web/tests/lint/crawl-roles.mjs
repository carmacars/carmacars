// Crawls the running site in a browser, anonymous and signed in as every role (renter, owner, admin, each
// assistant function, field, investor), and fails on anything a visitor would hit:
//   - a page or a link that answers 404 or 5xx (every link found is requested, the pages are rendered),
//   - a form whose GET action does not answer, a toggle or dialog button that does nothing or throws,
//   - a button with no handler (no React handler, no listener, not a form submit),
//   - a console error, an uncaught exception or a failed same-origin request,
//   - horizontal overflow at 375 and at 1440.
// Pages with ids are sampled (two of each shape, e.g. /admin/bookings/:id). Local stack only: it signs in
// accounts it picks from the database (the richest of each role) after giving them a known password in
// local_auth; it never submits a form that writes.
//   BASE_URL=http://localhost:3000 node tests/lint/crawl-roles.mjs [--roles anon,renter] [--per-shape 2] [--fresh] [--part 1/3] [--out reports/crawl.json]
// --part i/n (CI runs the large portals in parallel jobs): the same crawl, but this run renders and checks only the pages
// whose shape falls in part i of n (a hash of the shape); the other pages are still requested (status checked) and their
// links followed from the server's HTML, so the n parts together render and check every page one run would.
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from '@playwright/test';
import postgres from 'postgres';

// the browsers of this machine when present; otherwise Playwright's own cache (CI caches ~/.cache/ms-playwright)
if (!process.env.PLAYWRIGHT_BROWSERS_PATH && fs.existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const BASE = (process.env.BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');
const arg = (n, d) => { const i = process.argv.indexOf(n); return i > 0 ? process.argv[i + 1] : d; };
const PER_SHAPE = Number(arg('--per-shape', '2'));
// a role's crawl stops after this many minutes and reports where the time went (a page or link that got slow)
const MAX_MINUTES = Number(arg('--max-minutes', '30'));
const OUT = arg('--out', 'reports/crawl.json');
const ONLY = arg('--roles', '')?.split(',').filter(Boolean);
const [PART, PARTS] = (/^(\d+)\/(\d+)$/.exec(arg('--part', '1/1')) ?? [0, 1, 1]).slice(1).map(Number);
if (!(PARTS >= 1 && PART >= 1 && PART <= PARTS)) throw new Error('--part i/n: 1 <= i <= n');
// FNV-1a of the shape: which part renders it
const mine = (sh) => { let h = 0x811c9dc5; for (let i = 0; i < sh.length; i++) h = Math.imul(h ^ sh.charCodeAt(i), 0x01000193) >>> 0; return h % PARTS === PART - 1; };
const PW = 'crawl-roles password 1';
const FRESH = process.argv.includes('--fresh'); // new bare accounts instead of the richest existing ones
const sql = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 2, onnotice: () => {} });

const hash = (pw) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

// ------------------------------------------------------------------ who signs in
async function pick(role) {
  const no2fa = sql`and not exists (select 1 from local_auth.factors f where f.user_id = u.id and f.verified_at is not null)`;
  const q = {
    renter: sql`select u.id, u.email from users u join renters r on r.user_id = u.id where true ${no2fa}
                order by (select count(distinct b.status) from bookings b where b.renter_id = r.id) desc, (select count(*) from bookings b where b.renter_id = r.id) desc limit 1`,
    owner: sql`select u.id, u.email from users u join owners o on o.user_id = u.id where true ${no2fa}
               order by (select count(*) from owner_statements s where s.owner_id = o.id) desc, (select count(*) from vehicles v where v.owner_id = o.id) desc limit 1`,
    investor: sql`select u.id, u.email from users u join investors i on i.user_id = u.id where true ${no2fa}
                  order by (select count(*) from investments x where x.investor_id = i.id) desc limit 1`,
    admin: sql`select u.id, u.email from users u join user_roles r on r.user_id = u.id and r.role = 'admin' where u.status = 'active' ${no2fa}
               order by u.created_at limit 1`,
    field: sql`select u.id, u.email from users u join staff_profiles p on p.user_id = u.id and p.staff_type = 'field' where p.is_active ${no2fa}
               order by (select count(*) from field_jobs j where j.assigned_to = u.id) desc limit 1`
  };
  const va = /^va_(cs|finance|fleet|sales)$/.exec(role)?.[1];
  const rows = va
    ? await sql`select u.id, u.email from users u join staff_profiles p on p.user_id = u.id and p.staff_type = 'va' and p.va_function = ${va}::va_function
                where p.is_active and coalesce(array_length(p.cover_functions, 1), 0) = 0 ${no2fa}
                order by (select count(*) from tasks t where t.assigned_to = u.id) desc limit 1`
    : await q[role];
  // a fresh stack (CI before any end-to-end run) may have no account of a role: make a bare one
  if (!rows[0] || FRESH) rows.splice(0, 1, await create(role, va));
  const { id, email } = rows[0];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})
            on conflict (id) do update set password_hash = excluded.password_hash, email = excluded.email`;
  return { id, email };
}

async function create(role, va) {
  const id = randomUUID(); const email = `crawl-${role.replace('_', '-')}-${Date.now()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, ${'Crawl ' + role}, null)`;
  if (role !== 'renter') await sql`delete from user_roles where user_id = ${id} and role = 'renter'`;
  if (role === 'owner') { await sql`insert into user_roles (user_id, role) values (${id}, 'owner') on conflict do nothing`; await sql`insert into owners (user_id, owner_type, legal_name, status, email) values (${id}, 'individual', 'Crawl Owner', 'active', ${email})`; }
  if (role === 'investor') { await sql`insert into investors (user_id, legal_name, investor_type, status, email) values (${id}, 'Crawl Investor', 'individual', 'active', ${email})`; }
  if (role === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin') on conflict do nothing`;
  if (va) { await sql`insert into user_roles (user_id, role) values (${id}, 'va') on conflict do nothing`; await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, is_active) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va}::va_function, true)`; }
  if (role === 'field') { await sql`insert into user_roles (user_id, role) values (${id}, 'field') on conflict do nothing`; await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function, is_active) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver', true)`; }
  return { id, email };
}

const HOME = { anon: '/', renter: '/account', owner: '/owner', investor: '/investor', admin: '/admin', field: '/staff/field', va_cs: '/staff', va_finance: '/staff', va_fleet: '/staff', va_sales: '/staff' };
const ROLES = Object.keys(HOME).filter((r) => !ONLY.length || ONLY.includes(r));
// The other portals' homes: every role is also sent there, to see the refusal page is a good page.
const PORTALS = ['/account', '/owner', '/investor', '/admin', '/staff', '/staff/field'];

// ------------------------------------------------------------------ helpers
// the place pages (0095): every place and term is the same template, so they are one shape each (two segments: one per
// family; one segment: a place's own page, its slug ending in its region's code, a country, a province, the GTA or an airport)
const PLACE_HUB = /^\/(car-rental|buy|detailing|body-shop)\/[a-z0-9-]+\/[a-z0-9-]+$/;
const PLACE_ONE = /^\/car-rental\/([a-z0-9-]+-[a-z]{2,3}|canada|united-states|mexico|ontario|gta|[a-z0-9-]+-airport)$/;
const shape = (u) => {
  if (PLACE_HUB.test(u.pathname)) return `/${u.pathname.split('/')[1]}/:term/:place`;
  if (PLACE_ONE.test(u.pathname)) return '/car-rental/:place';
  // the vehicle pages (0097): one shape per level (/cars/<make>, /<model>, /<year>, /<trim>), thousands of addresses
  // the city and colour pages and the /buy twins (0097): one shape per depth
  const deep = /^\/(cars|buy|t)((?:\/[^/]+)+)$/.exec(u.pathname);
  if (deep && (deep[1] !== 'cars' || deep[2].split('/').length > 5)) return `/${deep[1]}/:vehicle-${deep[2].split('/').length - 1}${deep[2].includes('/colour/') ? '-colour' : ''}`;
  const v = /^\/cars\/([^/]+)((?:\/[^/]+){0,3})$/.exec(u.pathname);
  if (v && (v[2] || !/\d/.test(v[1]))) return ['/cars/:make', '/cars/:make/:model', '/cars/:make/:model/:year', '/cars/:make/:model/:year/:trim'][v[2].split('/').length - 1];
  const segs = u.pathname.split('/').map((s) => (/\d/.test(s) && !/^(two-step)$/.test(s) ? ':id' : s));
  // filters multiply (queue x tab x type): a shape keeps the tab's value and only the names of the others
  const qs = [...u.searchParams.entries()].map(([k, v]) => (k === 'tab' || k === 'section' ? `${k}=${v}` : k)).sort().join('&');
  return segs.join('/') + (qs ? '?' + qs : '');
};
// The families of generated pages: every vehicle level and variant (make, model, year, trim, place, colour, /buy, each
// term) and every place page; a shape of one of them stands for thousands of addresses of the same template.
const family = (sh) => (/^\/(cars\/:|buy\/|t\/|car-rental\/:|detailing\/:|body-shop\/:)/.test(sh) ? sh : null);
const LINK_PER_FAMILY = Number(arg('--links-per-family', '2'));
// Never followed: sign-out, and links that act once (a resume or referral link is requested, not rendered); the OAuth
// start and callback answer with a redirect to the provider's page (its local stand-in here), never a page of the site.
const SKIP_RENDER = /^\/(api\/|files\/|d\/|r\/|list-your-car\/apply\/resume|auth\/(callback|oauth)|admin\/reports\/export|admin\/documents\/|account\/documents\/[^/]+$|owner\/documents\/(forms\/)?[^/]+$|investor\/statements\/year\/|field\/manifest)/;
const PRIVATE = /^\/(account|owner|investor|admin|va|field|staff|two-step|sign\/|unsubscribe)/;
const IGNORE_CONSOLE = [/Download the React DevTools/];

const problems = [];
const report = { base: BASE, at: new Date().toISOString(), roles: {} };
const bad = (role, where, what) => problems.push(`[${role}] ${where}: ${what}`);

async function signIn(page, who, home) {
  await page.goto(BASE + '/sign-in', { waitUntil: 'networkidle' });
  const nec = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await nec.isVisible().catch(() => false)) await nec.click();
  await page.locator('input[type="email"]').fill(who.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(home), { timeout: 30_000 });
}

/** Buttons a person can press that do nothing: no React handler on it or a near ancestor, no DOM listener, not a submit. */
async function deadButtons(page) {
  const marked = await page.evaluate(() => {
    const vis = (e) => { const r = e.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(e).visibility !== 'hidden'; };
    const react = (e) => { const k = Object.keys(e).find((x) => x.startsWith('__reactProps$')); return k ? e[k] : null; };
    const has = (p) => p && Object.keys(p).some((k) => /^on[A-Z]/.test(k) && typeof p[k] === 'function');
    let n = 0; const out = [];
    for (const e of document.querySelectorAll('button, [role="button"], input[type="button"], input[type="submit"]')) {
      if (!vis(e) || e.disabled || e.getAttribute('aria-disabled') === 'true' || e.closest('[inert]')) continue;
      const p = react(e);
      if (has(p) || typeof e.onclick === 'function' || p?.formAction) continue;
      const type = (e.getAttribute('type') || (e.tagName === 'BUTTON' ? 'submit' : '')).toLowerCase();
      if ((type === 'submit' || type === 'reset') && e.form) continue;
      if (e.hasAttribute('popovertarget') || e.hasAttribute('commandfor')) continue;
      let a = e.parentElement; let ok = false;
      for (let i = 0; a && i < 4; i++, a = a.parentElement) if (has(react(a))) { ok = true; break; }
      if (ok) continue;
      e.setAttribute('data-crawl-dead', String(n++));
      out.push((e.textContent || e.getAttribute('aria-label') || e.outerHTML.slice(0, 80)).trim().slice(0, 60));
    }
    return out;
  });
  if (!marked.length) return [];
  // last chance: a listener added with addEventListener (DevTools protocol)
  const cdp = await page.context().newCDPSession(page);
  const dead = [];
  for (let i = 0; i < marked.length; i++) {
    const { result } = await cdp.send('Runtime.evaluate', { expression: `document.querySelector('[data-crawl-dead="${i}"]')` });
    if (!result.objectId) continue;
    const { listeners } = await cdp.send('DOMDebugger.getEventListeners', { objectId: result.objectId, depth: -1 });
    if (!listeners.some((l) => /click|pointer|mouse|touch|keydown/.test(l.type))) dead.push(marked[i]);
  }
  await cdp.detach();
  return dead;
}

/** Toggles and dialog buttons (aria-expanded, aria-haspopup): pressing one must change something and throw nothing. */
async function pressToggles(page, errors) {
  const n = await page.locator('button[aria-expanded]:visible, button[aria-haspopup]:visible').count();
  const out = [];
  for (let i = 0; i < Math.min(n, 8); i++) {
    const b = page.locator('button[aria-expanded]:visible, button[aria-haspopup]:visible').nth(i);
    const label = ((await b.textContent().catch(() => '')) || (await b.getAttribute('aria-label')) || '').trim().slice(0, 50);
    const before = await page.evaluate(() => document.body.innerHTML.length + ':' + document.querySelectorAll('dialog[open], [aria-expanded="true"]').length).catch(() => '');
    const errs = errors.length;
    try { await b.click({ timeout: 3000 }); } catch { continue; }
    await page.waitForTimeout(150);
    const after = await page.evaluate(() => document.body.innerHTML.length + ':' + document.querySelectorAll('dialog[open], [aria-expanded="true"]').length).catch(() => '');
    if (before === after) out.push(`"${label}" changes nothing`);
    if (errors.length > errs) out.push(`"${label}" throws: ${errors.slice(errs).join(' | ').slice(0, 200)}`);
    await page.keyboard.press('Escape').catch(() => {});
    await page.evaluate(() => document.querySelectorAll('dialog[open]').forEach((d) => d.close())).catch(() => {});
    if ((await b.getAttribute('aria-expanded').catch(() => null)) === 'true') await b.click({ timeout: 2000 }).catch(() => {});
  }
  return out;
}

async function overflow(page) {
  return page.evaluate(() => {
    const over = document.documentElement.scrollWidth - window.innerWidth;
    if (over <= 0) return null;
    const culprits = [...document.querySelectorAll('body *')].filter((e) => e.getBoundingClientRect().right > window.innerWidth + 1 && e.offsetParent)
      .slice(-3).map((e) => `${e.tagName.toLowerCase()}.${String(e.className).split(' ')[0]}`);
    return `${over}px (${culprits.join(', ')})`;
  });
}

// ------------------------------------------------------------------ crawl one role
async function crawlRole(browser, role) {
  const who = role === 'anon' ? null : await pick(role);
  const stats = { who: who?.email ?? null, pages: 0, links: 0, forms: 0, toggles: 0, skippedShapes: 0 };
  report.roles[role] = stats;
  if (role !== 'anon' && !who) { bad(role, 'setup', 'no account of this role in the database'); return; }
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, baseURL: BASE });
  const page = await ctx.newPage();
  const errors = [];
  page.on('console', (m) => { if (m.type() === 'error' && !IGNORE_CONSOLE.some((r) => r.test(m.text()))) errors.push(m.text().slice(0, 300)); });
  page.on('pageerror', (e) => errors.push('pageerror: ' + String(e).slice(0, 300)));
  page.on('response', (r) => {
    const u = new URL(r.url());
    if (u.origin === BASE && r.status() >= 400 && r.request().resourceType() !== 'document') errors.push(`request ${r.request().method()} ${u.pathname}${u.search} answered ${r.status()}`);
  });
  if (who) await signIn(page, who, HOME[role]);
  else await page.goto(BASE + '/', { waitUntil: 'networkidle' });

  const queue = [HOME[role], ...PORTALS.filter((p) => p !== HOME[role])];
  const seen = new Set(); const shapes = new Map(); const checked = new Map(); const familyLinks = new Map();
  const status = async (href) => {
    if (checked.has(href)) return checked.get(href);
    const t0 = Date.now();
    const r = await ctx.request.get(BASE + href, { maxRedirects: 5, failOnStatusCode: false, timeout: 30_000 }).catch((e) => ({ status: () => 599, headers: () => ({}), err: String(e) }));
    slow.push([Date.now() - t0, 'link ' + href]);
    // a link of ours that sends the browser on to another site (a follow on the Rewards page): ours answered with the
    // redirect, which is what counts; the other site's answer (a 429, a page that is not ours) is not checked or rendered
    const away = typeof r.url === 'function' && new URL(r.url()).origin !== BASE;
    const v = away ? { status: 200, type: 'external' } : { status: r.status(), type: r.headers()['content-type'] ?? '' };
    checked.set(href, v); stats.links++;
    return v;
  };

  const discover = async (href) => {
    const r = await ctx.request.get(BASE + href, { maxRedirects: 5, failOnStatusCode: false, timeout: 30_000 }).catch(() => null);
    if (!r || r.status() >= 400) return;
    const at = r.url();
    if (new URL(at).origin !== BASE) return;
    const html = await r.text().catch(() => '');
    for (const m of html.matchAll(/<a\b[^>]*\bhref="([^"]+)"/g)) {
      const h = m[1].replace(/&amp;/g, '&');
      if (/^(mailto:|tel:|javascript:|#)/.test(h) || h.startsWith('blob:') || h.startsWith('data:')) continue;
      const t = new URL(h, at);
      if (t.origin !== BASE) continue;
      const p = t.pathname + t.search;
      // a generated family's links: followed only while a rendered page would still request them (budget not spent here)
      const fam = family(shape(t));
      if (fam && !checked.has(p) && (familyLinks.get(fam) ?? 0) >= LINK_PER_FAMILY) continue;
      if (!seen.has(p)) queue.push(p);
    }
  };

  const started = Date.now(); let lastLog = started;
  const slow = []; const perPage = [];
  const timeReport = () => {
    const top = [...slow].sort((a, b) => b[0] - a[0]).slice(0, 12).map(([ms, w]) => `${(ms / 1000).toFixed(1)}s ${w}`);
    const pages = [...perPage].sort((a, b) => b[0] - a[0]).slice(0, 8).map(([ms, w, n]) => `${(ms / 1000).toFixed(0)}s ${w} (${n} links)`);
    return `slowest: ${top.join(' | ')} || pages taking longest (render + their links): ${pages.join(' | ')}`;
  };
  while (queue.length) {
    if (Date.now() - started > MAX_MINUTES * 60_000) {
      bad(role, 'time', `the crawl took over ${MAX_MINUTES} minutes (${stats.pages} pages, ${stats.links} links checked, ${queue.length} left): ${timeReport()}`.slice(0, 3000));
      break;
    }
    if (Date.now() - lastLog > 120_000) { lastLog = Date.now(); console.log(`crawl ${role}: ${Math.round((Date.now() - started) / 60_000)} min, ${stats.pages} pages, ${stats.links} links, ${queue.length} queued`); }
    const href = queue.shift();
    if (seen.has(href)) continue;
    seen.add(href);
    const u = new URL(href, BASE);
    const sh = shape(u);
    const n = shapes.get(sh) ?? 0;
    if (n >= PER_SHAPE) { stats.skippedShapes++; continue; }
    shapes.set(sh, n + 1);
    const s = await status(href);
    if (s.status >= 400) { bad(role, href, `HTTP ${s.status}`); continue; }
    if (SKIP_RENDER.test(u.pathname) || !s.type.includes('text/html')) continue;
    // public pages are rendered once, by the anonymous visitor; a signed-in role only checks they answer
    if (role !== 'anon' && !PRIVATE.test(u.pathname)) continue;
    // another part renders and checks this page: here only its links are followed (from the server's HTML)
    if (!mine(sh)) { await discover(href); continue; }

    errors.length = 0;
    const pageStart = Date.now(); const linksBefore = stats.links;
    const resp = await page.goto(BASE + href, { waitUntil: 'load', timeout: 45_000 }).catch((e) => { bad(role, href, 'load: ' + String(e).slice(0, 150)); return null; });
    // hydrated: the root layout's Effects adds the "js" class in its first effect (then handlers are attached)
    if (resp) await page.waitForFunction(() => document.documentElement.classList.contains('js'), null, { timeout: 15_000 }).catch(() => bad(role, href, 'the page did not hydrate within 15 s'));
    if (resp) await page.waitForLoadState('networkidle', { timeout: 3_000 }).catch(() => {});
    if (!resp) continue;
    if (resp.status() >= 400) { bad(role, href, `rendered with HTTP ${resp.status()}`); continue; }
    stats.pages++;
    const here = new URL(page.url());
    if (here.origin !== BASE) continue;
    await page.waitForTimeout(200);
    const body = await page.locator('body').innerText().catch(() => '');
    if (/Application error|Unhandled Runtime Error|couldn.t load this|Something went wrong/i.test(body)) bad(role, href, 'error text on the page: ' + (/(Application error|Unhandled Runtime Error|couldn.t load this[^.]*|Something went wrong[^.]*)/i.exec(body)?.[1] ?? ''));

    const text = body.replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
    if (/[\u2014\u2013]/.test(text)) bad(role, href, `long dash in the copy: "${/.{0,30}[\u2014\u2013].{0,30}/.exec(text)?.[0]}"`);
    if (/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bCarmaCar\b(?!s)/.test(text)) bad(role, href, 'brand not written CarmaCars');
    if (role === 'anon' && /18122211|Canada Inc\b/i.test(text)) bad(role, href, 'numbered company name on a public page');
    const found = await page.evaluate(() => ({
      links: [...document.querySelectorAll('a[href]')].map((a) => a.getAttribute('href')),
      forms: [...document.querySelectorAll('form')].map((f) => ({ method: (f.getAttribute('method') || 'get').toLowerCase(), action: f.getAttribute('action'), q: new URLSearchParams(new FormData(f)).toString() }))
    }));
    for (const h of found.links) {
      if (!h || /^(mailto:|tel:|javascript:|#)/.test(h) || h.startsWith('blob:') || h.startsWith('data:')) continue;
      const t = new URL(h, page.url());
      if (t.origin !== BASE) continue;
      const p = t.pathname + t.search;
      // a query appended to a query ("?tab=a?status=b") nests on every click, and each nesting is a new page to the crawl
      if (t.search.indexOf('?', 1) !== -1) { bad(role, href, `link with a second "?": ${p.slice(0, 120)}`); continue; }
      // the vehicle and place pages (0095, 0097) link to hundreds of their variants: of each family (one shape) only
      // the first LINK_PER_FAMILY links are requested; the link check and the SEO audit cover the rest by sampling
      const fam = family(shape(t));
      if (fam && !checked.has(p)) { const k = familyLinks.get(fam) ?? 0; if (k >= LINK_PER_FAMILY) continue; familyLinks.set(fam, k + 1); }
      const st = await status(p);
      if (st.status >= 400) bad(role, href, `link ${p} answers ${st.status}`);
      else if (!seen.has(p)) queue.push(p);
    }
    perPage.push([Date.now() - pageStart, href, stats.links - linksBefore]);
    for (const f of found.forms) {
      stats.forms++;
      if (f.action && /^javascript:/.test(f.action)) continue; // a React server action (POST, writes)
      if (f.method === 'get') {
        const t = new URL(f.action || page.url(), page.url());
        const p = t.pathname + '?' + f.q.replace(/(^|&)\$ACTION[^&]*/g, '');
        if (t.origin !== BASE) continue;
        const st = await status(p);
        if (st.status >= 400) bad(role, href, `form GET ${p} answers ${st.status}`);
      } else if (f.action && !/^javascript:/.test(f.action)) {
        const t = new URL(f.action, page.url());
        if (t.origin === BASE && !/^\/api\//.test(t.pathname)) bad(role, href, `form posts to ${t.pathname} (not a server action or API route)`);
      }
    }
    const dead = await deadButtons(page);
    for (const d of dead) bad(role, href, `button without a handler: "${d}"`);
    const tog = await pressToggles(page, errors);
    stats.toggles += tog.length;
    for (const t of tog) bad(role, href, `toggle ${t}`);
    for (const [w, h] of [[1440, 900], [375, 812]]) {
      await page.setViewportSize({ width: w, height: h });
      await page.waitForTimeout(120);
      const o = await overflow(page);
      if (o) bad(role, href, `horizontal overflow at ${w}: ${o}`);
    }
    await page.setViewportSize({ width: 1440, height: 900 });
    for (const e of new Set(errors)) bad(role, href, `console: ${e}`);
  }
  stats.shapes = shapes.size;
  stats.visited = [...shapes.keys()].sort();
  await ctx.close();
}

const browser = await chromium.launch({ args: ['--no-proxy-server'] });
await sql`delete from app.rate_limit_hits`.catch(() => {});
for (const role of ROLES) {
  const t = Date.now();
  try { await crawlRole(browser, role); } catch (e) { bad(role, 'crawl', String(e).slice(0, 300)); }
  const s = report.roles[role] ?? {};
  console.log(`crawl ${(role + (PARTS > 1 ? ` ${PART}/${PARTS}` : '')).padEnd(10)} ${String(s.pages ?? 0).padStart(4)} pages ${String(s.links ?? 0).padStart(5)} links ${String(s.forms ?? 0).padStart(4)} forms  ${s.who ?? ''}  ${Math.round((Date.now() - t) / 1000)}s`);
}
await browser.close();
await sql.end();
report.problems = problems;
fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(report, null, 2));
if (problems.length) { console.log(problems.join('\n')); console.log(`crawl: FAILED, ${problems.length} problems`); process.exit(1); }
console.log('crawl: 0 problems');
