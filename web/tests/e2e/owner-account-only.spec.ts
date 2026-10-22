import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db, fillYmm, noOverflow, tapColour, watch } from './helpers';

// An owner account without a car (migration 0087), at 375 and 1440: the application with "I'll add my car later"
// opens the account and the owner record with no car (an "Account only: no car yet" application, one follow-up task for
// the Admin, no per-car intake), the owner portal asks for the first car, the Admin sees it in Applications; then the
// owner adds the first car from the portal (VIN-first): an ordinary application, the follow-up closed.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
const vin = (prefix: string) => { const ok = 'ABCDEFGHJKLMNPRSTUVWXYZ0123456789'; let s = prefix; while (s.length < 17) s += ok[Math.floor(Math.random() * ok.length)]; return s; };

async function check(page: Page, where: string) {
  await noOverflow(page);
  const r = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  const bad = r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
  expect(bad.map((v) => `${where} ${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
}

test('owner account without a car, then the first car from the owner portal', async ({ page, browser }, info) => {
  test.setTimeout(240_000);
  const phone = info.project.name.startsWith('phone');
  const errors = watch(page);
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  const stamp = `${info.project.name}.${Date.now()}`;
  const email = `owner.nocar.${stamp}@example.test`;
  const adminEmail = `admin.nocar.${stamp}@example.test`;
  const adminId = randomUUID();
  await sql`insert into local_auth.users (id, email, password_hash) values (${adminId}, ${adminEmail}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${adminId}, ${adminEmail}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${adminId}, 'admin')`;

  // ---------------------------------------------------------------- 1. the account, no car
  await page.goto('/list-your-car/apply', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('label:has-text("An individual")').click();
  await page.locator('#ap-first').fill('Nora');
  await page.locator('#ap-last').fill(phone ? 'Phonenocar' : 'Desknocar');
  await page.locator('#ap-addr').fill('union');
  await page.getByRole('option', { name: /Union Station/ }).click();
  await page.locator('#ap-postal').fill('m5j 1e6');
  await page.locator('#ap-email').fill(email);
  await page.locator('#ap-phone').fill('647-555-0177');
  await page.locator('#ap-lic').fill('N1234-56789-01234');
  await page.locator('#ap-dob').fill('1986-06-06');
  await page.getByRole('button', { name: 'Continue to vehicles' }).click();
  await expect(page.getByTestId('apply-later')).toBeVisible();
  await check(page, 'vehicle step with add later');
  await page.getByTestId('apply-later').click();
  await expect(page.getByTestId('apply-review-later')).toContainText('No car yet');
  await page.locator('#ap-pw').fill(PW);
  await check(page, 'review without a car');
  await page.getByRole('button', { name: 'Open my owner account' }).click();
  await expect(page.getByTestId('apply-done')).toContainText('Your owner account is open', { timeout: 20_000 });

  const [owner] = await sql`select o.id from owners o where o.email = ${email}`;
  expect(owner, 'owner created').toBeTruthy();
  const apps = await sql`select status, vehicle_count from owner_applications where owner_id = ${owner!.id}`;
  expect(apps.map((a) => `${a.status}:${a.vehicle_count}`)).toEqual(['account_only:0']);
  const tasks = await sql`select task_type, status from tasks where owner_id = ${owner!.id} order by created_at`;
  expect(tasks.map((t) => `${t.task_type}:${t.status}`)).toEqual(['owner_signup_no_car:open']);

  // the confirmation link opens the owner portal: "Add your first car"
  const [confirm] = await sql`select link from local_auth.mailbox where to_email = ${email} order by id desc limit 1`;
  if (confirm) {
    await page.goto(new URL(confirm.link as string).pathname + new URL(confirm.link as string).search);
    await page.waitForURL(/\/owner/);
  } else {
    await page.goto('/owner', { waitUntil: 'networkidle' });
  }
  await expect(page.getByTestId('owner-first-car')).toContainText('Add your first car');
  await check(page, 'owner portal without a car');

  // the Admin sees it in Applications
  const ctx = await browser.newContext({ viewport: page.viewportSize()!, baseURL: info.project.use.baseURL });
  const admin = await ctx.newPage();
  await admin.goto(`/sign-in?next=${encodeURIComponent('/admin/applications?status=account_only')}`, { waitUntil: 'networkidle' });
  await acceptCookies(admin);
  await admin.locator('input[type="email"]').fill(adminEmail);
  await admin.locator('input[type="password"]').fill(PW);
  await admin.getByRole('button', { name: 'Sign in' }).click();
  await admin.waitForURL(/\/admin\/applications/);
  await expect(admin.getByTestId('applications')).toContainText(phone ? 'Phonenocar' : 'Desknocar');
  await expect(admin.getByTestId('applications')).toContainText('No car yet');
  await check(admin, 'admin applications, account only');
  await ctx.close();

  // ---------------------------------------------------------------- 2. the first car, from the owner portal
  await page.getByTestId('owner-add-first-car').click();
  await page.waitForURL(/\/list-your-car\/apply/);
  const toVehicles = page.getByRole('button', { name: 'Continue to vehicles' });
  if (await toVehicles.isVisible().catch(() => false)) {
    const lic = page.locator('#ap-lic');
    if (await lic.isVisible().catch(() => false) && !(await lic.inputValue())) await lic.fill('N1234-56789-01234');
    const dob = page.locator('#ap-dob');
    if (await dob.isVisible().catch(() => false) && !(await dob.inputValue())) await dob.fill('1986-06-06');
    await toVehicles.click();
  }
  const id = (k: string) => `#ap-v0-${k}`;
  await page.locator(id('vin')).fill(vin('3FA'));
  await expect(page.getByTestId('apply-ymm')).toBeVisible({ timeout: 20_000 });
  await fillYmm(page, 'apply', { year: '2021', make: 'Ford', model: 'Escape' });
  await tapColour(page, 'apply', 'Blue');
  await page.locator(id('plate')).fill(`NC${String(Date.now()).slice(-5)}`);
  await page.locator(id('odo')).fill('41000');
  await page.locator(id('ins')).fill('Aviva');
  const editor = page.getByTestId('vehicle-editor');
  await editor.locator('label:has-text("Me personally")').click();
  await editor.locator('label:has-text("Owned outright")').click();
  await editor.locator('fieldset:has-text("branded") label:has-text("No")').click();
  await editor.locator('fieldset:has-text("recall") label:has-text("No")').click();
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  const plan = page.getByTestId('plan-vehicle').first();
  await expect(plan.locator('input[name^="ap-method-"]').first()).toBeVisible();
  await plan.locator('label:has-text("Co-Registrant")').click();
  await page.getByRole('button', { name: 'Review' }).click();
  await page.getByRole('button', { name: 'Submit application' }).click();
  await expect(page.getByTestId('apply-done')).toContainText('Application received', { timeout: 20_000 });

  await expect.poll(async () => (await sql`select count(*)::int n from vehicles where owner_id = ${owner!.id}`)[0]!.n).toBe(1);
  const after = await sql`select status from owner_applications where owner_id = ${owner!.id} order by created_at`;
  expect(after.map((a) => a.status)).toEqual(['account_only', 'new']);
  const followUp = await sql`select status from tasks where owner_id = ${owner!.id} and task_type = 'owner_signup_no_car'`;
  expect(followUp[0]!.status).toBe('done');
  expect(errors.filter((e) => !/favicon|Failed to load resource.*404/.test(e)), 'no console errors').toEqual([]);
});
