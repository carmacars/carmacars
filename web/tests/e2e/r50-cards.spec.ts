import { expect, test, type Page } from '@playwright/test';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { acceptCookies, db, watch } from './helpers';
import { encodePng } from '../../src/features/listing/subject-frame';
import { matteRgba, studioMatte } from '../../src/features/listing/studio-matte';

// The car cards (release 50, 5030; docs/changes/2026-11-25-r50-car-cards.md, src/lib/card-photos.ts, styles/car-card.css):
// a phone swipes the photos natively and a tap opens the car; a mouse picks photo 1..N by where it is across the photo and
// leaving puts the cover back; the arrow keys on the focused card do the same; a click on a car with its matte drives it
// off and opens the car page; reduced motion: no drive-off. Motion is on here except in the last test.
test.use({ contextOptions: { reducedMotion: 'no-preference' } });

const sql = db();
let car = { id: '', slug: '' };
let wasSample = false;
// serve.mjs serves the local public bucket from .local-storage/vehicle-public (a file added to public/ after the build is a 404)
const PUB = path.join(process.env.LOCAL_STORAGE_DIR ?? path.join(process.cwd(), '.local-storage'), 'vehicle-public');
const SHOTS = ['left', 'front_left', 'front', 'rear_left', 'rear', 'dashboard', 'front_seats', 'rear_seats', 'trunk'];
const BOX = { x: 0.15, y: 0.5, w: 0.7, h: 0.3 };
// a studio render: the plate (a dark room) with a car standing in BOX, the view's name on the wall
const svg = (label: string, withCar = true) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 300 200" width="1800" height="1200">
  <rect width="300" height="200" fill="#282828"/><rect y="160" width="300" height="40" fill="#1c1c1c"/>
  <text x="150" y="50" fill="#bbb" font-size="20" text-anchor="middle" font-family="sans-serif">${label}</text>
  ${withCar ? `<rect x="${BOX.x * 300}" y="${BOX.y * 200}" width="${BOX.w * 300}" height="${BOX.h * 200}" rx="12" fill="#c8c8c8"/>` : ''}</svg>`;

test.beforeAll(async ({}, ti) => {
  // a published car with no studio render of its own gets nine (3701: only renders are shown), and its side render's matte
  const [c] = await sql`select v.id, l.slug, v.is_sample from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
                         where not exists (select 1 from vehicle_photos p where p.vehicle_id = v.id and p.r48) order by l.slug limit 1`;
  car = { id: c!.id as string, slug: c!.slug as string }; wasSample = !!c!.is_sample;
  mkdirSync(path.join(PUB, 'e2e-r50'), { recursive: true }); mkdirSync(path.join(PUB, 'site/cutouts/e2e-r50'), { recursive: true });
  for (const s of SHOTS) writeFileSync(path.join(PUB, `e2e-r50/${s}.svg`), svg(s));
  writeFileSync(path.join(PUB, 'site/cutouts/e2e-r50/left.plate.svg'), svg('left', false));
  // the matte as server/site-cutouts.ts makes it: the render against its plate
  const W = 300, H = 200;
  const plain = () => ({ width: W, height: H, data: new Uint8ClampedArray(W * H * 4).fill(40) });
  const img = plain();
  for (let y = Math.floor(BOX.y * H); y < (BOX.y + BOX.h) * H; y++) for (let x = Math.floor(BOX.x * W); x < (BOX.x + BOX.w) * W; x++) img.data.fill(200, (y * W + x) * 4, (y * W + x) * 4 + 3);
  writeFileSync(path.join(PUB, 'site/cutouts/e2e-r50/left.matte.png'), await encodePng(matteRgba(studioMatte(img, plain(), BOX))));
  await sql`update vehicles set is_sample = false where id = ${car.id}`;
  const gate = sql`jsonb_build_object('state', 'done', 'gate', jsonb_build_object('pass', true, 'spec', app.photo_r48_spec(), 'reasons', '[]'::jsonb))`;
  await sql`insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, r48, ai_generated, plate_status, sort_order, r45, width, height)
            select ${car.id}, a, a, 'e2e-r50/' || a || '.svg', 'e2e-r50/' || a || '.svg', 'approved', true, true, true, 'not_visible', 0, ${gate}, 1800, 1200
              from unnest(${SHOTS}::text[]) a`;
  await sql`update vehicle_photos set is_public = true where vehicle_id = ${car.id} and original_path like 'e2e-r50/%'`;
  await sql`insert into site_cutouts (vehicle_id, shot, source_kind, source_bucket, source_path, path, width, height, facing, made_at, kind, plate_path, box)
            values (${car.id}, 'left', 'studio', 'vehicle-public', 'e2e-r50/left.svg', 'site/cutouts/e2e-r50/left.matte.png', ${W}, ${H}, 'left', now(),
                    'matte', 'site/cutouts/e2e-r50/left.plate.svg', ${sql.json(BOX)})
            on conflict (vehicle_id, shot) do update set path = excluded.path, source_path = excluded.source_path, kind = 'matte', plate_path = excluded.plate_path, box = excluded.box`;
  await sql`select app.listing_cache_refresh(array[${car.id}::uuid])`;
  await rebuild(ti.project.use.baseURL);
});
test.afterAll(async ({}, ti) => {
  if (car.id) {
    await sql`delete from vehicle_photos where vehicle_id = ${car.id} and original_path like 'e2e-r50/%'`;
    await sql`delete from site_cutouts where vehicle_id = ${car.id}`;
    await sql`update vehicles set is_sample = ${wasSample} where id = ${car.id}`;
    await sql`select app.listing_cache_refresh(array[${car.id}::uuid])`;
    await rebuild(ti.project.use.baseURL);
  }
  await sql.end();
});
async function rebuild(baseURL?: string) {
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
// the photo's box once it has stopped moving (the reveal, a smooth scroll to the card)
async function box(page: Page) {
  const media = cardOf(page).locator('.car-card__media');
  let prev = '';
  let got = (await media.boundingBox())!;
  await expect.poll(async () => { got = (await media.boundingBox())!; const k = JSON.stringify(got); const same = k === prev; prev = k; return same; }, { intervals: [150], timeout: 10_000 }).toBe(true);
  return got;
}
async function openCars(page: Page) {
  await page.goto('/cars');
  await acceptCookies(page);
  const c = cardOf(page);
  await expect(c).toHaveAttribute('data-n', /[2-5]/, { timeout: 15_000 });
  await c.evaluate((e) => e.scrollIntoView({ block: 'center' }));
  await expect.poll(() => c.evaluate((el) => !el.classList.contains('rv') || el.classList.contains('is-in'))).toBe(true);
  return c;
}

test.describe('a mouse', () => {
  test.beforeEach(({}, ti) => { test.skip(ti.project.name !== 'desktop-1440', 'a mouse'); });

  test('the photo under the pointer, the dots follow, leaving goes back to the cover; arrow keys too', async ({ page }) => {
    const errors = watch(page);
    const c = await openCars(page);
    const n = Number(await c.getAttribute('data-n'));
    // nothing after the cover loads with the page
    await expect(c.locator('.car-card__slide img')).toHaveCount(1);
    const m = (await box(page));
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
    expect(errors).toEqual([]);
  });

  test('a click drives the car off and opens its page at once', async ({ page }) => {
    const c = await openCars(page);
    await expect(c).toHaveAttribute('data-matte', /e2e-r50\/left\.matte\.png$/);
    const m = (await box(page));
    await page.mouse.move(m.x + m.width / 2, m.y + m.height / 2);
    await expect(c).toHaveAttribute('data-drive', 'ready', { timeout: 8000 });
    // the animations that start are recorded in the page as they do (the drive-off lasts 620 ms and the car page starts 140 ms in:
    // asking the page afterwards, a round trip later, finds them finished or the page gone)
    const seen: string[] = [];
    await page.exposeFunction('__driveSeen', (n: string) => { seen.push(n); });
    await c.evaluate((e) => e.addEventListener('animationstart', (ev) => (window as unknown as { __driveSeen: (n: string) => void }).__driveSeen((ev as AnimationEvent).animationName), true));
    const t0 = Date.now();
    await page.mouse.click(m.x + m.width / 2, m.y + m.height / 2);
    await expect.poll(() => seen, { intervals: [20], timeout: 5000 }).toEqual(expect.arrayContaining(['car-drive-x', 'car-drive-y', 'car-drive-squat', 'car-drive-floor']));
    await page.waitForURL(new RegExp(`/cars/${car.slug}`), { timeout: 15_000 });
    expect(Date.now() - t0).toBeLessThan(15_000);
  });
});

test.describe('a phone', () => {
  test.beforeEach(({}, ti) => { test.skip(ti.project.name !== 'phone-375', 'a finger'); });
  test.use({ isMobile: true, hasTouch: true, viewport: { width: 390, height: 844 } });

  // a finger: down, twelve moves a frame apart, up (the browser decides the pan's direction, as on a phone)
  const gesture = async (page: Page, x: number, y: number, dx: number, dy: number) => {
    const cdp = await page.context().newCDPSession(page);
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x, y, id: 1 }] });
    for (let k = 1; k <= 12; k++) {
      await cdp.send('Input.dispatchTouchEvent', { type: 'touchMove', touchPoints: [{ x: x + (dx * k) / 12, y: y + (dy * k) / 12, id: 1 }] });
      await page.waitForTimeout(16);
    }
    await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] });
    await cdp.detach();
  };

  test('a swipe moves one photo with the dots, a page scroll is never taken, a tap opens the car', async ({ page }) => {
    const errors = watch(page);
    const c = await openCars(page);
    const track = c.locator('.car-card__track');
    expect(await track.evaluate((t) => getComputedStyle(t).scrollSnapType)).toContain('x mandatory');
    // the second photo is on its way before the first swipe
    await expect(c.locator('.car-card__slide').nth(1).locator('img')).toHaveCount(1, { timeout: 8000 });
    const m = (await box(page));
    await gesture(page, m.x + m.width * 0.9, m.y + m.height / 2, -m.width * 0.75, 0);
    await expect.poll(() => onIndex(page), { timeout: 5000 }).toBe(1);
    expect(await track.evaluate((t) => Math.round(t.scrollLeft / t.clientWidth))).toBe(1);
    expect(page.url()).toMatch(/\/cars$/);
    // a vertical scroll on the photo scrolls the page, not the photos
    const y0 = await page.evaluate(() => scrollY);
    const m2 = (await box(page));
    await gesture(page, m2.x + m2.width / 2, m2.y + m2.height / 2, 6, -200);
    await expect.poll(() => page.evaluate(() => scrollY)).toBeGreaterThan(y0 + 50);
    expect(await onIndex(page)).toBe(1);
    // a tap opens the car
    await c.evaluate((e) => e.scrollIntoView({ block: 'center' }));
    const m3 = (await box(page));
    await page.touchscreen.tap(m3.x + m3.width / 2, m3.y + m3.height / 2);
    await page.waitForURL(new RegExp(`/cars/${car.slug}`), { timeout: 15_000 });
    expect(errors).toEqual([]);
  });
});

test.describe('reduced motion', () => {
  test.use({ contextOptions: { reducedMotion: 'reduce' } });
  test('no drive-off: a click opens the car at once; the photos still change', async ({ page }, ti) => {
    test.skip(ti.project.name !== 'desktop-1440', 'a mouse');
    const c = await openCars(page);
    const m = (await box(page));
    const n = Number(await c.getAttribute('data-n'));
    await page.mouse.move(m.x + m.width - 4, m.y + m.height / 3);
    await expect.poll(() => onIndex(page), { timeout: 8000 }).toBe(n - 1);
    await expect(c.locator('.car-drive')).toHaveCount(0);
    await page.mouse.click(m.x + m.width / 2, m.y + m.height / 2);
    await page.waitForURL(new RegExp(`/cars/${car.slug}`), { timeout: 15_000 });
  });
});
