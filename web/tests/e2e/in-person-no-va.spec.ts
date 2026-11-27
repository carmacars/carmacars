import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';

// R50 hotfix 2 (5180): "VA" is for a remote virtual assistant only. A field staff member and an in-person salesperson see
// their real role on their portal, profile, the Admin's staff list, the townhall deck and the emails' role words, never "VA".
const PW = 'correct horse battery';
type Sql = ReturnType<typeof db>;
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const NO_VA = /\bVAs?\b/;
async function mk(sql: Sql, kind: 'field' | 'sales' | 'admin', tag: string) {
  const id = randomUUID(); const email = `nova.${kind}.${tag}.${randomBytes(2).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${kind === 'field' ? 'Fay Fieldworker' : kind === 'sales' ? 'Sam Salesperson' : 'Ada Admin'})`;
  await sql`insert into user_roles (user_id, role) values (${id}, ${kind === 'field' ? 'field' : kind === 'sales' ? 'va' : 'admin'})`;
  if (kind === 'field') await sql`insert into staff_profiles (user_id, staff_type, field_function, home_address, home_postal_code, onboarding_exempt, agreement_waived_at) values (${id}, 'field', 'driver', '1 Test Lane, Testville', 'X9X 9X9', true, now())`;
  if (kind === 'sales') await sql`insert into staff_profiles (user_id, staff_type, va_function, sales_work_mode, home_address, home_postal_code, onboarding_exempt, agreement_waived_at) values (${id}, 'va', 'sales', 'in_person', '1 Test Lane, Testville', 'X9X 9X9', true, now())`;
  return { id, email };
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const useEmail = page.getByRole('button', { name: /email/i }).first();
  if (await useEmail.isVisible().catch(() => false)) await useEmail.click();
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next.split('?')[0]!));
}
const text = async (page: Page, path: string) => { await page.goto(path, { waitUntil: 'networkidle' }); return page.locator('body').innerText(); };

test.describe.configure({ mode: 'serial' });
let sql: Sql;
test.beforeAll(() => { sql = db(); });
test.afterAll(async () => { await sql.end(); });

test('in-person staff see their real role on every page, the Admin list and the townhall deck, never VA', async ({ browser }) => {
  const tag = String(Date.now());
  const field = await mk(sql, 'field', tag); const sales = await mk(sql, 'sales', tag); const admin = await mk(sql, 'admin', tag);
  await sql`select app.townhall_build(null, null)`;
  // the deck's words (the people slide names each person's role)
  const [deck] = await sql`select slides::text as s from townhall_decks order by built_at desc limit 1`;
  expect(String(deck!.s)).not.toMatch(NO_VA);
  // the database's own role words for these two people (the emails' {{role_label}}, the people slide)
  const [w] = await sql`select app.staff_resign_role(f) as field, app.staff_resign_role(s) as sales
                         from staff_profiles f, staff_profiles s where f.user_id = ${field.id} and s.user_id = ${sales.id}`;
  expect(w!.field).toBe('Field staff'); expect(w!.sales).toBe('Sales');
  expect(JSON.stringify(await sql`select app.townhall_people(date_trunc('week', now())::date) as p`)).not.toMatch(NO_VA);

  const ctx = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page = await ctx.newPage();
  await signIn(page, field.email, '/staff/field');
  for (const p of ['/staff/field', '/staff/field/profile', '/staff/field/guide', '/staff/townhall', '/staff/alerts']) {
    const t = await text(page, p);
    expect(t, `${p} (field staff)`).not.toMatch(NO_VA);
  }
  await ctx.close();

  const ctx2 = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page2 = await ctx2.newPage();
  await signIn(page2, sales.email, '/staff');
  for (const p of ['/staff', '/staff/profile', '/staff/guide', '/staff/townhall']) expect(await text(page2, p), `${p} (in-person sales)`).not.toMatch(NO_VA);
  expect(await text(page2, '/staff/profile')).toContain('Sales');
  await ctx2.close();

  // the Admin's staff list: the sign-in roles in words, and each person's real function
  const ctx3 = await browser.newContext({ viewport: { width: 1366, height: 900 } });
  const page3 = await ctx3.newPage();
  await signIn(page3, admin.email, '/admin/settings/staff');
  const rows = page3.getByTestId('staff').locator('tr');
  const rowOf = async (email: string) => (await rows.filter({ hasText: email }).first().innerText());
  const fieldRow = await rowOf(field.email); const salesRow = await rowOf(sales.email);
  expect(fieldRow).toContain('Field work'); expect(fieldRow).not.toMatch(NO_VA); expect(fieldRow).not.toMatch(/\bva\b/);
  expect(salesRow).toContain('Sales (in person)'); expect(salesRow).not.toMatch(NO_VA); expect(salesRow).not.toMatch(/\bva\b/);
  await ctx3.close();
});
