// r48 (3041): one car's location in words, and its map link.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { NO_TRACKER, locationLine, mapLink, type CarLoc } from './location.ts';

const NOW = Date.parse('2026-11-15T15:00:00Z');
const car = (o: Partial<CarLoc> = {}): CarLoc => ({ vehicle_id: 'v', name: 'Test car', tracker: true, pos: null, ...o });

test('no tracker: "No tracker yet" instead of an empty map; a tracker that has not reported says so', () => {
  assert.equal(locationLine(car({ tracker: false }), NOW), `${NO_TRACKER}.`);
  assert.equal(NO_TRACKER, 'No tracker yet');
  assert.match(locationLine(car(), NOW), /not reported a position yet/);
});

test('moving with its speed, or parked, and how long ago', () => {
  const pos = { lat: 43.65, lng: -79.38, at: '2026-11-15T14:58:00Z', speed: 52.4, ignition: true, moving: true };
  assert.equal(locationLine(car({ pos }), NOW), 'Moving at 52 km/h, seen 2 min ago.');
  assert.equal(locationLine(car({ pos: { ...pos, moving: false, at: '2026-11-15T12:00:00Z' } }), NOW), 'Parked, last seen 3 h ago.');
  assert.equal(locationLine(car({ pos: { ...pos, at: '2026-11-15T15:00:00Z' } }), NOW), 'Moving at 52 km/h, seen just now.');
});

test('the map link opens the point on OpenStreetMap', () => {
  assert.equal(mapLink({ lat: 43.65, lng: -79.38 }), 'https://www.openstreetmap.org/?mlat=43.65000&mlon=-79.38000#map=16/43.65000/-79.38000');
});
