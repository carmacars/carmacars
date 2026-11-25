import { expect, test, type Browser, type Locator, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
import { signQuo } from '../../src/features/phone/webhook';
import { SAMPLES } from '../../src/features/phone/samples';

// Release 48, operations screens (docs/changes/2026-11-20-r48-ops-screens.md), at 375 and 1440:
//   the fleet calendar with a long fleet (search, filters, groups that fold, rows drawn near the screen), a return named a
//   check-out with its time, and the two end-of-trip jobs; the owner's Bookings page (on a trip, upcoming, past, the money
//   of each booking, a filter by car, a timeline); one portal with a role switcher; Unfinished rentals only where it
//   belongs; the staff onboarding screen; the conservative, seasonal earnings calculator; and Decline opening its dialog
//   while the call-helper panel is open.
const PW = 'correct horse battery';
const SECRET = 'whsec_' + 'Y2FybWFjYXJzLWxvY2FsLXF1by13ZWJob29rLXNlY3JldA==';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const number = () => `+1416${String(2000000 + Math.floor(Math.random() * 7999999)).slice(0, 7)}`;
const clean = (e: string[]) => e.filter((x) => !/favicon|Download the React DevTools|Failed to load resource/.test(x));
// Each changed screen at the five widths of the definition of done (320, 375, 768, 1280, 1440): nothing past the window at
// any of them. With OPS_SHOTS=<folder> a screenshot of each is kept too. The desktop project does it (once is enough).
const WIDTHS = [320, 375, 768, 1280, 1440];
async function widths(page: Page, name: string, show?: Locator) {
  if (isPhone()) return;
  const was = page.viewportSize()!;
  for (const w of WIDTHS) {
    await page.setViewportSize({ width: w, height: w < 600 ? 812 : 900 });
    await expect.poll(() => page.evaluate(() => window.innerWidth)).toBe(w);
    await noOverflow(page);
    if (show) await show.scrollIntoViewIfNeeded();
    if (process.env.OPS_SHOTS) await page.screenshot({ path: `${process.env.OPS_SHOTS}/${name}-${w}.png`, animations: 'disabled' });
  }
  await page.setViewportSize(was);
}

async function mkUser(sql: Sql, role: 'admin' | 'va' | 'field' | 'owner', o: { fn?: 'cs' | 'sales' | 'fleet' | 'finance'; name?: string; also?: Array<'owner' | 'field'> } = {}) {
  const id = randomUUID(); const email = `${role}.ops.${Date.now()}.${tag()}@example.test`;
  const name = o.name ?? { admin: 'Ada Admin', va: 'Val Assistant', field: 'Fay Field', owner: 'Olive Owner' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, onboarding_exempt) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${o.fn ?? 'cs'}, true)`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function, onboarding_exempt) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver_detailer', true)`;
  for (const r of o.also ?? []) await sql`insert into user_roles (user_id, role) values (${id}, ${r})`;
  return { id, email, name };
}
async function ctx(browser: Browser, width?: number, height?: number) {
  const w = width ?? (isPhone() ? 375 : 1440);
  const c = await browser.newContext({ viewport: { width: w, height: height ?? (w < 600 ? 812 : 900) }, hasTouch: w < 600, baseURL: test.info().project.use.baseURL, reducedMotion: 'reduce' });
  return c.newPage();
}
async function signIn(page: Page, email: string, path?: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in', exact: true }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 30_000 });
  if (path) await page.goto(path, { waitUntil: 'networkidle' });
}
async function seedRequest(sql: Sql, renter: { email: string; mobile: string; name: string }, vehicle: string, fromDays: number, toDays: number) {
  const day = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
  const req = {
    request_key: randomUUID(), vehicle_id: vehicle, pickup_at: `${day(fromDays)}T10:00:00-05:00`, return_at: `${day(toDays)}T10:00:00-05:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email: renter.email, full_name: renter.name, mobile: renter.mobile, date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', null) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  return v;
}
type Delivery = { id: string; data: { resource: Record<string, unknown>; context: Record<string, unknown> } };
const rung: string[] = [];
async function ring(page: Page, ours: string, theirs: string): Promise<number> {
  rung.push(theirs);
  const body = JSON.parse(JSON.stringify(SAMPLES.callRinging)) as Delivery;
  body.id = `EV${randomUUID()}`;
  body.data.resource.id = `AC${tag()}${tag()}`;
  body.data.resource.createdAt = new Date().toISOString();
  body.data.resource.updatedAt = new Date().toISOString();
  body.data.context.participants = { workspace: [ours], external: [theirs], resolution: 'available' };
  const raw = JSON.stringify(body);
  return (await page.request.post('/api/webhooks/quo', { data: raw, headers: { 'content-type': 'application/json', ...(await signQuo(raw, SECRET, `msg_${randomUUID()}`)) } })).status();
}
test.afterEach(async () => {
  if (!rung.length) return;
  const sql = db();
  try {
    await sql`update phone_activity a set started_at = now() - interval '40 minutes', ended_at = now() - interval '35 minutes' from phone_threads t
               where t.id = a.thread_id and a.kind = 'call' and a.ended_at is null and t.number = any (${rung.splice(0)})`;
  } finally { await sql.end(); }
});

test('Admin booking: with the call-helper panel open, More actions > Decline opens its dialog and declines', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin');
  const mobile = number();
  const t = tag();
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' and v.partner_id is null and (not v.is_sample or v.sample_bookable) order by random() limit 1`;
  const from = 200 + Math.floor(Math.random() * 400);
  const req = await seedRequest(sql, { email: `dana.${t}@example.test`, mobile, name: `Dana Decline ${t}` }, car!.id as string, from, from + 3);
  const ours = (await sql<Array<{ n: string }>>`select app.phone_our_number() as n`)[0]!.n;
  // a laptop's height: the panel with the helper open is as tall as the window
  const page = await ctx(browser, undefined, isPhone() ? 812 : 800);
  const errors = watch(page);
  await signIn(page, admin.email, `/admin/bookings/${req.booking_number}`);
  expect(await ring(page, ours, mobile)).toBe(200);
  const card = page.getByTestId('caller-card').first();
  await expect(card, 'the caller pop-up, with the call helper in it').toBeVisible({ timeout: 30_000 });
  await expect(card.getByTestId('call-helper-tools')).toBeVisible();
  // the bug: the open panel sat on top of the page's buttons, so a press on More actions (or on Decline in its menu)
  // landed on the panel and nothing opened. Nothing of the page's action row is under the panel now.
  const covered = (testId: string) => page.evaluate((id) => {
    const e = document.querySelector(`[data-testid="${id}"]`)!; e.scrollIntoView({ block: 'center' });
    const r = e.getBoundingClientRect(); const t = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return t === e || e.contains(t) ? null : (t as HTMLElement | null)?.className ?? 'nothing';
  }, testId);
  if (!isPhone()) expect(await covered('more-actions-open'), 'More actions is not under the call panel').toBeNull();
  // by keyboard first (no press outside the panel, so it stays open): the menu opens and Decline is reachable beside it
  await page.getByTestId('more-actions-open').focus();
  await page.keyboard.press('Enter');
  await expect(page.getByTestId('decline')).toBeVisible();
  if (!isPhone()) {
    await expect(card, 'the call panel is still open').toBeVisible();
    if (process.env.OPS_SHOTS) await page.screenshot({ path: `${process.env.OPS_SHOTS}/booking-call-panel-menu-1440.png` });
    expect(await covered('decline'), 'Decline is not under the call panel').toBeNull();
  }
  await page.keyboard.press('Enter');
  await expect(page.getByTestId('more-actions')).not.toHaveAttribute('open', '');
  // then as a person does it, with the mouse or a finger
  await page.getByTestId('more-actions-open').click();
  const decline = page.getByTestId('decline');
  await expect(decline).toBeVisible();
  await decline.click();
  const form = page.getByTestId('decline-form');
  await expect(form, 'the Decline dialog opens').toBeVisible();
  await widths(page, 'booking-decline-dialog');
  await expect(page.locator('dialog[open]').filter({ has: form })).toHaveCount(1);
  await form.getByLabel('Reason and any alternative').fill('No car of this class for those dates. We can offer the week after.');
  await page.getByTestId('decline-submit').click();
  await expect.poll(async () => (await sql`select status from bookings where id = ${req.booking_id}`)[0]?.status, { timeout: 20_000 }).toBe('declined');
  await noOverflow(page);
  expect(clean(errors)).toEqual([]);
  await page.context().close();
  await sql.end();
});

