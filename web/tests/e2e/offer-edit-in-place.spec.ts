import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Release 48, the owner: "When editing an offer, I shouldn't need to withdraw it first", "When you put through an edit, it
// just reverts back", "Send the offer button on the top doesn't even work" and "way too many repetitive buttons". At 375 and
// 1440: the top Send the offer takes you to the one main action and sends; the offer that is out is edited in place (car,
// return date, price, deposit), saved without sending and then sent as an update; after each save a reload shows the saved
// values, never the old ones.
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
}
async function mkUser(sql: Sql, role: 'admin' | 'renter') {
  const id = randomUUID(); const email = `oe.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${'Robin Renter'}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Avery Admin'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
// two cars free around the dates (the second is the one the offer moves to)
async function freeCars(sql: Sql) {
  // weeks ahead, where the sample bookings leave cars free (a random day, so runs side by side do not meet)
  const from = new Date(Date.now() + (40 + Math.floor(Math.random() * 20)) * 86_400_000); const to = new Date(from.getTime() + 2 * 86_400_000);
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and exists (select 1 from public_vehicle_listings p where p.vehicle_id = v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from.toISOString()}::timestamptz - interval '4 days', ${to.toISOString()}::timestamptz + interval '4 days'))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz + interval '4 days' and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
    order by random() limit 2`;
  if (rows.length < 2) throw new Error('two free cars needed');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0]!.id as string, other: rows[1]!.id as string, from: ymd(from), to: ymd(to), later: ymd(new Date(to.getTime() + 86_400_000)) };
}
async function request(sql: Sql, renter: { id: string; email: string }, car: { id: string; from: string; to: string }) {
  const req = {
    request_key: randomUUID(), vehicle_id: car.id, pickup_at: `${car.from}T10:00:00-05:00`, return_at: `${car.to}T10:00:00-05:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 2, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email: renter.email, full_name: 'Robin Renter', mobile: '+16475550188', date_of_birth: '1987-05-02', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  await sql`update bookings set requested_at = now() - interval '2 hours' where id = ${v.booking_id}::uuid`;
  return v;
}
const settled = async (page: Page) => {
  await expect(page.getByTestId('review-updating')).toHaveCount(0, { timeout: 20_000 });
  await expect(page.getByTestId('review-send')).toBeEnabled({ timeout: 20_000 });
};

test('an offer is sent from the top button, edited in place without a withdraw, and keeps its edits after a reload', async ({ page }) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const renter = await mkUser(sql, 'renter');
  const car = await freeCars(sql);
  const r = await request(sql, renter, car);
  const errors = watch(page);

  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 60_000 });

  // 1. the top Send the offer goes to the one main action of the screen, which sends it
  await page.goto(`/admin/bookings/${r.booking_number}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('review-steps')).toHaveCount(0);
  await expect(page.getByTestId('review-send')).toHaveCount(1);
  await expect(page.getByTestId('review-save')).toHaveText('Save without sending');
  await page.getByTestId('next-step-offer').click();
  await expect(page.getByTestId('review-send')).toBeInViewport({ timeout: 15_000 });
  await expect(page.getByTestId('review-send')).toHaveText('Send the offer');
  await check(page, 'review the request');
  await page.getByTestId('review-send').click();
  await expect(page.getByTestId('review-done')).toContainText('Offer sent', { timeout: 30_000 });
  const [b1] = await sql`select status::text s, current_offer_version v from bookings where id = ${r.booking_id}::uuid`;
  expect(`${b1!.s}/${b1!.v}`).toBe('offered/1');

  // 2. edited while out: car, return date, price and deposit; saved without telling the renter
  await page.goto(`/admin/bookings/${r.booking_number}?tab=review`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('review-edit-in-place')).toContainText('No need to withdraw it');
  await expect(page.getByTestId('review-send')).toHaveText('Send the update');
  await expect(page.locator('#rv-vehicle_id option[value="' + car.other + '"]')).toHaveCount(1, { timeout: 15_000 });
  await page.locator('#rv-vehicle_id').selectOption(car.other);
  const ret = page.locator('#rv-return_at');
  await ret.click();
  await ret.fill(`${car.later} 10:00`);
  await ret.press('Tab');
  await page.locator('#rv-rental_charge_cents').fill('321.00');
  await page.locator('#rv-price_reason').fill('Agreed on the phone');
  await page.locator('#rv-deposit_cents').fill('350');
  await expect(page.getByTestId('review-price')).toContainText('Re-priced', { timeout: 15_000 });
  await settled(page);
  await check(page, 'edit the offer');
  await page.getByTestId('review-save').click();
  await expect(page.getByTestId('review-done')).toContainText('the renter was not told', { timeout: 30_000 });
  const [b2] = await sql`select status::text s, current_offer_version v, vehicle_id::text car, rental_charge_cents::int rc, deposit_cents::int dep, total_due_at_booking_cents::int t,
                               to_char(return_at at time zone 'America/Toronto', 'YYYY-MM-DD HH24:MI') ret from bookings where id = ${r.booking_id}::uuid`;
  expect(`${b2!.s}/${b2!.v}/${b2!.car}/${b2!.rc}/${b2!.dep}/${b2!.ret}`).toBe(`offered/2/${car.other}/32100/35000/${car.later} 10:00`);
  // the screen shows what was saved, at once and after a reload
  await expect(page.locator('#rv-deposit_cents')).toHaveValue('350.00');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.locator('#rv-vehicle_id')).toHaveValue(car.other);
  await expect(page.locator('#rv-return_at')).toHaveAttribute('data-value', `${car.later}T10:00`);
  await expect(page.locator('#rv-deposit_cents')).toHaveValue('350.00');
  await expect(page.locator('#rv-rental_charge_cents')).toHaveValue('321.00');
  await expect(page.getByTestId('review-custom-price')).toContainText('$321.00');
  await expect(page.getByTestId('review-total')).toHaveText(new RegExp(`\\$${(Number(b2!.t) / 100).toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',').replace('.', '\\.')}`));
  await expect(page.locator('.ad-diff')).toHaveCount(0);

  // 3. edited again and sent as an update with a message: kept after a reload too
  await page.locator('#rv-deposit_cents').fill('360');
  await page.getByTestId('review-message').fill('The deposit is a little higher for this car.');
  await expect(page.getByTestId('review-price')).toContainText('Re-priced', { timeout: 15_000 });
  await settled(page);
  await page.getByTestId('review-send').click();
  await expect(page.getByTestId('review-done')).toContainText('the renter has the update', { timeout: 30_000 });
  await expect(page.getByTestId('review-revised')).toContainText('Deposit: $350.00 to $360.00');
  await page.reload({ waitUntil: 'networkidle' });
  await expect(page.locator('#rv-deposit_cents')).toHaveValue('360.00');
  await expect(page.getByTestId('review-custom-price')).toContainText('$321.00');
  const [b3] = await sql`select status::text s, current_offer_version v, rental_charge_cents::int rc, deposit_cents::int dep from bookings where id = ${r.booking_id}::uuid`;
  expect(`${b3!.s}/${b3!.v}/${b3!.rc}/${b3!.dep}`).toBe('offered/3/32100/36000');
  // never withdrawn: each edit supersedes the version before
  const [w] = await sql`select string_agg(version || ':' || status, ' ' order by version) s from booking_offers where booking_id = ${r.booking_id}::uuid`;
  expect(w!.s).toBe('1:superseded 2:superseded 3:sent');
  await check(page, 'the offer after the update');
  expect(errors.filter((e) => !/Failed to load resource|favicon|the server responded/.test(e))).toEqual([]);
  await sql.end();
});
