import { expect, test, type Locator, type Page } from '@playwright/test';
import { acceptCookies, db, watch } from './helpers';

// The car card's photos (src/lib/card-photos.ts, docs/changes/2026-11-06-stale-chunks-car-card-photos.md): a mouse
// resting on a card shows the car's other photos in turn and leaving puts the cover back; a swipe on a phone moves
// through them and does not open the car, a tap still does; under reduced motion nothing cycles. Motion is on here
// (every other test runs with reduced motion, playwright.config.ts).
test.use({ contextOptions: { reducedMotion: 'no-preference' } });

const firstCard = (page: Page) => page.locator('#fleet-grid .car-card:has(.car-card__deck)').first();
// Root cause of the swipe test's flakes (r35): the card arrives with the page's reveal (Effects.tsx: .rv slides it up
// into place over about a second, with motion on as here), and its box was measured while it was still sliding, so the
// finger landed below the photo, pointerdown missed the photo and the swipe was ignored. The box is measured once the
// card is revealed and nothing on it is moving (finite animations only: an endless one would never settle).
async function settled(card: Locator) {
  await expect.poll(() => card.evaluate((el) => (!el.classList.contains('rv') || el.classList.contains('is-in'))
    && el.getAnimations({ subtree: true }).every((a) => a.playState !== 'running' || a.effect?.getComputedTiming().endTime === Infinity)), { timeout: 5000 }).toBe(true);
}
// Where a finger should go on the card's photo, at fractions (fx, fy) of its box: measured only when the photo has kept
// the same box for two animation frames (scrolling, the reveal and late layout all finished), sits inside the screen, and
// the element at that point belongs to this card (not the sticky search bar or another card). Until then the photo is
// scrolled to the middle of the screen again and measured again. Called right before each touch, never reused after one.
async function aim(card: Locator, fx: number, fy: number): Promise<{ x: number; y: number; w: number }> {
  let got: { x: number; y: number; w: number } | null = null;
  await expect.poll(async () => {
    const r = await card.evaluate((el, [fx, fy]) => new Promise<string>((done) => {
      const media = el.querySelector('.car-card__media')!;
      requestAnimationFrame(() => {
        const a = media.getBoundingClientRect();
        requestAnimationFrame(() => {
          const b = media.getBoundingClientRect();
          const x = Math.round(b.left + b.width * fx!), y = Math.round(b.top + b.height * fy!);
          const still = a.left === b.left && a.top === b.top && a.width === b.width && a.height === b.height;
          const onScreen = b.top >= 0 && b.bottom <= innerHeight && b.left >= 0 && b.right <= innerWidth;
          const hit = document.elementFromPoint(x, y);
          if (still && onScreen && hit && el.contains(hit)) done(JSON.stringify({ x, y, w: b.width }));
          else { media.scrollIntoView({ block: 'center' }); done(''); }
        });
      });
    }), [fx, fy]);
    if (r) got = JSON.parse(r) as { x: number; y: number; w: number };
    return !!r;
  }, { message: 'the photo stays still, on screen and uncovered', timeout: 10_000 }).toBe(true);
  return got!;
}
// a click that follows a swipe within this many ms opens nothing (src/lib/card-photos.ts onClick)
const SWIPE_CLICK_MS = 600;
const at = (page: Page) => firstCard(page).locator('.car-card__deck').evaluate((d) => (d as HTMLElement).dataset.at ?? '');

test('hover cycles the photos, leaving goes back to the cover; no console error', async ({ page }, ti) => {
  test.skip(ti.project.name !== 'desktop-1440', 'a mouse');
  const errors = watch(page);
  await page.goto('/cars');
  await acceptCookies(page);
  const card = firstCard(page);
  await card.scrollIntoViewIfNeeded();
  await settled(card);
  const deck = card.locator('.car-card__deck');
  // nothing is downloaded before the first hover
  await expect(deck.locator('img')).toHaveCount(0);
  // the mouse rests on the photo (a person's hand moves a little: so does this one, while the first photos load)
  const m = (await card.locator('.car-card__media').boundingBox())!;
  await page.mouse.move(m.x + 60, m.y + 60);
  await expect.poll(async () => { await page.mouse.move(m.x + 61, m.y + 61); await page.mouse.move(m.x + 60, m.y + 60); return card.getAttribute('class'); }, { timeout: 8000 }).toContain('is-cycling');
  await expect(deck.locator('img').first()).toBeAttached();
  await expect.poll(() => at(page), { timeout: 5000 }).toBe('1');
  await expect(deck.locator('img.is-on')).toHaveCount(1);
  await expect.poll(() => at(page), { timeout: 5000 }).toBe('2');
  // the photos keep their box: the card is as tall as before
  // (layout boxes: the hover's small zoom is a transform and leaves them alone)
  const h = await card.locator('.car-card__media').evaluate((m) => (m as HTMLElement).offsetHeight);
  expect(await card.locator('.car-card__deck img.is-on').evaluate((i) => (i as HTMLElement).offsetHeight)).toBe(h);
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
  // the photo list is a public read: the reads earlier tests made from this address must not have used up its limit
  const sql = db();
  await sql`delete from app.rate_limit_hits`;
  await sql.end();
  const errors = watch(page);
  await page.goto('/cars', { waitUntil: 'networkidle' });
  await acceptCookies(page);
  const card = firstCard(page);
  // the photo in the middle of the screen: scrollIntoViewIfNeeded can leave it under the sticky search bar at the top
  await card.locator('.car-card__media').evaluate((el) => el.scrollIntoView({ block: 'center' }));
  await settled(card);
  // r35: the card used to move between measuring and touching (late layout, a scroll still running); every touch is now
  // aimed right before it is made (aim, above)
  const start = await aim(card, 0.8, 0.5);
  const x1 = Math.round(start.x - start.w * 0.65);
  const cdp = await page.context().newCDPSession(page);
  const url = page.url();
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: start.x, y: start.y }] });
  for (let i = 1; i <= 6; i++) await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: start.x + ((x1 - start.x) * i) / 6, y: start.y }] });
  await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
  const swipedAt = Date.now();
  await expect.poll(() => at(page), { timeout: 5000 }).toBe('1');
  await expect(card).toHaveClass(/is-swiped/);
  expect(page.url()).toBe(url);
  // the tap: past the window in which a click after a swipe is ignored (the earlier tap, 400 ms after the swipe, could
  // fall inside it and open nothing), aimed again, on the photo (the name's link covers the whole card)
  const left = SWIPE_CLICK_MS + 150 - (Date.now() - swipedAt);
  if (left > 0) await page.waitForTimeout(left);
  expect(page.url(), 'the swipe opened nothing').toBe(url);
  const tap = await aim(card, 0.5, 0.5);
  await page.touchscreen.tap(tap.x, tap.y);
  await expect(page).toHaveURL(/\/cars\/[a-z0-9-]+/, { timeout: 20_000 });
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
