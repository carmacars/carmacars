// Screens for the investor deck that the guides' screenshots do not have (docs/changes/2026-10-21-investor-deck.md):
// signs in on the local stack as fictional people (example.test) and photographs the sample-car pages at 1440 x 900.
// Writes JPEGs to public/deck/. The rest of the deck's screens are the guides' (docs/guides/src/img).
//
//   BASE_URL=http://localhost:3000 DATABASE_URL=postgresql://postgres@127.0.0.1:54322/carmacars node scripts/deck-shots.mjs
//
// Local stack only (DATA_BACKEND=local): it adds sign-ins and fictional sample records (cars with service history, a
// Turo trip email, contacts typed into forms). ONLY=maintenance,phone-sign-in,... takes just those screens.
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { chromium } from '@playwright/test';
import postgres from 'postgres';

if (!process.env.PLAYWRIGHT_BROWSERS_PATH && fs.existsSync('/opt/pw-browsers')) process.env.PLAYWRIGHT_BROWSERS_PATH = '/opt/pw-browsers';
const BASE = (process.env.BASE_URL ?? 'http://localhost:3000').replace(/\/$/, '');
const OUT = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../public/deck');
const PW = 'deck screens password 1';
const ONLY = (process.env.ONLY ?? '').split(',').map((x) => x.trim()).filter(Boolean);
const want = (name) => !ONLY.length || ONLY.includes(name);
const sql = postgres(process.env.DATABASE_URL ?? 'postgresql://postgres@127.0.0.1:54322/carmacars', { max: 2, onnotice: () => {} });
const hash = (pw) => { const s = randomBytes(16); return `scrypt$${s.toString('base64')}$${scryptSync(pw, s, 64).toString('base64')}`; };

async function person(kind, name) {
  const email = `${name.toLowerCase().replace(/ /g, '.')}.${randomBytes(2).toString('hex')}@example.test`;
  const id = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'investor') await sql`insert into investors (user_id, legal_name, investor_type, status, email) values (${id}, ${name}, 'individual', 'active', ${email})`;
  return email;
}
async function signIn(page, email) {
  await page.goto(`${BASE}/sign-in`, { waitUntil: 'networkidle' });
  const nb = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await nb.isVisible().catch(() => false)) await nb.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 240_000 });
}
const day = (n) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
const save = async (page, name, clip) => {
  // a dev server's indicator and the cookie toast are not part of the screen
  const nb = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await nb.isVisible().catch(() => false)) { await nb.click({ timeout: 10_000, force: true }).catch(() => {}); await page.waitForTimeout(1500); }
  await page.addStyleTag({ content: 'nextjs-portal, [data-nextjs-toast], .toast, .toasts { display: none !important; }' }).catch(() => {});
  await page.waitForTimeout(400);
  await page.screenshot({ path: path.join(OUT, name), type: 'jpeg', quality: 80, ...(clip ? { clip } : {}) });
  console.log('deck shot', name);
};

// three visitors who accepted cookies browse a few cars each (a viewing spree, a return to one car), then Live visitors
async function liveVisitors(staff) {
  const cars = (await sql`select l.slug from vehicle_listings l join vehicles v on v.id = l.vehicle_id where l.status = 'published' and v.partner_id is null order by l.slug limit 8`).map((r) => r.slug);
  const visits = [['google', 'toronto-suv', cars.slice(0, 6)], ['instagram', 'weekend', [cars[1], cars[2], cars[1]]], ['newsletter', 'october', [cars[3]]]];
  for (const [src, camp, list] of visits) {
    const v = await newPage();
    await v.goto(`${BASE}/?utm_source=${src}&utm_campaign=${camp}`, { waitUntil: 'networkidle' });
    await v.getByRole('button', { name: 'Accept all' }).first().click({ timeout: 60_000 }).catch(() => {});
    for (const c of list) { await v.goto(`${BASE}/cars/${c}`, { waitUntil: 'load' }); await v.waitForTimeout(1500); }
  }
  await staff.goto(`${BASE}/admin/live`, { waitUntil: 'networkidle' });
  await staff.getByTestId('live-visitors').waitFor({ timeout: 60_000 }).catch(() => {});
  const later = staff.getByRole('button', { name: 'Not now' }).first();
  if (await later.isVisible().catch(() => false)) await later.click().catch(() => {});
  await staff.waitForTimeout(2000);
  await save(staff, 'live-visitors.jpg');
}


