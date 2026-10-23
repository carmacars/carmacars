import { expect, test } from '@playwright/test';
import { acceptCookies, noOverflow, watch } from './helpers';

// The fleet page's dates and sorting bar folds under its arrow (the owner's request of October 23, 2026): open at the
// top, folded by itself on a phone once the visitor scrolls into the cars, open again back at the top; the arrow folds
// and opens it at any width, by mouse or keyboard.
test('fleet: the dates and filters bar folds and opens under its arrow', async ({ page }, info) => {
  const errors = watch(page);
  const phone = info.project.name.startsWith('phone');
  await page.goto('/cars');
  await acceptCookies(page);
  const fold = page.getByTestId('fleet-fold');
  const sort = page.locator('#fl-sort');
  await expect(page.locator('#fleet-grid .car-card').first()).toBeVisible();

  // open at the top of the page
  await expect(fold).toHaveAttribute('aria-expanded', 'true');
  await expect(fold).toHaveAttribute('aria-controls', 'fleet-options');
  await expect(page.locator('#fleet-options')).toHaveCount(1);
  await expect(fold).toHaveAccessibleName('Hide dates and filters');
  await expect(sort).toBeVisible();

  // the arrow folds it to one line with a summary, and opens it again
  await fold.click();
  await expect(fold).toHaveAttribute('aria-expanded', 'false');
  await expect(sort).toBeHidden();
  await expect(fold).toContainText(/Any dates · Filters · \d+ cars?/);
  await expect(fold).toHaveAccessibleName(/^Show dates and filters/);
  if (!phone) await expect(page.locator('#filter-panel')).toBeHidden(); // the filters column folds with it on a desktop
  await noOverflow(page);
  await fold.click();
  await expect(fold).toHaveAttribute('aria-expanded', 'true');
  await expect(sort).toBeVisible();
  if (!phone) await expect(page.locator('#filter-panel')).toBeVisible();

  // keyboard: a real button, Enter and Space both toggle it
  await fold.focus();
  await page.keyboard.press('Enter');
  await expect(fold).toHaveAttribute('aria-expanded', 'false');
  await page.keyboard.press(' ');
  await expect(fold).toHaveAttribute('aria-expanded', 'true');

  if (phone) {
    // scrolling into the cars folds it by itself; back at the top it opens again
    await page.evaluate(() => window.scrollTo(0, document.getElementById('fleet-grid')!.getBoundingClientRect().top + window.scrollY + 400));
    await expect(fold).toHaveAttribute('aria-expanded', 'false');
    await expect(sort).toBeHidden();
    // the folded bar is one line
    expect((await page.locator('.fleet-bar').boundingBox())!.height).toBeLessThan(64);
    // the arrow still opens it while scrolled down
    await fold.click();
    await expect(sort).toBeVisible();
    await fold.click();
    await expect(sort).toBeHidden();
    await page.evaluate(() => window.scrollTo(0, 0));
    await expect(fold).toHaveAttribute('aria-expanded', 'true');
    await expect(sort).toBeVisible();
  } else {
    // a desktop never folds it by itself
    await page.evaluate(() => window.scrollTo(0, 1200));
    await page.waitForTimeout(300);
    await expect(fold).toHaveAttribute('aria-expanded', 'true');
  }
  expect(errors).toEqual([]);
});
