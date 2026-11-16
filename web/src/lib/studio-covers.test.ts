// r48 (3040): real studio covers where a sample photo was shown: matched to the slot, the sample kept when nothing matches.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import type { CarRow } from './types.ts';
import { cardKeyframes, studioPool, withStudio, STUDIO_MAX, type StudioCover } from './studio-covers.ts';

const car = (id: string, o: Partial<CarRow> = {}): CarRow => ({
  vehicle_id: id, slug: `car-${id}`, path: `/cars/car-${id}`, canonical_path: `/cars/car-${id}`, headline: null, year: 2022, make: 'Toyota', model: 'Corolla',
  trim: null, colour: null, fuel: 'gas', class: 'compact', classes: ['compact'], body_style: 'sedan', seats: 5, transmission: null, doors: 4, drivetrain: null,
  luggage: null, home_area: null, allows_18_to_20: false, is_featured: false, taking_requests: true, model_hub_path: '/x', daily_rate_cents: 5000,
  weekend_rate_cents: 0, weekly_rate_cents: 0, monthly_rate_cents: 0, km_allowance_per_day: 200, overage_cents_per_km: 25, deposit_cents: 0,
  delivery_fee_cents: 0, pickup_fee_cents: 0, cover: { path: `vehicles/${id}/cover.jpg`, alt: '' }, published_at: null, updated_at: null, ...o });
const cov = (id: string): StudioCover => ({ vehicle_id: id, path: `vehicles/${id}/front-left-r48.jpg`, width: 1800, height: 1200, alt: 'x' });
const SAMPLE = { path: '/sample-photos/studio/sedan/white/lead/X.svg', alt: '', sample: true };

test('an example car (sample photo) shows real studio covers of the same body style, else the same class', () => {
  const fleet = [car('a'), car('b', { make: 'Honda', model: 'Civic' }), car('c', { body_style: 'suv', class: 'suv', classes: ['suv'] })];
  const covers = [cov('a'), cov('b'), cov('c')];
  const ex = car('s', { is_sample: true, cover: SAMPLE });
  const [row] = withStudio([ex], covers, fleet);
  assert.deepEqual(row!.studio!.map((p) => p.path).sort(), ['vehicles/a/front-left-r48.jpg', 'vehicles/b/front-left-r48.jpg']);
  assert.match(row!.studio![0]!.alt, /similar car/);
  // no car of that body style: the same class
  const van = car('v', { is_sample: true, cover: SAMPLE, body_style: 'van', class: 'suv', classes: ['suv'] });
  assert.deepEqual(withStudio([van], covers, fleet)[0]!.studio!.map((p) => p.path), ['vehicles/c/front-left-r48.jpg']);
  // nothing matches: the sample photo stays (no studio)
  const truck = car('t', { is_sample: true, cover: SAMPLE, body_style: 'truck', class: 'truck', classes: ['truck'] });
  assert.equal(withStudio([truck], covers, fleet)[0]!.studio, undefined);
});

test('a real car with no photo yet: only covers of the same make and model; a car with its own photo: never', () => {
  const fleet = [car('a'), car('b', { make: 'Honda', model: 'Civic' })];
  const covers = [cov('a'), cov('b')];
  const bare = car('n', { cover: SAMPLE, make: 'Honda', model: 'Civic' });
  assert.deepEqual(withStudio([bare], covers, fleet)[0]!.studio!.map((p) => p.path), ['vehicles/b/front-left-r48.jpg']);
  assert.equal(withStudio([car('a')], covers, fleet)[0]!.studio, undefined, 'its own photo');
  // its own cover is never in its pool; covers of cars not on the site are left out
  assert.deepEqual(studioPool(car('a', { cover: SAMPLE }), [cov('a'), cov('zz')], new Map(fleet.map((x) => [x.vehicle_id, x]))), []);
  // no covers at all: the rows as they were
  assert.deepEqual(withStudio([bare], [], fleet), [bare]);
});

test('at most a few covers a card, each card starting at another car', () => {
  const fleet = Array.from({ length: 8 }, (_, i) => car(`r${i}`));
  const covers = fleet.map((c) => cov(c.vehicle_id));
  const a = withStudio([car('s1', { is_sample: true, cover: SAMPLE }), car('s2x', { is_sample: true, cover: SAMPLE })], covers, fleet);
  assert.equal(a[0]!.studio!.length, STUDIO_MAX);
  assert.notEqual(a[0]!.studio![0]!.path, a[1]!.studio![0]!.path);
  assert.equal(cardKeyframes(1), '');
  assert.match(cardKeyframes(3), /@keyframes card-studio-3\{0%\{opacity:0\}6\.667%\{opacity:1\}33\.333%\{opacity:1\}40\.000%\{opacity:0\}100%\{opacity:0\}\}/);
});