// maintenance (0089): six company cars with odometer readings and service history, so the fleet overview shows cars
// overdue, due soon and fine; then the Admin's overview and one car's Maintenance tab. The overview's count of cars
// tracked is not shown (no fleet size on the deck).
async function maintenance(page, adminEmail) {
  const [{ id: by }] = await sql`select id from users where email = ${adminEmail}`;
  const cars = [
    ['Mercedes-Benz', 'C-Class', 'C 300 4MATIC', 2022, 'Black', 41_200, [[-200, 31_900, ['oil_filter', 'fluids', 'tire_rotation']], [-300, 30_000, ['brake_inspection', 'cabin_filter']]]],
    ['BMW', 'X3', 'xDrive30i', 2023, 'White', 22_800, [[-150, 15_400, ['oil_filter', 'fluids']], [-150, 15_400, ['tire_rotation']]]],
    ['Toyota', 'RAV4', 'XLE AWD', 2022, 'Grey', 58_300, [[-40, 56_100, ['oil_filter', 'fluids', 'tire_rotation', 'brake_inspection']]]],
    ['Honda', 'Civic', 'Sport', 2023, 'Blue', 30_500, [[-170, 23_100, ['oil_filter', 'fluids']], [-330, 18_000, ['tire_rotation', 'alignment']]]],
    ['Audi', 'Q5', 'Progressiv', 2021, 'Silver', 67_900, [[-25, 66_800, ['oil_filter', 'fluids', 'brake_inspection', 'engine_air_filter']]]],
    ['Hyundai', 'Tucson', 'Preferred', 2022, 'Red', 47_600, [[-120, 41_900, ['oil_filter', 'fluids']]]]
  ];
  // a second run replaces the first run's cars (their VINs carry DK in 3rd and 4th place)
  await sql`update vehicles set retired_at = now() where supply_type = 'company' and not is_sample and vin like '__DK%' and retired_at is null`;
  let first = null;
  for (const [make, model, trim, year, colour, km, records] of cars) {
    const vin = `${make.slice(0, 2)}DK${randomBytes(7).toString('hex')}`.toUpperCase().replace(/[^A-Z0-9]/g, '7').replace(/[IOQ]/g, 'A').slice(0, 17);
    const plate = `C${randomBytes(3).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A').slice(0, 3)} ${100 + Math.floor(Math.random() * 899)}`;
    const [r] = await sql`select app.vehicle_add(${by}, ${sql.json({ supply_type: 'company', vin, plate, year, make, model, trim, colour,
      rates: { daily: 8900, weekend: 9900, weekly: 54000, monthly: 190000, deposit: 50000 } })}) as r`;
    const id = r.r.vehicle_id;
    first ??= id;
    await sql`select app.maint_add_reading(${id}, ${Math.round(km - 75 * 55)}, now() - interval '75 days', 'manual', null, ${by})`;
    await sql`select app.maint_add_reading(${id}, ${km}, now() - interval '1 day', 'manual', null, ${by})`;
    for (const [d, at, items] of records) {
      await sql`select app.maint_record(${by}, ${sql.json({ vehicle_id: id, done_on: day(d), odometer_km: at, shop: 'Dundas West Auto Service', payer: 'none', items })})`;
    }
    // the registration renews on a date; one car's renewal is close
    await sql`select app.maint_record(${by}, ${sql.json({ vehicle_id: id, done_on: day(-340), shop: 'ServiceOntario', payer: 'none', items: [{ code: 'registration', expires_on: day(make === 'Toyota' ? 12 : 200) }] })})`;
    await sql`select app.maint_refresh(${id})`;
  }
  await page.goto(`${BASE}/admin/maintenance`, { waitUntil: 'networkidle' });
  await page.getByTestId('maint-overview').waitFor({ timeout: 120_000 });
  const later = page.getByRole('button', { name: 'Not now' }).first();
  if (await later.isVisible().catch(() => false)) await later.click().catch(() => {});
  // no counts of the whole fleet: the cars tracked and the cars with no record yet (here mostly a partner's) are hidden
  await page.evaluate(() => {
    for (const e of document.querySelectorAll('p, span, div')) if (e.children.length === 0 && /\bcars tracked\b/.test(e.textContent ?? '')) e.textContent = '';
    for (const e of document.querySelectorAll('a, button, li, div')) if (/^\s*\d+\s*(with no record yet|all OK)\s*$/.test(e.textContent ?? '') && e.querySelectorAll('a, button, li, div').length === 0) e.style.display = 'none';
  });
  await save(page, 'maintenance.jpg');
  await page.goto(`${BASE}/admin/vehicles/${first}?tab=maintenance`, { waitUntil: 'networkidle' });
  await page.getByTestId('maint-odometer').waitFor({ timeout: 120_000 }).catch(() => {});
  await page.getByTestId('maint-odometer').evaluate((e) => e.scrollIntoView({ block: 'start' })).catch(() => {});
  await page.evaluate(() => window.scrollBy(0, -120));
  await save(page, 'maintenance-car.jpg');
}

