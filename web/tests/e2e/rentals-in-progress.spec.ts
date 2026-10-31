import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, strongSign, completeAgreementDetails } from './helpers';

// Migration 0074 end to end: Add a rental decides the case from the dates, with nothing to tick. An Admin adds the
// owner's case (the car went out yesterday, back in five days), recorded as on trip; the form says which case it is
// for upcoming, underway and ended dates; an assistant adds a rental already underway with a payment link on a car
// closed to public bookings, and is told plainly that an ended rental is an Admin's. Every page is checked with axe,
// for overflow at 375 and 1440 pixels, and for the copy rules.
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
const vin = () => `2T1BU4EE${randomBytes(5).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `E2E${randomBytes(2).toString('hex').toUpperCase()}`;
const pad = (n: number) => String(n).padStart(2, '0');
const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
const fromNow = (hours: number) => { const d = new Date(Date.now() + hours * 3_600_000); d.setSeconds(0, 0); return d; };

async function mkUser(sql: Sql, kind: 'admin' | 'va' | 'renter', name: string) {
  const id = randomUUID(); const email = `${kind}.ip.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (kind === 'renter') {
    await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, ${name}, ${email}, '+14165550142', '1988-04-12')
              on conflict (user_id) do update set date_of_birth = excluded.date_of_birth, mobile = excluded.mobile`;
    return { id, email, name };
  }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  if (kind === 'admin') await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  if (kind === 'va') { await sql`insert into user_roles (user_id, role) values (${id}, 'va')`; await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs')`; }
  return { id, email, name };
}
async function mkCar(sql: Sql, adminId: string, model: string) {
  const [car] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin: vin(), plate: plate(), year: 2022, make: 'Chevrolet', model,
    rates: { daily: 6900, weekend: 7900, weekly: 42000, monthly: 150000, deposit: 30000 } })}) as r`;
  return (car!.r as { vehicle_id: string }).vehicle_id;
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
async function dates(page: Page, pickupHours: number, returnHours: number) {
  await page.getByTestId('mr-pickup_at').fill(local(fromNow(pickupHours)));
  await page.getByTestId('mr-return_at').fill(local(fromNow(returnHours)));
}

test.describe.configure({ mode: 'serial' });

test('Admin: a rental already underway, recorded as on trip, with the case shown for each set of dates', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const renter = await mkUser(sql, 'renter', `Robin Underway ${tag()}`);
  const carId = await mkCar(sql, admin.id, `Malibu ${tag()}`);
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await page.goto('/admin/bookings/new', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('mr-past')).toHaveCount(0);
  await page.getByTestId('mr-vehicle_id').selectOption(carId);

  // the form says which case the dates make, and changes with them
  await dates(page, 30, 72);
  await expect(page.getByTestId('mr-phase')).toHaveAttribute('data-phase', 'upcoming');
  await expect(page.getByTestId('mr-phase')).toContainText('starts in the future');
  await dates(page, -100, -50);
  await expect(page.getByTestId('mr-phase')).toHaveAttribute('data-phase', 'past');
  await expect(page.getByTestId('mr-phase')).toContainText('recorded as completed');
  await expect(page.getByTestId('mr-submit')).toHaveText('Record the past rental');
  await dates(page, -24, 5 * 24);
  await expect(page.getByTestId('mr-phase')).toHaveAttribute('data-phase', 'in_progress');
  await expect(page.getByTestId('mr-phase')).toContainText('This rental is already underway: it will be recorded as on trip');
  await check(page, 'add a rental, underway');

  await page.getByTestId('mr-renter-q').fill(renter.name);
  await page.getByTestId('mr-renter-search').click();
  await page.getByTestId('mr-renter-results').getByRole('button', { name: renter.name }).click();
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-free')).toBeVisible({ timeout: 20_000 });
  // a rental underway may be paid by link or card (unlike one that has ended)
  await expect(page.getByTestId('mr-paid-by').locator('option[value="link"]')).toHaveCount(1);
  await page.getByTestId('mr-paid-by').selectOption('e_transfer');
  await page.getByTestId('mr-reference').fill('ET-UNDERWAY');
  await page.getByTestId('mr-do-not-email').check();
  await check(page, 'add a rental, underway, priced');
  await expect(page.getByTestId('mr-submit')).toHaveText('Add the rental already underway');
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toContainText('Recorded as on trip', { timeout: 30_000 });
  await expect(page.getByTestId('mr-error')).toHaveCount(0);
  const number = (await page.getByTestId('mr-done').locator('h2').innerText()).match(/Rental (\S+) added/)![1]!;
  await check(page, 'rental underway added');
  const [bk] = await sql`select b.status, b.added_mode, b.handed_over_at = b.pickup_at as at_pickup, v.status as car,
                                (select count(*) from tasks t where t.booking_id = b.id and t.task_type like 'live_rental_%') as tasks
                           from bookings b join vehicles v on v.id = b.vehicle_id where b.booking_number = ${number}`;
  expect(`${bk!.status}/${bk!.added_mode}/${bk!.at_pickup}/${bk!.car}`).toBe('on_rent/in_progress/true/on_rent');
  expect(Number(bk!.tasks)).toBeGreaterThan(0);

  // the booking page says how it was added
  await page.getByTestId('mr-open').click();
  await expect(page.getByTestId('booking-added')).toContainText('while already underway');
  await check(page, 'booking added underway');
  await page.context().close();
  await sql.end();
});

test('assistant: a rental already underway on a car closed to public bookings, with a payment link; an ended one is an Admin\'s', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const va = await mkUser(sql, 'va', `Val Assistant ${tag()}`);
  const carId = await mkCar(sql, admin.id, `Closed ${tag()}`);
  await sql`update vehicles set bookings_enabled = false where id = ${carId}`;
  const page = await ctx(browser);
  await signIn(page, va.email, '/staff');
  await page.goto('/staff/bookings/new', { waitUntil: 'networkidle' });
  await page.getByTestId('mr-vehicle_id').selectOption(carId);
  await expect(page.getByTestId('mr-vehicle_id').locator(`option[value="${carId}"]`)).toContainText('closed to new bookings');

  // an ended rental: said before anything is checked
  await dates(page, -100, -50);
  await expect(page.getByTestId('mr-phase')).toContainText('Only an Admin can record it');
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-error')).toContainText('Only an Admin can record it');

  // underway: on a car closed to public bookings, paid by link
  await dates(page, -5, 48);
  await expect(page.getByTestId('mr-phase')).toHaveAttribute('data-phase', 'in_progress');
  if (!(await page.getByTestId('mr-new-renter').isChecked())) await page.getByTestId('mr-new-renter').check();
  await page.getByTestId('mr-full_name').fill(`Casey Underway ${tag()}`);
  await page.getByTestId('mr-email').fill(`casey.ip.${tag()}@example.test`);
  await page.getByTestId('mr-mobile').fill('4165550199');
  await page.getByTestId('mr-date_of_birth').fill('1990-02-03');
  await page.getByTestId('mr-licence_number').fill('C1234-56789-01234');
  await page.getByTestId('mr-licence_expiry').fill('2030-01-31');
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-free')).toBeVisible({ timeout: 20_000 });
  await page.getByTestId('mr-paid-by').selectOption('link');
  await expect(page.getByTestId('manual-rental')).toContainText('The rental is on trip already.');
  await page.getByTestId('choice-for_carmacars').check();
  await check(page, 'va add a rental underway');
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toContainText('Recorded as on trip', { timeout: 30_000 });
  await expect(page.getByTestId('mr-pay-online')).toBeVisible();
  const number = (await page.getByTestId('mr-done').locator('h2').innerText()).match(/Rental (\S+) added/)![1]!;
  await check(page, 'va rental underway added');
  const [bk] = await sql`select b.status, b.payment_mode, app.booking_link_due(b) as due from bookings b where b.booking_number = ${number}`;
  expect(`${bk!.status}/${bk!.payment_mode}/${bk!.due}`).toBe('on_rent/link/true');

  // an upcoming rental on the same closed car: refused with what to do
  await page.getByRole('button', { name: 'Add another' }).click();
  await page.getByTestId('mr-vehicle_id').selectOption(carId);
  await dates(page, 24 * 20, 24 * 22);
  await expect(page.getByTestId('mr-closed-car')).toBeVisible();
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-error')).toContainText('ask an Admin to open it for bookings', { timeout: 20_000 });
  await check(page, 'va closed car upcoming');
  await page.context().close();
  await sql.end();
});

test('renter: a rental already underway with a payment link: sign in the portal, then pay; it stays on trip', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const renter = await mkUser(sql, 'renter', `Morgan Underway${tag()}`);
  const carId = await mkCar(sql, admin.id, `Paylink ${tag()}`);
  const [rid] = await sql`select id from renters where user_id = ${renter.id}`;
  const [made] = await sql`select app.manual_rental_create(${admin.id}, ${sql.json({ vehicle_id: carId, pickup_at: fromNow(-6).toISOString(), return_at: fromNow(72).toISOString(),
    source: 'phone', coverage_option: 1, renter_id: rid!.id as string, payment: { mode: 'link' } })}) as r`;
  const number = (made!.r as { booking_number: string }).booking_number;
  const page = await ctx(browser);
  await signIn(page, renter.email, '/account');
  await page.goto(`/account/bookings/${number}`, { waitUntil: 'networkidle' });
  await check(page, 'renter: rental underway');
  await page.getByTestId('live-sign').click();
  await page.waitForURL(new RegExp(`/account/bookings/${number}/sign`), { timeout: 20_000 });
  // decide only once the page has rendered either the details form or the agreement (on a phone the form can arrive later)
  await expect(page.locator('#pt-d-address_line1').or(page.getByTestId('complete-details')).or(page.locator('.agreement')).first()).toBeVisible({ timeout: 30_000 });
  if (await page.locator('#pt-d-address_line1').isVisible()) {
    await page.locator('#pt-d-address_line1').fill('100 Queen Street West');
    await page.locator('#pt-d-city').fill('Toronto');
    await page.locator('#pt-d-postal_code').fill('M5H 2N2');
    await page.locator('#pt-d-licence_number').fill('W1234-56789-01234');
    await page.locator('#pt-d-licence_expiry').fill('2031-06-30');
    await page.getByRole('button', { name: 'Save details' }).click();
    await completeAgreementDetails(page);
    await expect(page.locator('.agreement')).toContainText('100 Queen Street West', { timeout: 15_000 });
  }
  await completeAgreementDetails(page);
  await expect(page.getByTestId('sign-pay-after')).toBeVisible();
  await check(page, 'renter: sign a rental underway');
  await page.getByTestId('consents-all').check();
  await strongSign(page);
  await page.getByRole('button', { name: 'Sign the agreement' }).click();
  await page.waitForURL(new RegExp(`/account/bookings/${number}/pay`), { timeout: 30_000 });
  await expect(page.getByRole('heading', { name: 'Pay for your rental' })).toBeVisible();
  await expect(page.getByTestId('fake-card')).toBeVisible();
  await check(page, 'renter: pay a rental underway');
  await page.locator('#pt-card-name').fill(renter.name);
  await page.locator('#pt-card-number').fill('4242 4242 4242 4242');
  await page.locator('#pt-card-exp').fill('12 / 30');
  await page.locator('#pt-card-cvc').fill('123');
  await page.getByRole('button', { name: /^Pay \$/ }).click();
  await page.waitForURL(new RegExp(`/account/bookings/${number}\\?paid=1`), { timeout: 30_000 });
  await expect(page.getByTestId('paid-live-panel')).toContainText('Paid, thank you');
  await check(page, 'renter: paid a rental underway');
  const [bk] = await sql`select b.status::text, app.booking_link_due(b) due, b.card_on_file_id is not null card,
      (select string_agg(p.status, ',') from payments p where p.booking_id = b.id and p.purpose = 'booking_total') pay,
      (select a.status from rental_agreements a where a.booking_id = b.id and a.status = 'completed') agreement
    from bookings b where b.booking_number = ${number}`;
  expect(bk).toMatchObject({ status: 'on_rent', due: false, card: true, pay: 'succeeded', agreement: 'completed' });
  await page.context().close();
  await sql.end();
});
