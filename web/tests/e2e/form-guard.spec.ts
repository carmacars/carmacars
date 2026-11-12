import { expect, test } from '@playwright/test';
import { acceptCookies } from './helpers';

// The form guard (r40-forms, src/lib/forms/guard-dom.ts): when a form cannot be sent, the person sees a summary of what is
// missing, each such field outlined with a message, and the focus in the first one. One mechanism for every form; checked on
// the contact form (its own field errors) and on the first step of the list-your-car application (a wizard step).
test('contact form: an empty send lists what is missing, marks the fields and focuses the first', async ({ page }) => {
  await page.goto('/contact', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.getByRole('button', { name: 'Send message' }).click();
  const summary = page.locator('form[aria-label="Send us a message"] .fg-summary');
  await expect(summary).toBeVisible();
  await expect(summary).toContainText('Fix these');
  await expect(summary.locator('a[data-fg-go]').first()).toBeVisible();
  const name = page.locator('#ct-name');
  await expect(name).toHaveAttribute('aria-invalid', 'true');
  await expect(name).toBeFocused();
  // the summary links go to the field
  await summary.locator('a[data-fg-go]').last().click();
  await expect(page.locator('#ct-msg')).toBeFocused();
  // fixing a field takes it off the list
  const before = await summary.locator('li').count();
  await name.fill('Alex Example');
  await expect(summary.locator('li')).toHaveCount(before - 1);
  await expect(name).not.toHaveAttribute('aria-invalid', 'true');
});

test('list your car: the first step says what is missing and puts the focus on it', async ({ page }) => {
  await page.goto('/list-your-car/apply', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  await page.getByTestId('apply-start-next').click();
  const summary = page.locator('.fg-summary');
  await expect(summary).toBeVisible();
  await expect(summary).toContainText(/first name/i);
  await expect(page.locator('#ap-s-first')).toHaveAttribute('aria-invalid', 'true');
  await expect(page.locator('#ap-s-first')).toBeFocused();
  await expect(page.locator('#ap-s-first-err')).toContainText('first name');
});
