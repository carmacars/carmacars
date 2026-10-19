import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { db, noOverflow } from './helpers';

// Migration 0063 end to end, at 375 and 1440. Turo by email: an Admin marks a car as listed on Turo (the name Turo
// gives it); a Turo "booked" email forwarded by Gmail (posted to /api/inbound/turo as the Worker's email handler does)
// blocks the car with the turnaround and lists the trip; a cancellation frees it; an email whose car cannot be told
// apart waits in the review list and is resolved with "Add as a Turo trip"; Gmail's forwarding confirmation shows its
// code to the Admin; a confirmed CarmaCars booking is listed under "Block on Turo" until ticked "Done on Turo".
// Site health: /api/health answering 404 from a website older than the database reads "Waiting for the website deploy".
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const jobToken = () => {
  const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
  return createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim()).update('carmacars-listing-worker-v1').digest('hex');
};
const fmt = (d: Date) => new Intl.DateTimeFormat('en-US', { timeZone: 'America/Toronto', weekday: 'short', month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' }).format(d).replace(/,(?= \d{1,2}:)/, '');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function admin(sql: Sql) {
  const id = randomUUID(); const email = `admin.turo.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Ada Admin ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  const b = page.getByRole('button', { name: 'Necessary only' }).first();
  if (await b.isVisible().catch(() => false)) await b.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
}
/** A Turo email as Gmail forwards it (the envelope is rent+caf_=...@carmacars.ca), posted as the Worker's email handler does. */
async function forward(page: Page, raw: string) {
  const r = await page.request.post('/api/inbound/turo', { data: raw, headers: { authorization: `Bearer ${jobToken()}`, 'content-type': 'message/rfc822',
    'x-envelope-from': 'rent+caf_=trips=in.carmacars.ca@carmacars.ca', 'x-envelope-to': 'trips@in.carmacars.ca' } });
  expect(r.status()).toBe(200);
  return (await r.json()) as { ok: boolean; status: string; reason?: string; audit?: string };
}
const mail = (o: { id: string; subject: string; body: string; from?: string }) => `From: ${o.from ?? 'Turo <noreply@mail.turo.com>'}
To: rent@carmacars.ca
Subject: ${o.subject}
Date: ${new Date().toUTCString()}
Message-ID: <${o.id}@mail.turo.com>
MIME-Version: 1.0
Content-Type: text/plain; charset="UTF-8"

${o.body}
`;

test.describe.configure({ mode: 'serial' });

test('Turo by email: the car on Turo, a booked email blocks it, a cancellation frees it, an unclear one is resolved by hand, Gmail\'s code, Done on Turo', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const a = await admin(sql);
  // a car of its own for each width, with a confirmed booking ahead (for "Block on Turo")
  const cars = await sql`select v.id, app.vehicle_name(v.id) as name from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and exists (select 1 from bookings b where b.vehicle_id = v.id and b.status = 'confirmed' and b.blocks_calendar and b.return_at > now()) order by l.slug`;
  const car = cars[isPhone() ? 0 : 1]!;
  const listing = `E2E Turo ${tag()} Mercedes-Benz GLC 2021`;
  await sql`delete from turo_vehicle_links where vehicle_id = ${car.id}`;
  await sql`delete from turo_blocked_bookings where vehicle_id = ${car.id}`;

  const page = await ctx(browser);
  page.on('dialog', (d) => { void d.accept(); });
  await signIn(page, a.email);
  await page.goto('/admin/calendar-sync', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('turo-panel')).toContainText('trips@in.carmacars.ca');
  // Turo is not an iCal platform any more
  const row = page.getByTestId(`cs-car-${car.id}`);
  await row.getByText('Add a calendar link').click();
  await expect(row.getByLabel('Platform', { exact: true }).locator('option')).toHaveText(['Getaround', 'Google Calendar', 'Other']);
  await row.getByText('Add a calendar link').click();

  // the car is on Turo: the name Turo gives it
  const tc = page.getByTestId(`turo-car-${car.id}`);
  await tc.getByRole('button', { name: 'This car is on Turo' }).click();
  await tc.getByLabel('Name on Turo').fill(listing);
  await tc.getByRole('button', { name: 'Save' }).click();
  await expect(row.getByTestId('cs-msg')).toContainText('Turo emails about this car now block it', { timeout: 15_000 });
  await expect(tc).toContainText(listing);

  // Done on Turo: our confirmed booking is listed to block on Turo
  const [bk] = await sql`select id, booking_number from bookings where vehicle_id = ${car.id} and status = 'confirmed' and blocks_calendar and return_at > now() order by pickup_at limit 1`;
  const item = tc.getByTestId('turo-block-item').filter({ hasText: bk!.booking_number });
  await expect(item).toBeVisible();
  await check(page, 'admin calendar sync with Turo');
  await item.getByRole('button', { name: 'Done on Turo' }).click();
  await expect(item).toHaveCount(0, { timeout: 15_000 });
  const [ticked] = await sql`select count(*)::int n from turo_blocked_bookings where booking_id = ${bk!.id}`;
  expect(ticked!.n).toBe(1);

  // a booked email, forwarded: the car is blocked at once, with the turnaround
  const trip = String(40_000_000 + Math.floor(Math.random() * 9_000_000));
  const start = new Date(Date.now() + (400 + (isPhone() ? 0 : 9) + Math.floor(Math.random() * 20) * 20) * 86_400_000); start.setUTCHours(14, 0, 0, 0);
  const end = new Date(start.getTime() + 2 * 86_400_000);
  const booked = await forward(page, mail({ id: `e2e-${trip}-b`, subject: `Ayesha booked your ${listing}`,
    body: `Ayesha K. booked your ${listing}.\nTrip start: ${fmt(start)}\nTrip end: ${fmt(end)}\nReservation ID: ${trip}\nhttps://turo.com/ca/en/reservation/${trip}\n` }));
  expect(`${booked.status} ${booked.audit}`).toMatch(new RegExp(`^applied Booked: Turo trip ${trip}, `));
  const [blk] = await sql`select k.starts_at, k.ends_at, k.note from vehicle_calendar_blocks k join calendar_feed_events e on e.block_id = k.id
    where e.uid = ${`turo:${trip}`} and k.removed_at is null`;
  const turn = (await sql`select app.turnaround_minutes(${car.id}) m`)[0]!.m as number;
  expect(blk!.starts_at.getTime()).toBe(start.getTime() - turn * 60_000);
  expect(blk!.ends_at.getTime()).toBe(end.getTime() + turn * 60_000);
  expect(blk!.note).toBe(`Turo: Turo trip ${trip}`);
  const [av] = await sql`select public.vehicle_is_available(${car.id}, ${new Date(start.getTime() + 3_600_000).toISOString()}::timestamptz, ${new Date(end.getTime() - 3_600_000).toISOString()}::timestamptz) ok`;
  expect(av!.ok).toBe(false);
  // nothing of the email is kept but what was read
  const [log] = await sql`select excerpt, guest_first_name, status from turo_inbound_emails where message_id = ${`e2e-${trip}-b@mail.turo.com`}`;
  expect(`${log!.status} ${log!.guest_first_name} ${log!.excerpt}`).toBe('applied Ayesha null');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(tc.getByTestId('turo-trips')).toContainText(`Turo trip ${trip} (Ayesha)`);

  // the same trip cancelled: freed
  const cancelled = await forward(page, mail({ id: `e2e-${trip}-c`, subject: 'Ayesha cancelled their trip', body: `Ayesha cancelled their trip with your ${listing}. Reservation ID ${trip}.` }));
  expect(cancelled.status).toBe('applied');
  const [av2] = await sql`select public.vehicle_is_available(${car.id}, ${new Date(start.getTime() + 3_600_000).toISOString()}::timestamptz, ${new Date(end.getTime() - 3_600_000).toISOString()}::timestamptz) ok`;
  expect(av2!.ok).toBe(true);

  // an email whose car cannot be told apart: the review list, then "Add as a Turo trip"
  const trip2 = String(50_000_000 + Math.floor(Math.random() * 9_000_000));
  const unclear = await forward(page, mail({ id: `e2e-${trip2}-u`, subject: `Priya booked your Hyundai Ioniq (${trip2})`, body: `Priya booked your Hyundai Ioniq.\nTrip start: ${fmt(start)}\nTrip end: ${fmt(end)}\nReservation ID: ${trip2}\nCall Priya at 647-555-0123.\n` }));
  expect(`${unclear.status} ${unclear.reason}`).toBe('review Could not read: car');
  await page.reload({ waitUntil: 'networkidle' });
  const review = page.getByTestId('turo-review-item').filter({ hasText: `Priya booked your Hyundai Ioniq (${trip2})` });
  await expect(review).toContainText('Could not read: car');
  await expect(review).not.toContainText('647-555-0123');
  await review.getByRole('button', { name: 'Add as a Turo trip' }).click();
  await review.getByLabel('Car').selectOption(car.id);
  await review.getByRole('button', { name: 'Add this trip' }).click();
  await expect(page.getByTestId('turo-msg')).toContainText('Trip added and the email checked', { timeout: 15_000 });
  await expect(review).toHaveCount(0);
  const [res] = await sql`select e.status, e.excerpt, t.vehicle_id from turo_inbound_emails e join turo_calendar_trips t on t.id = e.turo_trip where e.message_id = ${`e2e-${trip2}-u@mail.turo.com`}`;
  expect(`${res!.status} ${res!.excerpt} ${res!.vehicle_id}`).toBe(`resolved null ${car.id}`);

  // Gmail's forwarding confirmation: the Admin sees the code
  const code = String(100_000_000 + Math.floor(Math.random() * 800_000_000));
  const g = await forward(page, `From: Gmail Team <forwarding-noreply@google.com>\nTo: trips@in.carmacars.ca\nSubject: (#${code}) Gmail Forwarding Confirmation - Receive Mail from rent@carmacars.ca\nDate: ${new Date().toUTCString()}\nMessage-ID: <gc-${code}@google.com>\n\nConfirmation code: ${code}\n\nhttps://mail-settings.google.com/mail/vf-${code}\n`);
  expect(g.status).toBe('notice');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('gmail-confirmation')).toContainText(code);
  await check(page, 'admin calendar sync with Gmail\'s code and the review list');
  await page.getByTestId('gmail-confirmation').getByRole('button', { name: 'Done, hide this' }).click();
  await expect(page.getByTestId('gmail-confirmation')).toHaveCount(0, { timeout: 15_000 });

  // clean up: the trip of the review, the tick, the link
  await sql`update turo_calendar_trips set status = 'cancelled' where trip_id = ${trip2}`;
  await sql`select app.turo_feed_refresh(${car.id})`;
  await sql`delete from turo_blocked_bookings where booking_id = ${bk!.id}`;
  await sql`delete from turo_vehicle_links where vehicle_id = ${car.id}`;
  await sql.end();
});

