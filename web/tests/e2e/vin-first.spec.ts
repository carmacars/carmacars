import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { expectedCheckDigit } from '../../src/features/vin/vin';
import { acceptCookies, aiAllowanceLock, db, fillYmm, noOverflow, tapColour } from './helpers';

// Migration 0082 end to end, at 375 and 1440 pixels: a car added from its VIN alone at every entry point (Admin > Add a
// car, Add a car for an owner by an Admin and by customer service, the owner's own application). The fake decoder
// (VIN_DECODER=fake, src/integrations/vin.ts) knows the maker codes WP1 (Porsche Macan), 1FM (Ford Explorer), 1G6
// (Cadillac CTS) and 2HG (Honda Civic); ZZZ is "not decoded". Each test makes VINs of its own with a valid check digit.
const SHOTS = 'test-results/vin-first';
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });

const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const tag = () => randomBytes(3).toString('hex');
const CH = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
/** A VIN with the maker code, a valid check digit and a random serial. */
function vin(wmi: string, year = 'G'): string {
  let s = wmi.padEnd(8, 'A');
  s = `${s}0${year}${Array.from({ length: 7 }, () => CH[Math.floor(Math.random() * CH.length)]).join('')}`;
  return s.slice(0, 8) + expectedCheckDigit(s)! + s.slice(9);
}
const wrongCheck = (v: string) => v.slice(0, 8) + (v[8] === '1' ? '2' : '1') + v.slice(9);
const plate = () => `VF${randomBytes(2).toString('hex').toUpperCase()}`;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const shot = (page: Page, name: string) => page.screenshot({ path: `${SHOTS}/${test.info().project.name}-${name}.png`, fullPage: true });

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function mkUser(sql: Sql, kind: 'admin' | 'cs') {
  const id = randomUUID(); const email = `${kind}.vf.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Vf ${kind} ${tag()}`})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  else {
    await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
    await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs')`;
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
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 120_000 });
  return page;
}
/** The daily rate the database starts a car at (0070: similar real cars, else the class default). */
const startRate = async (sql: Sql, cls: string, make: string, model: string) => {
  const [r] = await sql`select (app.listing_default_daily(null, ${sql.json({ class: cls, make, model })}) ->> 'daily_cents')::int as c`;
  return r!.c as number;
};


// the AI allowance lock (helpers.ts) of a car copy test, let go when it ends, passed or not
let unlockAi: (() => Promise<void>) | undefined;
test.afterEach(async () => { await unlockAi?.(); unlockAi = undefined; });

test('Admin > Add a car from the VIN alone: one summary line, the class and the rate from it, the colour in one tap; the copy is written right after', async ({ browser }) => {
  test.setTimeout(1_500_000);
  unlockAi = await aiAllowanceLock('shared');   // the AI copy is written right after: not while the allowance is used up
  const sql = db();
  await sql`update program_settings set seo_ai_writer_enabled = true`;   // 0133: the site's own copy writer is off by default (the daily Claude batch writes); this test checks the writer
  const admin = await mkUser(sql, 'admin');
  const page = await signedIn(browser, admin.email, '/admin');
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  const v = vin('WP1AB2A5');

  // a VIN that does not add up is said in words, and can still be used
  await page.getByTestId('add-car-vin').fill(wrongCheck(v));
  await expect(page.getByTestId('add-car-vin-status')).toContainText('does not add up', { timeout: 90_000 });
  await page.getByTestId('add-car-vin').fill(`${v.slice(0, 16)}O`);
  await expect(page.getByTestId('add-car-vin-status')).toContainText('O is probably 0');

  await page.getByTestId('add-car-vin').fill(v.toLowerCase());
  const sum = page.getByTestId('add-car-summary');
  await expect(sum).toContainText('2016 Porsche Macan S', { timeout: 90_000 });
  await expect(sum).toContainText('SUV · 5 seats · 5 doors · Gas · All-wheel drive · Automatic · 3.0 L, V6, turbo');
  await expect(page.getByTestId('add-car-year')).toHaveCount(0);   // no inputs for what the VIN says
  await expect(page.getByTestId('add-car-class')).toHaveValue('premium');
  await expect(page.getByTestId('add-car-class-why')).toContainText('Premium: a Porsche');
  // the daily rate starts from similar Porsche Macans, else the Premium class, never from the Standard class
  const start = await startRate(sql, 'premium', 'Porsche', 'Macan');
  await expect(page.getByTestId('add-car-daily')).toHaveValue(String(start / 100), { timeout: 90_000 });
  await tapColour(page, 'add-car', 'Blue');
  await page.getByTestId('add-car-supply-company').check();
  await check(page, 'add car decoded');
  await shot(page, 'add-car');
  await page.getByTestId('add-car-submit').click();
  await page.waitForURL(/\/admin\/vehicles\/[0-9a-f-]{36}\?added=1/, { timeout: 120_000 });
  const id = page.url().match(/vehicles\/([0-9a-f-]{36})/)![1]!;
  const [car] = await sql`select v.year, v.make, v.model, v.trim, v.class::text, v.colour, v.spec_sources #>> '{class,source}' as cls, l.seats, l.doors, l.drivetrain, l.transmission, l.headline
    from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.id = ${id}`;
  expect([car!.year, car!.make, car!.model, car!.trim, car!.class, car!.colour, car!.cls, car!.seats, car!.doors, car!.drivetrain, car!.transmission])
    .toEqual([2016, 'Porsche', 'Macan', 'S', 'premium', 'Blue', 'inferred', 5, 5, 'All-wheel drive', 'Automatic']);
  expect(car!.headline).toMatch(/^2016 Porsche Macan S/);
  // the title, description and features: queued at once, written by the search job right after the response
  await expect.poll(async () => (await sql`select source from car_copy where vehicle_id = ${id}`)[0]?.source, { timeout: 60_000 }).toBe('ai');

  // the same VIN again: the car already in the fleet, with a link to it
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  await page.getByTestId('add-car-vin').fill(v);
  await expect(page.getByTestId('add-car-taken')).toContainText('Already in the fleet: 2016 Porsche Macan S', { timeout: 90_000 });
  await page.context().close();
  await sql.end();
});

