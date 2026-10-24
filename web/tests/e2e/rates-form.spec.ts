import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, carByHand, db, noOverflow } from './helpers';

// Migration 0064 end to end, at 375 and 1440 pixels: posting a car with its rates and kilometres in one pass (Add a
// car for the three supply types, a car's Rates tab, Fleet), the field messages, the preview priced like bookings;
// deleting a sample car whose bookings are only requests; Add a rental for a car whose listing is not finished.
const SHOTS = 'test-results/rates-form';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const tag = () => randomBytes(3).toString('hex');
// letters I, O and Q are not used in VINs
const vin = () => `3RF${randomBytes(7).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `RF${randomBytes(2).toString('hex').toUpperCase()}`;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const usd = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: c % 100 ? 2 : 0 })}`;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function mkStaff(sql: Sql, kind: 'admin' | 'fleet') {
  const id = randomUUID(); const email = `${kind}.rf.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Rf ${kind} ${tag()}`})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'fleet')`;
  }
  return { id, email };
}
async function signedIn(browser: Browser, email: string, expectPath: string) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  const page = await c.newPage();
  page.on('dialog', (d) => void d.accept());
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
  return page;
}
// the next Friday at 10 am Toronto, as the preview prices it
async function fridaySunday(sql: Sql, we: number, d: number, wk: number, m: number) {
  const [r] = await sql`select c.rental_charge_cents::int as cents from public.calc_rental_charge(
      (select case when f < now() then f + interval '7 days' else f end from (select (date_trunc('week', now() at time zone 'America/Toronto') + interval '4 days 10 hours') at time zone 'America/Toronto' as f) x),
      2, ${d}, ${we}, ${wk}, ${m}) c`;
  return r!.cents as number;
}
async function addCar(page: Page, supply: 'company' | 'partner' | 'program_owner', o: { partnerId?: string; ownerId?: string; rates: Record<string, string>; custom?: { km: string; ov: string } }) {
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  await page.getByTestId(`add-car-supply-${supply}`).check();
  if (o.partnerId) await page.getByTestId('add-car-partner').selectOption(o.partnerId);
  if (o.ownerId) await page.getByTestId('add-car-owner').selectOption({ index: 1 });
  await page.getByTestId('add-car-vin').fill(vin());
  await page.getByTestId('add-car-plate').fill(plate());
  await carByHand(page, 'add-car', { year: '2023', make: 'Hyundai', model: `Elantra ${tag()}` });
  for (const [k, v] of Object.entries(o.rates)) await page.getByTestId(`add-car-${k}`).fill(v);
  // the check answers after a short pause (and may add the similar cars line above the fields)
  await expect(page.getByTestId('add-car-example-friday_sunday')).toBeVisible({ timeout: 15_000 });
  if (o.custom) {
    await page.getByTestId('add-car-km-custom').check();
    await page.getByTestId('add-car-km_per_day').fill(o.custom.km);
    await page.getByTestId('add-car-overage').fill(o.custom.ov);
  }
  await expect(page.getByTestId('add-car-example-friday_sunday')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('add-car-submit').click();
  await page.waitForURL(/\/admin\/vehicles\/[0-9a-f-]{36}\?added=1/, { timeout: 30_000 });
  return page.url().match(/vehicles\/([0-9a-f-]{36})/)![1]!;
}

test.describe.configure({ mode: 'serial' });

test('post a car with its rates and kilometres in one pass: Add a car (three supply types), the Rates tab, Fleet', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  const admin = await mkStaff(sql, 'admin');
  const page = await signedIn(browser, admin.email, '/admin');
  const [partner] = await sql`select app.partner_save(${admin.id}, ${sql.json({ business_name: `Rf Rentals ${tag()}`, email: `rf.${tag()}@example.test`, contact_name: 'Pat Partner',
    insurance_company: 'Rf Mutual', insurance_policy: 'P-1', insurance_expiry: '2027-06-30' })}) as p`;
  const partnerId = (partner!.p as { id: string }).id;

  // the labels say the unit; the weekend rate is per day; the preview is the booking price
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  await expect(page.getByLabel('Weekend rate (per day, Friday and Saturday) ($)')).toBeVisible();
  await expect(page.getByText('A price per day, not for the whole weekend', { exact: false })).toBeVisible();
  await page.getByTestId('add-car-daily').fill('0');
  await expect(page.getByTestId('add-car-daily-error')).toHaveText('The daily rate must be above zero.', { timeout: 15_000 });
  await page.getByTestId('add-car-daily').fill('89');
  await page.getByTestId('add-car-weekend').fill('99');
  await page.getByTestId('add-car-weekly').fill('500');
  await page.getByTestId('add-car-monthly').fill('1800');
  const fs = await fridaySunday(sql, 9900, 8900, 50000, 180000);
  await expect(page.getByTestId('add-car-example-friday_sunday')).toHaveText(`Friday 10 am to Sunday 10 am: ${usd(fs)} before tax (2 days at the weekend rate), 400 km included.`, { timeout: 15_000 });
  await expect(page.getByTestId('add-car-km-default')).toBeChecked();
  await expect(page.getByTestId('add-car-km')).toContainText('200 km a day included, then $0.35 for each extra km');
  await check(page, 'add a car with rates');
  await page.screenshot({ path: `${SHOTS}/add-car-rates-${isPhone() ? 'phone' : 'desktop'}.png`, fullPage: true });

  // company (defaults), partner (custom kilometres), program owner (daily rate only)
  const company = await addCar(page, 'company', { rates: { daily: '89', weekend: '99', weekly: '500', monthly: '1800', deposit: '500' } });
  const partnerCar = await addCar(page, 'partner', { partnerId, rates: { daily: '70' }, custom: { km: '300', ov: '0.40' } });
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  await page.getByTestId('add-car-supply-program_owner').check();
  const owners = await page.getByTestId('add-car-owner').locator('option').count();
  const ownerCar = owners > 1 ? await addCar(page, 'program_owner', { ownerId: 'first', rates: { daily: '120' } }) : null;
  const cards = await sql`select vehicle_id, daily_rate_cents::int d, weekend_rate_cents::int we, weekly_rate_cents::int wk, monthly_rate_cents::int m, km_allowance_per_day km,
      overage_cents_per_km ov, deposit_cents::int dep, km_uses_defaults def from rate_cards where vehicle_id = any(${[company, partnerCar, ...(ownerCar ? [ownerCar] : [])]}) and effective_to is null`;
  const by = Object.fromEntries(cards.map((c) => [c.vehicle_id as string, c]));
  expect(by[company]).toMatchObject({ d: 8900, we: 9900, wk: 50000, m: 180000, km: 200, ov: 35, dep: 50000, def: true });
  expect(by[partnerCar]).toMatchObject({ d: 7000, we: 7000, wk: 42000, m: 154000, km: 300, ov: 40, def: false });
  if (ownerCar) expect(by[ownerCar]).toMatchObject({ d: 12000, km: 200, def: true });

  // the Rates tab: a car with no rates saves in one pass (the circular refusal of 0063)
  const [bare] = await sql`select app.vehicle_add(${admin.id}, ${sql.json({ supply_type: 'company', vin: vin(), plate: plate(), year: 2024, make: 'Kia', model: `K5 ${tag()}` })}) as r`;
  const bareId = (bare!.r as { vehicle_id: string }).vehicle_id;
  // 0087: a car added without rates gets a complete rate card from the class defaults, marked "Set automatically";
  // the circular refusal of 0063 is checked on a car with no card at all, so that card is taken off here
  await page.goto(`/admin/vehicles/${bareId}?tab=rates`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('rate-card-auto')).toContainText('Set automatically');
  await expect(page.getByTestId('auto-rate-daily')).toBeVisible();
  await sql`delete from rate_cards where vehicle_id = ${bareId} and auto_defaults ? 'daily'`;
  await page.goto(`/admin/vehicles/${bareId}?tab=rates`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('rate-form-none')).toBeVisible();
  await page.getByTestId('rate-form-daily').fill('75');
  await expect(page.getByTestId('rate-form-example-month')).toContainText('$1,650 before tax', { timeout: 15_000 });
  await check(page, 'rates tab, no rates yet');
  await page.getByTestId('rate-form-submit').click();
  await expect(page.getByTestId('rate-form-msg')).toHaveText('New rates saved.', { timeout: 15_000 });
  const [c1] = await sql`select daily_rate_cents::int d, weekend_rate_cents::int we, km_allowance_per_day km, overage_cents_per_km ov from rate_cards where vehicle_id = ${bareId} and effective_to is null`;
  expect(c1).toMatchObject({ d: 7500, we: 7500, km: 200, ov: 35 });
  // then custom kilometres on the same form
  await page.reload({ waitUntil: 'networkidle' });
  await page.getByTestId('rate-form-km-custom').check();
  await page.getByTestId('rate-form-km_per_day').fill('0');
  await expect(page.getByTestId('rate-form-km_per_day-error')).toHaveText('Enter the kilometres included a day, from 1 to 5,000.', { timeout: 15_000 });
  await page.getByTestId('rate-form-km_per_day').fill('150');
  await expect(page.getByTestId('rate-form-km-text')).toHaveText('150 km included a day, then $0.35 for each extra km.', { timeout: 15_000 });
  await page.getByTestId('rate-form-submit').click();
  await expect(page.getByTestId('rate-form-msg')).toHaveText('New rates saved.', { timeout: 15_000 });
  const [c2] = await sql`select km_allowance_per_day km, km_uses_defaults def from rate_cards where vehicle_id = ${bareId} and effective_to is null`;
  expect(c2).toMatchObject({ km: 150, def: false });
  await check(page, 'rates tab, saved');

  // Fleet enters rates on the car's page
  const fleet = await mkStaff(sql, 'fleet');
  const fp = await signedIn(browser, fleet.email, '/va');
  await fp.goto(`/va/vehicles/${partnerCar}`, { waitUntil: 'networkidle' });
  await fp.getByTestId('va-rate-form-daily').fill('72');
  await expect(fp.getByTestId('va-rate-form-example-friday_sunday')).toBeVisible({ timeout: 15_000 });
  await check(fp, 'fleet rates');
  await fp.getByTestId('va-rate-form-submit').click();
  await expect(fp.getByTestId('va-rate-form-msg')).toHaveText('New rates saved.', { timeout: 15_000 });
  const [c3] = await sql`select daily_rate_cents::int d, km_allowance_per_day km from rate_cards where vehicle_id = ${partnerCar} and effective_to is null`;
  expect(c3).toMatchObject({ d: 7200, km: 300 });
  await sql.end();
});

test('delete a sample car whose bookings are only requests; Add a rental for a car whose listing is not finished', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkStaff(sql, 'admin');
  const page = await signedIn(browser, admin.email, '/admin');
  const [renter] = await sql`select id from renters where not is_blocked order by created_at limit 1`;

  // a sample car with a request and a declined request, no money
  const [s] = await sql`select app.vehicle_add(${admin.id}, ${sql.json({ supply_type: 'company', vin: vin(), plate: plate(), year: 2023, make: 'Toyota', model: `Corolla ${tag()}`, rates: { daily: 6000 } })}) as r`;
  const sid = (s!.r as { vehicle_id: string }).vehicle_id;
  const [pl] = await sql`select plate from vehicles where id = ${sid}`;
  const nums: string[] = [];
  for (const [st, days] of [['requested', 40], ['declined', 50]] as const) {
    const n = `RF-${tag().toUpperCase()}`; nums.push(n);
    await sql`insert into bookings (booking_number, status, vehicle_id, renter_id, pickup_at, return_at, original_return_at, billable_days, daily_rate_cents, weekend_rate_cents,
        weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total, overage_cents_per_km, deposit_cents)
      values (${n}, ${st}, ${sid}, ${renter!.id}, now() + ${`${days} days`}::interval, now() + ${`${days + 2} days`}::interval, now() + ${`${days + 2} days`}::interval, 2, 6000, 6000, 36000, 132000, 'daily', 12000, 200, 400, 35, 50000)`;
  }
  // marked a sample only after its bookings are written (0065 refuses a booking on a sample car)
  await sql`update vehicles set is_sample = true where id = ${sid}`;
  await page.goto(`/admin/vehicles/${sid}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('delete-blocked')).toHaveCount(0);
  await page.getByTestId('vehicle-delete').click();
  for (const n of nums) await expect(page.getByTestId('vehicle-delete-removes')).toContainText(n);
  await check(page, 'delete with requests');
  await page.getByTestId('vehicle-delete-confirm').fill(String(pl!.plate));
  await page.getByTestId('vehicle-delete-submit').click();
  await page.waitForURL(/\/admin\/vehicles\?deleted=1/, { timeout: 20_000 });
  const [gone] = await sql`select (select count(*) from vehicles where id = ${sid})::int v, (select count(*) from deleted_booking_requests where booking_number = any(${nums}))::int a,
      (select count(*) from renters where id = ${renter!.id})::int r`;
  expect(gone).toMatchObject({ v: 0, a: 2, r: 1 });

  // Add a rental for a CarmaCars-owned car with a draft listing and no rates
  const [u] = await sql`select app.vehicle_add(${admin.id}, ${sql.json({ supply_type: 'company', vin: vin(), plate: plate(), year: 2024, make: 'Nissan', model: `Sentra ${tag()}` })}) as r`;
  const uid = (u!.r as { vehicle_id: string }).vehicle_id;
  // 0087: a car added without rates gets a rate card from the class defaults and, with "Publish new cars
  // automatically" on, goes live at once; this case is a car with neither, so both are taken back here
  await sql`delete from rate_cards where vehicle_id = ${uid} and auto_defaults ? 'daily'`;
  await sql`update vehicle_listings set status = 'draft' where vehicle_id = ${uid}`;
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await page.getByTestId('mr-vehicle_id').selectOption(uid);
  await expect(page.getByTestId('mr-unlisted-tag')).toContainText('Listing not finished');
  await expect(page.locator(`option[value="${uid}"]`)).toContainText('no rates yet');
  await page.getByTestId('mr-new-renter').check();
  await page.getByTestId('mr-full_name').fill(`Rf Walkin ${tag()}`);
  await page.getByTestId('mr-email').fill(`rf.walkin.${tag()}@example.test`);
  await page.getByTestId('mr-mobile').fill('4165550142');
  await page.getByTestId('mr-date_of_birth').fill('1988-04-12');
  await page.getByTestId('mr-licence_number').fill('R1234-56789-01234');
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-notes')).toContainText('This car has no rates yet', { timeout: 20_000 });
  await expect(page.getByTestId('mr-notes')).toContainText('Listing not finished: the car stays off the public site');
  await page.getByTestId('mr-rental_charge').fill('180');
  await page.getByTestId('mr-price_reason').fill('New car, rate sheet not set yet');
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-price')).toContainText('Total with the price you typed', { timeout: 20_000 });
  await page.getByTestId('mr-paid-by').selectOption('e_transfer');
  await page.getByTestId('mr-reference').fill('ET-RF-1');
  await page.getByTestId('mr-do-not-email').check();
  await check(page, 'add a rental, listing not finished');
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toContainText('Confirmed and on the calendar.', { timeout: 30_000 });
  const number = (await page.getByTestId('mr-done').locator('h2').innerText()).match(/Rental (\S+) added/)![1]!;
  const [bk] = await sql`select status, rental_charge_cents::int c, km_allowance_per_day km, overage_cents_per_km ov from bookings where booking_number = ${number}`;
  expect(bk).toMatchObject({ status: 'confirmed', c: 18000, km: 200, ov: 35 });
  const [pub] = await sql`select count(*)::int n from public_vehicle_listings where vehicle_id = ${uid}`;
  expect(pub!.n).toBe(0);
  await sql.end();
});
