import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migrations 0070 and 0071 end to end: an Admin publishes a car that has only the basics (no rates, no listing details,
// no photos, its onboarding open) with Publish now, its open items listed with the fleet policy as a handover item, and
// the car is on the site; a renter with coverage option 2 who paid with a credit card in their name ticks the card's
// coverage, which then waits for staff.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
type Sql = ReturnType<typeof db>;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}
async function account(sql: Sql, role: 'admin' | 'renter', name: string) {
  const id = randomUUID(); const email = `lc.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'admin') {
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
    await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  } else {
    await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
  }
  return { id, email };
}
async function signIn(page: Page, email: string, path: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(path), { timeout: 20_000 });
}

test('an Admin publishes a car with only the basics; its paperwork and the fleet policy are open items, not blockers', async ({ page }) => {
  test.skip((test.info().project.use.viewport?.width ?? 1440) < 600, 'one width: the car goes on the shared fleet');
  test.setTimeout(120_000);
  const sql = db();
  const admin = await account(sql, 'admin', 'Lee Lister');
  const [o] = await sql`select id from owners where kind = 'program' and email <> 'sample.owner@example.test' order by created_at limit 1`;
  const vid = randomUUID(); const model = `Forte ${tag().toUpperCase()}`;
  await sql`insert into vehicles (id, owner_id, year, make, model, vin, plate, class, status, management_mode, onboarding_method, on_fleet_policy)
            values (${vid}, ${o!.id}, 2021, 'Kia', ${model}, ${('LC' + randomBytes(8).toString('hex').toUpperCase()).slice(0, 17)}, ${'LC' + tag().toUpperCase()},
                    'standard', 'onboarding', 'managed', 'transfer', false)`;
  await signIn(page, admin.email, '/admin');
  await page.goto(`/admin/vehicles/${vid}?tab=listing`, { waitUntil: 'networkidle' });
  const items = page.getByTestId('listing-warnings');
  await expect(items).toContainText('Before the first handover');
  await expect(items).toContainText('Not on the fleet insurance policy yet');
  await expect(page.getByTestId('listing-default-rates')).toBeVisible();
  await check(page, 'car page, open items');
  await page.getByTestId('vehicle-publish').click();
  await expect.poll(async () => (await sql`select status from vehicle_listings where vehicle_id = ${vid}`)[0]?.status, { timeout: 20_000 }).toBe('published');
  const [l] = await sql`select l.slug, (select count(*)::int from rate_cards r where r.vehicle_id = l.vehicle_id and r.effective_to is null) rates from vehicle_listings l where l.vehicle_id = ${vid}`;
  expect(l!.rates).toBe(1);
  const pub = await page.request.get(`/cars/${l!.slug}`);
  expect(pub.status()).toBe(200);
  expect(await pub.text()).toContain(`Kia ${model}`);
  // the car stays in onboarding: listed and bookable, released only once on the fleet policy
  const [v] = await sql`select status::text s from vehicles where id = ${vid}`;
  expect(v!.s).toBe('onboarding');
  // off the shared fleet again for the other specs
  await sql`update vehicle_listings set status = 'unpublished', unpublished_at = now(), unpublished_reason = 'e2e' where vehicle_id = ${vid}`;
  await sql.end();
});

test('coverage option 2: the renter who paid with a credit card in their name confirms its coverage; staff check it before the handover', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const r = await account(sql, 'renter', 'Casey Card');
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id where l.status = 'published' and (not v.is_sample or v.sample_bookable)
                            and app.vehicle_bookable(v.id) order by random() limit 1`;
  const day = (n: number) => new Date(Date.now() + n * 86_400_000).toISOString().slice(0, 10);
  const start = 500 + Math.floor(Math.random() * 300);
  const req = {
    request_key: randomUUID(), vehicle_id: car!.id, pickup_at: `${day(start)}T10:00:00-04:00`, return_at: `${day(start + 3)}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: {},
    renter: { email: r.email, full_name: 'Casey Card', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } }, details: { source: 'e2e' }
  };
  const [x] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${r.id}) v`;
  const b = x!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(b.ok, b.message).toBe(true);
  await sql.begin(async (t) => {
    await t`set local session_replication_role = replica`;
    await t`update bookings set status = 'confirmed', coverage_option = 2 where id = ${b.booking_id}`;
  });
  // paid with a credit card in the renter's name (the Card on File the payment saves)
  const [pm] = await sql`insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit, funding)
                         select b.renter_id, 'visa', '4242', r.legal_name, 12, 2031, true, 'credit' from bookings b join renters r on r.id = b.renter_id where b.id = ${b.booking_id} returning id`;
  await sql`update bookings set card_on_file_id = ${pm!.id} where id = ${b.booking_id}`;

  await signIn(page, r.email, '/account');
  await page.goto(`/account/bookings/${b.booking_number}/verify`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('coverage-card')).toContainText('ending 4242');
  await check(page, 'coverage option 2');
  await expect(page.getByTestId('coverage-card-confirm')).toBeDisabled();
  await page.getByTestId('coverage-card-tick').check();
  await page.getByTestId('coverage-card-confirm').click();
  await expect(page.getByTestId('coverage-card-confirmed')).toBeVisible({ timeout: 20_000 });
  const [cp] = await sql`select status, card_funding, renter_confirmed_at is not null c from coverage_proofs where booking_id = ${b.booking_id} and coverage_option = 2 order by created_at desc limit 1`;
  expect(cp).toMatchObject({ status: 'submitted', card_funding: 'credit', c: true });
  // the handover still waits for staff
  const [bk] = await sql`select coverage_confirmed_at is null w from bookings where id = ${b.booking_id}`;
  expect(bk!.w).toBe(true);
  await sql.end();
});
