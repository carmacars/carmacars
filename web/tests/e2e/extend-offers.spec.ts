import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
import { PW, seedOwner } from './portal-design-seed';

// The renter's Extend panel (docs/changes/2026-11-07-extend-offers.md), at 375 and 1440: the six offers with their new
// return, price, regular price struck through and saving; an option the car cannot take is disabled with its reason and
// "Available until"; one tap pays with the card on file and the confirmation shows the new return; without a card the tap
// opens the pay page (0482). Axe (no serious or
// critical issue) and no sideways scroll. Fictional people only (example.test).
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`.toUpperCase();

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}

test('renter Extend panel: six offers, the reason of a taken one, one tap to pay, the new return', async ({ page }) => {
  test.setTimeout(180_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const o = await seedOwner(sql);
  const t = tag();
  const id = randomUUID(), email = `renter.ext.${t.toLowerCase()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, 'Robin Example', null)`;
  const [r] = await sql`insert into renters (user_id, legal_name, date_of_birth, mobile, email, identity_status) values (${id}, 'Robin Example', date '1990-05-05', '647-555-0143', ${email}, 'verified')
                        on conflict (user_id) do update set identity_status = 'verified' returning id`;
  await sql`insert into drivers (renter_id, is_account_holder, user_id, full_name, date_of_birth, licence_class, licence_number, licence_expiry)
            values (${r!.id}, true, ${id}, 'Robin Example', '1990-05-05', 'G', ${'E' + t.slice(0, 12)}, date '2031-01-01') on conflict do nothing`;
  const [pm] = await sql`insert into payment_methods (renter_id, card_brand, card_last4, cardholder_name, exp_month, exp_year, is_credit) values (${r!.id}, 'visa', '4242', 'Robin Example', 12, 2031, true) returning id`;
  await sql`insert into payment_method_secrets (payment_method_id, processor_customer_id, processor_method_id) values (${pm!.id}, ${'cus_fake_' + t}, ${'pm_fake_' + t})`;
  const car = o.cars.find((c) => c.status === 'available')!;
  const number = `EX-${t}`.slice(0, 16), next = `EY-${t}`.slice(0, 16);
  // on rent, back in 5 hours; the same car is booked again 4 days later, so the week and the month are taken
  await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
      overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents, handed_over_at, card_on_file_id)
    values (${number}, 'standard', 'on_rent', ${car.id}, ${r!.id}, now() - interval '5 days', now() - interval '2 days', now() + interval '5 hours', now() + interval '5 hours',
      public.calc_billable_days(now() - interval '2 days', now() + interval '5 hours'), 10000, 10000, 56000, 180000, 'daily', 30000, 200, 600, 25, 50000, true, 30000,
      now() - interval '2 days', ${pm!.id})`;
  // the rental is paid (by card), so nothing is unpaid when the card on file is gone below
  await sql`insert into payments (booking_id, renter_id, purpose, kind, method, amount_cents, status, processed_at)
            select id, renter_id, 'booking_total', 'charge', 'card', 30000, 'succeeded', now() from bookings where booking_number = ${number}`;
  await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
      overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents)
    values (${next}, 'standard', 'confirmed', ${car.id}, ${r!.id}, now() - interval '1 day', now() + interval '4 days', now() + interval '6 days', now() + interval '6 days',
      2, 10000, 10000, 56000, 180000, 'daily', 20000, 200, 400, 25, 50000, true, 20000)`;
  try {
    await page.goto(`/sign-in?next=${encodeURIComponent(`/account/bookings/${number}/extend`)}`, { waitUntil: 'networkidle' });
    await acceptCookies(page);
    await page.locator('input[type="email"]').fill(email);
    await page.locator('input[type="password"]').fill(PW);
    await page.getByRole('button', { name: 'Sign in' }).click();
    await page.waitForURL((u) => u.pathname.endsWith('/extend'), { timeout: 60_000 });
    await page.waitForLoadState('networkidle');

    const panel = page.getByTestId('extend-panel');
    for (const code of ['1h', '3h', '1d', '3d', '1w', '1m']) await expect(panel.getByTestId(`extend-opt-${code}`)).toBeVisible();
    // the prices come from the database
    const [x] = await sql`select app.extension_offers(b.id) x from bookings b where b.booking_number = ${number}`;
    const opt = (c: string) => (x!.x.options as Array<Record<string, unknown>>).find((y) => y.code === c)!;
    const dollars = (c: unknown) => `$${(Number(c) / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    await expect(panel.getByTestId('extend-opt-1d')).toContainText(dollars(opt('1d').total_cents));
    await expect(panel.getByTestId('extend-opt-1d').locator('s')).toHaveText(dollars(opt('1d').regular_total_cents));
    await expect(panel.getByTestId('extend-opt-1d')).toContainText('You save 5%');
    await expect(panel.getByTestId('extend-opt-1h')).toContainText('You save 10%');
    // the week runs into the next booking: disabled, with the reason, and how long the car is free
    await expect(panel.getByTestId('extend-opt-1w').locator('input')).toBeDisabled();
    await expect(panel.getByTestId('extend-opt-1w')).toContainText('Booked from');
    await expect(panel.getByTestId('extend-until')).toContainText('Available until');
    await check(page, `extend ${test.info().project.name}`);

    // one tap: 1 day, paid with the card on file; the confirmation shows the new return
    await panel.getByTestId('extend-opt-1d').click();
    await expect(page.getByTestId('extend-pay')).toHaveText(`Pay ${dollars(opt('1d').total_cents)} with Visa ending 4242`);
    await page.getByTestId('extend-pay').click();
    await expect(page.getByTestId('extend-done')).toContainText('Extended');
    const [b] = await sql`select b.return_at, e.status, e.auto_approved, e.option_code from bookings b join booking_extensions e on e.booking_id = b.id where b.booking_number = ${number}`;
    expect(b).toMatchObject({ status: 'confirmed', auto_approved: true, option_code: '1d' });
    await check(page, `extend done ${test.info().project.name}`);

    // no card on file (0482): the same tap opens Stripe's secure pay page for the approved extension
    await sql`update bookings set card_on_file_id = null where booking_number = ${number}`;
    await page.goto(`/account/bookings/${number}/extend`, { waitUntil: 'networkidle' });
    await panel.getByTestId('extend-opt-1h').click();
    const [y] = await sql`select app.extension_offers(b.id) x from bookings b where b.booking_number = ${number}`;
    const h1 = (y!.x.options as Array<Record<string, unknown>>).find((z) => z.code === '1h')!;
    await expect(page.getByTestId('extend-pay')).toHaveText(`Pay ${dollars(h1.total_cents)} by card`);
    await page.getByTestId('extend-pay').click();
    await page.waitForURL((u) => u.pathname.startsWith('/pay/'), { timeout: 60_000 });
    const [q] = await sql`select q.covers, q.status, q.amount_cents, e.total_cents from payment_requests q join booking_extensions e on e.id = q.extension_id
                            join bookings b on b.id = e.booking_id where b.booking_number = ${number} order by q.created_at desc limit 1`;
    expect(q).toMatchObject({ covers: 'extension', status: 'open' });
    expect(Number(q!.amount_cents)).toBe(Number(q!.total_cents));
    expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  } finally {
    await sql`delete from payment_requests where booking_id in (select id from bookings where booking_number in (${number}, ${next}))`.catch(() => undefined);
    await sql`delete from booking_extensions where booking_id in (select id from bookings where booking_number in (${number}, ${next}))`.catch(() => undefined);
    await sql.end();
  }
});
