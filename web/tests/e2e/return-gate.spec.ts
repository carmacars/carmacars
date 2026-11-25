import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 50 (migration 4730; live incident CC-10597): a renter whose documents are still in review and whose pickup was
// never recorded (confirmed, after the pickup time) is never told to upload documents first: the booking offers the
// return, the return page explains it plainly, and the report records the pickup at the booked time with Fleet's To dos.
// Fictional people only (example.test).
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

test('return with documents in review and no recorded pickup', async ({ page }) => {
  test.setTimeout(150_000);
  const errors = watch(page);
  const sql = db();
  const t = randomBytes(3).toString('hex'), T = t.toUpperCase();
  const user = randomUUID(), owner = randomUUID(), ou = randomUUID(), car = randomUUID();
  const email = `rg.${Date.now()}.${t}@example.test`;
  const n = `RG-${T}`;
  try {
    await sql`delete from app.rate_limit_hits`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${user}, ${email}, ${hash(PW)})`;
    await sql`select public.register_account(${user}, ${email}, 'Rami Return', null)`;
    const [r] = await sql`select id from renters where user_id = ${user}`;
    await sql`update renters set identity_status = 'pending' where id = ${r!.id}`;
    await sql`insert into users (id, email, full_name) values (${ou}, ${`rg.owner.${t}@example.test`}, 'Ola Owner')`;
    await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone) values (${owner}, ${ou}, 'individual', 'Ola Owner', 'active', ${`rg.owner.${t}@example.test`}, '416-555-0100')`;
    await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, enrollment_date)
              values (${car}, ${owner}, ${`F-${t}`}, 2015, 'Cadillac', 'CTS', ${('RG' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${`RG${T}`.slice(0, 8)}, 'premium', 'available', 'managed', 'transfer', true, current_date - 60)`;
    await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
        daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
        overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents)
      values (${n}, 'standard', 'confirmed', ${car}, ${r!.id}, now() - interval '2 days', now() - interval '1 day', now() + interval '1 day', now() + interval '1 day',
        2, 10000, 12000, 56000, 180000, 'daily', 20000, 200, 400, 25, 30000, true, 20000)`;
    const [b] = await sql`select id, return_link_token, pickup_at from bookings where booking_number = ${n}`;
    const [d] = await sql`select id from drivers where renter_id = ${r!.id} order by is_account_holder desc limit 1`;
    if (d) {
      await sql`insert into booking_drivers (booking_id, driver_id, role, full_name, date_of_birth, age_at_pickup, age_band)
                values (${b!.id}, ${d.id}, 'renter', 'Rami Return', date '1990-05-05', 36, '26_plus')`;
      for (const [kind, dk] of [['licence_front', 'id_front'], ['licence_back', 'id_back'], ['selfie', 'face_photo']] as const) {
        const [doc] = await sql`insert into documents (kind, storage_bucket, storage_path, booking_id) values (${dk}, 'documents', ${`rg/${t}/${kind}.jpg`}, ${b!.id}) returning id`;
        await sql`insert into verification_uploads (booking_id, driver_id, kind, document_id, status) values (${b!.id}, ${d.id}, ${kind}, ${doc!.id}, 'submitted')`;
      }
    }

    // the booking page: the return first, never "upload your documents first"
    await signIn(page, email, `/account/bookings/${n}`);
    await page.waitForURL((u) => u.pathname.startsWith(`/account/bookings/${n}`), { timeout: 60_000 });
    await expect(page.getByTestId('action-returned')).toBeVisible();
    await expect(page.getByTestId('booking-next-step')).toContainText('Return');
    await expect(page.getByTestId('booking-next-step')).not.toContainText(/upload your (licence|documents)/i);
    await noOverflow(page);

    // the return page explains it plainly and takes the report
    await page.goto(`/returned/${b!.return_link_token}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('returned-pickup-not-recorded')).toContainText('We never recorded your pickup');
    await page.getByTestId('returned-submit').click();
    await expect(page.getByTestId('returned-done')).toBeVisible({ timeout: 30_000 });
    await noOverflow(page);

    const [after] = await sql`select status::text, handed_over_at = pickup_at as at_booked, return_state from bookings where id = ${b!.id}`;
    expect(after!.status).toBe('on_rent');
    expect(after!.at_booked).toBe(true);
    expect(after!.return_state).toBe('returned_pending_confirmation');
    const [o] = await sql`select count(*)::int n from booking_overrides where booking_id = ${b!.id} and action = 'pickup' and status = 'used'`;
    expect(o!.n).toBe(1);
    const tasks = await sql`select task_type from tasks where booking_id = ${b!.id}`;
    const types = tasks.map((x) => x.task_type as string);
    expect(types).toContain('pickup_not_recorded');
    expect(types).toContain('return_claim_review');
    if (d) expect(types).toContain('docs_review_after_return');
    expect(errors()).toEqual([]);
  } finally {
    await sql.end();
  }
});
