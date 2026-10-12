import AxeBuilder from '@axe-core/playwright';
import { expect, test } from '@playwright/test';
import { noOverflow, PUBLIC_PAGES, watch } from './helpers';

// Every public page: renders with status 200, one h1, a title and description, no console errors,
// no horizontal overflow, and no serious or critical accessibility issue (axe, WCAG 2.1 AA).
for (const path of PUBLIC_PAGES) {
  test(`page ${path}`, async ({ page }) => {
    const errors = watch(page);
    const res = await page.goto(path, { waitUntil: 'load' });
    expect(res?.status()).toBe(200);
    await page.waitForTimeout(500);
    await expect(page.locator('h1')).toHaveCount(1);
    expect((await page.title()).length).toBeGreaterThan(5);
    await expect(page.locator('meta[name="description"]')).toHaveAttribute('content', /.{20,}/);
    await noOverflow(page);
    const axe = await new AxeBuilder({ page: page as never }).withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
    const bad = axe.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical');
    expect(bad.map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
    expect(errors).toEqual([]);
  });
}

test('unknown address shows the styled 404 with status 404', async ({ page }) => {
  const res = await page.goto('/no-such-page');
  expect(res?.status()).toBe(404);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Wrong turn.');
});

test('an unknown car is a 404', async ({ page }) => {
  const res = await page.goto('/cars/no-such-car');
  expect(res?.status()).toBe(404);
});
