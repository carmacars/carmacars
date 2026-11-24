import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, completeAgreementDetails, db, giveLicence, noOverflow, strongSign, watch } from './helpers';

// Hotfix 3650: booking and paying with card payments paused. The renter approves and signs as before; Sign and pay then
// shows the e-Transfer box (the email, the booking number as the message, the exact rental and deposit) instead of a
// card form, and the screenshot goes to Finance as a Check e-Transfer report; the deposit becomes an e-Transfer
// deposit. An Admin's Money tab says card payments are paused, with the message to copy, and no card way. At 375 and
// 1440, with no horizontal overflow. Card payments are switched off only for the steps that need it, then back on.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...randomBytes(64)]);

async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
}
async function user(sql: Sql, role: 'admin' | 'renter', name: string) {
  const id = randomUUID(); const email = `cardoff.${role}.${Date.now()}.${randomBytes(3).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  if (role === 'renter') { await sql`select public.register_account(${id}, ${email}, ${name}, null)`; return { id, email }; }
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
// an offer sent for a free car far ahead, paid by card (the default)
async function offer(sql: Sql, renter: { id: string; email: string }, admin: string) {
  const ahead = 220 + Math.floor(Math.random() * 300);
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
    renter: { email: renter.email, full_name: 'Casey Cardless', mobile: '+16475550188', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${renter.id}) v`;
  const v = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(v.ok, v.message).toBe(true);
  await sql`select app.send_offer(${v.booking_id}, ${admin}, null, null)`;
  await giveLicence(sql, v.booking_id);
  return v;
}

test('card payments paused: Sign and pay is the e-Transfer box, the screenshot goes to Finance, staff see the note', async ({ page }, info) => {
  test.setTimeout(180_000);
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const admin = await user(sql, 'admin', 'Ada Admin');
  const renter = await user(sql, 'renter', 'Casey Cardless');
  const b = await offer(sql, renter, admin.id);
  const [was] = await sql`select card_payments as cp from program_settings where id = (app.settings()).id`;
  try {
    // approve and sign as with cards on
    await signIn(page, renter.email, `/account/bookings/${b.booking_number}/offer`);
    await page.waitForURL(/\/offer$/);
    await page.getByRole('button', { name: 'Approve and continue' }).click();
    await page.waitForURL(/\/checkout$/, { timeout: 30_000 });
    await completeAgreementDetails(page, { address: '1 Yonge Street', postal: 'M5E 1E5', licence: 'S1234-56789-01234', expiry: '2030-01-31' });
    await expect(page.locator('.agreement')).toContainText('1 Yonge Street', { timeout: 15_000 });
    await page.getByTestId('consents-all').check();
    await strongSign(page);

    // cards paused from here: the payment box is the e-Transfer box, with the exact amounts
    await sql`update program_settings set card_payments = false where id = (app.settings()).id`;
    await page.getByRole('button', { name: /^Sign, then pay/ }).click();
    await page.waitForURL(/\/checkout\?signed=1/, { timeout: 30_000 });
    const box = page.getByTestId('etransfer-pay');
    await expect(box).toBeVisible();
    await expect(page.getByTestId('fake-card')).toHaveCount(0);
    await expect(page.getByTestId('etp-message')).toHaveText(b.booking_number);
    await expect(page.getByTestId('etp-email')).toContainText('@');
    const [due] = await sql`select app.booking_part_open(id, 'rental') + app.booking_part_open(id, 'fees') rental, app.deposit_for_method(b, 'e_transfer') deposit, b.deposit_pay_method
      from bookings b where id = ${b.booking_id}`;
    expect(due!.deposit_pay_method).toBe('e_transfer');
    const money = (c: number) => `$${(Number(c) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    await expect(page.getByTestId('etp-rental')).toHaveText(money(due!.rental));
    await expect(page.getByTestId('etp-deposit')).toHaveText(money(due!.deposit));
    await noOverflow(page);
    await page.screenshot({ path: `test-results/card-off/${info.project.name}-signpay.png`, fullPage: true });

    // the screenshot goes to Finance: a Check e-Transfer report for the rental and the deposit, nothing recorded yet
    await page.getByTestId('etp-file').setInputFiles({ name: 'etransfer.png', mimeType: 'image/png', buffer: PNG });
    await page.getByTestId('etp-send').click();
    await expect(page.getByTestId('etp-waiting')).toBeVisible({ timeout: 20_000 });
    const [rep] = await sql`select status, covers, amount_cents from etransfer_reports where booking_id = ${b.booking_id}`;
    expect(rep).toMatchObject({ status: 'open', covers: 'both' });
    expect(Number(rep!.amount_cents)).toBe(Number(due!.rental) + Number(due!.deposit));

    // an Admin's Money tab: paused, the message to copy, no card way to collect
    await page.context().clearCookies();
    await signIn(page, admin.email, `/admin/bookings/${b.booking_number}?tab=money`);
    await page.waitForURL(/\/admin\/bookings\//, { timeout: 30_000 });
    await expect(page.getByTestId('card-paused-note')).toBeVisible({ timeout: 20_000 });
    await expect(page.getByTestId('card-paused-message')).toContainText(`Message: ${b.booking_number}`);
    await expect(page.getByTestId('etransfer-open')).toBeVisible();
    await noOverflow(page);
  } finally {
    await sql`update program_settings set card_payments = ${was?.cp ?? true} where id = (app.settings()).id`;
    await sql`update bookings set status = 'cancelled' where id = ${b.booking_id} and status in ('pending_payment', 'offered')`.catch(() => undefined);
    await sql.end();
  }
  expect(errors).toEqual([]);
});
