import { expect, test, type Page } from '@playwright/test';
import { randomBytes, randomUUID, scryptSync } from 'node:crypto';
import { acceptCookies, db } from './helpers';

// Release 43: onboarding approval is visible without expanding anything (the top of Staff and roles, and Admin Today), and a
// people list sorts by recentness with the choice in the address only. Fixtures are example.test.
const PW = 'correct horse battery';
const hash = (pw: string) => { const salt = randomBytes(16); return `scrypt$${salt.toString('base64')}$${scryptSync(pw, salt, 64).toString('base64')}`; };
type Sql = ReturnType<typeof db>;
const tag = () => randomBytes(3).toString('hex');

async function mkAdmin(sql: Sql) {
  const id = randomUUID(); const email = `admin.r43.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, 'Ada Admin')`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'admin')`;
  return { id, email };
}
async function signIn(page: Page, email: string, next: string) {
  await page.goto(`/sign-in?next=${encodeURIComponent(next)}`, { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.locator('input[type="email"]').fill(email);
  await page.locator('input[type="password"]').fill(PW);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL((u) => u.pathname.startsWith(next.split('?')[0]!), { timeout: 20_000 });
}

test('A staff member waiting for onboarding approval is approvable from the top of Staff and roles and from Today', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkAdmin(sql);
  // a Fleet VA who did the academy, the agreement and the WhatsApp groups, and asked to be approved (not exempt, not approved)
  const id = randomUUID(); const email = `fleet.r43.${Date.now()}.${tag()}@example.test`;
  await sql`insert into local_auth.users (id, email, password_hash) values (${id}, ${email}, ${hash(PW)})`;
  await sql`insert into users (id, email, full_name) values (${id}, ${email}, ${`Wanda Waiting ${tag()}`})`;
  await sql`insert into user_roles (user_id, role) values (${id}, 'va')`;
  await sql`insert into staff_profiles (user_id, staff_type, va_function, home_address, home_postal_code, onboarding_exempt, whatsapp_joined, whatsapp_joined_at, onboarding_asked_at)
    values (${id}, 'va', 'fleet', '1 Example Lane, Testville', 'X9X 9X9', false, '{team}', now(), now())`;
  await signIn(page, admin.email, '/admin/settings/staff');
  // the top of the page: visible at once, with the buttons (nothing to expand)
  const top = page.getByTestId('staff-top-approvals');
  await expect(top).toBeVisible();
  await expect(top).toContainText('Waiting for your approval');
  await expect(top.getByTestId(`onboarding-approve-${id}`)).toBeVisible();
  await expect(top.getByTestId(`onboarding-reject-${id}`)).toBeVisible();
  // the person's own row has the button too
  await expect(page.getByTestId(`row-approve-${email}`)).toBeVisible();
  // the anchor the alert can link to
  await page.goto('/admin/settings/staff#onboarding-approvals', { waitUntil: 'networkidle' });
  await expect(page.locator('#onboarding-approvals')).toBeVisible();
  // Admin Today shows the same buttons
  await page.goto('/admin', { waitUntil: 'networkidle' });
  const card = page.getByTestId('today-onboarding-approvals');
  await expect(card).toBeVisible();
  await expect(card.getByTestId(`onboarding-approve-${id}`)).toBeVisible();
  // the hiring pipeline counts them in "Waiting for approval"
  await page.goto('/admin/hiring?tab=stages', { waitUntil: 'networkidle' });
  await expect(page.getByTestId('pipeline-stage-approval')).toContainText('Wanda Waiting');
  // other tests in the suite may leave people waiting too: the count is at least this one
  await expect(page.getByTestId('pipeline-count-approval')).toContainText(/[1-9]/);
  // approve: the card goes away
  await page.goto('/admin', { waitUntil: 'networkidle' });
  page.once('dialog', (d) => void d.accept());
  await card.getByTestId(`onboarding-approve-${id}`).click();
  // this person leaves the card (others in the suite may still be waiting, so the card itself can stay)
  await expect(page.getByTestId(`onboarding-approve-${id}`)).toHaveCount(0, { timeout: 20_000 });
});

test('A people list sorts newest first by default, and by the address: ?sort=oldest, ?sort=az', async ({ page }) => {
  test.setTimeout(120_000);
  const sql = db();
  const admin = await mkAdmin(sql);
  const t = tag();
  const names = [`Sortz Zed ${t}`, `Sortz Mid ${t}`, `Sortz Aaron ${t}`];
  const days = [1, 5, 30]; // days ago: Zed is the newest, Aaron the oldest
  for (let i = 0; i < names.length; i++) {
    const rid = randomUUID(); const e = `sort.r43.${i}.${t}@example.test`;
    await sql`insert into local_auth.users (id, email, password_hash) values (${rid}, ${e}, ${hash(PW)})`;
    await sql`select public.register_account(${rid}, ${e}, ${names[i]!}, null)`;
    // an account is not a renter until their details are on file: make each one a renter, created that many days ago
    await sql`insert into renters (user_id, legal_name, date_of_birth, mobile, email, created_at)
              values (${rid}, ${names[i]!}, '1990-01-01', ${`+1416555${String(1000 + i).slice(-4)}`}, ${e}, now() - make_interval(days => ${days[i]!}))`;
  }
  await signIn(page, admin.email, '/admin/renters');
  const order = async (qs: string) => {
    await page.goto(`/admin/renters?q=${encodeURIComponent(`Sortz`)}${qs}`, { waitUntil: 'networkidle' });
    return (await page.getByTestId('renters').locator('tbody tr td:first-child a:first-child').allInnerTexts()).filter((x) => x.includes(t));
  };
  expect(await order('')).toEqual([names[0], names[1], names[2]]);
  expect(await order('&sort=oldest')).toEqual([names[2], names[1], names[0]]);
  expect(await order('&sort=az')).toEqual([names[2], names[1], names[0]]);
  // the control shows the choice and puts only the sort in the address
  await page.goto(`/admin/renters?q=Sortz&sort=oldest`, { waitUntil: 'networkidle' });
  await expect(page.getByTestId('sort-select').first()).toHaveValue('oldest');
  await page.getByTestId('sort-select').first().selectOption('newest');
  await expect(page).toHaveURL(/sort=newest/);
  expect(page.url()).not.toContain('@');
});
