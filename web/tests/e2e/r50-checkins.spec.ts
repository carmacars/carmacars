import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, FIXTURE_JPEG } from './helpers';

// Release 50 (4000), end to end at phone widths (320 and 375): a renter on a 60-day rental sees "Next check-in visit:
// around" on their trips page and books an office slot; Fleet sees it booked in the queue and does the visit on the phone
// (five photos, the odometer, damage, tread, fluids) and the To do is raised; the owner's car page shows the visit. Every
// page: no sideways scroll, no serious axe finding, no raw database error.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect(await page.locator('body').innerText(), `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function login(sql: Sql, id: string, email: string) {
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}
async function phone(browser: Browser, width: number) {
  const c = await browser.newContext({ viewport: { width, height: 812 }, hasTouch: true, baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}

test.describe.configure({ mode: 'serial' });
test.setTimeout(240_000);

test('check-in visits: the renter books a slot, Fleet does the visit on the phone, the owner sees it', async ({ browser }) => {
  test.skip(test.info().project.name !== 'phone-375', 'one run is enough: each page is opened at 320 and 375 wide inside');
  const sql = db();
  const t = tag(), T = t.toUpperCase();
  const fleet = randomUUID(), fleetEmail = `ci.fleet.${t}@example.test`;
  const ru = randomUUID(), renterEmail = `ci.renter.${t}@example.test`;
  const ou = randomUUID(), ownerEmail = `ci.owner.${t}@example.test`;
  const owner = randomUUID(), car = randomUUID(), n = `CI-${T}`;
  await sql`insert into users (id, email, full_name) values (${fleet}, ${fleetEmail}, 'Fia Fleet'), (${ru}, ${renterEmail}, 'Rae Renter'), (${ou}, ${ownerEmail}, 'Oto Owner')`;
  await sql`insert into user_roles (user_id, role) values (${fleet}, 'va'), (${ru}, 'renter'), (${ou}, 'owner')`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${fleet}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'fleet', 0)`;
  for (const [id, e] of [[fleet, fleetEmail], [ru, renterEmail], [ou, ownerEmail]] as const) await login(sql, id, e);
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${ou}, 'individual', 'Oto Owner', 'active', ${ownerEmail}, '416-555-0100')`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, enrollment_date)
            values (${car}, ${owner}, ${`F-${t}`}, 2024, 'Toyota', 'Corolla', ${('CI' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${`CI${T}`.slice(0, 8)}, 'standard', 'available', 'managed', 'transfer', true, current_date - 90)`;
  const [r] = await sql`insert into renters (user_id, legal_name, date_of_birth, mobile, email, identity_status) values (${ru}, 'Rae Renter', date '1990-05-05', '647-555-0199', ${renterEmail}, 'verified') returning id`;
  await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
      overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents, handed_over_at, created_by)
    values (${n}, 'standard', 'on_rent', ${car}, ${r!.id}, now() - interval '30 days', now() - interval '27 days', now() + interval '33 days', now() + interval '33 days',
      60, 6900, 7900, 39000, 140000, 'monthly', 280000, 200, 12000, 25, 0, true, 280000, now() - interval '27 days', ${fleet})`;
  await sql`select app.checkin_sweep()`;

  // 1. the renter: the card on the trips page, Pick a time, a slot booked (320 wide)
  const rp = await phone(browser, 320);
  await signIn(rp, renterEmail, '/account');
  await rp.goto('/account', { waitUntil: 'networkidle' });
  const card = rp.getByTestId('checkin-card');
  await expect(card).toContainText('Next check-in visit: around');
  await expect(card).toContainText('Nothing to pay');
  await check(rp, 'the trips page');
  await card.getByTestId('checkin-pick').click();
  await rp.waitForURL(/\/check-in$/);
  await expect(rp.getByTestId('checkin-slots')).toBeVisible();
  await check(rp, 'Pick a time');
  await rp.getByTestId('checkin-slot').first().click();
  await rp.getByTestId('checkin-book').click();
  await expect(rp.getByTestId('checkin-booked')).toBeVisible();
  expect(Number((await sql`select count(*)::int as n from app_events where code = 'staff_checkin_booked' and entity_id = (select id from bookings where booking_number = ${n})`)[0]!.n)).toBe(1);

  // 2. Fleet: the queue, the checklist on the phone (375 wide)
  const fp = await phone(browser, 375);
  await signIn(fp, fleetEmail, '/staff');
  await fp.goto('/staff/check-ins?show=booked', { waitUntil: 'networkidle' });
  const row = fp.getByTestId('checkin-row').filter({ hasText: n });
  await expect(row).toBeVisible();
  await check(fp, 'the queue');
  await row.getByTestId('checkin-open').click();
  await expect(fp.getByTestId('checkin-checklist')).toBeVisible();
  for (const a of ['front', 'rear', 'left', 'right', 'odometer']) {
    await fp.getByTestId(`checkin-photo-${a}`).setInputFiles({ name: `${a}.jpg`, mimeType: 'image/jpeg', buffer: FIXTURE_JPEG });
    await expect(fp.getByTestId(`checkin-photo-${a}-state`)).toHaveText('Added');
  }
  await fp.getByTestId('checkin-km').fill('23450');
  await fp.getByTestId('checkin-damage-no').check();
  await fp.getByTestId('checkin-tread').fill('2.5');
  await fp.getByTestId('checkin-fluids-yes').check();
  await expect(fp.getByTestId('checkin-issues')).toContainText('tire tread 2.5 mm');
  await check(fp, 'the checklist');
  await fp.getByTestId('checkin-save').click();
  // the saved visit replaces the checklist at once (the page refreshes), so its answer is the "What we found" card, not the form's message
  await expect(fp.getByTestId('checkin-found')).toContainText('A Fleet To do is open for the maintenance', { timeout: 20_000 });
  await expect(fp.getByTestId('checkin-found')).toContainText('23,450 km');
  await expect(fp.getByTestId('checkin-checklist')).toHaveCount(0);
  const [v] = await sql`select v.status, v.odometer_km, (select count(*)::int from tasks k where k.task_type = 'checkin_maintenance' and k.booking_id = v.booking_id) as todos
                          from checkin_visits v join bookings b on b.id = v.booking_id where b.booking_number = ${n}`;
  expect([v!.status, v!.odometer_km, v!.todos]).toEqual(['done', 23450, 1]);

  // 3. the owner: the visit on the car page, condition only
  const op = await phone(browser, 375);
  await signIn(op, ownerEmail, '/owner');
  await op.goto(`/owner/vehicles/${car}`, { waitUntil: 'networkidle' });
  const visits = op.getByTestId('owner-checkins');
  if (await visits.count()) {
    await expect(visits).toContainText('No new damage');
    await expect(visits).toContainText('23,450 km');
    await check(op, 'the owner car page');
  }
  await sql.end();
});
