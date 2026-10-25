import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';
import { PW, seedOwner } from './portal-design-seed';

// Migration 0156 end to end (docs/changes/2026-10-25-hide-revenue-from-owner.md): an Admin hides a booking's revenue
// from the owner on the booking page (with a reason) and adds a documented booking expense on the Money tab; the owner
// sees the booking as Booked with its dates and no amount (Bookings, the car page, Home), and sees the expense with its
// reason on a booking they can see; then the Admin shows it again and the amount is back. Both widths for the owner;
// axe, no sideways scroll, no long dash. Fictional people only (example.test).
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const money = (c: number) => `$${(c / 100).toLocaleString('en-CA', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], `${where}: long dash`).toBeUndefined();
  expect(await page.locator('body').innerText(), `${where}: a raw database error`).not.toMatch(/violates|constraint "|relation "|invalid input syntax/);
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next), { timeout: 60_000 });
  await page.waitForLoadState('networkidle');
}
async function ctx(browser: Browser, phone: boolean) {
  const c = await browser.newContext({ viewport: phone ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: phone, baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

test('hide a booking\'s revenue from the owner, and a booking expense the owner sees', async ({ browser }) => {
  test.setTimeout(300_000);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const o = await seedOwner(sql);
  // an Admin of this test's own
  const admin = randomUUID(); const adminEmail = `oh.admin.${Date.now()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${adminEmail}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${admin}, ${adminEmail}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  // the first car's next confirmed booking (to hide) and its last finished one (for the expense)
  const [up] = await sql`select booking_number, rental_charge_cents::int c from bookings where vehicle_id = ${o.cars[0]!.id} and status = 'confirmed' order by pickup_at limit 1`;
  const [done] = await sql`select booking_number from bookings where vehicle_id = ${o.cars[0]!.id} and status = 'closed' order by return_at desc limit 1`;
  const hidden = up!.booking_number as string; const amount = money(up!.c as number);

  // the Admin hides it, with a reason
  const a = await ctx(browser, false);
  const errors = watch(a);
  await signIn(a, adminEmail, '/admin');
  await a.goto(`/admin/bookings/${hidden}`, { waitUntil: 'networkidle' });
  await expect(a.getByTestId('owner-visibility-state')).toHaveText('The owner can see it');
  await a.getByTestId('owner-hide').click();
  await a.getByTestId('owner-hide-form').getByLabel(/Reason/).fill('Price under review with the owner');
  await a.getByTestId('owner-hide-submit').click();
  await expect(a.getByTestId('owner-visibility-state')).toHaveText('Hidden from the owner');
  await expect(a.getByTestId('owner-visibility-label')).toContainText('until the owner statement covering it is approved');
  await check(a, 'admin booking, hidden from the owner');
  const [v] = await sql`select owner_visibility, owner_visibility_reason from bookings where booking_number = ${hidden}`;
  expect([v!.owner_visibility, v!.owner_visibility_reason]).toEqual(['until_statement', 'Price under review with the owner']);

  // and adds a documented expense on a finished booking (Money tab)
  await a.goto(`/admin/bookings/${done!.booking_number}?tab=money`, { waitUntil: 'networkidle' });
  await a.getByTestId('owner-expense-add').click();
  const f = a.getByTestId('owner-expense-add-form');
  await f.getByLabel('Amount').fill('45');
  await f.getByLabel('Reason the owner reads').fill('Smoke smell, ozone treatment');
  await a.getByTestId('owner-expense-add-submit').click();
  await expect(a.getByTestId('owner-expenses')).toContainText('Smoke smell, ozone treatment');
  await check(a, 'admin booking money, owner deductions');

  // the owner, at both widths: Booked with the dates, never the amount; the expense with its reason
  for (const phone of [false, true]) {
    const p = await ctx(browser, phone);
    const w = phone ? 'phone' : 'desktop';
    await signIn(p, o.email, '/owner');
    await p.goto('/owner/bookings', { waitUntil: 'networkidle' });
    const row = p.getByTestId('owner-booking-row').filter({ hasText: hidden });
    await expect(row).toHaveAttribute('data-view', 'booked');
    await expect(row.locator('.ow-amount')).toHaveText('Booked');
    expect(await row.innerText()).not.toContain(amount);
    await expect(p.getByTestId('owner-booking-row').filter({ hasText: done!.booking_number as string }).getByTestId('owner-booking-expense')).toContainText('Smoke smell, ozone treatment');
    await check(p, `owner bookings (${w})`);
    await p.goto(`/owner/vehicles/${o.cars[0]!.id}`, { waitUntil: 'networkidle' });
    await expect(p.getByTestId('owner-booking-row').filter({ hasText: hidden }).locator('.ow-amount')).toHaveText('Booked');
    await check(p, `owner car page (${w})`);
    await p.context().close();
  }

  // shown again: the amount is back
  await a.goto(`/admin/bookings/${hidden}`, { waitUntil: 'networkidle' });
  await a.getByTestId('owner-show').click();
  await a.getByTestId('owner-show-submit').click();
  await expect(a.getByTestId('owner-visibility-state')).toHaveText('The owner can see it');
  const p = await ctx(browser, false);
  await signIn(p, o.email, '/owner');
  await p.goto('/owner/bookings', { waitUntil: 'networkidle' });
  await expect(p.getByTestId('owner-booking-row').filter({ hasText: hidden }).locator('.ow-amount')).toHaveText(amount);
  expect(errors.filter((e) => !/favicon|Download the React DevTools/.test(e))).toEqual([]);
  await sql.end();
});
