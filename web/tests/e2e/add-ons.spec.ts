import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Add-ons (migration 0066) end to end, at 375 and 1440: a renter chooses a baby seat and flowers on the car page (priced
// live), carries them into the request and sends it; customer service adds a chauffeur in the offer; field staff see
// what to put in the car (and the prepaid fuel note) on the handover; the renter adds an umbrella from their portal,
// charged on the card on file; an Admin sees the catalogue and Fleet sets stock. Pages are checked with axe, for
// overflow and for the copy rules.
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
async function mkStaff(sql: Sql, kind: 'admin' | 'va' | 'field', name: string, fn?: 'cs' | 'fleet') {
  const id = randomUUID(); const email = `${kind}${fn ?? ''}.ao.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${kind})`;
  if (kind === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${fn ?? 'cs'}, 500000)`;
  if (kind === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver_detailer')`;
  return { id, email };
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
  return c.newPage();
}
/** Three free days on a car, far enough out that no other test or seed booking is near, and no baby seat booked then. */
async function freeWindow(sql: Sql, slug: string) {
  for (let off = 150 + Math.floor(Math.random() * 120); off < 400; off += 5) {
    const d = new Date(); d.setUTCDate(d.getUTCDate() + off);
    const from = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 3); const to = d.toISOString().slice(0, 10);
    const [r] = await sql`select (select count(*)::int from bookings b join vehicle_listings l using (vehicle_id) where l.slug = ${slug} and b.status in ('confirmed','on_rent','requested','offered')
                              and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from}::date::timestamptz, ${to}::date::timestamptz + interval '1 day')) n,
                             app.addon_held((select id from addons where code = 'baby_seat'), ${from}::date::timestamptz, ${to}::date::timestamptz + interval '1 day') seats`;
    if (r!.n === 0 && r!.seats === 0) return { from, to };
  }
  throw new Error('no free window');
}

test.describe.configure({ mode: 'serial' });

