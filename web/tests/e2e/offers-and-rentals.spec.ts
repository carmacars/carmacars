import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, storeFixtureJpeg } from './helpers';

// Migration 0129 end to end, at both widths: an Admin sends an offer without a request (a new customer, a price typed,
// the rental by e-Transfer and the deposit in cash), edits it in place (version 2, no "withdraw to edit"), the renter
// approves and signs, the e-Transfer and the cash deposit are recorded by part and the booking is confirmed; a rental
// input fast (Turo quick start, the platform payout, the deposit by e-Transfer, signed on paper, not blocking the
// calendar); a sales assistant's offer saved without telling the renter; a card collected on the staff device through the
// pay page (the fake Stripe). Each screen is checked with axe, for overflow and for the copy rules.
const PW = 'correct horse battery';
const SHOTS = process.env.OFFER_SHOTS ?? 'test-results/offers-and-rentals';
mkdirSync(SHOTS, { recursive: true });
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b/, 'brand misspelled'], [/coverage price/i, 'two names for the Protection Plan']];
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function mkStaff(sql: Sql, kind: 'admin' | 'va', fn: 'cs' | 'sales' | 'finance' | null, name: string) {
  const id = randomUUID(); const email = `${kind}.of.${Date.now()}.${tag()}@example.test`;
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
  const [r] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin, plate: `OF${randomBytes(2).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as v`;
  return (r!.v as { vehicle_id: string }).vehicle_id;
}
/** The three screens at 390 and 1440 (for the report; the desktop project only). */
async function shots(page: Page, name: string) {
  if (isPhone()) return;
  for (const w of [390, 1440]) {
    await page.setViewportSize({ width: w, height: w < 600 ? 844 : 900 });
    await page.waitForTimeout(300);
    await page.screenshot({ path: `${SHOTS}/${name}-${w}.png`, fullPage: true });
  }
  await page.setViewportSize({ width: 1440, height: 900 });
}

test.describe.configure({ mode: 'serial' });

