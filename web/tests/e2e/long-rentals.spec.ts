import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0132 end to end, at both widths, the owner's exact case: a rental picked up yesterday, six weeks long, a
// driver of 23, the rent paid in cash and the deposit by e-Transfer. The quick rental form takes the dates (no 31-day
// limit), prices six weeks at the monthly rate, shows the two monthly periods, lets the Admin change the young driver
// fee and the Protection Plan price, takes the rent in two parts and the deposit its own way, and sums it all up before
// saving. On the booking: the periods (agreement and payment of each) and the fees changed again after confirmation, with
// the change recorded. Each screen is checked with axe, for overflow and for the copy rules.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b/, 'brand misspelled'], [/renew with a new booking/i, 'the old 30-day rule']];
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;
const pad = (n: number) => String(n).padStart(2, '0');
const localInput = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `admin.lr.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Ada Long ' + tag()})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function mkCar(sql: Sql, adminId: string): Promise<string> {
  const vin = `5XYKL${randomBytes(6).toString('hex').toUpperCase()}`.slice(0, 17).padEnd(17, '3').replace(/[IOQ]/g, 'A');
  const [r] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin, plate: `LR${randomBytes(2).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  return (r!.v as { vehicle_id: string }).vehicle_id;
}

test.describe.configure({ mode: 'serial' });

