import { expect, test, type Page } from '@playwright/test';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, studioCar, watch } from './helpers';
import { encodePng } from '../../src/features/listing/subject-frame';
import { matteRgba, studioMatte } from '../../src/features/listing/studio-matte';

// The car cards (release 50, 5030; docs/changes/2026-11-25-r50-car-cards.md, src/lib/card-photos.ts, styles/car-card.css):
// a phone swipes the photos natively and a tap opens the car; a mouse picks photo 1..N by where it is across the photo and
// leaving puts the cover back; the arrow keys on the focused card do the same; a click on a car with its matte drives it
// off and opens the car page; reduced motion: no drive-off. Motion is on here except in the last test.
test.use({ contextOptions: { reducedMotion: 'no-preference' } });

const sql = db();
let car = { id: '', slug: '' };
let restore: (() => Promise<void>) | null = null;
const PUB = path.join(process.cwd(), 'public/_local/vehicle-public');

test.beforeAll(async ({}, ti) => {
  const s = await studioCar(sql, 1, undefined);
  car = { id: s.id, slug: s.slug }; restore = s.restore;
  // the side render's matte and plate, as server/site-cutouts.ts makes them (a car shape against a plain plate)
  const W = 300, H = 200, box = { x: 0.15, y: 0.5, w: 0.7, h: 0.3 };
  const plain = () => ({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4).fill(40) });
  const img = plain();
  for (let y = Math.floor(box.y * H); y < (box.y + box.h) * H; y++) for (let x = Math.floor(box.x * W); x < (box.x + box.w) * W; x++) img.data.fill(200, (y * W + x) * 4, (y * W + x) * 4 + 3);
  const png = await encodePng(matteRgba(studioMatte(img, plain(), box)));
  mkdirSync(path.join(PUB, 'site/cutouts/e2e'), { recursive: true });
  writeFileSync(path.join(PUB, 'site/cutouts/e2e/left.matte.png'), png);
  const [side] = await sql`select processed_path from vehicle_photos where vehicle_id = ${car.id} and r48 and shot_type = 'left' and replaced_at is null limit 1`;
  writeFileSync(path.join(PUB, 'site/cutouts/e2e/left.plate.svg'), readFileSync(path.join(PUB, side!.processed_path as string)));
  await sql`insert into site_cutouts (vehicle_id, shot, source_kind, source_bucket, source_path, path, width, height, facing, made_at, kind, plate_path, box)
            values (${car.id}, 'left', 'studio', 'vehicle-public', ${side!.processed_path as string}, 'site/cutouts/e2e/left.matte.png', ${W}, ${H}, 'left', now(),
                    'matte', 'site/cutouts/e2e/left.plate.svg', ${sql.json(box)})
            on conflict (vehicle_id, shot) do update set path = excluded.path, source_path = excluded.source_path, kind = 'matte', plate_path = excluded.plate_path, box = excluded.box`;
  await sql`select app.listing_cache_refresh(array[${car.id}::uuid])`;
  await studioRebuild(ti.project.use.baseURL);
});
test.afterAll(async () => { if (restore) await restore(); await sql.end(); });
async function studioRebuild(baseURL?: string) {
  if (!baseURL) return;
  const { createHmac } = await import('node:crypto');
  const env = readFileSync(path.join(process.cwd(), '.env.local'), 'utf8');
  const token = createHmac('sha256', /^LINK_SIGNING_KEY=(.*)$/m.exec(env)![1]!.trim()).update('carmacars-listing-worker-v1').digest('hex');
  const r = await (await import('@playwright/test')).request.newContext({ baseURL });
  await r.post('/api/jobs/public-rebuild', { headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, data: {} });
  await r.dispose();
}

const cardOf = (page: Page) => page.locator(`.car-card[data-slug="${car.slug}"]`).first();
const onIndex = (page: Page) => cardOf(page).locator('.car-card__dots > i').evaluateAll((ds) => ds.findIndex((d) => d.classList.contains('is-on')));
async function openCars(page: Page) {
  await page.goto('/cars');
  await acceptCookies(page);
  const c = cardOf(page);
  await expect(c).toHaveAttribute('data-n', /[2-5]/, { timeout: 15_000 });
  await c.scrollIntoViewIfNeeded();
  await expect.poll(() => c.evaluate((el) => !el.classList.contains('rv') || el.classList.contains('is-in'))).toBe(true);
  return c;
}

