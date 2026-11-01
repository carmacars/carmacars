import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
import { PW, seedInvestor, seedOwner } from './portal-design-seed';

// The customer portals' revamp (docs/changes/2026-11-06-portals-revamp.md), at 375 and 1440: each portal's menu (four
// or five links, one current), its home with what to do now first, each merged page and each tab with axe (no serious or
// critical issue) and no sideways scroll, every old address redirecting to its tab with its query, and amounts that never
// wrap. Fictional people only (example.test).
const LOCK = 780083; // the deck switch is global (investor-deck.spec.ts and owner-investor-portal-design.spec.ts take the same lock)
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => `${Date.now().toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`.toUpperCase();

async function check(page: Page, where: string) {
  await noOverflow(page);
  const wide = await page.evaluate(() => [...document.querySelectorAll('main *')].filter((e) => e.getBoundingClientRect().right > innerWidth + 1 && !e.closest('.table-scroll, .agreement, .ptabs__row, .dk-bleed')).slice(0, 5).map((e) => `${e.tagName}.${e.className}`));
  expect(wide, `${where}: elements wider than the screen`).toEqual([]);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  // amounts never wrap: every figure is one line
  const wrapped = await page.evaluate(() => [...document.querySelectorAll('.pu-stat__value, .now__v, .pu-doc__amount, .pu-tl__amount, .rp__amt')]
    .filter((e) => /\$\d/.test(e.textContent ?? '') && e.getBoundingClientRect().height > parseFloat(getComputedStyle(e).lineHeight || '0') * 1.6 + 2).map((e) => e.textContent));
  expect(wrapped, `${where}: amounts on two lines`).toEqual([]);
  // the menu's tap targets
  const small = await page.evaluate(() => [...document.querySelectorAll('.pm a, .ptabs__row a')].filter((a) => a.getBoundingClientRect().height < 40).map((a) => a.textContent));
  expect(small, `${where}: small tap targets`).toEqual([]);
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' }).catch(() => page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' }));
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next), { timeout: 60_000 });
  await page.waitForLoadState('networkidle');
}
async function menu(page: Page, testId: string, labels: string[], current: string) {
  const nav = page.getByTestId(testId);
  await expect(nav.getByRole('link')).toHaveText(labels.map((l) => new RegExp(`^${l}`)));
  await expect(nav.locator('a[aria-current="page"]')).toHaveText(new RegExp(`^${current}`));
}
async function moved(page: Page, from: string, to: RegExp) {
  await page.goto(from, { waitUntil: 'networkidle' });
  await expect(page, `${from} redirects`).toHaveURL(to);
}

