import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// The review request program (docs/changes/2026-10-24-review-requests.md, migration 0138), at 375 and 1440 with axe:
// - the renter's review page by its link (no sign-in): nothing written before they answer, the chips and the sentence
//   make the draft (only what they picked, the booking's car and length), Copy, Post on Google, a low star feel adds
//   "Tell us directly", and "I already left a review" stops the requests;
// - staff: the booking's Review requests card with Ask for a review; a booking with an open charge on the hold list in
//   Admin > Reviews and Send anyway; Admin > Settings > Reviews. Fictional people only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
type Sql = ReturnType<typeof db>;

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function person(sql: Sql, role: 'admin' | 'renter', name: string) {
  const id = randomUUID(); const email = `${role}.rv38.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
  else {
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
    await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  }
  return { id, email };
}
/** A returned booking of this renter: a request through the real function, then written as returned (a fixture). */
async function returnedBooking(sql: Sql, r: { id: string; email: string }, name: string) {
  const day = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
  const start = 400 + Math.floor(Math.random() * 300);
  const [v] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${day(start - 1)}::timestamptz, ${day(start + 4)}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${day(start + 4)}::timestamptz and (k.ends_at is null or k.ends_at > ${day(start - 1)}::timestamptz))
    order by random() limit 1`;
  const req = {
    request_key: randomUUID(), vehicle_id: v!.id, pickup_at: `${day(start)}T10:00:00-04:00`, return_at: `${day(start + 3)}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: {},
    renter: { email: r.email, full_name: name, mobile: '+16475550188', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: true, version: 'e2e', text: 'Yes.' } }, details: { source: 'e2e' }
  };
  const [x] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${r.id}) v`;
  const b = x!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(b.ok, b.message).toBe(true);
  await sql.begin(async (t) => {
    await t`set local session_replication_role = replica`;
    await t`update bookings set status = 'returned', handed_over_at = pickup_at, checked_in_at = return_at where id = ${b.booking_id}`;
  });
  const [{ token, vehicle }] = await sql`select (app.review_request_row(${b.booking_id})).token::text as token, app.vehicle_name(vehicle_id) as vehicle from bookings where id = ${b.booking_id}` as unknown as [{ token: string; vehicle: string }];
  return { ...b, token, vehicle };
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 30_000 });
}

