import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, storeFixtureJpeg } from './helpers';

// Release 48 (migration 2920): a renter on OPCF 27 who sent one page (the endorsement) sees on the booking exactly what
// is missing (the pink slip, not "Under review"), and its button opens the pink slip upload with that page chosen, the
// example picture open beside it, and both examples with the steps on the page. Runs at 375 and 1440.
const PW = 'correct horse battery';
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function signIn(page: Page, email: string, path: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(path), { timeout: 20_000 });
}

test('OPCF 27, one page sent: the checklist names the pink slip and goes straight to its upload, with the example pictures', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const id = randomUUID(); const email = `cx.renter.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, 'Alex Sample', null)`;
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' and (not v.is_sample or v.sample_bookable)
                            and app.vehicle_bookable(v.id) and v.partner_id is null order by random() limit 1`;
  const day = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
  const start = 500 + Math.floor(Math.random() * 300);
  const req = {
    request_key: randomUUID(), vehicle_id: car!.id, pickup_at: `${day(start)}T10:00:00-04:00`, return_at: `${day(start + 3)}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: {},
    renter: { email, full_name: 'Alex Sample', mobile: '+16475550148', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } }, details: { source: 'e2e' }
  };
  const [x] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${id}) v`;
  const b = x!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(b.ok, b.message).toBe(true);
  await sql.begin(async (t) => {
    await t`set local session_replication_role = replica`;
    await t`update bookings set status = 'confirmed', coverage_option = 1 where id = ${b.booking_id}`;
  });
  // the renter sent the OPCF 27 endorsement page only
  const details = { coverage_option: '1', page_kind: 'endorsement', insurer_name: 'Example Insurance Co.', policy_number: 'EX-000-123456', policy_expiry: day(start + 400) };
  // its file is stored too: the booking's Documents tab (crawled after the tests) links every document
  storeFixtureJpeg('documents', `renters/${id}/${b.booking_id}/cx-endorsement.jpg`);
  await sql`select app.register_verification_upload(${b.booking_id}::uuid, ${id}::uuid, 'coverage_proof', null, ${`renters/${id}/${b.booking_id}/cx-endorsement.jpg`},
            ${'c'.repeat(64)}, 'image/jpeg', ${sql.json(details)}, 'documents')`;

  await signIn(page, email, '/account');
  await page.goto(`/account/bookings/${b.booking_number}`, { waitUntil: 'networkidle' });
  // the booking's To do under its steps (StepTracker): the coverage item, still needed, with its button
  const item = page.getByTestId('todo-coverage').first();
  await expect(item).toHaveAttribute('data-tone', 'todo');
  await expect(item).toContainText('pink slip');
  await expect(item).toContainText('We have your OPCF 27 endorsement page');
  const go = item.getByTestId('todo-action');
  await expect(go).toHaveText('Upload the pink slip');
  await expect(go).toHaveAttribute('href', `/account/bookings/${b.booking_number}/verify?need=pink_slip#cov-pink_slip`);
  await noOverflow(page);

  await go.click();
  await page.waitForURL((u) => u.pathname.endsWith('/verify') && u.searchParams.get('need') === 'pink_slip');
  const up = page.locator('#cov-pink_slip');
  await expect(up).toBeVisible();
  await expect(up).toHaveAttribute('data-focus', 'true');
  await expect(up).toContainText('still needed');
  // the example beside the upload is open: the drawn pink slip with its parts listed
  await expect(up.getByTestId('example-open-pink_slip')).toHaveAttribute('open', '');
  await expect(up.locator('svg[data-testid="example-pink-slip"]')).toBeVisible();
  await expect(up).toContainText('The policy number');
  // both examples and the steps (where to find it, how to photograph it) on the page
  const all = page.getByTestId('coverage-examples');
  await expect(all).toHaveAttribute('open', '');
  await expect(all.locator('svg[data-testid="example-endorsement"]')).toBeVisible();
  await expect(page.getByTestId('coverage-howto')).toContainText('All four corners');
  await expect(page.getByTestId('coverage-opcf-missing')).toContainText('pink slip');
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], 'long dash').toBeUndefined();
  await sql.end();
});