test('renter portal: Trips opens on what to do now, Account has two tabs, old addresses redirect', async ({ page }) => {
  test.setTimeout(180_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const o = await seedOwner(sql);
  const t = tag();
  const id = randomUUID(), email = `renter.rv.${t.toLowerCase()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, 'Riley Example', null)`;
  const [r] = await sql`insert into renters (user_id, legal_name, date_of_birth, mobile, email, identity_status) values (${id}, 'Riley Example', date '1990-05-05', '647-555-0142', ${email}, 'verified')
                        on conflict (user_id) do update set identity_status = 'verified' returning id`;
  const car = o.cars.find((c) => c.status === 'available')!;
  const number = `RV-${t}`.slice(0, 16);
  await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, pickup_at, return_at, original_return_at, billable_days,
      daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
      overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents, handed_over_at)
    values (${number}, 'standard', 'on_rent', ${car.id}, ${r!.id}, now() - interval '5 days', now() - interval '2 days', now() + interval '5 hours', now() + interval '5 hours',
      public.calc_billable_days(now() - interval '2 days', now() + interval '5 hours'), 10000, 12000, 56000, 180000, 'daily', 30000, 200, 600, 25, 50000, true, 30000, now() - interval '2 days')`;
  try {
    await signIn(page, email, '/account');
    await menu(page, 'renter-nav', ['Trips', 'Documents', 'Rewards', 'Account'], 'Trips');
    // what to do now, first: return the car, when, with Extend and Message us
    const now = page.getByTestId('next-step');
    await expect(now).toContainText(/Return the \d{4} Mercedes-Benz GLC300 (today|tomorrow) at \d{1,2}:\d\d [ap]\.m\./);
    await expect(now.getByTestId('now-extend')).toHaveAttribute('href', `/account/bookings/${number}/extend`);
    await expect(now.getByTestId('now-message')).toBeVisible();
    const box = await now.boundingBox();
    const hero = await page.locator('.pu-ph, [data-testid="booking-number"]').first().boundingBox();
    if (box && hero) expect(box.y).toBeLessThan(hero.y);
    await check(page, 'renter home');
    // Account: Profile and Notifications tabs
    await page.getByTestId('renter-nav').getByRole('link', { name: /^Account/ }).click();
    await page.waitForURL(/\/account\/profile$/);
    await expect(page.getByTestId('portal-tabs').locator('a[aria-current="page"]')).toHaveText('Profile');
    await check(page, 'renter account profile');
    await page.getByTestId('tab-notifications').click();
    await page.waitForURL(/tab=notifications/);
    await expect(page.locator('#pt-prefs')).toHaveText('Email preferences');
    await check(page, 'renter account notifications');
    await moved(page, '/account/notifications?x=1', /\/account\/profile\?tab=notifications&x=1$/);
    await moved(page, '/account/bookings?welcome=1', /\/account\?welcome=1$/);
    for (const p of ['/account/documents', '/account/rewards']) { await page.goto(p, { waitUntil: 'networkidle' }); await check(page, p); }
    expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  } finally {
    await sql`delete from bookings where booking_number = ${number}`.catch(() => {});
    await sql.end();
  }
});

test('owner portal: five links, home with earned, cars out, next payout first, Cars, Money and Account tabs', async ({ page }) => {
  test.setTimeout(240_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const errors = watch(page);
  const o = await seedOwner(sql);
  await signIn(page, o.email, '/owner');
  await menu(page, 'owner-nav', ['Home', 'Cars', 'Money', 'Documents', 'Account'], 'Home');
  await expect(page.getByTestId('owner-now')).toHaveText(/^\d of 3 cars out right now\.$/);
  await expect(page.getByTestId('owner-next-payout')).toHaveText('$6,554.00');
  await expect(page.getByTestId('owner-hero').locator('img')).not.toHaveCount(0);
  await check(page, 'owner home');
  for (const [path, tab, menuAt, id] of [
    ['/owner/vehicles', 'Your cars', 'Cars', 'owner-vehicle'], ['/owner/vehicles?tab=bookings', 'Bookings', 'Cars', 'owner-coming-up'],
    ['/owner/money', 'Statements', 'Money', 'owner-mtd'], ['/owner/money?tab=payouts', 'Payouts', 'Money', 'owner-payouts'], ['/owner/money?tab=invoices', 'Invoices', 'Money', 'invoice-rows'],
    ['/owner/account', 'Profile', 'Account', null], ['/owner/account?tab=banking', 'Banking', 'Account', 'owner-auto-debit'], ['/owner/account?tab=notifications', 'Notifications', 'Account', null]
  ] as const) {
    await page.goto(path, { waitUntil: 'networkidle' });
    await expect(page.getByTestId('portal-tabs').locator('a[aria-current="page"]'), path).toHaveText(new RegExp(`^${tab}`));
    await expect(page.getByTestId('owner-nav').locator('a[aria-current="page"]')).toHaveText(new RegExp(`^${menuAt}`));
    if (id) await expect(page.getByTestId(id).first()).toBeVisible();
    await check(page, path);
  }
  // the email preferences are on the owner's own Notifications tab now
  await page.goto('/owner/account?tab=notifications', { waitUntil: 'networkidle' });
  await expect(page.locator('#pt-prefs')).toHaveText('Email preferences');
  for (const [from, to] of [
    ['/owner/statements', /\/owner\/money\?tab=statements$/], ['/owner/payouts', /\/owner\/money\?tab=payouts$/], ['/owner/invoices?paid=1', /\/owner\/money\?tab=invoices&paid=1$/],
    ['/owner/bookings?vehicle=abc', /\/owner\/vehicles\?tab=bookings&vehicle=abc$/], ['/owner/profile', /\/owner\/account\?tab=profile$/], ['/owner/banking', /\/owner\/account\?tab=banking$/],
    ['/owner/notifications', /\/owner\/account\?tab=notifications$/]
  ] as const) await moved(page, from, to);
  // a detail page keeps its address and its menu link
  await page.goto(`/owner/vehicles/${o.cars[0]!.id}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('owner-nav').locator('a[aria-current="page"]')).toHaveText(/^Cars/);
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});

test('investor portal: what needs you first, Documents with three tabs, nothing about the fleet', async ({ page }) => {
  test.setTimeout(180_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await sql`select pg_advisory_lock(${LOCK})`;
  try {
    await sql`update deck_settings set show_to_investors = true, deck_multiplier = 3.2, deck_return_bps = 3000`;
    const errors = watch(page);
    const i = await seedInvestor(sql);
    await signIn(page, i.email, '/investor');
    await menu(page, 'investor-nav', ['Home', 'Live sheets', 'Documents', 'Investor deck', 'Account'], 'Home');
    await check(page, 'investor home');
    for (const [path, tab] of [['/investor/documents', 'Statements'], ['/investor/documents?tab=sign', 'Documents to sign'], ['/investor/documents?tab=files', 'Your files']] as const) {
      await page.goto(path, { waitUntil: 'networkidle' });
      await expect(page.getByTestId('portal-tabs').locator('a[aria-current="page"]')).toHaveText(new RegExp(`^${tab}`));
      await expect(page.getByTestId('investor-nav').locator('a[aria-current="page"]')).toHaveText(/^Documents/);
      await check(page, path);
    }
    await expect(page.getByRole('heading', { level: 1 })).toHaveCount(1);
    await page.goto('/investor/profile', { waitUntil: 'networkidle' });
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Account');
    await check(page, 'investor account');
    await moved(page, '/investor/statements', /\/investor\/documents\?tab=statements$/);
    await moved(page, '/investor/sign?signed=1', /\/investor\/documents\?tab=sign&signed=1$/);
    for (const p of ['/investor', '/investor/documents', '/investor/documents?tab=files', '/investor/profile']) {
      await page.goto(p, { waitUntil: 'networkidle' });
      const text = await page.locator('main').innerText();
      for (const word of [/utili[sz]ation/i, /fleet size/i, /premium/i, /\bcars? in the fleet\b/i, /insurance/i, /operating cost/i]) expect(text, p).not.toMatch(word);
    }
    expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  } finally {
    await sql`select pg_advisory_unlock(${LOCK})`;
    await sql.end();
  }
});
