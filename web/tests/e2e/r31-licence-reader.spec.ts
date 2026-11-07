import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { acceptCookies, db, noOverflow } from './helpers';

// Release 31, D2 (migration 0602): the renter's flow of the licence reader. The renter uploads the back of a licence
// from Quebec (a made-up card: fixtures/licence-back-qc.jpg, invented data); the server reads its barcode, the main driver
// becomes an additional driver and the renter sees one plain screen; Add main driver puts a new main driver on the booking
// (their own licence photos next); the car cannot go out until their Ontario licence is read. example.test only.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const BACK = readFileSync(new URL('./fixtures/licence-back-qc.jpg', import.meta.url));
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function mkRenter(sql: Sql) {
  const id = randomUUID(); const email = `renter.lic31.${Date.now()}.${Math.floor(Math.random() * 1e4)}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, 'Riley Renter', null)`;
  return { id, email };
}
async function freeCar(sql: Sql) {
  const from = new Date(Date.now() + 40 * 86_400_000); const to = new Date(from.getTime() + 3 * 86_400_000);
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and exists (select 1 from public_vehicle_listings pv where pv.vehicle_id = v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from.toISOString()}::timestamptz, ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
    order by random() limit 1`;
  if (!rows[0]) throw new Error('no free car');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0].id as string, from: ymd(from), to: ymd(to) };
}
async function seedRequest(sql: Sql, renter: { id: string; email: string }, car: { id: string; from: string; to: string }) {
  const req = {
    request_key: randomUUID(), vehicle_id: car.id, pickup_at: `${car.from}T10:00:00-04:00`, return_at: `${car.to}T10:00:00-04:00`, booking_type: 'standard',
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
async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/account'), { timeout: 20_000 });
}
async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

test('a main driver with a licence from Quebec: the renter adds a main driver and stays as an extra driver', async ({ browser }, info) => {
  test.setTimeout(180_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const renter = await mkRenter(sql);
  const req = await seedRequest(sql, renter, await freeCar(sql));
  const page = await ctx(browser, info.project.name.startsWith('phone'));
  await signIn(page, renter.email);
  await page.goto(`/account/bookings/${req.booking_number}/verify`, { waitUntil: 'networkidle' });

  // the back of the licence: read from its barcode on the server
  const card = page.locator('[data-testid^="upload-licence_back-"]').first();
  await card.getByTestId('upload-pick-licence_back').setInputFiles({ name: 'back.jpg', mimeType: 'image/jpeg', buffer: BACK });
  await expect(page.getByTestId('main-driver-needed')).toBeVisible({ timeout: 30_000 });
  await expect(page.getByTestId('main-driver-needed')).toContainText('The main driver needs an Ontario licence. Add a driver with an Ontario licence as the main driver. You\'ll stay on the booking as an extra driver.');
  const [moved] = await sql`select bd.role, (select source from licence_reads r where r.booking_id = bd.booking_id and r.driver_id = bd.driver_id order by created_at desc limit 1) source,
      (app.booking_readiness(bd.booking_id) ->> 'primary_ontario_needed') needed
    from booking_drivers bd where bd.booking_id = ${req.booking_id}`;
  expect(moved).toMatchObject({ role: 'additional', source: 'barcode', needed: 'true' });
  await check(page, 'main driver needed');

  // Add main driver: the form, an error, then the new main driver
  await page.getByTestId('md-open').click();
  await page.getByTestId('md-save').click();
  await expect(page.getByTestId('md-form')).toContainText('Enter their full name');
  await page.getByTestId('md-full_name').fill('Ona Main');
  await page.getByTestId('md-email').fill(`ona.${Date.now()}@example.test`);
  await page.getByTestId('md-mobile').fill('6475550111');
  await page.getByTestId('md-date_of_birth').fill('1992-02-02');
  await check(page, 'add main driver');
  await page.getByTestId('md-save').click();
  await expect(page.getByTestId('main-driver-needed')).toHaveCount(0, { timeout: 20_000 });
  await expect(page.getByRole('heading', { name: 'Ona Main' })).toBeVisible();
  await expect(page.locator('[data-testid^="upload-licence_front-"]').first()).toBeVisible();
  const drivers = await sql`select full_name, role from booking_drivers where booking_id = ${req.booking_id} order by role desc`;
  expect(drivers.map((d) => `${d.full_name}:${d.role}`)).toEqual(['Ona Main:renter', 'Riley Renter:additional']);
  // still needed until the new main driver's Ontario licence is read
  const [w] = await sql`select app.primary_ontario_needed(${req.booking_id}::uuid) needed`;
  expect(w!.needed).toBe(true);
  await check(page, 'the new main driver');
  await sql.end();
});
