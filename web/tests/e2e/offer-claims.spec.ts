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
  const id = randomUUID(); const email = `ocl.${role}.${Date.now()}.${tag()}@example.test`;
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

// Migration 0177 at 375 and 1440: customer service opens a request (theirs: "You are answering"); an Admin opening it sees
// "Being answered by Val Cs" with the answer buttons off, and takes it over (in the history); customer service, on a fresh
// page, now sees the Admin's claim and the buttons off; the Admin sends; customer service's stale page sends late and is
// told who answered and when. One offer only.
test('two staff on one request: the claim, the takeover and the late send', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const cs = await mkUser(sql, 'va', 'cs');
  const renter = await mkUser(sql, 'renter');
  const r = await request(sql, renter, await freeCar(sql), 60);
  const phone = test.info().project.name.startsWith('phone');

  // customer service opens it first; this page does not look again (a stale screen)
  const b1 = await ctx(browser, phone);
  const errors = watch(b1);
  await signIn(b1, cs.email, '/va');
  await b1.addInitScript(() => { (window as unknown as { __ccClaimPollMs: number }).__ccClaimPollMs = 3_600_000; });
  await b1.goto(`/va/bookings/${r.booking_number}?tab=review`, { waitUntil: 'networkidle' });
  await expect(banner(b1)).toContainText('You are answering this request', { timeout: 30_000 });

  // the Admin sees who is answering it, with the buttons off, and takes it over
  const a = await ctx(browser, phone);
  await signIn(a, admin.email, '/admin');
  await a.goto(`/admin/bookings/${r.booking_number}?tab=review`, { waitUntil: 'networkidle' });
  await expect(banner(a)).toContainText('Being answered by Val Cs since', { timeout: 30_000 });
  await expect(gate(a)).toHaveAttribute('data-locked', 'true');
  await check(a, 'Admin booking page, claimed by customer service');
  await a.getByTestId('request-takeover').click();
  await expect(banner(a)).toContainText('You are answering this request', { timeout: 30_000 });
  await expect(gate(a)).toHaveAttribute('data-locked', 'false');
  const [ev] = await sql`select count(*)::int n from booking_events where booking_id = ${r.booking_id}::uuid and kind = 'claim_taken_over' and actor_user_id = ${admin.id}::uuid and note = 'Taken over from Val Cs (by an Admin)'`;
  expect(ev!.n).toBe(1);

  // customer service on a fresh page: the Admin's claim, the buttons off, and the list says who
  const b2 = await b1.context().newPage();
  await b2.goto(`/va/bookings/${r.booking_number}?tab=review`, { waitUntil: 'networkidle' });
  await expect(banner(b2)).toContainText('Being answered by Ada Admin since', { timeout: 30_000 });
  await expect(gate(b2)).toHaveAttribute('data-locked', 'true');
  await expect(b2.getByTestId('request-takeover')).toHaveCount(0);
  await check(b2, 'VA booking page, claimed by the Admin');
  await b2.goto('/va/requests', { waitUntil: 'networkidle' });
  await expect(b2.getByTestId(`claim-${r.booking_number}`)).toContainText('Being answered by Ada Admin', { timeout: 30_000 });
  await check(b2, 'VA requests list with the claim');
  await b2.close();

  // the Admin sends the offer
  await a.getByTestId('review-send').click();
  await expect(a.getByText('Offer sent.')).toBeVisible({ timeout: 30_000 });

  // customer service's stale page sends late: refused, with who answered and when
  await b1.getByTestId('choice-for_carmacars').check();
  await b1.getByTestId('review-send').click();
  await expect(b1.getByRole('alert').filter({ hasText: 'Already answered' })).toContainText(/Already answered by Ada Admin at .+: open the offer to see it\./, { timeout: 30_000 });
  const [n] = await sql`select count(*)::int n, min(sent_by::text) by from booking_offers where booking_id = ${r.booking_id}::uuid`;
  expect([n!.n, n!.by]).toEqual([1, admin.id]);
  expect(errors.filter((e) => !/Failed to load resource|favicon|the server responded/.test(e))).toEqual([]);
  await a.context().close(); await b1.context().close();
  await sql.end();
});

// Sales wait for customer service first: "Opens to you at" on the list, the buttons off on the booking; customer service
// takes it; their claim runs out after the wait and Sales opening it take it over (in the history).
test('Sales wait for customer service first; a claim that ran out is taken over', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const cs = await mkUser(sql, 'va', 'cs');
  const sales = await mkUser(sql, 'va', 'sales');
  const renter = await mkUser(sql, 'renter');
  const r = await request(sql, renter, await freeCar(sql), 0);
  const phone = test.info().project.name.startsWith('phone');

  const s = await ctx(browser, phone);
  const errors = watch(s);
  await signIn(s, sales.email, '/va');
  await s.goto('/va/requests', { waitUntil: 'networkidle' });
  await expect(s.getByTestId(`claim-${r.booking_number}`)).toContainText(/Opens to you at \d{1,2}:\d{2} [ap]m/, { timeout: 30_000 });
  await check(s, 'Sales requests list, a request not open to them yet');
  await s.goto(`/va/bookings/${r.booking_number}?tab=review`, { waitUntil: 'networkidle' });
  await expect(banner(s)).toContainText(/Open to Sales at .+ if nobody answers\. Customer service answers it first\./, { timeout: 30_000 });
  await expect(gate(s)).toHaveAttribute('data-locked', 'true');
  await check(s, 'Sales booking page during the wait');

  const c = await ctx(browser, phone);
  await signIn(c, cs.email, '/va');
  await c.goto(`/va/bookings/${r.booking_number}?tab=review`, { waitUntil: 'networkidle' });
  await expect(banner(c)).toContainText('You are answering this request', { timeout: 30_000 });
  await c.context().close();

  // the wait is over and customer service's claim ran out: Sales opening it take it
  await sql`update bookings set requested_at = now() - interval '20 minutes' where id = ${r.booking_id}::uuid`;
  await sql`update request_claims set expires_at = now() - interval '1 minute' where booking_id = ${r.booking_id}::uuid`;
  await s.reload({ waitUntil: 'networkidle' });
  await expect(banner(s)).toContainText('You are answering this request', { timeout: 30_000 });
  await expect(gate(s)).toHaveAttribute('data-locked', 'false');
  const [ev] = await sql`select count(*)::int n from booking_events where booking_id = ${r.booking_id}::uuid and kind = 'claim_taken_over' and actor_user_id = ${sales.id}::uuid and note like 'Taken over from Val Cs (their claim had run out at %)'`;
  expect(ev!.n).toBe(1);
  await check(s, 'Sales booking page, theirs after the wait');
  expect(errors.filter((e) => !/Failed to load resource|favicon|the server responded/.test(e))).toEqual([]);
  await s.context().close();
  await sql.end();
});
