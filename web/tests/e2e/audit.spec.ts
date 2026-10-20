import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// What the handover audit added (migration 0034, docs/audit/2026-10-13-audit.md): the renter's review of a closed
// booking (the review request email's link) and the unsubscribe link of the marketing emails, at 375 and 1440.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
type Sql = ReturnType<typeof db>;

async function axe(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}`)).toEqual([]);
}
async function renter(sql: Sql, tag: string) {
  const id = randomUUID(); const email = `audit.${tag}.${Date.now()}.${Math.floor(Math.random() * 1e4)}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, 'Robin Review', null)`;
  return { id, email };
}
/** A closed booking of this renter: a request through the real function, then written as closed (a fixture). */
async function closedBooking(sql: Sql, r: { id: string; email: string }) {
  const [v] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' and (not v.is_sample or v.sample_bookable) order by random() limit 1`;
  const day = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
  const start = 300 + Math.floor(Math.random() * 400);
  const req = {
    request_key: randomUUID(), vehicle_id: v!.id, pickup_at: `${day(start)}T10:00:00-04:00`, return_at: `${day(start + 2)}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: {},
    renter: { email: r.email, full_name: 'Robin Review', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: true, version: 'e2e', text: 'Yes.' } }, details: { source: 'e2e' }
  };
  const [x] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${r.id}) v`;
  const b = x!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(b.ok, b.message).toBe(true);
  await sql.begin(async (t) => {
    await t`set local session_replication_role = replica`;
    await t`update bookings set status = 'closed' where id = ${b.booking_id}`;
  });
  return b;
}
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/account'), { timeout: 20_000 });
}

test('audit: a renter reviews a closed booking from the booking page, with the consent to publish', async ({ page }) => {
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const r = await renter(sql, 'review');
  const b = await closedBooking(sql, r);
  const errors = watch(page);
  await signIn(page, r.email);
  await page.goto(`/account/bookings/${b.booking_number}`);
  await page.getByTestId('review-link').click();
  await expect(page).toHaveURL(new RegExp(`/account/bookings/${b.booking_number}/review$`));
  await axe(page, 'review form');
  await page.getByRole('button', { name: 'Send my review' }).click();
  await expect(page.getByText('Choose from 1 to 5 stars.')).toBeVisible();
  await page.locator('label.pt-star').nth(3).click();
  await page.locator('#pt-review-title').fill('Spotless and on time');
  await page.locator('#pt-review-body').fill('Pickup took five minutes and the car was clean.');
  await page.getByRole('button', { name: 'Send my review' }).click();
  // the action refreshes the page: the thank-you, or at once the review as left
  await expect(page.getByTestId('review-thanks').or(page.getByTestId('review-left'))).toBeVisible();
  const [rv] = await sql`select rating, title, status, publish_consent_at is not null as consent from reviews where booking_id = ${b.booking_id}`;
  expect(rv).toMatchObject({ rating: 4, title: 'Spotless and on time', status: 'pending', consent: true });
  await page.reload();
  await expect(page.getByTestId('review-left')).toContainText('With our team');
  await axe(page, 'review left');
  expect(errors.filter((e) => !/favicon/.test(e))).toEqual([]);
  await sql.end();
});

test('audit: the unsubscribe link asks first, then stops marketing; the old path still works', async ({ page }) => {
  const sql = db();
  const r = await renter(sql, 'unsub');
  const token = randomUUID();
  await sql`insert into notification_outbox (code, category, priority, audience, dedupe_key, to_address, recipient_user_id, unsubscribe_token, status, status_reason)
            values ('renter_comeback_1w', 'marketing', 5, 'renter', ${'e2e-unsub:' + token}, ${r.email}, ${r.id}, ${token}, 'suppressed', 'e2e fixture')`;
  await page.goto(`/email/unsubscribe?token=${token}`);
  await expect(page).toHaveURL(new RegExp(`/unsubscribe\\?token=${token}`));
  await acceptCookies(page);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Unsubscribe from offers');
  expect((await sql`select count(*)::int n from email_suppressions where email = ${r.email}`)[0]!.n).toBe(0);
  await axe(page, 'unsubscribe');
  await page.getByRole('button', { name: 'Unsubscribe' }).click();
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('You are unsubscribed');
  const [u] = await sql`select marketing_opt_in, marketing_unsubscribed_at is not null as at from users where id = ${r.id}`;
  expect(u).toMatchObject({ marketing_opt_in: false, at: true });
  expect((await sql`select count(*)::int n from email_suppressions where email = ${r.email} and scope = 'marketing' and lifted_at is null`)[0]!.n).toBe(1);
  await sql.end();
});
