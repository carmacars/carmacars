import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

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
  const id = randomUUID(); const email = `sro.${role}.${Date.now()}.${tag()}@example.test`;
  const name = { admin: 'Ada Admin', va: va === 'sales' ? 'Sam Sales' : 'Val Cs', renter: 'Riley Renter' }[role];
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
  const from = new Date(Date.now() + 30 * 3600_000); const to = new Date(from.getTime() + 2 * 86_400_000);
  const rows = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      and not exists (select 1 from bookings b where b.vehicle_id = v.id and b.status in ('requested','offered','pending_payment','confirmed','on_rent','returned','closed')
                        and tstzrange(b.pickup_at - interval '1 day', b.return_at + interval '1 day') && tstzrange(${from.toISOString()}::timestamptz - interval '4 days', ${to.toISOString()}::timestamptz))
      and not exists (select 1 from vehicle_calendar_blocks k where k.vehicle_id = v.id and k.removed_at is null and k.starts_at < ${to.toISOString()}::timestamptz and (k.ends_at is null or k.ends_at > ${from.toISOString()}::timestamptz))
    order by random() limit 1`;
  if (!rows[0]) throw new Error('no free car');
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  return { id: rows[0].id as string, from: ymd(from), to: ymd(to) };
}
// a request from the website, waiting for its first answer
async function request(sql: Sql, renter: { id: string; email: string }, car: { id: string; from: string; to: string }, minutesAgo: number) {
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
  await sql`update bookings set requested_at = now() - make_interval(mins => ${minutesAgo}) where id = ${v.booking_id}::uuid`;
  return v;
}
const banner = (p: Page) => p.getByTestId('request-claim');
const gate = (p: Page) => p.getByTestId('claim-gate-review');
const why = (p: Page) => p.getByTestId('claim-gate-review-why');

// 2026-10-28, the owner: an in-person Sales person opening a website request "is unable to click any buttons at all", cannot
// see the renter's phone or email to call them, and cannot send an offer. At 375 and 1440: an in-person Sales assistant with a
// $0 single limit sees the renter's phone (tel:) and email (mailto:) on the request; during the Sales wait the buttons are off
// and say why and when they come on; they come on by themselves at that time, the first touch takes the request, and the
// offer at the rate sheet price goes out.
test('in-person Sales: the renter contact, the wait explained, and the offer sent when it opens', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const sales = await mkUser(sql, 'va', 'sales');
  const [sp] = await sql`select sales_work_mode, single_limit_cents::int lim from staff_profiles where user_id = ${sales.id}::uuid`;
  expect([sp!.sales_work_mode, sp!.lim]).toEqual(['in_person', 0]);
  const renter = await mkUser(sql, 'renter');
  const r = await request(sql, renter, await freeCar(sql), 0);
  // the wait ends in under a minute
  await sql`update bookings set requested_at = now() - (select make_interval(mins => request_sales_after_minutes) from program_settings limit 1) + interval '40 seconds' where id = ${r.booking_id}::uuid`;
  const phone = test.info().project.name.startsWith('phone');

  const s = await ctx(browser, phone);
  const errors = watch(s);
  await signIn(s, sales.email, '/staff');
  await s.goto(`/staff/bookings/${r.booking_number}`, { waitUntil: 'networkidle' });
  await expect(s.getByTestId('request-renter-phone')).toHaveAttribute('href', 'tel:+16475550123');
  await expect(s.getByTestId('request-renter-phone')).toHaveText('+16475550123');
  await expect(s.getByTestId('request-renter-email')).toHaveAttribute('href', `mailto:${renter.email}`);
  await expect(gate(s)).toHaveAttribute('data-locked', 'true', { timeout: 30_000 });
  await expect(why(s)).toContainText(/goes to customer service first\. It opens to you at \d{1,2}:\d{2} [ap]m if nobody has answered it: the buttons come on by themselves then\./);
  await check(s, 'Sales booking page during the wait');

  // it opens by itself, no reload; the first touch takes it
  await expect(gate(s)).toHaveAttribute('data-locked', 'false', { timeout: 90_000 });
  await expect(why(s)).toHaveCount(0);
  await s.locator('#rv-msg').fill('Your car is ready for those dates.');
  await expect(banner(s)).toContainText('You are answering this request', { timeout: 30_000 });
  await s.getByTestId('choice-for_carmacars').check();
  await s.getByTestId('review-send').click();
  await expect(s.getByText('Offer sent.')).toBeVisible({ timeout: 30_000 });
  const [o] = await sql`select count(*)::int n, min(sent_by::text) by from booking_offers where booking_id = ${r.booking_id}::uuid`;
  expect([o!.n, o!.by]).toEqual([1, sales.id]);
  const [b] = await sql`select status::text, custom_price_reason from bookings where id = ${r.booking_id}::uuid`;
  expect([b!.status, b!.custom_price_reason]).toEqual(['offered', null]);
  expect(errors.filter((e) => !/Failed to load resource|favicon|the server responded/.test(e))).toEqual([]);
  await s.context().close();
  await sql.end();
});

// An Admin opened the request (and left it idle): Sales see who holds it, until when, and to ask an Admin if it cannot wait;
// when the Admin's claim runs out the buttons come on by themselves and Sales send the offer.
test('in-person Sales: an Admin holds the request; it opens when their claim runs out', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const sales = await mkUser(sql, 'va', 'sales');
  const renter = await mkUser(sql, 'renter');
  const r = await request(sql, renter, await freeCar(sql), 60);
  await sql`select app.door(${admin.id}::uuid, 'aal2', 'admin_do', 'request_claim', ${sql.json({ booking: r.booking_id, mode: 'claim' })})`;
  await sql`update request_claims set expires_at = now() + interval '45 seconds' where booking_id = ${r.booking_id}::uuid`;
  const phone = test.info().project.name.startsWith('phone');

  const s = await ctx(browser, phone);
  const errors = watch(s);
  await signIn(s, sales.email, '/staff');
  await s.goto(`/staff/bookings/${r.booking_number}?tab=review`, { waitUntil: 'networkidle' });
  await expect(gate(s)).toHaveAttribute('data-locked', 'true', { timeout: 30_000 });
  await expect(why(s)).toContainText(/^The answer buttons are off for now[\s\S]*Ada Admin is answering this request\. Their claim runs out at \d{1,2}:\d{2} [ap]m unless they keep working on it.+ask an Admin to take it over\./);
  await expect(banner(s)).toContainText('Being answered by Ada Admin since');
  await check(s, 'Sales booking page, held by an Admin');

  await expect(gate(s)).toHaveAttribute('data-locked', 'false', { timeout: 90_000 });
  await s.locator('#rv-msg').click();
  await expect(banner(s)).toContainText('You are answering this request', { timeout: 30_000 });
  await s.getByTestId('choice-for_carmacars').check();
  await s.getByTestId('review-send').click();
  await expect(s.getByText('Offer sent.')).toBeVisible({ timeout: 30_000 });
  const [o] = await sql`select count(*)::int n, min(sent_by::text) by from booking_offers where booking_id = ${r.booking_id}::uuid`;
  expect([o!.n, o!.by]).toEqual([1, sales.id]);
  const [ev] = await sql`select count(*)::int n from booking_events where booking_id = ${r.booking_id}::uuid and kind = 'claim_taken_over' and actor_user_id = ${sales.id}::uuid`;
  expect(ev!.n).toBe(1);
  expect(errors.filter((e) => !/Failed to load resource|favicon|the server responded/.test(e))).toEqual([]);
  await s.context().close();
  await sql.end();
});
