import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0057 end to end, at 375 and 1440: Sales adds a rental by hand within its limits and sees it credited in
// My sales (with a quote it took, the follow-ups and the deals, by week and by month); an Admin reads a staff member's
// sales, reassigns a deal with a reason, sees the team's month on the Overview and the credit on the booking; the
// first reply target and the staff agreement defaults by function in Program settings; a staff agreement generated with
// the monthly pay of the person's function. Every page is checked with axe, for overflow and for the copy rules.
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
const vin = () => `3STSA${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
const plate = () => `S${randomBytes(3).toString('hex').toUpperCase()}`;

async function mkUser(sql: Sql, kind: 'admin' | 'va' | 'renter', name: string, fn?: 'cs' | 'sales') {
  const id = randomUUID(); const email = `${kind}${fn ?? ''}.st.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (kind === 'renter') {
    await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${id}, ${name}, ${email}, '+14165550142', '1988-04-12')
              on conflict (user_id) do update set date_of_birth = excluded.date_of_birth, mobile = excluded.mobile`;
    const [r] = await sql`select id from renters where user_id = ${id}`;
    return { id, email, name, renterId: r!.id as string };
  }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${kind})`;
  if (kind === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${fn ?? 'cs'})`;
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
// a CarmaCars-owned car with rates and no bookings: an assistant's list shows only bookable cars with rates
async function companyCar(sql: Sql, adminId: string) {
  const [car] = await sql`select app.vehicle_add(${adminId}, ${sql.json({ supply_type: 'company', vin: vin(), plate: plate(), year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 7400, weekend: 8400, weekly: 44000, monthly: 160000, deposit: 30000 } })}) as r`;
  return (car!.r as { vehicle_id: string }).vehicle_id;
}
const pad = (n: number) => String(n).padStart(2, '0');
const local = (d: Date) => `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T10:00`;

test.describe.configure({ mode: 'serial' });

test('Sales: adds a rental within its limits, and My sales credits it with its quote, follow-ups and deals', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const sales = await mkUser(sql, 'va', `Sam Seller ${tag()}`, 'sales');
  const carId = await companyCar(sql, admin.id);
  // a quote Sales took on the phone earlier (New quote is tested in staff.spec.ts): credited to Sales, waiting for its offer
  const days = 60 + Math.floor(Math.random() * 200);
  const [q] = await sql`select app.staff_quote_request(${sales.id}, ${sql.json({ vehicle_id: carId, source: 'phone',
    pickup_at: new Date(Date.now() + days * 86_400_000).toISOString(), return_at: new Date(Date.now() + (days + 2) * 86_400_000).toISOString(),
    full_name: `Quinn Caller ${tag()}`, email: `quinn.${tag()}@example.test`, mobile: '4165550111', date_of_birth: '1985-03-04' })}) as r`;
  const quote = (q!.r as { booking_number: string }).booking_number;

  const page = await ctx(browser);
  await signIn(page, sales.email, '/va');
  // the menu: My work has My sales for Sales
  if (isPhone()) await page.getByTestId('va-nav').getByRole('button', { name: /^Menu\. You are on/ }).click();
  await expect(page.getByTestId('va-nav').getByRole('link', { name: 'My sales' })).toBeVisible();

  // Add a rental by hand within the limits: the rate-sheet price, no price typed by hand, no past rental, a payment link
  await page.goto('/va/bookings/new', { waitUntil: 'networkidle' });
  await check(page, 'sales add a rental');
  await expect(page.getByTestId('mr-past')).toHaveCount(0);
  const pick = new Date(Date.now() + (days + 10) * 86_400_000);
  await page.getByTestId('mr-vehicle_id').selectOption(carId);
  await page.getByTestId('mr-pickup_at').fill(local(pick));
  await page.getByTestId('mr-return_at').fill(local(new Date(pick.getTime() + 3 * 86_400_000)));
  if (!(await page.getByTestId('mr-new-renter').isChecked())) await page.getByTestId('mr-new-renter').check();
  await page.getByTestId('mr-date_of_birth').fill('1991-07-08');
  await page.getByTestId('mr-check').click();
  await expect(page.getByTestId('mr-quote')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('mr-free')).toBeVisible();
  await expect(page.getByTestId('mr-custom-price')).toContainText('Rental charge from the rate sheet');
  const renterName = `Riley Walkin ${tag()}`;
  await page.getByTestId('mr-full_name').fill(renterName);
  await page.getByTestId('mr-email').fill(`riley.${tag()}@example.test`);
  await page.getByTestId('mr-mobile').fill('4165550123');
  await page.getByTestId('mr-licence_number').fill('R1234-56789-01234');
  await page.getByTestId('mr-licence_expiry').fill('2031-01-31');
  await page.getByTestId('mr-paid-by').selectOption('link');
  await check(page, 'sales add a rental, priced');
  await page.getByTestId('choice-sourced').check();
  await page.getByTestId('mr-submit').click();
  await expect(page.getByTestId('mr-done')).toBeVisible({ timeout: 30_000 });
  const number = (await page.getByTestId('mr-done').locator('h2').innerText()).match(/Rental (\S+) added/)![1]!;
  const [bk] = await sql`select status, added_by_staff, created_by = ${sales.id} as by_me, sales_staff_id = ${sales.id} as credited, sales_source from bookings where booking_number = ${number}`;
  expect(`${bk!.status}/${bk!.added_by_staff}/${bk!.by_me}/${bk!.credited}/${bk!.sales_source}`).toBe('pending_payment/true/true/true/manual_rental');

  // My sales: this week's tiles, the deals with how each is credited, the follow-ups due
  await page.goto('/va/my-sales', { waitUntil: 'networkidle' });
  await expect(page.getByRole('heading', { name: 'My sales', level: 1 })).toBeVisible();
  const tiles = page.getByTestId('sales-tiles');
  await expect(tiles).toContainText('Quotes created this week');
  await expect(tiles.locator('.ad-tile', { hasText: 'Rentals added this week' }).locator('.ad-tile__v')).toHaveText('1');
  await expect(tiles.locator('.ad-tile', { hasText: 'Quotes created this week' }).locator('.ad-tile__v')).toHaveText('1');
  await expect(tiles.locator('.ad-tile', { hasText: 'Follow-ups due' }).locator('.ad-tile__v')).toHaveText('2');
  const deals = page.getByTestId('sales-deals');
  await expect(deals.locator('tr', { hasText: number })).toContainText('Rental you added');
  await expect(deals.locator('tr', { hasText: quote })).toContainText('Your quote');
  // renters by first name only
  await expect(deals.locator('tr', { hasText: number })).toContainText('Riley');
  await expect(deals).not.toContainText(renterName);
  const follow = page.getByTestId('sales-follow-ups');
  await expect(follow.locator('li', { hasText: quote })).toContainText('Send the offer');
  await expect(follow.locator('li', { hasText: number })).toContainText('waiting for signature and payment');
  await expect(page.getByTestId('sales-periods')).toContainText('Week of');
  await check(page, 'my sales by week');
  await page.getByRole('link', { name: 'By month' }).click();
  await page.waitForURL(/\/va\/my-sales\?period=month/);
  await expect(page.getByTestId('sales-periods')).toContainText(new Intl.DateTimeFormat('en-CA', { month: 'long', timeZone: 'America/Toronto' }).format(new Date()));
  await expect(page.getByTestId('sales-tiles')).toContainText('Rentals added this month');
  await check(page, 'my sales by month');
  // a rental Sales added opens from My sales
  await page.getByTestId('sales-deals').getByRole('link', { name: number }).click();
  await page.waitForURL(new RegExp(`/va/bookings/${number}`));
  await expect(page.locator('body')).toContainText(number);
  // customer service has My sales too since 0058 (its commissions)
  const cs = await mkUser(sql, 'va', `Casey Service ${tag()}`, 'cs');
  const cp = await ctx(browser);
  await signIn(cp, cs.email, '/va');
  const r = await cp.goto('/va/my-sales');
  expect(r?.status()).toBe(200);
  await expect(cp.getByTestId('commissions')).toBeVisible();
  await cp.context().close();
  await page.context().close();
  await sql.end();
});

test('Admin: a staff member\'s sales, reassign, the team\'s month, the booking\'s credit, the reply target and agreement defaults', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkUser(sql, 'admin', `Ada Admin ${tag()}`);
  const sales = await mkUser(sql, 'va', `Sasha Seller ${tag()}`, 'sales');
  const cs = await mkUser(sql, 'va', `Cory Service ${tag()}`, 'cs');
  const renter = await mkUser(sql, 'renter', `Rowan Renter ${tag()}`);
  const carId = await companyCar(sql, admin.id);
  // a rental Sales added, paid at the counter within its limit: confirmed at once and credited to Sales
  await sql`update staff_profiles set single_limit_cents = 100000 where user_id = ${sales.id}`;
  const days = 90 + Math.floor(Math.random() * 200);
  const [m] = await sql`select app.manual_rental_create(${sales.id}, ${sql.json({ vehicle_id: carId, source: 'phone', coverage_option: 1, renter_id: renter.renterId,
    pickup_at: new Date(Date.now() + days * 86_400_000).toISOString(), return_at: new Date(Date.now() + (days + 2) * 86_400_000).toISOString(),
    payment: { mode: 'other_way', method: 'cash', note: 'Paid at the counter' } })}) as r`;
  const number = (m!.r as { booking_number: string }).booking_number;

  const page = await ctx(browser);
  await signIn(page, admin.email, '/admin');
  // People > Staff: the staff member's Sales
  await page.goto('/admin/settings/staff', { waitUntil: 'networkidle' });
  await page.getByTestId(`sales-${sales.email}`).click();
  await page.waitForURL(new RegExp(`/admin/staff/${sales.id}/sales`));
  await expect(page.getByRole('heading', { level: 1 })).toContainText(`Sales: ${sales.name}`);
  await expect(page.getByTestId('sales-tiles').locator('.ad-tile', { hasText: 'Bookings confirmed this week' }).locator('.ad-tile__v')).toHaveText('1');
  await expect(page.getByTestId('sales-deals').locator('tr', { hasText: number })).toContainText('Rental they added');
  await check(page, 'admin staff sales');

  // reassign the deal to customer service, with a reason
  await page.getByTestId(`reassign-${number}`).click();
  const form = page.getByTestId(`reassign-${number}-form`);
  await form.getByLabel('Credit it to').selectOption(cs.id);
  await form.getByLabel('Reason').fill('Cory closed it on the phone');
  await check(page, 'reassign dialog');
  await page.getByTestId(`reassign-${number}-submit`).click();
  await expect(page.getByTestId('sales-deals').locator('tr', { hasText: number })).toContainText(`credited to ${cs.name}`, { timeout: 15_000 });
  const [cr] = await sql`select b.sales_staff_id = ${cs.id} as to_cs, b.sales_source, (select count(*) from booking_events e where e.booking_id = b.id and e.kind = 'sales_credit')::int as events
    from bookings b where b.booking_number = ${number}`;
  expect(`${cr!.to_cs}/${cr!.sales_source}/${cr!.events}`).toBe('true/admin/1');

  // the booking's page: the credit and who gave it
  await page.goto(`/admin/bookings/${number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('booking-sales-credit')).toContainText(cs.name);
  await expect(page.getByTestId('booking-sales-credit')).toContainText('given by an Admin');
  await check(page, 'booking sales credit');

  // the team's month on Today > Overview
  await page.goto('/admin/overview', { waitUntil: 'networkidle' });
  const team = page.getByTestId('team-sales');
  await expect(team.locator('tr', { hasText: sales.name })).toBeVisible();
  await expect(team.locator('tr', { hasText: cs.name })).toBeVisible();
  await expect(page.getByTestId('dash-requests')).toContainText('first reply target 5 min');
  await check(page, 'overview with the team');
  const prev = await page.getByTestId('team-sales-month').locator('option').nth(1).getAttribute('value');
  await page.getByTestId('team-sales-month').selectOption(prev!);
  await team.getByRole('button', { name: 'Show' }).click();
  await page.waitForURL(new RegExp(`sales_month=${prev}`));
  await expect(page.getByTestId('team-sales')).toBeVisible();
  await check(page, 'overview, an earlier month');

  // Program settings: the first reply target and the staff agreement defaults by function
  const [orig] = await sql`select (app.settings()).staff_agreement_defaults as d`;
  await page.goto('/admin/settings/program', { waitUntil: 'networkidle' });
  await expect(page.getByLabel('First reply target for customer service and sales (minutes)')).toHaveValue('5');
  await expect(page.getByTestId('sd-cs-rate')).toHaveValue('350.00');
  await expect(page.getByTestId('sd-cs-pay_basis')).toHaveValue('monthly');
  await expect(page.getByTestId('sd-fleet-rate')).toHaveValue('400.00');
  await expect(page.getByTestId('sd-finance-schedule')).toHaveValue('part_time');
  await expect(page.getByTestId('sd-finance-days_per_week')).toHaveValue('3');
  await expect(page.getByTestId('sd-finance-hours_per_day')).toHaveValue('9');
  await expect(page.getByTestId('sd-sales-rate')).toHaveValue('');
  await expect(page.getByTestId('sd-field-wage')).toHaveValue('18.00');
  await expect(page.getByTestId('sd-field-pay_dates')).toHaveValue('every two weeks');
  await check(page, 'program settings');
  await page.getByTestId('sd-sales-pay_basis').selectOption('monthly');
  await page.getByTestId('sd-sales-rate').fill('300.00');
  await page.getByTestId('staff-defaults-save').click();
  await expect(page.getByTestId('staff-defaults-form')).toContainText('Saved', { timeout: 15_000 });
  const [after] = await sql`select (app.settings()).staff_agreement_defaults #>> '{va,by_function,sales,rate}' as rate, (app.settings()).staff_agreement_defaults #>> '{va,by_function,cs,rate}' as cs`;
  expect(`${after!.rate}/${after!.cs}`).toBe('300.00/350.00');
  await sql`update program_settings set staff_agreement_defaults = ${sql.json(orig!.d as never)} where id = (app.settings()).id`;

  // a staff agreement generated for customer service starts from its function: US$350 a month, full time, 6 days of 10 hours
  await page.goto('/admin/settings/staff', { waitUntil: 'networkidle' });
  const row = page.locator(`[data-testid="staff-agreements"] li[data-staff="${cs.email}"]`);
  await row.getByTestId('send-generated').click();
  const gen = row.getByTestId('send-generated-form');
  await expect(gen.getByTestId('gen-pay_basis')).toHaveValue('monthly');
  await expect(gen.getByTestId('gen-rate')).toHaveValue('350.00');
  await expect(gen.getByTestId('gen-schedule')).toHaveValue('full_time');
  await expect(gen.getByTestId('gen-days_per_week')).toHaveValue('6');
  await expect(gen.getByTestId('gen-hours_per_day')).toHaveValue('10');
  await expect(gen.getByTestId('gen-hours_per_week')).toHaveValue('60');
  await gen.getByTestId('gen-start').fill('November 2, 2026');
  await check(page, 'staff agreement from the defaults');
  await gen.getByTestId('send-generated-submit').click();
  await expect(row.getByTestId('staff-agreement-status')).toContainText('waiting for their signature', { timeout: 30_000 });
  const [sr] = await sql`select extra -> 'values' ->> 'rate' as rate, extra -> 'values' ->> 'pay_basis' as basis, extra -> 'summary' as summary from sign_requests where staff_user_id = ${cs.id} and doc_type = 'staff_agreement'`;
  expect(`${sr!.rate}/${sr!.basis}`).toBe('350.00/monthly');
  expect(JSON.stringify(sr!.summary)).toContain('350.00 a month, in USD');
  expect(JSON.stringify(sr!.summary)).toContain('Full time: 6 days a week, 10 hours a day');
  await page.context().close();
  await sql.end();
});
