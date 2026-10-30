import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, giveLicence, noOverflow, watch } from './helpers';

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
async function mkUser(sql: Sql, role: 'admin' | 'va' | 'renter', va?: string) {
  const id = randomUUID(); const email = `sl.${role}.${Date.now()}.${tag()}@example.test`;
  const name = { admin: 'Ada Admin', va: `Val ${va ?? ''}`.trim(), renter: 'Riley Renter' }[role];
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents) values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', ${va!}, 0)`;
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
// an offer out (the renter has not approved it yet): the licence front, back and selfie are already sent
async function offered(sql: Sql, admin: string, renter: { id: string; email: string }, vehicle: string, from: string, to: string) {
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
  await sql`select app.send_offer(${v.booking_id}::uuid, ${admin}::uuid)`;
  await sql`update booking_drivers set licence_number = coalesce(licence_number, 'L1234-56789-01234') where booking_id = ${v.booking_id}::uuid and role = 'renter'`;
  await giveLicence(sql, v.booking_id);
  return v;
}

// Migration 0169 end to end, at 375 and 1440: the Sales function reviews the renter's licence. Their To do lists "Licences to
// check"; the booking page has the review card (reject the front with a reason: the decision is customer service's, with the
// reviewer's role in the history); /va/verify has Approve all and no coverage; the proof of coverage stays closed.
test('Sales review the renter\'s licence from the queue, the booking and the verify page', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const sales = await mkUser(sql, 'va', 'sales');
  const renter = await mkUser(sql, 'renter');
  const car = await freeCar(sql);
  const b = await offered(sql, admin.id, renter, car.id, car.from, car.to);
  const waiting = await sql`select count(*)::int n from verification_uploads where booking_id = ${b.booking_id} and status = 'submitted' and kind in ('licence_front', 'licence_back', 'selfie')`;
  expect(waiting[0]!.n).toBe(3);

  const phone = test.info().project.name.startsWith('phone');
  const page = await ctx(browser, phone);
  const errors = watch(page);
  await signIn(page, sales.email, '/staff');
  await page.goto('/staff', { waitUntil: 'networkidle' });
  const list = page.getByTestId('va-licences');
  await expect(list).toBeVisible({ timeout: 30_000 });
  const line = list.getByTestId(`va-licence-${b.booking_number}`);
  await expect(line).toHaveCount(1);
  await expect(line).toContainText('3 images to check');
  await check(page, 'Sales queue with Licences to check');

  // the booking page: the review card and the dialog, licence only
  await page.goto(`/staff/bookings/${b.booking_number}`, { waitUntil: 'networkidle' });
  const card = page.getByTestId('booking-doc-review');
  await expect(card).toBeVisible({ timeout: 30_000 });
  await card.getByTestId('doc-review-open').click();
  const dlg = page.getByTestId('doc-review-dialog');
  await expect(dlg.getByTestId('doc-licence_front')).toBeVisible({ timeout: 30_000 });
  await expect(dlg.getByTestId('doc-licence_back')).toBeVisible();
  await expect(dlg.getByTestId('doc-selfie')).toBeVisible();
  await expect(dlg.getByTestId('doc-review-coverage')).toHaveCount(0);
  await expect(dlg).not.toContainText('coverage');
  await check(page, 'booking page review dialog');
  await dlg.getByTestId('doc-licence_front-reject-open').click();
  await dlg.getByTestId('doc-licence_front-reason').fill('The photo is too dark to read');
  await dlg.getByTestId('doc-licence_front-reject').click();
  await expect(dlg.getByTestId('doc-review-msg')).toContainText('rejected', { timeout: 30_000 });
  const [rej] = await sql`select u.status, u.reject_reason, u.reviewed_by,
      (select count(*)::int from booking_events e where e.booking_id = u.booking_id and e.kind = 'verification' and e.details ->> 'reviewer_role' = 'sales' and e.details ->> 'decision' = 'rejected' and e.actor_user_id = ${sales.id}) ev,
      (select count(*)::int from app_events a where a.code = 'renter_identity_rejected' and a.entity_id = u.booking_id) told
    from verification_uploads u where u.booking_id = ${b.booking_id} and u.kind = 'licence_front' and u.status = 'rejected' limit 1`;
  expect([rej!.status, rej!.reject_reason, rej!.reviewed_by, rej!.ev, rej!.told]).toEqual(['rejected', 'The photo is too dark to read', sales.id, 1, 1]);
  await dlg.getByRole('button', { name: 'Close' }).click();

  // the renter sends a new front; /va/verify: Approve all, no coverage
  await giveLicence(sql, b.booking_id);
  await page.goto(`/staff/verify/${b.booking_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('va-licence-only')).toBeVisible({ timeout: 30_000 });
  await expect(page.getByTestId('va-coverage')).toHaveCount(0);
  await expect(page.getByTestId('upload-licence_front')).toBeVisible();
  await check(page, 'verify page for Sales');
  await page.getByTestId('va-approve-all-go').click();
  // nothing is left to approve: the page refreshes and the card (with its message) goes
  await expect(page.getByTestId('va-approve-all')).toHaveCount(0, { timeout: 30_000 });
  const [ok] = await sql`select (select count(*)::int from verification_uploads where booking_id = ${b.booking_id} and status = 'approved' and reviewed_by = ${sales.id}) n,
      (select identity_verified_on is not null from booking_drivers where booking_id = ${b.booking_id} and role = 'renter') v,
      (select count(*)::int from booking_events e where e.booking_id = ${b.booking_id} and e.details ->> 'reviewer_role' = 'sales' and e.details ->> 'decision' = 'approved') ev`;
  expect([ok!.n, ok!.v, ok!.ev]).toEqual([3, true, 3]);

  // the queue no longer lists the booking
  await page.goto('/staff', { waitUntil: 'networkidle' });
  await expect(page.getByTestId(`va-licence-${b.booking_number}`)).toHaveCount(0);
  await check(page, 'Sales queue after the review');
  expect(errors.filter((e) => !/Failed to load resource|favicon|the server responded/.test(e))).toEqual([]);
  await page.context().close();
  await sql.end();
});
