import { test } from 'node:test';
import assert from 'node:assert/strict';
import { carWords, rideshareProblem, RIDESHARE_PLATFORMS } from './model.ts';

test('the six platforms the owner listed', () => { assert.deepEqual(RIDESHARE_PLATFORMS.map(([, l]) => l), ['Uber', 'Lyft', 'DoorDash', 'Uber Eats', 'Instacart', 'Other']); });
test('the car in words', () => { assert.equal(carWords({ year: 2023, make: 'Toyota', model: 'Corolla', colour: 'White', plate: null, vin: null }), '2023 Toyota Corolla, White'); });
test('a platform is picked, and other is named', () => {
  assert.equal(rideshareProblem([], ''), 'Pick at least one platform.');
  assert.equal(rideshareProblem(['other'], ' '), 'Name the other platform.');
  assert.equal(rideshareProblem(['uber', 'other'], 'Skip'), null);
});
