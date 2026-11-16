// r48 O (3080): real cars cut out where a section photo's sample car stood (lib/slot-cars.ts).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { carPlace, isStandIn, slotScene, HERO_MAX, type SiteCutout } from './slot-cars.ts';
import { SLOT_CARS } from './slot-cars-data.ts';

const photo = (base: string) => ({ alt: 'x', wide: { path: `site/${base}-wide.svg`, width: 2400, height: 1200 }, tall: { path: `site/${base}-tall.svg`, width: 1200, height: 1500 } });
const cut = (id: string, facing: 'left' | 'right' = 'left'): SiteCutout => ({ vehicle_id: id, path: `site/cutouts/${id}/left-1.webp`, width: 1600, height: 600, facing, alt: `Car ${id}` });

test('only a section photo that is still the stand-in with its sample car gets cars', () => {
  assert.equal(isStandIn('home.hero', photo('home-hero')), true);
  assert.equal(isStandIn('home.hero', { ...photo('home-hero'), wide: { path: 'site/my-real-photo.jpg', width: 2400, height: 1200 } }), false);
  assert.equal(slotScene('home.hero', { ...photo('home-hero'), tall: { path: 'site/other.jpg', width: 1, height: 1 } }, [cut('a')]), null);
  assert.equal(slotScene('how.handover', photo('how-handover'), [cut('a')]), null, 'no sample car in that section');
  assert.equal(slotScene('home.hero', photo('home-hero'), []), null, 'no cutout yet: the photo stays');
});

test('the hero shows every car in turn, on the plate, where the sample car stood', () => {
  const cars = Array.from({ length: 9 }, (_, i) => cut(`c${i}`));
  const s = slotScene('home.hero', photo('home-hero'), cars, { rotate: true })!;
  assert.equal(s.cars.length, 1);
  assert.equal(s.cars[0]!.length, HERO_MAX);
  assert.equal(s.wide.plate, '/site-plates/home-hero-wide-plate.svg');
  assert.deepEqual(s.wide.boxes, SLOT_CARS['home.hero']!.wide);
  assert.equal(s.cars[0]![0]!.mirror, false);
});

test('a section with several sample cars gets a car each; a car facing the other way is mirrored', () => {
  const s = slotScene('home.owner', photo('home-owner'), [cut('a'), cut('b'), cut('c', 'right')])!;
  assert.equal(s.cars.length, 3);
  assert.deepEqual(new Set(s.cars.map((x) => x[0]!.path)).size, 3);
  assert.equal(s.cars.flat().find((c) => c.path.includes('/c/'))!.mirror, true);
  // the delivery scenes' car faces right: a left-facing cutout is mirrored
  assert.equal(slotScene('home.delivery', photo('home-delivery'), [cut('a')])!.cars[0]![0]!.mirror, true);
});

test('a car stands as long as the sample car, on its ground line', () => {
  assert.deepEqual(carPlace({ left: 51.04, top: 50.67, width: 41.92, height: 25.75 }), { left: 51.04, width: 41.92, bottom: 23.58 });
});
