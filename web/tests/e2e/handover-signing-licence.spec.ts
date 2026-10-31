import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, giveLicence, noOverflow, storeFixturePdf, watch, strongSign } from './helpers';

// Migration 0130 end to end, at both widths: Sales checks a car out from the booking page with the field checklist, an
// Admin checks it in three hours late from Admin > Today's list, the photo report shows the times, Late by, kilometres,
// fuel, photos and the return charges written at check-in, a charge is waived with a reason, and the renter reads the
// report from Documents; customer service collects the renter's signature on their own device ("Sign now on this
// device"); the renter uploads the licence from the request before the offer can be accepted; field staff open a
// check-out from their job card in one tap; a profile address fills in from a suggestion.
const SHOTS = '/tmp/claude-0/-home-claude/cd546a4d-311f-50f2-8aac-0a6c92256d38/scratchpad/handover-shots';
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function mkUser(sql: Sql, tag: string, role: 'admin' | 'va' | 'field' | 'renter', va?: string) {
  const id = randomUUID(); const email = `${role}.${tag}.${Date.now()}.${Math.floor(Math.random() * 1e4)}@example.test`;
  const name = { admin: 'Ada Admin', va: 'Val Assistant', field: 'Finn Field', renter: 'Riley Renter' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!})`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  return { id, email };
}
async function freeCar(sql: Sql, start: number, days: number, past = 0) {
  const from = new Date(Date.now() + start * 86_400_000); const to = new Date(from.getTime() + days * 86_400_000);
  const since = past > 0 ? new Date(Math.min(from.getTime(), Date.now() - past * 86_400_000)) : from;
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${since.toISOString()}::timestamptz, ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
      and not exists (select 1 from field_jobs j where j.vehicle_id = v.id and j.status not in ('cancelled', 'done') and j.scheduled_at between ${from.toISOString()}::timestamptz - interval '3 days' and ${to.toISOString()}::timestamptz)
    order by random() limit 1`;
  if (!rows[0]) throw new Error('no free car');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0].id as string, from: ymd(from), to: ymd(to) };
}
async function seedRequest(sql: Sql, renter: { id: string; email: string }, vehicle: string, from: string, to: string) {
  // today's 10:00 once it is less than the two-hour notice away: the next half hour that is (any time of day)
  let pickup = `${from}T10:00:00-04:00`;
  if (new Date(pickup).getTime() < Date.now() + 130 * 60_000) pickup = new Date(Math.ceil((Date.now() + 150 * 60_000) / 1_800_000) * 1_800_000).toISOString();
  const req = {
    request_key: randomUUID(), vehicle_id: vehicle, pickup_at: pickup, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email: renter.email, full_name: 'Riley Renter', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  return v;
}
async function confirmBooking(sql: Sql, booking: string, admin: string) {
  await sql`select app.send_offer(${booking}::uuid, ${admin}::uuid)`;
  await giveLicence(sql, booking);
  await sql`select app.approve_offer(b.id, b.current_offer_version, (select user_id from renters where id = b.renter_id)) from bookings b where b.id = ${booking}`;
  const doc = randomUUID(); const sig = randomUUID();
  await sql`insert into documents (id, kind, storage_bucket, storage_path, booking_id) values (${doc}, 'rental_agreement', 'agreements', ${`bookings/${booking}/agreement.pdf`}, ${booking})`;
  storeFixturePdf('agreements', `bookings/${booking}/agreement.pdf`);
  await sql`insert into signature_requests (id, document_id, provider, provider_envelope, status, completed_at) values (${sig}, ${doc}, 'esign', ${`env-${booking}`}, 'completed', now())`;
  await sql`update bookings set signature_request_id = ${sig}, agreement_document_id = ${doc} where id = ${booking}`;
  await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
            select id, renter_id, 'booking_total', 'charge', 'card', renter_due_at_booking_cents, 'succeeded', now() from bookings where id = ${booking}`;
  await sql`insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit)
            select renter_id, 'visa', '4242', 'Riley Renter', 12, 2031, true from bookings where id = ${booking}`;
  await sql`update bookings b set card_on_file_id = (select pm.id from payment_methods pm where pm.renter_id = b.renter_id order by pm.created_at desc limit 1) where b.id = ${booking}`;
  await sql`update bookings set status = 'confirmed' where id = ${booking}`;
  await sql`update booking_drivers set identity_method = 'staff_review', identity_verified_on = current_date, licence_number = coalesce(licence_number, 'L1234-56789-01234'), licence_expiry = coalesce(licence_expiry, date '2031-01-01'), licence_issuer = coalesce(licence_issuer, 'ON') where booking_id = ${booking}`;
  // what a claim needs on the agreement (0154: check-out stops without it): the renter's home address, the car's plate and VIN
  await sql`update renters r set address_line1 = coalesce(r.address_line1, '1 Test Street'), city = coalesce(r.city, 'Toronto'), province = coalesce(r.province, 'ON'),
            postal_code = coalesce(r.postal_code, 'M5H 2N2'), mobile = coalesce(r.mobile, '+16475550123') from bookings b where b.id = ${booking} and r.id = b.renter_id`;
  await sql`update vehicles v set plate = coalesce(nullif(v.plate, ''), 'E2E' || upper(substr(md5(v.id::text), 1, 4))),
            vin = coalesce(nullif(v.vin, ''), '1E2E' || translate(upper(substr(md5(v.id::text || 'vin'), 1, 13)), 'IOQ', '123')) from bookings b where b.id = ${booking} and v.id = b.vehicle_id`;
  await sql`insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (${booking}, 2, 'confirmed', 'Bank', '4242', now())`;
  await sql`update bookings set coverage_option = 2, coverage_confirmed_at = now(), blocks_calendar = true where id = ${booking}`;
  const [pay] = await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
    select id, renter_id, 'deposit', case when billable_days <= 7 then 'hold' else 'charge' end, 'card', deposit_cents, case when billable_days <= 7 then 'authorized' else 'succeeded' end, now() from bookings where id = ${booking} returning id`;
  await sql`select app.record_deposit_taken(${booking}::uuid, ${pay!.id}::uuid, ${admin}::uuid)`;
}
async function tracker(sql: Sql, car: string) {
  const trk = randomUUID();
  await sql`insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (${trk}, ${`E2E-${trk.slice(0, 8)}`}, ${car}, 'installed', now(), now())`;
  await sql`insert into tracker_status (tracker_device_id, reported_at, speed_kmh, ignition_on) values (${trk}, now() + interval '30 minutes', 0, false)`;
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function draw(page: Page, testId: string) {
  const canvas = page.getByTestId(testId).locator('canvas');
  await canvas.evaluate((e) => e.scrollIntoView({ block: 'center', behavior: 'instant' }));
  const b = (await canvas.boundingBox())!;
  await page.mouse.move(b.x + 20, b.y + b.height * 0.6); await page.mouse.down();
  for (let i = 1; i <= 30; i++) await page.mouse.move(b.x + 20 + i * ((b.width - 60) / 30), b.y + b.height * (0.6 + 0.25 * Math.sin(i / 2.5)), { steps: 2 });
  await page.mouse.up();
}
const next = async (page: Page, title: string) => { await page.getByTestId('next').click(); await expect(page.getByTestId('step-title')).toHaveText(title, { timeout: 15_000 }); };
async function complete(page: Page, text: string) {
  await expect(page.getByTestId('upload-count')).toContainText('all uploaded', { timeout: 60_000 });
  await expect(page.getByTestId('complete')).toBeEnabled({ timeout: 10_000 });
  await page.getByTestId('complete').click();
  await expect(page.getByTestId('field-done').or(page.locator('.fd-screen .alert--error'))).toBeVisible({ timeout: 30_000 });
  expect(await page.locator('.fd-screen .alert--error').innerText({ timeout: 500 }).catch(() => ''), 'the database refused the completion').toBe('');
  await expect(page.getByTestId('field-done')).toContainText(text);
}

test('check-out by Sales from the booking, a late check-in by an Admin from Today, the photo report, a waived charge, the renter\'s report', async ({ browser }, info) => {
  test.setTimeout(600_000);
  const phone = info.project.name.startsWith('phone');
  const w = info.project.name;
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'ho', 'admin');
  const sales = await mkUser(sql, 'ho', 'va', 'sales');
  const renter = await mkUser(sql, 'rho', 'renter');
  const car = await freeCar(sql, 1, 2, 4);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  await confirmBooking(sql, req.booking_id, admin.id);
  // pickup moves to just ahead of now (the request itself must be 2 hours out, so a fixed 10:00 failed after 8 a.m.)
  await sql`update bookings set pickup_at = now() + interval '10 minutes', return_at = now() + interval '2 days', billable_days = calc_billable_days(now() + interval '10 minutes', now() + interval '2 days') where id = ${req.booking_id}`;
  await tracker(sql, car.id);
  const [odo] = await sql`select coalesce(odometer_km, 0)::int o from vehicles where id = ${car.id}`;

  // Sales: the booking page has "Check out (pickup)"
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, sales.email, '/staff');
  await page.goto(`/staff/bookings/${req.booking_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('handover-panel')).toBeVisible();
  await check(page, 'va booking with the check-out card');
  await page.getByTestId('checkout-start').click();
  await page.waitForURL(/\/handover\//, { timeout: 30_000 });
  await expect(page.getByTestId('ready-check')).toBeVisible({ timeout: 15_000 });
  await check(page, 'staff ready check');
  await next(page, 'Car ready');
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Is this the renter?');
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Original licence');
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Card on File');
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Odometer');
  await page.getByTestId('odometer').fill(String(odo!.o + 10));
  await next(page, 'Fuel or charge');
  // the slider starts at 8/8 but unset: move it to set it (filling the same value fires no change)
  await page.getByTestId('fuel').fill('7');
  await page.getByTestId('fuel').fill('8');
  await next(page, 'Keys');
  await page.getByTestId('keys-more').click();
  await next(page, 'Photo set');
  await expect(page.getByText('front plate readable').first()).toBeVisible();
  const shots = await page.locator('[data-testid^="shot-"]').count();
  expect(shots).toBe(19);
  for (let i = 1; i <= shots; i++) await page.getByTestId(`shot-${i}`).setInputFiles({ name: `${i}.png`, mimeType: 'image/png', buffer: PNG });
  await expect(page.getByTestId('upload-count')).toContainText('19 of 19 photos taken · all uploaded', { timeout: 60_000 });
  await page.screenshot({ path: `${SHOTS}/${w}-checkout-photos.png`, fullPage: true });
  await next(page, 'Damage');
  await next(page, 'Tracker');
  await next(page, 'Renter reviews');
  await next(page, 'Signatures');
  await draw(page, 'sign-renter'); await page.getByTestId('use-renter').click(); await expect(page.getByTestId('signed-renter')).toBeVisible({ timeout: 15_000 });
  await draw(page, 'sign-staff'); await page.getByTestId('use-staff').click(); await expect(page.getByTestId('signed-staff')).toBeVisible({ timeout: 15_000 });
  await next(page, 'Hand over the keys');
  await complete(page, 'Checked out');
  const [out] = await sql`select status::text s, odometer_out_km::int km, fuel_out_pct::int f, (select assigned_to from field_jobs j where j.booking_id = b.id and j.kind = 'handover') who from bookings b where b.id = ${req.booking_id}`;
  expect(out).toMatchObject({ s: 'on_rent', km: odo!.o + 10, f: 100, who: sales.id });

  // three hours late, 100 km included: the Admin checks it in from Today with 450 km driven and a quarter tank less
  await sql.begin(async (tx) => {
    await tx`set local session_replication_role = replica`;
    await tx`update bookings set pickup_at = now() - interval '2 days 3 hours', handed_over_at = now() - interval '2 days 3 hours', return_at = now() - interval '3 hours', km_allowance_per_day = 50, km_allowance_total = 100 where id = ${req.booking_id}`;
  });
  const ap = await ctx(browser, phone);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('handovers-today')).toContainText(req.booking_number);
  await ap.goto('/admin/bookings?status=on_rent', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('bookings').getByText(/Overdue by 3 h/).first()).toBeVisible();
  await ap.goto('/admin', { waitUntil: 'networkidle' });
  await ap.getByTestId(`today-return-${req.booking_number}`).click();
  await ap.waitForURL(/\/handover\//, { timeout: 30_000 });
  await expect(ap.getByTestId('step-title')).toHaveText('Car and keys received', { timeout: 15_000 });
  await ap.getByRole('button', { name: 'Yes' }).click();
  await next(ap, 'Odometer');
  await ap.getByTestId('odometer').fill(String(odo!.o + 460));
  await next(ap, 'Fuel or charge');
  await ap.getByTestId('fuel').fill('6');
  await next(ap, 'Keys and extras');
  await ap.getByTestId('keys-more').click();
  await next(ap, 'Cleanliness');
  await ap.getByLabel('Standard').check();
  await next(ap, 'Photo set');
  for (let i = 1; i <= 19; i++) await ap.getByTestId(`shot-${i}`).setInputFiles({ name: `r${i}.png`, mimeType: 'image/png', buffer: PNG });
  await expect(ap.getByTestId('upload-count')).toContainText('19 of 19 photos taken · all uploaded', { timeout: 60_000 });
  await next(ap, 'Compare with pickup');
  await next(ap, 'Belongings');
  await next(ap, 'Renter reviews and signs');
  await draw(ap, 'sign-renter'); await ap.getByTestId('use-renter').click(); await expect(ap.getByTestId('signed-renter')).toBeVisible({ timeout: 15_000 });
  await next(ap, 'You sign and complete');
  await draw(ap, 'sign-staff'); await ap.getByTestId('use-staff').click(); await expect(ap.getByTestId('signed-staff')).toBeVisible({ timeout: 15_000 });
  await complete(ap, 'Checked in');
  await ap.getByTestId('checklist-back').click();
  await ap.waitForURL(/\/report$/, { timeout: 20_000 });
  await expect(ap.getByTestId('report-facts')).toContainText('Late by 3 h');
  await expect(ap.getByTestId('report-facts')).toContainText('350 km over');
  await expect(ap.getByTestId('report-facts')).toContainText('25% lower');
  await expect(ap.getByTestId('report-charges')).toContainText('Mileage overage');
  await expect(ap.getByTestId('report-pickup').locator('.hr-photos li')).toHaveCount(19);
  await check(ap, 'admin photo report');
  await ap.screenshot({ path: `${SHOTS}/${w}-admin-report.png`, fullPage: true });
  await ap.getByTestId('waive-late_return_fee').click();
  await ap.locator('dialog[open]').getByLabel('Why it is waived').fill('Traffic on the 401, called ahead');
  await ap.getByTestId('waive-late_return_fee-submit').click();
  await expect(ap.getByTestId('waived-late_return_fee')).toContainText('Traffic on the 401', { timeout: 15_000 });
  const [lines] = await sql`select count(*) filter (where assessment_key = 'mileage_overage' and voided_at is null and amount_cents = 350 * overage_cents_per_km)::int km,
      count(*) filter (where assessment_key = 'late_return_fee' and voided_at is not null and void_reason like 'waived:%')::int waived
    from booking_line_items li join bookings b on b.id = li.booking_id where li.booking_id = ${req.booking_id}`;
  expect(lines).toMatchObject({ km: 1, waived: 1 });

  // the renter: the report from Documents (the "Returned" email links to the same page)
  const rp = await ctx(browser, phone);
  await signIn(rp, renter.email, '/account');
  await rp.goto('/account/documents', { waitUntil: 'networkidle' });
  await rp.getByTestId('photo-reports').getByRole('link', { name: 'View' }).first().click();
  await rp.waitForURL(/\/condition-report$/);
  await expect(rp.getByTestId('report-facts')).toContainText('Late by 3 h');
  await expect(rp.getByTestId('report-return').locator('.hr-photos li')).toHaveCount(19);
  await expect(rp.getByTestId('waive-mileage_overage')).toHaveCount(0);
  await check(rp, 'renter photo report');
  await rp.screenshot({ path: `${SHOTS}/${w}-renter-report.png`, fullPage: true });
  expect(errors.filter((e) => !/favicon|Failed to load resource.*(404|401)/.test(e))).toEqual([]);
  await sql.end();
});

test('customer service collects the renter\'s signature on their own device, and sends the link', async ({ browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'sn', 'admin');
  const cs = await mkUser(sql, 'sn', 'va', 'cs');
  const renter = await mkUser(sql, 'rsn', 'renter');
  const car = await freeCar(sql, 20, 3);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  await sql`select app.send_offer(${req.booking_id}::uuid, ${admin.id}::uuid)`;
  await giveLicence(sql, req.booking_id);
  await sql`select app.approve_offer(b.id, b.current_offer_version, ${renter.id}::uuid) from bookings b where b.id = ${req.booking_id}`;
  storeFixturePdf('agreements', `bookings/${req.booking_id}/agreement.pdf`);
  await sql`select app.open_rental_agreement(${req.booking_id}::uuid, ${renter.id}::uuid, 'rental-e2e', encode(sha256(${req.booking_number}::bytea), 'hex'), ${`bookings/${req.booking_id}/agreement.pdf`})`;

  const page = await ctx(browser, phone);
  await signIn(page, cs.email, '/staff');
  await page.goto(`/staff/bookings/${req.booking_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('sign-waiting')).toContainText('Riley Renter');
  await page.getByTestId('sign-link-email').click();
  await expect(page.getByTestId('sign-link-result')).toContainText('Emailed to');
  await page.getByTestId('sign-now-link').click();
  await page.waitForURL(/\/sign-now$/);
  await expect(page.getByTestId('sign-now-signer-renter')).toContainText('Licence on file');
  await check(page, 'sign now, staff view');
  await expect(page.getByTestId('sn-hand-renter')).toBeDisabled();
  await page.getByTestId('sn-name').check();
  await page.getByTestId('sn-licence').check();
  await page.getByTestId('sn-hand-renter').click();
  await expect(page.getByTestId('sign-now-signer')).toBeVisible();
  await page.getByTestId('sn-consents-all').check();
  // 0154: in person too, the code to the renter's phone, the initials, the consents and the drawn signature
  await strongSign(page);
  await check(page, 'sign now, signer view');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-sign-now.png`, fullPage: true });
  await page.getByTestId('sn-sign').click();
  await expect(page.getByTestId('sign-now-done')).toBeVisible({ timeout: 30_000 });
  await page.getByTestId('sign-now-back').click();
  await expect(page.getByTestId('sign-now-all-signed')).toBeVisible({ timeout: 15_000 });
  const [rec] = await sql`select s.method, s.collected_in_person_by = ${cs.id}::uuid by_cs, (s.identity_check ->> 'licence_seen') seen, a.status
    from rental_agreements a join signature_records s on s.signature_request_id = a.signature_request_id and s.signer_role = 'renter' where a.booking_id = ${req.booking_id}`;
  expect(rec).toMatchObject({ method: 'drawn', by_cs: true, seen: 'true', status: 'signed' });
  await sql.end();
});

// 0185: the renter accepted online and left the pay page without signing or paying; at the office the Admin sees
// "Sign now on this device" on the booking (the card was empty), records the rental and fees in cash at once (both parts,
// one step) and the booking is confirmed, waiting for the renter's signature; the car is not released until they sign.
test('waiting for payment and not signed: sign now on this device; the rental and fees in cash at once confirm it', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'pb', 'admin');
  const renter = await mkUser(sql, 'rpb', 'renter');
  const car = await freeCar(sql, 30, 3);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  await sql`select app.send_offer(${req.booking_id}::uuid, ${admin.id}::uuid)`;
  await giveLicence(sql, req.booking_id);
  await sql`select app.approve_offer(b.id, b.current_offer_version, ${renter.id}::uuid) from bookings b where b.id = ${req.booking_id}`;
  const [b0] = await sql`select status from bookings where id = ${req.booking_id}`;
  expect(b0!.status).toBe('pending_payment');

  const page = await ctx(browser, phone);
  await signIn(page, admin.email, '/admin');
  const base = `/admin/bookings/${req.booking_number}`;
  await page.goto(base, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('handover-panel')).toBeVisible();
  await expect(page.getByTestId('sign-now-link')).toBeVisible();
  await expect(page.getByTestId('sign-state')).toContainText('Sign now on this device prepares it');
  await check(page, 'waiting for payment, sign now');

  await page.goto(`${base}?tab=money`, { waitUntil: 'networkidle' });
  await page.getByTestId('bm-record-open').click();
  await expect(page.getByTestId('bm-covers')).toHaveValue('both');
  await page.getByTestId('bm-method').selectOption('cash');
  await page.getByTestId('bm-record-save').click();
  await expect(page.getByTestId('bm-message')).toContainText('CarmaCars countersigns the rental agreement when the renter signs', { timeout: 20_000 });
  const [b1] = await sql`select b.status, app.booking_part_open(b.id, 'rental') + app.booking_part_open(b.id, 'fees') as open,
    (select count(*) from manual_payments m where m.booking_id = b.id and m.voided_at is null) as n, app.booking_awaiting_signature(b.id) as awaiting from bookings b where b.id = ${req.booking_id}`;
  expect(`${b1!.status}/${Number(b1!.open)}/${Number(b1!.n) >= 1}/${b1!.awaiting}`).toBe('confirmed/0/true/true');
  const refused = await sql`update bookings set status = 'on_rent' where id = ${req.booking_id}`.then(() => '', (e: Error) => e.message);
  expect(refused).toMatch(/has not signed/);

  await page.goto(base, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('sign-now-link')).toBeVisible();
  await page.getByTestId('sign-now-link').click();
  await page.waitForURL(/\/sign-now$/);
  // the agreement is made by now (a confirmed booking gets it by itself, 0132), or the page prepares it
  await expect(page.getByTestId('sign-now-signer-renter').or(page.getByTestId('sign-now-prepare'))).toBeVisible();
  await check(page, 'paid, sign now');
  await sql.end();
});

test('the licence is uploaded from the request before the offer can be accepted', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'lic', 'admin');
  const renter = await mkUser(sql, 'rlic', 'renter');
  const car = await freeCar(sql, 30, 3);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  const page = await ctx(browser, phone);
  await signIn(page, renter.email, '/account');
  await page.goto(`/book/sent/${req.booking_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('sent-licence')).toBeVisible();
  await sql`select app.send_offer(${req.booking_id}::uuid, ${admin.id}::uuid)`;
  await page.goto(`/account/bookings/${req.booking_number}/offer`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('licence-needed')).toContainText('licence front');
  await expect(page.getByTestId('offer-licence-first')).toBeVisible();
  await expect(page.getByRole('button', { name: 'Approve and continue' })).toHaveCount(0);
  await check(page, 'offer, licence first');
  await page.getByTestId('offer-licence-first').click();
  await page.waitForURL(/\/verify$/);
  await expect(page.getByTestId('licence-details')).toBeVisible();
  await page.getByTestId('lf-number').fill('A1234-12345-12345');
  await page.getByTestId('lf-expiry').fill('2031-06-30');
  await page.getByTestId('lf-save').click();
  await expect(page.getByTestId('licence-details')).toHaveCount(0, { timeout: 15_000 });
  const png = await page.screenshot({ clip: { x: 0, y: 0, width: 300, height: 200 } });
  for (const kind of ['licence_front', 'licence_back', 'selfie']) {
    const card = page.locator(`[data-testid^="upload-${kind}-"]`).first();
    await card.locator('input[type="file"]').setInputFiles({ name: `${kind}.png`, mimeType: 'image/png', buffer: png });
    await expect(card.getByText('In review')).toBeVisible({ timeout: 15_000 });
  }
  await page.reload();
  await expect(page.getByTestId('licence-complete')).toBeVisible();
  await check(page, 'licence step');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-licence.png`, fullPage: true });
  await page.goto(`/account/bookings/${req.booking_number}/offer`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('licence-needed')).toHaveCount(0);
  await page.getByRole('button', { name: 'Approve and continue' }).click();
  await page.waitForURL(/\/sign$/, { timeout: 30_000 });
  await sql.end();
});

test('field staff open a check-out from their job card in one tap', async ({ browser }, info) => {
  test.skip(!info.project.name.startsWith('phone'), 'the field portal is a phone app');
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkUser(sql, 'fc', 'admin');
  const field = await mkUser(sql, 'fc', 'field');
  const renter = await mkUser(sql, 'rfc', 'renter');
  const car = await freeCar(sql, 1, 2, 2);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  await confirmBooking(sql, req.booking_id, admin.id);
  // pickup moves to just ahead of now (the request itself must be 2 hours out, so a fixed 10:00 failed after 8 a.m.)
  // the job and the pickup a few minutes ahead, so both are today's even late in the evening (the field list is today's jobs)
  await sql`update bookings set pickup_at = now() + interval '3 minutes', return_at = now() + interval '2 days', billable_days = calc_billable_days(now() + interval '3 minutes', now() + interval '2 days') where id = ${req.booking_id}`;
  const [job] = await sql`select app.create_field_job('handover', ${car.id}::uuid, now() + interval '3 minutes', ${admin.id}::uuid, ${req.booking_id}::uuid, ${field.id}::uuid, '1 Front St W, Toronto') id`;
  const page = await ctx(browser, true);
  await signIn(page, field.email, '/staff/field');
  // the job is in an hour: on Tomorrow's list late in the evening
  const [when] = await sql`select (scheduled_at at time zone 'America/Toronto')::date = (now() at time zone 'America/Toronto')::date today from field_jobs where id = ${job!.id}::uuid`;
  await page.goto(when!.today ? '/staff/field' : '/staff/field?day=tomorrow', { waitUntil: 'networkidle' });
  await check(page, 'field jobs with the check-out button');
  // this job's own card: the booking's automatic handover job (0151) may be on the same list, given to the least busy
  // field staff member, who can be this new one
  await page.getByTestId('job-card').filter({ has: page.locator(`a[href="/staff/field/jobs/${job!.id}"]`) }).getByTestId('field-checkout').click();
  await page.waitForURL(new RegExp(`/staff/field/jobs/${job!.id}`), { timeout: 30_000 });
  await expect(page.getByTestId('ready-check')).toBeVisible({ timeout: 15_000 });
  await sql.end();
});

test('a profile address fills in from a suggestion', async ({ browser }, info) => {
  test.setTimeout(90_000);
  const sql = db();
  const renter = await mkUser(sql, 'addr', 'renter');
  // the contact details form is for a renter on file (the record a first request makes)
  await sql`insert into renters (user_id, legal_name, email, mobile, date_of_birth) values (${renter.id}, 'Riley Renter', ${renter.email}, '+14165550142', '1990-05-05') on conflict (user_id) do nothing`;
  const page = await ctx(browser, info.project.name.startsWith('phone'));
  await signIn(page, renter.email, '/account');
  await page.goto('/account/profile', { waitUntil: 'networkidle' });
  await page.getByTestId('pt-p-lookup').fill('union station');
  await page.getByRole('option', { name: /Union Station/ }).click();
  await expect(page.locator('#pt-p-address_line1')).toHaveValue('65 Front Street West', { timeout: 10_000 });
  await expect(page.locator('#pt-p-city')).toHaveValue('Toronto');
  await expect(page.locator('#pt-p-province')).toHaveValue('ON');
  await expect(page.locator('#pt-p-postal_code')).toHaveValue('M5J 1E6');
  await check(page, 'profile address');
  await sql.end();
});
