import { expect, test } from '@playwright/test';
import { randomBytes } from 'node:crypto';
import { acceptCookies, noOverflow } from './helpers';

// Guide me for renters (migration 4100): on the public sign-up page, a visitor opens Guide me, sees the page's own
// workflow first, and is walked through creating an account. A step to do does not pass on Next; typing moves it on;
// the card never covers the primary button it is not pointing at, and the page fits the phone.
test('Guide me walks a new renter through creating an account', async ({ page }) => {
  test.setTimeout(120_000);
  await page.goto('/create-account', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await expect(page.getByTestId('guide-me-card')).toHaveCount(0);
  await page.getByTestId('guide-me-open').click();
  // this page's workflow is listed first
  await expect(page.getByTestId('guide-me-here').getByTestId('guide-me-start-renter-signup')).toBeVisible();
  await page.getByTestId('guide-me-start-renter-signup').click();

  const card = page.getByTestId('guide-me-card');
  await expect(card).toHaveAttribute('data-step', 'name');
  await expect(page.getByTestId('guide-me-progress')).toHaveText('Step 1 of 5');
  await expect(page.getByTestId('guide-me-next')).toBeDisabled();
  await noOverflow(page);

  await page.locator('#su-name').fill('Riley Guided');
  await expect(card).toHaveAttribute('data-step', 'email');
  await page.locator('#su-email').fill(`riley.guided.${Date.now()}.${randomBytes(2).toString('hex')}@example.test`);
  await expect(card).toHaveAttribute('data-step', 'password');
  await page.locator('#su-pass').fill('correct horse battery');
  await expect(card).toHaveAttribute('data-step', 'agree');
  // the card is not over the Create account button while it points elsewhere
  const btn = await page.getByRole('button', { name: 'Create account' }).boundingBox();
  const cb = await card.boundingBox();
  if (btn && cb) expect(btn.x < cb.x + cb.width && cb.x < btn.x + btn.width && btn.y < cb.y + cb.height && cb.y < btn.y + btn.height).toBe(false);
  await page.locator('input[name="agree"]').check();
  await expect(card).toHaveAttribute('data-step', 'create');
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('Check your email')).toBeVisible({ timeout: 20_000 });
  await expect(page.getByTestId('guide-me-done')).toContainText('Create your account: all done.');
});
