import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { createHmac, randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, watch, storeFixturePdf } from './helpers';

// The staff and investor portals end to end (migration 0031). A customer service assistant reviews a
// request and sends the offer; a finance assistant asks for a refund above their limit and it becomes an
// Admin's approval; a fleet assistant schedules and assigns a field job; the field staff member completes
// a full handover with every photo and the renter's signature on a phone, then a late return with new
// damage; an investor sees only their own records; an Admin enrols an authenticator app and signs in with
// the second step. Every page visited is checked with axe, for overflow and with the copy rules.
const SHOTS = 'test-results/staff';
const PW = 'correct horse battery';
const COPY_RULES: Array<[RegExp, string]> = [[/[—–]/, 'long dash'], [/18122211(?! Canada Inc\.)|(?<!18122211 )Canada Inc\b/i, 'numbered company name (allowed only as the party, "18122211 Canada Inc.", 0120)'], [/\bCarma[ -]+Cars\b|\bCarmacars\b|\bCARMACARS\b|\bcarmaCars\b|\bCarmaCar\b(?!s)/, 'brand misspelled']];
type Sql = ReturnType<typeof db>;
mkdirSync(SHOTS, { recursive: true });
// a 1 x 1 PNG: the page re-encodes it as JPEG before the upload, as it does with a camera photo
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64');

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = (await page.locator('body').innerText()).replace(/[\w.+-]+@[\w.-]*carmacars\.ca|https?:\/\/\S+|\bcarmacars\.ca\b/gi, ' ');
  for (const [re, what] of COPY_RULES) expect(text.match(re)?.[0], `${where}: ${what}`).toBeUndefined();
}
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const vp = (phone: boolean) => (phone ? { width: 375, height: 812 } : { width: 1440, height: 900 });

// RFC 6238, as an authenticator app computes it
function totp(secret: string, t = Date.now()) {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'; let bits = '';
  for (const c of secret) bits += A.indexOf(c).toString(2).padStart(5, '0');
  const key = Buffer.from(bits.match(/.{8}/g)!.map((b) => parseInt(b, 2)));
  const ctr = Buffer.alloc(8); ctr.writeBigUInt64BE(BigInt(Math.floor(t / 30_000)));
  const h = createHmac('sha1', key).update(ctr).digest(); const o = h[h.length - 1]! & 0xf;
  return String((h.readUInt32BE(o) & 0x7fffffff) % 1_000_000).padStart(6, '0');
}

