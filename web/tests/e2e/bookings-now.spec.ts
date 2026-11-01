import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
// Bookings > Now (0330) end to end at 375 and 1440: an overdue return at the top in red, a weekly rental with its next
// payment, a confirmed booking past its pickup listed as out with "pickup not recorded" and Mark picked up, a pickup
// tomorrow with its readiness, the money due and a free car. Fixtures are example.test only.
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

test('Bookings opens on Now: out, overdue first, coming back, going out, money due, free cars', async ({ page }, info) => {
  test.setTimeout(150_000);
  const sql = db();
  const t = tag(), T = t.toUpperCase();
  const admin = randomUUID(), email = `bn.admin.${Date.now()}.${t}@example.test`;
  const owner = randomUUID(), ou = randomUUID();
  const cars = [randomUUID(), randomUUID(), randomUUID(), randomUUID(), randomUUID()];
  await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${admin}, ${email}, 'Nia Admin')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  await sql`insert into users (id, email, full_name) values (${ou}, ${`bn.owner.${t}@example.test`}, 'Oli Owner')`;
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${ou}, 'individual', 'Oli Owner', 'active', ${`bn.owner.${t}@example.test`}, '416-555-0100')`;
  const models = ['C 300', 'GLE 450', 'X5', 'Model Y', 'Corolla'];
  for (const [i, car] of cars.entries()) {
    await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, enrollment_date)
              values (${car}, ${owner}, ${`F-${t}-${i}`}, 2024, ${i === 2 ? 'BMW' : i === 3 ? 'Tesla' : i === 4 ? 'Toyota' : 'Mercedes-Benz'}, ${models[i]!}, ${(`BN${i}` + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)},
                      ${`BN${i}${T}`.slice(0, 8)}, 'premium', 'available', 'managed', 'transfer', true, current_date - 60)`;
  }
  const renter = async (name: string) => {
    const [r] = await sql`insert into renters (legal_name, date_of_birth, mobile, email, identity_status) values (${name}, date '1990-05-05', '647-555-0199', ${`bn.${name.split(' ')[0]!.toLowerCase()}.${t}@example.test`}, 'verified') returning id`;
    return r!.id as string;
  };
  const rita = await renter('Rita Late'), wes = await renter('Wes Weekly'), una = await renter('Una Unrecorded'), gia = await renter('Gia Going');
  const book = async (n: string, car: string, who: string, status: string, from: string, to: string, total: number, every: string | null) => {
    await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
        daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
        overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents, pay_every, handed_over_at, created_by)
      values (${n}, 'standard', ${status}, ${car}, ${who}, now() - interval '30 days', now() + ${from}::interval, now() + ${to}::interval, now() + ${to}::interval,
        public.calc_billable_days(now() + ${from}::interval, now() + ${to}::interval),
        10000, 12000, 56000, 180000, 'daily', ${total}, 200, 200 * public.calc_billable_days(now() + ${from}::interval, now() + ${to}::interval), 25, 100000, true, ${total}, ${every}, ${status === 'on_rent' ? sql`now() + ${from}::interval` : null}, ${admin})`;
  };
  const late = `BN-L${T}`, weekly = `BN-W${T}`, unrec = `BN-U${T}`, going = `BN-G${T}`;
  try {
    await book(late, cars[0]!, rita, 'on_rent', '-5 days', '-3 hours', 60000, null);
    await book(weekly, cars[1]!, wes, 'on_rent', '-10 days', '18 days', 280000, 'weekly');
    await book(unrec, cars[2]!, una, 'confirmed', '-2 hours', '3 days', 40000, null);
    await book(going, cars[3]!, gia, 'confirmed', '30 hours', '5 days', 50000, null);
    const errors = watch(page);
    await signIn(page, email);

    await page.goto('/admin/bookings', { waitUntil: 'networkidle' });
    const board = page.getByTestId('bookings-now');
    await expect(board).toBeVisible();
    await expect(page.getByTestId('bookings-tab-now')).toHaveAttribute('aria-current', 'page');

    // Out now: the overdue return first, in red; the unrecorded pickup listed as out with Mark picked up
    const out = page.getByTestId('bn-out');
    const first = out.locator('[data-testid^="bn-out-"]').first();
    await expect(first).toHaveAttribute('data-due', 'overdue');
    await expect(out.getByTestId(`bn-out-${late}`)).toContainText('Overdue');
    await expect(out.getByTestId(`bn-out-${late}`)).toContainText('Rita Late');
    await expect(out.getByTestId(`bn-out-${weekly}`)).toContainText('a week');
    await expect(out.getByTestId(`bn-unrecorded-${unrec}`)).toContainText('Out (pickup not recorded)');
    await expect(out.getByTestId(`bn-mark-${unrec}`)).toBeVisible();
    await expect(out.getByRole('link', { name: 'Call Rita Late' }).first()).toHaveAttribute('href', 'tel:+16475550199');
    // the filter
    await page.getByTestId('bn-filter-late').click();
    await expect(out.getByTestId(`bn-out-${weekly}`)).toHaveCount(0);
    await expect(out.getByTestId(`bn-out-${late}`)).toBeVisible();
    await page.getByTestId('bn-filter-all').click();
    // Bill to: these rentals are billed to the renter
    await page.getByTestId('bn-bill-insurer').click();
    await expect(out.getByTestId(`bn-out-${late}`)).toHaveCount(0);
    await page.getByTestId('bn-bill-renter').click();
    await expect(out.getByTestId(`bn-out-${late}`)).toBeVisible();
    await page.getByTestId('bn-bill-all').click();

    await expect(page.getByTestId(`bn-back-${late}`)).toBeVisible();
    await expect(page.getByTestId(`bn-going-${going}`)).toContainText('Gia Going');
    await expect(page.getByTestId(`bn-going-${going}`).locator('.bn-tick')).toHaveCount(5);
    await expect(page.getByTestId(`bn-money-${weekly}`)).toContainText('$1,400');
    await expect(page.getByTestId('bn-free')).toContainText('Corolla');
    await expect(page.getByTestId('bn-tile-overdue')).toHaveClass(/is-urgent/);

    // Mark picked up: the deposit guard of the record-now path holds and its reason is shown
    await out.getByTestId(`bn-mark-${unrec}`).click();
    await page.getByTestId(`bn-mark-${unrec}-submit`).click();
    await expect(page.getByTestId(`bn-mark-${unrec}-form`).getByRole('alert')).toContainText(/deposit|identity|signed|coverage|agreement/i);
    await page.keyboard.press('Escape');

    await noOverflow(page);
    const a = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa']).include('[data-testid="bookings-now"]').include('[data-testid="bookings-tabs"]').analyze();
    expect(a.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(', ')}`)).toEqual([]);
    const text = await page.locator('body').innerText();
    expect(text.match(/[–—]/)?.[0], 'long dash').toBeUndefined();
    await page.screenshot({ path: `test-results/bookings-now-${info.project.name}.png`, fullPage: true });

    // an old link: the bookings on rent open All bookings > Out now, with the unrecorded pickup in it
    await page.goto('/admin/bookings?status=on_rent', { waitUntil: 'networkidle' });
    await expect(page).toHaveURL(/view=all/);
    await expect(page).toHaveURL(/status=out/);
    await expect(page.getByTestId('bookings')).toContainText(unrec);
    await expect(page.getByTestId('bookings')).toContainText(late);
    // fewer pages: Chauffeur is a tab of Requests and offers; the old address lands there
    await page.goto('/admin/chauffeur', { waitUntil: 'networkidle' });
    await expect(page).toHaveURL(/\/admin\/requests\?tab=chauffeur/);
    await expect(page.getByTestId('chauffeur-requests')).toBeVisible();
    // the live refresh answers
    const r = await page.request.get('/api/staff/bookings-now');
    expect(r.status()).toBe(200);
    expect(((await r.json()) as { out: Array<{ number: string }> }).out.some((x) => x.number === late)).toBe(true);
    expect(errors).toEqual([]);
  } finally {
    await sql`delete from bookings where vehicle_id in ${sql(cars)}`.catch(() => undefined);
    await sql`delete from user_roles where user_id = ${admin}`.catch(() => undefined);
    await sql.end();
  }
});
