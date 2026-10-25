import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Migration 0163 end to end (docs/changes/2026-10-25-insurer-rate-sheet.md), at the width of each project: an Admin sets
// an insurer's sedan rate on the grid of Admin > Insurer rates (with a weekly cap and a taxes note) and saves a raise from
// a later date (the history keeps both); Add a rental, Insurance replacement, fills the daily rate authorized from the
// sheet for the car and asks for the reason when another rate is typed; a rental billed to the insurer shows the rate and
// its paid invoice on the booking's Insurance replacement card; the insurer's page has the billing by class and the
// bookings, and the CSV. Axe, no sideways scroll, no long dash, no raw database error. Fictional names (example.test).
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;
const day = (offset: number) => new Date(Date.now() + offset * 86_400_000).toLocaleDateString('en-CA', { timeZone: 'America/Toronto' });

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(text, `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `admin.ir.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Ines Rates ' + tag()})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
// a 2024 Jetta: pricing class standard, also a sedan
async function mkJetta(sql: Sql, adminId: string): Promise<string> {
  const vin = `3VWCX7BU${randomBytes(5).toString('hex').toUpperCase()}`.slice(0, 17).padEnd(17, '7').replace(/[IOQ]/g, 'A');
  const [r] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin, plate: `IR${randomBytes(2).toString('hex').toUpperCase()}`, year: 2024, make: 'Volkswagen', model: 'Jetta',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  const id = (r!.v as { vehicle_id: string }).vehicle_id;
  await sql`update vehicles set class = 'standard' where id = ${id}`;
  await sql`insert into vehicle_class_links (vehicle_id, class_code, source) values (${id}, 'sedan', 'staff') on conflict do nothing`;
  return id;
}
async function signIn(browser: Browser, email: string) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  await page.goto('/sign-in?next=/admin', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 30_000 });
  return { c, page };
}

