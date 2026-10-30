import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 21a end to end, at both widths: the bookings search (a CC-style number, a name, a plate; Admin and the staff
// portal), and the card tools of a booking's Money tab: pairing the S700 (the simulated reader of the fake adapter),
// Hold deposit on reader, Record card payment with a Stripe id looked up, and the same-card rule of a card-coverage rental.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'renter', va?: string, name = 'Riley Renter') {
  const id = randomUUID(); const email = `r21.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${role === 'admin' ? 'Ada Admin' : 'Casey Service'})`;
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

// a confirmed booking far ahead, the renter's credit card coverage on a Visa ending 4242 (the simulated reader's card)
async function confirmedBooking(sql: Sql, renter: { id: string; email: string }, name: string) {
  const ahead = 300 + Math.floor(Math.random() * 300);
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  const from = ymd(new Date(Date.now() + ahead * 86_400_000)); const to = ymd(new Date(Date.now() + (ahead + 3) * 86_400_000));
  const [car] = await sql`select v.id, v.plate from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id) and v.plate is not null
      and app.vehicle_is_available(v.id, ${`${from}T10:00:00-04:00`}::timestamptz - interval '1 day', ${`${to}T10:00:00-04:00`}::timestamptz + interval '1 day', null)
    order by random() limit 1`;
  if (!car) throw new Error('no free car');
  const req = {
    request_key: randomUUID(), vehicle_id: car.id, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: {},
    renter: { email: renter.email, full_name: name, mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  await sql.begin(async (t) => {
    await t`set local session_replication_role = replica`;
    const [rt] = await t`select renter_id from bookings where id = ${v.booking_id}`;
    const pm = randomUUID();
    await t`insert into payment_methods (id, renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit, funding) values (${pm}, ${rt!.renter_id}, 'visa', '4242', ${name}, 12, 2030, true, 'credit')`;
    await t`insert into payment_method_secrets (payment_method_id, processor, processor_customer_id, processor_method_id, fingerprint) values (${pm}, 'stripe', 'cus_e2e', 'pm_e2e', 'fp_004242')`;
    await t`update bookings set status = 'confirmed', deposit_cents = 50000, deposit_pay_method = 'card', card_on_file_id = ${pm} where id = ${v.booking_id}`;
  });
  return { id: v.booking_id, number: v.booking_number, plate: String(car.plate) };
}

test('bookings search: a CC-style number, a name and a plate, in Admin and in the staff portal', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const cs = await mkUser(sql, 'va', 'cs');
  const name = `Quinn Searchable ${tag()}`;
  const renter = await mkUser(sql, 'renter', undefined, name);
  const b = await confirmedBooking(sql, renter, name);

  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, admin.email, '/admin');
  for (const q of [b.number.replace('-', '').toLowerCase(), name.split(' ').slice(1).join(' '), b.plate.slice(0, 3) + ' ' + b.plate.slice(3)]) {
    await page.goto(`/admin/bookings?q=${encodeURIComponent(q)}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('bookings').getByRole('link', { name: b.number }), `Admin search "${q}"`).toBeVisible();
  }
  await check(page, 'admin bookings search');

  const st = await ctx(browser, phone);
  await signIn(st, cs.email, '/staff');
  await st.goto(`/staff/bookings?q=${encodeURIComponent(b.number)}`, { waitUntil: 'networkidle' });
  await expect(st.getByTestId('booking-search').getByRole('link', { name: b.number })).toBeVisible();
  await expect(st.getByTestId('booking-search')).toContainText('Booking number');
  await st.goto(`/staff/bookings?q=${encodeURIComponent(name)}`, { waitUntil: 'networkidle' });
  await expect(st.getByTestId('booking-search').getByRole('link', { name: b.number })).toBeVisible();
  await check(st, 'staff find a booking');
  expect(errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x))).toEqual([]);
  await sql.end();
});

test('the card reader is paired, a deposit is held on it, a Dashboard payment is recorded, another card is refused on a card-coverage rental', async ({ browser }, info) => {
  test.setTimeout(300_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const renter = await mkUser(sql, 'renter');
  const b = await confirmedBooking(sql, renter, 'Riley Renter');

  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, admin.email, '/admin');
  // Settings > Card reader: Pair reader with the code the S700 shows
  await page.goto('/admin/settings/card-reader', { waitUntil: 'networkidle' });
  await page.getByTestId('pr-code').fill('simulated wpe reader');
  await page.getByTestId('pr-label').fill(`Front desk ${tag()}`);
  await page.getByTestId('pr-go').click();
  await expect(page.getByTestId('pr-message')).toContainText('is paired');
  await check(page, 'card reader settings');

  // the booking's Money tab: the rule, then the deposit held on the reader
  await page.goto(`/admin/bookings/${b.number}?tab=money`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('card-rule')).toContainText('Visa ending 4242');
  await page.getByTestId('ct-reader-hold-open').click();
  await page.getByTestId('ct-reader-go').click();
  await expect(page.getByTestId('ct-message')).toContainText('held on the card', { timeout: 30_000 });
  const [dep] = await sql`select d.status, d.method, (d.hold_expires_at < now() + interval '49 hours') as two_days from deposits d where d.booking_id = ${b.id}`;
  expect([dep?.status, dep?.method, dep?.two_days]).toEqual(['held', 'card_hold', true]);

  // Record card payment: a later charge taken in the Dashboard, its Stripe id looked up
  await page.getByTestId('ct-record-open').click();
  await page.getByTestId('ct-covers').selectOption('later');
  await page.getByTestId('ct-sid').fill(`pi_test_2500_4242_succeeded_${tag()}`);
  await page.getByTestId('ct-lookup').click();
  await expect(page.getByTestId('ct-found')).toContainText('$25.00 paid on visa ending 4242');
  await page.getByTestId('ct-record-save').click();
  await expect(page.getByTestId('ct-message')).toContainText('Recorded.');

  // another card for the rental: refused with the reason
  await page.getByTestId('ct-record-open').click();
  await page.getByTestId('ct-covers').selectOption('rental');
  await page.getByTestId('ct-last4').fill('1111');
  await page.getByTestId('ct-amount').fill('10');
  await page.getByTestId('ct-record-save').click();
  await expect(page.getByTestId('ct-message')).toContainText('the whole rental is paid on that same card (Visa ending 4242). This card ends 1111');
  await check(page, 'booking money card tools');
  expect(errors.filter((x) => !/favicon|Failed to load resource|net::ERR/.test(x))).toEqual([]);
  await sql.end();
});
