import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';
import { sampleForm } from '../../src/features/official-forms/fill';

// Migration 0079 end to end, at 375 and 1440:
// - the management fee is labelled "Management fee (Revenue Share)" on the staff screens (the car's terms)
// - every add-on shows its studio illustration in Admin > Settings > Add-ons, served by the site
// - a refund says what it gives back (the rental charge, delivery or pickup, kilometres, add-ons, other charges)
// - an official form not checked yet opens "Review and check" from a link to it: the form filled for a car, page by
//   page, then "Checked: use for owners"
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
const VIN_CHARS = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789';
const vin = (prefix: string) => prefix + Array.from({ length: 17 - prefix.length }, () => VIN_CHARS[Math.floor(Math.random() * VIN_CHARS.length)]).join('');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const onlyDesktop = () => test.skip(test.info().project.name !== 'desktop-1440', 'one run: the test opens its own phone and desktop pages');

async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `admin.af.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
/** An owner with one enrolled car and its signed terms (35% management fee). */
async function mkOwnerCar(sql: Sql) {
  const uid = randomUUID(); const email = `owner.af.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${uid}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${uid}, ${email}, 'Olive Owner')`;
  await sql`insert into user_roles (user_id, role) values (${uid}, 'owner')`;
  const owner = randomUUID(); const car = randomUUID(); const agr = randomUUID(); const t = tag().toUpperCase();
  await sql`insert into owners (id, user_id, owner_type, legal_name, status, email, phone, address_line1, city, province, postal_code)
            values (${owner}, ${uid}, 'individual', 'Olive Owner', 'active', ${email}, '416-555-0100', '1 King St W', 'Toronto', 'ON', 'm5v1a1')`;
  await sql`insert into owner_agreements (id, owner_id, kind, agreement_number, agreement_date, status) values (${agr}, ${owner}, 'enrollment', ${`EA-${t}`}, current_date - 30, 'signed')`;
  await sql`insert into vehicles (id, owner_id, fleet_number, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, fleet_policy_added_on, enrollment_date, colour, body_type, odometer_km)
            values (${car}, ${owner}, ${`F-${t}`}, 2022, 'Toyota', 'Corolla', ${vin('2T1')}, ${`AF${t.replace(/[^A-Z0-9]/g, '').slice(-5)}`}, 'standard', 'ready_to_list', 'managed', 'transfer', true, current_date - 20, current_date - 20, 'Grey', 'sedan', 21000)`;
  await sql`insert into vehicle_schedules (vehicle_id, owner_agreement_id, schedule_number, vehicle_number, held_by, title_status, management_mode, onboarding_method,
              insurance_fee_cents, tracker_fee_cents, install_fee_cents, revenue_share_bps, enrollment_date, signed_at)
            values (${car}, ${agr}, ${`VS-${t}`}, 1, 'individual', 'owned_outright', 'managed', 'transfer', 45000, 2500, 10000, 3500, current_date - 20, now())`;
  await sql`insert into vehicle_fee_history (vehicle_id, source, insurance_fee_cents, tracker_fee_cents, revenue_share_bps, effective_from) values (${car}, 'signed_schedule', 45000, 2500, 3500, current_date - 20)`;
  return { owner, car };
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where}: ${v.id} ${v.nodes.map((n) => n.target.join(' ')).join(', ')}`)).toEqual([]);
}

test('management fee (Revenue Share) on the car\'s terms; the shareholder switch; add-on illustrations in Settings', async ({ page }) => {
  const sql = db();
  try {
    const admin = await mkAdmin(sql);
    const { car, owner } = await mkOwnerCar(sql);
    await signIn(page, admin.email, `/admin/vehicles/${car}`);
    await page.goto(`/admin/vehicles/${car}`, { waitUntil: 'networkidle' });
    await expect(page.getByText('Management fee (Revenue Share)').first()).toBeVisible();
    await expect(page.getByText(/^Revenue Share$/)).toHaveCount(0);
    await axe(page, 'vehicle terms');
    // the owner page: the management fee, and the shareholder's own car switch with what it changes
    await page.goto(`/admin/owners/${owner}`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('shareholder-car').first()).toContainText('Shareholder\'s own car: no');
    await page.getByTestId(`shareholder-${car}`).click();
    const dlg = page.getByRole('dialog');
    await expect(dlg).toContainText('90/10');
    await dlg.getByLabel('Why (kept in the audit log)').fill('e2e');
    await page.getByTestId(`shareholder-${car}-submit`).click();
    await expect.poll(async () => (await sql`select is_shareholder_owned from vehicles where id = ${car}`)[0]?.is_shareholder_owned, { timeout: 15_000 }).toBe(true);
    await axe(page, 'owner page');
    await page.goto('/admin/settings/addons', { waitUntil: 'networkidle' });
    const srcs = await page.locator('img[src^="/addon-photos/"]').evaluateAll((els) => els.map((e) => e.getAttribute('src')));
    for (const code of ['flowers', 'baby_seat', 'child_seat', 'booster_seat', 'chauffeur', 'umbrella', 'phone_charger', 'full_tank', 'winter_tire'])
      expect(srcs).toContain(`/addon-photos/${code}.svg`);
    const r = await page.request.get('/addon-photos/flowers.svg');
    expect([r.status(), r.headers()['content-type']?.split(';')[0]]).toEqual([200, 'image/svg+xml']);
    await expect.poll(() => page.locator('img[src="/addon-photos/flowers.svg"]').first().evaluate((i: HTMLImageElement) => i.naturalWidth)).toBeGreaterThan(0);
    await noOverflow(page);
  } finally { await sql.end(); }
});