async function mkUser(sql: Sql, tag: string, role: 'admin' | 'va' | 'field' | 'renter', extra: { va?: string } = {}) {
  const id = randomUUID(); const email = `${role}.${tag}.${Date.now()}.${Math.floor(Math.random() * 1e4)}@example.test`;
  const name = { admin: 'Ada Admin', va: 'Val Assistant', field: 'Finn Field', renter: 'Riley Renter' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${extra.va!})`;
  if (role === 'field') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, field_function) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'field', 'driver')`;
  return { id, email };
}
// `past`: the car must also be free that many days back (a test that later moves its booking into the past;
// the exclusion constraint bookings_no_double_booking refuses the move onto another booking of the car)
async function freeCar(sql: Sql, start: number, days: number, past = 0) {
  const from = new Date(Date.now() + start * 86_400_000); const to = new Date(from.getTime() + days * 86_400_000);
  const since = past > 0 ? new Date(Math.min(from.getTime(), Date.now() - past * 86_400_000)) : from;
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable)
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
  return v;
}
/** Offered, approved, signed, paid, verified, covered, confirmed: what procedures 1 and 2 leave behind. */
async function confirmBooking(sql: Sql, booking: string, admin: string) {
  await sql`select app.send_offer(${booking}::uuid, ${admin}::uuid)`;
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
  await sql`update booking_drivers set identity_method = 'staff_review', identity_verified_on = current_date, licence_number = coalesce(licence_number, 'L1234-56789-01234'), licence_expiry = coalesce(licence_expiry, date '2031-01-01') where booking_id = ${booking}`;
  await sql`insert into coverage_proofs (booking_id, coverage_option, status, card_issuer, card_last4, confirmed_at) values (${booking}, 2, 'confirmed', 'Bank', '4242', now())`;
  await sql`update bookings set coverage_option = 2, coverage_confirmed_at = now(), blocks_calendar = true where id = ${booking}`;
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
  const c = await browser.newContext({ viewport: vp(phone), hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}
async function draw(page: Page, testId: string) {
  const canvas = page.getByTestId(testId).locator('canvas');
  await canvas.evaluate((e) => e.scrollIntoView({ block: 'center', behavior: 'instant' })); // clear of the fixed button bar
  const b = (await canvas.boundingBox())!;
  await page.mouse.move(b.x + 20, b.y + b.height * 0.6); await page.mouse.down();
  for (let i = 1; i <= 30; i++) await page.mouse.move(b.x + 20 + i * ((b.width - 60) / 30), b.y + b.height * (0.6 + 0.25 * Math.sin(i / 2.5)), { steps: 2 });
  await page.mouse.up();
}
async function complete(page: Page, text: string) {
  await expect(page.getByTestId('upload-count')).toContainText('all uploaded', { timeout: 30_000 });
  await expect(page.getByTestId('complete')).toBeEnabled({ timeout: 10_000 });
  await page.getByTestId('complete').click();
  // the page shows the finished checklist, or (once the job page reloads) the job as done
  await expect(page.getByTestId('field-done').or(page.getByTestId('job-done')).or(page.locator('.fd-screen .alert--error'))).toBeVisible({ timeout: 30_000 });
  const err = await page.locator('.fd-screen .alert--error').innerText({ timeout: 500 }).catch(() => '');
  expect(err, 'the database refused the completion').toBe('');
  if (await page.getByTestId('field-done').isVisible()) await expect(page.getByTestId('field-done')).toContainText(text);
}
const next = async (page: Page, title: string) => { await page.getByTestId('next').click(); await expect(page.getByTestId('step-title')).toHaveText(title, { timeout: 15_000 }); };

test('va: customer service reviews a request from the queue and sends the offer', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const cs = await mkUser(sql, 'cs', 'va', { va: 'cs' });
  const renter = await mkUser(sql, 'rq', 'renter');
  const car = await freeCar(sql, 60 + (phone ? 0 : 10), 3);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, cs.email, '/va');
  await expect(page.getByRole('heading', { name: 'To do', level: 1 })).toBeVisible();
  await check(page, 'va queue');
  await page.screenshot({ path: `${SHOTS}/va-queue-${info.project.name}.png`, fullPage: true });
  await page.goto('/va/today'); await expect(page.getByTestId('digest')).toBeVisible(); await check(page, 'va today');
  await page.goto('/va/requests'); await expect(page.getByTestId('requests')).toContainText(req.booking_number); await check(page, 'va requests');
  await page.goto('/va'); await page.locator(`a[href^="/va/bookings/${req.booking_number}"]`).first().click();
  await page.waitForURL(new RegExp(`/va/bookings/${req.booking_number}`));
  await expect(page.getByTestId('booking-review')).toBeVisible();
  await expect(page.getByLabel('Daily ($)')).toHaveCount(0); // no per-booking price override for an assistant
  await page.getByLabel('Message to the renter').fill('Your car is ready for these dates.');
  await check(page, 'va review');
  await page.screenshot({ path: `${SHOTS}/va-review-${info.project.name}.png`, fullPage: true });
  await page.getByTestId('choice-for_carmacars').check(); // 0058: the sender's choice on a website request
  await page.getByTestId('review-send').click();
  await expect(page.getByRole('status').filter({ hasText: 'Offer sent' })).toBeVisible({ timeout: 15_000 });
  const [b] = await sql`select b.status::text s, (select sent_by from booking_offers o where o.booking_id = b.id order by version desc limit 1) by from bookings b where b.id = ${req.booking_id}`;
  expect(b).toMatchObject({ s: 'offered', by: cs.id });
  expect(errors.filter((e) => !/favicon|Failed to load resource/.test(e))).toEqual([]);
  await sql.end();
});

