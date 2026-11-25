import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, noOverflow } from './helpers';

// R50 hotfix (5064; the owner, Nov 25: "the home pages ... just show the dealership background with no car in it at all.
// And all of the cars are missing from all of the listings, even the sample photos"). With no live studio render (the
// local database has none, as production had none), every card and the home hero still show a car: the photos as before
// release 50, never the empty studio plate. The drive-off is only for a card with its matte.
const PLATE = /coming-soon\.jpg|site\/r48\/plates\//;

async function loaded(page: Page, sel: string) {
  return page.locator(sel).evaluateAll((imgs) => imgs.map((i) => { const im = i as HTMLImageElement; return { src: im.currentSrc || im.src, ok: im.complete && im.naturalWidth > 0 }; }));
}

test('the cards show the car when no matte exists', async ({ page }) => {
  await page.goto('/cars', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const cards = page.locator('.fleet-grid .car-card');
  await expect(cards.first()).toBeVisible();
  const n = Math.min(await cards.count(), 6);
  for (let i = 0; i < n; i++) {
    const card = cards.nth(i);
    await card.scrollIntoViewIfNeeded();
    const img = card.locator('.car-card__slide.is-on img').first();
    await expect(img).toBeVisible();
    await expect.poll(() => img.evaluate((im) => (im as HTMLImageElement).complete && (im as HTMLImageElement).naturalWidth > 0), { timeout: 15_000 }).toBe(true);
    expect(await img.evaluate((im) => (im as HTMLImageElement).currentSrc || (im as HTMLImageElement).src)).not.toMatch(PLATE);
    await expect(card.getByTestId('photos-coming-soon')).toHaveCount(0);
    // no matte: nothing for the drive-off, the photo as it is
    if (!(await card.getAttribute('data-matte'))) await expect(card.getByTestId('card-drive')).toHaveCount(0);
  }
  await noOverflow(page);
});

test('the home hero shows a car, never the empty studio plate', async ({ page }) => {
  await page.goto('/', { waitUntil: 'networkidle' });
  const hero = await loaded(page, '.hero__media img');
  expect(hero.length, 'the hero has a picture').toBeGreaterThan(0);
  expect(hero.some((h) => h.ok && !PLATE.test(h.src)), `hero pictures: ${hero.map((h) => h.src).join(', ')}`).toBe(true);
  await noOverflow(page);
});
