import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, giveLicence, noOverflow, storeFixturePdf, watch } from './helpers';

// Migration 0144 end to end, at both widths: field staff fix the ready check on their phone (the licence checked in
// person with three photos and four checks, the deposit by e-Transfer) and release a car whose tracker is not reporting
// with a reason (an Admin task at once); the handover and return jobs are made from the booking and Fleet sees them;
// Finance's Payments by day (methods, totals, the cash drawer count, the refunds waiting, the CSV) and an Admin's approval
// in the same row; the owner's month to date, provisional.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(await page.locator('body').innerText(), `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'field' | 'renter', va?: string) {
  const id = randomUUID(); const email = `ff.${role}.${Date.now()}.${tag()}@example.test`;
  const name = { admin: 'Ada Admin', va: `Val ${va ?? ''}`.trim(), field: 'Finn Field', renter: 'Riley Renter' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!}, 0)`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 60_000 });
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function freeCar(sql: Sql) {
  const from = new Date(Date.now() + 26 * 3600_000); const to = new Date(from.getTime() + 2 * 86_400_000);
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from.toISOString()}::timestamptz - interval '4 days', ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
      and not exists (select 1 from field_jobs j where j.vehicle_id = v.id and j.status not in ('cancelled', 'done') and j.scheduled_at between ${from.toISOString()}::timestamptz - interval '3 days' and ${to.toISOString()}::timestamptz)
      and not exists (select 1 from tracker_devices t where t.vehicle_id = v.id and t.status = 'installed')
    order by random() limit 1`;
  if (!rows[0]) throw new Error('no free car');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0].id as string, from: ymd(from), to: ymd(to) };
}
// a request offered, approved, signed and paid, confirmed: but the driver not verified and no deposit (the office's work left)
async function confirmedButNotReady(sql: Sql, admin: string, renter: { id: string; email: string }, vehicle: string, from: string, to: string) {
  const req = {
    request_key: randomUUID(), vehicle_id: vehicle, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email: renter.email, full_name: 'Riley Renter', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  const booking = v.booking_id;
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
  await sql`update booking_drivers set identity_method = null, identity_verified_on = null, licence_number = coalesce(licence_number, 'L1234-56789-01234'), licence_expiry = coalesce(licence_expiry, date '2031-01-01') where booking_id = ${booking}`;
  await sql`update verification_uploads set status = 'replaced' where booking_id = ${booking} and kind in ('licence_front', 'licence_back', 'selfie')`.catch(async () => {
    await sql`delete from verification_uploads where booking_id = ${booking} and kind in ('licence_front', 'licence_back', 'selfie')`;
  });
  await sql`insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (${booking}, 2, 'confirmed', 'Bank', '4242', now())`;
  await sql`update bookings set coverage_option = 2, coverage_confirmed_at = now(), blocks_calendar = true where id = ${booking}`;
  return v;
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

test('field staff fix the ready check on the phone and release a car whose tracker is not reporting; Fleet sees the jobs made from the booking', async ({ browser }, info) => {
  test.setTimeout(600_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const field = await mkUser(sql, 'field');
  const fleet = await mkUser(sql, 'va', 'fleet');
  const renter = await mkUser(sql, 'renter');
  const car = await freeCar(sql);
  const b = await confirmedButNotReady(sql, admin.id, renter, car.id, car.from, car.to);
  // the jobs were made from the booking at its confirmation (0144)
  const jobs = await sql`select kind, auto_created, place from field_jobs where booking_id = ${b.booking_id} and status <> 'cancelled' order by kind`;
  expect(jobs.map((j) => `${j.kind}:${j.auto_created}:${j.place ? 'place' : 'none'}`)).toEqual(['handover:true:place', 'return_check_in:true:place']);
  // the pickup and the job a few minutes ahead, so both fall on today at any hour of the run (the booking was made for
  // 10:00 the day after tomorrow's start: late in the evening the job sat on tomorrow and the check-out ran a day early)
  await sql`update bookings set pickup_at = now() + interval '3 minutes', return_at = now() + interval '2 days' where id = ${b.booking_id}`;
  const [job] = await sql`update field_jobs set assigned_to = ${field.id}, scheduled_at = now() + interval '3 minutes', auto_at = now() + interval '3 minutes'
                           where booking_id = ${b.booking_id} and kind = 'handover' returning id`;

  // Fleet: the jobs are there with their place, marked as made from the booking
  const fp = await ctx(browser, phone);
  await signIn(fp, fleet.email, '/va');
  await fp.goto('/va/fleet', { waitUntil: 'networkidle' });
  await expect(fp.getByTestId('fleet-auto-note')).toBeVisible();
  await expect(fp.getByTestId('jobs').getByText('made from the booking').first()).toBeVisible();
  await check(fp, 'fleet board');
  await fp.context().close();

  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, field.email, '/field');
  await page.goto(`/field/jobs/${job!.id}`, { waitUntil: 'networkidle' });
  await page.getByTestId('acknowledge').click();
  await expect(page.getByTestId('start')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('start').click();
  await expect(page.getByTestId('ready-check')).toBeVisible({ timeout: 15_000 });
  await expect(page.getByTestId('fix-identity')).toBeVisible();
  await expect(page.getByTestId('fix-deposit')).toBeVisible();
  await check(page, 'ready check with its fixes');
  await expect(page.getByTestId('next')).toBeDisabled();

  // the licence, in person: three photos, four checks
  for (const k of ['licence_front', 'licence_back', 'selfie']) {
    await page.getByTestId(`fix-photo-renter-${k}`).setInputFiles({ name: `${k}.png`, mimeType: 'image/png', buffer: PNG });
    await expect(page.getByTestId('fix-driver-renter').locator('li.is-done')).toHaveCount(['licence_front', 'licence_back', 'selfie'].indexOf(k) + 1, { timeout: 30_000 });
  }
  for (const c of ['name', 'photo', 'expiry', 'class']) await page.getByTestId(`fix-check-${c}-renter`).check();
  await page.getByTestId('fix-identity-confirm-renter').click();
  await expect(page.getByTestId('fix-identity')).toHaveCount(0, { timeout: 30_000 });
  // the deposit by e-Transfer
  await page.getByTestId('fix-deposit-etransfer').locator('summary').click();
  await page.getByTestId('fix-etransfer-ref').fill(`CA${tag().toUpperCase()}`);
  await page.getByTestId('fix-etransfer-save').click();
  await expect(page.getByTestId('fix-deposit')).toHaveCount(0, { timeout: 30_000 });
  await expect(page.getByTestId('next')).toBeEnabled({ timeout: 15_000 });
  await check(page, 'ready check all green');
  const [st] = await sql`select (select identity_verified_on is not null from booking_drivers where booking_id = ${b.booking_id} and role = 'renter') v,
                                (select status from deposits where booking_id = ${b.booking_id}) d,
                                (select count(*)::int from handover_resolutions where booking_id = ${b.booking_id}) n`;
  expect([st!.v, st!.d, st!.n]).toEqual([true, 'captured', 2]);

  const [odo] = await sql`select coalesce(odometer_km, 0)::int o from vehicles where id = ${car.id}`;
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
  await page.getByTestId('fuel').fill('7');
  await page.getByTestId('fuel').fill('8');
  await next(page, 'Keys');
  await page.getByTestId('keys-more').click();
  await next(page, 'Photo set');
  const shots = await page.locator('[data-testid^="shot-"]').count();
  for (let i = 1; i <= shots; i++) await page.getByTestId(`shot-${i}`).setInputFiles({ name: `${i}.png`, mimeType: 'image/png', buffer: PNG });
  await expect(page.getByTestId('upload-count')).toContainText('all uploaded', { timeout: 60_000 });
  await next(page, 'Damage');
  await next(page, 'Tracker');
  // the tracker is not reporting: release with a reason
  await expect(page.getByTestId('next')).toBeDisabled();
  await page.getByTestId('fix-tracker').locator('summary').click();
  await check(page, 'tracker override');
  await page.getByTestId('fix-tracker-reason').fill('Underground parking, no signal; office told by phone');
  await page.getByTestId('fix-tracker-save').click();
  await expect(page.getByTestId('tracker-overridden')).toBeVisible({ timeout: 30_000 });
  await next(page, 'Renter reviews');
  await next(page, 'Signatures');
  await draw(page, 'sign-renter'); await page.getByTestId('use-renter').click(); await expect(page.getByTestId('signed-renter')).toBeVisible({ timeout: 30_000 });
  await draw(page, 'sign-staff'); await page.getByTestId('use-staff').click(); await expect(page.getByTestId('signed-staff')).toBeVisible({ timeout: 30_000 });
  await next(page, 'Hand over the keys');
  await expect(page.getByTestId('upload-count')).toContainText('all uploaded', { timeout: 60_000 });
  await page.getByTestId('complete').click();
  await expect(page.getByTestId('field-done').or(page.locator('.fd-screen .alert--error'))).toBeVisible({ timeout: 30_000 });
  expect(await page.locator('.fd-screen .alert--error').innerText({ timeout: 500 }).catch(() => ''), 'the database refused the completion').toBe('');
  const [done] = await sql`select (select status::text from bookings where id = ${b.booking_id}) s,
                                  (select tracker_reporting from condition_reports where booking_id = ${b.booking_id} and kind = 'pickup') t,
                                  (select queue from tasks where booking_id = ${b.booking_id} and task_type = 'tracker_override') q`;
  expect([done!.s, done!.t, done!.q]).toEqual(['on_rent', false, 'admin']);
  expect(errors).toEqual([]);
  await sql.end();
});

test('Finance: Payments by day with the methods, totals, the cash drawer count, the refunds waiting and the CSV; an Admin approves in the same row', async ({ browser }, info) => {
  test.setTimeout(300_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const fin = await mkUser(sql, 'va', 'finance');
  const [bk] = await sql`select b.id, b.booking_number, b.renter_id from bookings b where b.status in ('confirmed', 'closed', 'returned') order by b.created_at desc limit 1`;
  // a quiet day of its own, far in the past, so the totals are this test's (per width)
  const day = phone ? '2025-11-03' : '2025-11-04';
  const ref = `ET${tag().toUpperCase()}`;
  // (the day is this test's alone: what an earlier run left that day goes)
  await sql`delete from manual_payments where payment_id in (select id from payments where processed_at >= ${day}::date - 1 and processed_at < ${day}::date + 2)`;
  await sql`delete from payments where processed_at >= ${day}::date - 1 and processed_at < ${day}::date + 2`;
  await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at, card_brand, card_last4) values
    (${bk!.id}, ${bk!.renter_id}, 'booking_total', 'charge', 'card', 50000, 'succeeded', ${`${day}T15:00:00Z`}, 'visa', '4242'),
    (${bk!.id}, ${bk!.renter_id}, 'deposit', 'charge', 'cash', 100000, 'succeeded', ${`${day}T16:00:00Z`}, null, null),
    (${bk!.id}, ${bk!.renter_id}, 'deposit', 'refund', 'cash', 30000, 'succeeded', ${`${day}T20:00:00Z`}, null, null)`;
  const [et] = await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at) values
    (${bk!.id}, ${bk!.renter_id}, 'booking_total', 'charge', 'e_transfer', 20000, 'succeeded', ${`${day}T17:00:00Z`}) returning id`;
  await sql`insert into manual_payments (payment_id, target, booking_id, renter_id, method, amount_cents, received_on, reference, recorded_by, covers)
            values (${et!.id}, 'booking', ${bk!.id}, ${bk!.renter_id}, 'e_transfer', 20000, ${day}, ${ref}, ${fin.id}, 'rental')`;
  await sql`delete from cash_drawer_counts where day = ${day}`;
  const amt = (phone ? 1500 : 1600) + Math.floor(Math.random() * 90) + 1;
  const money = `$${(amt / 100).toFixed(2)}`;
  const [rf] = await sql`insert into refunds (booking_id, reason, amount_cents, requested_by, note) values (${bk!.id}, 'goodwill', ${amt}, ${admin.id}, ${`e2e ${tag()}`}) returning id`;

  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, fin.email, '/va');
  await page.goto(`/va/payments?from=${day}&to=${day}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('payments-rows')).toContainText(ref);
  await expect(page.getByTestId('payments-rows')).toContainText('Card Visa ending 4242');
  await expect(page.getByTestId('payments-rows')).not.toContainText('booking_total');
  await expect(page.getByTestId('payments-totals')).toContainText('Cash');
  await check(page, 'Payments by day');
  // a method filter
  await page.getByTestId('pay-m-cash').check();
  await page.getByTestId('pay-apply').click();
  await page.waitForURL(/method=cash/);
  await expect(page.getByTestId('payments-rows')).not.toContainText(ref);
  await expect(page.getByTestId('payments-rows')).toContainText('Cash');
  // the cash drawer: expected $700.00, counted $695.00: short $5.00
  await page.goto(`/va/payments?from=${day}&to=${day}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('payments-days')).toContainText('$700.00');
  await page.getByTestId(`cash-count-${day}`).click();
  const form = page.getByTestId(`cash-count-${day}-form`);
  await form.getByRole('textbox', { name: /Cash counted/ }).fill('695');
  await form.getByTestId(`cash-count-${day}-submit`).click();
  await expect(page.getByTestId(`cash-diff-${day}`)).toContainText('short $5.00', { timeout: 20_000 });
  // the refund waiting: goodwill is an Admin's, Finance may decline
  const row = page.getByTestId('refund-queue').locator('tr', { hasText: bk!.booking_number as string }).filter({ hasText: money });
  await expect(row.first()).toContainText('an Admin approves');
  await check(page, 'refunds waiting');
  // the CSV, with the same filters
  const csv = await page.request.get(`/api/payments/export?from=${day}&to=${day}`);
  expect(csv.status()).toBe(200);
  const text = await csv.text();
  expect(text.split('\r\n')[0]).toBe('Date,Time,Method,What,How,Reference,Booking,From or to,Amount,Status,Recorded by');
  expect(text).toContain(ref);
  expect(text).toContain('-300.00');
  expect(errors).toEqual([]);
  await page.context().close();

  // the Admin approves it in the same row
  const ap = await ctx(browser, phone);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/payments', { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('refund-queue')).toBeVisible();
  await check(ap, 'Admin Payments by day');
  await ap.getByTestId('refund-queue').locator('tr', { hasText: money }).filter({ hasText: bk!.booking_number as string }).first().getByRole('button', { name: 'Approve' }).click();
  await expect.poll(async () => (await sql`select status from refunds where id = ${rf!.id}`)[0]!.status, { timeout: 20_000 }).toBe('approved');
  await ap.context().close();
  await sql.end();
});

test('the owner sees this month so far, provisional, and nothing is kept', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  // an owner of their own, with a car in the program
  const uid = randomUUID(); const email = `ff.owner.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${uid}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${uid}, ${email}, 'Olive Owner')`;
  await sql`insert into user_roles (user_id, role) values (${uid}, 'owner')`;
  const [o] = await sql`insert into owners (user_id, owner_type, legal_name, status, email, phone) values (${uid}, 'individual', 'Olive Owner', 'active', ${email}, '416-555-0100') returning id`;
  await sql`insert into vehicles (owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy, enrollment_date)
            values (${o!.id}, 2022, 'Toyota', ${`Corolla ${tag()}`}, ${('FF' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${'FF' + tag().toUpperCase()}, 'standard', 'available', 'managed', 'transfer', true, current_date - 40)`;
  const before = 0;
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, email, '/owner');
  await page.goto('/owner/statements', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('owner-mtd')).toBeVisible();
  await expect(page.getByTestId('owner-mtd-provisional').or(page.getByTestId('owner-mtd').getByText('is approved'))).toBeVisible();
  await check(page, 'owner statements with the month so far');
  const [after] = await sql`select count(*)::int n from owner_statements where owner_id = ${o!.id}`;
  expect(after!.n).toBe(before);
  expect(errors).toEqual([]);
  await sql.end();
});