test('Admin > Add a car: a VIN the decoder cannot read asks only year, make and model from lists; by plate the same; never blocked', async ({ browser }) => {
  test.setTimeout(1_500_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin');
  const page = await signedIn(browser, admin.email, '/admin');
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  const v = vin('ZZZZZ123', 'L');
  await page.getByTestId('add-car-vin').fill(v);
  await expect(page.getByTestId('add-car-fallback')).toContainText('could not be read', { timeout: 90_000 });
  await fillYmm(page, 'add-car', { year: '2021', make: 'Ford', model: 'Mustang' });
  await expect(page.getByTestId('add-car-class')).toHaveValue('premium', { timeout: 60_000 });
  await expect(page.getByTestId('add-car-class-why')).toContainText('a sports model');
  // a person's class is theirs
  await page.getByTestId('add-car-class').selectOption('luxury');
  await expect(page.getByTestId('add-car-class-why')).toContainText('Chosen by you');
  await page.getByTestId('add-car-supply-company').check();
  await check(page, 'add car not decoded');
  await shot(page, 'add-car-fallback');
  await page.getByTestId('add-car-submit').click();
  await page.waitForURL(/\/admin\/vehicles\/[0-9a-f-]{36}\?added=1/, { timeout: 120_000 });
  const id = page.url().match(/vehicles\/([0-9a-f-]{36})/)![1]!;
  const [a] = await sql`select year, make, model, class::text, spec_sources #>> '{class,source}' as cls from vehicles where id = ${id}`;
  expect([a!.year, a!.make, a!.model, a!.class, a!.cls]).toEqual([2021, 'Ford', 'Mustang', 'luxury', 'person']);

  // by plate
  await page.goto('/admin/vehicles/new', { waitUntil: 'networkidle' });
  await page.getByTestId('add-car-use-plate').click();
  const p = plate();
  await page.getByTestId('add-car-plate').fill(p);
  await fillYmm(page, 'add-car', { year: '2020', make: 'Honda', model: 'CR-V' });
  await expect(page.getByTestId('add-car-class-why')).toContainText('Standard', { timeout: 60_000 });
  await page.getByTestId('add-car-supply-company').check();
  await page.getByTestId('add-car-submit').click();
  await page.waitForURL(/\/admin\/vehicles\/[0-9a-f-]{36}\?added=1/, { timeout: 120_000 });
  const [b] = await sql`select vin, make, model from vehicles where plate = ${p}`;
  expect([b!.vin, b!.make, b!.model]).toEqual([null, 'Honda', 'CR-V']);
  await page.context().close();
  await sql.end();
});

test('Add a car for an owner (Admin): the VIN fills the car; an SUV is SUV; the copy is queued', async ({ browser }) => {
  test.setTimeout(1_500_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin');
  const page = await signedIn(browser, admin.email, '/admin');
  await page.goto('/admin/owners/add-car', { waitUntil: 'networkidle' });
  const f = page.getByTestId('addcar');
  await f.getByTestId('addcar-new-owner').check();
  await f.getByTestId('addcar-legal_name').fill(`Vera Vinfirst ${tag()}`);
  await f.getByTestId('addcar-email').fill(`vera.${tag()}@example.test`);
  await f.getByTestId('addcar-phone').fill('+16475550177');
  const v = vin('1FM5K8D8', 'L');
  await f.getByTestId('addcar-vin').fill(v);
  await expect(f.getByTestId('addcar-summary')).toContainText('2020 Ford Explorer XLT', { timeout: 90_000 });
  await expect(f.getByTestId('addcar-summary')).toContainText('7 seats');
  await expect(f.getByTestId('addcar-class')).toHaveValue('suv');
  // Edit opens the fields with the decoded values
  await f.getByTestId('addcar-edit').click();
  await expect(f.getByTestId('addcar-edit-model')).toHaveValue('Explorer');
  await f.getByTestId('addcar-edit-trim').fill('XLT Sport');
  await tapColour(page, 'addcar', 'White');
  await check(page, 'admin add car for an owner');
  await shot(page, 'admin-add-car-owner');
  await f.getByTestId('addcar-submit').click();
  await expect(page.getByTestId('addcar-done')).toBeVisible({ timeout: 120_000 });
  const [c] = await sql`select v.year, v.model, v.trim, v.class::text, v.colour, l.seats, (select count(*)::int from car_copy cc where cc.vehicle_id = v.id) as copy
    from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.vin = ${v}`;
  expect([c!.year, c!.model, c!.trim, c!.class, c!.colour, c!.seats, c!.copy]).toEqual([2020, 'Explorer', 'XLT Sport', 'suv', 'White', 7, 1]);
  await page.context().close();
  await sql.end();
});

test('Add a car for an owner (customer service): the VIN alone; a Cadillac CTS is Premium, not Standard', async ({ browser }) => {
  test.setTimeout(1_500_000);
  const sql = db();
  const cs = await mkUser(sql, 'cs');
  const page = await signedIn(browser, cs.email, '/va');
  await page.goto('/va/owners/add-car', { waitUntil: 'networkidle' });
  const f = page.getByTestId('addcar');
  await f.getByTestId('addcar-new-owner').check();
  await f.getByTestId('addcar-legal_name').fill(`Cal Vinfirst ${tag()}`);
  await f.getByTestId('addcar-email').fill(`cal.${tag()}@example.test`);
  await f.getByTestId('addcar-phone').fill('+16475550178');
  const v = vin('1G6AX5SX', 'F');
  await f.getByTestId('addcar-vin').fill(v);
  await expect(f.getByTestId('addcar-summary')).toContainText('2015 Cadillac CTS Luxury', { timeout: 90_000 });
  await expect(f.getByTestId('addcar-class')).toHaveValue('premium');
  await check(page, 'va add car for an owner');
  await shot(page, 'va-add-car-owner');
  await f.getByTestId('addcar-submit').click();
  await expect(page.getByTestId('addcar-done')).toContainText('Sent to an Admin', { timeout: 120_000 });
  const [c] = await sql`select v.make, v.model, v.class::text, v.colour, l.drivetrain from vehicles v join vehicle_listings l on l.vehicle_id = v.id where v.vin = ${v}`;
  expect([c!.make, c!.model, c!.class, c!.colour, c!.drivetrain]).toEqual(['Cadillac', 'CTS', 'premium', null, 'All-wheel drive']);
  await page.context().close();
  await sql.end();
});

test('the owner\'s application: the VIN finds the car as the last character is typed; one tap for the colour; not decoded, three lists', async ({ page }) => {
  test.setTimeout(1_500_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await page.goto('/list-your-car/apply', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('label:has-text("An individual")').click();
  await page.locator('#ap-first').fill('Vina');
  await page.locator('#ap-last').fill('Applicant');
  await page.locator('#ap-email').fill(`vina.${tag()}@example.test`);
  await page.locator('#ap-addr').fill('union');
  await page.getByRole('option', { name: /Union Station/ }).click();
  await page.locator('#ap-postal').fill('m5j 1e6');
  await page.locator('#ap-phone').fill('647-555-0102');
  await page.locator('#ap-lic').fill('O1234-56789-01234');
  await page.locator('#ap-dob').fill('1985-05-05');
  await page.getByRole('button', { name: 'Continue to vehicles' }).click();
  await page.locator('#ap-v0-vin').fill(vin('2HGFC2F5', 'K'));
  const sum = page.getByTestId('apply-vin-summary');
  await expect(sum).toContainText('2019 Honda Civic LX', { timeout: 90_000 });
  await expect(sum).toContainText('Sedan · 5 seats · 4 doors · Gas');
  await page.getByTestId('apply-vin-edit').click();
  await expect(page.locator('#ap-v0-model')).toHaveValue('Civic');
  await tapColour(page, 'apply', 'Red');
  await expect(page.getByTestId('apply-colour-red')).toBeChecked();
  await check(page, 'owner application decoded');
  await shot(page, 'apply-vehicle');
  // a VIN the decoder cannot read: year, make and model from lists
  await page.locator('#ap-v0-vin').fill(vin('ZZZZZ123', 'L'));
  await expect(page.getByTestId('apply-ymm')).toBeVisible({ timeout: 90_000 });
  await fillYmm(page, 'apply', { year: '2018', make: 'Toyota', model: 'Camry' });
  await expect(page.getByTestId('apply-model')).toHaveValue('Camry');
  await check(page, 'owner application not decoded');
  await sql.end();
});
