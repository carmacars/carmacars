import AxeBuilder from '@axe-core/playwright';
import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, noOverflow, watch } from './helpers';

// The earnings calculator (migration 0354, docs/changes/2026-11-06-owner-earnings-calculator.md): on List your car near
// the top and compact at the start of the application. The car typed in, the owner's month (5141: at 80% occupancy a typical
// car makes the typical month, never under the floor, more when newer or in higher demand), the month and the year that
// follow the sliders, "before fees" while the fees are not set, the cheaper insurance view, axe.

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
  await expect(page.getByTestId('ecalc-monthly')).toBeVisible();
  // 5141: the days start at the occupancy of Program settings (80%: 24 days); a typical car at the typical share makes the
  // typical month (about $1,200), never under the floor ($800)
  await expect(page.getByTestId('ecalc-days-out')).toHaveText('24 days');
  await expect(page.getByTestId('ecalc-share-out')).toHaveText('70%');
  const at18 = await value(page, 'ecalc-monthly');
  expect(at18).toBeGreaterThanOrEqual(800);
  // the year is its twelve months added up over the season; the month shown is their average (whole dollars)
  expect(Math.abs((await value(page, 'ecalc-yearly')) - at18 * 12)).toBeLessThanOrEqual(6);
  await expect(page.getByTestId('ecalc-range')).toContainText(/slow month \((March|April|October|November)\).*busy one \((July|August)\)/);
  await expect(page.getByTestId('ecalc-season').locator('li')).toHaveCount(12);
  // 0344: Apply with this car hands the car and the estimate to the application
  const href = await page.getByTestId('ecalc-apply').getAttribute('href');
  expect(href).toMatch(/^\/list-your-car\/apply\?year=\d{4}&make=Toyota&model=Corolla&est=\d+$/);
  // no fees set in Program settings: none made up
  await expect(page.getByTestId('ecalc-fees')).toHaveText('quoted in your agreement');
  await expect(page.getByTestId('ecalc-result')).toContainText('a month on average, before fees');
  await expect(page.getByTestId('ecalc-disclaimer')).toContainText('A rough estimate, not a promise');
  // 12 days: the month falls with the days, to about half
  await page.getByTestId('ecalc-days').fill('12');
  await expect(page.getByTestId('ecalc-days-out')).toHaveText('12 days');
  await expect.poll(() => value(page, 'ecalc-monthly')).toBeLessThan(at18);
  expect(Math.abs((await value(page, 'ecalc-monthly')) - at18 / 2)).toBeLessThanOrEqual(60);
  // 90% share
  const before = await value(page, 'ecalc-monthly');
  await page.getByTestId('ecalc-share').fill('90');
  await expect(page.getByTestId('ecalc-share-out')).toHaveText('90%');
  await expect.poll(() => value(page, 'ecalc-monthly')).toBeGreaterThan(before);
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
  await expect.poll(() => value(page, 'ecalc-monthly')).toBeGreaterThan(0);
  const r = await new AxeBuilder({ page: page as never }).include('.ecalc--compact').withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']).analyze();
  expect(r.violations.filter((v) => v.impact === 'serious' || v.impact === 'critical').map((v) => v.id)).toEqual([]);
  await noOverflow(page);
  expect(errors).toEqual([]);
});

test('5141: a 2015 Acura RDX earns less than a 2025 Honda CR-V, and is not shown as Premium', async ({ page }) => {
  await page.goto('/list-your-car');
  await acceptCookies(page);
  const root = page.getByTestId('earnings-calculator').first();
  const pick = async (year: string, make: string, model: string) => {
    await root.getByTestId('ecalc-year').selectOption(year);
    // the make list turns into a text box after "Other"
    if ((await root.getByTestId('ecalc-make').evaluate((e) => e.tagName)) === 'SELECT') await root.getByTestId('ecalc-make').selectOption('__other');
    await root.getByTestId('ecalc-make').fill(make);
    await root.getByTestId('ecalc-model').fill(model);
    await expect(page.getByTestId('ecalc-monthly')).toBeVisible();
  };
  await pick('2015', 'Acura', 'RDX');
  await expect(page.getByTestId('ecalc-class')).not.toContainText('Premium');
  const rdx = await value(page, 'ecalc-monthly');
  await pick('2025', 'Honda', 'CR-V');
  await expect.poll(() => value(page, 'ecalc-monthly')).toBeGreaterThan(rdx);
  expect(rdx).toBeGreaterThanOrEqual(800);
});
