import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';

// Live updates (release 41, migration 2500): an Admin screen shows a change made elsewhere within a few seconds, with no
// reload, and keeps what is typed. A new staff alert written straight to the database moves the bell's count while the
// page stays put (no navigation) and a half-typed search keeps its text. Fixtures are example.test only.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function signIn(page: Page, email: string, path = '/admin') {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(path), { timeout: 60_000 });
}

test('a new alert reaches an open Admin page live, without a reload, keeping typed text', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = randomUUID(), email = `live.admin.${Date.now()}.${randomBytes(3).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${admin}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${admin}, ${email}, 'Lia Live')`;
  await sql`insert into user_roles (user_id, role) values (${admin}, 'admin')`;
  try {
    await signIn(page, email);
    await page.goto('/admin/bookings', { waitUntil: 'networkidle' });
    const bell = page.getByTestId('alerts-bell');
    await expect(bell).toBeVisible();
    await expect(page.getByTestId('alerts-bell-count')).toHaveCount(0);

    // the page's own marker: a reload would drop it
    await page.evaluate(() => { (window as unknown as { __liveMark: number }).__liveMark = 41; });
    const search = page.locator('input[type="search"], input[name="q"]').first();
    const typed = (await search.count()) > 0;
    if (typed) { await search.fill('half typed'); await search.blur(); }

    const [code] = await sql`select code from notification_catalogue where audience like 'staff%' order by code limit 1`;
    await sql`insert into notifications (user_id, code, title, dedupe_key) values (${admin}, ${code!.code as string}, 'A new request came in', ${`live-e2e-${admin}`})`;

    // within a few seconds (2 s reads, or a Realtime broadcast), no reload
    await expect(page.getByTestId('alerts-bell-count')).toHaveText('1', { timeout: 10_000 });
    expect(await page.evaluate(() => (window as unknown as { __liveMark?: number }).__liveMark)).toBe(41);
    if (typed) await expect(search).toHaveValue('half typed');
  } finally {
    await sql`delete from notifications where user_id = ${admin}`;
    await sql`delete from user_roles where user_id = ${admin}`;
    await sql`delete from users where id = ${admin}`;
    await sql`delete from local_auth.users where id = ${admin}`;
    await sql.end();
  }
});
