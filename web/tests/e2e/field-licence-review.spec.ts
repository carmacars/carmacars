import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, claimReady, db, giveLicence, noOverflow, storeFixturePdf, watch } from './helpers';

const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
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
  await claimReady(sql, booking);
  return v;
}

// Migration 0162 end to end, at 375: field staff review the renter's licence. Their home lists "Licences to check" for the
// upcoming jobs of their own only (another field staff member sees none); they reject one image with a reason and approve the
// rest from the home, then approve again from the job page; the decisions are customer service's (statuses, the renter told,
// the history with the reviewer's role); an Admin and customer service are unchanged.
test('field staff review the renter\'s licence from their home and from the job', async ({ browser }, info) => {
  test.skip(!info.project.name.startsWith('phone'), 'the field portal is a phone screen: run at 375');
  test.setTimeout(600_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const field = await mkUser(sql, 'field');
  const other = await mkUser(sql, 'field');
  const renter = await mkUser(sql, 'renter');
  const car = await freeCar(sql);
  const b = await confirmedButNotReady(sql, admin.id, renter, car.id, car.from, car.to);
  // the handover job: this field staff member's, two days from now (within 7 days, beyond the job page's 36 hours)
  await sql`update field_jobs set assigned_to = ${field.id} where booking_id = ${b.booking_id}`; // the return job went to the least busy member too
  const [job] = await sql`update field_jobs set assigned_to = ${field.id}, scheduled_at = now() + interval '2 days', auto_at = now() + interval '2 days'
                           where booking_id = ${b.booking_id} and kind = 'handover' returning id`;
  await giveLicence(sql, b.booking_id);
  const waiting = await sql`select count(*)::int n from verification_uploads where booking_id = ${b.booking_id} and status = 'submitted' and kind in ('licence_front', 'licence_back', 'selfie')`;
  expect(waiting[0]!.n).toBe(3);

  // another field staff member's home does not show this booking
  const op = await ctx(browser, true);
  await signIn(op, other.email, '/field');
  await op.waitForLoadState('networkidle');
  await expect(op.locator('body')).not.toContainText(b.booking_number);
  await op.context().close();

  const page = await ctx(browser, true);
  const errors = watch(page);
  await signIn(page, field.email, '/field');
  await page.goto('/field', { waitUntil: 'networkidle' });
  const home = page.getByTestId('field-licences');
  await expect(home).toBeVisible({ timeout: 30_000 });
  // this booking's card (the shared test database may hold other bookings of other tests)
  const card = home.getByTestId('licence-card').filter({ hasText: b.booking_number });
  await expect(card).toHaveCount(1);
  await check(page, 'field home with Licences to check');
  await card.getByTestId('licence-review-open').click();
  const panel = card.getByTestId('licence-review-panel');
  await expect(panel.getByTestId('licence-doc-licence_front')).toBeVisible({ timeout: 30_000 });
  await expect(panel.getByTestId('licence-doc-licence_back')).toBeVisible();
  await expect(panel.getByTestId('licence-doc-selfie')).toBeVisible();
  await check(page, 'licence review panel');
  // the touch targets are large
  const tall = await panel.getByTestId('licence-approve-all').boundingBox();
  expect(tall!.height).toBeGreaterThanOrEqual(44);

  // reject the front with a reason
  await panel.getByTestId('licence-licence_front-reject-open').click();
  await panel.getByTestId('licence-licence_front-reason').fill('The photo is too dark to read');
  await panel.getByTestId('licence-licence_front-reject').click();
  await expect(panel.getByTestId('licence-review-msg')).toContainText('rejected', { timeout: 30_000 });
  const [rej] = await sql`select u.status, u.reject_reason, u.reviewed_by,
      (select count(*)::int from booking_events e where e.booking_id = u.booking_id and e.kind = 'verification' and e.details ->> 'reviewer_role' = 'field' and e.details ->> 'decision' = 'rejected' and e.actor_user_id = ${field.id}) ev,
      (select count(*)::int from app_events a where a.code = 'renter_identity_rejected' and a.entity_id = u.booking_id) told
    from verification_uploads u where u.booking_id = ${b.booking_id} and u.kind = 'licence_front' order by u.uploaded_at limit 1`;
  expect([rej!.status, rej!.reject_reason, rej!.reviewed_by, rej!.ev, rej!.told]).toEqual(['rejected', 'The photo is too dark to read', field.id, 1, 1]);

  // closing the panel refreshes the home: the booking still has the back and the selfie waiting
  await card.getByTestId('licence-review-open').click();
  await expect(card).toHaveCount(1);

  // the renter sends a new front; the job is now close (within 36 hours), so the job page has the review too
  await giveLicence(sql, b.booking_id);
  await sql`update field_jobs set scheduled_at = now() + interval '1 hour', auto_at = now() + interval '1 hour' where id = ${job!.id}`;
  await page.goto(`/field/jobs/${job!.id}`, { waitUntil: 'networkidle' });
  const onJob = page.getByTestId('job-licence');
  await expect(onJob).toBeVisible({ timeout: 30_000 });
  await check(page, 'job page with the licence check');
  await onJob.getByTestId('licence-review-open').click();
  await expect(onJob.getByTestId('licence-doc-licence_front')).toBeVisible({ timeout: 30_000 });
  await onJob.getByTestId('licence-approve-all').click();
  await expect(onJob.getByTestId('licence-review-msg')).toContainText('3 approved', { timeout: 30_000 });
  const [ok] = await sql`select (select count(*)::int from verification_uploads where booking_id = ${b.booking_id} and status = 'approved' and reviewed_by = ${field.id}) n,
      (select identity_verified_on is not null from booking_drivers where booking_id = ${b.booking_id} and role = 'renter') v,
      (select count(*)::int from booking_events e where e.booking_id = ${b.booking_id} and e.details ->> 'reviewer_role' = 'field' and e.details ->> 'decision' = 'approved') ev`;
  expect([ok!.n, ok!.v, ok!.ev]).toEqual([3, true, 3]);
  await page.goto('/field', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('licence-card').filter({ hasText: b.booking_number })).toHaveCount(0);
  await check(page, 'field home after the review');
  expect(errors.filter((e) => !/Failed to load resource|favicon|the server responded/.test(e))).toEqual([]);
  await page.context().close();
  await sql.end();
});
