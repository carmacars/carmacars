import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, completeAgreementDetails, db, giveLicence, noOverflow, strongSign, watch } from './helpers';

// Gift cards (release 49, migration 3600), end to end with the fake payments adapter: a renter buys a gift card on
// /gift-cards (the receipt, the gift email and the staff line queued), and a renter uses a gift card on Sign and pay (the
// balance first, the rest by card: two payments, the booking confirmed). Layout checked at each project's width.
const ADMIN = '00000000-0000-4000-8000-0000000049a1';
const STAFF = '00000000-0000-4000-8000-0000000000c5';
const SHOTS = 'test-results/gift-cards';

function hash(pw: string) { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; }
async function seedRenter(sql: ReturnType<typeof db>, email: string, name: string) {
  const id = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash('correct horse battery')})`;
  await sql`select public.register_account(${id}, ${email}, ${name}, null)`;
  return id;
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill('correct horse battery');
  await page.getByRole('button', { name: 'Sign in' }).click();
}
async function fakeCard(page: Page, prefix: string) {
  await page.locator(`#${prefix}-number`).fill('4242 4242 4242 4242');
  await page.locator(`#${prefix}-exp`).fill('12 / 30');
  await page.locator(`#${prefix}-cvc`).fill('123');
}

test('gift cards: buy one with the card; the receipt, the gift and the staff line are queued', async ({ page }, info) => {
  test.setTimeout(150_000);
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const email = `gift.buyer.${info.project.name}.${Date.now()}@example.test`;
  const to = `gift.to.${info.project.name}.${Date.now()}@example.test`;
  await seedRenter(sql, email, 'Sam Giver');
  await signIn(page, email, '/gift-cards');
  await page.waitForURL(/\/gift-cards/);
  await expect(page.getByTestId('gift-form')).toBeVisible();
  await noOverflow(page);
  await page.screenshot({ path: `${SHOTS}-${info.project.name}-buy.png`, fullPage: true });

  // nothing typed: the fields say what is missing
  await page.getByTestId('gift-continue').click();
  await expect(page.locator('#gc-name-err')).toHaveText('Enter the recipient\'s name.');
  await page.getByTestId('gift-amount-10000').check({ force: true });
  await expect(page.getByTestId('gift-total')).toHaveText('$100.00');
  await page.getByTestId('gift-to-name').fill('Jordan Long-Recipient-Name Lee');
  await page.getByTestId('gift-to-email').fill(to);
  await page.getByTestId('gift-message').fill('Happy birthday. Take a road trip on me.');
  await page.getByTestId('gift-continue').click();
  await expect(page.getByTestId('gift-pay-form')).toBeVisible({ timeout: 20_000 });
  await page.locator('#gc-card-name').fill('Sam Giver');
  await fakeCard(page, 'gc-card');
  await page.getByTestId('gift-pay').click();
  await expect(page.getByTestId('gift-done')).toBeVisible({ timeout: 30_000 });
  await noOverflow(page);
  await page.screenshot({ path: `${SHOTS}-${info.project.name}-done.png`, fullPage: true });

  const [g] = await sql`select id, status, balance_cents::int bal, initial_cents::int amt, view_token from gift_cards where recipient_email = ${to}`;
  expect(g).toMatchObject({ status: 'active', bal: 10000, amt: 10000 });
  const ev = await sql`select code from app_events where entity = 'gift_card' and entity_id = ${g!.id} order by id`;
  expect(ev.map((e) => e.code)).toEqual(['renter_gift_card_receipt', 'staff_gift_card_sold', 'renter_gift_card_delivered']);

  // the printable card opens with its token
  await page.getByTestId('gift-print').click();
  await expect(page.getByTestId('gift-print-page')).toBeVisible();
  await expect(page.getByTestId('gift-card-code')).toHaveText(/^CCGC-[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  await noOverflow(page);
  expect(errors).toEqual([]);
  await sql.end();
});

test('gift cards: Sign and pay uses the balance before the card; the rest is paid by card', async ({ page }, info) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await sql`insert into users (id, email, full_name) values (${ADMIN}, 'e2e.gift.admin@example.test', 'Gift Admin') on conflict do nothing`;
  await sql`insert into user_roles (user_id, role) values (${ADMIN}, 'admin') on conflict do nothing`;
  await sql`insert into users (id, email, full_name) values (${STAFF}, 'e2e.staff@example.test', 'Casey Staff') on conflict do nothing`;
  await sql`insert into user_roles (user_id, role) values (${STAFF}, 'va') on conflict do nothing`;
  await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function) values (${STAFF}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'cs') on conflict do nothing`;
  const slug = info.project.name.startsWith('phone') ? 'kia-forte' : 'hyundai-elantra';
  const [car] = await sql`select vehicle_id from vehicle_listings where slug = ${slug}`;
  // a free window far ahead (no confirmed booking within a day either side)
  let from = '', to = '';
  for (let off = 120; off < 400 && !from; off += 5) {
    const d = new Date(); d.setUTCDate(d.getUTCDate() + off);
    const a = d.toISOString().slice(0, 10); d.setUTCDate(d.getUTCDate() + 3);
    const b = d.toISOString().slice(0, 10);
    const [n] = await sql`select count(*)::int n from bookings where vehicle_id = ${car!.vehicle_id} and status in ('confirmed','on_rent','requested','offered','pending_payment')
      and tstzrange(pickup_at - interval '1 day', return_at + interval '1 day') && tstzrange(${a}::date::timestamptz, ${b}::date::timestamptz + interval '1 day')`;
    if (n!.n === 0) { from = a; to = b; }
  }
  const email = `gift.renter.${info.project.name}.${Date.now()}@example.test`;
  const user = await seedRenter(sql, email, 'Gia Holder');
  const req = {
    request_key: randomUUID(), vehicle_id: car!.vehicle_id, pickup_at: `${from}T10:00:00-05:00`, return_at: `${to}T10:00:00-05:00`, booking_type: 'standard',
    pickup_method: 'collected', return_method: 'returned', pickup_location: { kind: 'our_location' }, return_location: { kind: 'our_location' },
    coverage_option: 3, extras: { winter_tire: false, baby_seats: 0 },
    renter: { email, full_name: 'Gia Holder', mobile: '+16475550177', date_of_birth: '1988-03-14', licence_class: 'G', licence_issuer: 'ON' }, additional_drivers: [],
    consents: { terms: { accepted: true, version: 'e2e', text: 'I agree.' }, privacy: { accepted: true, version: 'e2e', text: 'I agree.' }, marketing: { opted_in: false, version: 'e2e', text: 'No.' } },
    details: { source: 'e2e' }
  };
  const [r] = await sql`select public.submit_booking_request(${sql.json(req)}, '203.0.113.9', 'e2e', ${user}) v`;
  const bk = r!.v as { ok: boolean; booking_id: string; booking_number: string; message?: string };
  expect(bk.ok, bk.message).toBe(true);
  await sql`update bookings set request_details = request_details || '{"source":"e2e"}' where id = ${bk.booking_id}`;
  await sql`select app.send_offer(${bk.booking_id}, ${STAFF}, null, null)`;
  await giveLicence(sql, bk.booking_id);
  // a $50 voucher (a bearer code: no email)
  const [v] = await sql`select app.gift_card_issue(${ADMIN}, '{"type":"amount","amount_cents":5000,"reason":"e2e gift card"}'::jsonb) v`;
  const code = (v!.v as { code: string }).code;

  await signIn(page, email, `/account/bookings/${bk.booking_number}/offer`);
  await page.waitForURL(/\/offer$/);
  await page.getByRole('button', { name: 'Approve and continue' }).click();
  await page.waitForURL(/\/checkout$/, { timeout: 30_000 });
  await completeAgreementDetails(page, { address: '1 Yonge Street', postal: 'M5E 1E5', licence: 'S1234-56789-01234', expiry: '2030-01-31' });
  await expect(page.locator('.agreement')).toContainText('1 Yonge Street', { timeout: 15_000 });
  await page.getByTestId('consents-all').check();
  await strongSign(page);
  await page.getByRole('button', { name: /^Sign, then pay/ }).click();
  await page.waitForURL(/\/checkout\?signed=1/, { timeout: 30_000 });

  // the gift card: add its code (typed in lower case, with spaces) and use it
  await expect(page.getByTestId('gift-pay-box')).toBeVisible();
  await page.getByTestId('gift-code-open').click();
  await page.getByTestId('gift-code').fill(code.toLowerCase().replace(/-/g, ' '));
  await page.getByTestId('gift-code-add').click();
  await expect(page.getByTestId('gift-applied')).toHaveText('−$50.00', { timeout: 20_000 });
  await expect(page.getByTestId('sum-gift')).toBeVisible({ timeout: 20_000 });
  await noOverflow(page);
  await page.screenshot({ path: `${SHOTS}-${info.project.name}-sign-and-pay.png`, fullPage: true });
  const [due] = await sql`select renter_due_at_booking_cents::int due from bookings where id = ${bk.booking_id}`;
  const rest = (due!.due - 5000) / 100;
  await expect(page.getByRole('button', { name: /^Pay \$/ })).toHaveText(`Pay $${rest.toLocaleString('en-CA', { minimumFractionDigits: 2 })}`, { timeout: 20_000 });

  // the rest by card
  await page.locator('#pt-card-name').fill('Gia Holder');
  await fakeCard(page, 'pt-card');
  await page.getByRole('button', { name: /^Pay \$/ }).click();
  await page.waitForURL(/\?paid=1/, { timeout: 45_000 });
  const pays = await sql`select method, amount_cents::int amt from payments where booking_id = ${bk.booking_id} and kind = 'charge' and status = 'succeeded' order by method`;
  expect(pays).toEqual([{ method: 'card', amt: due!.due - 5000 }, { method: 'gift_card', amt: 5000 }]);
  const [st] = await sql`select b.status::text, g.balance_cents::int bal from bookings b, gift_cards g where b.id = ${bk.booking_id} and g.code = ${code}`;
  expect(st).toMatchObject({ status: 'confirmed', bal: 0 });

  // Account > Gift cards: the card, used up, with its history
  await page.goto('/account/gift-cards', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('gift-cards')).toContainText(code.slice(-4));
  await noOverflow(page);
  // tidy: the sample booking would otherwise block this car for later runs
  await sql`update bookings set status = 'cancelled' where id = ${bk.booking_id}`.catch(() => undefined);
  await sql.end();
});
