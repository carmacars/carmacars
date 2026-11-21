import { test } from 'node:test';
import assert from 'node:assert/strict';
import { airportTitle } from './copy.ts';

test('an airport title never cuts the brand', () => {
  assert.equal(airportTitle('Billy Bishop', 'YTZ', 'CarmaCars'), 'Billy Bishop (YTZ) Car Rental, Delivered to the Terminal | CarmaCars');
  assert.equal(airportTitle('Toronto Pearson', 'YYZ', 'CarmaCars'), 'Toronto Pearson (YYZ) Car Rental at the Terminal | CarmaCars');
  for (const t of [airportTitle('Toronto Pearson', 'YYZ', 'CarmaCars'), airportTitle('A very long airport name for a test', 'XXX', 'CarmaCars')]) assert.ok(t.length <= 70 && /\| CarmaCars$/.test(t));
});
