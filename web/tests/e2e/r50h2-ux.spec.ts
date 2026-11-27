import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
import { seedOwner } from './portal-design-seed';

// R50 hotfix 2 UX (docs/changes/2026-11-27-r50h2-ux.md), at 375 and 1440:
//   1. the renter's booking page: the live countdown to pickup, Add to calendar (Apple, Google, Outlook, .ics) and the
//      stepped tracker (one step now, a step opens its detail);
//   2. the booking status tracker for staff: From sale to pickup on the booking's overview;
//   4. the demo renter and owner portals for staff (made-up data, nothing saved);
//   5. the weekly Admin call: the deck builds, a To do is approved in place, the calendar file, staff refused.
// Fictional people only.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function person(sql: Sql, role: 'renter' | 'admin' | 'va', name: string) {
  const id = randomUUID(); const email = `r50h2.ux.${role}.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash, email_confirmed_at) values (${id}, ${email}, ${hash(PW)}, now())`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents, started_on, onboarding_exempt)
                               values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'sales', 0, current_date - 200, true)`;
  return { id, email };
}
async function signIn(browser: Browser, email: string): Promise<Page> {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL, reducedMotion: 'reduce' });
  const page = await c.newPage();
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => !u.pathname.startsWith('/sign-in'), { timeout: 60_000 });
  return page;
}

test.describe('r50 hotfix 2 UX', () => {
  let sql: Sql;
  test.beforeAll(() => { sql = db(); });
  test.afterAll(async () => { await sql.end(); });

  test('the renter booking page: countdown, Add to calendar, the stepped tracker; staff see From sale to pickup', async ({ browser }) => {
    test.setTimeout(180_000);
    await sql`delete from app.rate_limit_hits`;
    const o = await seedOwner(sql);
    const car = o.cars.find((c) => c.status === 'available')!;
    const renter = await person(sql, 'renter', 'Robin Example');
    const [r] = await sql`insert into renters (user_id, legal_name, date_of_birth, mobile, email, identity_status) values (${renter.id}, 'Robin Example', date '1990-05-05', '647-555-0148', ${renter.email}, 'verified')
                          on conflict (user_id) do update set identity_status = 'verified' returning id`;
    const number = `UX-${tag().toUpperCase()}`;
    await sql`insert into bookings (booking_number, booking_type, status, vehicle_id, renter_id, booked_at, confirmed_at, pickup_at, return_at, original_return_at, billable_days,
        daily_rate_cents, weekend_rate_cents, weekly_rate_cents, monthly_rate_cents, rate_applied, rental_charge_cents, km_allowance_per_day, km_allowance_total,
        overage_cents_per_km, deposit_cents, blocks_calendar, total_due_at_booking_cents)
      values (${number}, 'standard', 'confirmed', ${car.id}, ${r!.id}, now() - interval '1 day', now() - interval '1 day', now() + interval '3 days 2 hours', now() + interval '6 days 2 hours', now() + interval '6 days 2 hours',
        3, 10000, 12000, 56000, 180000, 'daily', 30000, 200, 600, 25, 50000, true, 30000)`;
    const page = await signIn(browser, renter.email);
    const errors = watch(page);
    await page.goto(`/account/bookings/${number}`, { waitUntil: 'networkidle' });
    // 1. the countdown: days, hours, minutes, seconds, ticking
    const cd = page.getByTestId('pickup-countdown');
    await expect(cd).toBeVisible();
    await expect(cd.getByTestId('pickup-countdown-days')).toHaveText('3');
    const sec = await cd.getByTestId('pickup-countdown-sec').textContent();
    await expect.poll(async () => cd.getByTestId('pickup-countdown-sec').textContent(), { timeout: 5_000 }).not.toBe(sec);
    // Add to calendar: Apple (.ics), Google and Outlook with the pickup filled in
    await page.getByTestId('add-to-calendar-open').click();
    await expect(page.getByTestId('add-to-calendar-apple')).toBeVisible();
    await expect(page.getByTestId('add-to-calendar-google')).toHaveAttribute('href', new RegExp(`^https://calendar\\.google\\.com/calendar/render\\?action=TEMPLATE&text=Pick\\+up.*${number}`));
    await expect(page.getByTestId('add-to-calendar-outlook')).toHaveAttribute('href', /^https:\/\/outlook\.live\.com\/calendar\//);
    const [dl] = await Promise.all([page.waitForEvent('download'), page.getByTestId('add-to-calendar-ics').click()]);
    expect(dl.suggestedFilename()).toBe(`${number}.ics`);
    // the stepped tracker: the offer and sign-and-pay are done, one step is now, a tap opens what it means
    const tr = page.getByTestId('step-tracker');
    await expect(page.getByTestId('step-tracker-offer')).toHaveAttribute('data-state', 'done');
    await expect(tr.locator('li[aria-current="step"]')).toHaveCount(1);
    const now = tr.locator('li[aria-current="step"]');
    const key = await now.getAttribute('data-step');
    await expect(page.getByTestId(`step-tracker-${key}-detail`)).toBeVisible();
    await page.getByTestId(`step-tracker-${key}-toggle`).click();
    await expect(page.getByTestId(`step-tracker-${key}-detail`)).toBeHidden();
    await expect(page.getByTestId('step-tracker-finish')).toHaveAttribute('data-state', 'later');
    await noOverflow(page);
    expect(errors).toEqual([]);

    // 2. the booking status for staff: From sale to pickup, on the booking's overview (Admin and staff alike)
    const admin = await person(sql, 'admin', 'Avery Example');
    const a = await signIn(browser, admin.email);
    await a.goto(`/admin/bookings/${number}`, { waitUntil: 'networkidle' });
    const sale = a.getByTestId('sale-steps');
    await expect(sale).toBeVisible();
    await expect(a.getByTestId('sale-steps-ms-answer')).toHaveAttribute('data-state', 'done');
    await expect(a.getByTestId('sale-steps-ms-pickup')).toHaveAttribute('data-state', 'later');
    await expect(sale.locator('li[aria-current="step"]')).toHaveCount(1);
    await noOverflow(a);
  });

  test('the demo renter and owner portals: made-up data, stage by stage, nothing saved', async ({ browser }) => {
    test.setTimeout(150_000);
    const staff = await person(sql, 'va', 'Sasha Example');
    const page = await signIn(browser, staff.email);
    const errors = watch(page);
    await page.goto('/staff/demo', { waitUntil: 'networkidle' });
    await page.getByTestId('demo-open-renter').click();
    await page.waitForURL(/\/staff\/demo\/renter$/);
    await expect(page.getByTestId('demo-banner')).toContainText('Made-up data');
    await page.getByTestId('demo-renter-stage-offered').click();
    await expect(page.getByTestId('demo-renter')).toHaveAttribute('data-stage', 'offered');
    await expect(page.getByTestId('demo-renter-status')).toHaveText('Offer ready');
    await expect(page.getByTestId('demo-countdown')).toBeVisible();
    await expect(page.getByTestId('demo-renter-steps-offer')).toHaveAttribute('data-state', 'now');
    await page.getByRole('button', { name: 'See the offer' }).click();
    await expect(page.getByTestId('demo-said')).toContainText('Nothing was sent or saved');
    await page.getByTestId('demo-renter-stage-closed').click();
    await expect(page.getByTestId('demo-renter-steps-finish')).toHaveAttribute('data-state', 'done');
    await noOverflow(page);
    await page.goto('/staff/demo/owner', { waitUntil: 'networkidle' });
    await page.getByTestId('demo-owner-stage-transfer').click();
    await expect(page.getByTestId('demo-owner-steps-transfer')).toHaveAttribute('data-state', 'now');
    await page.getByTestId('demo-owner-stage-earning').click();
    await expect(page.getByTestId('demo-owner-statement')).toContainText('Your payout');
    await noOverflow(page);
    expect(errors).toEqual([]);
    // the Admins have the same pages
    const admin = await person(sql, 'admin', 'Ari Example');
    const a = await signIn(browser, admin.email);
    await a.goto('/admin/demo/renter', { waitUntil: 'networkidle' });
    await expect(a.getByTestId('demo-renter')).toBeVisible();
  });

  test('the weekly Admin call: the deck, Approve in place, the calendar file; staff are refused', async ({ browser }) => {
    test.setTimeout(150_000);
    const admin = await person(sql, 'admin', 'Morgan Example');
    const t = tag();
    await sql`select app.raise_task(p_type => 'ux_admin_call', p_title => ${`UX ${t}: decide the new insurer`}, p_dedupe => ${`ux-ac:${t}`}, p_queue => 'admin', p_priority => 'urgent')`;
    const [task] = await sql`select id from tasks where dedupe_key = ${`ux-ac:${t}`}`;
    const page = await signIn(browser, admin.email);
    const errors = watch(page);
    await page.goto('/admin/admin-call', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('ac-when')).toContainText('Toronto time');
    await page.getByTestId('ac-build').click();
    await expect(page.getByTestId('ac-slide-shifts')).toBeVisible({ timeout: 30_000 });
    await expect(page.getByTestId('ac-deck').locator('> li')).toHaveCount(14);
    const item = page.getByTestId(`ac-item-todo:${task!.id}`);
    await expect(item).toHaveAttribute('data-decision', 'open');
    await page.getByTestId(`ac-approve-todo:${task!.id}`).click();
    await expect(page.getByTestId(`ac-decided-todo:${task!.id}`)).toContainText('Approve: Morgan Example');
    expect((await sql`select status, detail from tasks where id = ${task!.id}`)[0]!.detail).toContain('Approved in the Admin call');
    const ics = await page.request.get('/api/admin-call-ics');
    expect(ics.status()).toBe(200);
    expect(await ics.text()).toContain('UID:admin-call@carmacars.ca');
    await noOverflow(page);
    expect(errors).toEqual([]);
    const staff = await person(sql, 'va', 'Sam Staff');
    const s = await signIn(browser, staff.email);
    await s.goto('/admin/admin-call', { waitUntil: 'networkidle' });
    await expect(s.getByTestId('ac-deck')).toHaveCount(0);
    expect(s.url()).not.toMatch(/\/admin\/admin-call$/);
  });
});
