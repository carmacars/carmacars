import { expect, test } from '@playwright/test';
import { acceptCookies } from './helpers';

// Release 47: on a phone, the menu opened after scrolling down keeps the header (logo and Close) at the top of the
// screen. The menu used to lock scrolling on <body>; with html clipping sideways, body became its own scroll box and
// the sticky header stuck to it, scrolled away with the page (the owner's screenshot, Nov 14).
test('the phone menu opened mid-page keeps the header at the top', async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 760 });
  await page.goto('/cars');
  await acceptCookies(page);
  await page.evaluate(() => window.scrollTo(0, 1600));
  await page.waitForFunction(() => window.scrollY > 800);
  await page.locator('.menu-btn').click();
  await expect(page.locator('#menu')).toHaveClass(/is-open/);
  const box = await page.locator('.site-header').boundingBox();
  expect(Math.round(box?.y ?? -999)).toBe(0);
  await expect(page.locator('.menu-btn')).toBeInViewport();
  await page.locator('.menu-btn').click();
  await expect(page.locator('#menu')).not.toHaveClass(/is-open/);
  expect(await page.evaluate(() => window.scrollY)).toBeGreaterThan(800);
});