test('the renter’s review page: answers make the draft, Copy and Post on Google, a low star feel, "I already left a review"', async ({ page, context }) => {
  test.setTimeout(120_000);
  const errors = watch(page);
  const sql = db();
  try {
    await context.grantPermissions(['clipboard-read', 'clipboard-write']).catch(() => undefined);
    const r = await person(sql, 'renter', 'Robin Helper');
    const b = await returnedBooking(sql, r, 'Robin Helper');
    const [{ url }] = await sql`select app.google_review_url() as url` as unknown as [{ url: string | null }];
    await page.goto(`/review/${b.token}`, { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('How was your trip, Robin?');
    // nothing is written for the renter before they answer
    await expect(page.getByTestId('review-draft-empty')).toBeVisible();
    await expect(page.getByTestId('review-draft')).toHaveCount(0);
    await axe(page, 'review page');

    await page.getByTestId('chip-car').click();
    await page.getByTestId('chip-cleanliness').click();
    await expect(page.getByTestId('chip-car')).toHaveAttribute('aria-pressed', 'true');
    await page.getByTestId('review-sentence').fill('the pickup took five minutes');
    const draft = page.getByTestId('review-draft');
    await expect(draft).toBeVisible();
    const text = await draft.inputValue();
    expect(text).toContain(b.vehicle);
    expect(text).toContain('3 days');
    expect(text).toMatch(/clean/i);
    expect(text).toContain('The pickup took five minutes.');
    expect(text).not.toMatch(/price|value|communicat|deliver/i);
    // the renter edits it: their text stays
    await draft.fill(`${text} Thanks!`);
    await page.getByTestId('chip-price').click();
    await expect(draft).toHaveValue(`${text} Thanks!`);
    await page.getByTestId('review-copy').click();
    await expect(page.getByTestId('review-copy')).toHaveText(/Copied|Copy/);
    if (url) await expect(page.getByTestId('review-google')).toHaveAttribute('href', url);
    else await expect(page.getByTestId('review-google')).toHaveCount(0);

    // a low star feel: everyone still gets the Google link, and "Tell us directly" appears
    await expect(page.getByTestId('review-direct')).toHaveCount(0);
    await page.locator('label.rh-star').nth(1).click();
    await expect(page.getByTestId('review-direct')).toContainText("Something wasn't right?");
    if (url) await expect(page.getByTestId('review-google')).toBeVisible();
    await axe(page, 'review page with a draft');

    await page.getByTestId('review-already').click();
    await expect(page.getByTestId('review-helper-done')).toContainText('We will not ask you for a review of this trip again.');
    await expect.poll(async () => (await sql`select status, stop_reason, helper_opened_at is not null as opened from review_requests where booking_id = ${b.booking_id}`)[0])
      .toMatchObject({ status: 'stopped', stop_reason: 'renter_said_reviewed', opened: true });
    // the email's "I already left a review" opens the page asking to confirm (opening it changes nothing)
    const b2 = await returnedBooking(sql, r, 'Robin Helper');
    await page.goto(`/review/${b2.token}?done=1`, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('review-confirm-done')).toBeVisible();
    expect((await sql`select status from review_requests where booking_id = ${b2.booking_id}`)[0]!.status).toBe('waiting');
    await page.getByTestId('review-confirm-done').getByTestId('review-already').click();
    await expect(page.getByTestId('review-helper-done')).toBeVisible();
    // a wrong link reads nothing
    await page.goto(`/review/${randomUUID()}`);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('This link does not work');
    expect(errors.filter((e) => !/favicon/.test(e))).toEqual([]);
  } finally { await sql.end(); }
});

test('staff: Ask for a review on the booking, the hold list with Send anyway, Settings > Reviews', async ({ page }) => {
  test.setTimeout(150_000);
  const errors = watch(page);
  const sql = db();
  try {
    const admin = await person(sql, 'admin', 'Avery Admin');
    const r = await person(sql, 'renter', 'Sasha Staffcase');
    const asked = await returnedBooking(sql, r, 'Sasha Staffcase');
    const held = await returnedBooking(sql, r, 'Sasha Staffcase');
    // an open return charge (a cleaning fee not on a statement yet): the request waits on the hold list
    await sql`insert into booking_line_items (booking_id, charge_type, quantity, unit_amount_cents, amount_cents, hst_applies, hst_cents, revenue_class, stage)
              select ${held.booking_id}, code, 1, 15000, 15000, hst_applies, case when hst_applies then 1950 else 0 end, revenue_class, 'check_in' from fee_types where code = 'cleaning'`;
    await sql`select app.review_step(${held.booking_id}, now())`;

    await signIn(page, admin.email, `/admin/bookings/${asked.booking_number}`);
    await page.goto(`/admin/bookings/${asked.booking_number}`, { waitUntil: 'networkidle' });
    const card = page.getByTestId('review-panel');
    await expect(card).toContainText('Review request');
    await expect(card.getByTestId('review-steps')).toContainText('Final follow-up');
    await axe(page, 'booking with the review card');
    await card.getByTestId('review-ask-now').click();
    await page.getByTestId('review-ask-now-submit').click();
    await expect.poll(async () => (await sql`select manual_asks from review_requests where booking_id = ${asked.booking_id}`)[0]?.manual_asks).toBe(1);

    await page.goto('/admin/reviews', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('reviews-dashboard')).toContainText('Average rating');
    const holds = page.getByTestId('review-holds');
    await expect(holds).toContainText(held.booking_number);
    await expect(holds).toContainText('Cleaning $169.50');
    await axe(page, 'reviews dashboard');
    await holds.getByTestId(`hold-send-${held.booking_number}`).click();
    await page.getByTestId(`hold-send-${held.booking_number}-submit`).click();
    await expect.poll(async () => (await sql`select send_anyway_at is not null as released, status from review_requests where booking_id = ${held.booking_id}`)[0]?.released).toBe(true);
    await page.reload();
    await expect(page.getByTestId('review-holds')).not.toContainText(held.booking_number);

    await page.goto('/admin/settings/reviews', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('review-timings')).toBeVisible();
    await expect(page.getByTestId('review-google-status')).toContainText(/Not connected|Connected|failed/);
    await expect(page.getByTestId('review-google-nokeys').or(page.getByTestId('review-google-connect'))).toBeVisible();
    await axe(page, 'settings, reviews');
    expect(errors.filter((e) => !/favicon/.test(e))).toEqual([]);
  } finally {
    await sql.end();
  }
});
