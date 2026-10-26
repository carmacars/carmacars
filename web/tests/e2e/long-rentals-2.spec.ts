import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0148 end to end, at both widths: Quick start at pickup (the renter's name and phone, the car, kilometres and
// fuel; the car held and a task to finish), the draft listed under Unfinished rentals and opened again where it was left,
// a rental typed and saved as a draft as you go, and a long rental's monthly periods on the booking.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `admin.dr.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Dee Draft ' + tag()})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function mkCar(sql: Sql, adminId: string): Promise<{ id: string; plate: string }> {
  const vin = `5XYKD${randomBytes(6).toString('hex').toUpperCase()}`.slice(0, 17).padEnd(17, '4').replace(/[IOQ]/g, 'A');
  const plate = `DR${randomBytes(2).toString('hex').toUpperCase()}`;
  const [r] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin, plate, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  return { id: (r!.v as { vehicle_id: string }).vehicle_id, plate };
}

test.describe.configure({ mode: 'serial' });

test('quick start at pickup, unfinished rentals, and a draft opened again', async ({ browser }: { browser: Browser }) => {
  test.setTimeout(180_000);
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

  // A. Quick start at pickup
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('mr-quick')).toBeVisible();
  await page.getByTestId('mr-quick-open').click();
  const who = `Quinn Quick ${tag()}`;
  await page.getByTestId('mr-q-full_name').fill(who);
  await page.getByTestId('mr-q-mobile').fill('4165550186');
  await page.getByTestId('mr-quick-car').selectOption(car.id);
  await page.getByTestId('mr-q-odometer_out').fill('12345');
  await page.getByTestId('mr-q-fuel_out').selectOption('75');
  await check(page, 'quick start');
  await page.getByTestId('mr-quick-save').click();
  await expect(page.getByTestId('mr-quick-done')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('mr-quick-done')).toContainText('12345 km');
  const [d] = await sql`select id, quick, hold_block_id from rental_drafts where created_by = ${admin.id} and status = 'open' order by created_at desc limit 1`;
  expect(d?.quick).toBe(true);
  expect(d?.hold_block_id).toBeTruthy();
  const [held] = await sql`select count(*)::int as n from vehicle_calendar_blocks where vehicle_id = ${car.id} and removed_at is null`;
  expect(held!.n).toBe(1);
  const [task] = await sql`select count(*)::int as n from tasks where dedupe_key = ${'finish_rental_draft:' + d!.id} and status = 'open'`;
  expect(task!.n).toBe(1);

  // B. Unfinished rentals: on Bookings and on Add a rental; opened again with what was typed
  await page.goto('/admin/bookings', { waitUntil: 'networkidle' });
  const row = page.getByTestId('unfinished-row').filter({ hasText: who });
  await expect(row).toBeVisible();
  await expect(row).toContainText('Started at pickup');
  await check(page, 'bookings with unfinished rentals');
  await row.getByRole('link', { name: 'Finish it' }).click();
  await page.waitForURL(/draft=/);
  await expect(page.getByTestId('mr-full_name')).toHaveValue(who);
  await expect(page.getByTestId('mr-hold')).toBeChecked();
  await check(page, 'draft opened again');

  // C. discarded: off the list, the car free again, the task done
  await page.getByTestId('mr-discard-draft').click();
  await page.waitForURL((u) => !u.search.includes('draft='));
  await expect.poll(async () => (await sql`select status from rental_drafts where id = ${d!.id}`)[0]?.status).toBe('discarded');
  const [free] = await sql`select count(*)::int as n from vehicle_calendar_blocks where vehicle_id = ${car.id} and removed_at is null`;
  expect(free!.n).toBe(0);

  // D. typed into the full form: saved as a draft as you go
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  const typed = `Tara Typed ${tag()}`;
  if (!(await page.getByTestId('mr-new-renter').isChecked())) await page.getByTestId('mr-new-renter').check();
  await page.getByTestId('mr-full_name').fill(typed);
  await expect(page.getByTestId('mr-draft-bar')).toContainText('Saved as a draft at', { timeout: 15_000 });
  await expect.poll(async () => (await sql`select count(*)::int as n from rental_drafts where created_by = ${admin.id} and status = 'open' and data #>> '{f,full_name}' = ${typed}`)[0]!.n).toBe(1);
  await c.close();
});

test('a long rental: its monthly periods on the booking', async ({ browser }: { browser: Browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkAdmin(sql);
  const car = await mkCar(sql, admin.id);
  const now = new Date(); now.setMinutes(0, 0, 0);
  const [r] = await sql`select app.manual_rental_create(${admin.id}, ${sql.json({
    vehicle_id: car.id, pickup_at: new Date(now.getTime() - 2 * 86_400_000).toISOString(), return_at: new Date(now.getTime() + 68 * 86_400_000).toISOString(),
    coverage_option: 3, source: 'walk_in', sales_choice: 'for_carmacars', agreement: 'paper',
    renter: { full_name: 'Lee Period', email: `lee.period.${tag()}@example.test`, mobile: '4165550187', date_of_birth: '1985-01-01', licence_number: 'P1234-12345-12345' },
    payment: { mode: 'other_way', method: 'cash', received_on: now.toLocaleDateString('en-CA', { timeZone: 'America/Toronto' }) }, deposit: { method: 'cash' } })}) as v`;
  const number = (r!.v as { booking_number: string }).booking_number;
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
  await page.goto(`/admin/bookings/${number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('booking-periods')).toBeVisible();
  await expect(page.getByTestId('period-row')).toHaveCount(3);
  await check(page, 'booking periods');
  await page.getByTestId('period-send-now').click();
  await expect(page.getByTestId('booking-periods')).toContainText('within five minutes');
  await c.close();
});

test('an insurance replacement takes the insurer, the claim and what is authorized', async ({ browser }: { browser: Browser }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkAdmin(sql);
  await mkCar(sql, admin.id);
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await page.getByTestId('mr-preset-insurer').click();
  await expect(page.getByTestId('mr-insurance')).toBeVisible();
  await expect(page.getByTestId('mr-insurer').locator('option', { hasText: 'Not listed' })).toHaveCount(1);
  await page.getByTestId('mr-insurer').selectOption('new');
  await expect(page.getByTestId('mr-insurer_name')).toBeVisible();
  await page.getByTestId('mr-claim_number').fill('CLM-1');
  await page.getByTestId('mr-authorized_days').fill('10');
  await check(page, 'insurance replacement');
  await c.close();
});
