// r48: site-wide "squished text" audit. Visits every public page and every portal page for each role at 320, 375, 768,
// 1280 and 1440 and lists the text that is squeezed (see scripts/squish-lib.mjs). r48 ops: 1280 added (a laptop), and the
// people and cars the audit makes carry long names and large numbers (a long surname, a long model name, a five-figure
// amount), so a box that only fits short sample data shows up. Needs the local stack and a running app:
//   scripts/local-db.sh up; npm run build; PORT=3000 node scripts/serve.mjs   (then, in another shell)
//   BASE_URL=http://localhost:3000 DATABASE_URL=... node scripts/squish-audit.mjs [--roles=admin,cs] [--widths=375,1440] [--out=file.json] [--only=/admin]
//   --chunk=2/8      the third eighth of each role's pages (a small machine: a run per chunk, the app restarted between)
//   --seen=file.json pages a run opened are written there, and a page already in it is skipped: with the staff roles run one
//                    after the other, each staff page is read once, by the first role that may open it
import { chromium } from '@playwright/test';
import postgres from 'postgres';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readdirSync, readFileSync, statSync, writeFileSync, existsSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { PUBLIC, squishScan } from './squish-lib.mjs';

if (!process.env.PLAYWRIGHT_BROWSERS_PATH && existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const WEB = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const arg = (k, d) => (process.argv.find((a) => a.startsWith(`--${k}=`)) ?? `--${k}=${d}`).split('=')[1];
const BASE = process.env.BASE_URL ?? 'http://localhost:3000';
const WIDTHS = arg('widths', '1440,1280,768,375,320').split(',').map(Number);
const ROLES = arg('roles', 'public,admin,cs,sales,fleet,finance,field,renter,owner').split(',');
const OUT = arg('out', '');
const ONLY = arg('only', '');
const [CHUNK, CHUNKS] = arg('chunk', '0/1').split('/').map(Number);
const SEEN_FILE = arg('seen', '');
const seenPages = new Set(SEEN_FILE && existsSync(SEEN_FILE) ? JSON.parse(readFileSync(SEEN_FILE, 'utf8')) : []);
const failed = [];
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
  if (role === 'owner') {
    const [o] = await sql`insert into owners (user_id, owner_type, legal_name, status, email) values (${id}, 'individual', ${name}, 'active', ${email}) returning id`;
    await longCars(o.id);
  }
  return { email };
}

