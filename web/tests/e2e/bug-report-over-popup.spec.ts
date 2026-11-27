import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, openAccountMenu } from './helpers';

// r50 (3900): "Report a bug" can be pressed while a pop-up is open. A native modal dialog (What's new opens with showModal)
// makes the header's button inert; the button is then shown inside the pop-up, opens the form above it, and the report
// carries the pop-up (its picture and, in the context, its title and test id).
const PW = 'correct horse battery';
const tag = () => randomBytes(3).toString('hex');
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function signIn(page: Page, email: string, home: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(home), { timeout: 20_000 });
}

test('Report a bug works from inside an open modal and captures it', async ({ page }) => {
  test.setTimeout(90_000);
  const sql = db();
  const id = randomUUID(); const email = `admin.bugpop.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Pat Popup ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  try {
    await signIn(page, email, '/admin');
    await openAccountMenu(page); await page.getByTestId('whats-new-link').first().click();
    const modal = page.getByTestId('whats-new');
    await expect(modal).toBeVisible();
    // the modal makes the page behind it inert: the copy of the button is inside the modal, and it can be pressed
    const float = modal.getByTestId('bug-report-float');
    await expect(float).toBeVisible();
    // r50 hotfix2: the copy never lies over the pop-up's own controls (on a phone it sat across a sheet's full width)
    const fb = (await float.boundingBox())!;
    for (const b of await modal.locator('button, a, input, select, textarea').all()) {
      if (!(await b.isVisible()) || (await b.getAttribute('data-testid')) === 'bug-report-float') continue;
      const o = await b.boundingBox();
      if (!o) continue;
      const overlaps = fb.x < o.x + o.width && o.x < fb.x + fb.width && fb.y < o.y + o.height && o.y < fb.y + fb.height;
      expect(overlaps, `the bug button covers ${await b.textContent()}`).toBe(false);
    }
    await float.click();
    const form = page.getByTestId('bug-report-dialog');
    await expect(form).toBeVisible();
    // the form is on top and usable while the modal stays open behind it
    await page.getByTestId('bug-report-happened').fill('The What\'s new pop-up covered the page and nothing else could be pressed.');
    await page.getByTestId('bug-report-sev-cosmetic').check();
    await page.getByTestId('bug-report-send').click();
    await expect(page.getByTestId('bug-report-mine')).toBeVisible({ timeout: 20_000 });
    const [r] = await sql<{ popup: string | null }[]>`select context ->> 'popup' as popup from bug_reports where reporter_id = ${id} order by number desc limit 1`;
    expect(r?.popup ?? '').toContain('[whats-new]');
    // closing the form leaves the modal as it was, and closing the modal removes the copy of the button
    await page.keyboard.press('Escape');
    await expect(form).toBeHidden();
    await expect(modal).toBeVisible();
    await page.getByTestId('whats-new-dismiss').click();
    await expect(modal).toBeHidden();
    await expect(page.getByTestId('bug-report-float')).toHaveCount(0);
    await openAccountMenu(page);
    await expect(page.getByTestId('bug-report-open')).toBeVisible();
  } finally {
    await sql`delete from bug_reports where reporter_id = ${id}`.catch(() => undefined);
    await sql`delete from users where id = ${id}`.catch(() => undefined);
    await sql`delete from local_auth.users where id = ${id}`.catch(() => undefined);
    await sql.end().catch(() => undefined);
  }
});
