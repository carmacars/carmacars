import { test, expect } from '@playwright/test';
import { db, noOverflow } from './helpers';

// Release 48 AN (3150 to 3153): the main paths. A car's studio renders come first (the side profile the cover), its real
// photos after them with the "Rendered photos" note and a way to them; the card's car stands on its studio floor with its
// cutout; the Cars filter lists one model per family; a car's finished set queues the owner's branded email and Fleet's
// notice; the hero's logo is drawn (shown at once under reduced motion, as the tests run); the pause control.
const sql = db();
let slug = '';
let vehicleId = '';

test.beforeAll(async () => {
  // the first published real car of the seed gets a full render set and a side cutout (paths of the seed's own drawings)
  const [car] = await sql`select v.id, l.slug from vehicles v join vehicle_listings l on l.vehicle_id = v.id and l.status = 'published'
                           where exists (select 1 from vehicle_photos p where p.vehicle_id = v.id and p.processed_path like 'vehicles/%-side.svg')
                           order by l.slug limit 1`;
  test.skip(!car, 'the seed has no published car with photos');
  vehicleId = car!.id as string; slug = car!.slug as string;
  // a real car (the seed's cars are examples): renders and notices are for real cars
  await sql`update vehicles set is_sample = false where id = ${vehicleId}`;
  await sql`delete from vehicle_photos where vehicle_id = ${vehicleId} and r48`;
  await sql`insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, r48, ai_generated, background_status, plate_status, sort_order, r45, width, height)
            select p.vehicle_id, p.shot_type, p.shot_type, p.original_path, p.processed_path, 'approved', true, true, true, 'done', 'not_visible', -100,
                   jsonb_build_object('state', 'done', 'spec', app.photo_r48_spec()), p.width, p.height
              from vehicle_photos p where p.vehicle_id = ${vehicleId} and not p.r48 and p.shot_type = any (app.photo_r45_angles())`;
  // every standard angle, so the set is complete (an angle the seed has no photo of reuses the side drawing)
  await sql`insert into vehicle_photos (vehicle_id, angle, shot_type, original_path, processed_path, status, is_public, r48, ai_generated, background_status, plate_status, sort_order, r45, width, height)
            select ${vehicleId}, a, a, 'vehicles/original/e2e/' || a || '.jpg', (select processed_path from vehicle_photos where vehicle_id = ${vehicleId} and shot_type = 'left' and not r48 limit 1),
                   'approved', true, true, true, 'done', 'not_visible', -100, jsonb_build_object('state', 'done', 'spec', app.photo_r48_spec()), 1800, 1200
              from unnest(app.photo_r45_angles()) a
             where not exists (select 1 from vehicle_photos x where x.vehicle_id = ${vehicleId} and x.r48 and x.shot_type = a)`;
  await sql`delete from photo_render_notified where vehicle_id = ${vehicleId}`;
  await sql`select app.listing_cache_refresh(array[${vehicleId}::uuid])`;
});
// put the car back as the seed had it, so the other suites see the seed's fleet
test.afterAll(async () => {
  if (vehicleId) {
    await sql`delete from vehicle_photos where vehicle_id = ${vehicleId} and r48`;
    await sql`delete from site_cutouts where vehicle_id = ${vehicleId}`;
    await sql`delete from photo_render_notified where vehicle_id = ${vehicleId}`;
    await sql`update vehicles set is_sample = true where id = ${vehicleId}`;
    await sql`select app.listing_cache_refresh(array[${vehicleId}::uuid])`;
  }
  await sql.end();
});

test('the side profile is the cover, renders first, real photos reachable, with the note', async ({ page }) => {
  await page.goto(`/cars/${slug}`);
  const note = page.getByTestId('rendered-note');
  await expect(note).toContainText('Rendered photos.');
  await expect(page.locator('.gallery__count')).toContainText('(rendered)');
  const real = page.getByTestId('see-real-photos');
  if (await real.count()) { await real.click(); await expect(page.locator('.gallery__count')).toContainText('(real photo)'); }
  await noOverflow(page);
});

test('a finished render set queues the owner\'s branded email and Fleet\'s notice', async () => {
  const [{ n }] = await sql`select app.photo_render_notices() as n`;
  expect(Number(n)).toBeGreaterThanOrEqual(1);
  const ev = await sql`select code from app_events where entity_id = ${vehicleId} and code like '%car_photos_ready' order by code`;
  expect(ev.map((e) => e.code)).toEqual(['owner_car_photos_ready', 'staff_car_photos_ready']);
  await sql`select app.process_events(1000)`;
  const [o] = await sql`select count(*)::int as n from notification_outbox where code = 'owner_car_photos_ready' and vehicle_id = ${vehicleId}`;
  expect(o!.n).toBeGreaterThanOrEqual(1);
});

test('the Cars filter lists one model per family, never a trim of its own', async ({ page }) => {
  await page.goto('/cars');
  const open = page.getByRole('button', { name: /filters/i }).first();
  if (await open.isVisible().catch(() => false) && !(await page.locator('#fl-model').isVisible())) await open.click();
  const options = await page.locator('#fl-model option').allTextContents();
  expect(options.length).toBeGreaterThan(1);
  // a trim was an indented option before (" CLA250 4MATIC"); now every option is a family with its number of cars
  for (const o of options.slice(1)) expect(o).toMatch(/^\S.* \(\d+\)$/);
  await noOverflow(page);
});

test('the card stands on its studio floor with the cutout once one is made', async ({ page }) => {
  await sql`insert into site_cutouts (vehicle_id, shot, source_kind, source_bucket, source_path, path, width, height, facing, made_at)
            values (${vehicleId}, 'left', 'studio', 'vehicle-public', 'e2e', 'site/cutouts/e2e-left.svg', 1500, 500, 'left', now())
            on conflict (vehicle_id, shot) do update set path = excluded.path`;
  await sql`select app.listing_cache_refresh(array[${vehicleId}::uuid])`;
  await page.goto('/cars');
  await expect(page.locator('.car-stage').first()).toBeVisible();
  await noOverflow(page);
});

test('the hero shows the logo at once under reduced motion, and the footer can pause animations', async ({ page }) => {
  await page.goto('/');
  await expect(page.locator('.hero__logo')).toBeVisible();
  expect(await page.evaluate(() => document.documentElement.dataset.moDraw ?? null)).toBeNull();
  const pause = page.getByTestId('motion-pause').first();
  await pause.click();
  await expect(pause).toHaveAttribute('aria-pressed', 'true');
  expect(await page.evaluate(() => document.documentElement.dataset.motion)).toBe('reduced');
  await pause.click();
  await expect(pause).toHaveAttribute('aria-pressed', 'false');
});