// r48 ops: long names and large numbers. Two cars with a long model name for the audit's owner, and on them a trip under
// way, one coming up, a finished one and a cancelled one, each with a five-figure rental charge ($12,345.67) and a long renter name;
// the Admin and staff lists read the same rows.
const VIN_CHARS = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
const rnd = (n) => Array.from({ length: n }, () => VIN_CHARS[Math.floor(Math.random() * VIN_CHARS.length)]).join('');
async function longCars(owner) {
  const agr = randomUUID();
  await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-SQ${rnd(6)}`}, current_date - 60, 'signed')`;
  const [r] = await sql`insert into renters (legal_name, date_of_birth, mobile, email, identity_status)
    values ('Maximiliana Wolfeschlegelsteinhausenbergerdorff-Featherstonehaugh', '1990-05-05', '647-555-0199', ${`squish_renter_${Date.now()}_${rnd(4).toLowerCase()}@example.test`}, 'verified') returning id`;
  let n = 0;
  for (const model of ['GLE 450 4MATIC Coupe Extended Wheelbase Launch Edition', 'Grand Cherokee Summit Reserve 4xe Plug-in Hybrid']) {
    const car = randomUUID();
    await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, colour)
              values (${car}, ${owner}, ${`F-SQ${rnd(5)}`}, 2024, ${n ? 'Jeep' : 'Mercedes-Benz'}, ${model}, ${`SQ${rnd(15)}`}, ${`SQ${rnd(5)}`}, 'premium', 'available', 'managed', 'transfer', true, current_date - 50, current_date - 50, 'Obsidian Black Metallic')`;
    await sql`insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status, management_mode, onboarding_method,
                insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date, signed_at)
              values (${car}, ${agr}, ${`VS-SQ${rnd(6)}`}, ${n + 1}, 'individual', 'owned_outright', 'managed', 'transfer', 45000, 2500, 10000, 3500, current_date - 50, now())`;
    await sql`insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from) values (${car}, 'signed_schedule', 45000, 2500, 3500, current_date - 50)`;
    await sql`insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
              values (${car}, 123456, 134567, 789012, 2345678, 250, 25, 500000, 7500, 7500, now() - interval '50 days')`;
    const trips = n ? [['confirmed', 9, 16], ['cancelled', 20, 23]] : [['on_rent', -2, 3], ['confirmed', 6, 9], ['closed', -20, -15]];
    for (const [status, a, z] of trips) {
      await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
                  handed_over_at, checked_in_at, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
                  rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents,
                  subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
                values (${`SQ-${rnd(8)}`}, 'standard', ${status}, ${car}, ${r.id}, now() - interval '30 days', now() + make_interval(days => ${a}), now() + make_interval(days => ${z}), now() + make_interval(days => ${z}), ${z - a},
                  ${['on_rent', 'closed'].includes(status) ? sql`now() + make_interval(days => ${a})` : null}, ${status === 'closed' ? sql`now() + make_interval(days => ${z})` : null},
                  123456, 134567, 789012, 2345678, 'daily', ${z - a}, 0, 1234567, 0, 250, ${250 * (z - a)}, 25, 500000, 1234567, 160494, 1395061)`;
    }
    n++;
  }
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
  if (!res) { console.log(`  ! ${role} ${url}: did not load`); failed.push(`${role} ${url}`); return; }
  const here = new URL(page.url()).pathname;
  if (here !== url.split('?')[0] && /sign-in|no-access|not-an-owner|choose-portal/.test(here) && !/sign-in|no-access|choose-portal/.test(url)) return; // refused for this role
  seenPages.add(url);
  await page.waitForTimeout(900); // portals poll their APIs, so the network never goes idle
  if (dynPatterns) {
    // a page that redirects once more (a moved page, a tab) is read after it settles
    const links = () => page.$$eval('a[href^="/"]', (as) => [...new Set(as.map((a) => a.getAttribute('href').split('#')[0]))]);
    const hrefs = await links().catch(async () => { await page.waitForLoadState('load').catch(() => undefined); await page.waitForTimeout(600); return links().catch(() => []); });
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
  list = [...list].sort().filter((_, i) => i % CHUNKS === CHUNK).filter((x) => !seenPages.has(x));
  const found = new Map();
  console.log(`== ${role}: ${list.length} pages`);
  for (const url of list) await scanPage(page, role, url, dyn.length ? dyn : null, found);
  for (const url of found.values()) if (!seenPages.has(url) && ![...seenPages].some((x) => dyn.some((re) => re.test(x.split('?')[0]) && re.test(url.split('?')[0])))) await scanPage(page, role, url, null, null);
  await ctx.close();
}
await browser.close();
await sql.end();

const rows = [...findings.values()].sort((a, b) => b.pages.size - a.pages.size);
console.log(`\n${scanned} page scans, ${rows.length} distinct findings`);
for (const f of rows) console.log(`${f.kind.padEnd(19)} ${f.sel}\n    "${f.text}" ${f.extra} | ${f.pages.size} pages (${[...f.pages].slice(0, 2).join(', ')}) | w ${[...f.widths].join('/')} | ${[...f.roles].join(',')}`);
if (SEEN_FILE) writeFileSync(SEEN_FILE, JSON.stringify([...seenPages].sort(), null, 1));
if (failed.length) console.log(`${failed.length} page(s) did not load: ${failed.join('; ')}`);
if (OUT) writeFileSync(OUT, JSON.stringify(rows.map((f) => ({ ...f, pages: [...f.pages], widths: [...f.widths], roles: [...f.roles] })), null, 1));
process.exit(rows.length ? 1 : failed.length ? 2 : 0);
