import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, noOverflow, watch } from './helpers';

// Sign first, then cars (r50, migration 3800), at 375 and 1440: a fleet supplier who signed up has the Fleet Supplier
// Lease Agreement and the Title-Holding and Lease Agreement to sign at once, with no car; the owner portal's guided path
// shows the six steps with one big button; the Admin's owner page says exactly what is missing, with Send reminder.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

test('sign first: a fleet supplier signs the lease before any car; the Admin sees what is missing and sends a reminder', async ({ page, browser }, info) => {
  test.setTimeout(180_000);
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const stamp = `${info.project.name}.${Date.now()}`;
  const ownerEmail = `supplier.signfirst.${stamp}@example.test`;
  const adminEmail = `admin.signfirst.${stamp}@example.test`;
  const [ownerUser, adminId] = [randomUUID(), randomUUID()];
  for (const [id, email, role, name] of [[ownerUser, ownerEmail, 'owner', 'Sam Supplier'], [adminId, adminEmail, 'admin', 'Ada Admin']] as const) {
    await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
    await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${name})`;
    await sql`insert into user_roles (user_id, role) values (${id}, ${role})`;
  }
  // the signup: a corporation with a complete profile on the fleet supplier route, no car
  const [o] = await sql`insert into owners (user_id, owner_type, legal_name, first_name, last_name, corporation_name, corporation_number, signing_officer_name, signing_officer_title,
      address_line1, city, province, postal_code, email, phone, status, onboarding_route)
    values (${ownerUser}, 'corporation', 'Sam Supplier', 'Sam', 'Supplier', ${`Signfirst Fleet ${stamp} Ltd.`}, '5000777', 'Sam Supplier', 'Director',
      '1 Example Way', 'Toronto', 'ON', 'M5V 1A1', ${ownerEmail}, '+16475550177', 'lead', 'fleet_supplier') returning id`;
  const agreements = await sql`select kind, variant, status from owner_agreements where owner_id = ${o!.id} order by kind`;
  expect(agreements.map((a) => `${a.kind}/${a.variant}/${a.status}`)).toEqual(['enrollment/fleet_lease/draft', 'title_holding/standard/draft']);

  // ---------------------------------------------------------------- the owner portal: the guided path
  await signIn(page, ownerEmail, '/owner');
  await page.waitForURL(/\/owner/);
  const path = page.getByTestId('owner-path');
  await expect(path).toHaveAttribute('data-step', 'sign');
  await expect(path).toContainText('Sign the Fleet Supplier Lease Agreement');
  await expect(page.getByTestId('owner-path-step')).toHaveCount(6);
  await expect(page.locator('[data-testid="owner-path-cta"], [data-testid="os-cta"]').first()).toBeVisible();
  const box = await page.locator('[data-testid="owner-path-cta"], [data-testid="os-cta"]').first().boundingBox();
  expect(box!.height).toBeGreaterThanOrEqual(44);
  await check(page, 'owner path');
  await page.locator('[data-testid="owner-path-cta"], [data-testid="os-cta"]').first().click();
  await page.waitForURL(/\/owner\/sign/);
  await expect(page.locator('#sg-docs-h')).toContainText('The documents (2)');
  await expect(page.locator('main')).toContainText('Fleet Supplier Lease Agreement');
  await expect(page.locator('main')).toContainText('Title-Holding and Lease Agreement');
  await check(page, 'sign the master agreement');

  // ---------------------------------------------------------------- the Admin: what is missing, Send reminder
  const ctx = await browser.newContext({ viewport: page.viewportSize()!, baseURL: info.project.use.baseURL });
  const admin = await ctx.newPage();
  await signIn(admin, adminEmail, `/admin/owners/${o!.id}`);
  await admin.waitForURL(/\/admin\/owners\//);
  const gate = admin.getByTestId('sign-gate');
  await expect(gate).toContainText('Agreements before cars');
  await expect(gate.getByTestId('sign-gate-list')).toContainText('Sign the Fleet Supplier Lease Agreement');
  await check(admin, 'admin sign gate');
  await admin.getByTestId('sign-gate-remind').click();
  await expect.poll(async () => (await sql`select count(*)::int n from app_events where code = 'owner_sign_reminder' and entity_id = ${o!.id}`)[0]!.n).toBe(1);
  await ctx.close();
  expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e)), 'no console errors').toEqual([]);
});
