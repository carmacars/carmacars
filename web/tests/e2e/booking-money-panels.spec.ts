import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// The booking's Money tab in two panels (release 29, C0): an Admin collects the deposit alone (cash), then the rental
// alone (e-Transfer). Each leaves the other's balance as it was: the strip (Rental due, Deposit, Total paid), each
// panel's numbers and its own history. Checked at 375 and 1440 with axe and for horizontal overflow; before and after
// screenshots under test-results/booking-money.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');
const money = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const SHOTS = process.env.SHOTS_DIR ?? 'test-results/booking-money';

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  const text = await page.locator('body').innerText();
  expect(text.match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
}

async function mkUser(sql: Sql, role: 'admin' | 'renter') {
  const id = randomUUID(); const email = `bmp.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, 'Riley Renter', null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}

// a confirmed booking far ahead, paid by e-Transfer and the deposit in cash, nothing received yet
async function confirmedUnpaid(sql: Sql, renter: { id: string; email: string }) {
  const ahead = 200 + Math.floor(Math.random() * 300);
  const ymd = (d: Date) => new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Toronto', year: 'numeric', month: '2-digit', day: '2-digit' }).format(d);
  const from = ymd(new Date(Date.now() + ahead * 86_400_000)); const to = ymd(new Date(Date.now() + (ahead + 3) * 86_400_000));
  const [car] = await sql`select v.id from vehicles v join vehicle_listings l on l.vehicle_id = v.id
    where l.status = 'published' and app.vehicle_bookable(v.id) and exists (select 1 from public_vehicle_listings pv where pv.vehicle_id = v.id) and v.partner_id is null and (not v.is_sample or v.sample_bookable) and app.vehicle_on_policy(v.id)
      and app.vehicle_is_available(v.id, ${`${from}T10:00:00-04:00`}::timestamptz - interval '1 day', ${`${to}T10:00:00-04:00`}::timestamptz + interval '1 day', null)
    order by random() limit 1`;
  if (!car) throw new Error('no free car');
  const req = {
    request_key: randomUUID(), vehicle_id: car.id, pickup_at: `${from}T10:00:00-04:00`, return_at: `${to}T10:00:00-04:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' }, coverage_option: 2, extras: {},
    renter: { email: renter.email, full_name: 'Riley Renter', mobile: '+16475550123', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  await sql.begin(async (t) => {
    // the offer and the signing are not this test's: confirmed, to be paid by e-Transfer, a $500 cash deposit
    await t`set local session_replication_role = replica`;
    await t`update bookings set status = 'confirmed', rental_pay_method = 'e_transfer', deposit_pay_method = 'cash', deposit_cents = 50000, card_on_file_id = null where id = ${v.booking_id}`;
  });
  return { id: v.booking_id, number: v.booking_number };
}

test('the Money tab: the deposit alone, then the rental alone, each balance untouched by the other', async ({ page }, info) => {
  test.setTimeout(240_000);
  mkdirSync(SHOTS, { recursive: true });
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await mkUser(sql, 'admin');
  const renter = await mkUser(sql, 'renter');
  const b = await confirmedUnpaid(sql, renter);
  const open = async () => Number((await sql`select app.booking_part_open(${b.id}, 'rental') + app.booking_part_open(${b.id}, 'fees') as o`)[0]!.o);
  const due = await open();
  expect(due).toBeGreaterThan(0);

  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(admin.email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 60_000 });
  await page.goto(`/admin/bookings/${b.number}?tab=money`, { waitUntil: 'networkidle' });

  // before: both open, nothing paid
  await expect(page.getByTestId('bm-strip-rental')).toHaveText(money(due));
  await expect(page.getByTestId('bm-strip-deposit')).toHaveText('Not collected');
  await expect(page.getByTestId('bm-strip-paid')).toHaveText(money(0));
  await expect(page.getByTestId('bm-rental-collect')).toHaveText(`Collect ${money(due)} rental`);
  await expect(page.getByTestId('bm-deposit-collect')).toHaveText(`Collect ${money(50000)} deposit`);
  await check(page, 'money before');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-1-before.png`, fullPage: true });

  // the deposit alone, in cash
  await page.getByTestId('bm-deposit-collect').click();
  await page.getByTestId('bm-dhow-record').check();
  await page.getByTestId('bm-dmethod').selectOption('cash');
  await page.getByTestId('bm-dcollect-go').click();
  await expect(page.getByTestId('bm-message-deposit')).toContainText('Deposit recorded', { timeout: 20_000 });
  await expect(page.getByTestId('bm-strip-deposit')).toHaveText('Charged');
  await expect(page.getByTestId('bm-strip-rental')).toHaveText(money(due));
  await expect(page.getByTestId('bm-rental-due')).toHaveText(money(due));
  await expect(page.getByTestId('bm-strip-paid')).toHaveText(money(50000));
  await expect(page.getByTestId('bm-deposit-history')).toContainText(money(50000));
  await expect(page.getByTestId('bm-rental-history-empty')).toHaveText('No rental payment yet.');
  expect(await open()).toBe(due);

  // the rental alone, by e-Transfer
  await page.getByTestId('bm-rental-collect').click();
  await page.getByTestId('bm-rhow-record').check();
  await expect(page.getByTestId('bm-rcovers')).toHaveValue('balance');
  await page.getByTestId('bm-rmethod').selectOption('e_transfer');
  await page.getByTestId('bm-rref').fill(`CA${tag().toUpperCase()}`);
  await page.getByTestId('bm-rcollect-go').click();
  await expect(page.getByTestId('bm-message-rental')).toContainText('Rental payment recorded', { timeout: 20_000 });
  await expect(page.getByTestId('bm-strip-rental')).toHaveText(money(0));
  await expect(page.getByTestId('bm-rental-paid')).toHaveText(money(due));
  await expect(page.getByTestId('bm-strip-deposit')).toHaveText('Charged');
  await expect(page.getByTestId('bm-deposit')).toHaveText(money(50000));
  await expect(page.getByTestId('bm-strip-paid')).toHaveText(money(due + 50000));
  await expect(page.getByTestId('bm-rental-collect')).toHaveCount(0);
  await expect(page.getByTestId('bm-deposit-collect')).toHaveCount(0);
  expect(await open()).toBe(0);
  const [dep] = await sql`select status, amount_cents from deposits where booking_id = ${b.id}`;
  expect(`${dep!.status}/${dep!.amount_cents}`).toBe('captured/50000');
  await check(page, 'money after');
  await page.screenshot({ path: `${SHOTS}/${info.project.name}-2-after.png`, fullPage: true });
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});