test('admin: an offer without a request, edited in place, paid by part, confirmed', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkStaff(sql, 'admin', null, `Ada Offers ${tag()}`);
  const car = await mkCar(sql, admin.id);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');

  // A. the offer screen, from Bookings
  await page.goto('/admin/bookings', { waitUntil: 'networkidle' });
  await page.getByTestId('send-offer-link').click();
  await page.waitForURL(/\/admin\/offers\/new/);
  await expect(page.getByTestId('offer-composer')).toBeVisible();
  const email = `nora.${tag()}@example.test`;
  await page.getByTestId('oc-add-customer').click();
  await page.getByTestId('oc-full_name').fill('Nora Offer');
  await page.getByTestId('oc-mobile').fill(`289555${String(Date.now()).slice(-4)}`);
  await page.getByTestId('oc-email').fill(email);
  await page.getByTestId('oc-date_of_birth').fill('1991-02-03');
  await page.getByTestId('oc-vehicle_id').selectOption(car);
  await expect(page.getByTestId('oc-car-free')).toContainText('Free for these dates');
  await page.getByTestId('oc-pm-total').check();
  await page.getByTestId('oc-price_total').fill('250');
  await page.getByTestId('oc-price_reason').fill('Phone deal');
  await page.getByTestId('oc-rental_pay').selectOption('e_transfer');
  await page.getByTestId('oc-deposit_pay').selectOption('cash');
  await page.getByTestId('choice-for_carmacars').check();
  await page.getByTestId('oc-message').fill('As discussed on the phone.');
  // the renter's view, priced by the database: $250 plus 13% HST
  await expect(page.getByTestId('oc-total')).toHaveText('$282.50', { timeout: 15_000 });
  await expect(page.getByTestId('oc-renter-view')).toContainText('You pay by');
  await expect(page.getByTestId('oc-renter-view')).toContainText('e-Transfer');
  await check(page, 'offer screen');
  await shots(page, 'A-send-an-offer');
  await page.getByTestId('oc-send').click();
  await expect(page.getByTestId('offer-sent')).toBeVisible({ timeout: 20_000 });
  const [b] = await sql`select b.id, b.booking_number, b.status, b.current_offer_version, b.rental_pay_method, b.deposit_pay_method, b.rental_charge_cents, r.user_id
                          from bookings b join renters r on r.id = b.renter_id where lower(r.email) = ${email}`;
  expect(`${b!.status}/${b!.current_offer_version}/${b!.rental_pay_method}/${b!.deposit_pay_method}/${b!.rental_charge_cents}`).toBe('offered/1/e_transfer/cash/25000');
  const [ev] = await sql`select count(*)::int n from app_events where entity_id = ${b!.id} and code = 'renter_request_received'`;
  expect(ev!.n).toBe(0);

  // B. edited in place: Edit the offer, the deposit, Save and send the update
  await page.getByTestId('offer-open').click();
  await page.waitForURL(new RegExp(`/admin/bookings/${b!.booking_number}`));
  await page.getByTestId('edit-offer').click();
  await expect(page.getByTestId('review-edit-in-place')).toBeVisible();
  await page.locator('#rv-deposit_cents').fill('400');
  await expect(page.getByTestId('review-price')).toContainText('Re-priced', { timeout: 15_000 });
  await page.getByTestId('review-revise-message').fill('The deposit is $400 for this car.');
  await check(page, 'edit the offer');
  await shots(page, 'B-edit-offer-in-place');
  await page.getByTestId('review-revise-send').click();
  await expect(page.getByTestId('review-revised')).toContainText('Deposit: $300.00 to $400.00', { timeout: 20_000 });
  const [b2] = await sql`select status, current_offer_version, deposit_cents from bookings where id = ${b!.id}`;
  expect(`${b2!.status}/${b2!.current_offer_version}/${b2!.deposit_cents}`).toBe('offered/2/40000');

  // the renter puts their licence on file (0130's gate), approves and signs (their own screens are covered elsewhere)
  const [drv] = await sql`select driver_id from booking_drivers where booking_id = ${b!.id} and role = 'renter'`;
  for (const k of ['licence_front', 'licence_back', 'selfie']) {
    const key = `renters/of/${k}-${tag()}.jpg`;
    storeFixtureJpeg('identity', key);
    await sql`select app.register_verification_upload(${b!.id}, ${b!.user_id}, ${k}, ${drv!.driver_id}, ${key}, ${'e'.repeat(64)}, 'image/jpeg', null, 'identity')`;
  }
  await sql`select public.renter_save_details(${b!.user_id}, ${sql.json({ licence_number: 'N1234-12345-12345', licence_issuer: 'ON', licence_class: 'G', licence_expiry: '2030-01-01' })}, ${b!.id})`;
  await sql`select public.renter_approve_offer(${b!.id}, 2, ${b!.user_id})`;
  await sql`select public.renter_open_agreement(${b!.id}, ${b!.user_id}, 'rental-test', ${'f'.repeat(64)}, ${'bookings/of/x.pdf'})`;
  await sql`select public.renter_sign_agreement(${b!.id}, ${b!.user_id}, 'I agree', ${'f'.repeat(64)},
    ${sql.json([{ code: 'tracking_disabling', version: 'v', text: 't' }, { code: 'identity_verification', version: 'v', text: 't' }, { code: 'electronic_signature', version: 'v', text: 't' }, { code: 'card_authorization', version: 'v', text: 't' }])}, 'Nora Offer')`;

  // payments by part: the rental by e-Transfer confirms it; the deposit in cash
  await page.goto(`/admin/bookings/${b!.booking_number}?tab=money`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('booking-money')).toBeVisible();
  await expect(page.getByTestId('bm-parts')).toContainText('$282.50');
  await page.getByTestId('bm-record-open').click();
  await page.getByTestId('bm-covers').selectOption('rental');
  await page.getByTestId('bm-method').selectOption('e_transfer');
  await page.getByTestId('bm-ref').fill(`CA${tag().toUpperCase()}`);
  await page.getByTestId('bm-record-save').click();
  await expect(page.getByTestId('bm-message')).toContainText('The booking is confirmed', { timeout: 20_000 });
  await page.getByTestId('bm-record-open').click();
  await page.getByTestId('bm-covers').selectOption('deposit');
  await page.getByTestId('bm-method').selectOption('cash');
  await page.getByTestId('bm-record-save').click();
  await expect(page.getByTestId('bm-message')).toContainText('Recorded', { timeout: 20_000 });
  await expect(page.getByTestId('bm-deposit')).toContainText('taken by cash');
  await check(page, 'money by part');
  const pays = await sql`select method, purpose from payments where booking_id = ${b!.id} order by purpose`;
  expect(pays.map((p) => `${p.method}:${p.purpose}`).join(',')).toBe('e_transfer:booking_total,cash:deposit');
  const [b3] = await sql`select status from bookings where id = ${b!.id}`;
  expect(b3!.status).toBe('confirmed');
  await sql.end();
});

