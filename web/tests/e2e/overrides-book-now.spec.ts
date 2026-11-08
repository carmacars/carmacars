import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0770 end to end: an Admin sends an offer with Book it now (the booking waits for payment at once, no renter
// approval), the booking page lists what stops the pickup (the payment due, the deposit, the signatures) and the Admin
// overrides and records it (on rent); customer service asks for an override from the same card and the Admin approves
// it in one tap from the booking page.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;

async function mkStaff(sql: Sql, kind: 'admin' | 'va', fn: 'cs' | null, name: string) {
  const id = randomUUID(); const email = `${kind}.ov.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${kind})`;
  if (kind === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${fn}, 500000)`;
  return { id, email, name };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const p = await c.newPage();
  p.on('dialog', (d) => void d.accept());
  return p;
}
async function mkCar(sql: Sql, adminId: string): Promise<string> {
  const vin = `5XYKF${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '3').replace(/O/g, 'A');
  const [r] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin, plate: `OV${randomBytes(2).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  return (r!.v as { vehicle_id: string }).vehicle_id;
}
async function bookNow(sql: Sql, by: string, car: string, days: number) {
  const from = new Date(Date.now() + days * 86_400_000); from.setMinutes(0, 0, 0);
  const [r] = await sql`select app.door(${by}, 'aal2', 'ops_do', 'offer_create', ${sql.json({ vehicle_id: car, pickup_at: from.toISOString(), return_at: new Date(from.getTime() + 3 * 86_400_000).toISOString(),
    renter: { full_name: 'Ovi Override', email: `ovi.${tag()}@example.test`, mobile: `289555${String(Date.now()).slice(-4)}`, date_of_birth: '1990-05-06' },
    coverage_option: 1, sales_choice: 'sourced', channels: { email: false, text: false }, notify: false, book_now: true })}) as v`;
  return r!.v as { booking_number: string; booking_id: string; book_now: { status: string } };
}

test.describe.configure({ mode: 'serial' });

test('admin: Book it now on the offer screen, then override the pickup', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkStaff(sql, 'admin', null, `Ada Override ${tag()}`);
  const car = await mkCar(sql, admin.id);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');

  // the offer screen has the tick box, with what it does
  await page.goto('/admin/offers/new', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('oc-book-now-field')).toContainText('Book it now (no renter approval)');

  // an offer booked now waits for payment; the booking page lists what stops the pickup
  const b = await bookNow(sql, admin.id, car, 1);
  expect(b.book_now.status).toBe('approved');
  const [s] = await sql`select status from bookings where id = ${b.booking_id}`;
  expect(s!.status).toBe('pending_payment');
  await page.goto(`/admin/bookings/${b.booking_number}`, { waitUntil: 'networkidle' });
  const card = page.getByTestId('handover-override');
  await expect(card).toBeVisible();
  await expect(page.getByTestId('override-blockers')).toContainText('payment');
  await noOverflow(page);
  await page.getByTestId('override-pickup').click();
  await page.getByLabel('Why the trip must go ahead').fill('Renter at the counter, paying cash now');
  await page.getByTestId('override-pickup-submit').click();
  await expect.poll(async () => (await sql`select status from bookings where id = ${b.booking_id}`)[0]!.status, { timeout: 20_000 }).toBe('on_rent');
  const [e] = await sql`select count(*)::int as n from booking_events where booking_id = ${b.booking_id} and kind = 'handover_override'`;
  expect(e!.n).toBeGreaterThan(0);
});

test('customer service asks for Book it now; the Admin approves in one tap on the booking', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkStaff(sql, 'admin', null, `Ada Approve ${tag()}`);
  const cs = await mkStaff(sql, 'va', 'cs', `Cy Service ${tag()}`);
  const car = await mkCar(sql, admin.id);
  const b = await bookNow(sql, cs.id, car, 5);
  expect(b.book_now.status).toBe('requested');
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/bookings/${b.booking_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('override-request-book_now')).toContainText('booking the offer now');
  await page.getByTestId('override-approve-book_now').click();
  await expect.poll(async () => (await sql`select status from bookings where id = ${b.booking_id}`)[0]!.status, { timeout: 20_000 }).toBe('pending_payment');
});