// ---------------------------------------------------------------- fixtures: an owner with a fleet, and trips on its cars
const VIN_CHARS = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
const rnd = (n: number) => Array.from({ length: n }, () => VIN_CHARS[Math.floor(Math.random() * VIN_CHARS.length)]).join('');
async function mkOwner(sql: Sql, name = 'Olive Owner') {
  const u = await mkUser(sql, 'owner', { name });
  const owner = randomUUID(); const agr = randomUUID();
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${u.id}, 'individual', ${name}, 'active', ${u.email}, '416-555-0100')`;
  await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-OPS${rnd(6)}`}, current_date - 60, 'signed') on conflict (owner_id, kind) where status in ('draft', 'sent', 'signed') do update set id = excluded.id, agreement_number = excluded.agreement_number, agreement_date = excluded.agreement_date, status = excluded.status`;
  return { ...u, owner, agr, n: 0 };
}
async function mkCar(sql: Sql, o: { owner: string; agr: string; n: number }, model: string, cls = 'standard') {
  const car = randomUUID(); const plate = `OP${rnd(5)}`; o.n += 1;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, colour)
            values (${car}, ${o.owner}, ${`F-OP${rnd(5)}`}, 2023, 'Opsmobile', ${model}, ${`OP${rnd(15)}`}, ${plate}, ${cls}, 'available', 'managed', 'transfer', true, current_date - 50, current_date - 50, 'Grey')`;
  await sql`insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status, management_mode, onboarding_method,
              insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date, signed_at)
            values (${car}, ${o.agr}, ${`VS-OP${rnd(6)}`}, ${o.n}, 'individual', 'owned_outright', 'managed', 'transfer', 45000, 2500, 10000, 3500, current_date - 50, now())`;
  await sql`insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from) values (${car}, 'signed_schedule', 45000, 2500, 3500, current_date - 50)`;
  await sql`insert into rate_cards (vehicle_id, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, km_allowance_per_day, overage_cents_per_km, deposit_cents, delivery_fee_cents, pickup_fee_cents, effective_from)
            values (${car}, 6900, 7900, 39000, 140000, 250, 25, 50000, 7500, 7500, now() - interval '50 days')`;
  return { id: car, plate, name: `2023 Opsmobile ${model}` };
}
async function mkRenter(sql: Sql, name: string) {
  const [r] = await sql`insert into renters (legal_name, date_of_birth, mobile, email, identity_status) values (${name}, '1990-05-05', '647-555-0199', ${`ops.renter.${Date.now()}.${tag()}@example.test`}, 'verified') returning id`;
  return r!.id as string;
}
/** A booking written straight into a status (the import path), from `a` to `z` hours from now; `back` hours: when it actually came back. */
async function mkTrip(sql: Sql, car: string, renter: string, status: 'confirmed' | 'on_rent' | 'returned' | 'closed' | 'cancelled', a: number, z: number, back?: number, cents = 30000) {
  const n = `OPS-${rnd(7)}`;
  const at = (h: number) => new Date(Math.round((Date.now() + h * 3_600_000) / 60_000) * 60_000).toISOString();
  const out = ['on_rent', 'returned', 'closed'].includes(status);
  // the billable days as the database counts them (a check on the table)
  const [b] = await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
              handed_over_at, checked_in_at, daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, daily_days, weekend_days,
              rental_charge_cents, discount_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents,
              subtotal_at_booking_cents, hst_at_booking_cents, total_due_at_booking_cents)
            select ${n}, 'standard', ${status}, ${car}, ${renter}, now() - interval '30 days', ${at(a)}::timestamptz, ${at(z)}::timestamptz, ${at(z)}::timestamptz, d.n,
              ${out ? at(a) : null}::timestamptz, ${back !== undefined ? at(back) : null}::timestamptz, 10000, 12000, 56000, 180000, 'daily', d.n, 0,
              ${cents}, 0, 200, 200 * d.n, 35, 100000, ${cents}, ${Math.round(cents * 0.13)}, ${Math.round(cents * 1.13)}
              from (select public.calc_billable_days(${at(a)}::timestamptz, ${at(z)}::timestamptz) as n) d returning id`;
  return { id: b!.id as string, number: n, returnAt: at(z), backAt: back !== undefined ? at(back) : null };
}
const toronto = (iso: string) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', hour: 'numeric', minute: '2-digit' }).format(new Date(iso)).replace(/\./g, '').replace(/\s?a\s?m\b/i, ' am').replace(/\s?p\s?m\b/i, ' pm');

test('Calendar: a long fleet is found by search, filters and groups that fold; a return is a check-out with its time, and the cleaning is its own job', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin');
  const sales = await mkUser(sql, 'va', { fn: 'sales' });
  const o = await mkOwner(sql, `Opal Owner ${tag()}`);
  const cars = [];
  for (let i = 0; i < 46; i++) cars.push(await mkCar(sql, o, `Ops ${String(i).padStart(2, '0')} ${tag()}`, i % 2 ? 'premium' : 'economy'));
  const renter = await mkRenter(sql, 'Rhea Returning');
  // a trip that came back 95 minutes late and was checked clean, and one out now, both on the first car
  const done = await mkTrip(sql, cars[0]!.id, renter, 'returned', -60, -26, -26 + 95 / 60);
  await sql`insert into vehicle_clean_checks (vehicle_id, booking_id, moment, clean, checked_by, checked_at) values (${cars[0]!.id}, ${done.id}, 'after_return', true, ${admin.id}, ${new Date(Date.parse(done.backAt!) + 40 * 60_000).toISOString()})`;
  const out = await mkTrip(sql, cars[0]!.id, renter, 'on_rent', -4, 30);
  const page = await ctx(browser);
  const errors = watch(page);
  // the two weeks from four days ago, so the finished trip's return is among the days shown at any hour of the day
  const start = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(Date.now() - 4 * 86_400_000));
  await signIn(page, admin.email, `/admin/calendar?start=${start}`);
  const cal = page.getByTestId('master-calendar');
  await expect(cal).toBeVisible();
  // the toolbar: filters and the count of cars
  const count = cal.getByTestId('cal-count');
  await expect(count).toContainText(/\d+ of \d+ cars/);
  const total = Number((await count.innerText()).match(/of (\d+) cars/)![1]);
  expect(total).toBeGreaterThanOrEqual(46);
  await noOverflow(page);
  await widths(page, 'calendar-long-fleet');
  // a phone opens on the agenda once the page is live in the browser: wait for it, then ask for the timeline
  if (isPhone()) { await expect(page.getByTestId('cal-agenda')).toBeVisible(); await cal.getByRole('button', { name: 'Timeline' }).click(); }
  const grid = cal.locator('.mcal__grid');
  // rows near the screen only: the list is long, far fewer rows are in the page, and scrolling brings the later ones
  await expect(grid).toHaveAttribute('data-virtual', 'yes');
  const drawn = await grid.locator('.mcal__row').count();
  expect(drawn, 'only the rows near the screen are drawn').toBeLessThan(total);
  expect(drawn).toBeGreaterThan(3);
  const firstBefore = await grid.locator('.mcal__row').first().getAttribute('data-row');
  await grid.evaluate((g) => { g.scrollTop = g.scrollHeight; });
  const at = await grid.evaluate((g) => `scrolled to ${Math.round(g.scrollTop)} of ${g.scrollHeight}, ${g.clientHeight} high, overflow ${getComputedStyle(g).overflowY}`);
  await expect.poll(async () => grid.locator('.mcal__row').first().getAttribute('data-row'), { message: `later rows are drawn after scrolling (${at})` }).not.toBe(firstBefore);
  await expect(grid.locator('.mcal__row').last()).toBeVisible();
  await grid.evaluate((g) => { g.scrollTop = 0; });
  // search: one car
  await cal.getByLabel('Find a plate, fleet number, booking or surname').fill(cars[0]!.plate);
  await expect(count).toContainText(`1 of ${total} cars`);
  const lane = cal.getByTestId(`lane-${cars[0]!.plate}`);
  await expect(lane).toBeVisible();
  // the two jobs at the end of the finished trip: the check-out at the time the car actually came back, and the cleaning, done
  const outChip = lane.locator('[data-job="checkout"][data-done="yes"]');
  await expect(outChip).toHaveCount(1);
  await widths(page, 'calendar-jobs-one-car');
  await expect(outChip).toHaveText(`Check-out ${toronto(done.backAt!)}`);
  await expect(lane.locator('[data-job="cleaning"][data-done="yes"]')).toHaveCount(1);
  // the trip that is out: a check-out still due, and its cleaning to come
  await expect(lane.locator('[data-job="checkout"]:not([data-done])')).toHaveText(`Check-out ${toronto(out.returnAt)}`);
  await expect(lane.locator('[data-job="cleaning"]:not([data-done])')).toHaveCount(1);
  // chips never sit on top of each other
  const boxes = await lane.locator('.mcal__job').evaluateAll((els) => els.map((e) => { const r = e.getBoundingClientRect(); return [r.left, r.top, r.right, r.bottom]; }));
  for (const a of boxes) for (const b of boxes) if (a !== b) expect(a[0]! < b[2]! - 1 && b[0]! < a[2]! - 1 && a[1]! < b[3]! - 1 && b[1]! < a[3]! - 1, 'two job chips overlap').toBe(false);
  // the booking's panel: check-in and check-out, with the time it came back
  await outChip.click();
  const panel = cal.getByTestId('cal-panel');
  await expect(panel.getByRole('heading')).toHaveText('Return check-out');
  await expect(panel).toContainText(done.number);
  await panel.getByRole('button', { name: 'Close' }).click();
  await cal.getByTestId(`bar-${done.number}`).click();
  await expect(panel).toContainText('Pickup (check-in)');
  await expect(panel).toContainText('Return (check-out)');
  await expect(panel.getByTestId('cal-return-time')).toContainText('came back');
  await widths(page, 'calendar-booking-panel');
  expect((await panel.innerText()).toLowerCase()).not.toMatch(/return[^\n]*check-in/);
  await panel.getByRole('button', { name: 'Close' }).click();
  // filters: by class, by availability; a filter that is on can be cleared
  await cal.getByLabel('Find a plate, fleet number, booking or surname').fill('');
  await cal.getByTestId('cal-f-owner').selectOption(o.name);
  await expect(count).toContainText(`46 of ${total} cars`);
  await cal.getByTestId('cal-f-class').selectOption('premium');
  await expect(count).toContainText(`23 of ${total} cars`);
  await cal.getByTestId('cal-f-avail').selectOption('out');
  await expect(count).toContainText(`0 of ${total} cars`);
  await expect(cal.getByTestId('cal-empty')).toContainText('No car matches the search and filters');
  await cal.getByTestId('cal-f-class').selectOption('');
  await expect(count).toContainText(`1 of ${total} cars`);
  await cal.getByTestId('cal-clear').click();
  await expect(count).toContainText(`${total} of ${total} cars`);
  // groups that fold, remembered in this browser
  await cal.getByTestId('cal-f-owner').selectOption(o.name);
  await cal.getByTestId('cal-group').selectOption('class');
  const groups = cal.getByTestId('cal-group-row');
  await expect(groups.first()).toContainText('Economy');
  await expect(groups.first()).toContainText('23 cars');
  await widths(page, 'calendar-grouped');
  await groups.first().getByRole('button').click();
  await expect(groups.first().getByRole('button')).toHaveAttribute('aria-expanded', 'false');
  await expect(cal.getByTestId(`lane-${cars[0]!.plate}`)).toHaveCount(0);
  // with the first group folded the next heading is on the screen (only the rows near the screen are in the page)
  await expect(groups).toHaveCount(2);
  await expect(groups.nth(1)).toContainText('Premium');
  await cal.getByTestId('cal-fold-all').click();
  await expect(grid.locator('.mcal__row')).toHaveCount(0);
  await noOverflow(page);
  await page.reload({ waitUntil: 'networkidle' });
  await expect(cal.getByTestId('cal-group')).toHaveValue('class');
  if (await cal.getByRole('button', { name: 'Timeline' }).count()) await cal.getByRole('button', { name: 'Timeline' }).click();
  await expect(cal.getByTestId('cal-group-row').first().getByRole('button')).toHaveAttribute('aria-expanded', 'false');
  await cal.getByTestId('cal-fold-all').click();
  // the phone agenda names the jobs too
  if (isPhone()) {
    await cal.getByRole('button', { name: 'Agenda' }).click();
    await cal.getByLabel('Find a plate, fleet number, booking or surname').fill(cars[0]!.plate);
    await expect(cal.getByTestId('agenda-job-checkout').first()).toContainText('Return check-out');
    await expect(cal.getByTestId('agenda-job-cleaning').first()).toContainText('Post-trip cleaning');
    await noOverflow(page);
  }
  expect(clean(errors)).toEqual([]);
  await page.context().close();

  // Sales, the same calendar: no owners to filter or group by (the database does not give them), the jobs from the booking itself
  const sp = await ctx(browser);
  await signIn(sp, sales.email, `/staff/calendar?start=${start}`);
  const scal = sp.getByTestId('master-calendar');
  await expect(scal.getByTestId('cal-fleet-bar')).toBeVisible();
  await expect(scal.getByTestId('cal-f-owner')).toHaveCount(0);
  await expect(scal.getByTestId('cal-group').locator('option')).toHaveText(['No groups', 'Class', 'Car status', 'Availability']);
  await scal.getByLabel('Find a plate, fleet number, booking or surname').fill(cars[0]!.plate);
  if (isPhone()) await scal.getByRole('button', { name: 'Timeline' }).click();
  await expect(scal.getByTestId(`lane-${cars[0]!.plate}`).locator('[data-job="checkout"][data-done="yes"]')).toHaveText(`Check-out ${toronto(done.backAt!)}`);
  await noOverflow(sp);
  await widths(sp, 'calendar-sales');
  await sp.context().close();
  // tidy up: the fleet made here would lengthen every other test's calendar
  await sql`update vehicles set status = 'exited', retired_at = now() where owner_id = ${o.owner}`.catch(() => undefined);
  await sql.end();
});

test('Owner: Bookings as on a trip, upcoming and past, the money of each by what the owner may see, a filter by car and a timeline', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const o = await mkOwner(sql, `Odette Owner ${tag()}`);
  const a = await mkCar(sql, o, `Alpha ${tag()}`);
  const b = await mkCar(sql, o, `Bravo ${tag()}`);
  const renter = await mkRenter(sql, 'Remy Renter');
  const out = await mkTrip(sql, a.id, renter, 'on_rent', -30, 40, undefined, 41100);
  const next = await mkTrip(sql, a.id, renter, 'confirmed', 24 * 6, 24 * 9, undefined, 52200);
  const nextB = await mkTrip(sql, b.id, renter, 'confirmed', 24 * 3, 24 * 5, undefined, 63300);
  const past = await mkTrip(sql, b.id, renter, 'closed', -24 * 12, -24 * 9, -24 * 9, 74400);
  const page = await ctx(browser);
  const errors = watch(page);
  await signIn(page, o.email, '/owner/vehicles?tab=bookings');
  const tabs = page.getByTestId('owner-bookings');
  await expect(tabs).toBeVisible();
  // three lists with their counts; it opens on the trip under way
  await expect(page.getByTestId('owner-bookings-tab-trip')).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByTestId('owner-bookings-tab-trip')).toContainText('1');
  await expect(page.getByTestId('owner-bookings-tab-upcoming')).toContainText('2');
  await expect(page.getByTestId('owner-bookings-tab-past')).toContainText('1');
  const row = (n: string) => page.getByTestId('owner-booking-row').filter({ hasText: n });
  await expect(row(out.number)).toBeVisible();
  await expect(row(out.number).getByTestId('owner-booking-status')).toHaveText('On rent now');
  await expect(row(out.number).locator('.ow-amount')).toHaveText('$411.00');
  await expect(row(next.number)).toBeHidden();
  // the timeline: a row a car, the bookings as bars
  const tl = page.getByTestId('owner-timeline');
  await expect(tl.getByTestId('owner-timeline-row')).toHaveCount(2);
  await expect(tl.getByTestId('owner-timeline-bar')).toHaveCount(3);
  await noOverflow(page);
  await widths(page, 'owner-bookings-on-a-trip');
  // upcoming: the next pickup first, each with its money; the line above adds up what is shown
  await page.getByTestId('owner-bookings-tab-upcoming').click();
  await expect(page).toHaveURL(/when=upcoming/);
  const upcoming = page.getByTestId('owner-bookings-panel-upcoming').getByTestId('owner-booking-row');
  await expect(upcoming).toHaveCount(2);
  await expect(upcoming.first()).toContainText(nextB.number);
  await expect(page.getByTestId('owner-bookings-totals-upcoming')).toContainText('$1,155.00');
  // a booking hidden until its statement: Booked, never the amount
  await sql`update bookings set owner_visibility = 'until_statement', owner_visibility_reason = 'Price under review', owner_visibility_by = (select user_id from user_roles where role = 'admin' limit 1), owner_visibility_at = now() where id = ${next.id}`.catch(async () => {
    await sql`update bookings set owner_visibility = 'until_statement' where id = ${next.id}`; });
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.getByTestId('owner-bookings-tab-upcoming'), 'the address keeps the list').toHaveAttribute('aria-selected', 'true');
  await expect(row(next.number)).toHaveAttribute('data-view', 'booked');
  await expect(row(next.number).locator('.ow-amount')).toHaveText('Booked');
  await expect(row(next.number).getByTestId('owner-booking-money')).toContainText('The amount comes with your approved statement');
  expect(await row(next.number).innerText()).not.toContain('522');
  await expect(page.getByTestId('owner-bookings-totals-upcoming')).toContainText('$633.00');
  await expect(page.getByTestId('owner-bookings-totals-upcoming')).toContainText('1 with your statement');
  await widths(page, 'owner-bookings-upcoming');
  // filter by car: the lists and the timeline follow, and the list chosen is kept
  await page.getByTestId('owner-bookings-car').filter({ hasText: b.name }).click();
  await page.waitForURL(/car=/);
  await expect(page.getByTestId('owner-bookings-tab-upcoming')).toHaveAttribute('aria-selected', 'true');
  await expect(page.getByTestId('owner-bookings-tab-trip')).toContainText('0');
  await expect(page.getByTestId('owner-bookings-panel-upcoming').getByTestId('owner-booking-row')).toHaveCount(1);
  await expect(page.getByTestId('owner-timeline').getByTestId('owner-timeline-row')).toHaveCount(1);
  // past: the finished trip, and the last six weeks
  await page.getByTestId('owner-bookings-tab-past').click();
  await expect(row(past.number).getByTestId('owner-booking-status')).toHaveText('Completed');
  await expect(row(past.number).locator('.ow-amount')).toHaveText('$744.00');
  await expect(page.getByTestId('owner-timeline-past')).toBeVisible();
  await widths(page, 'owner-bookings-past');
  // an empty list says so in plain words
  await page.getByTestId('owner-bookings-tab-trip').click();
  await expect(page.getByTestId('owner-bookings-empty-trip')).toContainText('No car is out right now');
  // the keyboard moves between the lists
  await page.getByTestId('owner-bookings-tab-trip').focus();
  await page.keyboard.press('ArrowRight');
  await expect(page.getByTestId('owner-bookings-tab-upcoming')).toHaveAttribute('aria-selected', 'true');
  await noOverflow(page);
  expect(clean(errors)).toEqual([]);
  await page.context().close();
  await sql`update vehicles set status = 'exited', retired_at = now() where owner_id = ${o.owner}`.catch(() => undefined);
  await sql.end();
});

test('Unfinished rentals: on the Admin\'s and Sales\' Today and Bookings only; the forms show one\'s own', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin');
  const sales = await mkUser(sql, 'va', { fn: 'sales' });
  const cs = await mkUser(sql, 'va', { fn: 'cs' });
  const who = `Dara Draft ${tag()}`;
  const [d] = await sql`select app.draft_save(${admin.id}, ${sql.json({ kind: 'rental', title: who, data: { f: { full_name: who } } })}) v`;
  const id = (d!.v as { id: string }).id;
  const page = await ctx(browser);
  const errors = watch(page);
  await signIn(page, admin.email, '/admin');
  // Today and Bookings carry the section, with what the draft still needs and one button
  for (const path of ['/admin', '/admin/bookings']) {
    await page.goto(path, { waitUntil: 'networkidle' });
    const r = page.getByTestId('unfinished-row').filter({ hasText: who });
    await expect(r, path).toBeVisible();
    await expect(r).toContainText('You');
    await expect(r).toContainText('Still missing');
    await expect(r.getByRole('link', { name: 'Finish it' })).toHaveAttribute('href', `/admin/bookings/new?draft=${id}`);
    await noOverflow(page);
    await widths(page, `unfinished-admin-${path === '/admin' ? 'today' : 'bookings'}`);
  }
  // the forms no longer carry everyone's list: one line with the person's own
  for (const path of ['/admin/bookings/new', '/admin/offers/new']) {
    await page.goto(path, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('unfinished-rentals'), path).toHaveCount(0);
  }
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('my-draft-link').filter({ hasText: who })).toHaveAttribute('href', `/admin/bookings/new?draft=${id}`);
  await widths(page, 'unfinished-own-line-on-the-form');
  await page.context().close();
  // Sales: Today and Bookings; someone else's draft is not "theirs" on the form
  const sp = await ctx(browser);
  await signIn(sp, sales.email, '/staff/today');
  await expect(sp.getByTestId('unfinished-row').filter({ hasText: who })).toContainText('Ada Admin');
  await widths(sp, 'unfinished-sales-today');
  await sp.goto('/staff/bookings', { waitUntil: 'networkidle' });
  await expect(sp.getByTestId('unfinished-row').filter({ hasText: who })).toBeVisible();
  await noOverflow(sp);
  await sp.goto('/staff/bookings/new', { waitUntil: 'networkidle' });
  await expect(sp.getByTestId('unfinished-rentals')).toHaveCount(0);
  await expect(sp.getByTestId('my-drafts')).toHaveCount(0);
  await sp.context().close();
  // customer service: not on their Today
  const cp = await ctx(browser);
  await signIn(cp, cs.email, '/staff/today');
  await expect(cp.getByTestId('digest')).toBeVisible();
  await expect(cp.getByTestId('unfinished-rentals')).toHaveCount(0);
  await cp.context().close();
  expect(clean(errors)).toEqual([]);
  await sql`update rental_drafts set status = 'discarded' where id = ${id}`;
  await sql.end();
});

test('One portal: Sales, Field work and Owner on one account switch from any frame; onboarding shows the step to do now', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const p = await mkUser(sql, 'va', { fn: 'sales', name: 'Robin Roles', also: ['field', 'owner'] });
  await sql`update staff_profiles set functions = array['sales', 'field'] where user_id = ${p.id}`.catch(() => undefined);
  await sql`insert into owners (user_id, owner_type, legal_name, status, email, phone) values (${p.id}, 'individual', 'Robin Roles', 'active', ${p.email}, '416-555-0100')`;
  const page = await ctx(browser);
  const errors = watch(page);
  await signIn(page, p.email);
  expect(new URL(page.url()).pathname, 'no chooser stop').toBe('/staff');
  const sw = page.getByTestId('role-switch');
  await expect(sw.locator('.rsw__role')).toHaveText(['Sales', 'Field work', 'Owner']);
  await expect(sw.getByRole('button', { name: 'Sales' })).toHaveAttribute('aria-pressed', 'true');
  await noOverflow(page);
  await widths(page, 'roles-staff-frame');
  // every role is a full-size target
  for (const h of await sw.locator('.rsw__role').evaluateAll((els) => els.map((e) => e.getBoundingClientRect().height))) expect(h).toBeGreaterThanOrEqual(40);
  await sw.getByRole('link', { name: 'Field work' }).click();
  await page.waitForURL((u) => u.pathname === '/staff/field');
  await expect(page.getByTestId('role-switch').getByRole('link', { name: 'Field work' })).toHaveAttribute('aria-current', 'true');
  // merged navigation: a page of another role from here
  const nav = page.getByTestId('role-nav');
  await nav.locator('summary').click();
  await expect(nav.getByRole('link', { name: 'Cars' })).toHaveAttribute('href', '/owner/vehicles');
  await widths(page, 'roles-merged-navigation');
  await nav.getByRole('link', { name: 'Requests and offers' }).click();
  await page.waitForURL((u) => u.pathname === '/staff/requests');
  await expect(page.getByTestId('role-switch').getByRole('button', { name: 'Sales' })).toHaveAttribute('aria-pressed', 'true');
  await page.getByTestId('role-switch').getByRole('link', { name: 'Owner', exact: true }).click();
  await page.waitForURL((u) => u.pathname === '/owner');
  await expect(page.getByTestId('role-switch').getByRole('link', { name: 'Owner', exact: true })).toHaveAttribute('aria-current', 'true');
  await noOverflow(page);
  await widths(page, 'roles-owner-frame');
  // permissions as they were: Admin is still refused
  await page.goto('/admin/calendar');
  await expect(page.getByTestId('no-access')).toBeVisible();
  expect(clean(errors)).toEqual([]);
  await page.context().close();

  // a new hire on Welcome: one card asks for something, with one large button (or says plainly there is nothing to press yet)
  const hire = await mkUser(sql, 'va', { fn: 'cs', name: 'Nia Newhire' });
  await sql`update staff_profiles set onboarding_exempt = false where user_id = ${hire.id}`;
  const hp = await ctx(browser);
  await signIn(hp, hire.email);
  await hp.goto('/staff/welcome', { waitUntil: 'networkidle' });
  const welcome = hp.getByTestId('staff-welcome');
  await expect(welcome).toBeVisible();
  const nextCards = welcome.locator('ol > li.pt-card--next');
  await expect(nextCards).toHaveCount(1);
  const look = await nextCards.evaluate((li) => {
    const cs = getComputedStyle(li); const tag = getComputedStyle(li, '::before').content; const none = getComputedStyle(li, '::after').content;
    const btn = li.querySelector('.btn--primary') as HTMLElement | null;
    return { border: cs.borderTopWidth, tag, none, btn: btn ? btn.getBoundingClientRect().height : null, any: !!li.querySelector('.btn, button') };
  });
  expect(look.border).toBe('2px');
  expect(look.tag).toContain('Do this now');
  if (look.btn !== null) expect(look.btn, 'the primary button of the step is large').toBeGreaterThanOrEqual(48);
  if (!look.any) expect(look.none, 'a step with nothing to press says so').toContain('Nothing to press here yet');
  await noOverflow(hp);
  await widths(hp, 'onboarding-welcome');
  await hp.context().close();
  await sql.end();
});

// a small real JPEG (a grey square): a photo the server accepts and stores; nothing is printed on it to read
const GREY_JPEG = Buffer.from('/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/wAALCAAIAAgBAREA/8QAFAABAAAAAAAAAAAAAAAAAAAACP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAD8AVN//2Q==', 'base64');

test('Pickup identity check: optional on the check-in; a card that does not match flags Fleet and Admin and marks the booking, and nothing is blocked', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin');
  const o = await mkOwner(sql, `Ida Owner ${tag()}`);
  const car = (await mkCar(sql, o, `Idcheck ${tag()}`)).id;
  const name = `Rita Renter ${tag()}`;
  const renter = await mkRenter(sql, name);
  const trip = await mkTrip(sql, car, renter, 'confirmed', 1, 49);
  const [d] = await sql`insert into drivers (renter_id, full_name) values (${renter}, ${name}) returning id`;
  await sql`insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, licence_number, licence_class, licence_issuer, licence_expiry)
            values (${trip.id}, ${d!.id}, 'renter', ${name}, '1990-05-05', 'R1234-56789-01234', 'G', 'ON', '2031-05-05')`;
  const [pm] = await sql`insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name) values (${renter}, 'visa', '4242', ${name}) returning id`;
  await sql`update bookings set card_on_file_id = ${pm!.id} where id = ${trip.id}`;

  const page = await ctx(browser);
  await signIn(page, admin.email, `/admin/bookings/${trip.number}`);
  // never checked: no mark on the booking
  await expect(page.getByTestId('pickup-identity-mark')).toHaveCount(0);
  await page.getByTestId('one-screen').locator('summary').first().click();
  const step = page.getByTestId('pickup-identity');
  await expect(step).toBeVisible();
  // optional and folded: the check-in's own button is there whether or not the step is opened
  await expect(step.getByTestId('pid-open')).toContainText('Optional');
  await step.getByTestId('pid-open').click();
  await expect(step.getByTestId('pid-card-on-file')).toHaveText(`Visa ending in 4242, in the name of ${name}`);
  await expect(step.getByTestId('pid-check')).toBeDisabled();
  await widths(page, 'pickup-identity-step', step);
  // the licence they are holding, and the card they show does not end in the digits on file
  await step.getByTestId('pid-front').setInputFiles({ name: 'licence.jpg', mimeType: 'image/jpeg', buffer: GREY_JPEG });
  await expect(step.getByTestId('pid-front-state')).toContainText('Photo ready');
  await step.getByTestId('pid-last4-no').check();
  await step.getByTestId('pid-cname-yes').check();
  await step.getByTestId('pid-check').click();
  const res = step.getByTestId('pid-result');
  await expect(res).toHaveAttribute('data-outcome', 'mismatch', { timeout: 60_000 });
  await expect(res).toContainText('Possible wrong person at pickup');
  await expect(res).toContainText('The card shown does not end in 4242');
  await expect(step.getByTestId('pid-r-card_last4')).toHaveText('Does not match');
  await expect(step.getByTestId('pid-r-card_name')).toHaveText('Matches');
  await expect(step.getByTestId('pid-marked')).toBeVisible();
  for (const text of await step.allInnerTexts()) expect(text).not.toMatch(/[—–]/);

  // Fleet and Admin each have the urgent To do; the photo is kept as a pickup photo; the booking is as it was
  const tasks = await sql`select queue, priority, title from tasks where booking_id = ${trip.id} and task_type = 'pickup_identity' order by queue`;
  expect(tasks.map((t) => `${t.queue}:${t.priority}`)).toEqual(['admin:urgent', 'fleet:urgent']);
  expect(tasks[0]!.title).toBe(`Possible wrong person at pickup: ${trip.number}`);
  const [up] = await sql`select count(*)::int as n from verification_uploads where booking_id = ${trip.id} and kind = 'licence_front_pickup' and status = 'at_pickup'`;
  expect(up!.n).toBe(1);
  const [bk] = await sql`select status::text as status from bookings where id = ${trip.id}`;
  expect(bk!.status).toBe('confirmed');
  const [kept] = await sql`select card_last4, read_number from pickup_identity_checks where booking_id = ${trip.id}`;
  expect(kept!.card_last4).toBeNull();

  // the booking is marked for anyone who opens it, until the To do's are done
  await page.goto(`/admin/bookings/${trip.number}`);
  const mark = page.getByTestId('pickup-identity-mark');
  await expect(mark).toHaveAttribute('data-marked', 'yes');
  await expect(mark).toContainText('Possible wrong person at pickup');
  await widths(page, 'pickup-identity-mark', mark);
  await sql`update tasks set status = 'done', completed_at = now() where booking_id = ${trip.id} and task_type = 'pickup_identity'`;
  await page.reload();
  await expect(page.getByTestId('pickup-identity-mark')).toHaveAttribute('data-marked', 'no');
  await page.context().close();
  await sql`update vehicles set status = 'exited', retired_at = now() where owner_id = ${o.owner}`.catch(() => undefined);
  await sql.end();
});

test('List your car: the earnings calculator is conservative and seasonal, with a clear disclaimer, at every width', async ({ browser }) => {
  test.setTimeout(180_000);
  const page = await ctx(browser);
  const errors = watch(page);
  await page.goto('/list-your-car', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const calc = page.getByTestId('earnings-calculator').first();
  await calc.scrollIntoViewIfNeeded();
  await calc.getByTestId('ecalc-year').selectOption({ index: 3 });
  await calc.getByTestId('ecalc-make').selectOption('__other');
  await calc.getByTestId('ecalc-make').fill('Toyota');
  await calc.getByTestId('ecalc-model').fill('Corolla');
  await expect(page.getByTestId('ecalc-monthly')).toBeVisible();
  // 12 days in an average month from the start; the year is less than twelve of the busiest month
  await expect(page.getByTestId('ecalc-days-out')).toHaveText('12 days');
  const bars = page.getByTestId('ecalc-season').locator('li');
  await expect(bars).toHaveCount(12);
  const days = (await bars.locator('.ecalc__bar-n').allInnerTexts()).map(Number);
  expect(Math.max(...days.slice(5, 8)), 'summer is the busiest').toBe(Math.max(...days));
  expect(Math.min(...days), 'a shoulder month is the slowest').toBe(Math.min(days[2]!, days[3]!, days[9]!, days[10]!));
  expect(Math.min(days[11]!, days[0]!, days[1]!), 'winter is slow, above the slowest').toBeGreaterThanOrEqual(Math.min(...days));
  const val = async (id: string) => Number(await page.getByTestId(id).getAttribute('data-value'));
  const rate = Number((await page.getByTestId('ecalc-result').locator('.ecalc__kicker').innerText()).match(/\$([\d,]+) a day listed/)![1]!.replace(/,/g, ''));
  expect(await val('ecalc-monthly'), 'far under 18 days at the full rate').toBeLessThan(rate * 18 * 0.7 * 0.75);
  expect(await val('ecalc-yearly')).toBeLessThan(rate * Math.max(...days) * 0.7 * 12);
  const note = page.getByTestId('ecalc-disclaimer');
  await expect(note).toContainText('A rough estimate, not a promise.');
  await expect(note).toContainText('Some months a car earns little or nothing');
  await note.scrollIntoViewIfNeeded();
  await expect(note).toBeVisible();
  await noOverflow(page);
  await widths(page, 'earnings-calculator');
  expect(clean(errors)).toEqual([]);
  await page.context().close();
});
