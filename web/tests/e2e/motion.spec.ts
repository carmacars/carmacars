import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, noOverflow, watch } from './helpers';

// The site's motion (src/styles/motion.css, src/components/Effects.tsx, docs/changes/2026-10-21-motion.md). Every
// other test runs with prefers-reduced-motion (playwright.config.ts); these turn motion on and check that it never
// shifts the layout, hides nothing for good, keeps links and steps working, and stays off under reduced motion.
test.use({ reducedMotion: 'no-preference' });

// layout shifts since the page started (the CLS entries without recent input)
const watchShifts = (page: Page) => page.addInitScript(() => {
  (window as unknown as { __cls: number }).__cls = 0;
  new PerformanceObserver((l) => { for (const e of l.getEntries() as unknown as { value: number; hadRecentInput: boolean }[]) if (!e.hadRecentInput) (window as unknown as { __cls: number }).__cls += e.value; })
    .observe({ type: 'layout-shift', buffered: true });
});
const cls = (page: Page) => page.evaluate(() => (window as unknown as { __cls: number }).__cls);

test('motion: reveals below the fold, all shown after scrolling, no layout shift, no console error', async ({ page }) => {
  const errors = watch(page);
  await watchShifts(page);
  await page.goto('/');
  await acceptCookies(page);
  // nothing in the first screen is hidden: the hero heading and the search are shown at once
  await expect(page.locator('.hero h1')).toBeVisible();
  expect(await page.locator('.hero .rv').count()).toBe(0);
  // what is below the viewport waits for the scroll
  await expect.poll(() => page.locator('.rv').count()).toBeGreaterThan(0);
  const below = await page.evaluate(() => Array.from(document.querySelectorAll('.rv')).every((e) => e.getBoundingClientRect().top > innerHeight));
  expect(below).toBe(true);
  // scroll the whole page: everything comes in and the reveal classes are cleaned away
  for (let y = 0; y < 30; y++) { await page.mouse.wheel(0, 700); await page.waitForTimeout(60); }
  await expect.poll(() => page.locator('.rv:not(.is-in)').count(), { timeout: 8000 }).toBe(0);
  await expect.poll(() => page.locator('.rv').count(), { timeout: 8000 }).toBe(0);
  // every lazy image that arrived is shown
  await expect.poll(() => page.locator('img.img-wait').evaluateAll((l) => l.filter((i) => (i as HTMLImageElement).complete).length), { timeout: 8000 }).toBe(0);
  expect(await cls(page)).toBeLessThan(0.01);
  await noOverflow(page);
  expect(errors).toEqual([]);
});

test('motion: a link is a page transition; the next page is shown and works', async ({ page }) => {
  const errors = watch(page);
  await page.goto('/how-it-works');
  await acceptCookies(page);
  await expect(page.locator('.nav-progress')).toHaveCount(1);
  await page.locator('footer a[href="/faq"]').first().click();
  await expect(page).toHaveURL(/\/faq$/);
  await expect(page.locator('h1')).toBeVisible();
  // the transition ends: nothing is left half drawn and the page takes clicks
  await expect.poll(() => page.evaluate(() => getComputedStyle(document.getElementById('main')!).opacity)).toBe('1');
  await expect.poll(() => page.locator('main.page-enter').count(), { timeout: 3000 }).toBe(0);
  await expect(page.locator('.nav-progress.is-on')).toHaveCount(0, { timeout: 16000 });
  await page.goBack();
  await expect(page).toHaveURL(/\/how-it-works$/);
  await expect(page.locator('h1')).toBeVisible();
  expect(errors).toEqual([]);
});

test('motion: float labels sit in the field until it has a value; the error nudges and stays readable', async ({ page }) => {
  const errors = watch(page);
  await page.goto('/sign-in');
  await acceptCookies(page);
  const label = page.locator('.field--float:has(#si-email) > .label');
  const scale = () => label.evaluate((l) => new DOMMatrix(getComputedStyle(l).transform).a);
  expect(await scale()).toBe(1);
  await page.getByLabel('Email').fill('someone@example.com');
  await page.locator('body').click({ position: { x: 5, y: 5 } });
  await expect.poll(scale).toBeLessThan(0.9);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await expect(page.locator('#si-pass-err')).not.toBeEmpty();
  await expect.poll(() => page.locator('#si-pass-err').evaluate((e) => getComputedStyle(e).opacity)).toBe('1');
  expect(errors).toEqual([]);
});

test('motion: the car page photo (the LCP) is never faded or moved at rest', async ({ page }) => {
  const errors = watch(page);
  await page.goto('/cars');
  await acceptCookies(page);
  await page.locator('#fleet-grid .car-card__name a').first().click();
  await expect(page.locator('.gallery')).toBeVisible();
  // the first photo (the LCP) is never faded or moved at rest
  const first = page.locator('.gallery__track img').first();
  await expect.poll(() => first.evaluate((i) => getComputedStyle(i).opacity)).toBe('1');
  expect(await first.evaluate((i) => i.classList.contains('img-wait'))).toBe(false);
  expect(errors).toEqual([]);
});

test.describe('reduced motion', () => {
  test.use({ reducedMotion: 'reduce' });
  test('nothing waits, nothing moves', async ({ page }) => {
    await page.goto('/');
    await acceptCookies(page);
    for (let y = 0; y < 6; y++) { await page.mouse.wheel(0, 900); await page.waitForTimeout(50); }
    expect(await page.locator('.rv, img.img-wait, .nav-progress').count()).toBe(0);
    await page.locator('footer a[href="/faq"]').first().click();
    await expect(page).toHaveURL(/\/faq$/);
    expect(await page.locator('main.page-enter').count()).toBe(0);
  });
});
