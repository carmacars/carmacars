// Unit tests for Fleet's car status board (carboard.ts): a late return first, then today's handovers and returns, then
// cars on rent, on Turo, blocked and available.
//   npm run test:unit
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { carBoard, countStates, type CalVehicle } from './carboard.ts';

const NOW = Date.parse('2026-10-25T16:00:00Z'); // noon in Toronto
const h = (n: number) => new Date(NOW + n * 3600_000).toISOString();
const car = (id: string, entries: CalVehicle['entries']): CalVehicle => ({ id, label: `Car ${id}`, plate: null, status: 'active', entries });
const bk = (status: string, s: number, e: number, n = 'CC-1') => ({ type: 'booking', status, starts_at: h(s), ends_at: h(e), blocks: true, booking_number: n });

test('each car gets one state, the most pressing first', () => {
  const rows = carBoard([
    car('free', []),
    car('rent', [bk('on_rent', -48, 48)]),
    car('back', [bk('on_rent', -48, 3, 'CC-2')]),
    car('late', [bk('on_rent', -48, -1, 'CC-3')]),
    car('out', [bk('confirmed', 2, 30, 'CC-4')]),
    car('turo', [{ type: 'turo_trip', status: null, starts_at: h(-5), ends_at: h(20), blocks: true, booking_number: null }]),
    car('block', [{ type: 'block', status: null, starts_at: h(-5), ends_at: h(20), blocks: true, booking_number: null, reason: 'service' }]),
    { ...car('gone', []), status: 'retired' }
  ], NOW);
  assert.deepEqual(rows.map((r) => [r.id, r.state]), [['late', 'late'], ['out', 'out_today'], ['back', 'back_today'], ['rent', 'on_rent'], ['turo', 'turo'], ['block', 'blocked'], ['free', 'free']]);
  assert.equal(rows.find((r) => r.id === 'block')?.note, 'service');
  assert.equal(countStates(rows).free, 1);
});

test('a non-blocking booking does not take the car', () => {
  const [r] = carBoard([car('x', [{ ...bk('confirmed', 1, 30), blocks: false }])], NOW);
  assert.equal(r!.state, 'free');
});