test('A renter adds a baby seat and flowers on the car page and sends the request; staff add a chauffeur in the offer', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const slug = 'honda-civic';
  const w = await freeWindow(sql, slug);
  const email = `ao.renter.${Date.now()}.${tag()}@example.test`;

  // the car page: the add-ons, priced live in the estimate
  const page = await ctx(browser);
  await page.goto(`/cars/${slug}?from=${w.from}&to=${w.to}&tf=10:00&tt=10:00`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const box = page.getByTestId('car-addons');
  await box.locator('summary').click();
  await box.getByRole('button', { name: 'More: Baby seat (rear-facing)' }).click();
  await expect(box.getByTestId('car-baby_seat-count')).toHaveText('1');
  await box.locator('#car-flowers').check();
  await expect(page.locator('.estimate__lines')).toContainText('Baby seat (rear-facing), 3 days', { timeout: 15_000 });
  await expect(page.locator('.estimate__lines')).toContainText('Flowers');
  await expect(page.locator('.estimate__lines')).toContainText('$150.00');
  await check(page, 'car page with add-ons');
  await page.locator('.booking__est [data-book]').click();
  await page.waitForURL(/\/book\//);
  await expect(page).toHaveURL(/addons=/);

  // the request: the add-ons came along; the add-ons step shows them chosen
  await page.getByRole('button', { name: 'Continue to driver details' }).click();
  await page.locator('#rq-first').fill('Addie');
  await page.locator('#rq-last').fill('Ons');
  await page.locator('#rq-email').fill(email);
  await page.locator('#rq-phone').fill('647-555-0142');
  await page.locator('#rq-dobm').selectOption('4');
  await page.locator('#rq-dobd').fill('9');
  await page.locator('#rq-doby').fill('1990');
  await page.getByRole('button', { name: 'Continue to licence' }).click();
  await page.locator('label', { hasText: 'Ontario G2' }).click();
  await page.locator('label.option', { hasText: 'Option 2' }).click();
  await page.getByRole('button', { name: 'Continue to add-ons' }).click();
  await expect(page.getByRole('heading', { name: 'Add-ons' })).toBeVisible();
  await expect(page.locator('#rq-flowers')).toBeChecked();
  await expect(page.getByTestId('rq-baby_seat-count')).toHaveText('1');
  await check(page, 'request add-ons step');
  await page.getByRole('button', { name: 'Review request' }).click();
  await expect(page.locator('.req__review')).toContainText('Baby seat (rear-facing)');
  await expect(page.locator('.req__review')).toContainText('Flowers');
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Send request' }).click();
  await page.waitForURL(/\/book\/sent\//, { timeout: 30_000 });
  const number = decodeURIComponent(page.url().split('/').pop()!);
  const got = await sql`select a.code, ba.quantity, ba.status from booking_addons ba join addons a on a.id = ba.addon_id join bookings b on b.id = ba.booking_id
                         where b.booking_number = ${number} and ba.status in ('pending', 'confirmed') order by a.code`;
  expect(got.map((r) => `${r.code}:${r.quantity}:${r.status}`)).toEqual(['baby_seat:1:confirmed', 'flowers:1:confirmed']);
  await page.context().close();

  // customer service adds a 4-hour chauffeur on the review screen; the price follows
  const cs = await mkStaff(sql, 'va', `Casey Addons ${tag()}`, 'cs');
  const sp = await ctx(browser);
  await signIn(sp, cs.email, '/staff');
  await sp.goto(`/staff/bookings/${encodeURIComponent(number)}?tab=review`, { waitUntil: 'networkidle' });
  const rv = sp.getByTestId('review-addons');
  await expect(rv.locator('#rv-flowers')).toBeChecked();
  await rv.locator('#rv-chauffeur').check();
  await rv.locator('#rv-chauffeur-h').selectOption('4');
  await expect(sp.getByTestId('review-price')).toContainText('Chauffeur, 4 hours', { timeout: 15_000 });
  await expect(sp.getByTestId('review-price')).toContainText('$180.00');
  await check(sp, 'offer review with add-ons');
  await sp.getByTestId('review-save').click();
  await expect(sp.getByText('Saved.')).toBeVisible({ timeout: 20_000 });
  const ch = await sql`select ba.status, ba.hours::int h, li.amount_cents::int amt from booking_addons ba join addons a on a.id = ba.addon_id join bookings b on b.id = ba.booking_id
                        join booking_line_items li on li.id = ba.line_item_id where b.booking_number = ${number} and a.code = 'chauffeur' and ba.status = 'confirmed'`;
  expect(ch.map((r) => `${r.status}:${r.h}:${r.amt}`)).toEqual(['confirmed:4:18000']);
  await sp.context().close();
  await sql.end();
});

test('Field staff see the add-ons to put in the car; the renter adds an umbrella from the portal; the catalogue and stock', async ({ browser }) => {
  test.setTimeout(240_000);
  const sql = db();
  const admin = await mkStaff(sql, 'admin', `Ada Addons ${tag()}`);
  const field = await mkStaff(sql, 'field', `Frankie Addons ${tag()}`);
  const fleet = await mkStaff(sql, 'va', `Fleet Addons ${tag()}`, 'fleet');
  // a renter with a sign-in and a card on file
  const rid = randomUUID(); const remail = `ao.portal.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${rid}, ${remail}, ${hash(PW)})`;
  await sql`select public.register_account(${rid}, ${remail}, 'Penny Portal', null)`;
  await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${rid}, 'Penny Portal', ${remail}, '+14165550142', '1988-04-12')
            on conflict (user_id) do update set date_of_birth = excluded.date_of_birth`;
  const [rn] = await sql`select id from renters where user_id = ${rid}`;
  await sql`insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, licence_number) values (${rn!.id as string}, true, ${rid}, 'Penny Portal', '1988-04-12', 'G', 'P1234-56789-01234') on conflict do nothing`;
  const [pm] = await sql`insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit) values (${rn!.id as string}, 'visa', '4242', 'Penny Portal', 12, 2031, true) returning id`;
  await sql`insert into payment_method_secrets (payment_method_id, processor_customer_id, processor_method_id) values (${pm!.id as string}, ${'cus_fake_' + tag()}, ${'pm_fake_' + tag()})`;
  // a company car and a rental tomorrow with flowers and a prepaid tank (no stock-counted item: runs repeat on one database) (an Admin adds it, paid another way)
  const vin = `3AXMX${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
  const [car] = await sql`select app.vehicle_add(${admin.id}, ${sql.json({ supply_type: 'company', vin, plate: `A${randomBytes(3).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as r`;
  const carId = (car!.r as { vehicle_id: string }).vehicle_id;
  const pick = new Date(Date.now() + 20 * 3600_000); pick.setMinutes(0, 0, 0);
  const [m] = await sql`select app.manual_rental_create(${admin.id}, ${sql.json({ vehicle_id: carId, pickup_at: pick.toISOString(), return_at: new Date(pick.getTime() + 3 * 86_400_000).toISOString(),
    source: 'phone', coverage_option: 1, renter_id: rn!.id as string, payment: { mode: 'other_way', method: 'cash' },
    addons: [{ code: 'flowers' }, { code: 'full_tank' }] })}) as r`;
  const booking = m!.r as { booking_id: string; booking_number: string };
  await sql`update bookings set card_on_file_id = ${pm!.id as string} where id = ${booking.booking_id}`;
  const [job] = await sql`insert into field_jobs (kind, vehicle_id, booking_id, scheduled_at, assigned_to, status, created_by)
                          values ('handover', ${carId}, ${booking.booking_id}, ${pick.toISOString()}, ${field.id}, 'scheduled', ${admin.id}) returning id`;

  // field staff: the handover lists what goes in the car, and the prepaid fuel note
  const fp = await ctx(browser);
  await signIn(fp, field.email, '/staff/field');
  await fp.goto(`/staff/field/jobs/${job!.id as string}`, { waitUntil: 'networkidle' });
  const put = fp.getByTestId('job-addons');
  await expect(put).toContainText('Put in the car');
  await expect(put).toContainText('Flowers');
  await expect(put).toContainText('Full tank of gas (prepaid)');
  await expect(fp.getByTestId('job-prepaid-fuel')).toContainText('Do not charge for fuel');
  await check(fp, 'field job with add-ons');
  await fp.context().close();
  // Fleet's task for the flowers
  const [task] = await sql`select count(*)::int n from tasks where booking_id = ${booking.booking_id} and task_type = 'addon_prep' and queue = 'fleet' and status = 'open'`;
  expect(task!.n).toBe(1);

  // the renter's portal: add an umbrella, charged on the card on file (the cutoff is 24 hours: the pickup is in 20,
  // so this booking may not take more; a second booking further out does)
  const pick2 = new Date(Date.now() + (9 + Math.floor(Math.random() * 200)) * 86_400_000); pick2.setMinutes(0, 0, 0);
  const [m2] = await sql`select app.manual_rental_create(${admin.id}, ${sql.json({ vehicle_id: carId, pickup_at: pick2.toISOString(), return_at: new Date(pick2.getTime() + 2 * 86_400_000).toISOString(),
    source: 'phone', coverage_option: 1, renter_id: rn!.id as string, payment: { mode: 'other_way', method: 'cash' } })}) as r`;
  const b2 = m2!.r as { booking_id: string; booking_number: string };
  await sql`update bookings set card_on_file_id = ${pm!.id as string} where id = ${b2.booking_id}`;
  const rp = await ctx(browser);
  await signIn(rp, remail, '/account');
  await rp.goto(`/account/bookings/${encodeURIComponent(booking.booking_number)}`, { waitUntil: 'networkidle' });
  await expect(rp.getByTestId('portal-addons')).toContainText('Flowers');
  await expect(rp.getByTestId('portal-addons')).not.toContainText('Add something to your trip');
  await rp.goto(`/account/bookings/${encodeURIComponent(b2.booking_number)}`, { waitUntil: 'networkidle' });
  const pa = rp.getByTestId('portal-addons');
  await pa.getByText('Add something to your trip').click();
  await pa.locator('#pa-umbrella').check();
  await expect(rp.getByTestId('portal-addon-price')).toContainText('$5 a trip');
  await check(rp, 'renter portal add-ons');
  await rp.getByTestId('portal-addon-add').click();
  await expect(pa).toContainText('is added and paid', { timeout: 20_000 });
  await expect(pa.locator('[data-addon="umbrella"]')).toContainText('$5.65');
  const [paid] = await sql`select count(*)::int n from payments where booking_id = ${b2.booking_id} and purpose = 'addon' and status = 'succeeded' and amount_cents = 565`;
  expect(paid!.n).toBe(1);
  await rp.context().close();

  // the catalogue: an Admin sees every add-on; Fleet sets the stock of umbrellas
  const ap = await ctx(browser);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/settings/addons', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('addons-table')).toContainText('Chauffeur');
  await expect(ap.getByTestId('addons-table')).toContainText('$45 an hour, 3 hours minimum');
  await ap.getByTestId('addon-open-umbrella').click();
  await expect(ap.getByTestId('addon-edit-umbrella')).toBeVisible();
  await check(ap, 'admin add-ons');
  await ap.context().close();
  const vp = await ctx(browser);
  await signIn(vp, fleet.email, '/staff');
  await vp.goto('/staff/addons', { waitUntil: 'networkidle' });
  const [before] = await sql`select stock_count from addons where code = 'umbrella'`;
  await vp.getByTestId('stock-umbrella').fill(String(Number(before!.stock_count ?? 4) + 1));
  await vp.locator('[data-addon="umbrella"]').getByRole('button', { name: 'Save' }).click();
  await expect(vp.locator('[data-addon="umbrella"]')).toContainText('Saved.');
  const [after] = await sql`select stock_count from addons where code = 'umbrella'`;
  expect(after!.stock_count).toBe(Number(before!.stock_count ?? 4) + 1);
  await sql`update addons set stock_count = ${before!.stock_count as number} where code = 'umbrella'`;
  await expect(vp.getByTestId('addon-open-umbrella')).toHaveCount(0);
  await check(vp, 'fleet add-ons');
  await vp.context().close();
  await sql.end();
});
