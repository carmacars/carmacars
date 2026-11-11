import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
// Placeholder bookings and conflicting dates (0283, 0284) end to end: a placeholder held for an insurer and the real
// rental on the same car for the same days, and a renter's request for those days. The placeholder's page says what it
// is and points at the real rental; the request's page says which booking holds the car and that the placeholder never
// counts; the calendar stacks the three bars, marks the request's dates as taken and draws the placeholder dashed.
// Fixtures are example.test only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 60_000 });
}

test('placeholder and real rental on one car: the booking pages and the calendar keep them apart', async ({ page }, info) => {
  const phone = info.project.name.startsWith('phone');
  test.setTimeout(240_000); // a phone runs three pages, axe and the agenda then the timeline: past 150 s on a busy runner
  const sql = db();
  const t = tag(), T = t.toUpperCase();
  const admin = randomUUID(), email = `ph.admin.${Date.now()}.${t}@example.test`;
  const owner = randomUUID(), ou = randomUUID(), car = randomUUID();
  const plate = `PH${T}`.slice(0, 8);
  await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${admin}, ${email}, 'Pia Admin')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  await sql`insert into users (id, email, full_name) values (${ou}, ${`ph.owner.${t}@example.test`}, 'Pat Owner')`;
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${ou}, 'individual', 'Pat Owner', 'active', ${`ph.owner.${t}@example.test`}, '416-555-0100')`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, enrollment_date)
            values (${car}, ${owner}, ${`F-${t}`}, 2023, 'Toyota', 'Corolla', ${('PH' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${plate}, 'standard', 'available', 'managed', 'transfer', true, current_date - 40)`;
  const renter = async (name: string) => {
    const [r] = await sql`insert into renters (legal_name, date_of_birth, mobile, email, identity_status) values (${name}, date '1990-05-05', '647-555-0199', ${`ph.${name.split(' ')[0]!.toLowerCase()}.${t}@example.test`}, 'verified') returning id`;
    return r!.id as string;
  };
  const rita = await renter('Rita Renter'), ivy = await renter('Ivy Insurer'), rob = await renter('Rob Request');
  const book = async (n: string, who: string, status: string, from: number, to: number, extra: { placeholder?: boolean } = {}) => {
    await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
        daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
        overage_cents_per_km, deposit_cents, blocks_calendar, is_placeholder, placeholder_reason, placeholder_by, created_by)
      values (${n}, 'standard', ${status}, ${car}, ${who}, now(), date_trunc('day', now()) + ${`${from} days 10 hours`}::interval, date_trunc('day', now()) + ${`${to} days 10 hours`}::interval,
        date_trunc('day', now()) + ${`${to} days 10 hours`}::interval, ${to - from}, 6900, 7900, 39000, 140000, 'daily', 0, 200, ${200 * (to - from)}, 25, 0, true,
        ${!!extra.placeholder}, ${extra.placeholder ? 'Insurer asked for a booking on file' : null}, ${extra.placeholder ? admin : null}, ${admin})`;
  };
  const place = `PH-P${T}`, real = `PH-R${T}`, req = `PH-Q${T}`;
  try {
    await book(place, ivy, 'confirmed', 2, 9, { placeholder: true });
    await book(real, rita, 'confirmed', 3, 6);
    await book(req, rob, 'requested', 4, 5);
    const errors = watch(page);
    await signIn(page, email);

    // the placeholder: a quiet banner instead of the next step, pointing at the real rental
    await page.goto(`/admin/bookings/${place}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('placeholder-flag')).toHaveText('placeholder');
    const banner = page.getByTestId('placeholder-banner');
    await expect(banner).toContainText('Insurer asked for a booking on file');
    await expect(banner).toContainText('Tolls, tickets and damage go to the real rental');
    await expect(banner.getByRole('link', { name: real })).toBeVisible();
    const card = page.getByTestId('date-conflicts-card');
    await expect(card.locator('[data-kind="booked"]')).toContainText(real);
    await expect(card).toContainText('nothing below keeps it off the car');
    await noOverflow(page);
    const a = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa']).include('[data-testid="placeholder-banner"]').include('[data-testid="date-conflicts-card"]').analyze();
    expect(a.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id)).toEqual([]);

    // the request: the real rental takes the car, the placeholder never counts
    await page.goto(`/admin/bookings/${req}?tab=review`, { waitUntil: 'networkidle' });
    const comp = page.getByTestId('competing');
    await expect(comp.locator('[data-kind="booked"].is-holding')).toContainText(real);
    await expect(comp.locator('[data-kind="booked"]')).toContainText('Takes the car for these dates');
    await expect(comp.locator('[data-kind="placeholder"]')).toContainText('never counts');
    await noOverflow(page);

    // the calendar: three bars stacked, the request's dates taken, the placeholder dashed
    await page.goto(`/admin/calendar?view=two&q=${plate}`, { waitUntil: 'networkidle' });
    if (phone) {
      // a phone opens on the agenda: the clash is said there too; then the timeline
      await expect(page.getByTestId('cal-agenda')).toBeVisible();
      await expect(page.getByTestId('cal-agenda-clash')).toContainText(`clashes with ${real}`);
      await page.getByRole('button', { name: 'Timeline' }).click();
    }
    // a call another test made in the last minutes shows the caller pop-up to an Admin (0970); on a phone it covers the
    // timeline, so it is closed as a person would
    for (const x of await page.getByTestId('caller-close').all()) await x.click().catch(() => undefined);
    const lane = page.getByTestId(`lane-${plate}`);
    await expect(lane).toBeVisible();
    await expect(lane.getByTestId(`bar-${req}`)).toHaveAttribute('data-clash', real);
    await expect(lane.getByTestId(`bar-${place}`)).toHaveClass(/is-placeholder/);
    await expect(lane.getByTestId(`bar-${real}`)).not.toHaveAttribute('data-clash', /./);
    const boxes = await Promise.all([place, real, req].map(async (n) => (await lane.getByTestId(`bar-${n}`).boundingBox())!));
    expect(new Set(boxes.map((b) => Math.round(b.y))).size, 'three rows, nothing drawn over anything').toBe(3);
    await lane.getByTestId(`bar-${req}`).click();
    await expect(page.getByTestId('cal-clash')).toContainText(`Clashes with ${real}`);
    const text = await page.locator('body').innerText();
    expect(text.match(/[–—]/)?.[0], 'long dash').toBeUndefined();

    // Add a rental > Placeholder: says what it is, and the calendar switch is off and cannot be turned on
    await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
    await page.getByTestId('mr-preset-dummy').click();
    await expect(page.getByTestId('mr-placeholder-note')).toContainText('never blocks the calendar');
    await expect(page.getByTestId('mr-blocks')).not.toBeChecked();
    await expect(page.getByTestId('mr-blocks')).toBeDisabled();
    await page.getByTestId('mr-preset-phone').click();
    await expect(page.getByTestId('mr-placeholder-note')).toHaveCount(0);
    await expect(page.getByTestId('mr-blocks')).toBeChecked();
    await noOverflow(page);
    expect(errors).toEqual([]);
  } finally {
    await sql`delete from bookings where vehicle_id = ${car}`.catch(() => undefined);
    await sql`delete from user_roles where user_id = ${admin}`.catch(() => undefined);
    await sql.end();
  }
});