test('the insurers\' rate sheet: set and raise a rate, Add a rental filled from it, the booking card, billing history and CSV', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkAdmin(sql);
  const car = await mkJetta(sql, admin.id);
  const insurer = `Example Mutual ${tag()}`;
  const [ins] = await sql`insert into insurers (name, billing_email) values (${insurer}, 'claims.billing@example.test') returning id`;
  const insId = ins!.id as string;
  const { c, page } = await signIn(browser, admin.email);
  const errors = watch(page);

  // A. the grid: Set the sedan rate, with a weekly cap and a taxes note
  await page.goto('/admin/insurers', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('ir-grid')).toContainText(insurer);
  await check(page, 'insurer rates grid');
  await page.getByTestId(`ir-set-${insId}-sedan`).click();
  const set = page.getByTestId(`ir-set-${insId}-sedan-form`);
  await set.getByLabel('Daily rate ($)').fill('65');
  await set.getByLabel('Weekly cap (empty: none) ($)').fill('390');
  await set.getByLabel('Taxes note (printed on the invoice)').fill('HST is added to every invoice.');
  await set.getByLabel('Why it changed (kept in the history)').fill('Agreed with the claims department');
  await page.getByTestId(`ir-set-${insId}-sedan-submit`).click();
  await expect(page.getByTestId(`ir-cell-${insId}-sedan`)).toContainText('$65.00');
  await expect(page.getByTestId(`ir-cell-${insId}-sedan`)).toContainText('at most $390.00 a week');
  // a raise from a later date: the cell keeps today's rate and shows the next one
  await page.getByTestId(`ir-set-${insId}-sedan`).click();
  await set.getByLabel('Daily rate ($)').fill('68');
  await set.getByLabel('From', { exact: true }).fill(day(10));
  await page.getByTestId(`ir-set-${insId}-sedan-submit`).click();
  await expect(page.getByTestId(`ir-cell-${insId}-sedan`)).toContainText('$68.00');
  await expect(page.getByTestId(`ir-cell-${insId}-sedan`)).toContainText('$65.00');
  const [{ n }] = await sql`select count(*)::int n from insurer_rates where insurer_id = ${insId}` as unknown as [{ n: number }];
  expect(n).toBe(2);

  // B. Add a rental, Insurance replacement: the daily rate authorized comes from the sheet; another rate needs a reason
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await page.getByTestId('mr-preset-insurer').click();
  await page.getByTestId('mr-vehicle_id').selectOption(car);
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-quote')).toBeVisible({ timeout: 30_000 });
  await page.getByTestId('mr-insurer').selectOption(insId);
  await expect(page.getByTestId('mr-authorized_rate')).toHaveValue('65.00');
  await expect(page.getByTestId('mr-insurance')).toContainText(`${insurer}'s rate sheet for Sedan: $65.00 a day, at most $390.00 a week`);
  await expect(page.getByTestId('mr-rate-taxes')).toContainText('HST is added to every invoice.');
  await page.getByTestId('mr-authorized_rate').fill('72');
  await expect(page.getByTestId('mr-rate-differs')).toContainText('$72.00 a day differs from');
  await expect(page.getByTestId('mr-rate_reason')).toBeVisible();
  await check(page, 'add a rental, a rate that differs from the sheet');

  // C. a rental billed to the insurer (added as the form does), invoiced and paid: the booking's card
  const pickup = new Date(Date.now() + 2 * 86_400_000); pickup.setMinutes(0, 0, 0);
  const [mr] = await sql`select app.door(${admin.id}, 'aal2', 'ops_do', 'manual_rental_create', ${sql.json({
    vehicle_id: car, pickup_at: pickup.toISOString(), return_at: new Date(pickup.getTime() + 10 * 86_400_000).toISOString(), coverage_option: 3, source: 'insurer',
    sales_choice: 'for_carmacars', agreement: 'paper', renter: { full_name: 'Remy Replacement', email: `remy.${tag()}@example.test`, mobile: '4165550163', date_of_birth: '1984-02-03', licence_number: 'R1234-12345-12345' },
    payment: { mode: 'unpaid', method: 'insurer' }, deposit: { method: 'cash' }, insurance: { insurer_id: insId, claim_number: 'CLM-E2E-163', pays: 'insurer' } })}) as r`;
  const bookingId = (mr!.r as { booking_id: string }).booking_id;
  const [bk] = await sql`select booking_number, insurer_authorized_daily_rate_cents::int rate, status from bookings where id = ${bookingId}`;
  expect(bk!.rate).toBe(6500);
  if (!['confirmed', 'on_rent'].includes(bk!.status as string)) await sql`update bookings set status = 'confirmed' where id = ${bookingId}`;
  const [inv] = await sql`select app.draft_insurer_invoice(${bookingId}, ${admin.id}) as id`;
  await sql`update insurer_invoices set status = 'sent', sent_at = now() - interval '9 days', sent_by = ${admin.id} where id = ${inv!.id as string}`;
  await sql`select app.record_insurer_payment(${inv!.id as string}, (select total_cents from insurer_invoices where id = ${inv!.id as string}), ${admin.id}, 'bank_transfer', now(), 'EFT-E2E')`;
  await page.goto(`/admin/bookings/${bk!.booking_number as string}?tab=overview`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('booking-insurer')).toContainText(insurer);
  await expect(page.getByTestId('booking-insurer-rate')).toContainText('$65.00');
  await expect(page.getByTestId('booking-insurer-rate')).toContainText('Rate sheet');
  await expect(page.getByTestId('booking-insurer-invoices')).toContainText('Paid');
  await check(page, 'booking, insurance replacement card');

  // D. the insurer's page: rates and history, billing by class, the bookings, the CSV
  await page.goto(`/admin/insurers/${insId}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('ir-rate-sedan')).toContainText('$65.00 a day, at most $390.00 a week');
  await expect(page.getByTestId('ir-history')).toContainText('Upcoming');
  await expect(page.getByTestId('ir-history')).toContainText('Agreed with the claims department');
  await expect(page.getByTestId('ir-by-class')).toContainText('Sedan');
  await expect(page.getByTestId('ir-bookings')).toContainText(bk!.booking_number as string);
  await expect(page.getByTestId('ir-bookings')).toContainText('Rate sheet');
  await check(page, 'insurer page');
  const csv = await page.request.get(`/admin/insurers/${insId}/export`);
  expect(csv.status()).toBe(200);
  expect(csv.headers()['content-type']).toContain('text/csv');
  const body = await csv.text();
  expect(body.split('\r\n')[0]).toContain('Insurer,Booking,Status,Class');
  expect(body).toContain(`${bk!.booking_number as string},`);
  expect(body).toContain('CLM-E2E-163');
  expect(errors.filter((e) => !/favicon|Failed to load resource/.test(e))).toEqual([]);
  await c.close();
  await sql.end();
});
