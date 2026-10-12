import { expect, test } from '@playwright/test';
import { acceptCookies, db } from './helpers';

test('create an account, sign out, sign in, reset the password by email', async ({ page }, info) => {
  const email = `account.${info.project.name}.${Date.now()}@example.test`;
  await page.goto('/create-account');
  await acceptCookies(page);
  await page.locator('#su-name').fill('Riley Renter');
  await page.locator('#su-email').fill(email);
  await page.locator('#su-pass').fill('short');
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('Use at least 8 characters.')).toBeVisible();
  await page.locator('#su-pass').fill('correct horse battery');
  await page.locator('input[name="agree"]').check();
  await page.getByRole('button', { name: 'Create account' }).click();
  await page.waitForURL(/\/account/);
  await expect(page.getByTestId('account-email')).toHaveText(email);
  const sql = db();
  const u = await sql`select u.id, r.role::text from users u join user_roles r on r.user_id = u.id where u.email = ${email}`;
  expect(u[0]?.role).toBe('renter');
  // sign out and back in
  await page.getByRole('button', { name: 'Sign out' }).click();
  await page.waitForURL((url) => url.pathname === '/');
  await page.goto('/sign-in');
  await page.locator('#si-email').fill(email);
  await page.locator('#si-pass').fill('wrong password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.getByText('That email and password do not match an account.')).toBeVisible();
  await page.locator('#si-pass').fill('correct horse battery');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.waitForURL(/\/account/);
  await expect(page.getByTestId('account-email')).toHaveText(email);
  // reset by email (the local stand-in for Supabase Auth keeps the email in local_auth.mailbox)
  await page.getByRole('button', { name: 'Sign out' }).click();
  await page.goto('/reset-password');
  await page.locator('#rp-email').fill(email);
  await page.getByRole('button', { name: 'Send the link' }).click();
  await expect(page.getByText('Check your email')).toBeVisible();
  const m = await sql`select link from local_auth.mailbox where to_email = ${email} order by id desc limit 1`;
  await sql.end();
  expect(m[0]?.link).toContain('/update-password?token=');
  await page.goto(new URL(m[0]!.link as string).pathname + new URL(m[0]!.link as string).search);
  await page.locator('#np-pass').fill('a brand new password');
  await page.getByRole('button', { name: 'Save the new password' }).click();
  await page.waitForURL(/\/account/);
  await expect(page.getByText('Password saved')).toBeVisible();
});

test('the account page needs a session', async ({ page }) => {
  await page.goto('/account');
  await page.waitForURL(/\/sign-in\?next=%2Faccount|\/sign-in\?next=\/account/);
});
