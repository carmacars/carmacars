import { expect, test, type Page } from '@playwright/test';
import { acceptCookies, watch } from './helpers';

// The car card's photos (src/lib/card-photos.ts, docs/changes/2026-11-06-stale-chunks-car-card-photos.md): a mouse
// resting on a card shows the car's other photos in turn and leaving puts the cover back; a swipe on a phone moves
// through them and does not open the car, a tap still does; under reduced motion nothing cycles. Motion is on here
// (every other test runs with reduced motion, playwright.config.ts).
test.use({ contextOptions: { reducedMotion: 'no-preference' } });

const firstCard = (page: Page) => page.locator('#fleet-grid .car-card:has(.car-card__deck)').first();
const at = (page: Page) => firstCard(page).locator('.car-card__deck').evaluate((d) => (d as HTMLElement).dataset.at ?? '');

test('hover cycles the photos, leaving goes back to the cover; no console error', async ({ page }, ti) => {
  test.skip(ti.project.name !== 'desktop-1440', 'a mouse');
  const errors = watch(page);
  await page.goto('/cars');
  await acceptCookies(page);
  const card = firstCard(page);
  await card.scrollIntoViewIfNeeded();
  const deck = card.locator('.car-card__deck');
  // nothing is downloaded before the first hover
  await expect(deck.locator('img')).toHaveCount(0);
  await card.hover({ position: { x: 60, y: 60 } });
  await expect.poll(() => deck.locator('img').count()).toBeGreaterThan(0);
  await expect(card).toHaveClass(/is-cycling/);
  await expect.poll(() => at(page), { timeout: 5000 }).toBe('1');
  await expect(deck.locator('img.is-on')).toHaveCount(1);
  await expect.poll(() => at(page), { timeout: 5000 }).toBe('2');
  // the photos keep their box: the card is as tall as before
  const h = await card.locator('.car-card__media').evaluate((m) => m.getBoundingClientRect().height);
  expect(await card.locator('.car-card__deck img.is-on').evaluate((i) => Math.round(i.getBoundingClientRect().height))).toBe(Math.round(h));
  await page.mouse.move(2, 2);
  await expect.poll(() => at(page)).toBe('0');
  await expect(deck.locator('img.is-on')).toHaveCount(0);
  await expect(card).not.toHaveClass(/is-cycling/);
  // and the card still opens the car
  await card.locator('.car-card__name a').click();
  await expect(page).toHaveURL(/\/cars\/[a-z0-9-]+/);
  await expect(page.locator('.gallery')).toBeVisible();
  expect(errors).toEqual([]);
});

test('a swipe on a phone moves to the next photo and opens nothing; a tap opens the car', async ({ page }, ti) => {
  test.skip(ti.project.name !== 'phone-375', 'a finger');
  const errors = watch(page);
  await page.goto('/cars');
  await acceptCookies(page);
  const card = firstCard(page);
  await card.scrollIntoViewIfNeeded();
  const m = (await card.locator('.car-card__media').boundingBox())!;
  const y = Math.round(m.y + m.height / 2), x0 = Math.round(m.x + m.width * 0.8), x1 = Math.round(m.x + m.width * 0.15);
  const cdp = await page.context().newCDPSession(page);
  const url = page.url();
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: x0, y }] });
  for (let i = 1; i <= 6; i++) await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x0 + ((x1 - x0) * i) / 6, y }] });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  await expect.poll(() => at(page), { timeout: 5000 }).toBe('1');
  await expect(card).toHaveClass(/is-swiped/);
  await page.waitForTimeout(400);
  expect(page.url()).toBe(url);
  await card.locator('.car-card__name a').tap();
  await expect(page).toHaveURL(/\/cars\/[a-z0-9-]+/);
  expect(errors).toEqual([]);
});

test.describe('reduced motion', () => {
  test.use({ contextOptions: { reducedMotion: 'reduce' } });
  test('hovering a card changes nothing and reads nothing', async ({ page }, ti) => {
    test.skip(ti.project.name !== 'desktop-1440', 'a mouse');
    const errors = watch(page);
    let reads = 0;
    page.on('request', (r) => { if (r.url().includes('vehicle_photos_public')) reads++; });
    await page.goto('/cars');
    await acceptCookies(page);
    const card = firstCard(page);
    await card.scrollIntoViewIfNeeded();
    await card.hover({ position: { x: 60, y: 60 } });
    await page.waitForTimeout(2600);
    await expect(card.locator('.car-card__deck img')).toHaveCount(0);
    await expect(card).not.toHaveClass(/is-cycling/);
    expect(reads).toBe(0);
    expect(errors).toEqual([]);
  });
});