test('the owner\'s case: picked up yesterday, six weeks, young driver, rent in cash, deposit by e-Transfer', async ({ browser }: { browser: Browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkAdmin(sql);
  const car = await mkCar(sql, admin.id);
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  page.on('dialog', (d) => void d.accept());
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });

  // A. the quick rental form, Walk-in
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await page.getByTestId('mr-preset-walk_in').click();
  await page.getByTestId('mr-vehicle_id').selectOption(car);
  const from = new Date(Date.now() - 86_400_000); from.setMinutes(0, 0, 0);
  const to = new Date(from.getTime() + 42 * 86_400_000);
  await page.getByTestId('mr-pickup_at').fill(localInput(from));
  await page.getByTestId('mr-return_at').fill(localInput(to));
  await expect(page.getByTestId('mr-phase')).toHaveAttribute('data-phase', 'in_progress');
  await page.getByTestId('mr-new-renter').check();
  const email = `yusuf.${tag()}@example.test`;
  await page.getByTestId('mr-full_name').fill('Yusuf Long');
  await page.getByTestId('mr-email').fill(email);
  await page.getByTestId('mr-mobile').fill('4165550142');
  const dob = new Date(); dob.setFullYear(dob.getFullYear() - 23);
  await page.getByTestId('mr-date_of_birth').fill(`${dob.getFullYear()}-${pad(dob.getMonth() + 1)}-${pad(dob.getDate())}`);
  await page.getByTestId('mr-licence_number').fill('L1234-12345-12345');
  await page.getByTestId('mr-coverage_option').selectOption('3');

  // B. priced: the monthly rate, two periods, no 31-day refusal
  await expect(page.getByTestId('mr-quote')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('mr-error')).toHaveCount(0);
  await expect(page.getByTestId('mr-quote')).toContainText('monthly rate');
  await expect(page.getByTestId('mr-line-rental_charge')).toContainText('$4,200.00');
  await expect(page.getByTestId('mr-periods')).toContainText('2 monthly periods');

  // C. the young driver fee and the Protection Plan price changed by hand
  await page.getByTestId('mr-fee-young_driver_21_25').fill('250');
  await page.getByTestId('mr-fee-coverage_sold').fill('400');
  await expect(page.getByTestId('mr-line-young_driver_21_25')).toContainText('$250.00', { timeout: 15_000 });
  await expect(page.getByTestId('mr-line-coverage_sold')).toContainText('$400.00', { timeout: 15_000 });
  const total = (await page.getByTestId('mr-total').innerText()).trim();
  expect(total).toBe('$5,480.50');   // (4,200 + 250 + 400) plus 13% HST

  // D. the rent in cash, in two parts; the deposit by e-Transfer
  await page.getByTestId('mr-paid-by').selectOption('cash');
  await page.getByTestId('mr-amount').fill('3000');
  await page.getByTestId('mr-add-payment').click();
  await page.getByTestId('mr-part-0-method').selectOption('cash');
  await page.getByTestId('mr-part-0-amount').fill('2480.50');
  await page.getByTestId('mr-deposit-by').selectOption('e_transfer');
  await page.getByTestId('mr-deposit_reference').fill('ETDEP-4410');
  await page.getByTestId('mr-agreement-paper').check();
  await expect(page.getByTestId('mr-summary')).toContainText('2 monthly periods');
  await expect(page.getByTestId('mr-sum-paid')).toContainText('$5,480.50 received');
  await expect(page.getByTestId('mr-sum-deposit')).toContainText('e-transfer (ETDEP-4410)');
  await check(page, 'quick rental form');
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toBeVisible({ timeout: 30_000 });
  await expect(page.getByTestId('mr-done')).toContainText('on trip');
  const number = (await page.getByTestId('mr-done').locator('h2').innerText()).match(/CC-\d+/)![0];

  const [b] = await sql`select id, status, billable_days, rental_charge_cents, total_due_at_booking_cents from bookings where booking_number = ${number}`;
  expect(b!.status).toBe('on_rent');
  expect(Number(b!.billable_days)).toBeGreaterThanOrEqual(42);
  const pays = await sql`select method, amount_cents, covers from manual_payments where booking_id = ${b!.id} order by amount_cents desc`;
  expect(pays.filter((p) => p.covers === 'deposit').map((p) => p.method)).toEqual(['e_transfer']);
  expect(pays.filter((p) => p.covers !== 'deposit').every((p) => p.method === 'cash')).toBe(true);
  expect(pays.reduce((s, p) => s + (p.covers === 'deposit' ? 0 : Number(p.amount_cents)), 0)).toBe(548050);

  // E. the owner's addition: the rental on trip edited directly: a week more, the young driver fee changed, told to the renter
  await page.goto(`/admin/bookings/${number}?tab=overview`, { waitUntil: 'networkidle' });
  await page.getByTestId('be-open').click();
  const later = new Date(to.getTime() + 7 * 86_400_000);
  await page.getByTestId('be-return_at').fill(localInput(later));
  await page.getByTestId('be-fee-young_driver_21_25').fill('200');
  await page.getByTestId('be-reason').fill('Extended a week by phone');
  await page.getByTestId('be-tell').check();
  await check(page, 'edit the booking');
  await page.getByTestId('be-save').click();
  await expect(page.getByTestId('be-msg')).toContainText('Saved', { timeout: 20_000 });
  await expect(page.getByTestId('be-msg')).toContainText('to collect');
  const [b2] = await sql`select billable_days, rental_charge_cents, status from bookings where id = ${b!.id}`;
  expect(Number(b2!.billable_days)).toBeGreaterThanOrEqual(49);
  expect(Number(b2!.rental_charge_cents)).toBeGreaterThan(Number(b!.rental_charge_cents));
  expect(b2!.status).toBe('on_rent');
  await expect(page.getByTestId('be-edits')).toContainText('Extended a week by phone', { timeout: 15_000 });

  // E2. the renter's email was typed wrong: corrected from the booking
  await page.getByTestId('re-open').click();
  const fixed = `yusuf.right.${tag()}@example.test`;
  await page.getByTestId('re-email').fill(fixed);
  await page.getByTestId('re-reason').fill('Typo at the counter');
  await page.getByTestId('re-save').click();
  await expect(page.getByTestId('re-msg')).toContainText(`The email is now ${fixed}`, { timeout: 20_000 });
  const [rn] = await sql`select r.email from renters r join bookings b on b.renter_id = r.id where b.id = ${b!.id}`;
  expect(rn!.email).toBe(fixed);

  // F. the second cash payment, for the rental and the fees together, on the Money tab
  await page.goto(`/admin/bookings/${number}?tab=money`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('booking-fees')).toContainText('$200.00');
  // the owner's CC-10012 case: a fee forgotten is added, the renter gets a pay link for exactly the new balance
  await page.getByTestId('bf-edit').click();
  await page.getByTestId('bf-own-label').fill('Young driver fee forgotten');
  await page.getByTestId('bf-own-amount').fill('50');
  await page.getByTestId('bf-own-add').click();
  await expect(page.getByTestId('bf-msg')).toContainText('Added', { timeout: 20_000 });
  await expect(page.getByTestId('bal-open')).toBeVisible();
  await page.getByTestId('bal-email').click();
  await expect(page.getByTestId('bal-msg')).toContainText('pay link', { timeout: 20_000 });
  const [req] = await sql`select covers, amount_cents, status from payment_requests where booking_id = ${b!.id} order by created_at desc limit 1`;
  expect(req!.covers).toBe('balance');
  expect(req!.status).toBe('open');
  await page.getByTestId('bm-record-open').click();
  await expect(page.getByTestId('bm-covers')).toHaveValue('both');
  await page.getByTestId('bm-method').selectOption('cash');
  await page.getByTestId('bm-record-save').click();
  await expect(page.getByTestId('booking-money')).toContainText('Recorded', { timeout: 20_000 });
  const [open] = await sql`select app.booking_part_open(${b!.id}, 'rental') + app.booking_part_open(${b!.id}, 'fees') as o`;
  expect(Number(open!.o)).toBe(0);
  await check(page, 'booking money');
  await sql.end();
  await c.close();
});