test('a refund says what it gives back', async ({ page }) => {
  const sql = db();
  try {
    const admin = await mkAdmin(sql);
    const [b] = await sql`select b.booking_number, b.id from bookings b where exists (select 1 from payments p where p.booking_id = b.id and p.status = 'succeeded' and p.kind in ('charge', 'capture'))
                           order by b.created_at desc limit 1`;
    test.skip(!b, 'no paid booking in the local data');
    await signIn(page, admin.email, `/admin/bookings/${b!.booking_number}`);
    await page.goto(`/admin/bookings/${b!.booking_number}?tab=money`, { waitUntil: 'networkidle' });
    const open = page.getByTestId('new-refund');
    if (!(await open.isVisible())) {
      for (const name of ['Money', 'Payments']) { const tab = page.getByRole('link', { name, exact: true }).or(page.getByRole('tab', { name, exact: true })); if (await tab.count()) { await tab.first().click(); break; } }
    }
    await open.click();
    const dlg = page.getByRole('dialog');
    const kind = dlg.getByLabel('What it refunds');
    await expect(kind).toHaveValue('rental');
    await expect(kind.locator('option')).toHaveText(['The rental charge', 'Delivery or pickup', 'Kilometres', 'Add-ons', 'Other charges (fuel, cleaning, fees)']);
    await axe(page, 'refund dialog');
    await kind.selectOption('delivery');
    await dlg.getByLabel('Amount ($)').fill('1.00');
    const note = `af-${tag()}`;
    await dlg.getByLabel('Note').fill(note);
    await page.getByTestId('new-refund-submit').click();
    await expect.poll(async () => (await sql`select refund_of from refunds where note = ${note}`)[0]?.refund_of, { timeout: 15_000 }).toBe('delivery');
  } finally { await sql.end(); }
});

test('an official form: Review and check from its link, filled for a car, then used for owners', async ({ browser }) => {
  onlyDesktop();
  test.setTimeout(180_000);
  const sql = db();
  const CODE = 'SR-LV-006';
  const [before] = await sql`select id from pdf_templates where form_code = ${CODE} and is_current`;
  try {
    const admin = await mkAdmin(sql);
    await mkOwnerCar(sql);
    const desk = await ctx(browser, false);
    await signIn(desk, admin.email, '/admin/settings/forms');
    await desk.goto('/admin/settings/forms', { waitUntil: 'networkidle' });
    await desk.getByTestId(`form-upload-${CODE}`).setInputFiles({ name: 'sample-fillable.pdf', mimeType: 'application/pdf', buffer: Buffer.from(await sampleForm()) });
    const map = desk.getByTestId(`form-map-${CODE}`);
    await expect(map).toBeVisible({ timeout: 20_000 });
    await map.getByTestId('map-owner_name').selectOption('owner.legal_name');
    await map.getByTestId('map-vin').selectOption('vehicle.vin');
    await desk.getByTestId(`form-save-${CODE}`).click();
    await expect(desk.getByRole('status').filter({ hasText: 'Mapping saved' })).toBeVisible({ timeout: 20_000 });

    // the To do line links to the form: the review opens by itself, on a phone too
    const phone = await ctx(browser, true);
    await signIn(phone, admin.email, '/admin/settings/forms');
    await phone.goto(`/admin/settings/forms#${CODE}`, { waitUntil: 'networkidle' });
    const pdlg = phone.getByTestId(`form-review-${CODE}-dialog`);
    await expect(pdlg).toBeVisible();
    await expect(pdlg.getByTestId(`form-review-${CODE}-sample`).locator('img').first()).toBeVisible({ timeout: 30_000 });
    await axe(phone, 'form review 375');
    await pdlg.getByRole('button', { name: 'Not yet' }).click();
    await expect(pdlg).toBeHidden();
    await phone.context().close();

    await desk.goto(`/admin/settings/forms#${CODE}`, { waitUntil: 'networkidle' });
    const dlg = desk.getByTestId(`form-review-${CODE}-dialog`);
    await expect(dlg).toBeVisible();
    await expect(dlg.getByTestId(`form-review-${CODE}-sample`)).toContainText('field(s) filled', { timeout: 30_000 });
    await expect(dlg.getByRole('img', { name: `${CODE}, page 1, filled` })).toBeVisible();
    await axe(desk, 'form review 1440');
    await dlg.getByTestId(`form-review-${CODE}-verify`).click();
    await expect(dlg.getByRole('status').filter({ hasText: 'Checked and in use' })).toBeVisible({ timeout: 20_000 });
    const [t] = await sql`select verified from pdf_templates where form_code = ${CODE} and is_current`;
    expect(t!.verified).toBe(true);
    await desk.context().close();
  } finally {
    // the other tests see the form as it was
    if (before) {
      await sql`update pdf_templates set is_current = false where form_code = ${CODE} and is_current and id <> ${before.id}`;
      await sql`update pdf_templates set is_current = true where id = ${before.id}`;
    }
    await sql.end();
  }
});

