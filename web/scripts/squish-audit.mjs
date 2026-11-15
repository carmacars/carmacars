// r48: site-wide "squished text" audit. Visits every public page and every portal page for each role at 320, 375, 768
// and 1440 and lists the text that is squeezed (see scripts/squish-lib.mjs). Needs the local stack and a running app:
//   scripts/local-db.sh up; npm run build; PORT=3000 node scripts/serve.mjs   (then, in another shell)
//   BASE_URL=http://localhost:3000 DATABASE_URL=... node scripts/squish-audit.mjs [--roles=admin,cs] [--widths=375,1440] [--out=file.json] [--only=/admin]
import { chromium } from '@playwright/test';
import postgres from 'postgres';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readdirSync, statSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PUBLIC, squishScan } from './squish-lib.mjs';

if (!process.env.PLAYWRIGHT_BROWSERS_PATH && existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const BASE = process.env.BASE_URL ?? 'http://localhost:3000';
const WIDTHS = arg('widths', '1440,768,375,320').split(',').map(Number);
const ROLES = arg('roles', 'public,admin,cs,sales,fleet,finance,field,renter,owner').split(',');
const OUT = arg('out', '');
const ONLY = arg('only', '');
const PW = 'correct horse battery';
const hash = (pw) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const sql = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 1, onnotice: () => {} });

/** The static routes under src/app/<dir> (no dynamic segments), and the dynamic route patterns as regular expressions. */
function routes(dir) {
  const stat = []; const dyn = [];
  const walk = (d, url) => {
    for (const f of readdirSync(d)) {
      const p = path.join(d, f);
      if (statSync(p).isDirectory()) { if (!f.startsWith('(') && !f.startsWith('_') && f !== 'api') walk(p, `${url}/${f}`); continue; }
      if (f !== 'page.tsx') continue;
      if (url.includes('[')) dyn.push(new RegExp('^' + url.replace(/\[[^\]]+\]/g, '[^/?#]+') + '$')); else stat.push(url || '/');
    }
  };
  walk(path.join(WEB, 'src/app', dir), `/${dir}`);
  return { stat, dyn };
}

async function mkUser(role) {
  const id = randomUUID(); // a long address and a long single-word name on purpose: they must wrap inside their boxes, not run off the edge
  const email = `squish_${role}_averylongaddressthatneverbreaks_${Date.now()}@example.test`;
  const name = `Sam ${role[0].toUpperCase()}${role.slice(1)}Averyveryverylongsurnamethatneverbreaks`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  const base = ['cs', 'sales', 'fleet', 'finance'].includes(role) ? 'va' : role;
  await sql`insert into user_roles (user_id, role) values (${id}, ${base})`;
  if (base === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, cover_functions) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${role}, '{}'::va_function[])`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  if (role === 'owner') await sql`insert into owners (user_id, owner_type, legal_name, status, email) values (${id}, 'individual', ${name}, 'active', ${email})`;
  return { email };
}

async function signIn(page, email) {
  await page.goto(`${BASE}/sign-in`, { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('#si-email').fill(email);
  await page.locator('#si-pass').fill(PW);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 150_000 });
}

const findings = new Map(); // kind|sel -> { kind, sel, text, extra, pages:Set, widths:Set }
let scanned = 0;
async function scanPage(page, role, url, dynPatterns, found) {
  await page.setViewportSize({ width: Math.min(...WIDTHS), height: 800 }); // load at the narrowest width
  const res = await page.goto(BASE + url, { waitUntil: 'load', timeout: 60_000 }).catch(() => null);
  if (!res) { console.log(`  ! ${role} ${url}: did not load`); return; }
  const here = new URL(page.url()).pathname;
  if (here !== url.split('?')[0] && /sign-in|no-access|not-an-owner|choose-portal/.test(here) && !/sign-in|no-access|choose-portal/.test(url)) return; // refused for this role
  await page.waitForTimeout(900); // portals poll their APIs, so the network never goes idle
  if (dynPatterns) {
    const hrefs = await page.$$eval('a[href^="/"]', (as) => [...new Set(as.map((a) => a.getAttribute('href').split('#')[0]))]);
    for (const h of hrefs) dynPatterns.forEach((re, i) => { if (re.test(h.split('?')[0]) && !found.has(i)) found.set(i, h); });
  }
  for (const w of [...WIDTHS].sort((a, b) => a - b)) {
    await page.setViewportSize({ width: w, height: w < 500 ? 800 : 900 });
    await page.waitForTimeout(120);
    const hits = await page.evaluate(squishScan).catch((e) => { console.log(`  ! scan ${url} @${w}: ${String(e).slice(0, 100)}`); return []; });
    scanned++;
    for (const h of hits) {
      const k = h.kind + '|' + h.sel;
      const f = findings.get(k) ?? { ...h, pages: new Set(), widths: new Set(), roles: new Set() };
      f.pages.add(here); f.widths.add(w); f.roles.add(role);
      findings.set(k, f);
    }
  }
}

const browser = await chromium.launch({ args: ['--no-proxy-server', '--force-prefers-reduced-motion'] });
const PORTAL = { admin: 'admin', cs: 'staff', sales: 'staff', fleet: 'staff', finance: 'staff', field: 'staff', renter: 'account', owner: 'owner' };
for (const role of ROLES) {
  const ctx = await browser.newContext({ viewport: { width: 1440, height: 900 }, reducedMotion: 'reduce', hasTouch: false });
  const page = await ctx.newPage();
  let list; let dyn = [];
  if (role === 'public') list = PUBLIC;
  else {
    const u = await mkUser(role);
    await signIn(page, u.email);
    const r = routes(PORTAL[role]);
    list = r.stat; dyn = r.dyn;
    if (role === 'field') list = list.filter((x) => x.startsWith('/staff/field'));
  }
  if (ONLY) list = list.filter((x) => x.startsWith(ONLY));
  const found = new Map();
  console.log(`== ${role}: ${list.length} pages`);
  for (const url of list) await scanPage(page, role, url, dyn.length ? dyn : null, found);
  for (const url of found.values()) await scanPage(page, role, url, null, null);
  await ctx.close();
}
await browser.close();
await sql.end();

const rows = [...findings.values()].sort((a, b) => b.pages.size - a.pages.size);
console.log(`\n${scanned} page scans, ${rows.length} distinct findings`);
for (const f of rows) console.log(`${f.kind.padEnd(19)} ${f.sel}\n    "${f.text}" ${f.extra} | ${f.pages.size} pages (${[...f.pages].slice(0, 2).join(', ')}) | w ${[...f.widths].join('/')} | ${[...f.roles].join(',')}`);
if (OUT) writeFileSync(OUT, JSON.stringify(rows.map((f) => ({ ...f, pages: [...f.pages], widths: [...f.widths], roles: [...f.roles] })), null, 1));
process.exit(rows.length ? 1 : 0);
