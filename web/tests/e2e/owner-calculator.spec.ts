import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, noOverflow, watch } from './helpers';

// The earnings calculator (migration 0354, docs/changes/2026-11-06-owner-earnings-calculator.md): on List your car near
// the top and compact at the start of the application. The car typed in, the rate from the cars on the site, the month
// and the year that follow the sliders, "before fees" while the fees are not set, the cheaper insurance view, axe.

async function pickCar(page: Page, root = page.getByTestId('earnings-calculator').first()) {
  await root.getByTestId('ecalc-year').selectOption({ index: 3 });
  await root.getByTestId('ecalc-make').selectOption('__other');
  await root.getByTestId('ecalc-make').fill('Toyota');
  await root.getByTestId('ecalc-model').fill('Corolla');
}
const value = async (page: Page, id: string) => Number(await page.getByTestId(id).first().getAttribute('data-value'));

test('List your car: the month and the year from the car, the days and the share; before fees; axe', async ({ page }) => {
  const errors = watch(page);
  await page.goto('/list-your-car');
  await acceptCookies(page);
  const calc = page.getByTestId('earnings-calculator');
  await expect(calc).toBeVisible();
  await expect(calc.getByTestId('ecalc-result')).toContainText('Pick your car');
  await pickCar(page);
  await expect(page.getByTestId('ecalc-month')).toBeVisible();
  await expect(page.getByTestId('ecalc-days-out')).toHaveText('18 days');
  await expect(page.getByTestId('ecalc-share-out')).toHaveText('70%');
  const at18 = await value(page, 'ecalc-month');
  expect(at18).toBeGreaterThan(0);
  expect(await value(page, 'ecalc-year')).toBe(at18 * 12);
  // no fees set in Program settings: none made up
  await expect(page.getByTestId('ecalc-fees')).toHaveText('quoted in your agreement');
  await expect(page.getByTestId('ecalc-result')).toContainText('a month, before fees');
  await expect(page.getByTestId('ecalc-result')).toContainText('An estimate, not a promise');
  // 28 days: the month grows with the days (to the dollar, after rounding)
  await page.getByTestId('ecalc-days').fill('28');
  await expect(page.getByTestId('ecalc-days-out')).toHaveText('28 days');
  await expect.poll(() => value(page, 'ecalc-month')).toBeGreaterThan(at18);
  expect(Math.abs((await value(page, 'ecalc-month')) - Math.round((at18 * 28) / 18))).toBeLessThanOrEqual(2);
  // 90% share
  const before = await value(page, 'ecalc-month');
  await page.getByTestId('ecalc-share').fill('90');
  await expect(page.getByTestId('ecalc-share-out')).toHaveText('90%');
  await expect.poll(() => value(page, 'ecalc-month')).toBeGreaterThan(before);
  // just cheaper insurance: the fleet policy's fee (quoted while not set) and the share at a few days a month
  await page.getByTestId('ecalc-insurance').check();
  await expect(page.getByTestId('ecalc-insurance-box')).toContainText('the insurance fee is quoted in your agreement');
  await expect(page.getByTestId('ecalc-low')).toBeVisible();
  const r = await new AxeBuilder({ page: page as never }).include('[data-testid="earnings-calculator"]').withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => `${v.id}: ${v.nodes.map((n) => n.target.join(' ')).slice(0, 3).join(', ')}`)).toEqual([]);
  await noOverflow(page);
  expect(errors).toEqual([]);
});

test('the application starts with the compact calculator, its numbers read in the browser', async ({ page }) => {
  const errors = watch(page);
  await page.goto('/list-your-car/apply');
  await acceptCookies(page);
  const calc = page.locator('.ecalc--compact');
  await expect(calc).toBeVisible();
  await expect(calc.getByTestId('ecalc-result')).toContainText('Pick your car', { timeout: 15_000 });
  await pickCar(page, calc);
  await expect.poll(() => value(page, 'ecalc-month')).toBeGreaterThan(0);
  const r = await new AxeBuilder({ page: page as never }).include('.ecalc--compact').withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id)).toEqual([]);
  await noOverflow(page);
  expect(errors).toEqual([]);
});
