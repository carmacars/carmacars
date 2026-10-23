import { expect, test, type Page } from '@playwright/test';
import { noOverflow } from './helpers';

// Migration 0115 end to end (phone 375 and desktop 1440): a new term with its own page, a synonym served with its
// term's page as canonical and kept out of search (rental and /buy), the chauffeur terms taking a request, body repair
// that says it is not mechanical work. Uses the test places of the local stack (scripts/places/fixtures).
const canonical = (page: Page) => page.locator('link[rel="canonical"]').first().getAttribute('href');
const robots = async (page: Page) => ((await page.locator('meta[name="robots"]').count()) ? page.locator('meta[name="robots"]').first().getAttribute('content') : null);

test('new terms: own pages indexable as their tier allows; synonyms point to their term and stay out of search', async ({ page }) => {
  await page.goto('/car-rental/loaner-car/kingston-on');
  await expect(page.locator('h1')).toHaveText('Loaner Car in Kingston');
  expect(await canonical(page)).toMatch(/\/car-rental\/loaner-car\/kingston-on$/);
  await noOverflow(page);

  await page.goto('/car-rental/car-rentals/kingston-on');
  await expect(page.locator('h1')).toHaveText('Car Rentals in Kingston');
  expect(await robots(page)).toMatch(/noindex/);
  expect(await canonical(page)).toMatch(/\/car-rental\/kingston-on$/);

  const r = await page.goto('/buy/car-loan/kingston-on');
  expect(r?.status()).toBe(200);
  expect(await robots(page)).toMatch(/noindex/);
  expect(await canonical(page)).toMatch(/\/buy\/auto-loans\/kingston-on$/);
  await expect(page.locator('body')).toContainText(/do not lend/i);
});

test('chauffeur terms take a request; body repair never promises mechanical work', async ({ page }) => {
  await page.goto('/car-rental/black-car-service/kingston-on');
  await expect(page.locator('h1')).toHaveText('Black Car Service in Kingston');
  await expect(page.locator('body')).toContainText('chauffeur service');
  await expect(page.locator('form').first()).toBeVisible();
  await page.goto('/body-shop/car-repair/kingston-on');
  await expect(page.locator('body')).toContainText('We do not do mechanical work');
  await noOverflow(page);
});
