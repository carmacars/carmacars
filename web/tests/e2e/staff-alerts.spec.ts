import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// The staff Alerts feed and settings (migration 0466), at 375 and 1440 with axe: the bell with the unread count, the
// list (filters, open, mark read, snooze, mark all read), quiet hours, focus mode and the Admin's rule table; a staff
// member's own Alerts page. Every person and alert here is made for the test (example.test).
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function mkStaff(sql: Sql, role: 'admin' | 'va') {
  const id = randomUUID(); const email = `alerts.${role}.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${role === 'admin' ? 'Ada Alerts' : 'Cora Service'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, staff_type, va_function) values (${id}, 'va', 'cs')`;
  return { id, email };
}
async function seed(sql: Sql, user: string) {
  const rows: Array<[string, string, string, string, number]> = [
    ['staff_alert_urgent', 'Agreement not signed: CC-E2E1, Car, Renter', 'Pickup at 3:00 pm. Send the signing link again.', '/admin/bookings/CC-E2E1', 3],
    ['staff_alert_normal', 'Payment received: $640.00', 'CC-E2E2, Car, Renter', '/admin/payments', 20],
    ['staff_alert_digest', 'Offer sent: CC-E2E3, Car, Renter', 'Pickup Nov 9', '/admin/bookings/CC-E2E3', 90]
  ];
  for (const [code, title, body, url, mins] of rows) {
    await sql`insert into notifications (user_id, code, title, body, url, dedupe_key, created_at)
              values (${user}, ${code}, ${title}, ${body}, ${url}, ${'e2e:' + randomUUID()}, now() - make_interval(mins => ${mins}))`;
  }
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const useEmail = page.getByRole('button', { name: /email/i }).first();
  if (await useEmail.isVisible().catch(() => false)) await useEmail.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next));
}
async function check(page: Page, where: string, scope: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).include(scope).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[–—]/)?.[0], `${where}: long dash`).toBeUndefined();
}

test('an Admin reads, snoozes and clears alerts behind the bell, and sets quiet hours, focus mode and the rules', async ({ page }, info) => {
  const sql = db();
  const rule = info.project.name.includes('phone') ? 'win_month_totals' : 'win_first_payout';
  try {
    const me = await mkStaff(sql, 'admin');
    await seed(sql, me.id);
    await signIn(page, me.email, '/admin');
    const bell = page.getByTestId('alerts-bell');
    await expect(bell.getByTestId('alerts-bell-count')).toHaveText('3');
    await bell.click();
    await page.waitForURL((u) => u.pathname === '/admin/alerts');
    const feed = page.getByTestId('alerts-feed');
    await expect(feed.getByTestId('alert-item')).toHaveCount(3);
    await expect(feed.getByTestId('alerts-unread')).toHaveText('3 unread');
    await check(page, '/admin/alerts', '[data-testid="alerts-feed"], [data-testid="alerts-bell"]');

    await feed.getByTestId('alerts-filter-urgent').click();
    await expect(page).toHaveURL(/f=urgent/);
    await expect(page.getByTestId('alerts-feed').getByTestId('alert-item')).toHaveCount(1);
    await page.getByTestId('alert-snooze').click();
    await expect(page.getByTestId('alerts-feed').getByRole('status')).toContainText('Snoozed until');
    expect((await sql`select count(*)::int n from notifications where user_id = ${me.id} and snoozed_until > now() + interval '25 minutes'`)[0]?.n).toBe(1);

    await page.getByTestId('alerts-filter-all').click();
    await expect(page.getByTestId('alerts-feed').getByTestId('alert-item')).toHaveCount(3);
    await page.getByTestId('alert-read').first().click();
    await expect(page.getByTestId('alerts-unread')).toHaveText('2 unread');
    await page.getByTestId('alerts-read-all').click();
    await expect(page.getByTestId('alerts-unread')).toHaveCount(0);
    await expect.poll(async () => (await sql`select count(*)::int n from notifications where user_id = ${me.id} and read_at is null`)[0]?.n).toBe(0);
    await page.getByTestId('alerts-filter-unread').click();
    await expect(page.getByTestId('alerts-empty')).toContainText('Nothing unread');

    await page.goto('/admin/alerts?tab=settings', { waitUntil: 'networkidle' });
    const s = page.getByTestId('alert-settings');
    await expect(s).toBeVisible();
    await s.getByTestId('alert-quiet-from').selectOption('1320');
    await expect(s.getByTestId('alert-settings-msg')).toContainText('Saved');
    await expect.poll(async () => (await sql`select quiet_from from staff_alert_prefs where user_id = ${me.id}`)[0]?.quiet_from).toBe(1320);
    await s.getByTestId('alert-focus-60').click();
    await expect(s.getByTestId('alert-focus-state')).toContainText('On until');
    await s.getByTestId('alert-focus-off').click();
    await expect(s.getByTestId('alert-focus-state')).toHaveText('Off');

    const rules = page.getByTestId('alert-rules');
    await rules.getByText('Wins', { exact: true }).click();
    const row = rules.getByTestId(`alert-rule-${rule}`);
    await row.getByRole('switch').uncheck();
    await expect.poll(async () => (await sql`select enabled from staff_alert_rules where rule = ${rule}`)[0]?.enabled).toBe(false);
    await row.getByRole('switch').check();
    await expect.poll(async () => (await sql`select enabled from staff_alert_rules where rule = ${rule}`)[0]?.enabled).toBe(true);
    await check(page, '/admin/alerts?tab=settings', '[data-testid="alert-settings"], [data-testid="alert-rules"]');
  } finally {
    await sql`update staff_alert_rules set enabled = true where rule = ${rule}`;
    await sql.end();
  }
});

test('a staff member has their own Alerts behind the bell, and their quiet hours', async ({ page }) => {
  const sql = db();
  try {
    const me = await mkStaff(sql, 'va');
    await sql`insert into notifications (user_id, code, title, body, url, dedupe_key)
              values (${me.id}, 'staff_alert_urgent', 'Passed to you: Card declined at pickup: CC-E2E4', 'Cora did not open it in 15 minutes.', '/staff/bookings/CC-E2E4', ${'e2e:' + randomUUID()})`;
    await signIn(page, me.email, '/staff');
    await page.getByTestId('alerts-bell').click();
    await page.waitForURL((u) => u.pathname === '/staff/alerts');
    const feed = page.getByTestId('alerts-feed');
    await expect(feed.getByTestId('alert-item')).toHaveCount(1);
    await expect(feed.getByTestId('alert-item')).toHaveAttribute('data-tier', 'urgent');
    await check(page, '/staff/alerts', '[data-testid="alerts-feed"]');
    await page.goto('/staff/alerts?tab=settings', { waitUntil: 'networkidle' });
    const s = page.getByTestId('alert-settings');
    await s.getByTestId('alert-quiet-on').uncheck();
    await expect(s.getByTestId('alert-settings-msg')).toContainText('Quiet hours off');
    await expect.poll(async () => (await sql`select quiet_on from staff_alert_prefs where user_id = ${me.id}`)[0]?.quiet_on).toBe(false);
    await expect(page.getByTestId('alert-rules')).toHaveCount(0);
    await check(page, '/staff/alerts?tab=settings', '[data-testid="alert-settings"]');
  } finally { await sql.end(); }
});
