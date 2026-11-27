import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { FIXTURE_JPEG, acceptCookies, db, noOverflow } from './helpers';

// R50 hotfix 2 end to end, at 375 and 1440 pixels (the local server's vision model is the fake one: a receipt of an oil change,
// $85.00 + $11.05 HST, and a permit with the synthetic VIN 3FAKEPRM5RT000042 and plate ZZZZ 123).
//   5143: Fleet logs an expense from two receipt photos on the phone: the fields are read from the photo, the owner's car makes
//         the owner pay, Save puts an open deduction for $96.05 on the owner's statement with both photos as receipts.
//   5144: Fleet uploads ownership permits in bulk: the first is filed on the car with that VIN; the next matches no car, waits,
//         and is filed by hand on the car picked. Each page is checked with axe and for overflow.
const PW = 'correct horse battery';
const PERMIT_VIN = '3FAKEPRM5RT000042';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;

async function mkFleet(sql: Sql) {
  const id = randomUUID(); const email = `fleet.r50h2.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Fern Fleet ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'fleet', 10000)`;
  return { id, email };
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/staff'), { timeout: 20_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}`)).toEqual([]);
}
const photo = (n: number) => ({ name: `receipt-${n}.jpg`, mimeType: 'image/jpeg', buffer: FIXTURE_JPEG });

test.describe.configure({ mode: 'serial' });

test('5143: Fleet logs an expense from two receipt photos; it goes on the owner\'s statement with both receipts', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const fleet = await mkFleet(sql);
  const [car] = await sql`select v.id, v.owner_id from vehicles v where v.supply_type = 'program_owner' and v.owner_id is not null and not coalesce(v.is_sample, false)
                            and v.status::text not in ('archived', 'removed', 'sold') order by v.created_at limit 1`;
  expect(car, 'the seed has program owner cars (scripts/seed.mjs)').toBeTruthy();
  const page = await ctx(browser);
  await signIn(page, fleet.email);
  await page.goto('/staff/expenses', { waitUntil: 'networkidle' });
  const cap = page.getByTestId('expense-capture');
  await expect(cap).toBeVisible();
  await expect(page.getByTestId('expense-save')).toBeDisabled();
  // the picker is off until the expense context has loaded: photos chosen before that are ignored
  await expect(page.getByTestId('expense-upload')).toBeEnabled();
  await page.getByTestId('expense-upload').setInputFiles([photo(1), photo(2)]);
  await expect(page.getByTestId('expense-shots').locator('li')).toHaveCount(2);
  // read from the photo: the amount before tax, the tax, the shop, the category
  await expect(page.getByTestId('expense-amount')).toHaveValue('85.00', { timeout: 30_000 });
  await expect(page.getByTestId('expense-tax')).toHaveValue('11.05');
  await expect(page.getByTestId('expense-vendor')).toHaveValue('Example Quick Lube');
  await expect(page.getByTestId('expense-category')).toHaveValue('maint_oil');
  await page.getByTestId('expense-car').selectOption(String(car!.id));
  await expect(page.getByTestId('expense-payer-owner')).toBeChecked();
  await check(page, 'expenses with two photos');
  await expect(page.getByTestId('expense-save')).toHaveText('Save $96.05');
  await page.getByTestId('expense-save').click();
  await expect(page.getByTestId('expense-msg')).toContainText('on the owner\'s next statement', { timeout: 20_000 });
  const [e] = await sql`select e.payer, d.amount_cents, d.hst_cents, d.status, (select count(*) from expense_entry_photos p where p.entry_id = e.id)::int as photos
                          from expense_entries e join owner_deductions d on d.id = e.owner_deduction_id where e.created_by = ${fleet.id} order by e.created_at desc limit 1`;
  expect([e!.payer, Number(e!.amount_cents), Number(e!.hst_cents), e!.status, e!.photos]).toEqual(['owner', 9605, 1105, 'open', 2]);
  await expect(page.getByTestId('expense-entries')).toContainText('Example Quick Lube');
  await expect(page.getByTestId('expense-shots')).toHaveCount(0);
  await sql.end();
});

test('5144: Fleet uploads ownership permits in bulk: one filed by its VIN, one waits and is filed by hand', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const fleet = await mkFleet(sql);
  const [admin] = await sql`select u.id from users u join user_roles r on r.user_id = u.id and r.role = 'admin' order by u.created_at limit 1`;
  // the car the fake permit belongs to: the synthetic VIN on one car only, and no car with its plate
  await sql`update vehicles set plate = ${`PX${tag().toUpperCase()}`} where app.norm_plate(plate) = 'ZZZZ123'`;
  let [car] = await sql`select id from vehicles where upper(vin) = ${PERMIT_VIN} limit 1`;
  if (!car) {
    const [r] = await sql`select app.vehicle_add(${admin!.id}, ${sql.json({ supply_type: 'company', vin: PERMIT_VIN, plate: `PY${tag().toUpperCase()}`, year: 2024, make: 'Toyota', model: `Corolla ${tag()}`,
      rates: { daily: 6900, weekend: 7900, weekly: 42000, monthly: 150000, deposit: 30000 } })}) as r`;
    car = { id: (r!.r as { vehicle_id: string }).vehicle_id };
  }
  const page = await ctx(browser);
  await signIn(page, fleet.email);
  await page.goto('/staff/ownership-documents', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('permit-bulk')).toBeVisible();
  await check(page, 'ownership documents');
  await page.getByTestId('permit-files').setInputFiles([{ name: 'permit-a.jpg', mimeType: 'image/jpeg', buffer: FIXTURE_JPEG }]);
  await expect(page.getByTestId('permit-rows').locator('li').first()).toContainText('Filed on the', { timeout: 30_000 });
  await expect(page.getByTestId('permit-rows').locator('li').first()).toContainText('by its VIN');
  const [filed] = await sql`select u.status, u.matched_by, d.kind, d.vehicle_id from permit_uploads u join documents d on d.id = u.document_id where u.created_by = ${fleet.id} order by u.created_at limit 1`;
  expect([filed!.status, filed!.matched_by, filed!.kind, filed!.vehicle_id]).toEqual(['filed', 'vin', 'ownership_permit', car!.id]);

  // the VIN now on no car: the next file waits for a person
  const other = `3FAKEPRM5RT${randomBytes(3).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17);
  await sql`update vehicles set vin = ${other} where id = ${car!.id}`;
  await page.getByTestId('permit-files').setInputFiles([{ name: 'permit-b.jpg', mimeType: 'image/jpeg', buffer: FIXTURE_JPEG }]);
  await expect(page.getByTestId('permit-rows').locator('li').first()).toContainText('No car matched', { timeout: 30_000 });
  const [w] = await sql`select id from permit_uploads where created_by = ${fleet.id} and status = 'unmatched' limit 1`;
  const row = page.getByTestId(`permit-wait-${w!.id}`);
  await expect(row).toBeVisible();
  await expect(row.getByTestId('permit-wait-file')).toBeDisabled();
  await row.getByTestId('permit-wait-car').selectOption(String(car!.id));
  await row.getByTestId('permit-wait-file').click();
  await expect(row).toHaveCount(0, { timeout: 20_000 });
  const [hand] = await sql`select status, matched_by, vehicle_id from permit_uploads where id = ${w!.id}`;
  expect([hand!.status, hand!.matched_by, hand!.vehicle_id]).toEqual(['filed', 'hand', car!.id]);
  await check(page, 'ownership documents after filing');
  await sql`update vehicles set vin = ${PERMIT_VIN} where id = ${car!.id}`;
  await sql.end();
});
