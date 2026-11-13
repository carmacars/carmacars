import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 2730 end to end, at 375 and 1440: an Admin signing in after a release sees the "What's new" pop-up once, with
// the words written for admins; Esc closes it; it does not come back on the next page or the next visit; the "What's new"
// link in the frame opens it again; the database holds one row for it.
const PW = 'correct horse battery';
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function signIn(page: Page, email: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
}


// this file checks the pop-up itself, so it does not send the header that keeps it shut under the other tests
test.use({ extraHTTPHeaders: {} });

test('the What\'s new pop-up opens once after a release, closes with Esc, and the link opens it again', async ({ page }) => {
  const sql = db();
  const id = randomUUID(); const email = `admin.wn.${Date.now()}.${tag()}@example.test`;
  try {
    await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Wendy News ${tag()}`})`;
    await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
    await signIn(page, email);

    const dialog = page.getByTestId('whats-new');
    await expect(dialog).toBeVisible();
    await expect(dialog.getByRole('heading', { name: "What's new" })).toBeVisible();
    await expect(dialog.locator('li').first()).toBeVisible();
    await noOverflow(page);
    const axe = await new AxeBuilder({ page: page as never }).include('[data-testid="whats-new"]').withTags(['wcag2a', 'wcag2aa']).analyze();
    expect(axe.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id)).toEqual([]);

    // the focus is in the pop-up (its button), Esc closes it
    await expect.poll(() => page.evaluate(() => !!document.activeElement?.closest('dialog'))).toBe(true);
    await page.keyboard.press('Escape');
    await expect(dialog).toBeHidden();

    // seen once: another page and a reload do not open it
    await expect.poll(async () => (await sql`select count(*)::int as n from user_release_seen where user_id = ${id} and portal = 'admin'`)[0]!.n).toBe(1);
    await page.goto('/admin/settings', { waitUntil: 'networkidle' });
    await expect(page.getByTestId('whats-new')).toBeHidden();

    // the link opens it again, and the button closes it
    await page.getByTestId('whats-new-link').click();
    await expect(page.getByTestId('whats-new')).toBeVisible();
    await page.getByTestId('whats-new-dismiss').click();
    await expect(page.getByTestId('whats-new')).toBeHidden();
    expect((await sql`select count(*)::int as n from user_release_seen where user_id = ${id}`)[0]!.n).toBe(1);
  } finally {
    await sql`delete from users where id = ${id}`.catch(() => undefined);
    await sql`delete from local_auth.users where id = ${id}`.catch(() => undefined);
    await sql.end().catch(() => undefined);
  }
});
