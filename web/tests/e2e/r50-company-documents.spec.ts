import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Release 50 (5060): Admin > Company documents renders for an Admin (the six kinds, the add form, the link in the Settings
// menu) and is refused for staff, who land on Admin's no-access page and never see the list. Fictional people only.
type Sql = ReturnType<typeof db>;
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const isPhone = () => (test.info().project.use.viewport?.width ?? 1440) < 600;

async function mkUser(sql: Sql, role: 'admin' | 'va', name: string) {
  const id = randomUUID(); const email = `r50.cdoc.${role}.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (role === 'va') await sql`insert into staff_profiles (user_id, home_address, home_postal_code, staff_type, va_function, single_limit_cents, started_on, onboarding_exempt)
                               values (${id}, '1 Test Lane, Testville', 'X9X 9X9', 'va', 'finance', 0, current_date - 200, true)`;
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

test.describe('company documents', () => {
  let sql: Sql;
  test.beforeAll(() => { sql = db(); });
  test.afterAll(async () => { await sql.end(); });

  test('an Admin sees the page; staff are refused', async ({ browser }) => {
    test.setTimeout(120_000);
    const admin = await mkUser(sql, 'admin', 'Sam Example');
    const staff = await mkUser(sql, 'va', 'Robin Example');

    const a = await signIn(browser, admin.email);
    await a.goto('/admin/company-documents', { waitUntil: 'networkidle' });
    await expect(a.getByRole('heading', { level: 1, name: 'Company documents' })).toBeVisible();
    await expect(a.getByTestId('cdoc-add')).toBeVisible();
    for (const k of ['shareholder_agreement', 'articles', 'franchise_agreement', 'insurance_policy', 'lease', 'other']) await expect(a.getByTestId(`cdoc-kind-${k}`)).toBeVisible();
    await a.getByTestId('cdoc-new-mode-text').check();
    await expect(a.getByTestId('cdoc-new-body')).toBeVisible();
    await expect(a.getByTestId('cdoc-new-signers')).toContainText('Sam Example');
    await noOverflow(a);
    await a.context().close();

    const s = await signIn(browser, staff.email);
    await s.goto('/admin/company-documents', { waitUntil: 'networkidle' });
    await expect(s).toHaveURL(/\/admin\/no-access/);
    await expect(s.getByTestId('cdoc-add')).toHaveCount(0);
    expect((await s.request.get('/admin/company-documents/file/00000000-0000-4000-8000-000000000000', { maxRedirects: 0 })).status()).toBe(404);
    await s.context().close();
  });
});