test('va: finance asks for a refund above the limit and it becomes an Admin approval', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'fa', 'admin');
  const fin = await mkUser(sql, 'fin', 'va', { va: 'finance' });
  const renter = await mkUser(sql, 'rf', 'renter');
  const car = await freeCar(sql, 80 + (phone ? 0 : 10), 3);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  await confirmBooking(sql, req.booking_id, admin.id);
  const page = await ctx(browser, phone);
  await signIn(page, fin.email, '/va');
  await page.goto('/va/money'); await expect(page.getByTestId('failed-payments').or(page.getByTestId('failed-payments-empty'))).toBeVisible(); await check(page, 'va money');
  await page.goto(`/va/bookings/${req.booking_number}?tab=money`);
  await page.getByTestId('request-refund').click();
  await page.getByLabel('Reason').selectOption('goodwill');
  await page.getByLabel('Amount ($)').fill('75.00');
  await page.getByTestId('request-refund-submit').click();
  await expect(page.getByTestId('refunds')).toContainText('Waiting for an Admin', { timeout: 15_000 });
  await check(page, 'va booking money');
  const [t] = await sql`select t.queue, t.task_type, t.escalated, r.status, r.amount_cents::int a from refunds r join tasks t on t.related_table = 'refunds' and t.related_id = r.id where r.booking_id = ${req.booking_id}`;
  expect(t).toMatchObject({ queue: 'admin', task_type: 'approve_refund', escalated: true, status: 'pending_approval', a: 7500 });
  // the Admin sees it in the admin queue
  const ap = await ctx(browser, phone);
  await signIn(ap, admin.email, '/admin');
  await ap.goto('/admin/tasks?queue=admin'); await expect(ap.getByTestId('tasks')).toContainText(`Booking ${req.booking_number}: approve a refund`);
  await sql.end();
});

test('va: fleet schedules and assigns a field job', async ({ browser }, info) => {
  test.setTimeout(150_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'fl', 'admin');
  const fleet = await mkUser(sql, 'fleet', 'va', { va: 'fleet' });
  const field = await mkUser(sql, 'fj', 'field');
  const renter = await mkUser(sql, 'rj', 'renter');
  const car = await freeCar(sql, 2, 2);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  await confirmBooking(sql, req.booking_id, admin.id);
  const page = await ctx(browser, phone);
  await signIn(page, fleet.email, '/va');
  await page.goto('/va/fleet');
  await expect(page.getByTestId('unscheduled')).toContainText(req.booking_number);
  await check(page, 'va fleet');
  await page.getByTestId(`schedule-${req.booking_number}-handover`).click();
  const dlg = page.locator('dialog[open]');
  await dlg.getByLabel('Assigned to').selectOption(field.id);
  await dlg.getByTestId(`schedule-${req.booking_number}-handover-submit`).click();
  await expect.poll(async () => (await sql`select assigned_to from field_jobs where booking_id = ${req.booking_id} and kind = 'handover'`)[0]?.assigned_to, { timeout: 15_000 }).toBe(field.id);
  const [j] = await sql`select id, assigned_to from field_jobs where booking_id = ${req.booking_id} and kind = 'handover'`;
  // and hand it to someone else, then back: an assignment the database checks each time
  const other = await mkUser(sql, 'fj2', 'field');
  await sql`select app.assign_field_job(${j!.id}::uuid, ${other.id}::uuid, ${admin.id}::uuid)`;
  await page.reload();
  await page.getByTestId(`assign-${j!.id}`).click();
  await page.locator('dialog[open]').getByLabel('Field staff').selectOption(field.id);
  await page.getByTestId(`assign-${j!.id}-submit`).click();
  await expect.poll(async () => (await sql`select assigned_to from field_jobs where id = ${j!.id}`)[0]?.assigned_to, { timeout: 15_000 }).toBe(field.id);
  await page.goto('/va/calendar'); await check(page, 'va calendar');
  await sql.end();
});

