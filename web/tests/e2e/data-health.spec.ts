import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
// Data health on Admin > To do (0441) at 375 and 1440: the night's run lists a confirmed booking past its pickup with
// Mark picked up and a task left with someone who no longer works here; Unassign sends it back to its queue and the line
// goes. The run is stored straight from the database (app.data_health_store, without the auto-fix, so no other test's
// records are touched). Fixtures are example.test only.
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

test('Data health: the night\'s problems on To do, each with its link and one-tap fix', async ({ page }, info) => {
  test.setTimeout(150_000);
  const sql = db();
  const t = tag(), T = t.toUpperCase();
  const admin = randomUUID(), email = `dh.admin.${Date.now()}.${t}@example.test`;
  const gone = randomUUID(), owner = randomUUID(), ou = randomUUID(), car = randomUUID();
  const number = `DH-U${T}`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${admin}, ${email}, 'Nia Admin')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  await sql`insert into users (id, email, full_name, status) values (${gone}, ${`dh.gone.${t}@example.test`}, ${`Gus Gone ${T}`}, 'suspended')`;
  await sql`insert into users (id, email, full_name) values (${ou}, ${`dh.owner.${t}@example.test`}, 'Oli Owner')`;
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${ou}, 'individual', 'Oli Owner', 'active', ${`dh.owner.${t}@example.test`}, '416-555-0100')`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, enrollment_date)
            values (${car}, ${owner}, ${`F-${t}`}, 2024, 'Toyota', 'Corolla', ${('DH' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${`DH${T}`.slice(0, 8)},
                    'standard', 'available', 'managed', 'transfer', true, current_date - 60)`;
  const [r] = await sql`insert into renters (legal_name, date_of_birth, mobile, email, identity_status) values ('Una Unrecorded', date '1990-05-05', '647-555-0199', ${`dh.una.${t}@example.test`}, 'verified') returning id`;
  try {
    await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
        daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
        overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents, created_by)
      values (${number}, 'standard', 'confirmed', ${car}, ${r!.id}, now() - interval '10 days', now() - interval '3 hours', now() + interval '3 days', now() + interval '3 days',
        public.calc_billable_days(now() - interval '3 hours', now() + interval '3 days'), 5000, 6000, 30000, 100000, 'daily', 20000, 200, 800, 25, 50000, true, 20000, ${admin})`;
    const [task] = await sql`insert into tasks (queue, task_type, title, assigned_to) values ('cs', 'staff_task', ${`Call the renter back ${T}`}, ${gone}) returning id`;
    await sql`select app.data_health_store(now(), '{}'::jsonb, ${admin})`;
    const errors = watch(page);
    await signIn(page, email);
    await page.goto('/admin', { waitUntil: 'networkidle' });
    const card = page.getByTestId('data-health');
    await expect(card).toBeVisible();
    await expect(card).toContainText('Checked');
    await expect(page.getByTestId('data-health-count')).toBeVisible();

    // the booking past its pickup: its line, its record and Mark picked up
    const pick = page.getByTestId('data-health-pickup_not_recorded');
    await pick.locator('summary').click();
    await expect(pick.getByRole('link', { name: new RegExp(number) })).toHaveAttribute('href', `/admin/bookings/${number}`);
    await expect(pick.getByRole('button', { name: 'Mark picked up' }).first()).toBeVisible();

    // the task left with someone suspended: Unassign, and it leaves the card
    const gl = page.getByTestId('data-health-inactive_assignee');
    await gl.locator('summary').click();
    const row = gl.locator('.dh__item', { hasText: `Call the renter back ${T}` });
    await expect(row).toContainText('suspended');
    await noOverflow(page);
    const a = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa']).include('[data-testid="data-health"]').analyze();
    expect(a.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).join(', ')}`)).toEqual([]);
    const text = await card.innerText();
    expect(text.match(/[–—]/)?.[0], 'long dash').toBeUndefined();
    await page.screenshot({ path: `test-results/data-health-${info.project.name}.png`, fullPage: true });
    await row.getByRole('button', { name: 'Unassign' }).click();
    await expect(gl.locator('.dh__item', { hasText: `Call the renter back ${T}` })).toHaveCount(0, { timeout: 15_000 });
    const [after] = await sql`select assigned_to from tasks where id = ${task!.id}`;
    expect(after!.assigned_to).toBeNull();
    expect(errors).toEqual([]);
  } finally {
    await sql`delete from tasks where title = ${`Call the renter back ${T}`}`.catch(() => undefined);
    await sql`delete from bookings where vehicle_id = ${car}`.catch(() => undefined);
    await sql`delete from user_roles where user_id = ${admin}`.catch(() => undefined);
    await sql.end();
  }
});
