import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Migration 0155 end to end, at both widths: Finance settles a deposit the day after the return and the screen holds the
// whole rest back for the 7-day toll window (a release needs "Release now anyway"); a toll on the car not matched yet
// keeps the whole deposit (Finance and an Admin without the reason cannot release any of it); an Admin keeps the whole
// deposit for damage in one step, with the reason and the photos, and nothing is released.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const money = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error or code`).not.toMatch(/violates|constraint "|relation "|invalid input syntax|card_hold|carried_forward|release_hold/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'renter', va?: string) {
  const id = randomUUID(); const email = `dg.${role}.${Date.now()}.${tag()}@example.test`;
  const name = { admin: 'Ada Admin', va: 'Fay Finance', renter: 'Riley Renter' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!}, 50000)`;
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

// a booking returned yesterday: a cash deposit, no card on file, fuel on the Check-in statement
async function returnedYesterday(sql: Sql, renter: { id: string; email: string }) {
  const ahead = 200 + Math.floor(Math.random() * 300);
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  const from = ymd(new Date(Date.now() + ahead * 86_400_000)); const to = ymd(new Date(Date.now() + (ahead + 3) * 86_400_000));
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      and app.vehicle_is_available(v.id, ${`${from}T10:00:00-04:00`}::timestamptz - interval '1 day', ${`${to}T10:00:00-04:00`}::timestamptz + interval '1 day', null)
    order by random() limit 1`;
  if (!car) throw new Error('no free car');
  const req = {
    request_key: randomUUID(), vehicle_id: car.id, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: {},
    renter: { email: renter.email, full_name: 'Riley Renter', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  const id = v.booking_id;
  await sql.begin(async (t) => {
    // the trip itself is not this test's: straight to returned, yesterday
    await t`set local session_replication_role = replica`;
    await t`update bookings set status = 'returned', deposit_cents = 50000, deposit_pay_method = 'cash', card_on_file_id = null,
              handed_over_at = now() - interval '4 days', checked_in_at = now() - interval '1 day' where id = ${id}`;
    const pay = randomUUID();
    await t`insert into payments (id, booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
            select ${pay}, id, renter_id, 'deposit', 'charge', 'cash', 50000, 'succeeded', now() - interval '4 days' from bookings where id = ${id}`;
    await t`insert into deposits (booking_id, amount_cents, method, paid_method, status, hold_payment_id, taken_at, captured_cents)
            values (${id}, 50000, 'offline', 'cash', 'captured', ${pay}, now() - interval '4 days', 50000)`;
    const st = randomUUID();
    await t`insert into booking_statements (id, booking_id, statement_number, kind, issued_at) values (${st}, ${id}, ${`RS-DG${tag()}`}, 'check_in', now() - interval '2 hours')`;
    await t`insert into booking_line_items (booking_id, charge_type, description, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage, statement_id, supporting_refs)
            values (${id}, 'fuel', 'Fuel: a quarter tank', 1, 5000, 5000, true, 650, 'company_only', 'check_in', ${st}, ${sql.json({ fuel_out: 100, fuel_in: 75 })})`;
  });
  return { id, number: v.booking_number, vehicle: car.id as string };
}

test('the deposit is held for the toll window, kept whole while a toll is open, and kept for damage by an Admin', async ({ browser }, info) => {
  test.setTimeout(300_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const fin = await mkUser(sql, 'va', 'finance');
  const renter = await mkUser(sql, 'renter');
  const b = await returnedYesterday(sql, renter);
  const rest = 50000 - 5650;

  // ---- Finance, the day after the return: the toll window holds the rest back
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, fin.email, '/va');
  await page.goto(`/va/bookings/${b.number}?tab=money`, { waitUntil: 'networkidle' });
  await page.getByTestId('deposit-settle').click();
  const form = page.getByTestId('deposit-form');
  await expect(form).toBeVisible();
  await expect(page.getByTestId('deposit-window')).toContainText('Tolls and tickets can take up to 7 days');
  await expect(page.getByTestId('deposit-hold')).toHaveValue((rest / 100).toFixed(2));
  await expect(page.getByTestId('deposit-release')).toContainText('Back to the renter: $0.00');
  await check(page, 'settle, inside the toll window');
  // releasing it now needs the person's choice
  await page.getByTestId('deposit-hold').fill('0');
  await expect(page.getByTestId('deposit-release-now')).toBeVisible();
  await page.getByTestId('deposit-submit').click();
  await expect(page.getByTestId('deposit-error')).toContainText('Release now anyway');
  await page.getByTestId('deposit-hold').fill((rest / 100).toFixed(2));
  await page.getByTestId('deposit-submit').click();
  await expect(page.getByTestId('deposit-done')).toContainText(`${money(rest)} held back`);
  const [d1] = await sql`select applied_cents, held_back_cents, released_cents from deposits where booking_id = ${b.id}`;
  expect(d1).toMatchObject({ applied_cents: '5650', held_back_cents: String(rest), released_cents: '0' });

  // ---- a toll on the car during the rental, not matched yet: the whole deposit stays
  await sql`insert into toll_tickets (kind, plate, vehicle_id, occurred_at, amount_cents, status, matched_to)
            values ('toll_invoice', ${`ZZ${tag()}`}, ${b.vehicle}, now() - interval '3 days', 1200, 'logged', 'unmatched')`;
  await page.reload({ waitUntil: 'networkidle' });
  await page.getByTestId('deposit-settle').click();
  await expect(page.getByTestId('deposit-blockers')).toContainText('not matched yet');
  await page.getByTestId('deposit-hold').fill('0');
  await page.getByTestId('deposit-submit').click();
  await expect(page.getByTestId('deposit-error')).toContainText('The whole deposit stays held');
  await check(page, 'settle, a toll still open');

  // ---- an Admin: no release without the reason; Keep the whole deposit (damage)
  const ad = await ctx(browser, phone);
  const adErrors = watch(ad);
  await signIn(ad, admin.email, '/admin');
  await ad.goto(`/admin/bookings/${b.number}?tab=money`, { waitUntil: 'networkidle' });
  await ad.getByTestId('deposit-settle').click();
  await expect(ad.getByTestId('deposit-blockers')).toBeVisible();
  await ad.getByTestId('deposit-hold').fill('0');
  await expect(ad.getByTestId('deposit-override')).toBeVisible();
  await ad.getByTestId('deposit-submit').click();
  await expect(ad.getByTestId('deposit-error')).toContainText('reason');
  await ad.getByTestId('deposit-keep').click();
  await ad.getByTestId('damage-reason').fill('Dent in the rear door, left side');
  await ad.getByTestId('damage-photos').fill('Return report photo 7\nClose-up 21');
  await check(ad, 'keep the whole deposit');
  await ad.getByTestId('damage-go').click();
  await expect(ad.getByTestId('deposit-done')).toContainText('The whole deposit');
  const [line] = await sql`select amount_cents, description, statement_id is not null as issued from booking_line_items where booking_id = ${b.id} and charge_type = 'damage_at_cost'`;
  expect(line).toMatchObject({ amount_cents: String(rest), description: 'Damage: Dent in the rear door, left side', issued: true });
  const [d2] = await sql`select d.applied_cents, d.released_cents, (select count(*) from payments p where p.booking_id = d.booking_id and p.kind in ('release', 'refund'))::int as given_back from deposits d where d.booking_id = ${b.id}`;
  expect(d2).toMatchObject({ applied_cents: '50000', released_cents: '0', given_back: 0 });
  expect(errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x))).toEqual([]);
  expect(adErrors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x))).toEqual([]);
  await sql.end();
});