test('an add-on bought after booking with no card on file is paid on its pay page', async ({ page }) => {
  test.setTimeout(180_000);
  const sql = db();
  try {
    const admin = await mkAdmin(sql);
    const rid = randomUUID(); const remail = `af.renter.${tag()}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${rid}, ${remail}, ${hash(PW)})`;
    await sql`select public.register_account(${rid}, ${remail}, 'Nora Nocard', null)`;
    await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${rid}, 'Nora Nocard', ${remail}, '+14165550143', '1988-04-12')
              on conflict (user_id) do update set date_of_birth = excluded.date_of_birth`;
    const [rn] = await sql`select id from renters where user_id = ${rid}`;
    await sql`insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, licence_number) values (${rn!.id as string}, true, ${rid}, 'Nora Nocard', '1988-04-12', 'G', 'N1234-56789-01234') on conflict do nothing`;
    const v = `3AXMX${randomBytes(6).toString('hex').toUpperCase().replace(/[IOQ]/g, 'A')}`.slice(0, 17).padEnd(17, '7');
    const [car] = await sql`select app.vehicle_add(${admin.id}, ${sql.json({ supply_type: 'company', vin: v, plate: `N${randomBytes(3).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
      rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) as r`;
    const carId = (car!.r as { vehicle_id: string }).vehicle_id;
    const pick = new Date(Date.now() + (9 + Math.floor(Math.random() * 200)) * 86_400_000); pick.setMinutes(0, 0, 0);
    const [m] = await sql`select app.manual_rental_create(${admin.id}, ${sql.json({ vehicle_id: carId, pickup_at: pick.toISOString(), return_at: new Date(pick.getTime() + 2 * 86_400_000).toISOString(),
      source: 'phone', coverage_option: 1, renter_id: rn!.id as string, payment: { mode: 'other_way', method: 'cash' } })}) as r`;
    const b = m!.r as { booking_id: string; booking_number: string };
    await sql`update bookings set card_on_file_id = null where id = ${b.booking_id}`;

    await page.goto(`/sign-in?next=${encodeURIComponent(`/account/bookings/${b.booking_number}`)}`, { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await page.locator('input[type="email"]').fill(remail);
    await page.locator('input[type="password"]').fill(PW);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.waitForURL((u) => u.pathname.startsWith('/account'), { timeout: 20_000 });
    await page.goto(`/account/bookings/${encodeURIComponent(b.booking_number)}`, { waitUntil: 'networkidle' });
    const pa = page.getByTestId('portal-addons');
    await pa.getByText('Add something to your trip').click();
    await pa.locator('#pa-umbrella').check();
    await page.getByTestId('portal-addon-add').click();
    await expect(pa).toContainText('Pay for your add-ons', { timeout: 20_000 });
    await page.getByTestId('portal-addons-pay').click();
    await page.waitForURL('**/addons/pay');
    await expect(page.getByTestId('addon-pay-summary')).toContainText('Umbrella');
    await expect(page.getByTestId('addon-pay-summary')).toContainText('$5.65');
    await axe(page, 'add-on pay page');
    await page.getByLabel('Name on the card').fill('Nora Nocard');
    await page.getByLabel('Card number').fill('4242 4242 4242 4242');
    await page.getByLabel('Expiry (MM / YY)').fill('12 / 31');
    await page.getByLabel('Security code').fill('123');
    await page.getByTestId('addon-pay-submit').click();
    await page.waitForURL((u) => u.searchParams.get('addons_paid') === '1', { timeout: 30_000 });
    const [paid] = await sql`select count(*)::int n from payments where booking_id = ${b.booking_id} and purpose = 'addon' and status = 'succeeded' and amount_cents = 565`;
    expect(paid!.n).toBe(1);
    const [opened] = await sql`select count(*)::int n from payment_intents_opened where booking_id = ${b.booking_id} and purpose = 'addon_unpaid'`;
    expect(opened!.n).toBe(1);
    await expect(page.getByTestId('portal-addons-pay')).toHaveCount(0);
  } finally { await sql.end(); }
});