test.describe('a mouse', () => {
  test.skip(({}, ti) => ti.project.name !== 'desktop-1440', 'a mouse');

  test('the photo under the pointer, the dots follow, leaving goes back to the cover; arrow keys too', async ({ page }) => {
    const errors = watch(page);
    const c = await openCars(page);
    const n = Number(await c.getAttribute('data-n'));
    // nothing after the cover loads with the page
    await expect(c.locator('.car-card__slide img')).toHaveCount(1);
    const m = (await c.locator('.car-card__media').boundingBox())!;
    const y = m.y + m.height * 0.3;
    await page.mouse.move(m.x + 4, y);
    await expect(c.locator('.car-card__slide img')).toHaveCount(n, { timeout: 8000 });
    for (const i of [n - 1, 1, 0, n - 1]) {
      await page.mouse.move(m.x + (m.width * (i + 0.5)) / n, y);
      await expect.poll(() => onIndex(page)).toBe(i);
      await expect(c.locator('.car-card__slide.is-on')).toHaveCount(1);
      expect(await c.locator('.car-card__slide').nth(i).evaluate((s) => s.classList.contains('is-on'))).toBe(true);
    }
    await page.mouse.move(2, 2);
    await expect.poll(() => onIndex(page)).toBe(0);
    // the keyboard: the focused card's link, the arrow keys
    await c.locator('.car-card__name a').focus();
    await page.keyboard.press('ArrowRight');
    await expect.poll(() => onIndex(page)).toBe(1);
    await page.keyboard.press('ArrowLeft');
    await expect.poll(() => onIndex(page)).toBe(0);
    await page.keyboard.press('ArrowLeft');
    await expect.poll(() => onIndex(page)).toBe(0);
    expect(errors()).toEqual([]);
  });

  test('a click drives the car off and opens its page at once', async ({ page }) => {
    const c = await openCars(page);
    await expect(c).toHaveAttribute('data-matte', /left\.matte\.png$/);
    const m = (await c.locator('.car-card__media').boundingBox())!;
    await page.mouse.move(m.x + m.width / 2, m.y + m.height / 2);
    await expect(c).toHaveAttribute('data-drive', 'ready', { timeout: 8000 });
    const t0 = Date.now();
    await page.mouse.click(m.x + m.width / 2, m.y + m.height / 2);
    await expect(c).toHaveClass(/is-driving/);
    // the car's layers: the plate, the floor fading, the car through the matte, moving with transforms only
    const anims = await c.locator('.car-drive').evaluate((d) => d.getAnimations({ subtree: true }).map((a) => (a as CSSAnimation).animationName));
    expect(anims).toEqual(expect.arrayContaining(['car-drive-x', 'car-drive-y', 'car-drive-squat', 'car-drive-floor']));
    await page.waitForURL(new RegExp(`/cars/${car.slug}`), { timeout: 15_000 });
    expect(Date.now() - t0).toBeLessThan(15_000);
  });
});

test.describe('a phone', () => {
  test.skip(({}, ti) => ti.project.name !== 'phone-375', 'a finger');
  test.use({ isMobile: true, hasTouch: true, viewport: { width: 390, height: 844 } });

  const gesture = async (page: Page, x: number, y: number, dx: number, dy: number) => {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Input.synthesizeScrollGesture', { x, y, xDistance: dx, yDistance: dy, gestureSourceType: 'touch', speed: 1200, preventFling: false });
    await cdp.detach();
  };

  test('a swipe moves one photo with the dots, a page scroll is never taken, a tap opens the car', async ({ page }) => {
    const errors = watch(page);
    const c = await openCars(page);
    const track = c.locator('.car-card__track');
    expect(await track.evaluate((t) => getComputedStyle(t).scrollSnapType)).toContain('x mandatory');
    // the second photo is on its way before the first swipe
    await expect(c.locator('.car-card__slide').nth(1).locator('img')).toHaveCount(1, { timeout: 8000 });
    const m = (await c.locator('.car-card__media').boundingBox())!;
    await gesture(page, m.x + m.width * 0.7, m.y + m.height / 2, -m.width * 0.5, 0);
    await expect.poll(() => onIndex(page), { timeout: 5000 }).toBe(1);
    expect(await track.evaluate((t) => Math.round(t.scrollLeft / t.clientWidth))).toBe(1);
    expect(page.url()).toMatch(/\/cars$/);
    // a vertical scroll on the photo scrolls the page, not the photos
    const y0 = await page.evaluate(() => scrollY);
    const m2 = (await c.locator('.car-card__media').boundingBox())!;
    await gesture(page, m2.x + m2.width / 2, m2.y + m2.height / 2, 0, -200);
    await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(y0 + 50);
    expect(await onIndex(page)).toBe(1);
    // a tap opens the car
    await c.scrollIntoViewIfNeeded();
    const m3 = (await c.locator('.car-card__media').boundingBox())!;
    await page.touchscreen.tap(m3.x + m3.width / 2, m3.y + m3.height / 2);
    await page.waitForURL(new RegExp(`/cars/${car.slug}`), { timeout: 15_000 });
    expect(errors()).toEqual([]);
  });
});

test.describe('reduced motion', () => {
  test.use({ contextOptions: { reducedMotion: 'reduce' } });
  test('no drive-off: a click opens the car at once; the photos still change', async ({ page }, ti) => {
    test.skip(ti.project.name !== 'desktop-1440', 'a mouse');
    const c = await openCars(page);
    const m = (await c.locator('.car-card__media').boundingBox())!;
    const n = Number(await c.getAttribute('data-n'));
    await page.mouse.move(m.x + m.width - 4, m.y + m.height / 3);
    await expect.poll(() => onIndex(page), { timeout: 8000 }).toBe(n - 1);
    await expect(c.locator('.car-drive')).toHaveCount(0);
    await page.mouse.click(m.x + m.width / 2, m.y + m.height / 2);
    await page.waitForURL(new RegExp(`/cars/${car.slug}`), { timeout: 15_000 });
  });
});
