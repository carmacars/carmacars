import { test } from 'node:test';
import assert from 'node:assert/strict';
import { boardTiles, type Dash } from './board.ts';

const dash = (over: Partial<Dash> = {}): Dash => ({ target_minutes: 5, requests: [], offers: [], payments_failed: [], deposits_due: [], late: [], tasks: [], alerts: [], ...over });
const quiet = { pickups: [], returns: [], late: 0 };
const by = (tiles: ReturnType<typeof boardTiles>) => Object.fromEntries(tiles.map((t) => [t.key, t]));

test('a quiet day: seven counts at zero, none urgent', () => {
  const t = boardTiles(dash(), quiet, 0);
  assert.deepEqual(t.map((x) => x.key), ['requests', 'pickups', 'returns', 'payments', 'deposits', 'tasks', 'alerts']);
  assert.ok(t.every((x) => x.count === 0 && !x.urgent));
  assert.equal(by(t).requests!.wait, undefined);
});

test('requests: those waiting on the renter are not counted; the oldest wait past the target is urgent', () => {
  const t = by(boardTiles(dash({ requests: [
    { booking_number: 'CC-1', waiting_minutes: 3, awaiting_renter: false },
    { booking_number: 'CC-2', waiting_minutes: 42, awaiting_renter: false },
    { booking_number: 'CC-3', waiting_minutes: 900, awaiting_renter: true }] }), quiet, 0));
  assert.equal(t.requests!.count, 2);
  assert.deepEqual(t.requests!.wait, { minutes: 42, target: 5 });
  assert.equal(t.requests!.urgent, true);
});

test('pickups not ready, cars late, failed payments, overdue tasks and site problems are urgent', () => {
  const t = by(boardTiles(dash({ payments_failed: [{}], tasks: [{ queue: 'cs', open: 4, overdue: 1, escalated: 0 }, { queue: 'fleet', open: 2, overdue: 0, escalated: 0 }],
    deposits_due: [{ kind: 'take' }, { kind: 'release' }, { kind: 'release' }] }),
    { pickups: [{ ready: true }, { ready: false }], returns: [{ late: true }], late: 1 }, 2));
  assert.equal(t.pickups!.note, '1 not ready');
  assert.equal(t.returns!.href, '/admin/bookings?status=on_rent');
  assert.equal(t.payments!.urgent, true);
  assert.equal(t.tasks!.count, 6);
  assert.equal(t.tasks!.note, '1 overdue');
  assert.equal(t.deposits!.note, '1 to take, 2 to release');
  assert.equal(t.alerts!.count, 2);
  assert.equal(t.alerts!.href, '#site-health');
});

test('without the dashboard read the board still shows today\'s pickups and returns', () => {
  const t = by(boardTiles(null, { pickups: [{ ready: true }], returns: [], late: 0 }, 0));
  assert.equal(t.pickups!.count, 1);
  assert.equal(t.requests!.count, 0);
});