test('field: a full handover with every photo and the renter signature, then a late return with damage', async ({ browser }, info) => {
  test.skip(!info.project.name.startsWith('phone'), 'the field portal is a phone app');
  test.setTimeout(600_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'fh', 'admin');
  const field = await mkUser(sql, 'fh', 'field');
  const renter = await mkUser(sql, 'rh', 'renter');
  const car = await freeCar(sql, 1, 2, 4);
  const req = await seedRequest(sql, renter, car.id, car.from, car.to);
  await confirmBooking(sql, req.booking_id, admin.id);
  const [bk] = await sql`select pickup_at, deposit_cents::int dep, billable_days d from bookings where id = ${req.booking_id}`;
  const [pay] = await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
    select id, renter_id, 'deposit', case when billable_days <= 7 then 'hold' else 'charge' end, 'card', deposit_cents, case when billable_days <= 7 then 'authorized' else 'succeeded' end, now() from bookings where id = ${req.booking_id} returning id`;
  await sql`select app.record_deposit_taken(${req.booking_id}::uuid, ${pay!.id}::uuid, ${admin.id}::uuid)`;
  const trk = randomUUID();
  await sql`insert into tracker_devices (id, serial_number, vehicle_id, status, installed_at, tested_at) values (${trk}, ${`E2E-${trk.slice(0, 8)}`}, ${car.id}, 'installed', now(), now())`;
  await sql`insert into tracker_status (tracker_device_id, reported_at, speed_kmh, ignition_on) values (${trk}, now() + interval '30 minutes', 0, false)`;
  const [rd] = await sql`select app.booking_readiness(${req.booking_id}::uuid) r`;
  expect((rd!.r as { missing: string[] }).missing.filter((m) => m !== 'pickup_condition_report')).toEqual([]);
  const [job] = await sql`select app.create_field_job('handover', ${car.id}::uuid, ${bk!.pickup_at}::timestamptz, ${admin.id}::uuid, ${req.booking_id}::uuid, ${field.id}::uuid, '1 Front St W, Toronto') id`;
  const [odo] = await sql`select coalesce(odometer_km, 0)::int o from vehicles where id = ${car.id}`;

  const page = await ctx(browser, true);
  const errors = watch(page);
  await signIn(page, field.email, '/field');
  await page.goto('/field');
  if (!(await page.getByTestId('job-card').count())) await page.goto('/field?day=tomorrow');
  await expect(page.getByTestId('job-card').first()).toBeVisible();
  await check(page, 'field jobs');
  await page.screenshot({ path: `${SHOTS}/field-jobs.png`, fullPage: true });
  await page.goto(`/field/jobs/${job!.id}`);
  await page.getByTestId('acknowledge').click();
  await page.getByTestId('start').click();
  await expect(page.getByTestId('ready-check')).toBeVisible({ timeout: 15_000 });
  await check(page, 'field ready check');
  await next(page, 'Car ready');
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Is this the renter?');
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Original licence');
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Card on File');
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Odometer');
  await page.getByTestId('odometer').fill(String(odo!.o + 12));
  await next(page, 'Fuel or charge');
  await page.getByTestId('fuel').fill('7');
  await next(page, 'Keys');
  await page.getByTestId('keys-more').click(); await page.getByTestId('keys-more').click();
  await next(page, 'Photo set');
  const shots = await page.locator('[data-testid^="shot-"]').count();
  expect(shots).toBe(19);
  await check(page, 'field photos');
  for (let i = 1; i <= shots; i++) await page.getByTestId(`shot-${i}`).setInputFiles({ name: `${i}.png`, mimeType: 'image/png', buffer: PNG });
  await expect(page.getByTestId('upload-count')).toContainText('19 of 19 photos taken · all uploaded', { timeout: 60_000 });
  await next(page, 'Damage');
  await expect(page.getByTestId('car-diagram')).toBeVisible();
  await next(page, 'Tracker');
  await next(page, 'Renter reviews');
  await expect(page.getByTestId('summary')).toContainText(`${odo!.o + 12} km`);
  await next(page, 'Signatures');
  await draw(page, 'sign-renter'); await page.getByTestId('use-renter').click(); await expect(page.getByTestId('signed-renter')).toBeVisible({ timeout: 15_000 });
  await draw(page, 'sign-staff'); await page.getByTestId('use-staff').click(); await expect(page.getByTestId('signed-staff')).toBeVisible({ timeout: 15_000 });
  await check(page, 'field signatures');
  await next(page, 'Hand over the keys');
  await complete(page, 'Handed over');
  const [after] = await sql`select b.status::text s, (select count(*)::int from condition_report_photos p join condition_reports c on c.id = p.condition_report_id where c.booking_id = b.id and c.kind = 'pickup') photos,
    (select renter_signature_ref is not null and completed_at is not null from condition_reports c where c.booking_id = b.id and c.kind = 'pickup') signed from bookings b where b.id = ${req.booking_id}`;
  expect(after).toMatchObject({ s: 'on_rent', photos: 19, signed: true });

  // the return: three hours late, with a new scratch
  await sql.begin(async (tx) => {
    await tx`set local session_replication_role = replica`;
    await tx`update bookings set pickup_at = now() - interval '2 days 3 hours' - (return_at - pickup_at - interval '2 days'), handed_over_at = now() - interval '2 days 3 hours', return_at = now() - interval '3 hours' where id = ${req.booking_id}`;
  });
  const [rj] = await sql`select app.create_field_job('return_check_in', ${car.id}::uuid, now() - interval '3 hours', ${admin.id}::uuid, ${req.booking_id}::uuid, ${field.id}::uuid, '1 Front St W, Toronto') id`;
  await page.goto(`/field/jobs/${rj!.id}`);
  await page.getByTestId('acknowledge').click();
  await page.getByTestId('start').click();
  await expect(page.getByTestId('step-title')).toHaveText('Car and keys received', { timeout: 15_000 });
  await page.getByRole('button', { name: 'Yes' }).click();
  await next(page, 'Odometer');
  await page.getByTestId('odometer').fill(String(odo!.o + 412));
  await next(page, 'Fuel or charge');
  await page.getByTestId('fuel').fill('6');
  await next(page, 'Keys and extras');
  await page.getByTestId('keys-more').click(); await page.getByTestId('keys-more').click();
  await next(page, 'Cleanliness');
  await page.getByLabel('Standard').check();
  await next(page, 'Photo set');
  for (let i = 1; i <= 19; i++) await page.getByTestId(`shot-${i}`).setInputFiles({ name: `r${i}.png`, mimeType: 'image/png', buffer: PNG });
  await expect(page.getByTestId('upload-count')).toContainText('19 of 19 photos taken · all uploaded', { timeout: 60_000 });
  await next(page, 'Compare with pickup');
  const box = (await page.getByTestId('car-diagram').boundingBox())!;
  await page.getByTestId('car-diagram').click({ position: { x: box.width * 0.5, y: box.height * 0.9 } });
  await page.getByTestId('damage-location').selectOption('rear bumper');
  await page.getByTestId('damage-description').fill('Scratch on the rear bumper');
  await page.getByTestId('damage-add').click();
  await expect(page.getByTestId('damage-D1')).toBeVisible({ timeout: 15_000 });
  await page.getByTestId('closeup-D1').setInputFiles({ name: 'd1.png', mimeType: 'image/png', buffer: PNG });
  await expect(page.getByTestId('damage-D1')).toContainText('Close-up taken', { timeout: 30_000 });
  // contrast is read once the pointer has left the buttons and Next has finished its transition (a run on October 17
  // caught it mid-transition)
  await page.mouse.move(0, 0);
  await expect(page.getByTestId('next')).toBeEnabled();
  await page.waitForTimeout(400);
  await check(page, 'field damage');
  await next(page, 'Belongings');
  await next(page, 'Renter reviews and signs');
  await draw(page, 'sign-renter'); await page.getByTestId('use-renter').click(); await expect(page.getByTestId('signed-renter')).toBeVisible({ timeout: 15_000 });
  await next(page, 'You sign and complete');
  await draw(page, 'sign-staff'); await page.getByTestId('use-staff').click(); await expect(page.getByTestId('signed-staff')).toBeVisible({ timeout: 15_000 });
  await complete(page, 'Return complete');
  const [ret] = await sql`select b.status::text s, b.minutes_late::int late, b.extra_days::int extra,
    (select count(*)::int from incidents i where i.booking_id = b.id and i.kind = 'damage_at_return') incidents,
    (select d.position is not null from condition_report_damages d join condition_reports c on c.id = d.condition_report_id where c.booking_id = b.id and c.kind = 'return' and d.label = 'D1') marked
    from bookings b where b.id = ${req.booking_id}`;
  expect(ret!.s).toBe('returned');
  expect(ret!.late).toBeGreaterThanOrEqual(170);
  expect(ret!.incidents).toBe(1);
  expect(ret!.marked, 'the damage carries its place on the car diagram').toBe(true);
  // the late fee is assessed from these findings by Finance (assess_check_in): the per-hour line is there
  const [fee] = await sql`select app.assess_check_in(${req.booking_id}::uuid, (select findings from condition_reports where booking_id = ${req.booking_id} and kind = 'return'), ${admin.id}::uuid) a`;
  expect(JSON.stringify(fee!.a)).toContain('late_return');
  expect(errors.filter((e) => !/favicon|Failed to load resource/.test(e))).toEqual([]);
  await sql.end();
});

test('investor: sees only their own records', async ({ browser }, info) => {
  test.setTimeout(120_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const me = await mkUser(sql, 'inv', 'renter');
  const other = await mkUser(sql, 'inv2', 'renter');
  const ids = { a: randomUUID(), b: randomUUID(), ia: randomUUID(), ib: randomUUID(), ra: randomUUID(), rb: randomUUID(), dc: randomUUID(), dd: randomUUID(), ga: randomUUID(), gb: randomUUID() };
  await sql`delete from user_roles where user_id in (${me.id}, ${other.id}) and role = 'renter'`;
  await sql`insert into investors (id, user_id, legal_name, investor_type, status, email) values (${ids.a}, ${me.id}, 'Ivy Investor', 'individual', 'active', ${me.email}), (${ids.b}, ${other.id}, 'Otto Other', 'individual', 'active', ${other.email})`;
  await sql`insert into documents (id, kind, storage_bucket, storage_path) values (${ids.dc}, 'other', 'documents', 'x/c.pdf'), (${ids.dd}, 'other', 'documents', 'x/d.pdf')`;
  await sql`insert into investment_agreements (id, investor_id, agreement_number, status, schedule_c_document_id, schedule_d_document_id, exemption_category, legal_advice_choice)
    values (${ids.ga}, ${ids.a}, ${`IA-${ids.a.slice(0, 6)}`}, 'signed', ${ids.dc}, ${ids.dd}, 'accredited_investor', 'declined'), (${ids.gb}, ${ids.b}, ${`IA-${ids.b.slice(0, 6)}`}, 'signed', ${ids.dc}, ${ids.dd}, 'accredited_investor', 'declined')`;
  await sql`insert into investments (id, investor_id, agreement_id, is_initial, principal_cents, yearly_bps, investment_date, lockup_end_date)
    values (${ids.ia}, ${ids.a}, ${ids.ga}, true, 2500000, 1200, date '2026-01-05', date '2026-07-05'), (${ids.ib}, ${ids.b}, ${ids.gb}, true, 9900000, 1200, date '2026-01-05', date '2026-07-05')`;
  await sql`insert into investment_returns (id, investment_id, return_month, opening_invested_cents, yearly_bps, days_earning, days_in_month, return_cents, disposition, payment_date, closing_invested_cents)
    values (${ids.ra}, ${ids.ia}, date '2026-08-01', 2500000, 1200, 31, 31, 25479, 'pay', date '2026-09-15', 2500000), (${ids.rb}, ${ids.ib}, date '2026-08-01', 9900000, 1200, 31, 31, 100898, 'pay', date '2026-09-15', 9900000)`;
  const page = await ctx(browser, phone);
  await signIn(page, me.email, '/investor');
  await expect(page.getByTestId('investor-name')).toHaveText('Ivy Investor');
  await expect(page.getByTestId('invested-amount')).toHaveText('$25,000.00');
  await expect(page.locator('body')).not.toContainText('Otto Other');
  await expect(page.locator('body')).not.toContainText('$99,000');
  await check(page, 'investor home');
  await page.goto('/investor/statements'); await expect(page.getByTestId('statements')).toContainText('$254.79'); await expect(page.getByTestId('statements')).not.toContainText('$1,008.98'); await check(page, 'investor statements');
  await page.goto(`/investor/statements/${ids.ra}`); await expect(page.getByTestId('statement')).toContainText('section 3.6'); await check(page, 'investor statement');
  const r = await page.goto(`/investor/statements/${ids.rb}`); expect(r!.status()).toBe(404);
  await page.goto('/investor/profile'); await check(page, 'investor profile');
  await page.getByTestId('election-send').click();
  await expect(page.getByRole('status').filter({ hasText: 'Received' })).toBeVisible({ timeout: 15_000 });
  const [t] = await sql`select queue, task_type from tasks where related_table = 'investors' and related_id = ${ids.a}`;
  expect(t).toMatchObject({ queue: 'admin', task_type: 'investor_request' });
  // nothing public: a visitor is sent to sign in, and a renter sees nothing
  const anon = await ctx(browser, phone);
  await anon.goto('/investor'); await expect(anon).toHaveURL(/\/sign-in/);
  await sql.end();
});

test('two-step sign-in: an Admin enrols an authenticator app and signs in with the code', async ({ browser }, info) => {
  test.setTimeout(120_000);
  const phone = info.project.name.startsWith('phone');
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'ts', 'admin');
  const page = await ctx(browser, phone);
  await signIn(page, admin.email, '/admin');
  await page.goto('/two-step/setup?next=/admin');
  await check(page, 'two-step setup');
  await page.getByTestId('totp-start').click();
  const secret = (await page.getByTestId('totp-secret').innerText()).trim();
  expect(secret).toMatch(/^[A-Z2-7]{32}$/);
  await page.getByTestId('totp-code').fill('000000');
  await page.getByTestId('totp-submit').click();
  await expect(page.locator('#ts-err')).toContainText('did not match');
  await page.getByTestId('totp-code').fill(totp(secret));
  await page.getByTestId('totp-submit').click();
  await page.waitForURL((u) => u.pathname === '/admin', { timeout: 15_000 });
  const [f] = await sql`select count(*)::int n from local_auth.factors where user_id = ${admin.id} and verified_at is not null`;
  expect(f!.n).toBe(1);
  // the next sign-in asks for the code, then routes the Admin home
  const p2 = await ctx(browser, phone);
  await signIn(p2, admin.email, '/two-step');
  await check(p2, 'two-step challenge');
  await p2.getByTestId('totp-code').fill(totp(secret));
  await p2.getByTestId('totp-submit').click();
  await p2.waitForURL((u) => u.pathname === '/admin', { timeout: 15_000 });
  await expect(p2.getByRole('heading', { name: 'To do', level: 1 })).toBeVisible();
  await sql.end();
});