// sign in with a phone number (0091): the number typed, the code texted (the local stand-in's outbox), the code step
async function phoneSignIn() {
  await sql`delete from app.rate_limit_hits where key like 'signin-%'`;
  const v = await newPage();
  await v.goto(`${BASE}/sign-in`, { waitUntil: 'networkidle' });
  await v.getByRole('button', { name: 'Necessary only' }).first().click({ timeout: 30_000 }).catch(() => {});
  await v.getByTestId('use-phone').click();
  await v.getByTestId('phone-signin').waitFor();
  await v.getByTestId('phone-number').fill('416 555 0142');
  await save(v, 'phone-sign-in.jpg');
  await v.getByTestId('phone-send').click();
  await v.getByTestId('phone-code').waitFor({ timeout: 60_000 });
  await save(v, 'phone-sign-in-code.jpg');
}

// saving contacts from unfinished forms (0090): three visitors type their details into a booking request and the
// contact form and leave; then the Admin's Leads, "Typed into forms"
async function capture(staff) {
  const cars = (await sql`select l.slug from vehicle_listings l join vehicles v on v.id = l.vehicle_id where l.status = 'published' and v.partner_id is null and v.is_sample order by l.slug limit 3`).map((r) => r.slug);
  // a second run replaces the first run's (fictional, example.test) captures
  await sql`delete from contact_captures where email like '%@example.test' and name in ('Priya Natarajan', 'Marcus Bell', 'Elena Kovacs')`;
  const people = [['Priya', 'Natarajan', '647 555 0118'], ['Marcus', 'Bell', '416 555 0163'], ['Elena', 'Kovacs', '905 555 0127']];
  for (const [i, [first, last, phone]] of people.entries()) {
    const v = await newPage();
    const email = `${first}.${last}`.toLowerCase() + `.${randomBytes(2).toString('hex')}@example.test`;
    if (i < 2) {
      await v.goto(`${BASE}/book/${cars[0]}?from=${day(30 + i * 7)}&to=${day(33 + i * 7)}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
      await v.getByRole('button', { name: 'Accept all' }).first().click({ timeout: 30_000 }).catch(() => {});
      await v.getByRole('button', { name: 'Continue to driver details' }).click();
      await v.getByRole('heading', { name: 'The driver' }).waitFor({ timeout: 60_000 });
      await v.locator('#rq-first').fill(first);
      await v.locator('#rq-last').fill(last);
      await v.locator('#rq-phone').fill(phone);
      await v.locator('#rq-email').fill(email);
      await v.locator('#rq-dobm').focus();
      await v.getByTestId('capture-note').waitFor({ timeout: 60_000 }).catch(() => {});
      if (i === 0) await save(v, 'capture-form.jpg');
    } else {
      await v.goto(`${BASE}/contact`, { waitUntil: 'networkidle' });
      await v.getByRole('button', { name: 'Accept all' }).first().click({ timeout: 30_000 }).catch(() => {});
      await v.locator('#ct-name').fill(`${first} ${last}`);
      await v.locator('#ct-email').fill(email);
      await v.locator('#ct-phone').fill(phone);
      await v.locator('#ct-msg').focus();
      await v.getByTestId('capture-note').waitFor({ timeout: 60_000 }).catch(() => {});
    }
    await v.waitForTimeout(1500);
  }
  await staff.goto(`${BASE}/admin/leads`, { waitUntil: 'networkidle' });
  const card = staff.getByTestId('captured-contacts');
  await card.waitFor({ timeout: 60_000 });
  await card.evaluate((e) => e.scrollIntoView({ block: 'start' }));
  await save(staff, 'capture-leads.jpg');
}

// smart Turo matching (0088): two identical cars, a Turo trip email that names only the model waits as "Which car is
// this?", and the pop-up with the best guesses first and the guest
async function turoMatching(staff) {
  const env = fs.readFileSync(path.resolve(path.dirname(new URL(import.meta.url).pathname), '../.env.local'), 'utf8');
  const token = createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)[1].trim()).update('carmacars-listing-worker-v1').digest('hex');
  const owner = (await sql`select owner_id from vehicles where is_sample order by created_at limit 1`)[0].owner_id;
  await sql`update vehicles set retired_at = now() where make = 'Volkswagen' and model = 'Tiguan' and retired_at is null`;
  for (const plate of ['CTRM 418', 'CTRN 552']) {
    await sql`insert into vehicles (owner_id, year, make, model, trim, colour, plate, status) values (${owner}, 2023, 'Volkswagen', 'Tiguan', 'Comfortline', 'White', ${plate}, 'onboarding')`;
  }
  const fmt = (d) => new Intl.DateTimeFormat('en-US', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(d).replace(/,(?= \d{1,2}:)/, '');
  const start = new Date(Date.now() + 9 * 86_400_000); start.setUTCHours(15, 0, 0, 0);
  const end = new Date(start.getTime() + 3 * 86_400_000);
  const trip = String(60_000_000 + Math.floor(Math.random() * 9_000_000));
  const car = 'Volkswagen Tiguan 2023';
  const raw = `From: Turo <noreply@mail.turo.com>
To: rent@carmacars.ca
Subject: Noor booked your ${car}
Date: ${new Date().toUTCString()}
Message-ID: <deck-${trip}@mail.turo.com>
MIME-Version: 1.0
Content-Type: text/html; charset="UTF-8"

<html><body><h1>Noor H. booked your ${car}</h1>
<table><tr><td>Trip start</td><td>${fmt(start)}</td></tr><tr><td>Trip end</td><td>${fmt(end)}</td></tr>
<tr><td>Car</td><td><a href="https://turo.com/ca/en/car-rental/canada/toronto-on/volkswagen/tiguan/${7_000_000 + Math.floor(Math.random() * 900_000)}">${car}</a></td></tr>
<tr><td>Guest</td><td>Noor H.</td></tr><tr><td>Reservation ID</td><td>${trip}</td></tr></table>
<p>Message Noor at +1 (416) 555-0177 if plans change.</p>
<p><a href="https://turo.com/ca/en/reservation/${trip}">View trip details</a></p></body></html>
`;
  const res = await staff.request.post(`${BASE}/api/inbound/turo`, { data: raw, headers: { authorization: `Bearer ${token}`, 'content-type': 'message/rfc822', 'x-envelope-from': 'rent+caf_=trips=in.carmacars.ca@carmacars.ca' } });
  console.log('turo email', res.status(), JSON.stringify(await res.json().catch(() => null)));
  const [e] = await sql`select id from turo_inbound_emails where message_id = ${`deck-${trip}@mail.turo.com`}`;
  await staff.goto(`${BASE}/admin/calendar-sync?pick=${e.id}#turo-review`, { waitUntil: 'networkidle' });
  await staff.getByTestId('turo-which-car').waitFor({ timeout: 60_000 });
  await staff.waitForTimeout(800);
  await save(staff, 'turo-matching.jpg');
  await staff.keyboard.press('Escape').catch(() => {});
}

// discount games (0069, 0100): a visitor who browses cars gets the wheel, played to its prize
async function games() {
  const vid = randomUUID();
  await sql`delete from app.rate_limit_hits where key like 'game-%'`;
  const c = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: 'reduce' });
  c.setDefaultTimeout(240_000);
  await c.addCookies([{ name: 'cc_vid', value: vid, url: BASE }]);
  await c.addInitScript(() => { try { if (!sessionStorage.getItem('cc_e2e_seeded')) { localStorage.setItem('cc_games_e2e', '1'); localStorage.setItem('cc_games_e2e_cfg', JSON.stringify({ car_pages: 1 })); sessionStorage.setItem('cc_e2e_seeded', '1'); } } catch { /* none */ } });
  await sql`insert into game_plays (visitor_id, game, prize, path, trigger) values (${vid}, 'wheel', ${sql.json({ key: 'pct10', percent_bps: 1000, weight: 25 })}, '/cars', 'pages')`;
  const v = await c.newPage();
  const car = (await sql`select l.slug from vehicle_listings l join vehicles v on v.id = l.vehicle_id where l.status = 'published' and v.is_sample order by l.slug limit 1`)[0].slug;
  await v.goto(`${BASE}/cars/${car}`, { waitUntil: 'load' });
  await v.getByRole('button', { name: 'Necessary only' }).first().click({ timeout: 30_000 }).catch(() => {});
  const g = v.getByTestId('game');
  await g.waitFor({ timeout: 60_000 });
  await v.waitForTimeout(800);
  await save(v, 'games.jpg');
}

// booking recovery emails: the "offer still open" reminder as a renter sees it on a phone, from the email build's
// sample render (node ../emails/build.mjs writes emails/dist with fictional sample values)
async function recovery() {
  const file = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../../emails/dist/renter_recovery_offer.html');
  if (!fs.existsSync(file)) { console.log('deck shot recovery-email.jpg skipped: run node emails/build.mjs first'); return; }
  const c = await browser.newContext({ viewport: { width: 390, height: 800 }, deviceScaleFactor: 1.54, reducedMotion: 'reduce' });
  const v = await c.newPage();
  await v.goto(`file://${file}`, { waitUntil: 'load' });
  await v.screenshot({ path: path.join(OUT, 'recovery-email.jpg'), type: 'jpeg', quality: 80 });
  console.log('deck shot', 'recovery-email.jpg');
}

const browser = await chromium.launch({ args: ['--no-proxy-server'] });
// a dev server compiles each page on its first visit
const newPage = async () => { const c = await browser.newContext({ viewport: { width: 1440, height: 900 }, deviceScaleFactor: 1, reducedMotion: 'reduce' }); c.setDefaultTimeout(240_000); return c.newPage(); };
try {
  const page = await newPage();
  if (want('public')) {
    // public pages: a landing page, a car page's add-ons, the chat
    await page.goto(`${BASE}/car-rental/toronto`, { waitUntil: 'networkidle' });
    const nb = page.getByRole('button', { name: 'Necessary only' }).first();
    if (await nb.isVisible().catch(() => false)) await nb.click();
    // the top of the page (the sample fleet's count below it is not shown)
    await save(page, 'landing.jpg', { x: 0, y: 0, width: 1440, height: 560 });
    const car = (await sql`select l.slug from vehicle_listings l where l.status = 'published' order by l.slug limit 1`)[0]?.slug;
    await page.goto(`${BASE}/cars/${car}`, { waitUntil: 'networkidle' });
    const add = page.locator('details[data-testid="car-addons"]');
    await add.waitFor({ timeout: 120_000 }).catch(() => {});
    if (await add.count()) {
      if (!(await add.evaluate((e) => e.open))) await add.locator('summary').click();
      await add.evaluate((e) => e.scrollIntoView({ block: 'center' }));
    }
    await save(page, 'addons.jpg');
  }
  if (want('partners')) {
    // partner fleets and the chauffeur service (0093): a partner car's page (the badges and the tiered rates), the
    // chauffeur page. The partner is never named on the slide.
    const pcar = (await sql`select l.slug from vehicle_listings l join vehicles v on v.id = l.vehicle_id where l.status = 'published' and v.insurance_included and v.partner_sheet_name is not null order by v.class desc, l.slug limit 1`)[0]?.slug;
    if (pcar) {
      await page.goto(`${BASE}/cars/${pcar}`, { waitUntil: 'networkidle' });
      const nb = page.getByRole('button', { name: 'Necessary only' }).first();
      if (await nb.isVisible().catch(() => false)) await nb.click();
      await save(page, 'partner-car.jpg');
    }
    await page.goto(`${BASE}/chauffeur`, { waitUntil: 'networkidle' });
    await page.locator('[data-testid="chauffeur-vehicles"]').evaluate((e) => e.scrollIntoView({ block: 'start' })).catch(() => {});
    await save(page, 'chauffeur.jpg');
  }
  if (want('chat')) {
    // a fresh visitor: the chat button shows once the cookie notice is answered
    const v = await newPage();
    await v.goto(`${BASE}/`, { waitUntil: 'networkidle' });
    await v.getByRole('button', { name: 'Necessary only' }).first().click({ timeout: 60_000 }).catch(() => {});
    const open = v.getByTestId('chat-open');
    await open.waitFor({ timeout: 240_000 });
    await open.click();
    const box = v.locator('#ccw-input');
    await box.fill('Is the C300 free next weekend, and what would 3 days cost?');
    await box.press('Enter');
    await v.getByTestId('chat-log').locator('[data-sender="ai"]').last().waitFor({ timeout: 240_000 }).catch(() => {});
    await save(v, 'chat.jpg');
  }
  if (want('phone-sign-in')) await phoneSignIn();
  if (want('games')) await games();
  if (want('recovery')) await recovery();

  // the Admin
  const admin = await person('admin', 'Sam Rivera');
  const a = await newPage();
  await signIn(a, admin);
  if (want('admin')) {
    await a.goto(`${BASE}/admin/calendar-sync`, { waitUntil: 'networkidle' });
    await save(a, 'calendar-sync.jpg');
    await a.goto(`${BASE}/admin/guide`, { waitUntil: 'networkidle' });
    await save(a, 'guide.jpg');
  }
  // live visitor signals (0086): three consenting visitors browse cars, then the Admin's Live visitors screen
  if (want('live')) await liveVisitors(a);
  if (want('capture')) await capture(a);
  if (want('turo')) await turoMatching(a);
  if (want('maintenance')) await maintenance(a, admin);
} finally {
  await browser.close();
  await sql.end();
}