test('a rental input fast: Turo, paid on the platform, deposit by e-Transfer, signed on paper, not blocking', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkStaff(sql, 'admin', null, `Ada Rentals ${tag()}`);
  const car = await mkCar(sql, admin.id);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await page.getByTestId('mr-preset-turo').click();
  await page.getByTestId('mr-vehicle_id').selectOption(car);
  await page.getByTestId('mr-new-renter').check();
  const email = `tess.${tag()}@example.test`;
  await page.getByTestId('mr-full_name').fill('Tess Turo');
  await page.getByTestId('mr-email').fill(email);
  await page.getByTestId('mr-mobile').fill('4165550190');
  await page.getByTestId('mr-date_of_birth').fill('1990-03-04');
  await page.getByTestId('mr-licence_number').fill('T1234-56789-01234');
  // the calendar and the price are checked by themselves
  await expect(page.getByTestId('mr-quote')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('mr-paid-by')).toHaveValue('platform_payout');
  await page.getByTestId('mr-reference').fill('TURO-12345');
  await page.getByTestId('mr-deposit-by').selectOption('e_transfer');
  await page.getByTestId('mr-deposit_reference').fill('DEP-778');
  await page.getByTestId('mr-agreement-paper').check();
  await page.getByTestId('mr-blocks').uncheck();
  await page.getByTestId('mr-blocks_reason').fill('Turo holds the dates');
  await check(page, 'add a rental');
  await shots(page, 'C-input-a-rental');
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toBeVisible({ timeout: 20_000 });
  const [b] = await sql`select b.id, b.status, b.rental_pay_method, b.deposit_pay_method, b.agreement_on_paper, b.blocks_calendar from bookings b join renters r on r.id = b.renter_id where lower(r.email) = ${email}`;
  expect(`${b!.status}/${b!.rental_pay_method}/${b!.deposit_pay_method}/${b!.agreement_on_paper}/${b!.blocks_calendar}`).toBe('confirmed/platform_payout/e_transfer/true/false');
  const pays = await sql`select method, purpose from payments where booking_id = ${b!.id} order by purpose`;
  expect(pays.map((p) => `${p.method}:${p.purpose}`).join(',')).toBe('platform_payout:booking_total,e_transfer:deposit');

  // a card collected on this device: the fake Stripe form on the pay page, for a later charge
  await page.goto(`/admin/bookings/${(await sql`select booking_number from bookings where id = ${b!.id}`)[0]!.booking_number}?tab=money`, { waitUntil: 'networkidle' });
  await page.getByTestId('bm-collect-open').click();
  await page.getByTestId('bm-kind').selectOption('charge');
  await page.locator('#bm-ccovers').selectOption('later');
  await page.getByTestId('bm-camount').fill('45');
  await page.getByTestId('bm-creason').fill('Fuel');
  await page.getByTestId('bm-ch-device').check();
  await page.getByTestId('bm-collect-go').click();
  await page.waitForURL(/\/pay\/[A-Za-z0-9_-]{20,}/, { timeout: 20_000 });
  await expect(page.getByTestId('paylink-what')).toContainText('$45.00 for fuel');
  await page.locator('#pl-name').fill('Tess Turo');
  await page.locator('#pl-num').fill('4242 4242 4242 4242');
  await page.locator('#pl-exp').fill('12 / 30');
  await page.locator('#pl-cvc').fill('123');
  await check(page, 'pay page');
  await page.getByTestId('paylink-submit').click();
  await expect(page.getByTestId('paylink-done')).toBeVisible({ timeout: 20_000 });
  const [c] = await sql`select count(*)::int n from payments where booking_id = ${b!.id} and method = 'card' and purpose = 'post_rental' and status = 'succeeded'`;
  expect(c!.n).toBe(1);
  await sql.end();
});

test('sales: an offer saved without telling the renter', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const admin = await mkStaff(sql, 'admin', null, `Ada Setup ${tag()}`);
  const sales = await mkStaff(sql, 'va', 'sales', `Sam Sales ${tag()}`);
  const car = await mkCar(sql, admin.id);
  const page = await ctx(browser);
  await signIn(page, sales.email, '/va');
  await page.goto(`/va/offers/new?car=${car}`, { waitUntil: 'networkidle' });
  await page.getByTestId('oc-add-customer').click();
  const email = `sid.${tag()}@example.test`;
  await page.getByTestId('oc-full_name').fill('Sid Sales');
  await page.getByTestId('oc-mobile').fill(`905555${String(Date.now()).slice(-4)}`);
  await page.getByTestId('oc-email').fill(email);
  await page.getByTestId('oc-date_of_birth').fill('1989-07-08');
  await expect(page.getByTestId('oc-vehicle_id')).toHaveValue(car);
  // an assistant does not see the deposit, discounts or fees
  await expect(page.getByTestId('oc-deposit')).toHaveCount(0);
  await expect(page.getByTestId('oc-total')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('oc-send').click();
  await expect(page.getByTestId('oc-error')).toContainText('who found this client');
  await page.getByTestId('choice-sourced').check();
  await page.getByTestId('oc-by-email').uncheck();
  await expect(page.getByTestId('oc-send')).toHaveText('Make the offer (not sent)');
  await check(page, 'sales offer screen');
  await page.getByTestId('oc-send').click();
  await expect(page.getByTestId('offer-sent')).toContainText('Not sent to the renter', { timeout: 20_000 });
  const [b] = await sql`select b.id, b.status, b.sales_sourced from bookings b join renters r on r.id = b.renter_id where lower(r.email) = ${email}`;
  expect(`${b!.status}/${b!.sales_sourced}`).toBe('offered/true');
  const [e] = await sql`select count(*)::int n from app_events where entity_id = ${b!.id} and code = 'renter_offer_ready'`;
  expect(e!.n).toBe(0);
  await sql.end();
});