test('Site health: /api/health answering 404 from a website older than the database reads "Waiting for the website deploy"', async ({ browser }) => {
  test.skip(isPhone(), 'one width: the site check is shared state');
  test.setTimeout(90_000);
  const sql = db();
  const a = await admin(sql);
  await sql`update site_alerts set resolved_at = now() where check_key = 'health' and resolved_at is null`;
  await sql`select app.uptime_page_result('health', 404, '{}'::jsonb, '<html>404</html>', false, null, 60)`;
  const page = await ctx(browser);
  await signIn(page, a.email);
  await expect(page.getByTestId('check-health')).toHaveAttribute('data-status', 'waiting');
  await expect(page.getByTestId('check-health-words')).toHaveText('Waiting for the website deploy');
  await expect(page.getByTestId('check-health')).toContainText('older than the database');
  await expect(page.getByTestId('site-health-rules')).toContainText('Emails only for a real outage');
  await expect(page.getByTestId('todo-site_alerts')).toHaveCount(0);
  await check(page, 'admin to do with the health check waiting');
  // this website (the local server) answers its own health check with its marker
  const h = await page.request.get('/api/health');
  expect(h.headers()['x-carmacars-schema'] ?? (await h.json()).schema).toBe('0063');
  await sql`select app.uptime_page_result('health', 200, '{"x-carmacars-schema": "0063"}'::jsonb, '{"ok":true}', false, null, 40)`;
  await sql.end();
});
