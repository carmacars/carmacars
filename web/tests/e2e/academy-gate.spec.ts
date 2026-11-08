import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Browser, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow } from './helpers';

// Migration 0802 end to end, at 375 and 1440: a new customer service hire, enrolled with the gate on, lands on Welcome
// (welcome, profile and phone, the academy, first tasks); a work page sends them back there; the academy and the profile
// open. An Admin waives the academy for them with a reason on their academy page, and their work pages open.
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');
const isPhone = () => test.info().project.name.includes('phone') || (test.info().project.use.viewport?.width ?? 1440) < 600;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${where} ${v.id}`)).toEqual([]);
}
async function mkUser(sql: Sql, role: 'admin' | 'va', fn?: 'cs') {
  const id = randomUUID(); const email = `${role}.ag.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Gail Gate ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  if (fn) await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code) values (${id}, 'va', ${fn}, '1 Example Lane, Testville', 'X9X 9X9')`;
  return { id, email };
}
async function signIn(page: Page, email: string, expectPath: string) {
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(expectPath), { timeout: 20_000 });
}
async function ctx(browser: Browser) {
  const c = await browser.newContext({ viewport: isPhone() ? { width: 375, height: 812 } : { width: 1440, height: 900 }, hasTouch: isPhone(), baseURL: test.info().project.use.baseURL });
  return c.newPage();
}

test.describe.configure({ mode: 'serial' });

test('A new hire is held on Welcome until the academy is passed; an Admin waives it with a reason', async ({ browser }) => {
  test.setTimeout(150_000);
  const sql = db();
  await sql`update program_settings set academy_gate = true`;
  const cs = await mkUser(sql, 'va', 'cs');
  const admin = await mkUser(sql, 'admin');
  await sql`select app.academy_enroll(${cs.id}::uuid, ${admin.id}::uuid, 'hire', now())`;
  const page = await ctx(browser);
  await signIn(page, cs.email, '/staff');
  await page.goto('/staff/renters', { waitUntil: 'networkidle' });
  await page.waitForURL(/\/staff\/welcome$/);
  const w = page.getByTestId('staff-welcome');
  await expect(w.getByTestId('welcome-locked')).toBeVisible();
  for (const k of ['welcome', 'profile', 'academy', 'tasks']) await expect(w.getByTestId(`welcome-step-${k}`)).toBeVisible();
  await expect(w.getByTestId('welcome-step-academy')).toHaveAttribute('data-done', 'false');
  await check(page, 'staff welcome');
  await w.getByRole('link', { name: 'Open the academy' }).click();
  await page.waitForURL(/\/staff\/academy$/);
  await expect(page.getByTestId('academy-locked')).toBeVisible();
  await page.goto('/staff/profile', { waitUntil: 'networkidle' });
  expect(new URL(page.url()).pathname).toBe('/staff/profile');

  const ap = await ctx(browser);
  await signIn(ap, admin.email, '/admin');
  await ap.goto(`/admin/academy/staff/${cs.id}`, { waitUntil: 'networkidle' });
  await expect(ap.getByTestId('academy-gate-state')).toContainText('Held:');
  await ap.getByTestId('academy-waive').click();
  await ap.getByRole('dialog').getByLabel(/Reason/).fill('Two years of rental desk work');
  await ap.getByTestId('academy-waive-submit').click();
  await expect(ap.getByTestId('academy-gate-state')).toContainText('Waived by');
  await check(ap, 'admin academy gate');
  const [wv] = await sql<Array<{ reason: string }>>`select reason from academy_waivers where user_id = ${cs.id} and revoked_at is null`;
  expect(wv?.reason).toBe('Two years of rental desk work');

  await page.goto('/staff/renters', { waitUntil: 'networkidle' });
  expect(new URL(page.url()).pathname, 'waived: the work pages open').toBe('/staff/renters');
  await sql.end();
});
