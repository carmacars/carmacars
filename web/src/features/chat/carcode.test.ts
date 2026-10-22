import { test } from 'node:test';
import assert from 'node:assert/strict';
import { carByCode, codesIn, type FleetCar } from './agent.ts';

const car = (slug: string, code: string): FleetCar => ({ slug, name: slug, class: 'standard', seats: 5, transmission: 'auto', fuel: 'gas', daily_rate_cents: 5000, deposit_cents: 30000, vehicle_id: slug, code });
const fleet = [car('kia-forte', 'CC-7F3A'), car('vw-jetta', 'CC-CC9K')];

test('a car code finds its car, with or without the prefix, the dash or the case', () => {
  assert.equal(carByCode({ fleet }, 'CC-7F3A')?.slug, 'kia-forte');
  assert.equal(carByCode({ fleet }, 'cc 7f3a')?.slug, 'kia-forte');
  assert.equal(carByCode({ fleet }, '7F3A')?.slug, 'kia-forte');
  assert.equal(carByCode({ fleet }, 'CC9K')?.slug, 'vw-jetta');
  assert.equal(carByCode({ fleet }, 'CC-0000'), undefined);
});

test('the codes written in a message', () => {
  assert.deepEqual(codesIn('Is cc-7f3a free next week, or CC 9ZZZ?'), ['CC-7F3A', 'CC-9ZZZ']);
  assert.deepEqual(codesIn('booking CC-10057 please'), [], 'a booking number is not a car code');
});
