import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0089 end to end: the fleet maintenance overview and the one-step record pop-up, at 375 and 1440 pixels.
// An Admin finds a new car with no service record, records its last oil change and tire rotation from the overview
// (billed to CarmaCars: a company expense under the oil change category), sees the timers reset on the car's
// Maintenance tab and adds the tire set on the car. Fleet opens a car straight into the pop-up (as a task link does),
// records a service above their single limit with a receipt, and is told an Admin bills it. Every page is checked
// with axe, for overflow and for the copy rules.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const vin = () => `3G1BE5SM${randomBytes(5).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `MT${randomBytes(2).toString('hex').toUpperCase()}`;

async function mkUser(sql: Sql, kind: 'admin' | 'fleet', name: string) {
  const id = randomUUID(); const email = `${kind}.mt.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'fleet', 10000)`;
  }
  return { id, email, name };
}
async function mkCar(sql: Sql, adminId: string, model: string) {
  const [car] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin: vin(), plate: plate(), year: 2022, make: 'Chevrolet', model,
    rates: { daily: 6900, weekend: 7900, weekly: 42000, monthly: 150000, deposit: 30000 } })}) as r`;
  const id = (car!.r as { vehicle_id: string }).vehicle_id;
  await sql`update vehicles set odometer_km = 48200 where id = ${id}`;
  return id;
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

test.describe.configure({ mode: 'serial' });

test('Admin: the fleet overview, the record pop-up, the timers reset and the bill as a company expense', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const model = `Malibu ${tag()}`;
  const carId = await mkCar(sql, admin.id, model);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');

  // To do points at it: cars with no service record yet
  await expect(page.getByTestId('todo-maintenance_unknown')).toBeVisible();
  await page.goto(`/admin/maintenance?show=unknown&q=${encodeURIComponent(model)}`, { waitUntil: 'networkidle' });
  const card = page.getByTestId(`maint-car-${carId}`);
  await expect(card).toHaveAttribute('data-worst', 'unknown');
  await expect(card).toContainText('48,200 km');
  await check(page, 'maintenance overview');

  // the pop-up: one step, opened from the overview (it loads the car)
  await card.getByTestId(`record-${carId}`).click();
  const dlg = page.getByTestId(`record-${carId}-dialog`);
  await expect(dlg).toBeVisible();
  await expect(dlg.getByTestId(`record-${carId}-km`)).toHaveValue('48200');
  for (const box of await dlg.locator('input[type="checkbox"][data-item]').all()) if (await box.isChecked()) await box.uncheck();
  await dlg.locator('input[data-item="oil_filter"]').check();
  await dlg.locator('input[data-item="tire_rotation"]').check();
  await dlg.getByTestId(`record-${carId}-shop`).fill('Quick Lube Toronto');
  await dlg.getByTestId(`record-${carId}-cost`).fill('89.95');
  await expect(dlg.getByTestId(`record-${carId}-payer`)).toHaveValue('company');
  await expect(dlg.getByTestId(`record-${carId}-summary`)).toContainText('company expense');
  await expect(dlg.getByTestId(`record-${carId}-summary`)).toContainText('$101.64');
  await check(page, 'record pop-up');
  await dlg.getByTestId(`record-${carId}-submit`).click();
  await expect(dlg).toBeHidden({ timeout: 20_000 });
  await expect(page.getByTestId(`record-${carId}-done`)).toContainText('The timers are reset');

  const [r] = await sql`select r.billing_status, r.odometer_km, e.category, e.amount_cents, e.hst_cents,
                               (select string_agg(item_code, ',' order by item_code) from vehicle_service_record_items where record_id = r.id) as items
                          from vehicle_service_records r join company_expenses e on e.id = r.company_expense_id where r.vehicle_id = ${carId}`;
  expect(`${r!.billing_status}/${r!.odometer_km}/${r!.category}/${r!.amount_cents}/${r!.hst_cents}/${r!.items}`).toBe('billed/48200/maint_service/8995/1169/oil_filter,tire_rotation');

  // the car's Maintenance tab: oil is OK with the next one at 56,200 km
  await page.goto(`/admin/vehicles/${carId}?tab=maintenance`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('status-oil_filter')).toHaveAttribute('data-status', 'ok');
  await expect(page.getByTestId('next-oil_filter')).toContainText('56,200 km');
  await expect(page.getByTestId('status-tire_rotation')).toHaveAttribute('data-status', 'ok');
  await expect(page.getByTestId('maint-records')).toContainText('Quick Lube Toronto');
  await check(page, 'car maintenance tab');

  // the tire set on the car: winter, so the seasonal swap follows
  await page.getByTestId('tire-add').click();
  const form = page.getByTestId('tire-add-form');
  await form.getByLabel('Kind').selectOption('winter');
  await form.getByLabel('Size').fill('225/55R17');
  await form.getByLabel('Tread depth (mm)').fill('8');
  await form.getByTestId('tire-add-submit').click();
  await expect(page.getByTestId('tire-sets')).toContainText('On the car');
  await expect(page.getByTestId('tire-sets')).toContainText('225/55R17');
  await check(page, 'car maintenance tab with tires');
  await page.context().close();
  await sql.end();
});

test('Fleet: a task link opens the pop-up; above the single limit the service is recorded and an Admin bills it', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const fleet = await mkUser(sql, 'fleet', `Fred Fleet ${tag()}`);
  const model = `Forte ${tag()}`;
  const carId = await mkCar(sql, admin.id, model);
  const page = await ctx(browser);
  await signIn(page, fleet.email, '/va');
  await page.goto(`/va/maintenance?q=${encodeURIComponent(model)}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId(`maint-car-${carId}`)).toBeVisible();
  await check(page, 'fleet maintenance overview');

  // as a task link opens it: the car's view with the pop-up open
  await page.goto(`/va/vehicles/${carId}?record=1#maintenance`, { waitUntil: 'networkidle' });
  const dlg = page.getByTestId('record-service-dialog');
  await expect(dlg).toBeVisible({ timeout: 20_000 });
  for (const box of await dlg.locator('input[type="checkbox"][data-item]').all()) if (await box.isChecked()) await box.uncheck();
  await dlg.locator('input[data-item="brake_inspection"]').check();
  await dlg.locator('input[data-item="brake_pads_rotors"]').check();
  await dlg.getByTestId('record-service-shop').fill('Brake Masters');
  await dlg.getByTestId('record-service-cost').fill('420');
  await expect(dlg.getByTestId('record-service-summary')).toContainText('an Admin bills it');
  await dlg.locator('input[type="file"]').setInputFiles({ name: 'receipt.png', mimeType: 'image/png',
    buffer: Buffer.from('89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d49444154789c6360000002000154a24f5d0000000049454e44ae426082', 'hex') });
  await check(page, 'fleet record pop-up');
  await dlg.getByTestId('record-service-submit').click();
  await expect(dlg).toBeHidden({ timeout: 20_000 });
  await expect(page.getByTestId('record-service-done')).toContainText('An Admin bills it');
  const [r] = await sql`select billing_status, receipt_document_id is not null as receipt from vehicle_service_records where vehicle_id = ${carId}`;
  expect(`${r!.billing_status}/${r!.receipt}`).toBe('needs_admin/true');
  await expect(page.getByTestId('maint-records')).toContainText('Waiting for an Admin to bill');
  await check(page, 'fleet car view');
  await page.context().close();

  // the Admin bills it from the car's history
  const ap = await ctx(browser);
  await signIn(ap, admin.email, '/admin');
  await expect(ap.getByTestId('todo-maintenance_bill')).toBeVisible();
  await ap.goto(`/admin/vehicles/${carId}?tab=maintenance`, { waitUntil: 'networkidle' });
  const [rec] = await sql`select id from vehicle_service_records where vehicle_id = ${carId}`;
  await ap.getByTestId(`bill-${rec!.id}`).click();
  await ap.getByTestId(`bill-${rec!.id}-submit`).click();
  await expect(ap.getByTestId('maint-records')).toContainText('Billed', { timeout: 20_000 });
  const [b] = await sql`select r.billing_status, e.category from vehicle_service_records r join company_expenses e on e.id = r.company_expense_id where r.vehicle_id = ${carId}`;
  expect(`${b!.billing_status}/${b!.category}`).toBe('billed/maint_brakes');
  await ap.context().close();
  await sql.end();
});
