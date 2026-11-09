import { expect, test } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';

// Migration 0813 end to end (one generic card since 1150): the incident card page (Admin) with the fleet insurance policy, two
// identical cards to a Letter page, the steps, the three coverage options, the QR code to /incident, the slip fields, no car
// and no amount of money.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };

test('Admin: set the policy, see the one generic card with the steps, the options and the slip fields', async ({ browser }) => {
  test.setTimeout(180_000);
  const sql = db();
  const id = randomUUID(); const email = `admin.ic.${Date.now()}.${randomBytes(3).toString('hex')}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Cards')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  const [v] = await sql`select (app.vehicle_add(${id}, ${sql.json({ supply_type: 'company', vin: '1XFCXMM0000009877', plate: `IC${randomBytes(2).toString('hex').toUpperCase()}`, year: 2024, make: 'Kia', model: 'K5',
    rates: { daily: 10000, weekend: 10000, weekly: 70000, monthly: 300000, deposit: 30000 } })}) ->> 'vehicle_id') as vid`;
  await sql`update fleet_insurance_policies set is_current = false where is_current`;
  await sql`insert into fleet_insurance_policies (insurer_name, policy_number, effective_on, expires_on) values ('Example Mutual', 'IC-100', '2026-01-01', '2099-01-01')`;
  const c = await browser.newContext({ baseURL: test.info().project.use.baseURL, viewport: { width: 1280, height: 900 } });
  const page = await c.newPage();
  await page.goto('/sign-in', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith('/admin'), { timeout: 20_000 });
  await page.goto('/admin/vehicles/incident-cards', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('incident-card')).toHaveCount(2);
  const card = page.getByTestId('incident-card').first();
  await expect(card).toContainText('In an accident or breakdown');
  await expect(card).toContainText('call 911', { ignoreCase: true });
  await expect(card).toContainText('Do not admit fault');
  for (const o of [1, 2, 3]) await expect(card.getByTestId(`incident-card-option-${o}`)).toContainText(`Option ${o}`);
  await expect(card).not.toContainText('1XFCXMM0000009877');
  await expect(card.getByTestId('incident-card-slip')).toContainText('IC-100');
  await expect(card.getByTestId('incident-card-slip')).toContainText('18122211 Canada Inc.');
  await expect(card.locator('.ic-qr svg')).toBeVisible();
  await expect(card).toContainText('/incident');
  expect(await card.innerText()).not.toMatch(/premium|\$\d/i);
  await expect(page.getByTestId('print-cards')).toHaveText('Print the cards');
  // the car page links to the card
  await page.goto(`/admin/vehicles/${v!.vid}`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('incident-card-link')).toHaveAttribute('href', '/admin/vehicles/incident-cards');
  await c.close();
  await sql.end();
});
