import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0058 end to end, at 375 and 1440: customer service adds a rental with a price typed by hand and "I sourced
// this client" (flagged as past the discount limit); finance adds one "Entered for CarmaCars"; field staff add one from
// the field portal; a rental completed and paid shows its commission pending approval on My sales; an Admin approves it
// and records the payment; a refund reverses it; the flagged price is reviewed; Sales sees the month's target. Every page
// is checked with axe, for overflow and for the copy rules.
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
const vin = () => `3SCMX${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `C${randomBytes(3).toString('hex').toUpperCase()}`;

async function mkUser(sql: Sql, kind: 'admin' | 'va' | 'field' | 'renter', name: string, fn?: 'cs' | 'sales' | 'finance' | 'fleet') {
  const id = randomUUID(); const email = `${kind}${fn ?? ''}.sc.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (kind === 'renter') {
    await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, ${name}, ${email}, '+14165550142', '1988-04-12')
              on conflict (user_id) do update set date_of_birth = excluded.date_of_birth, mobile = excluded.mobile`;
    const [r] = await sql`select id from renters where user_id = ${id}`;
    await sql`insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, licence_number) values (${r!.id as string}, true, ${id}, ${name}, '1988-04-12', 'G', 'R1234-56789-01234')
              on conflict do nothing`;
    return { id, email, name, renterId: r!.id as string };
  }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${kind})`;
  if (kind === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function, single_limit_cents) values (${id}, 'va', ${fn ?? 'cs'}, 500000)`;
  if (kind === 'field') await sql`insert into staff_profiles (user_id, staff_type, field_function) values (${id}, 'field', 'driver_detailer')`;
  return { id, email, name, renterId: '' };
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
async function companyCar(sql: Sql, adminId: string) {
  const [car] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin: vin(), plate: plate(), year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as r`;
  return (car!.r as { vehicle_id: string }).vehicle_id;
}
const pad = (n: number) => String(n).padStart(2, '0');
const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T10:00`;

// fill the Add a rental form for a new renter and check the calendar and the price
async function fillRental(page: Page, carId: string, days: number, opts: { field?: boolean } = {}) {
  const pick = new Date(Date.now() + days * 86_400_000);
  await page.getByTestId('mr-vehicle_id').selectOption(carId);
  await page.getByTestId('mr-pickup_at').fill(local(pick));
  await page.getByTestId('mr-return_at').fill(local(new Date(pick.getTime() + 3 * 86_400_000)));
  if (!opts.field && !(await page.getByTestId('mr-new-renter').isChecked())) await page.getByTestId('mr-new-renter').check();
  await page.getByTestId('mr-date_of_birth').fill('1991-07-08');
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-quote')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('mr-free')).toBeVisible();
  await page.getByTestId('mr-full_name').fill(`Riley Caller ${tag()}`);
  await page.getByTestId('mr-email').fill(`riley.${tag()}@example.test`);
  await page.getByTestId('mr-mobile').fill('4165550123');
  await page.getByTestId('mr-licence_number').fill('R1234-56789-01234');
  await page.getByTestId('mr-licence_expiry').fill('2031-01-31');
  await page.getByTestId('mr-mode-link').check();
}
const doneNumber = async (page: Page) => (await page.getByTestId('mr-done').locator('h2').innerText()).match(/Rental (\S+) added/)![1]!;

test.describe.configure({ mode: 'serial' });

test('Staff add rentals: a typed price and "I sourced this client", "Entered for CarmaCars", and field staff', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const cs = await mkUser(sql, 'va', `Casey Service ${tag()}`, 'cs');
  const fin = await mkUser(sql, 'va', `Finn Finance ${tag()}`, 'finance');
  const field = await mkUser(sql, 'field', `Frankie Field ${tag()}`);
  const carId = await companyCar(sql, admin.id);
  const days = 60 + Math.floor(Math.random() * 300);

  // customer service: a price typed by hand (30% under the rate sheet) and "I sourced this client"
  const page = await ctx(browser);
  await signIn(page, cs.email, '/va');
  await page.goto('/va/bookings/new', { waitUntil: 'networkidle' });
  await fillRental(page, carId, days);
  await expect(page.getByTestId('mr-custom-price')).toContainText('$300.00');
  await page.getByTestId('mr-rental_charge').fill('210');
  await page.getByTestId('mr-price_reason').fill('Returning customer, matched a competitor quote');
  await expect(page.getByTestId('mr-price-flag')).toContainText('more than 20% under the rate sheet');
  // the choice is required
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-error')).toContainText('I sourced this client');
  await page.getByTestId('choice-sourced').check();
  await check(page, 'cs add a rental, sourced, typed price');
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toBeVisible({ timeout: 30_000 });
  await expect(page.getByTestId('mr-done-choice')).toContainText('Marked as sourced by you');
  await expect(page.getByTestId('mr-done-choice')).toContainText('flagged for an Admin');
  const n1 = await doneNumber(page);
  const [b1] = await sql`select b.rental_charge_cents::int rc, b.rate_sheet_rental_cents::int rs, b.sales_sourced, array_to_string(b.price_flags, ',') flags,
    (select status from staff_commissions c where c.booking_id = b.id and c.kind = 'commission') cstatus from bookings b where b.booking_number = ${n1}`;
  expect(`${b1!.rc}/${b1!.rs}/${b1!.sales_sourced}/${b1!.flags}/${b1!.cstatus}`).toBe('21000/30000/true/discount_over_limit/accruing');
  // My sales: the commission not earned yet, at 10%
  await page.goto('/va/my-sales', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('commission-rate')).toContainText('10%');
  await expect(page.getByTestId(`commission-status-${n1}-commission`)).toContainText('Not earned yet');
  await expect(page.getByTestId('sales-deals').locator('tr', { hasText: n1 })).toContainText('sourced');
  await check(page, 'cs my sales');
  await page.context().close();

  // finance: "Entered for CarmaCars", no commission
  const fp = await ctx(browser);
  await signIn(fp, fin.email, '/va');
  // the menu has Add a rental and My sales for Finance (0058)
  if (isPhone()) await fp.getByTestId('va-nav').getByRole('button', { name: /^Menu\. You are on/ }).click();
  await expect(fp.getByTestId('va-nav').getByRole('link', { name: 'My sales' })).toBeVisible();
  await fp.getByTestId('va-nav').getByRole('button', { name: 'Rentals' }).click();
  await expect(fp.getByTestId('va-nav').getByRole('link', { name: 'Add a rental' })).toBeVisible();
  await fp.goto('/va/bookings/new', { waitUntil: 'networkidle' });
  await fillRental(fp, carId, days + 10);
  await fp.getByTestId('choice-for_carmacars').check();
  await check(fp, 'finance add a rental, for CarmaCars');
  await fp.getByTestId('mr-submit').click();
  await expect(fp.getByTestId('mr-done')).toBeVisible({ timeout: 30_000 });
  await expect(fp.getByTestId('mr-done-choice')).toContainText('Entered for CarmaCars: no commission');
  const n2 = await doneNumber(fp);
  const [b2] = await sql`select b.sales_sourced, b.sales_choice, (b.sales_staff_id = ${fin.id}) mine, (select count(*)::int from staff_commissions c where c.booking_id = b.id) n from bookings b where b.booking_number = ${n2}`;
  expect(`${b2!.sales_sourced}/${b2!.sales_choice}/${b2!.mine}/${b2!.n}`).toBe('false/for_carmacars/true/0');
  await fp.context().close();

  // field staff: from the field portal, a payment link, "I sourced this client"
  const dp = await ctx(browser);
  await signIn(dp, field.email, '/field');
  await expect(dp.locator('.fd-nav').getByRole('link', { name: 'Add a rental' })).toBeVisible();
  await dp.goto('/field/rentals/new', { waitUntil: 'networkidle' });
  await expect(dp.getByTestId('mr-renter-q')).toHaveCount(0);
  await expect(dp.getByTestId('mr-mode-other_way')).toHaveCount(0);
  await fillRental(dp, carId, days + 20, { field: true });
  await expect(dp.getByTestId('mr-mode-other_way')).toHaveCount(0);
  await dp.getByTestId('choice-sourced').check();
  await check(dp, 'field add a rental');
  await dp.getByTestId('mr-submit').click();
  await expect(dp.getByTestId('mr-done')).toBeVisible({ timeout: 30_000 });
  const n3 = await doneNumber(dp);
  const [b3] = await sql`select b.status::text s, b.sales_sourced, (b.sales_staff_id = ${field.id}) mine from bookings b where b.booking_number = ${n3}`;
  expect(`${b3!.s}/${b3!.sales_sourced}/${b3!.mine}`).toBe('pending_payment/true/true');
  await dp.getByTestId('mr-open').click();
  await dp.waitForURL(/\/field\/sales/);
  await expect(dp.getByTestId('field-deals')).toContainText(n3);
  await expect(dp.getByTestId('commissions')).toContainText('10%');
  await check(dp, 'field my sales');
  await dp.context().close();
  await sql.end();
});

test('Commissions: completed and paid, approved, paid by hand, reversed by a refund; the flagged price reviewed; the Sales target', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const cs = await mkUser(sql, 'va', `Cory Service ${tag()}`, 'cs');
  const sales = await mkUser(sql, 'va', `Sasha Seller ${tag()}`, 'sales');
  const renter = await mkUser(sql, 'renter', `Rowan Renter ${tag()}`);
  const carId = await companyCar(sql, admin.id);
  // a rental completed and paid (recorded after the fact), credited to customer service as sourced by them
  const back = 3 + Math.floor(Math.random() * 2);
  const [m] = await sql`select app.manual_rental_create(${admin.id}, ${sql.json({ vehicle_id: carId, source: 'phone', coverage_option: 1, renter_id: renter.renterId, past: true,
    pickup_at: new Date(Date.now() - (back + 2) * 86_400_000).toISOString(), return_at: new Date(Date.now() - back * 86_400_000).toISOString(),
    payment: { mode: 'other_way', method: 'cash' } })}) as r`;
  const number = (m!.r as { booking_number: string }).booking_number;
  await sql`select app.sales_reassign(${admin.id}, ${sql.json({ booking: number, staff: cs.id, sourced: true, reason: 'Cory found this renter' })})`;
  // a quote with a price far under the rate sheet, typed by Sales (flagged)
  const [q] = await sql`select app.staff_quote_create(${sales.id}, ${sql.json({ vehicle_id: carId, source: 'phone', sales_choice: 'sourced', rental_charge_cents: 15000, price_reason: 'Friend of a regular',
    pickup_at: new Date(Date.now() + 200 * 86_400_000).toISOString(), return_at: new Date(Date.now() + 203 * 86_400_000).toISOString(),
    full_name: `Quinn Caller ${tag()}`, email: `quinn.${tag()}@example.test`, mobile: '4165550111', date_of_birth: '1985-03-04' })}) as r`;
  const quote = (q!.r as { booking_number: string }).booking_number;

  // My sales: pending approval
  const sp = await ctx(browser);
  await signIn(sp, cs.email, '/va');
  await sp.goto('/va/my-sales', { waitUntil: 'networkidle' });
  await expect(sp.getByTestId(`commission-status-${number}-commission`)).toContainText('Pending approval');
  await check(sp, 'my sales, pending approval');

  // the Admin: To do, Money > Staff commissions, approve, record the payment
  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  await expect(page.locator('body')).toContainText('Staff commissions to approve');
  await page.goto('/admin/money/commissions', { waitUntil: 'networkidle' });
  const people = page.getByTestId('commission-people');
  await expect(people.locator('tr', { hasText: cs.name })).toBeVisible();
  await check(page, 'staff commissions');
  await page.getByTestId(`approve-all-${cs.id}`).click();
  await expect(page.getByTestId(`approve-all-${cs.id}-form`)).toContainText('Nothing is paid until you record the payment');
  await page.getByTestId(`approve-all-${cs.id}-submit`).click();
  await expect(page.getByTestId(`pay-${cs.id}`)).toBeVisible({ timeout: 15_000 });
  const [a] = await sql`select c.status from staff_commissions c join bookings b on b.id = c.booking_id where b.booking_number = ${number} and c.kind = 'commission'`;
  expect(a!.status).toBe('approved');
  await page.getByTestId(`pay-${cs.id}`).click();
  const form = page.getByTestId(`pay-${cs.id}-form`);
  await form.getByLabel('How it was paid').selectOption('e_transfer');
  await form.getByLabel(/^Reference/).fill('CA-E2E-77');
  await check(page, 'record a commission payment');
  await page.getByTestId(`pay-${cs.id}-submit`).click();
  await expect(page.getByTestId(`pay-${cs.id}`)).toHaveCount(0, { timeout: 15_000 });
  const [pd] = await sql`select c.status, po.method, po.reference from staff_commissions c join staff_commission_payouts po on po.id = c.payout_id join bookings b on b.id = c.booking_id
    where b.booking_number = ${number} and c.kind = 'commission'`;
  expect(`${pd!.status}/${pd!.method}/${pd!.reference}`).toBe('paid/e_transfer/CA-E2E-77');
  const [ev] = await sql`select count(*)::int n from app_events where code in ('staff_commission_approved', 'staff_commission_paid') and payload ->> 'staff_id' = ${cs.id}`;
  expect(ev!.n).toBe(2);
  await page.goto('/admin/money/commissions?tab=payments', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('commission-payments')).toContainText('CA-E2E-77');
  await check(page, 'commission payments');

  // a refund after payment: reversed, taken off the next payment
  // recorded as paid, so it does not wait in Money > Refunds for another test's "Issue the refund"
  await sql`insert into refunds (booking_id, payment_id, reason, amount_cents, status, paid_at, requested_by, approved_by, note)
    select b.id, (select p.id from payments p where p.booking_id = b.id and p.status = 'succeeded' limit 1), 'other',
           (select sum(p.amount_cents) from payments p where p.booking_id = b.id and p.status = 'succeeded'), 'paid', now(), ${admin.id}, ${admin.id}, 'E2E: refunded in full'
      from bookings b where b.booking_number = ${number}`;
  await sp.goto('/va/my-sales', { waitUntil: 'networkidle' });
  await expect(sp.getByTestId(`commission-status-${number}-commission`)).toContainText('Paid');
  await expect(sp.getByTestId(`commission-status-${number}-clawback`)).toContainText('Reversed after payment');
  await check(sp, 'my sales, reversed after payment');
  await sp.context().close();

  // the flagged price: on the booking and in Prices to review
  await page.goto(`/admin/bookings/${quote}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('booking-custom-price')).toContainText('Flagged');
  await expect(page.getByTestId('booking-sourced')).toContainText('sourced the client');
  await check(page, 'booking with a typed price');
  await page.goto('/admin/money/commissions?tab=prices', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('prices')).toContainText(quote);
  await check(page, 'prices to review');
  await page.getByTestId(`price-review-${quote}`).click();
  await page.getByTestId(`price-review-${quote}-submit`).click();
  await expect(page.getByTestId('prices').locator('tr', { hasText: quote })).toContainText('reviewed', { timeout: 15_000 });
  await page.context().close();

  // Sales: the month's target of 100 rental days
  const sl = await ctx(browser);
  await signIn(sl, sales.email, '/va');
  await sl.goto('/va/my-sales', { waitUntil: 'networkidle' });
  await expect(sl.getByTestId('sales-target')).toContainText('of 100 rental days');
  await expect(sl.getByTestId('sales-target')).toContainText('rises to 15% at 50 days / 20% at 100 days');
  await expect(sl.getByRole('progressbar')).toBeVisible();
  await check(sl, 'sales my sales with the target');
  await sl.goto('/va/scorecard', { waitUntil: 'networkidle' });
  await expect(sl.getByTestId('score-target')).toContainText('of 100 rental days');
  await check(sl, 'sales scorecard with the target');
  await sl.context().close();
  await sql.end();
});
