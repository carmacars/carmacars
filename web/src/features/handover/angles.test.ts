// The suggested angles (0545): every key the picker tags maps to a report shot in the database's app.angle_shot.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ANGLES, anglesDone, photoKey } from './angles.ts';

test('the fifteen suggested angles, in the order the owner listed them', () => {
  assert.deepEqual(ANGLES.map(([k]) => k), ['front', 'front_left', 'left', 'rear_left', 'rear', 'rear_right', 'right', 'front_right', 'odometer', 'fuel', 'interior_front', 'interior_rear', 'trunk', 'wheels', 'damage']);
});

test('an angle is ticked by a tagged photo or by hand; an unknown tag ticks nothing', () => {
  const done = anglesDone([{ angle: 'front' }, { angle: null }, { angle: 'bogus' }], new Set(['trunk']));
  assert.deepEqual([...done].sort(), ['front', 'trunk']);
});

test('photo keys have the shapes the database accepts', () => {
  const id = '11111111-2222-4333-8444-555555555555';
  assert.equal(photoKey('self-pickup', id, id, false), `bookings/${id}/self-pickup/${id}.jpg`);
  assert.equal(photoKey('owner-handoff', id, id, true), `vehicles/${id}/owner-handoff/${id}.png`);
});
