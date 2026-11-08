import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0760 (release 33, part J): Cars > Import photos from Drive. An Admin opens the page, a link that is not a Drive
// folder is refused on the page, a folder link enables the button, and a renter cannot open the page. The import itself reads
// Google Drive, which the test server cannot reach: the folder reading, the matching and the idempotency are covered by the
// unit tests (drive-folder.test.ts, drive-match.test.ts) and the database suite (supabase/tests/99_r33_drive_import.sql).
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const tag = () => randomBytes(3).toString('hex');

async function signIn(page: Page, email: string, path: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(path), { timeout: 20_000 });
}

test('an Admin opens Import photos from Drive; only a Drive folder link starts it', async ({ page }) => {
  test.skip((test.info().project.use.viewport?.width ?? 1440) < 600, 'one width is enough');
  test.setTimeout(90_000);
  const sql = db();
  const id = randomUUID(); const email = `di.admin.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${'Dee Importer'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  await signIn(page, email, '/admin');
  await page.goto('/admin/vehicles/import-photos', { waitUntil: 'networkidle' });
  await expect(page.getByRole('heading', { name: 'Import photos from Drive' }).first()).toBeVisible();
  const start = page.getByTestId('drive-import-start');
  await expect(start).toBeDisabled();
  await page.getByTestId('drive-import-link').fill('https://example.test/not-drive');
  await expect(page.getByText('That is not a Google Drive link.')).toBeVisible();
  await expect(start).toBeDisabled();
  await page.getByTestId('drive-import-link').fill('https://drive.google.com/file/d/ExampleFileId0000001/view');
  await expect(page.getByText('That is the link of one file.')).toBeVisible();
  await page.getByTestId('drive-import-link').fill('https://drive.google.com/drive/folders/ExampleFolderId000001?usp=sharing');
  await expect(start).toBeEnabled();
  await expect(page.getByTestId('drive-import-submit')).toBeChecked();
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id)).toEqual([]);
  expect((await page.locator('body').innerText()).match(/[—–]/)?.[0], 'long dash').toBeUndefined();
});

test('a renter does not get the page', async ({ page }) => {
  test.skip((test.info().project.use.viewport?.width ?? 1440) < 600, 'one width is enough');
  const sql = db();
  const id = randomUUID(); const email = `di.renter.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`select public.register_account(${id}, ${email}, ${'Rae Renter'}, null)`;
  await signIn(page, email, '/account');
  await page.goto('/admin/vehicles/import-photos');
  await expect(page.getByTestId('drive-import')).toHaveCount(0);
});
